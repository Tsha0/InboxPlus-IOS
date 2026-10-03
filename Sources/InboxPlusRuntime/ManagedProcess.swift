import Darwin
import Foundation

public struct ManagedProcessIdentity: Codable, Sendable, Equatable {
    public let executablePath: String
    public let launchTimestamp: Date
    public let processIdentifier: Int32
    public let startIdentityToken: String

    public init(
        executablePath: String,
        launchTimestamp: Date,
        processIdentifier: Int32,
        startIdentityToken: String
    ) {
        self.executablePath = executablePath
        self.launchTimestamp = launchTimestamp
        self.processIdentifier = processIdentifier
        self.startIdentityToken = startIdentityToken
    }
}

public enum ManagedProcessIdentityStatus: Sendable, Equatable {
    case matching
    case exited
    case mismatched(actual: ManagedProcessIdentity)
    case indeterminate(ManagedProcessError)
}

public enum ManagedProcessOwnership: Sendable, Equatable {
    case directChild
    case observedOnly
}

public enum ManagedProcessSignal: Sendable, Equatable {
    case terminate
    case kill
}

public struct ManagedProcessConfiguration: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL
    public let profileRoot: URL
    public let logsDirectory: URL
    public let standardOutputLog: URL
    public let standardErrorLog: URL
    public let maximumLogBytesPerFile: Int
    public let retainedLogFileCount: Int
    public let sensitiveLogValues: [String]

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        profileRoot: URL,
        logsDirectory: URL,
        standardOutputLog: URL,
        standardErrorLog: URL,
        maximumLogBytesPerFile: Int = 1_048_576,
        retainedLogFileCount: Int = 3,
        sensitiveLogValues: [String] = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.profileRoot = profileRoot
        self.logsDirectory = logsDirectory
        self.standardOutputLog = standardOutputLog
        self.standardErrorLog = standardErrorLog
        self.maximumLogBytesPerFile = maximumLogBytesPerFile
        self.retainedLogFileCount = retainedLogFileCount
        self.sensitiveLogValues = sensitiveLogValues
    }

    var redactedLogValues: [String] {
        let sensitiveEnvironmentKeys = ["token", "secret", "password", "credential", "private_key"]
        let environmentValues = environment.compactMap { key, value in
            sensitiveEnvironmentKeys.contains(where: key.lowercased().contains) ? value : nil
        }
        return Array(Set((sensitiveLogValues + environmentValues).filter { !$0.isEmpty }))
    }
}

public protocol ManagedProcess: Sendable {
    func launch() async throws -> ManagedProcessIdentity
    func identityStatus(for expected: ManagedProcessIdentity) async -> ManagedProcessIdentityStatus
    func ownership(for expected: ManagedProcessIdentity) async -> ManagedProcessOwnership
    @discardableResult
    func signal(_ signal: ManagedProcessSignal, ifMatching expected: ManagedProcessIdentity) async throws -> Bool
    func waitForExit(matching expected: ManagedProcessIdentity, timeout: Duration) async throws -> Bool
    func lifecycleFailure() async -> ManagedProcessError?
}

public extension ManagedProcess {
    func lifecycleFailure() async -> ManagedProcessError? { nil }
}

public protocol ManagedProcessFactory: Sendable {
    func make(_ configuration: ManagedProcessConfiguration) throws -> any ManagedProcess
    func rehydrate(
        _ configuration: ManagedProcessConfiguration,
        expectedIdentity: ManagedProcessIdentity
    ) throws -> any ManagedProcess
}

public enum LoopbackListenerPresence: Sendable, Equatable {
    case present
    case absent
    case indeterminate(LoopbackListenerFailure)
}

public enum LoopbackListenerFailure: Sendable, Equatable {
    case timeout
    case systemError(operation: String, code: Int32)
}

public protocol LoopbackListenerChecking: Sendable {
    func presence(on port: UInt16) async -> LoopbackListenerPresence
}

public struct SystemLoopbackListenerChecker: LoopbackListenerChecking {
    private let timeoutMilliseconds: Int32

    public init(timeoutMilliseconds: Int32 = 100) {
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func presence(on port: UInt16) async -> LoopbackListenerPresence {
        let timeoutMilliseconds = timeoutMilliseconds
        return await Task.detached(priority: .utility) {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                return .indeterminate(.systemError(operation: "socket", code: errno))
            }
            defer { _ = Darwin.close(descriptor) }

            let originalFlags = Darwin.fcntl(descriptor, F_GETFL)
            guard originalFlags >= 0,
                  Darwin.fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0
            else {
                return .indeterminate(.systemError(operation: "fcntl", code: errno))
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connectionResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connectionResult == 0 { return .present }
            if errno == ECONNREFUSED { return .absent }
            guard errno == EINPROGRESS else {
                return .indeterminate(.systemError(operation: "connect", code: errno))
            }

            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let pollResult = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
            if pollResult == 0 { return .indeterminate(.timeout) }
            guard pollResult > 0 else {
                return .indeterminate(.systemError(operation: "poll", code: errno))
            }

            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorLength
            ) == 0 else {
                return .indeterminate(.systemError(operation: "getsockopt", code: errno))
            }
            if socketError == 0 { return .present }
            if socketError == ECONNREFUSED { return .absent }
            return .indeterminate(.systemError(operation: "connect", code: socketError))
        }.value
    }
}

public enum ManagedProcessError: Error, Sendable, Equatable {
    case invalidConfiguration(String)
    case alreadyLaunched
    case launchIdentityUnavailable(Int32)
    case processIdentityUnavailable(Int32)
    case processNotOwned(ManagedProcessIdentity)
    case spawnFailed(code: Int32)
    case signalFailed(signal: ManagedProcessSignal, code: Int32)
    case childWaitFailed(code: Int32)
    case logFailure(operation: String, code: Int32)
    case logIdentityChanged
}
