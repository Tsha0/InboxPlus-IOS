import Darwin
import Foundation

/// Allocates a free loopback port by binding an ephemeral socket and reading it back.
public struct LoopbackPortAllocator: Sendable {
    public init() {}

    public func allocate() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RuntimeProfileError.portAllocationFailed }
        defer { _ = close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw RuntimeProfileError.portAllocationFailed }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard read == 0 else { throw RuntimeProfileError.portAllocationFailed }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// Assembles the pinned runtime, configuration, supervisor, and persisted session for one profile.
///
/// The CLI stays a thin adapter by delegating every multi-step operation here.
public struct RuntimeProfileService: Sendable {
    public let paths: RuntimePaths
    public let packageRoot: URL

    private let store: RuntimeProfileStore
    private let portAllocator: LoopbackPortAllocator

    public init(paths: RuntimePaths, packageRoot: URL) {
        self.paths = paths
        self.packageRoot = packageRoot.standardizedFileURL
        store = RuntimeProfileStore(paths: paths)
        portAllocator = LoopbackPortAllocator()
    }

    /// `~/Library/Application Support/Inbox+/DeveloperRuntime`, overridable for disposable runs.
    public static func developerRuntimeRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let override = environment["INBOXPLUS_RUNTIME_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("Inbox+", isDirectory: true)
            .appendingPathComponent("DeveloperRuntime", isDirectory: true)
            .standardizedFileURL
    }

