import Darwin
import Foundation

@_silgen_name("posix_spawn_file_actions_addchdir_np")
private func inboxplus_spawn_file_actions_addchdir(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    _ path: UnsafePointer<CChar>
) -> Int32

typealias ManagedProcessIdentityReader = @Sendable (pid_t) -> ManagedProcessIdentity?
typealias ManagedProcessSignalSender = @Sendable (pid_t, Int32) -> Int32
typealias ManagedProcessPIDHook = @Sendable (pid_t) -> Void
typealias ManagedLogWriteHook = @Sendable (Data) throws -> Void

public struct FoundationManagedProcessFactory: ManagedProcessFactory {
    private let identityReader: ManagedProcessIdentityReader
    private let signalSender: ManagedProcessSignalSender
    private let afterSpawn: ManagedProcessPIDHook
    private let afterIdentityBeforeSignal: ManagedProcessPIDHook
    private let logWriteHook: ManagedLogWriteHook

    public init() {
        self.init(
            identityReader: FoundationManagedProcess.readIdentity,
            signalSender: { pid, signal in Darwin.kill(pid, signal) },
            afterSpawn: { _ in },
            afterIdentityBeforeSignal: { _ in },
            logWriteHook: { _ in }
        )
    }

    init(
        identityReader: @escaping ManagedProcessIdentityReader = FoundationManagedProcess.readIdentity,
        signalSender: @escaping ManagedProcessSignalSender = { pid, signal in Darwin.kill(pid, signal) },
        afterSpawn: @escaping ManagedProcessPIDHook = { _ in },
        afterIdentityBeforeSignal: @escaping ManagedProcessPIDHook = { _ in },
        logWriteHook: @escaping ManagedLogWriteHook = { _ in }
    ) {
        self.identityReader = identityReader
        self.signalSender = signalSender
        self.afterSpawn = afterSpawn
        self.afterIdentityBeforeSignal = afterIdentityBeforeSignal
        self.logWriteHook = logWriteHook
    }

    public func make(_ configuration: ManagedProcessConfiguration) throws -> any ManagedProcess {
        try FoundationManagedProcess(
            configuration: configuration,
            observedIdentity: nil,
            identityReader: identityReader,
            signalSender: signalSender,
            afterSpawn: afterSpawn,
            afterIdentityBeforeSignal: afterIdentityBeforeSignal,
            logWriteHook: logWriteHook
        )
    }

    public func rehydrate(
        _ configuration: ManagedProcessConfiguration,
        expectedIdentity: ManagedProcessIdentity
    ) throws -> any ManagedProcess {
        try FoundationManagedProcess(
            configuration: configuration,
            observedIdentity: expectedIdentity,
            identityReader: identityReader,
            signalSender: signalSender,
            afterSpawn: afterSpawn,
            afterIdentityBeforeSignal: afterIdentityBeforeSignal,
            logWriteHook: logWriteHook
        )
    }
}

public final class FoundationManagedProcess: ManagedProcess, @unchecked Sendable {
    private enum LaunchState {
        case idle
        case launching
        case launched
    }

    private let configuration: ManagedProcessConfiguration
    private let identityReader: ManagedProcessIdentityReader
    private let signalSender: ManagedProcessSignalSender
    private let afterSpawn: ManagedProcessPIDHook
    private let afterIdentityBeforeSignal: ManagedProcessPIDHook
    private let observerOnly: Bool
    private let stateLock = NSLock()
    private var ownedPID: pid_t?
    private var launchedIdentity: ManagedProcessIdentity?
    private var observedIdentity: ManagedProcessIdentity?
    private var collector: ManagedOutputCollector?
    private var terminalLogFailure: ManagedProcessError?
    private var launchState: LaunchState = .idle
    private let secureLogDirectory: SecureLogDirectory?
    private let standardOutput: BoundedRotatingLog?
    private let standardError: BoundedRotatingLog?

