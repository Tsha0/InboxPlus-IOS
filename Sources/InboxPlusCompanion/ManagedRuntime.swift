import Foundation
import InboxPlusRuntime

/// Starts and stops the local runtime the app needs, so opening Inbox+ is enough.
///
/// The homeserver and every bridge are separate processes. Until now the app expected someone to
/// have run `InboxPlusRuntimeCLI start` in a shell first, which is a reasonable thing to ask of a
/// developer and an unreasonable thing to ask of anyone opening an application.
///
/// This launches that same CLI as a child rather than supervising Synapse directly. Phase 2 settled
/// on one foreground session owning a profile — it holds the exclusive lock, verifies process
/// identity and restarts children with bounded backoff — and re-implementing that inside the app
/// would mean two owners of the same profile with two ideas about who is in charge.
actor ManagedRuntime {
    static let shared = ManagedRuntime()

    enum StartFailure: Error, CustomStringConvertible {
        case commandMissing(String)
        case exitedDuringStartup(status: Int32, output: String)
        case timedOut(seconds: Int, lastPhase: String)

        var description: String {
            switch self {
            case let .commandMissing(path):
                "the runtime command is missing at \(path)"
            case let .exitedDuringStartup(status, output):
                "the runtime stopped while starting (exit \(status)). \(output)"
            case let .timedOut(seconds, phase):
                "the runtime did not become ready within \(seconds)s (last phase: \(phase))"
            }
        }
    }

    private var preparation: Task<Void, Error>?

    private nonisolated let stoppable = StoppableChild()

    private var child: Process? {
        get { stoppable.value }
        set { stoppable.value = newValue }
    }
    /// Only a runtime this app started may be stopped by it. A developer's own
    /// `InboxPlusRuntimeCLI start` in a terminal is not ours to kill.
    private var startedByThisApp: Bool {
        get { stoppable.startedByThisApp }
        set { stoppable.startedByThisApp = newValue }
    }

    /// Readable from outside the actor so quitting does not have to await anything.
    private nonisolated func stoppableChild() -> Process? {
        guard stoppable.startedByThisApp, let process = stoppable.value, process.isRunning else {
            return nil
        }
        return process
    }

    /// Ensures the profile is running and returns the state once it is serving.
    ///
    /// Idempotent: an already-running profile is attached to rather than restarted, which is what
    /// makes launching the app safe while a shell session owns the runtime.
    func ensureRunning(
        paths: RuntimePaths,
        profileName: String,
        timeout: Duration = .seconds(240),
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> RuntimeProfileState {
        if let state = try? await servingState(paths: paths) {
            progress("attached to the runtime already serving '\(profileName)'")
            return state
        }

        if try RuntimeProfileStore(paths: paths).load() == nil {
            progress("preparing your inbox…")
            if preparation == nil {
                preparation = Task.detached {
                    let service = RuntimeProfileService(
                        paths: paths, packageRoot: RuntimeProfileService.resolvedPackageRoot()
                    )
                    let lock = try service.acquireProfileLock()
                    defer { withExtendedLifetime(lock) {} }
                    // Another caller may have completed setup before the lock was acquired.
                    if try service.loadState() == nil { _ = try service.bootstrapBundled() }
                }
            }
            do { try await preparation?.value; preparation = nil }
            catch { preparation = nil; throw error }
        }

        // Read before launching: the file still holds the *previous* session's phase, and
        // announcing it makes a cold start report "runtime stopped…" a moment after saying it is
        // starting one.
        let phaseBeforeLaunch = (try? RuntimeProfileStore(paths: paths).load())??.snapshot.phase.rawValue
        if child == nil {
            // A runtime that was killed rather than stopped leaves the profile recorded as healthy.
            // `start` then refuses with an invalid transition, so a force quit would make the app
            // unable to launch its own runtime until something else reconciled the state. Asking
            // the CLI to stop a profile nothing is serving is what does that reconciliation, and it
            // is a no-op when the state is already clean.
            if phaseBeforeLaunch != nil, phaseBeforeLaunch != "stopped" {
                progress("clearing state left by a runtime that did not shut down")
                reconcileStaleState(profileName: profileName)
            }
            try launch(profileName: profileName, progress: progress)
        }
        return try await waitUntilServing(
            paths: paths,
            profileName: profileName,
            timeout: timeout,
            stalePhase: phaseBeforeLaunch,
            progress: progress
        )
    }

    /// Asks the runtime to stop, without waiting for it.
    ///
    /// Quit has to be prompt. The child stops the bridges and the homeserver in order on SIGINT,
    /// and it exits on its own if this process dies before that finishes, so there is nothing to
    /// gain by holding up the app to watch.
    nonisolated func requestStop() {
        guard let process = stoppableChild() else { return }
        kill(process.processIdentifier, SIGINT)
    }

    /// Stops the runtime, but only the one this app started.
    func stop() async {
        guard startedByThisApp, let process = child, process.isRunning else {
            child = nil
            return
        }
        // SIGINT is what the CLI's own interrupt handling expects; it stops the bridges and the
        // homeserver in order and verifies the listener is gone. SIGKILL would leave a lock file
        // and orphaned children behind.
        kill(process.processIdentifier, SIGINT)

        let deadline = ContinuousClock().now.advanced(by: .seconds(45))
        while process.isRunning, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if process.isRunning {
            // A runtime that will not stop gracefully still must not outlive the app that owns it.
            process.terminate()
        }
        child = nil
        startedByThisApp = false
    }

    // MARK: - Launching

    private func launch(profileName: String, progress: @Sendable (String) -> Void) throws {
        let command = Self.runtimeCommandURL()
        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            throw StartFailure.commandMissing(command.path)
        }

        let process = Process()
        process.executableURL = command
        // The child also watches for this process disappearing. The clean quit path below is the
        // normal way it stops; this is what covers a crash or a force quit, where nothing gets the
        // chance to send a signal at all.
        process.arguments = ["start", "--profile", profileName, "--exit-with-parent"]
        // The child writes one line per supervised process. Forwarding it keeps the app's own log
        // the single place to look when a bridge fails to come up.
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardError.write(Data("runtime: ".utf8) + data)
        }

        progress("starting the local runtime for '\(profileName)'")
        try process.run()
        child = process
        startedByThisApp = true
    }

    /// Runs `stop` so a profile recorded as running but serving nothing becomes stopped again.
    ///
    /// Best effort by design: if a runtime really is alive, `stop` refuses and says so, and the
    /// launch that follows fails with its own clear message rather than this one guessing.
    private func reconcileStaleState(profileName: String) {
        let process = Process()
        process.executableURL = Self.runtimeCommandURL()
        process.arguments = ["stop", "--profile", profileName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func waitUntilServing(
        paths: RuntimePaths,
        profileName: String,
        timeout: Duration,
        stalePhase: String?,
        progress: @Sendable (String) -> Void
    ) async throws -> RuntimeProfileState {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        var lastPhase = "unknown"
        var announced: Set<String> = stalePhase.map { [$0] } ?? []

        while ContinuousClock().now < deadline {
            if let process = child, !process.isRunning {
                let status = process.terminationStatus
                child = nil
                startedByThisApp = false
                throw StartFailure.exitedDuringStartup(
                    status: status,
                    output: "See the runtime lines above for the reason."
                )
            }

            if let state = try? await servingState(paths: paths) {
                progress("runtime ready for '\(profileName)'")
                return state
            }

            // Synapse plus nine bridges takes tens of seconds from cold. Reporting the phase as it
            // changes is what keeps that from looking like a hang.
            if let phase = (try? RuntimeProfileStore(paths: paths).load())??.snapshot.phase.rawValue {
                lastPhase = phase
                if announced.insert(phase).inserted { progress("runtime \(phase)…") }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw StartFailure.timedOut(seconds: Int(timeout.components.seconds), lastPhase: lastPhase)
    }

    // MARK: - Readiness

    /// The profile's state, but only once the homeserver actually answers.
    ///
    /// A recorded port is not proof of a running server: a crash or a hard shutdown leaves the last
    /// state behind, and trusting it means building a client against a port nothing is listening
    /// on. The probe is what distinguishes a live runtime from a stale record of one.
    private func servingState(paths: RuntimePaths) async throws -> RuntimeProfileState {
        guard let state = try RuntimeProfileStore(paths: paths).load(),
              let port = state.snapshot.loopbackPort else {
            throw StartFailure.timedOut(seconds: 0, lastPhase: "no recorded port")
        }
        guard await Self.homeserverAnswers(port: port) else {
            throw StartFailure.timedOut(seconds: 0, lastPhase: "port \(port) not answering")
        }
        return state
    }

    static func homeserverAnswers(port: UInt16) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/_matrix/client/versions")!)
        request.timeoutInterval = 2
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        // Any answer proves something is listening and speaking Matrix; the status itself does not
        // matter, because an unauthenticated probe is allowed to be refused.
        return http.statusCode > 0
    }

    /// The CLI ships beside the app's own executable — inside the bundle for an installed Inbox+,
    /// and in the build directory for `swift run` — so one lookup covers both.
    static func runtimeCommandURL() -> URL {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("InboxPlusRuntimeCLI")
    }
}


/// Shared, lock-guarded handle on the child.
///
/// The actor owns the lifecycle, but quitting reads it from the main thread without awaiting: an
/// `await` there means the app is already tearing down before the runtime is told to stop.
final class StoppableChild: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var started = false

    var value: Process? {
        get { lock.withLock { process } }
        set { lock.withLock { process = newValue } }
    }

    var startedByThisApp: Bool {
        get { lock.withLock { started } }
        set { lock.withLock { started = newValue } }
    }
}
