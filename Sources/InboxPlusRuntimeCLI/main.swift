import Foundation
import InboxPlusBridge
import InboxPlusBridgeService
import InboxPlusCore
import InboxPlusRuntime

func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func describe(_ snapshot: RuntimeSnapshot) -> String {
    var fields = ["phase=\(snapshot.phase.rawValue)"]
    if let port = snapshot.loopbackPort { fields.append("port=\(port)") }
    if let identity = snapshot.processIdentity { fields.append("pid=\(identity.processIdentifier)") }
    fields.append("restarts=\(snapshot.restartCount)")
    if snapshot.processIdentity != nil, let health = snapshot.lastHealthResult {
        fields.append("health=\(health)")
    }
    if let error = snapshot.lastError { fields.append("error=\(error)") }
    return fields.joined(separator: " ")
}

func makeService(profile: String) throws -> RuntimeProfileService {
    let root = try RuntimeProfileService.developerRuntimeRoot()
    let paths = try RuntimePaths(root: root, profileName: profile)
    return RuntimeProfileService(paths: paths, packageRoot: RuntimeProfileService.resolvedPackageRoot())
}

func execute(_ command: RuntimeCommand) async throws -> String {
    // Describes what Inbox+ ships rather than what a profile contains, so it runs before any
    // profile is resolved and never takes the lock.
    if case let .sbom(output) = command {
        return try emitSBOM(output: output)
    }
    guard let profileName = command.profile else {
        throw RuntimeCommandError.missingOption("--profile")
    }
    let service = try makeService(profile: profileName)
    // `status` only observes, so it must never contend with the session that owns the profile.
    let lock: ProfileLock?
    do {
        lock = try command.observesOnly ? nil : service.acquireProfileLock()
    } catch ProfileLockError.alreadyLocked {
        throw RuntimeProfileError.profileLockedByAnotherSession
    }
    defer { _ = lock }

    switch command {
    case .sbom:
        // Handled above, before any profile is resolved.
        throw RuntimeCommandError.missingCommand
    case let .diagnostics(_, output):
        let state = try RuntimeProfileStore(paths: service.paths).load()
        // Everything Inbox+ knows to be secret is removed by value as well as by pattern.
        let known = [state?.registrationSecret].compactMap { $0 }
        let bundle = DiagnosticsBundle(
            paths: service.paths,
            redactor: DiagnosticsRedactor(knownSecrets: known)
        )
        let manifest = try bundle.write(
            to: URL(fileURLWithPath: output),
            inboxplusVersion: InboxPlusVersion.current
        )
        var summary = "wrote \(manifest.entries.count) redacted file(s) to \(output)"
        if !manifest.excluded.isEmpty {
            summary += "\nexcluded \(manifest.excluded.count): " + manifest.excluded.joined(separator: "; ")
        }
        return summary
    case let .bridge(_, action, network):
        return try await executeBridge(action: action, network: network, service: service)
    case let .bootstrap(_, python):
        let receipt = try await service.bootstrap(python: URL(fileURLWithPath: python))
        return """
        prepared profile '\(profileName)' \
        python=\(receipt.pythonVersion) synapse=\(receipt.synapseVersion) \
        packages=\(receipt.installedPackages.count)
        """
    case let .start(_, exitWithParent):
        let monitor = InterruptMonitor(exitWhenParentExits: exitWithParent)
        let runtime = BridgeRuntime(paths: service.paths)
        try await service.withRunningRuntime(
            onReady: { snapshot in
                print(describe(snapshot))
                // The session blocks indefinitely, so a redirected stdout must not stay buffered.
                fflush(stdout)
            }
        ) { supervisor, context in
            // Bridges follow the homeserver: it is healthy by the time this runs, and each bridge
            // config has to name the port it actually got.
            try runtime.rebindToHomeserver(port: context.port)
            try await runtime.withRunningBridges(
                onBridgeReady: { record, snapshot in
                    print("bridge \(record.bridgeID) \(describe(snapshot))")
                    fflush(stdout)
                },
                // One bridge failing is reported and stepped over: taking the homeserver and every
                // other network down with it would be a worse outcome than a single dark network.
                onBridgeFailed: { record, error in
                    writeStandardError("bridge \(record.bridgeID) failed to start: \(error)")
                }
            ) { _ in
                print("supervising; press Ctrl-C to stop")
                fflush(stdout)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await supervisor.supervise() }
                    group.addTask { await monitor.wait() }
                    await group.next()
                    group.cancelAll()
                    await group.waitForAll()
                }
            }
        }
        return describe(try await service.status())
    case .status:
        return describe(try await service.status())
    case .stop:
        return describe(try await service.stop())
    case let .verify(_, options):
        if options.simulateDataLoss {
            guard let backup = options.restoreBackup else {
                throw RuntimeCommandError.missingOption("--restore")
            }
            let recovery = try await service.verifyRecovery(
                name: backup,
                seed: BenchmarkCLIOptions.defaultSeed
            )
            guard recovery.succeeded else {
                throw VerificationFailed(
                    summary: """
                    recovery failed: integrity=\(recovery.integrity) \
                    rooms=\(recovery.roomCount) events=\(recovery.eventCount) \
                    acceptedNewWrite=\(recovery.acceptedNewWrite)
                    """
                )
            }
            return """
            recovered '\(profileName)' from '\(backup)' \
            integrity=\(recovery.integrity) rooms=\(recovery.roomCount) \
            events=\(recovery.eventCount) accepted-new-write=\(recovery.acceptedNewWrite)
            """
        }
        if let reportName = options.reportName {
            let verification = try service.verifyReport(named: reportName)
            let decision = verification.decision == .retainSQLiteProvisionally
                ? "Retain SQLite provisionally"
                : "Require PostgreSQL"
            var summary = """
            verified report '\(verification.name)' \
            samples=\(verification.sampleCount) decision: \(decision)
            """
            for gate in verification.failingGates {
                summary += "\n  - failed gate: \(gate)"
            }
            return summary
        }
        if let rooms = options.fixtureRooms {
            let verification = try await service.verifyFixtures(
                seed: BenchmarkCLIOptions.defaultSeed,
                rooms: rooms
            )
            guard verification.reconciledExactly else {
                throw VerificationFailed(
                    summary: """
                    fixture reconciliation failed: requested=\(verification.requestedRooms) \
                    created=\(verification.createdRooms) \
                    reconciled=\(verification.reconciledRooms) \
                    missing=\(verification.missingRooms.count)
                    """
                )
            }
            return """
            verified profile '\(profileName)' \
            rooms=\(verification.reconciledRooms)/\(verification.requestedRooms) reconciled exactly
            """
        }
        let receipt = try service.verifyPreparedRuntime()
        return """
        verified profile '\(profileName)' \
        python=\(receipt.pythonVersion) synapse=\(receipt.synapseVersion) \
        packages=\(receipt.installedPackages.count) configuration=loopback-only
        """
    case let .benchmark(_, options):
        let report = try await service.runBenchmark(
            BenchmarkWorkload.reduced(
                seed: options.seed,
                rooms: options.rooms,
                messages: options.messages,
                importWorkers: options.importWorkers
            )
        )
        let run = report.run
        let decision = report.verdict.decision == .retainSQLiteProvisionally
            ? "Retain SQLite provisionally"
            : "Require PostgreSQL"
        var summary = """
        benchmark '\(profileName)' rooms=\(run.workload.roomCount) \
        imported=\(run.importedEventCount) live=\(run.liveTrafficEventCount) \
        missing=\(run.reconciliation.missingEventIDs.count) \
        duplicates=\(run.reconciliation.duplicateEventIDs.count) \
        failures=\(run.unrecoverableFailureCount) \
        integrity=\(run.sqliteIntegrity ?? "unverified") \
        elapsed=\(String(format: "%.1f", run.elapsedSeconds))s
        decision: \(decision)
        """
        for reason in report.verdict.failureReasons {
            summary += "\n  - \(reason)"
        }
        return summary
    case let .backup(_, name):
        let manifest = try await service.createBackup(name: name)
        return """
        backed up '\(profileName)' as '\(name)' \
        files=\(manifest.files.count) \
        bytes=\(manifest.files.reduce(0) { $0 + $1.byteCount })
        """
    case let .restore(_, backup):
        let result = try await service.restoreBackup(name: backup, into: service.paths)
        return """
        restored '\(backup)' into '\(profileName)' \
        files=\(result.restoredFileCount) verified=\(result.verifiedChecksums)
        """
    case let .remove(_, confirmation, exportReport):
        let result = try await service.removeProfile(
            confirmation: confirmation,
            exportReportTo: exportReport.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        guard result.removedProfile else {
            return "profile '\(profileName)' was already absent"
        }
        return """
        removed profile '\(profileName)' \
        exported-reports=\(result.exportedReportCount) residue=\(result.residuePaths.count)
        """
    }
}