    init(
        configuration: ManagedProcessConfiguration,
        observedIdentity: ManagedProcessIdentity?,
        identityReader: @escaping ManagedProcessIdentityReader,
        signalSender: @escaping ManagedProcessSignalSender,
        afterSpawn: @escaping ManagedProcessPIDHook,
        afterIdentityBeforeSignal: @escaping ManagedProcessPIDHook,
        logWriteHook: @escaping ManagedLogWriteHook
    ) throws {
        guard configuration.executable.isFileURL,
              Darwin.access(configuration.executable.path, X_OK) == 0
        else {
            throw ManagedProcessError.invalidConfiguration("executable is not an executable file URL")
        }
        var workingDirectoryMetadata = stat()
        guard configuration.workingDirectory.isFileURL,
              Darwin.lstat(configuration.workingDirectory.path, &workingDirectoryMetadata) == 0,
              (workingDirectoryMetadata.st_mode & S_IFMT) == S_IFDIR
        else {
            throw ManagedProcessError.invalidConfiguration("working directory is not a non-symlink directory")
        }
        guard configuration.standardOutputLog != configuration.standardErrorLog,
              configuration.maximumLogBytesPerFile > 0,
              configuration.retainedLogFileCount > 0
        else {
            throw ManagedProcessError.invalidConfiguration("invalid log configuration")
        }

        self.configuration = configuration
        self.identityReader = identityReader
        self.signalSender = signalSender
        self.afterSpawn = afterSpawn
        self.afterIdentityBeforeSignal = afterIdentityBeforeSignal
        self.observedIdentity = observedIdentity
        observerOnly = observedIdentity != nil

        if observedIdentity == nil {
            let secureDirectory = try SecureLogDirectory(
                profileRoot: configuration.profileRoot,
                logsDirectory: configuration.logsDirectory
            )
            secureLogDirectory = secureDirectory
            standardOutput = try BoundedRotatingLog(
                directory: secureDirectory,
                fileName: try Self.validatedLogName(
                    configuration.standardOutputLog,
                    directory: configuration.logsDirectory
                ),
                maximumBytesPerFile: configuration.maximumLogBytesPerFile,
                retainedFileCount: configuration.retainedLogFileCount,
                redactedValues: configuration.redactedLogValues,
                writeHook: logWriteHook
            )
            standardError = try BoundedRotatingLog(
                directory: secureDirectory,
                fileName: try Self.validatedLogName(
                    configuration.standardErrorLog,
                    directory: configuration.logsDirectory
                ),
                maximumBytesPerFile: configuration.maximumLogBytesPerFile,
                retainedFileCount: configuration.retainedLogFileCount,
                redactedValues: configuration.redactedLogValues,
                writeHook: logWriteHook
            )
        } else {
            secureLogDirectory = nil
            standardOutput = nil
            standardError = nil
        }
    }

    deinit {
        terminateAndReapOwnedChild()
    }

    public func launch() async throws -> ManagedProcessIdentity {
        guard !observerOnly else {
            throw ManagedProcessError.invalidConfiguration("an observed process cannot be launched")
        }
        try Task.checkCancellation()
        try stateLock.withLock {
            guard launchState == .idle, ownedPID == nil else {
                throw ManagedProcessError.alreadyLaunched
            }
            launchState = .launching
        }

        do {
            let pid = try spawnChild()
            afterSpawn(pid)

            var previousIdentity: ManagedProcessIdentity?
            for _ in 0..<40 {
                try Task.checkCancellation()
                if let failure = currentLogFailure() { throw failure }
                if let identity = identityReader(pid) {
                    if identity == previousIdentity {
                        stateLock.withLock {
                            launchedIdentity = identity
                            launchState = .launched
                        }
                        return identity
                    }
                    previousIdentity = identity
                }
                if try childHasExited(pid) {
                    // The child launched and then exited before a second identical read. The
                    // identity already observed while it was alive is still the truth about the
                    // process that ran, and this object is its sole reaper, so the PID cannot have
                    // been reused. Discarding it would fail a launch that actually succeeded —
                    // which is what made every short-lived child racy.
                    if let previousIdentity {
                        stateLock.withLock {
                            launchedIdentity = previousIdentity
                            launchState = .launched
                        }
                        return previousIdentity
                    }
                    break
                }
                _ = await Task.detached(priority: .utility) { usleep(5_000) }.value
            }

            throw ManagedProcessError.launchIdentityUnavailable(pid)
        } catch {
            terminateAndReapOwnedChild()
            stateLock.withLock {
                if ownedPID == nil { launchState = .idle }
            }
            throw error
        }
    }

