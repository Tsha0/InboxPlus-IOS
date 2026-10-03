import Foundation

public enum RuntimePhase: String, Codable, Sendable, CaseIterable {
    case unprepared
    case stopped
    case starting
    case healthy
    case degraded
    case recovering
    case stopping
    case failed
}

public struct RuntimeState: Sendable, Equatable {
    public let phase: RuntimePhase

    public init(phase: RuntimePhase) {
        self.phase = phase
    }

    public func transitioning(to next: RuntimePhase) throws -> RuntimeState {
        guard Self.allowedTransitions[phase, default: []].contains(next) else {
            throw RuntimeStateError.invalidTransition(from: phase, to: next)
        }
        return RuntimeState(phase: next)
    }

    private static let allowedTransitions: [RuntimePhase: Set<RuntimePhase>] = [
        .unprepared: [.stopped, .failed],
        .stopped: [.starting],
        .starting: [.healthy, .degraded, .failed],
        .healthy: [.degraded, .stopping, .recovering, .failed],
        .degraded: [.healthy, .recovering, .stopping, .failed],
        .recovering: [.starting, .healthy, .degraded, .stopping, .failed],
        .stopping: [.stopped, .failed],
        .failed: [.stopping, .stopped, .recovering],
    ]
}

public struct RuntimeSnapshot: Codable, Sendable, Equatable {
    public let phase: RuntimePhase
    public let processIdentity: ManagedProcessIdentity?
    public let loopbackPort: UInt16?
    public let restartCount: Int
    public let lastHealthResult: String?
    public let diagnosticLogDirectory: URL?
    public let lastError: String?

    public init(
        phase: RuntimePhase,
        processIdentity: ManagedProcessIdentity?,
        loopbackPort: UInt16?,
        restartCount: Int,
        lastHealthResult: String?,
        diagnosticLogDirectory: URL?,
        lastError: String?
    ) throws {
        if let validationError = Self.validationError(
            phase: phase,
            processIdentity: processIdentity,
            loopbackPort: loopbackPort,
            restartCount: restartCount,
            lastError: lastError
        ) {
            throw validationError
        }
        self.init(
            uncheckedPhase: phase,
            processIdentity: processIdentity,
            loopbackPort: loopbackPort,
            restartCount: restartCount,
            lastHealthResult: lastHealthResult,
            diagnosticLogDirectory: diagnosticLogDirectory,
            lastError: lastError
        )
    }

    init(
        uncheckedPhase phase: RuntimePhase,
        processIdentity: ManagedProcessIdentity?,
        loopbackPort: UInt16?,
        restartCount: Int,
        lastHealthResult: String?,
        diagnosticLogDirectory: URL?,
        lastError: String?
    ) {
        self.phase = phase
        self.processIdentity = processIdentity
        self.loopbackPort = loopbackPort
        self.restartCount = restartCount
        self.lastHealthResult = lastHealthResult
        self.diagnosticLogDirectory = diagnosticLogDirectory
        self.lastError = lastError
    }

    public static let stopped = RuntimeSnapshot(
        uncheckedPhase: .stopped,
        processIdentity: nil,
        loopbackPort: nil,
        restartCount: 0,
        lastHealthResult: nil,
        diagnosticLogDirectory: nil,
        lastError: nil
    )

    var structuralValidationError: RuntimeStateError? {
        Self.validationError(
            phase: phase,
            processIdentity: processIdentity,
            loopbackPort: loopbackPort,
            restartCount: restartCount,
            lastError: lastError
        )
    }

    private static func validationError(
        phase: RuntimePhase,
        processIdentity: ManagedProcessIdentity?,
        loopbackPort: UInt16?,
        restartCount: Int,
        lastError: String?
    ) -> RuntimeStateError? {
        guard restartCount >= 0 else {
            return .invalidSnapshot(phase: phase, reason: "restart count cannot be negative")
        }

        let requiresRuntimeAuthority: Bool = switch phase {
        case .healthy, .degraded, .stopping: true
        case .unprepared, .stopped, .starting, .recovering, .failed: false
        }
        if requiresRuntimeAuthority {
            guard let processIdentity else {
                return .invalidSnapshot(phase: phase, reason: "phase requires exact process identity")
            }
            guard processIdentity.processIdentifier > 0,
                  !processIdentity.executablePath.isEmpty,
                  !processIdentity.startIdentityToken.isEmpty
            else {
                return .invalidSnapshot(phase: phase, reason: "process identity is incomplete")
            }
            guard let loopbackPort, loopbackPort > 0 else {
                return .invalidSnapshot(phase: phase, reason: "phase requires a nonzero loopback port")
            }
        } else {
            guard processIdentity == nil else {
                return .invalidSnapshot(phase: phase, reason: "phase forbids process identity")
            }
            guard loopbackPort == nil else {
                return .invalidSnapshot(phase: phase, reason: "phase forbids listener metadata")
            }
        }
        if phase == .failed, lastError?.isEmpty != false {
            return .invalidSnapshot(phase: phase, reason: "failed phase requires an actionable error")
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case phase
        case processIdentity
        case loopbackPort
        case restartCount
        case lastHealthResult
        case diagnosticLogDirectory
        case lastError
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let phase = try container.decode(RuntimePhase.self, forKey: .phase)
        do {
            try self.init(
                phase: phase,
                processIdentity: container.decodeIfPresent(
                    ManagedProcessIdentity.self,
                    forKey: .processIdentity
                ),
                loopbackPort: container.decodeIfPresent(UInt16.self, forKey: .loopbackPort),
                restartCount: container.decode(Int.self, forKey: .restartCount),
                lastHealthResult: container.decodeIfPresent(String.self, forKey: .lastHealthResult),
                diagnosticLogDirectory: container.decodeIfPresent(
                    URL.self,
                    forKey: .diagnosticLogDirectory
                ),
                lastError: container.decodeIfPresent(String.self, forKey: .lastError)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .phase,
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phase, forKey: .phase)
        try container.encodeIfPresent(processIdentity, forKey: .processIdentity)
        try container.encodeIfPresent(loopbackPort, forKey: .loopbackPort)
        try container.encode(restartCount, forKey: .restartCount)
        try container.encodeIfPresent(lastHealthResult, forKey: .lastHealthResult)
        try container.encodeIfPresent(diagnosticLogDirectory, forKey: .diagnosticLogDirectory)
        try container.encodeIfPresent(lastError, forKey: .lastError)
    }
}

public enum RuntimeExitCode: Int32, Codable, Sendable, CaseIterable {
    case success = 0
    case usage = 10
    case invalidTransition = 20
    case unprepared = 21
    case processLaunchFailed = 22
    case processIdentityMismatch = 23
    case shutdownIncomplete = 24
    case unavailableDependency = 25
    case healthFailure = 26
    case integrityFailure = 27
    case benchmarkFailure = 28
    case unsafePath = 29
}

public enum RuntimeStateError: Error, Sendable, Equatable {
    case invalidSnapshot(phase: RuntimePhase, reason: String)
    case invalidTransition(from: RuntimePhase, to: RuntimePhase)
    case processExitedUnexpectedly(ManagedProcessIdentity)
    case processIdentityMismatch(expected: ManagedProcessIdentity, actual: ManagedProcessIdentity)
    case uncontrolledProcess(ManagedProcessIdentity)
    case shutdownIncomplete(processAlive: Bool, listenerPresence: LoopbackListenerPresence)
}