struct VerificationFailed: Error, CustomStringConvertible {
    let summary: String
    var description: String { summary }
}

struct UnknownNetwork: Error, CustomStringConvertible {
    let name: String
    var description: String {
        let available = BridgeCatalog.all.map { "\($0.platform.rawValue)" }.joined(separator: ", ")
        return "unknown network '\(name)'; Inbox+ can bridge: \(available)"
    }
}

func resolveNetwork(_ name: String) throws -> BridgeDescriptor {
    guard let platform = Platform(rawValue: name),
          let descriptor = BridgeCatalog.descriptor(for: platform)
    else { throw UnknownNetwork(name: name) }
    return descriptor
}

func executeBridge(
    action: BridgeCLIAction,
    network: String?,
    service: RuntimeProfileService
) async throws -> String {
    let runtime = BridgeRuntime(paths: service.paths)

    switch action {
    case .list:
        let prepared = try runtime.prepared()
        guard !prepared.isEmpty else { return "no bridges prepared for '\(service.paths.profile.lastPathComponent)'" }
        return prepared
            .map { "\($0.bridgeID) \($0.version) port=\($0.appservicePort) sha256=\($0.sha256.prefix(12))…" }
            .joined(separator: "\n")

    case .install:
        let descriptor = try resolveNetwork(network!)
        guard descriptor.runtimeKind == .goBinary else {
            return "\(descriptor.displayName) needs no download — it connects through macOS permissions"
        }
        let installer = BridgeInstaller(paths: service.paths)
        let installed = try await installer.install(descriptor)
        let directory = installer.directory(for: descriptor)
        try await LibolmProvisioner().install(into: directory)
        return """
        installed \(descriptor.id) \(descriptor.version) \
        sha256=\(installed.sha256) \
        libolm=\(LibolmProvisioner.version) \
        at \(installed.executable.path)
        """

    case .prepare:
        let descriptor = try resolveNetwork(network!)
        let state = try service.loadState()
        guard let state else {
            throw RuntimeProfileError.missingRuntimeManifest(service.manifestFile)
        }
        // Preparing needs the port the homeserver will use, and the registration must be on disk
        // before Synapse reads `app_service_config_files` at startup, so this runs while stopped.
        let record = try await runtime.prepare(
            descriptor,
            serverName: state.serverName,
            homeserverPort: state.snapshot.loopbackPort ?? 8008,
            ownerUserID: "@inboxplus:\(state.serverName)"
        )
        return """
        prepared \(record.bridgeID) \(record.version) \
        provisioning=127.0.0.1:\(record.appservicePort) \
        registration=\(record.registrationFile)
        start the profile to load it: InboxPlusRuntimeCLI start --profile \
        \(service.paths.profile.lastPathComponent)
        """

    case .flows:
        let descriptor = try resolveNetwork(network!)
        guard let record = try runtime.prepared(for: descriptor.platform) else {
            throw BridgeRuntimeError.notPrepared(descriptor.id)
        }
        return try await service.withRunningRuntime { _, context in
            try runtime.rebindToHomeserver(port: context.port)
            let supervisor = try runtime.makeSupervisor(for: record)
            let snapshot = try await supervisor.start()
            var lines = ["bridge \(record.bridgeID) \(describe(snapshot))"]

            let client = try runtime.provisioningClient(for: record)
            let flows = try await client.loginFlows()
            for flow in flows {
                lines.append("  flow \(flow.id): \(flow.name) — \(flow.description)")
            }
            do {
                try runtime.detectFlowDrift(descriptor, advertised: flows)
                lines.append("  flows match the pinned expectation")
            } catch {
                lines.append("  WARNING: \(error)")
            }
            _ = try? await supervisor.stop()
            return lines.joined(separator: "\n")
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    let command = try RuntimeCommand.parse(arguments)
    let summary = try await execute(command)
    print(summary)
    exit(RuntimeExitCode.success.rawValue)
} catch let error as RuntimeCommandError {
    writeStandardError("error: \(error.diagnostic)")
    writeStandardError(RuntimeCommand.usage)
    exit(RuntimeExitCode.usage.rawValue)
} catch {
    writeStandardError("error: \(error)")
    exit(RuntimeExitCode(for: error).rawValue)
}

/// Writes the bill of materials, or prints it when no destination is given.
///
/// The timestamp and serial are derived from the content rather than the clock, so the same pins
/// always produce the same document and two releases can be diffed.
func emitSBOM(output: String?) throws -> String {
    let bill = InboxPlusSBOM.bill(applicationVersion: InboxPlusVersion.current)
    let fingerprint = try bill.contentFingerprint()
    let data = try bill.cycloneDXJSON(
        timestamp: Date(timeIntervalSince1970: 0),
        serialNumber: fingerprint.uuidString
    )
    guard let output else {
        return String(decoding: data, as: UTF8.self)
    }
    let url = URL(fileURLWithPath: output)
    try data.write(to: url, options: [.atomic])
    let unscannable = bill.unscannableComponents.map(\.name)
    var summary = "wrote \(bill.components.count) components to \(url.path)"
    if !unscannable.isEmpty {
        summary += "\n\(unscannable.count) component(s) have no package URL and cannot be "
            + "matched against an advisory database: \(unscannable.joined(separator: ", "))"
    }
    return summary
}