    public func identityStatus(for expected: ManagedProcessIdentity) async -> ManagedProcessIdentityStatus {
        stateLock.withLock {
            if launchedIdentity == expected, ownedPID == nil { return .exited }
            if let ownedPID, ownedPID == expected.processIdentifier {
                do {
                    if try childHasExited(ownedPID) { return .exited }
                } catch let failure as ManagedProcessError {
                    return .indeterminate(failure)
                } catch {
                    return .indeterminate(.childWaitFailed(code: EIO))
                }
            }
            guard let actual = identityReader(expected.processIdentifier) else {
                if ownedPID == expected.processIdentifier {
                    return .indeterminate(.processIdentityUnavailable(expected.processIdentifier))
                }
                return .exited
            }
            return actual == expected ? .matching : .mismatched(actual: actual)
        }
    }

    public func ownership(for expected: ManagedProcessIdentity) async -> ManagedProcessOwnership {
        stateLock.withLock {
            if ownedPID == expected.processIdentifier, launchedIdentity == expected {
                return .directChild
            }
            return .observedOnly
        }
    }

    @discardableResult
    public func signal(
        _ signal: ManagedProcessSignal,
        ifMatching expected: ManagedProcessIdentity
    ) async throws -> Bool {
        var completedCollector: ManagedOutputCollector?
        let result: Bool = try stateLock.withLock {
            guard ownedPID == expected.processIdentifier else {
                throw ManagedProcessError.processNotOwned(expected)
            }
            guard launchedIdentity == expected else {
                if let actual = identityReader(expected.processIdentifier) {
                    throw RuntimeStateError.processIdentityMismatch(expected: expected, actual: actual)
                }
                return false
            }
            if try childHasExited(expected.processIdentifier) {
                try reapOwnedChild(expected.processIdentifier)
                completedCollector = collector
                collector = nil
                return false
            }
            guard let actual = identityReader(expected.processIdentifier) else {
                throw ManagedProcessError.processIdentityUnavailable(expected.processIdentifier)
            }
            guard actual == expected else {
                throw RuntimeStateError.processIdentityMismatch(expected: expected, actual: actual)
            }

            // This seam intentionally occurs after identity verification. Because this object is
            // the sole reaper for its direct child, exit here leaves an unreaped zombie and the
            // kernel cannot reuse the PID before the signal syscall below.
            afterIdentityBeforeSignal(expected.processIdentifier)
            let systemSignal = signal == .terminate ? SIGTERM : SIGKILL
            let signalResult = signalSender(expected.processIdentifier, systemSignal)
            if signalResult == 0 { return true }
            if errno == ESRCH { return false }
            throw ManagedProcessError.signalFailed(signal: signal, code: errno)
        }
        try finishCollector(completedCollector)
        return result
    }

    public func waitForExit(
        matching expected: ManagedProcessIdentity,
        timeout: Duration
    ) async throws -> Bool {
        guard await ownership(for: expected) == .directChild else {
            throw ManagedProcessError.processNotOwned(expected)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if let failure = currentLogFailure() {
                terminateAndReapOwnedChild()
                throw failure
            }
            var completedCollector: ManagedOutputCollector?
            let exited = try stateLock.withLock {
                guard ownedPID == expected.processIdentifier else { return true }
                guard try childHasExited(expected.processIdentifier) else { return false }
                try reapOwnedChild(expected.processIdentifier)
                completedCollector = collector
                collector = nil
                return true
            }
            if exited {
                try finishCollector(completedCollector)
                return true
            }
            if clock.now >= deadline { return false }
            _ = await Task.detached(priority: .utility) { usleep(25_000) }.value
        } while true
    }

    public func lifecycleFailure() -> ManagedProcessError? {
        currentLogFailure()
    }