    /// Repository root holding `Runtime/Synapse`, overridable for installed or relocated runs.
    public static func resolvedPackageRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL
    ) -> URL {
        if let override = environment["INBOXPLUS_RUNTIME_PACKAGE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        // Both the app and its CLI live in Contents/MacOS. Prefer bundled runtime inputs so
        // launching from Finder does not depend on a checkout or the working directory.
        if let executableURL {
            let resources = executableURL.deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
            if FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("Runtime/Synapse/runtime-manifest.json").path
            ) { return resources.standardizedFileURL }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    public var manifestFile: URL {
        packageRoot.appendingPathComponent("Runtime/Synapse/runtime-manifest.json")
    }

    public var requirementsLockFile: URL {
        packageRoot.appendingPathComponent("Runtime/Synapse/requirements.lock")
    }

    public func loadManifest() throws -> RuntimeManifest {
        guard FileManager.default.fileExists(atPath: manifestFile.path) else {
            throw RuntimeProfileError.missingRuntimeManifest(manifestFile)
        }
        return try RuntimeManifest.load(from: manifestFile)
    }

    public func loadState() throws -> RuntimeProfileState? { try store.load() }

    // MARK: - Bootstrap

    public func bootstrap(python: URL) async throws -> PreparedRuntimeReceipt {
        let manifest = try loadManifest()
        try createProfileDirectories()

        let receipt = try await RuntimeBootstrapper(requirementsLock: requirementsLockFile)
            .bootstrap(python: python, manifest: manifest, paths: paths)

        try finishBootstrap()
        return receipt
    }

    /// Installs the signed, self-contained runtime shipped in the app. No downloads or build tools.
    public func bootstrapBundled() throws -> PreparedRuntimeReceipt {
        try createProfileDirectories()
        let receipt = try BundledRuntime(packageRoot: packageRoot).install(paths: paths)
        try finishBootstrap()
        return receipt
    }

    private func finishBootstrap() throws {
        let existing = try store.load()
        let registrationSecret = existing?.registrationSecret ?? Self.freshRegistrationSecret()
        let virtualPython = paths.runtime.appendingPathComponent("venv/bin/python")

        // Rendering with a placeholder port is enough to generate the signing keys; `start`
        // re-renders the file with the port it actually allocates.
        let configuration = SynapseConfiguration(
            profile: paths,
            port: try portAllocator.allocate(),
            credentials: SynapseCredentials(registrationSecret: registrationSecret)
        )
        let configurationFile = try configuration.write()
        try generateSigningKeys(python: virtualPython, configurationFile: configurationFile)

        try store.save(
            RuntimeProfileState(
                serverName: configuration.serverName,
                registrationSecret: registrationSecret,
                launchExecutable: try Self.stableLaunchExecutable(virtualPython: virtualPython).path,
                virtualEnvironmentPython: virtualPython.path,
                configurationFile: configurationFile.path,
                snapshot: .stopped
            )
        )
    }

    // MARK: - Lifecycle

    /// Launches Synapse and supervises it for as long as this process lives.
    ///
    /// The supervisor only ever controls its own direct child, so the owning process must stay
    /// alive for the whole session. `onReady` fires once the runtime is healthy; the session then
    /// runs until `interrupt` resolves or supervision reaches a terminal state, and always stops
    /// the child before returning.
    public func runForegroundSession(
        interrupt: @Sendable @escaping () async -> Void,
        onReady: @Sendable (RuntimeSnapshot) -> Void = { _ in }
    ) async throws -> RuntimeSnapshot {
        try await withRunningRuntime(onReady: onReady) { supervisor, _ in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await supervisor.supervise() }
                group.addTask { await interrupt() }
                await group.next()
                group.cancelAll()
                await group.waitForAll()
            }
        }
        return try store.load()?.snapshot ?? .stopped
    }

    /// Starts Synapse, runs `body` against the healthy runtime, then always stops it.
    ///
    /// Every command that needs a live Synapse (benchmark, fixture verification, recovery
    /// exercises) owns the full lifecycle inside one process through this entry point.
    @discardableResult
    public func withRunningRuntime<T>(
        onReady: @Sendable (RuntimeSnapshot) -> Void = { _ in },
        _ body: @Sendable (SynapseSupervisor, RuntimeContext) async throws -> T
    ) async throws -> T {
        let state = try requirePreparedState()
        let port = try portAllocator.allocate()
        let configuration = SynapseConfiguration(
            profile: paths,
            port: port,
            credentials: SynapseCredentials(registrationSecret: state.registrationSecret)
        )
        _ = try configuration.write()

        let supervisor = try makeSupervisor(state: state, port: port, snapshot: state.snapshot)
        let started = try await supervisor.start()
        try store.save(state.replacing(snapshot: started))
        onReady(started)

        let context = RuntimeContext(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            serverName: configuration.serverName,
            registrationSecret: state.registrationSecret,
            port: port,
            paths: paths
        )
        do {
            let value = try await body(supervisor, context)
            try await stopAndPersist(supervisor: supervisor, state: state)
            return value
        } catch {
            try? await stopAndPersist(supervisor: supervisor, state: state)
            throw error
        }
    }

    @discardableResult
    private func stopAndPersist(
        supervisor: SynapseSupervisor,
        state: RuntimeProfileState
    ) async throws -> RuntimeSnapshot {
        do {
            let stopped = try await supervisor.stop()
            try store.save(state.replacing(snapshot: stopped))
            return stopped
        } catch {
            try? store.save(state.replacing(snapshot: await supervisor.status()))
            throw error
        }
    }

    /// Reports the persisted phase reconciled against the live process, without controlling it.
    ///
    /// Observation is safe from any process; only control requires direct-child ownership. This
    /// never persists, so it cannot race the session that owns the runtime.
    public func status() async throws -> RuntimeSnapshot {
        let state = try requirePreparedState()
        guard let identity = state.snapshot.processIdentity,
              let port = state.snapshot.loopbackPort
        else {
            return state.snapshot
        }
        switch await SynapseHealthChecker.systemIdentityStatus(identity) {
        case .matching:
            break
        case .exited, .mismatched:
            return .stopped
        case let .indeterminate(failure):
            throw failure
        }

        // Probe health directly rather than through the supervisor: the supervisor reports any
        // process it does not own as `uncontrolledProcess`, which is a statement about control
        // authority, not about the runtime's health.
        let checker = try SynapseHealthChecker(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            serverName: state.serverName,
            registrationSecret: state.registrationSecret,
            credentialStore: try SynapseProbeCredentialStore(profileRoot: paths.profile)
        )
        switch await checker.check(snapshot: state.snapshot) {
        case .healthy:
            return try RuntimeSnapshot(
                phase: .healthy,
                processIdentity: identity,
                loopbackPort: port,
                restartCount: state.snapshot.restartCount,
                lastHealthResult: "healthy",
                diagnosticLogDirectory: paths.logs,
                lastError: nil
            )
        case let .degraded(failure):
            return try RuntimeSnapshot(
                phase: .degraded,
                processIdentity: identity,
                loopbackPort: port,
                restartCount: state.snapshot.restartCount,
                lastHealthResult: "degraded",
                diagnosticLogDirectory: paths.logs,
                lastError: String(describing: failure)
            )
        case .stopped:
            return .stopped
        }
    }

    /// Reconciles a profile whose owning session is gone.
    ///
    /// A live runtime belongs to the foreground session that launched it, so this refuses to act
    /// while that session still owns the child rather than signalling a process it does not own.
    public func stop() async throws -> RuntimeSnapshot {
        let state = try requirePreparedState()
        guard let identity = state.snapshot.processIdentity else {
            let snapshot = RuntimeSnapshot.stopped
            try store.save(state.replacing(snapshot: snapshot))
            return snapshot
        }
        switch await SynapseHealthChecker.systemIdentityStatus(identity) {
        case .matching:
            throw RuntimeProfileError.runtimeOwnedByForegroundSession(
                processIdentifier: identity.processIdentifier
            )
        case .exited, .mismatched:
            try store.save(state.replacing(snapshot: .stopped))
            return .stopped
        case let .indeterminate(failure):
            throw failure
        }
    }

    // MARK: - Verification

    /// Validates the prepared runtime receipt and the rendered loopback-only configuration.
    public func verifyPreparedRuntime() throws -> PreparedRuntimeReceipt {
        let manifest = try loadManifest()
        let state = try requirePreparedState()
        let receipt = try manifest.validatePreparedRuntime(
            at: paths.runtime.appendingPathComponent(RuntimeBootstrapper.receiptName)
        )
        let configurationFile = URL(fileURLWithPath: state.configurationFile)
        let rendered = try String(contentsOf: configurationFile, encoding: .utf8)
        guard rendered.contains("bind_addresses: ['127.0.0.1']") else {
            throw SynapseConfigurationError.nonLoopbackAddress("configuration is not loopback-only")
        }
        return receipt
    }

    /// Records a completed recovery exercise against the most recent stored report.
    private func applyRecoveryEvidence(_ result: RecoveryResult) throws {
        let state = try requirePreparedState()
        let entries = try FileManager.default.contentsOfDirectory(atPath: paths.reports.path)
            .filter { $0.hasSuffix(".json") }
        guard !entries.isEmpty else { return }

        let latest = try entries.map { name -> (String, Date) in
            let attributes = try FileManager.default.attributesOfItem(
                atPath: paths.reports.appendingPathComponent(name).path
            )
            return (name, (attributes[.modificationDate] as? Date) ?? .distantPast)
        }
        .max { $0.1 < $1.1 }!
        .0

        let jsonURL = paths.reports.appendingPathComponent(latest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var report = try decoder.decode(BenchmarkReport.self, from: Data(contentsOf: jsonURL))

        var run = report.run
        run.recoveryVerified = result.succeeded
        report = BenchmarkReport(
            run: run,
            verdict: BenchmarkReporter.evaluate(run),
            generatedAt: report.generatedAt
        )
        _ = try BenchmarkReporter(sensitiveValues: [state.registrationSecret]).write(
            run,
            verdict: report.verdict,
            to: paths.reports,
            name: latest.replacingOccurrences(of: ".json", with: "")
        )
    }

    /// Checks that a written report is complete and free of secrets.
    ///
    /// `latest` selects the most recently modified report; any other name selects it exactly.
    public func verifyReport(named selector: String) throws -> ReportVerification {
        let state = try requirePreparedState()
        let entries = try FileManager.default.contentsOfDirectory(atPath: paths.reports.path)
            .filter { $0.hasSuffix(".json") }
        guard !entries.isEmpty else { throw ReportVerificationError.noReportsFound(paths.reports) }

        let chosen: String
        if selector == "latest" {
            chosen = try entries.map { name -> (String, Date) in
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: paths.reports.appendingPathComponent(name).path
                )
                return (name, (attributes[.modificationDate] as? Date) ?? .distantPast)
            }
            .max { $0.1 < $1.1 }!
            .0
        } else {
            chosen = selector.hasSuffix(".json") ? selector : "\(selector).json"
            guard entries.contains(chosen) else {
                throw ReportVerificationError.reportNotFound(chosen)
            }
        }

        let jsonURL = paths.reports.appendingPathComponent(chosen)
        let markdownURL = paths.reports.appendingPathComponent(
            chosen.replacingOccurrences(of: ".json", with: ".md")
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(BenchmarkReport.self, from: Data(contentsOf: jsonURL))

        guard report.run.environment != nil else {
            throw ReportVerificationError.incompleteReport("environment is missing")
        }
        guard !report.run.samples.warmTimelineReads.isEmpty,
              !report.run.samples.committedEventVisibility.isEmpty,
              !report.run.samples.imports.isEmpty
        else {
            throw ReportVerificationError.incompleteReport("raw latency samples are missing")
        }
        guard report.run.sqliteIntegrity != nil else {
            throw ReportVerificationError.incompleteReport("SQLite integrity is missing")
        }

        // The registration secret is the one profile value that could plausibly reach a report.
        let markdown = (try? String(contentsOf: markdownURL, encoding: .utf8)) ?? ""
        let json = String(decoding: try Data(contentsOf: jsonURL), as: UTF8.self)
        let leaked = [markdown, json].contains { $0.contains(state.registrationSecret) }
        guard !leaked else { throw ReportVerificationError.secretLeaked }

        return ReportVerification(
            name: chosen,
            decision: report.verdict.decision,
            failingGates: report.verdict.gates.filter { !$0.passed }.map(\.name),
            sampleCount: report.run.samples.imports.count
                + report.run.samples.warmTimelineReads.count
                + report.run.samples.committedEventVisibility.count
        )
    }

    /// Provisions deterministic fixture rooms against a live runtime and reconciles them back.
    public func verifyFixtures(seed: UInt64, rooms: Int) async throws -> FixtureVerification {
        try await withRunningRuntime { _, context in
            let provisioner = try MatrixFixtureProvisioner(
                baseURL: context.baseURL,
                serverName: context.serverName,
                registrationSecret: context.registrationSecret
            )
            let fixture = try await provisioner.prepare(seed: seed, roomCount: rooms)
            let client = try MatrixHTTPClient(
                baseURL: context.baseURL,
                accessToken: fixture.accessToken
            )
            let joined: JoinedRoomsResponse = try await client.send(
                .get,
                path: ["_matrix", "client", "v3", "joined_rooms"],
                idempotent: true
            )
            let expected = Set(fixture.roomIDs)
            return FixtureVerification(
                seed: seed,
                requestedRooms: rooms,
                createdRooms: fixture.roomIDs.count,
                reconciledRooms: expected.intersection(joined.joinedRooms).count,
                missingRooms: expected.subtracting(joined.joinedRooms).sorted()
            )
        }
    }

    /// Provisions fixtures, runs the workload against a live runtime, and reconciles the result.
    ///
    /// SQLite integrity is checked after the runtime stops, because `PRAGMA integrity_check`
    /// is only meaningful against a database no longer being written.
    public func runBenchmark(_ workload: BenchmarkWorkload) async throws -> BenchmarkReport {
        let state = try requirePreparedState()
        var run = try await withRunningRuntime { _, context in
            let provisioner = try MatrixFixtureProvisioner(
                baseURL: context.baseURL,
                serverName: context.serverName,
                registrationSecret: context.registrationSecret
            )
            let fixture = try await provisioner.prepare(
                seed: workload.seed,
                roomCount: workload.roomCount
            )
            let client = try MatrixHTTPClient(
                baseURL: context.baseURL,
                accessToken: fixture.accessToken
            )
            return try await BenchmarkRunner(
                operations: LiveBenchmarkOperations(client: client, rooms: fixture.roomIDs)
            ).run(workload)
        }

        let manifest = try loadManifest()
        let receipt = try manifest.validatePreparedRuntime(
            at: paths.runtime.appendingPathComponent(RuntimeBootstrapper.receiptName)
        )
        run.sqliteIntegrity = try checkSQLiteIntegrity()
        run.environment = BenchmarkEnvironmentCollector().collect(
            receipt: receipt,
            manifest: manifest,
            databaseURL: databaseURL
        )

        let reporter = BenchmarkReporter(sensitiveValues: [state.registrationSecret])
        let verdict = BenchmarkReporter.evaluate(run)
        _ = try reporter.write(
            run,
            verdict: verdict,
            to: paths.reports,
            name: "benchmark-\(workload.seed)-\(workload.roomCount)x\(workload.messageCount)"
        )
        return BenchmarkReport(run: run, verdict: verdict, generatedAt: Date())
    }

    public var databaseURL: URL {
        paths.data.appendingPathComponent("homeserver.db")
    }

    /// Runs SQLite's own quick and full integrity checks against the stopped database.
    public func checkSQLiteIntegrity() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, "PRAGMA quick_check; PRAGMA integrity_check;"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "unavailable" }
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.allSatisfy { $0 == "ok" } ? "ok" : lines.joined(separator: "; ")
    }

    // MARK: - Backup and recovery

    public func removeProfile(
        confirmation: String,
        exportReportTo destination: URL?
    ) async throws -> RemovalResult {
        try await ProfileRemover(
            paths: paths,
            runtimeSnapshot: { try await status() }
        ).remove(confirmation: confirmation, exportReportTo: destination)
    }

    public func makeBackupManager() -> BackupManager {
        BackupManager(
            paths: paths,
            runtimeSnapshot: { try await status() }
        )
    }

    public func createBackup(name: String) async throws -> BackupManifest {
        try await makeBackupManager().create(name: name)
    }

    public func restoreBackup(name: String, into target: RuntimePaths) async throws -> RestoreResult {
        try await makeBackupManager().restore(name: name, into: target)
    }

    /// Damages the stopped database, restores the named backup, and proves the runtime recovers.
    ///
    /// Recovery counts as verified only when integrity passes, the fixture data reconciles, and
    /// the restored runtime accepts a brand new write.
    public func verifyRecovery(name: String, seed: UInt64) async throws -> RecoveryResult {
        let manager = makeBackupManager()
        let backupDirectory = paths.backups.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: backupDirectory.path) else {
            throw BackupError.backupNotFound(name)
        }

        // Simulate data loss on the stopped profile, keeping the backups tree intact.
        for entry in ["data", "configuration"] {
            let url = paths.profile.appendingPathComponent(entry)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try FileManager.default.removeItem(at: paths.state.appendingPathComponent(RuntimeProfileStore.fileName))

        // Restore into a staging profile, then move its contents back over this profile.
        let restoreTarget = try RuntimePaths(
            root: paths.root,
            profileName: "\(paths.profile.lastPathComponent)-recovery"
        )
        if FileManager.default.fileExists(atPath: restoreTarget.profile.path) {
            try FileManager.default.removeItem(at: restoreTarget.profile)
        }
        _ = try await manager.restore(name: name, into: restoreTarget)
        // Move back only what was damaged. `runtime/` must be left alone: the backup holds the
        // receipt but not the Python virtual environment, so replacing it would delete the venv.
        for entry in ["data", "configuration", "state/\(RuntimeProfileStore.fileName)"] {
            let source = restoreTarget.profile.appendingPathComponent(entry)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = paths.profile.appendingPathComponent(entry)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.moveItem(at: source, to: destination)
        }
        try FileManager.default.removeItem(at: restoreTarget.profile)

        let integrity = try checkSQLiteIntegrity()
        let observed = try await withRunningRuntime { _, context -> (Int, Int, Bool) in
            let provisioner = try MatrixFixtureProvisioner(
                baseURL: context.baseURL,
                serverName: context.serverName,
                registrationSecret: context.registrationSecret
            )
            let fixture = try await provisioner.prepare(seed: seed, roomCount: 1)
            let client = try MatrixHTTPClient(
                baseURL: context.baseURL,
                accessToken: fixture.accessToken
            )
            let joined: JoinedRoomsResponse = try await client.send(
                .get,
                path: ["_matrix", "client", "v3", "joined_rooms"],
                idempotent: true
            )
            let operations = LiveBenchmarkOperations(client: client, rooms: joined.joinedRooms)
            var events = 0
            for room in joined.joinedRooms {
                events += try await operations.eventIDs(inRoom: room).count
            }

            // A restored profile is only usable if it still accepts new writes.
            var acceptedNewWrite = false
            if let room = joined.joinedRooms.first {
                _ = try await operations.sendMessage(
                    roomID: room,
                    transactionID: "inboxplus-recovery-\(UUID().uuidString)",
                    body: "post-restore write"
                )
                acceptedNewWrite = true
            }
            return (joined.joinedRooms.count, events, acceptedNewWrite)
        }

        let result = RecoveryResult(
            integrity: integrity,
            roomCount: observed.0,
            eventCount: observed.1,
            acceptedNewWrite: observed.2
        )

        // The benchmark cannot verify recovery inside its own run, so its stored report carries an
        // unverified recovery gate. Fold this exercise's real evidence into that report and
        // re-evaluate, rather than leaving the verdict permanently incomplete.
        try? applyRecoveryEvidence(result)
        return result
    }

    // MARK: - Assembly

    public func makeSupervisor(
        state: RuntimeProfileState,
        port: UInt16,
        snapshot: RuntimeSnapshot
    ) throws -> SynapseSupervisor {
        let healthChecker = try SynapseHealthChecker(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            serverName: state.serverName,
            registrationSecret: state.registrationSecret,
            credentialStore: try SynapseProbeCredentialStore(profileRoot: paths.profile)
        )
        return SynapseSupervisor(
            configuration: managedProcessConfiguration(state: state),
            loopbackPort: port,
            healthChecker: healthChecker,
            initialSnapshot: snapshot
        )
    }

    public func managedProcessConfiguration(
        state: RuntimeProfileState
    ) -> ManagedProcessConfiguration {
        let virtualPython = URL(fileURLWithPath: state.virtualEnvironmentPython)
        return ManagedProcessConfiguration(
            executable: URL(fileURLWithPath: state.launchExecutable),
            arguments: [
                "-m", "synapse.app.homeserver",
                "--config-path", state.configurationFile,
            ],
            environment: [
                "PATH": virtualPython.deletingLastPathComponent().path + ":/usr/bin:/bin",
                "PYTHONUNBUFFERED": "1",
                "__PYVENV_LAUNCHER__": virtualPython.path,
            ],
            workingDirectory: paths.profile,
            profileRoot: paths.profile,
            logsDirectory: paths.logs,
            standardOutputLog: paths.logs.appendingPathComponent("stdout.log"),
            standardErrorLog: paths.logs.appendingPathComponent("stderr.log"),
            sensitiveLogValues: [state.registrationSecret]
        )
    }

    public func acquireProfileLock() throws -> ProfileLock {
        try FileManager.default.createDirectory(
            at: paths.state,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try ProfileLock.acquire(at: paths.state.appendingPathComponent("profile.lock"))
    }

    // MARK: - Helpers

    private func requirePreparedState() throws -> RuntimeProfileState {
        guard let state = try store.load() else {
            throw RuntimeProfileError.profileNotPrepared(paths.profile)
        }
        return state
    }

    private func createProfileDirectories() throws {
        // `paths.runtime` is deliberately absent: RuntimeBootstrapper owns it and treats a
        // pre-existing runtime directory without a receipt as drift.
        for directory in [
            paths.profile, paths.configuration,
            paths.data, paths.logs, paths.backups, paths.reports, paths.state,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private static func freshRegistrationSecret() -> String {
        UUID().uuidString + UUID().uuidString
    }

    private func generateSigningKeys(python: URL, configurationFile: URL) throws {
        let process = Process()
        process.executableURL = python
        process.arguments = [
            "-m", "synapse.app.homeserver",
            "--config-path", configurationFile.path,
            "--generate-keys",
        ]
        process.environment = [
            "PATH": python.deletingLastPathComponent().path + ":/usr/bin:/bin",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeProfileError.keyGenerationFailed(
                status: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    /// Resolve the interpreter's stable executable path for process identity verification, using
    /// the framework stub for Homebrew Python or the standalone binary for bundled Python.
    static func stableLaunchExecutable(virtualPython: URL) throws -> URL {
        let process = Process()
        process.executableURL = virtualPython
        process.arguments = ["-c", "import sys; print(sys._base_executable)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/")
        else {
            throw RuntimeProfileError.pythonExecutableUnavailable
        }
        let applicationExecutable = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Python.app/Contents/MacOS/Python")
        if FileManager.default.isExecutableFile(atPath: applicationExecutable.path) {
            return applicationExecutable
        }
        // Portable CPython has no framework application stub. Resolve its real executable so
        // the supervisor can compare the process identity against a stable path.
        let standalone = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: standalone.path) else {
            throw RuntimeProfileError.pythonExecutableUnavailable
        }
        return standalone
    }
}

public struct ReportVerification: Sendable, Equatable {
    public let name: String
    public let decision: DatabaseDecision
    public let failingGates: [String]
    public let sampleCount: Int
}

public enum ReportVerificationError: Error, Equatable, Sendable, CustomStringConvertible {
    case noReportsFound(URL)
    case reportNotFound(String)
    case incompleteReport(String)
    case secretLeaked

    public var description: String {
        switch self {
        case let .noReportsFound(url):
            "no reports were found in \(url.path)"
        case let .reportNotFound(name):
            "no report named '\(name)'"
        case let .incompleteReport(reason):
            "report is incomplete: \(reason)"
        case .secretLeaked:
            "report contains a profile secret and must not be published"
        }
    }
}

public struct FixtureVerification: Sendable, Equatable {
    public let seed: UInt64
    public let requestedRooms: Int
    public let createdRooms: Int
    public let reconciledRooms: Int
    public let missingRooms: [String]

    public var reconciledExactly: Bool {
        missingRooms.isEmpty && createdRooms == requestedRooms && reconciledRooms == requestedRooms
    }
}

struct JoinedRoomsResponse: Decodable {
    let joinedRooms: [String]

    private enum CodingKeys: String, CodingKey {
        case joinedRooms = "joined_rooms"
    }
}

/// Everything a command needs to talk to the running Synapse it was handed.
public struct RuntimeContext: Sendable {
    public let baseURL: URL
    public let serverName: String
    public let registrationSecret: String
    public let port: UInt16
    public let paths: RuntimePaths

    public init(
        baseURL: URL,
        serverName: String,
        registrationSecret: String,
        port: UInt16,
        paths: RuntimePaths
    ) {
        self.baseURL = baseURL
        self.serverName = serverName
        self.registrationSecret = registrationSecret
        self.port = port
        self.paths = paths
    }
}

/// Resolves when the process receives an interactive interrupt or a termination request.
public final class InterruptMonitor: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    private var parentWatchdog: DispatchSourceTimer?

    /// - Parameter exitWhenParentExits: also stop when the process that launched this one goes
    ///   away. The app runs the runtime as a child, and a signal-only shutdown leaves the whole
    ///   runtime alive and holding the profile lock whenever the app dies without getting to send
    ///   one — a crash, a force quit, `kill -9`. Noticing the parent is gone is the only shutdown
    ///   path that survives those, because SIGKILL cannot be caught by the thing being killed.
    public init(signals: [Int32] = [SIGINT, SIGTERM], exitWhenParentExits: Bool = false) {
        for number in signals { Darwin.signal(number, SIG_IGN) }
        sources = signals.map { number in
            DispatchSource.makeSignalSource(signal: number, queue: .global())
        }
        for source in sources {
            source.setEventHandler { [weak self] in self?.fire() }
            source.resume()
        }
        if exitWhenParentExits { watchParentProcess() }
    }

    /// Fires once this process is reparented, which is what being orphaned looks like.
    ///
    /// Polled rather than observed: `kqueue`'s `NOTE_EXIT` watches a child, and there is no
    /// equivalent for watching a parent. A second of latency on shutdown costs nothing.
    private func watchParentProcess() {
        let original = getppid()
        // Already orphaned before the watch even started — launched from something already gone.
        guard original > 1 else { fire(); return }

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard getppid() != original else { return }
            self?.fire()
        }
        timer.resume()
        parentWatchdog = timer
    }

    deinit {
        for source in sources { source.cancel() }
        parentWatchdog?.cancel()
    }

    public func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeImmediately: Bool = lock.withLock {
                    if fired { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            fire()
        }
    }

    private func fire() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !fired else { return nil }
            fired = true
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume()
    }
}

public enum RuntimeProfileError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingRuntimeManifest(URL)
    case profileNotPrepared(URL)
    case portAllocationFailed
    case pythonExecutableUnavailable
    case keyGenerationFailed(status: Int32, output: String)
    case runtimeOwnedByForegroundSession(processIdentifier: Int32)
    case profileLockedByAnotherSession

    public var description: String {
        switch self {
        case let .missingRuntimeManifest(url):
            "no runtime manifest at \(url.path); run from the package root or set INBOXPLUS_RUNTIME_PACKAGE_ROOT"
        case let .profileNotPrepared(url):
            "profile at \(url.path) is not prepared; run 'bootstrap' first"
        case .portAllocationFailed:
            "could not allocate a loopback port"
        case .pythonExecutableUnavailable:
            "could not resolve a stable Python application executable for the prepared runtime"
        case let .keyGenerationFailed(status, output):
            "Synapse key generation failed with status \(status): \(output)"
        case let .runtimeOwnedByForegroundSession(processIdentifier):
            """
            the runtime is live as process \(processIdentifier) and belongs to the session that \
            started it; interrupt that 'start' session to stop it
            """
        case .profileLockedByAnotherSession:
            "another Inbox+ runtime session already holds this profile; interrupt it first"
        }
    }
}
