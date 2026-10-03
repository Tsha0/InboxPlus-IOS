import Foundation

public enum SynapseSupervisorError: Error, Sendable, Equatable {
    case startupHealthTimeout(HealthFailure)
    case healthCheckReportedStopped
}

public actor SynapseSupervisor {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Now = @Sendable () async -> Duration

    private struct OperationToken: Equatable {
        let value: UInt64
    }

    private struct ObservationContext {
        let stateGeneration: UInt64
        let processGeneration: UInt64
        let phase: RuntimePhase
        let identity: ManagedProcessIdentity
    }

    private let configuration: ManagedProcessConfiguration
    private let loopbackPort: UInt16
    private let processFactory: any ManagedProcessFactory
    private let listenerChecker: any LoopbackListenerChecking
    private let healthChecker: any SynapseHealthChecking
    private let gracefulTerminationTimeout: Duration
    private let forcedTerminationTimeout: Duration
    private let listenerVerificationAttempts: Int
    private let listenerVerificationInterval: Duration
    private let sleep: Sleep
    private let startupPollInterval: Duration
    private let startupTimeout: Duration
    private let healthPollInterval: Duration
    private let healthyResetInterval: Duration
    private let pollSleep: Sleep
    private let recoverySleep: Sleep
    private let now: Now

    private var snapshot: RuntimeSnapshot
    private var managedProcess: (any ManagedProcess)?
    private let snapshotValidationFailure: RuntimeStateError?
    private var stateGeneration: UInt64 = 0
    private var processGeneration: UInt64 = 0
    private var nextOperationValue: UInt64 = 0
    private var activeOperation: OperationToken?
    private var nextSupervisionValue: UInt64 = 0
    private var activeSupervision: UInt64?
    private var healthySince: Duration?

    public init(
        configuration: ManagedProcessConfiguration,
        loopbackPort: UInt16,
        processFactory: any ManagedProcessFactory = FoundationManagedProcessFactory(),
        listenerChecker: any LoopbackListenerChecking = SystemLoopbackListenerChecker(),
        healthChecker: any SynapseHealthChecking,
        initialSnapshot: RuntimeSnapshot = .stopped,
        gracefulTerminationTimeout: Duration = .seconds(5),
        forcedTerminationTimeout: Duration = .seconds(1),
        listenerVerificationAttempts: Int = 20,
        listenerVerificationInterval: Duration = .milliseconds(50),
        startupPollInterval: Duration = .milliseconds(500),
        startupTimeout: Duration = .seconds(30),
        healthPollInterval: Duration = .milliseconds(500),
        healthyResetInterval: Duration = .seconds(60),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        pollSleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        recoverySleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping Now = { .seconds(ProcessInfo.processInfo.systemUptime) }
    ) {
        precondition(listenerVerificationAttempts > 0)
        precondition(startupPollInterval > .zero)
        precondition(startupTimeout > .zero)
        precondition(healthPollInterval > .zero)
        precondition(healthyResetInterval > .zero)
        self.configuration = configuration
        self.loopbackPort = loopbackPort
        self.processFactory = processFactory
        self.listenerChecker = listenerChecker
        self.healthChecker = healthChecker
        let validationFailure = initialSnapshot.structuralValidationError
        snapshotValidationFailure = validationFailure
        if let validationFailure {
            snapshot = RuntimeSnapshot(
                uncheckedPhase: .failed,
                processIdentity: nil,
                loopbackPort: nil,
                restartCount: max(0, initialSnapshot.restartCount),
                lastHealthResult: initialSnapshot.lastHealthResult,
                diagnosticLogDirectory: initialSnapshot.diagnosticLogDirectory ?? configuration.logsDirectory,
                lastError: String(describing: validationFailure)
            )
        } else {
            snapshot = initialSnapshot
        }
        self.gracefulTerminationTimeout = gracefulTerminationTimeout
        self.forcedTerminationTimeout = forcedTerminationTimeout
        self.listenerVerificationAttempts = listenerVerificationAttempts
        self.listenerVerificationInterval = listenerVerificationInterval
        self.sleep = sleep
        self.startupPollInterval = startupPollInterval
        self.startupTimeout = startupTimeout
        self.healthPollInterval = healthPollInterval
        self.healthyResetInterval = healthyResetInterval
        self.pollSleep = pollSleep
        self.recoverySleep = recoverySleep
        self.now = now
    }

    public func start() async throws -> RuntimeSnapshot {
        if let snapshotValidationFailure { throw snapshotValidationFailure }
        let operation = try beginOperation(transitioningTo: .starting)
        cancelSupervision()
        defer { endOperation(operation) }
        var launchedIdentity: ManagedProcessIdentity?
        var launchedProcess: (any ManagedProcess)?
        do {
            let process = try processFactory.make(configuration)
            launchedProcess = process
            replaceManagedProcess(with: process)
            let identity = try await process.launch()
            launchedIdentity = identity
            try requireCurrent(operation)
            let lifecycleFailure = await process.lifecycleFailure()
            try requireCurrent(operation)
            if let lifecycleFailure { throw lifecycleFailure }
            let result = try await waitForStartupHealth(
                process: process,
                identity: identity,
                operation: operation,
                restartCount: 0
            )
            healthySince = await now()
            return result
        } catch {
            if isCurrent(operation) {
                await cleanUpFailedLaunch(
                    process: launchedProcess,
                    identity: launchedIdentity,
                    operation: operation
                )
                replaceManagedProcess(with: nil)
                fail(with: error)
            }
            throw error
        }
    }

    public func stop() async throws -> RuntimeSnapshot {
        if let snapshotValidationFailure { throw snapshotValidationFailure }
        cancelSupervision()
        if snapshot.phase == .stopped { return snapshot }
        if snapshot.phase == .failed || snapshot.phase == .recovering {
            return try await stopWithoutRuntimeAuthority()
        }
        let operation = try beginOperation(transitioningTo: .stopping)
        defer { endOperation(operation) }

        do {
            guard let identity = snapshot.processIdentity else {
                let listenerPresence = await waitForListenerDisappearance()
                try requireCurrent(operation)
                guard listenerPresence == .absent else {
                    throw RuntimeStateError.shutdownIncomplete(
                        processAlive: false,
                        listenerPresence: listenerPresence
                    )
                }
                replaceManagedProcess(with: nil)
                return stoppedSnapshot()
            }
            let process = try rehydratedProcessIfNeeded(identity: identity)

            let initialIdentityStatus = await process.identityStatus(for: identity)
            try requireCurrent(operation)
            switch initialIdentityStatus {
            case .exited:
                let ownership = await process.ownership(for: identity)
                try requireCurrent(operation)
                if ownership == .directChild {
                    _ = try await process.waitForExit(matching: identity, timeout: .zero)
                    try requireCurrent(operation)
                }
            case let .mismatched(actual):
                throw RuntimeStateError.processIdentityMismatch(expected: identity, actual: actual)
            case let .indeterminate(failure):
                throw failure
            case .matching:
                let ownership = await process.ownership(for: identity)
                try requireCurrent(operation)
                guard ownership == .directChild else {
                    throw RuntimeStateError.uncontrolledProcess(identity)
                }
                _ = try await process.signal(.terminate, ifMatching: identity)
                try requireCurrent(operation)
                let exitedGracefully = try await process.waitForExit(
                    matching: identity,
                    timeout: gracefulTerminationTimeout
                )
                try requireCurrent(operation)
                if !exitedGracefully {
                    _ = try await process.signal(.kill, ifMatching: identity)
                    try requireCurrent(operation)
                    _ = try await process.waitForExit(
                        matching: identity,
                        timeout: forcedTerminationTimeout
                    )
                    try requireCurrent(operation)
                }
            }

            let processAlive: Bool
            let finalIdentityStatus = await process.identityStatus(for: identity)
            try requireCurrent(operation)
            switch finalIdentityStatus {
            case .exited:
                processAlive = false
            case let .mismatched(actual):
                throw RuntimeStateError.processIdentityMismatch(expected: identity, actual: actual)
            case let .indeterminate(failure):
                throw failure
            case .matching:
                processAlive = true
            }
            let listenerPresence = await waitForListenerDisappearance()
            try requireCurrent(operation)
            guard !processAlive, listenerPresence == .absent else {
                throw RuntimeStateError.shutdownIncomplete(
                    processAlive: processAlive,
                    listenerPresence: listenerPresence
                )
            }

            replaceManagedProcess(with: nil)
            return stoppedSnapshot()
        } catch {
            if isCurrent(operation) { fail(with: error) }
            throw error
        }
    }

    public func status() async -> RuntimeSnapshot {
        if snapshotValidationFailure != nil || activeOperation != nil { return snapshot }
        let observedPhase = snapshot.phase
        guard observedPhase == .healthy || observedPhase == .degraded,
              let identity = snapshot.processIdentity
        else {
            return snapshot
        }

        let process: any ManagedProcess
        do {
            process = try rehydratedProcessIfNeeded(identity: identity)
        } catch {
            fail(with: error)
            return snapshot
        }
        let observation = observationContext(phase: observedPhase, identity: identity)

        let lifecycleFailure = await process.lifecycleFailure()
        guard observationIsCurrent(observation) else { return snapshot }
        if let lifecycleFailure {
            await cleanUpAfterLifecycleFailure(
                process: process,
                identity: identity,
                failure: lifecycleFailure,
                observation: observation
            )
            return snapshot
        }
        let identityStatus = await process.identityStatus(for: identity)
        guard observationIsCurrent(observation) else { return snapshot }
        switch identityStatus {
        case .matching:
            let ownership = await process.ownership(for: identity)
            guard observationIsCurrent(observation) else { return snapshot }
            if ownership == .observedOnly {
                updateSnapshot(RuntimeSnapshot(
                    uncheckedPhase: .degraded,
                    processIdentity: identity,
                    loopbackPort: snapshot.loopbackPort,
                    restartCount: snapshot.restartCount,
                    lastHealthResult: snapshot.lastHealthResult,
                    diagnosticLogDirectory: snapshot.diagnosticLogDirectory,
                    lastError: String(describing: RuntimeStateError.uncontrolledProcess(identity))
                ))
                return snapshot
            }
            let health = await healthChecker.check(snapshot: snapshot)
            guard observationIsCurrent(observation) else { return snapshot }
            applyObservedHealth(health, identity: identity)
        case .exited:
            fail(with: RuntimeStateError.processExitedUnexpectedly(identity))
        case let .mismatched(actual):
            fail(with: RuntimeStateError.processIdentityMismatch(expected: identity, actual: actual))
        case let .indeterminate(failure):
            fail(with: failure)
        }
        return snapshot
    }

    public func supervise() async {
        guard activeSupervision == nil,
              activeOperation == nil,
              snapshot.phase == .healthy || snapshot.phase == .degraded
        else {
            return
        }
        nextSupervisionValue &+= 1
        let supervision = nextSupervisionValue
        activeSupervision = supervision
        if healthySince == nil { healthySince = await now() }
        defer {
            if activeSupervision == supervision { activeSupervision = nil }
        }

        while supervisionIsCurrent(supervision), !Task.isCancelled {
            guard snapshot.phase == .healthy || snapshot.phase == .degraded,
                  let identity = snapshot.processIdentity,
                  let process = managedProcess
            else {
                return
            }
            let observation = observationContext(phase: snapshot.phase, identity: identity)
            let health = await healthChecker.check(snapshot: snapshot)
            guard supervisionIsCurrent(supervision), observationIsCurrent(observation) else {
                return
            }

            switch health {
            case .stopped:
                guard await recover(
                    supervision: supervision,
                    process: process,
                    identity: identity,
                    failure: RuntimeStateError.processExitedUnexpectedly(identity)
                ) else {
                    return
                }
            case let .degraded(failure) where failure.processIsUnavailable:
                fail(with: failure)
                return
            case let .degraded(failure):
                healthySince = nil
                publishHealth(.degraded(failure), identity: identity)
            case .healthy:
                let instant = await now()
                if let healthySince,
                   instant - healthySince >= healthyResetInterval,
                   snapshot.restartCount != 0 {
                    publishHealth(health, identity: identity, restartCount: 0)
                    self.healthySince = instant
                } else {
                    if healthySince == nil { healthySince = instant }
                    publishHealth(health, identity: identity)
                }
            }

            guard supervisionIsCurrent(supervision), !Task.isCancelled else { return }
            do {
                try await pollSleep(healthPollInterval)
            } catch {
                return
            }
        }
    }

    private func waitForStartupHealth(
        process: any ManagedProcess,
        identity: ManagedProcessIdentity,
        operation: OperationToken,
        restartCount: Int
    ) async throws -> RuntimeSnapshot {
        let started = await now()
        var lastFailure: HealthFailure?
        while true {
            try requireCurrent(operation)
            let candidate = healthCandidate(identity: identity, restartCount: restartCount)
            let health = await healthChecker.check(snapshot: candidate)
            try requireCurrent(operation)
            switch health {
            case .healthy:
                publishHealth(health, identity: identity, restartCount: restartCount)
                return snapshot
            case .stopped:
                throw SynapseSupervisorError.healthCheckReportedStopped
            case let .degraded(failure):
                lastFailure = failure
            }
            let instant = await now()
            try requireCurrent(operation)
            if instant - started >= startupTimeout {
                throw SynapseSupervisorError.startupHealthTimeout(
                    lastFailure ?? .invalidResponse(layer: .versions)
                )
            }
            try await pollSleep(startupPollInterval)
        }
    }

    private func waitForRecoveryHealth(
        supervision: UInt64,
        process: any ManagedProcess,
        identity: ManagedProcessIdentity,
        restartCount: Int
    ) async throws {
        let started = await now()
        var lastFailure: HealthFailure?
        while supervisionIsCurrent(supervision), !Task.isCancelled {
            let processGeneration = self.processGeneration
            let stateGeneration = self.stateGeneration
            let health = await healthChecker.check(
                snapshot: healthCandidate(identity: identity, restartCount: restartCount)
            )
            guard supervisionIsCurrent(supervision),
                  self.processGeneration == processGeneration,
                  self.stateGeneration == stateGeneration,
                  snapshot.phase == .starting
            else {
                throw CancellationError()
            }
            switch health {
            case .healthy:
                publishHealth(health, identity: identity, restartCount: restartCount)
                healthySince = await now()
                return
            case .stopped:
                throw SynapseSupervisorError.healthCheckReportedStopped
            case let .degraded(failure):
                lastFailure = failure
            }
            if await now() - started >= startupTimeout {
                throw SynapseSupervisorError.startupHealthTimeout(
                    lastFailure ?? .invalidResponse(layer: .versions)
                )
            }
            try await pollSleep(startupPollInterval)
        }
        throw CancellationError()
    }

    private func recover(
        supervision: UInt64,
        process: any ManagedProcess,
        identity: ManagedProcessIdentity,
        failure: any Error
    ) async -> Bool {
        do {
            if await process.ownership(for: identity) == .directChild {
                _ = try await process.waitForExit(matching: identity, timeout: .zero)
            }
        } catch {
            if supervisionIsCurrent(supervision) { fail(with: error) }
            return false
        }
        guard supervisionIsCurrent(supervision) else { return false }
        replaceManagedProcess(with: nil)
        healthySince = nil

        var recoveryFailure: any Error = failure
        while snapshot.restartCount < 3,
              supervisionIsCurrent(supervision),
              !Task.isCancelled {
            let nextRestartCount = snapshot.restartCount + 1
            publishAuthorityFree(
                phase: .recovering,
                restartCount: snapshot.restartCount,
                lastHealthResult: snapshot.lastHealthResult,
                lastError: String(describing: recoveryFailure)
            )
            do {
                try await recoverySleep(Self.recoveryDelays[nextRestartCount - 1])
            } catch {
                return false
            }
            guard supervisionIsCurrent(supervision),
                  snapshot.phase == .recovering,
                  !Task.isCancelled
            else {
                return false
            }
            publishAuthorityFree(
                phase: .starting,
                restartCount: nextRestartCount,
                lastHealthResult: snapshot.lastHealthResult,
                lastError: nil
            )

            var launchedProcess: (any ManagedProcess)?
            var launchedIdentity: ManagedProcessIdentity?
            do {
                let replacement = try processFactory.make(configuration)
                launchedProcess = replacement
                replaceManagedProcess(with: replacement)
                let replacementIdentity = try await replacement.launch()
                launchedIdentity = replacementIdentity
                guard supervisionIsCurrent(supervision), snapshot.phase == .starting else {
                    throw CancellationError()
                }
                if let lifecycleFailure = await replacement.lifecycleFailure() {
                    throw lifecycleFailure
                }
                guard supervisionIsCurrent(supervision), snapshot.phase == .starting else {
                    throw CancellationError()
                }
                try await waitForRecoveryHealth(
                    supervision: supervision,
                    process: replacement,
                    identity: replacementIdentity,
                    restartCount: nextRestartCount
                )
                return true
            } catch {
                recoveryFailure = error
                await cleanUpRecoveryLaunch(
                    process: launchedProcess,
                    identity: launchedIdentity,
                    supervision: supervision
                )
                guard supervisionIsCurrent(supervision), !Task.isCancelled else { return false }
                replaceManagedProcess(with: nil)
                publishAuthorityFree(
                    phase: .recovering,
                    restartCount: nextRestartCount,
                    lastHealthResult: snapshot.lastHealthResult,
                    lastError: String(describing: error)
                )
            }
        }
        guard supervisionIsCurrent(supervision) else { return false }
        fail(with: recoveryFailure)
        return false
    }

    private func cleanUpFailedLaunch(
        process: (any ManagedProcess)?,
        identity: ManagedProcessIdentity?,
        operation: OperationToken
    ) async {
        guard let process, let identity, isCurrent(operation) else { return }
        await terminateAndReap(process: process, identity: identity)
    }

    private func cleanUpRecoveryLaunch(
        process: (any ManagedProcess)?,
        identity: ManagedProcessIdentity?,
        supervision: UInt64
    ) async {
        guard let process, let identity, supervisionIsCurrent(supervision) else { return }
        await terminateAndReap(process: process, identity: identity)
    }

    private func terminateAndReap(
        process: any ManagedProcess,
        identity: ManagedProcessIdentity
    ) async {
        guard await process.ownership(for: identity) == .directChild else { return }
        do {
            switch await process.identityStatus(for: identity) {
            case .matching:
                _ = try await process.signal(.kill, ifMatching: identity)
                _ = try await process.waitForExit(
                    matching: identity,
                    timeout: forcedTerminationTimeout
                )
            case .exited:
                _ = try await process.waitForExit(matching: identity, timeout: .zero)
            case .mismatched, .indeterminate:
                return
            }
        } catch {
            return
        }
    }

    private func applyObservedHealth(
        _ health: HealthResult,
        identity: ManagedProcessIdentity
    ) {
        switch health {
        case .healthy:
            publishHealth(health, identity: identity)
        case let .degraded(failure) where failure.processIsUnavailable:
            fail(with: failure)
        case .degraded:
            publishHealth(health, identity: identity)
        case .stopped:
            fail(with: RuntimeStateError.processExitedUnexpectedly(identity))
        }
    }

    private func publishHealth(
        _ health: HealthResult,
        identity: ManagedProcessIdentity,
        restartCount: Int? = nil
    ) {
        let phase: RuntimePhase
        let lastError: String?
        switch health {
        case .healthy:
            phase = .healthy
            lastError = nil
        case let .degraded(failure):
            phase = .degraded
            lastError = String(describing: failure)
        case .stopped:
            return
        }
        updateSnapshot(RuntimeSnapshot(
            uncheckedPhase: phase,
            processIdentity: identity,
            loopbackPort: loopbackPort,
            restartCount: restartCount ?? snapshot.restartCount,
            lastHealthResult: Self.healthSummary(health),
            diagnosticLogDirectory: configuration.logsDirectory,
            lastError: lastError
        ))
    }

    private func publishAuthorityFree(
        phase: RuntimePhase,
        restartCount: Int,
        lastHealthResult: String?,
        lastError: String?
    ) {
        if managedProcess != nil { replaceManagedProcess(with: nil) }
        updateSnapshot(RuntimeSnapshot(
            uncheckedPhase: phase,
            processIdentity: nil,
            loopbackPort: nil,
            restartCount: restartCount,
            lastHealthResult: lastHealthResult,
            diagnosticLogDirectory: configuration.logsDirectory,
            lastError: lastError
        ))
    }

    private func healthCandidate(
        identity: ManagedProcessIdentity,
        restartCount: Int
    ) -> RuntimeSnapshot {
        RuntimeSnapshot(
            uncheckedPhase: .healthy,
            processIdentity: identity,
            loopbackPort: loopbackPort,
            restartCount: restartCount,
            lastHealthResult: snapshot.lastHealthResult,
            diagnosticLogDirectory: configuration.logsDirectory,
            lastError: nil
        )
    }

    private static func healthSummary(_ health: HealthResult) -> String {
        switch health {
        case .healthy: "healthy"
        case let .degraded(failure): "degraded: \(failure)"
        case .stopped: "stopped"
        }
    }

    private static let recoveryDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4),
    ]

    private func rehydratedProcessIfNeeded(
        identity: ManagedProcessIdentity
    ) throws -> any ManagedProcess {
        if let managedProcess { return managedProcess }
        let process = try processFactory.rehydrate(configuration, expectedIdentity: identity)
        replaceManagedProcess(with: process)
        return process
    }

    private func cleanUpAfterLifecycleFailure(
        process: any ManagedProcess,
        identity: ManagedProcessIdentity,
        failure: ManagedProcessError,
        observation: ObservationContext
    ) async {
        let ownership = await process.ownership(for: identity)
        guard observationIsCurrent(observation),
              let operation = beginObservationOperation(observation)
        else {
            return
        }
        defer { endOperation(operation) }
        if ownership == .directChild {
            do {
                let signalled = try await process.signal(.kill, ifMatching: identity)
                guard isCurrent(operation) else { return }
                if signalled {
                    _ = try await process.waitForExit(matching: identity, timeout: forcedTerminationTimeout)
                    guard isCurrent(operation) else { return }
                }
            } catch {
                if isCurrent(operation) { fail(with: error) }
                return
            }
        }
        if isCurrent(operation) { fail(with: failure) }
    }

    private func transition(to next: RuntimePhase) throws {
        let state = try RuntimeState(phase: snapshot.phase).transitioning(to: next)
        updateSnapshot(RuntimeSnapshot(
            uncheckedPhase: state.phase,
            processIdentity: snapshot.processIdentity,
            loopbackPort: snapshot.loopbackPort,
            restartCount: snapshot.restartCount,
            lastHealthResult: snapshot.lastHealthResult,
            diagnosticLogDirectory: snapshot.diagnosticLogDirectory,
            lastError: snapshot.lastError
        ))
    }

    private func waitForListenerDisappearance() async -> LoopbackListenerPresence {
        var lastPresence: LoopbackListenerPresence = .indeterminate(.timeout)
        for attempt in 0..<listenerVerificationAttempts {
            lastPresence = await listenerChecker.presence(on: loopbackPort)
            if lastPresence == .absent { return .absent }
            if attempt + 1 < listenerVerificationAttempts {
                try? await sleep(listenerVerificationInterval)
            }
        }
        return lastPresence
    }

    private func stopWithoutRuntimeAuthority() async throws -> RuntimeSnapshot {
        let operation = try beginOperationWithoutPublishingTransition(validating: .stopping)
        defer { endOperation(operation) }
        do {
            let listenerPresence = await waitForListenerDisappearance()
            try requireCurrent(operation)
            guard listenerPresence == .absent else {
                throw RuntimeStateError.shutdownIncomplete(
                    processAlive: false,
                    listenerPresence: listenerPresence
                )
            }
            replaceManagedProcess(with: nil)
            return stoppedSnapshot()
        } catch {
            if isCurrent(operation) { fail(with: error) }
            throw error
        }
    }

    private func stoppedSnapshot() -> RuntimeSnapshot {
        updateSnapshot(RuntimeSnapshot(
            uncheckedPhase: .stopped,
            processIdentity: nil,
            loopbackPort: nil,
            restartCount: snapshot.restartCount,
            lastHealthResult: snapshot.lastHealthResult,
            diagnosticLogDirectory: snapshot.diagnosticLogDirectory,
            lastError: nil
        ))
        return snapshot
    }

    private func fail(with error: any Error) {
        replaceManagedProcess(with: nil)
        updateSnapshot(RuntimeSnapshot(
            uncheckedPhase: .failed,
            processIdentity: nil,
            loopbackPort: nil,
            restartCount: snapshot.restartCount,
            lastHealthResult: snapshot.lastHealthResult,
            diagnosticLogDirectory: snapshot.diagnosticLogDirectory ?? configuration.logsDirectory,
            lastError: String(describing: error)
        ))
    }

    private func beginOperation(transitioningTo phase: RuntimePhase) throws -> OperationToken {
        guard activeOperation == nil else {
            throw RuntimeStateError.invalidTransition(from: snapshot.phase, to: phase)
        }
        nextOperationValue &+= 1
        let operation = OperationToken(value: nextOperationValue)
        activeOperation = operation
        do {
            try transition(to: phase)
            return operation
        } catch {
            activeOperation = nil
            throw error
        }
    }

    private func beginObservationOperation(_ observation: ObservationContext) -> OperationToken? {
        guard activeOperation == nil, observationIsCurrent(observation) else { return nil }
        nextOperationValue &+= 1
        let operation = OperationToken(value: nextOperationValue)
        activeOperation = operation
        return operation
    }

    private func beginOperationWithoutPublishingTransition(
        validating phase: RuntimePhase
    ) throws -> OperationToken {
        guard activeOperation == nil else {
            throw RuntimeStateError.invalidTransition(from: snapshot.phase, to: phase)
        }
        _ = try RuntimeState(phase: snapshot.phase).transitioning(to: phase)
        nextOperationValue &+= 1
        let operation = OperationToken(value: nextOperationValue)
        activeOperation = operation
        return operation
    }

    private func endOperation(_ operation: OperationToken) {
        if activeOperation == operation { activeOperation = nil }
    }

    private func cancelSupervision() {
        nextSupervisionValue &+= 1
        activeSupervision = nil
        healthySince = nil
    }

    private func supervisionIsCurrent(_ supervision: UInt64) -> Bool {
        activeSupervision == supervision
    }

    private func isCurrent(_ operation: OperationToken) -> Bool {
        activeOperation == operation
    }

    private func requireCurrent(_ operation: OperationToken) throws {
        guard isCurrent(operation) else { throw CancellationError() }
    }

    private func observationContext(
        phase: RuntimePhase,
        identity: ManagedProcessIdentity
    ) -> ObservationContext {
        ObservationContext(
            stateGeneration: stateGeneration,
            processGeneration: processGeneration,
            phase: phase,
            identity: identity
        )
    }

    private func observationIsCurrent(_ observation: ObservationContext) -> Bool {
        activeOperation == nil
            && stateGeneration == observation.stateGeneration
            && processGeneration == observation.processGeneration
            && snapshot.phase == observation.phase
            && snapshot.processIdentity == observation.identity
    }

    private func updateSnapshot(_ nextSnapshot: RuntimeSnapshot) {
        precondition(nextSnapshot.structuralValidationError == nil)
        snapshot = nextSnapshot
        stateGeneration &+= 1
    }

    private func replaceManagedProcess(with process: (any ManagedProcess)?) {
        managedProcess = process
        processGeneration &+= 1
    }
}