    private func spawnChild() throws -> pid_t {
        guard let standardOutput, let standardError else {
            throw ManagedProcessError.invalidConfiguration("missing owned-process logs")
        }
        var outputPipe = try Self.makePipe()
        var errorPipe: (read: Int32, write: Int32)
        do {
            errorPipe = try Self.makePipe()
        } catch {
            Self.closePipe(&outputPipe)
            throw error
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else {
            Self.closePipe(&outputPipe)
            Self.closePipe(&errorPipe)
            throw ManagedProcessError.spawnFailed(code: actionsResult)
        }
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            Self.closePipe(&outputPipe)
            Self.closePipe(&errorPipe)
            throw ManagedProcessError.spawnFailed(code: attributesResult)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let actionResults = [
            posix_spawn_file_actions_adddup2(&actions, outputPipe.write, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, errorPipe.write, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, outputPipe.read),
            posix_spawn_file_actions_addclose(&actions, errorPipe.read),
            posix_spawn_file_actions_addclose(&actions, outputPipe.write),
            posix_spawn_file_actions_addclose(&actions, errorPipe.write),
            configuration.workingDirectory.path.withCString {
                inboxplus_spawn_file_actions_addchdir(&actions, $0)
            },
        ]
        var defaultSignals = sigset_t()
        var emptySignalMask = sigset_t()
        sigemptyset(&defaultSignals)
        sigemptyset(&emptySignalMask)
        for signal in [SIGTERM, SIGINT, SIGQUIT, SIGHUP, SIGPIPE] {
            sigaddset(&defaultSignals, signal)
        }
        let spawnFlags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        guard actionResults.allSatisfy({ $0 == 0 }),
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &emptySignalMask) == 0,
              posix_spawnattr_setflags(&attributes, Int16(spawnFlags)) == 0
        else {
            Self.closePipe(&outputPipe)
            Self.closePipe(&errorPipe)
            throw ManagedProcessError.spawnFailed(code: actionResults.first(where: { $0 != 0 }) ?? errno)
        }

        var pid: pid_t = 0
        let arguments = [configuration.executable.path] + configuration.arguments
        let environment = configuration.environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
        let spawnResult = Self.withMutableCStringArray(arguments) { argv in
            Self.withMutableCStringArray(environment) { environmentPointer in
                posix_spawn(
                    &pid,
                    configuration.executable.path,
                    &actions,
                    &attributes,
                    argv,
                    environmentPointer
                )
            }
        }
        _ = Darwin.close(outputPipe.write)
        outputPipe.write = -1
        _ = Darwin.close(errorPipe.write)
        errorPipe.write = -1
        guard spawnResult == 0 else {
            Self.closePipe(&outputPipe)
            Self.closePipe(&errorPipe)
            throw ManagedProcessError.spawnFailed(code: spawnResult)
        }

        let outputCollector = ManagedOutputCollector(
            standardOutputDescriptor: outputPipe.read,
            standardErrorDescriptor: errorPipe.read,
            standardOutput: standardOutput,
            standardError: standardError
        )
        outputPipe.read = -1
        errorPipe.read = -1
        stateLock.withLock {
            ownedPID = pid
            collector = outputCollector
        }
        return pid
    }

    private func terminateAndReapOwnedChild() {
        var completedCollector: ManagedOutputCollector?
        stateLock.withLock {
            guard let pid = ownedPID else {
                completedCollector = collector
                collector = nil
                return
            }
            do {
                if try !childHasExited(pid) {
                    let signalResult = signalSender(pid, SIGKILL)
                    guard signalResult == 0 || errno == ESRCH else {
                        if terminalLogFailure == nil {
                            terminalLogFailure = .signalFailed(signal: .kill, code: errno)
                        }
                        return
                    }
                }
                try reapOwnedChild(pid)
            } catch let failure as ManagedProcessError {
                // Probe failure means the direct-child/PID reservation cannot be proven. Never
                // signal by PID in that state; retain an actionable failure instead.
                if terminalLogFailure == nil { terminalLogFailure = failure }
                if failure == .childWaitFailed(code: ECHILD) { ownedPID = nil }
            } catch {
                if terminalLogFailure == nil {
                    terminalLogFailure = .childWaitFailed(code: EIO)
                }
            }
            completedCollector = collector
            collector = nil
        }
        do {
            try finishCollector(completedCollector)
        } catch let failure as ManagedProcessError {
            stateLock.withLock { terminalLogFailure = failure }
        } catch {}
    }

    private func reapOwnedChild(_ pid: pid_t) throws {
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(pid, &status, 0)
            if result == pid {
                ownedPID = nil
                observedIdentity = nil
                return
            }
            if result == -1, errno == EINTR { continue }
            if result == -1, errno == ECHILD {
                ownedPID = nil
                throw ManagedProcessError.childWaitFailed(code: ECHILD)
            }
            throw ManagedProcessError.childWaitFailed(code: errno)
        }
    }

    private func childHasExited(_ pid: pid_t) throws -> Bool {
        var information = siginfo_t()
        while true {
            let result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
            if result == 0 { return information.si_pid == pid }
            if errno == EINTR { continue }
            if errno == ECHILD { throw ManagedProcessError.childWaitFailed(code: ECHILD) }
            throw ManagedProcessError.childWaitFailed(code: errno)
        }
    }

    private func currentLogFailure() -> ManagedProcessError? {
        stateLock.withLock { terminalLogFailure ?? collector?.failure() }
    }

    private func finishCollector(_ collector: ManagedOutputCollector?) throws {
        guard let collector else { return }
        do {
            try collector.waitForEOF()
        } catch let failure as ManagedProcessError {
            stateLock.withLock { terminalLogFailure = failure }
            throw failure
        }
    }

    private static func validatedLogName(_ file: URL, directory: URL) throws -> String {
        guard file.isFileURL,
              file.deletingLastPathComponent().path == directory.path,
              !file.lastPathComponent.isEmpty,
              !file.lastPathComponent.contains("/")
        else {
            throw ManagedProcessError.invalidConfiguration("log file is outside the configured log directory")
        }
        return file.lastPathComponent
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw ManagedProcessError.logFailure(operation: "pipe", code: errno)
        }
        for descriptor in descriptors {
            let flags = Darwin.fcntl(descriptor, F_GETFD)
            guard flags >= 0, Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                let code = errno
                _ = Darwin.close(descriptors[0])
                _ = Darwin.close(descriptors[1])
                throw ManagedProcessError.logFailure(operation: "fcntl pipe", code: code)
            }
        }
        return (descriptors[0], descriptors[1])
    }

    private static func closePipe(_ pipe: inout (read: Int32, write: Int32)) {
        if pipe.read >= 0 { _ = Darwin.close(pipe.read); pipe.read = -1 }
        if pipe.write >= 0 { _ = Darwin.close(pipe.write); pipe.write = -1 }
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.compactMap { $0 }.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    static func readIdentity(for processIdentifier: pid_t) -> ManagedProcessIdentity? {
        guard processIdentifier > 0 else { return nil }
        var information = proc_bsdinfo()
        let informationSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &information,
            informationSize
        )
        guard result == informationSize, information.pbi_pid == UInt32(processIdentifier) else {
            return nil
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        let executablePath = String(
            decoding: pathBuffer.prefix(Int(pathLength)).map(UInt8.init(bitPattern:)),
            as: UTF8.self
        )
        let seconds = information.pbi_start_tvsec
        let microseconds = information.pbi_start_tvusec
        return ManagedProcessIdentity(
            executablePath: URL(fileURLWithPath: executablePath).standardizedFileURL.path,
            launchTimestamp: Date(
                timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000
            ),
            processIdentifier: processIdentifier,
            startIdentityToken: "\(processIdentifier):\(seconds):\(microseconds)"
        )
    }
}

private final class ManagedOutputCollector: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var firstFailure: ManagedProcessError?

    init(
        standardOutputDescriptor: Int32,
        standardErrorDescriptor: Int32,
        standardOutput: BoundedRotatingLog,
        standardError: BoundedRotatingLog
    ) {
        startReader(descriptor: standardOutputDescriptor, name: "stdout", writer: standardOutput)
        startReader(descriptor: standardErrorDescriptor, name: "stderr", writer: standardError)
    }

    func failure() -> ManagedProcessError? {
        lock.withLock { firstFailure }
    }

    func waitForEOF() throws {
        group.wait()
        if let failure = failure() { throw failure }
    }

    private func startReader(descriptor: Int32, name: String, writer: BoundedRotatingLog) {
        group.enter()
        // Dedicated readers prevent cooperative-executor starvation when several supervisors
        // synchronously drain/reap during concurrent shutdown.
        Thread.detachNewThread { [self] in
            defer {
                _ = Darwin.close(descriptor)
                group.leave()
            }
            var redactor = StreamingLogRedactor(values: writer.redactedValues)
            var buffer = [UInt8](repeating: 0, count: 32_768)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    write(redactor.consume(Data(buffer.prefix(count))), to: writer)
                } else if count == 0 {
                    write(redactor.finish(), to: writer)
                    return
                } else if errno != EINTR {
                    record(.logFailure(operation: "read \(name)", code: errno))
                    return
                }
            }
        }
    }

    private func write(_ data: Data, to writer: BoundedRotatingLog) {
        guard !data.isEmpty else { return }
        do {
            try writer.append(data)
        } catch let failure as ManagedProcessError {
            record(failure)
        } catch {
            record(.logFailure(operation: "write log", code: EIO))
        }
    }

    private func record(_ failure: ManagedProcessError) {
        lock.withLock {
            if firstFailure == nil { firstFailure = failure }
        }
    }
}

private struct StreamingLogRedactor {
    private static let replacement = Data("[REDACTED]".utf8)
    private let values: [Data]
    private let retainedByteCount: Int
    private var pending = Data()

    init(values: [String]) {
        self.values = values.map { Data($0.utf8) }.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        retainedByteCount = max(0, (self.values.map(\.count).max() ?? 1) - 1)
    }

    mutating func consume(_ data: Data) -> Data {
        pending.append(data)
        pending = redact(pending)
        guard pending.count > retainedByteCount else { return Data() }
        let emittedCount = pending.count - retainedByteCount
        let emitted = Data(pending.prefix(emittedCount))
        pending.removeFirst(emittedCount)
        return emitted
    }

    mutating func finish() -> Data {
        defer { pending.removeAll(keepingCapacity: false) }
        return redact(pending)
    }

    private func redact(_ data: Data) -> Data {
        values.reduce(data) { partial, secret in
            var result = partial
            while let range = result.range(of: secret) {
                result.replaceSubrange(range, with: Self.replacement)
            }
            return result
        }
    }
}

final class SecureLogDirectory: @unchecked Sendable {
    let descriptor: Int32
    private let profileRoot: URL
    private let profileIdentity: FilesystemIdentity
    private let logIdentity: FilesystemIdentity
    private let logName: String
    private let profileDescriptor: Int32

    init(profileRoot: URL, logsDirectory: URL) throws {
        let profileRoot = profileRoot
        let logsDirectory = logsDirectory
        guard profileRoot.isFileURL,
              logsDirectory.isFileURL,
              logsDirectory.deletingLastPathComponent() == profileRoot,
              !logsDirectory.lastPathComponent.isEmpty
        else {
            throw ManagedProcessError.invalidConfiguration("logs directory must be a direct child of the profile root")
        }

        let profileDescriptor = try Self.openAbsoluteDirectory(profileRoot)
        do {
            let profileIdentity = try Self.validatedDirectoryIdentity(profileDescriptor, requiredMode: 0o700)
            let logName = logsDirectory.lastPathComponent
            var created = false
            let mkdirResult = logName.withCString { Darwin.mkdirat(profileDescriptor, $0, mode_t(0o700)) }
            if mkdirResult == 0 {
                created = true
            } else if errno != EEXIST {
                throw ManagedProcessError.logFailure(operation: "mkdir logs", code: errno)
            }
            let descriptor = logName.withCString {
                Darwin.openat(profileDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw ManagedProcessError.logFailure(operation: "open logs", code: errno)
            }
            do {
                if created, Darwin.fchmod(descriptor, mode_t(0o700)) != 0 {
                    throw ManagedProcessError.logFailure(operation: "fchmod new logs", code: errno)
                }
                let logIdentity = try Self.validatedDirectoryIdentity(descriptor, requiredMode: 0o700)
                self.profileRoot = profileRoot
                self.profileIdentity = profileIdentity
                self.logIdentity = logIdentity
                self.logName = logName
                self.profileDescriptor = profileDescriptor
                self.descriptor = descriptor
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        } catch {
            _ = Darwin.close(profileDescriptor)
            throw error
        }
    }

    deinit {
        _ = Darwin.close(descriptor)
        _ = Darwin.close(profileDescriptor)
    }

    func validateIdentity() throws {
        let reopenedProfile = try Self.openAbsoluteDirectory(profileRoot)
        defer { _ = Darwin.close(reopenedProfile) }
        guard try Self.validatedDirectoryIdentity(reopenedProfile, requiredMode: 0o700) == profileIdentity,
              try Self.validatedDirectoryIdentity(profileDescriptor, requiredMode: 0o700) == profileIdentity,
              try Self.validatedDirectoryIdentity(descriptor, requiredMode: 0o700) == logIdentity
        else {
            throw ManagedProcessError.logIdentityChanged
        }

        var pathMetadata = stat()
        let result = logName.withCString {
            Darwin.fstatat(profileDescriptor, $0, &pathMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              FilesystemIdentity(pathMetadata) == logIdentity
        else {
            throw ManagedProcessError.logIdentityChanged
        }
    }

    private static func openAbsoluteDirectory(_ url: URL) throws -> Int32 {
        guard url.path.hasPrefix("/") else {
            throw ManagedProcessError.invalidConfiguration("profile root must be absolute")
        }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else {
            throw ManagedProcessError.logFailure(operation: "open filesystem root", code: errno)
        }
        for component in url.pathComponents.dropFirst() {
            let next = component.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                let code = errno
                _ = Darwin.close(current)
                throw ManagedProcessError.logFailure(operation: "open profile ancestor", code: code)
            }
            _ = Darwin.close(current)
            current = next
        }
        return current
    }

    private static func validatedDirectoryIdentity(
        _ descriptor: Int32,
        requiredMode: mode_t
    ) throws -> FilesystemIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ManagedProcessError.logFailure(operation: "fstat directory", code: errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o777 == requiredMode
        else {
            throw ManagedProcessError.invalidConfiguration("profile/log directory owner, mode, or type is unsafe")
        }
        return FilesystemIdentity(metadata)
    }
}

private struct FilesystemIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let mode: mode_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        owner = metadata.st_uid
        mode = metadata.st_mode
    }
}

final class BoundedRotatingLog: @unchecked Sendable {
    let redactedValues: [String]
    private let directory: SecureLogDirectory
    private let fileName: String
    private let maximumBytesPerFile: Int
    private let retainedFileCount: Int
    private let writeHook: ManagedLogWriteHook
    private let lock = NSLock()

    init(
        directory: SecureLogDirectory,
        fileName: String,
        maximumBytesPerFile: Int,
        retainedFileCount: Int,
        redactedValues: [String],
        writeHook: @escaping ManagedLogWriteHook
    ) throws {
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              maximumBytesPerFile > 0,
              retainedFileCount > 0
        else {
            throw ManagedProcessError.invalidConfiguration("invalid rotating log configuration")
        }
        self.directory = directory
        self.fileName = fileName
        self.maximumBytesPerFile = maximumBytesPerFile
        self.retainedFileCount = retainedFileCount
        self.redactedValues = redactedValues
        self.writeHook = writeHook
        try normalizeRetainedFiles()
    }

    convenience init(file: URL, maximumBytesPerFile: Int, retainedFileCount: Int) throws {
        let logs = file.deletingLastPathComponent()
        let profile = logs.deletingLastPathComponent()
        let directory = try SecureLogDirectory(profileRoot: profile, logsDirectory: logs)
        try self.init(
            directory: directory,
            fileName: file.lastPathComponent,
            maximumBytesPerFile: maximumBytesPerFile,
            retainedFileCount: retainedFileCount,
            redactedValues: [],
            writeHook: { _ in }
        )
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try writeHook(data)
        lock.lock()
        defer { lock.unlock() }
        try directory.validateIdentity()

        var offset = 0
        while offset < data.count {
            var descriptor = try openCurrentLog()
            var status = try validatedFileIdentity(descriptor)
            var size = Int(status.st_size)
            if size >= maximumBytesPerFile {
                _ = Darwin.close(descriptor)
                try rotate()
                descriptor = try openCurrentLog()
                status = try validatedFileIdentity(descriptor)
                size = Int(status.st_size)
            }

            let count = min(maximumBytesPerFile - size, data.count - offset)
            do {
                try data.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else { return }
                    var written = 0
                    while written < count {
                        let result = Darwin.write(
                            descriptor,
                            base.advanced(by: offset + written),
                            count - written
                        )
                        if result > 0 {
                            written += result
                        } else if result < 0, errno == EINTR {
                            continue
                        } else {
                            throw ManagedProcessError.logFailure(operation: "write log", code: errno)
                        }
                    }
                }
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
            guard Darwin.close(descriptor) == 0 else {
                throw ManagedProcessError.logFailure(operation: "close log", code: errno)
            }
            offset += count
        }
        try directory.validateIdentity()
    }

    private func openCurrentLog() throws -> Int32 {
        try directory.validateIdentity()
        let createFlags = O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC | O_NOFOLLOW
        var descriptor = fileName.withCString {
            Darwin.openat(directory.descriptor, $0, createFlags, mode_t(0o600))
        }
        if descriptor >= 0 {
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                let code = errno
                _ = Darwin.close(descriptor)
                throw ManagedProcessError.logFailure(operation: "fchmod new log", code: code)
            }
        } else if errno == EEXIST {
            descriptor = fileName.withCString {
                Darwin.openat(directory.descriptor, $0, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
            }
        }
        guard descriptor >= 0 else {
            throw ManagedProcessError.logFailure(operation: "open log", code: errno)
        }
        _ = try validatedFileIdentity(descriptor)
        return descriptor
    }

    private func validatedFileIdentity(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw ManagedProcessError.logFailure(operation: "fstat log", code: errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == getuid(),
              status.st_mode & 0o777 == 0o600
        else {
            throw ManagedProcessError.invalidConfiguration("log must be a user-only regular single-link file")
        }
        return status
    }

    private func normalizeRetainedFiles() throws {
        try directory.validateIdentity()
        for index in 0..<retainedFileCount {
            let name = index == 0 ? fileName : rotatedName(index)
            let descriptor = name.withCString {
                Darwin.openat(directory.descriptor, $0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            if descriptor < 0, errno == ENOENT { continue }
            guard descriptor >= 0 else {
                throw ManagedProcessError.logFailure(operation: "open retained log", code: errno)
            }
            do {
                let status = try validatedFileIdentity(descriptor)
                if status.st_size > maximumBytesPerFile,
                   Darwin.ftruncate(descriptor, off_t(maximumBytesPerFile)) != 0 {
                    throw ManagedProcessError.logFailure(operation: "truncate retained log", code: errno)
                }
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
            _ = Darwin.close(descriptor)
        }
    }

    private func rotate() throws {
        try directory.validateIdentity()
        if retainedFileCount == 1 {
            try unlinkIfPresent(fileName)
            return
        }
        try unlinkIfPresent(rotatedName(retainedFileCount - 1))
        if retainedFileCount > 2 {
            for index in stride(from: retainedFileCount - 2, through: 1, by: -1) {
                try renameIfPresent(from: rotatedName(index), to: rotatedName(index + 1))
            }
        }
        try renameIfPresent(from: fileName, to: rotatedName(1))
    }

    private func rotatedName(_ index: Int) -> String { "\(fileName).\(index)" }

    private func unlinkIfPresent(_ name: String) throws {
        let result = name.withCString { Darwin.unlinkat(directory.descriptor, $0, 0) }
        guard result == 0 || errno == ENOENT else {
            throw ManagedProcessError.logFailure(operation: "unlink rotated log", code: errno)
        }
    }

    private func renameIfPresent(from source: String, to destination: String) throws {
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                Darwin.renameat(directory.descriptor, sourcePointer, directory.descriptor, destinationPointer)
            }
        }
        guard result == 0 || errno == ENOENT else {
            throw ManagedProcessError.logFailure(operation: "rotate log", code: errno)
        }
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
