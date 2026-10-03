import Foundation
import Testing
@testable import InboxPlusRuntime

@Test func startupPollsEveryHalfSecondAndFailsAtThirtySeconds() async throws {
    // Break caught: startup polls without the approved cadence or waits forever for a degraded endpoint.
    let health = RecoveryHealthChecker(results: Array(
        repeating: .degraded(.versionsRequestFailed(status: 503)),
        count: 80
    ))
    let clock = TestMonotonicClock()
    let fixture = RecoverySupervisorFixture(
        processCount: 1,
        health: health,
        clock: clock,
        pollSleep: { duration in await clock.advance(by: duration) }
    )

    await #expect(throws: SynapseSupervisorError.startupHealthTimeout(
        .versionsRequestFailed(status: 503)
    )) {
        try await fixture.supervisor.start()
    }

    #expect(await clock.sleeps() == Array(repeating: .milliseconds(500), count: 60))
    #expect(await fixture.processes[0].metrics().waitCalls == 1)
    #expect(await fixture.supervisor.status().phase == .failed)
}

@Test func fourthCrashEntersFailedWithoutRelaunch() async throws {
    // Break caught: recovery is unbounded or the fourth crash launches a fifth child.
    let health = RecoveryHealthChecker(results: [
        .healthy(latency: .milliseconds(1)), // initial start
        .stopped,
        .healthy(latency: .milliseconds(1)),
        .stopped,
        .healthy(latency: .milliseconds(1)),
        .stopped,
        .healthy(latency: .milliseconds(1)),
        .stopped,
    ])
    let delays = DurationRecorder()
    let fixture = RecoverySupervisorFixture(
        processCount: 4,
        health: health,
        recoverySleep: { duration in await delays.record(duration) },
        pollSleep: { _ in }
    )

    _ = try await fixture.supervisor.start()
    await fixture.supervisor.supervise()

    let snapshot = await fixture.supervisor.status()
    #expect(snapshot.phase == .failed)
    #expect(snapshot.restartCount == 3)
    #expect(await fixture.totalLaunchCalls() == 4)
    #expect(await delays.values() == [.seconds(1), .seconds(2), .seconds(4)])
}

@Test func sixtyHealthySecondsResetTheConsecutiveCrashCount() async throws {
    // Break caught: an old crash permanently consumes restart budget after a stable recovery.
    let health = RecoveryHealthChecker(results: [
        .healthy(latency: .milliseconds(1)),
        .stopped,
        .healthy(latency: .milliseconds(1)),
        .healthy(latency: .milliseconds(1)),
        .stopped,
        .healthy(latency: .milliseconds(1)),
        .stopped,
        .healthy(latency: .milliseconds(1)),
        .stopped,
        .healthy(latency: .milliseconds(1)),
        .stopped,
    ])
    let clock = TestMonotonicClock()
    let delays = DurationRecorder()
    let fixture = RecoverySupervisorFixture(
        processCount: 5,
        health: health,
        clock: clock,
        recoverySleep: { duration in await delays.record(duration) },
        pollSleep: { duration in await clock.advance(by: duration == .zero ? .seconds(60) : duration) },
        healthPollInterval: .seconds(60)
    )

    _ = try await fixture.supervisor.start()
    await fixture.supervisor.supervise()

    #expect(await delays.values().prefix(2) == [.seconds(1), .seconds(1)])
    #expect(await fixture.totalLaunchCalls() == 5)
    #expect(await fixture.supervisor.status().phase == .failed)
}

@Test func userStopDuringRecoveryDelaySuppressesRelaunch() async throws {
    // Break caught: a delayed recovery wakes after an explicit stop and relaunches behind the user's back.
    let health = RecoveryHealthChecker(results: [
        .healthy(latency: .milliseconds(1)),
        .stopped,
    ])
    let gate = RecoverySleepGate()
    let fixture = RecoverySupervisorFixture(
        processCount: 2,
        health: health,
        recoverySleep: { duration in await gate.sleep(duration) },
        pollSleep: { _ in }
    )

    _ = try await fixture.supervisor.start()
    let supervision = Task { await fixture.supervisor.supervise() }
    try await gate.waitUntilSleeping()

    #expect(try await fixture.supervisor.stop().phase == .stopped)
    await gate.release()
    await supervision.value

    #expect(await fixture.totalLaunchCalls() == 1)
    #expect(await fixture.supervisor.status().phase == .stopped)
}

@Test func cancellingSupervisionDuringRecoveryDelaySuppressesRelaunch() async throws {
    // Break caught: task cancellation is swallowed and a recovery child launches anyway.
    let health = RecoveryHealthChecker(results: [
        .healthy(latency: .milliseconds(1)),
        .stopped,
    ])
    let gate = CancellationAwareRecoverySleeper()
    let fixture = RecoverySupervisorFixture(
        processCount: 2,
        health: health,
        recoverySleep: { duration in try await gate.sleep(duration) },
        pollSleep: { _ in }
    )

    _ = try await fixture.supervisor.start()
    let supervision = Task { await fixture.supervisor.supervise() }
    try await gate.waitUntilSleeping()
    supervision.cancel()
    await supervision.value

    #expect(await fixture.totalLaunchCalls() == 1)
    #expect(await fixture.supervisor.status().phase == .recovering)
    #expect(try await fixture.supervisor.stop().phase == .stopped)
}

@Test func concurrentSuperviseCallsDoNotCreateDuplicateRecoveryLoops() async throws {
    // Break caught: two supervision callers each spend restart budget and launch their own replacement.
    let health = RecoveryHealthChecker(results: [
        .healthy(latency: .milliseconds(1)),
        .stopped,
        .healthy(latency: .milliseconds(1)),
        .stopped,
        .healthy(latency: .milliseconds(1)),
        .stopped,
        .healthy(latency: .milliseconds(1)),
        .stopped,
    ])
    let recoveryGate = RecoverySleepGate()
    let fixture = RecoverySupervisorFixture(
        processCount: 4,
        health: health,
        recoverySleep: { duration in
            if duration == .seconds(1) { await recoveryGate.sleep(duration) }
        },
        pollSleep: { _ in }
    )

    _ = try await fixture.supervisor.start()
    let first = Task { await fixture.supervisor.supervise() }
    try await recoveryGate.waitUntilSleeping()
    let second = Task { await fixture.supervisor.supervise() }
    await second.value
    await recoveryGate.release()
    await first.value

    #expect(await fixture.totalLaunchCalls() == 4)
}

@Test func rejectedStartDoesNotCancelTheExistingSupervisionLoop() async throws {
    // Break caught: an invalid duplicate start silently disables crash supervision.
    let healthGate = HealthResultGate()
    let recoveryGate = RecoverySleepGate()
    let health = RecoveryHealthChecker(results: [
        .healthy(latency: .milliseconds(1)),
        .stopped,
    ], gateAtCall: 2, gate: healthGate)
    let fixture = RecoverySupervisorFixture(
        processCount: 2,
        health: health,
        recoverySleep: { duration in await recoveryGate.sleep(duration) },
        pollSleep: { _ in }
    )

    _ = try await fixture.supervisor.start()
    let supervision = Task { await fixture.supervisor.supervise() }
    try await healthGate.waitUntilSuspended()
    await #expect(throws: RuntimeStateError.invalidTransition(from: .healthy, to: .starting)) {
        try await fixture.supervisor.start()
    }
    await healthGate.release()

    try await recoveryGate.waitUntilSleeping()
    #expect(try await fixture.supervisor.stop().phase == .stopped)
    await recoveryGate.release()
    await supervision.value
    #expect(await fixture.totalLaunchCalls() == 1)
}

@Test func staleHealthResultCannotDegradeAReplacementGeneration() async throws {
    // Break caught: a suspended health request from an old process overwrites a stopped-and-restarted generation.
    let gate = HealthResultGate()
    let health = RecoveryHealthChecker(results: [
        .healthy(latency: .milliseconds(1)),
        .degraded(.matrixRequestFailed(status: 401)),
        .healthy(latency: .milliseconds(1)),
    ], gateAtCall: 2, gate: gate)
    let fixture = RecoverySupervisorFixture(processCount: 2, health: health)

    _ = try await fixture.supervisor.start()
    let staleStatus = Task { await fixture.supervisor.status() }
    try await gate.waitUntilSuspended()
    #expect(try await fixture.supervisor.stop().phase == .stopped)
    #expect(try await fixture.supervisor.start().phase == .healthy)
    await gate.release()

    #expect(await staleStatus.value.phase == .healthy)
    #expect(await fixture.supervisor.status().phase == .healthy)
    #expect(await fixture.processes[1].metrics().signals.isEmpty)
    _ = try await fixture.supervisor.stop()
}

private struct RecoverySupervisorFixture {
    let processes: [RecoveryManagedProcess]
    let supervisor: SynapseSupervisor

    init(
        processCount: Int,
        health: RecoveryHealthChecker,
        clock: TestMonotonicClock = TestMonotonicClock(),
        recoverySleep: @escaping SynapseSupervisor.Sleep = { _ in },
        pollSleep: @escaping SynapseSupervisor.Sleep = { _ in },
        healthPollInterval: Duration = .milliseconds(500)
    ) {
        processes = (0..<processCount).map { RecoveryManagedProcess(index: $0) }
        supervisor = SynapseSupervisor(
            configuration: recoveryManagedProcessConfiguration(),
            loopbackPort: 18_008,
            processFactory: RecoveryProcessFactory(processes: processes),
            listenerChecker: RecoveryListenerChecker(),
            healthChecker: health,
            listenerVerificationAttempts: 1,
            listenerVerificationInterval: .zero,
            startupPollInterval: .milliseconds(500),
            startupTimeout: .seconds(30),
            healthPollInterval: healthPollInterval,
            healthyResetInterval: .seconds(60),
            sleep: { _ in },
            pollSleep: pollSleep,
            recoverySleep: recoverySleep,
            now: { await clock.now() }
        )
    }

    func totalLaunchCalls() async -> Int {
        var result = 0
        for process in processes { result += await process.metrics().launchCalls }
        return result
    }
}

private actor RecoveryHealthChecker: SynapseHealthChecking {
    private var results: [HealthResult]
    private var callCount = 0
    private let gateAtCall: Int?
    private let gate: HealthResultGate?

    init(results: [HealthResult], gateAtCall: Int? = nil, gate: HealthResultGate? = nil) {
        self.results = results
        self.gateAtCall = gateAtCall
        self.gate = gate
    }

    func check(snapshot: RuntimeSnapshot) async -> HealthResult {
        callCount += 1
        if callCount == gateAtCall, let gate { await gate.suspend() }
        guard !results.isEmpty else { return .healthy(latency: .milliseconds(1)) }
        return results.removeFirst()
    }
}

private actor RecoveryManagedProcess: ManagedProcess {
    struct Metrics: Sendable {
        var launchCalls = 0
        var signals: [ManagedProcessSignal] = []
        var waitCalls = 0
    }

    private let identity: ManagedProcessIdentity
    private var running = false
    private var state = Metrics()

    init(index: Int) {
        identity = ManagedProcessIdentity(
            executablePath: "/opt/inboxplus/synapse_homeserver",
            launchTimestamp: Date(timeIntervalSince1970: 1_789_000_000 + Double(index)),
            processIdentifier: Int32(42 + index),
            startIdentityToken: "\(42 + index):\(index)"
        )
    }

    func launch() async throws -> ManagedProcessIdentity {
        state.launchCalls += 1
        running = true
        return identity
    }

    func identityStatus(for expected: ManagedProcessIdentity) async -> ManagedProcessIdentityStatus {
        guard running else { return .exited }
        return expected == identity ? .matching : .mismatched(actual: identity)
    }

    func ownership(for expected: ManagedProcessIdentity) async -> ManagedProcessOwnership {
        expected == identity ? .directChild : .observedOnly
    }

    func signal(
        _ signal: ManagedProcessSignal,
        ifMatching expected: ManagedProcessIdentity
    ) async throws -> Bool {
        guard running, expected == identity else { return false }
        state.signals.append(signal)
        running = false
        return true
    }

    func waitForExit(
        matching expected: ManagedProcessIdentity,
        timeout: Duration
    ) async throws -> Bool {
        state.waitCalls += 1
        running = false
        return true
    }

    func metrics() -> Metrics { state }
}

private final class RecoveryProcessFactory: ManagedProcessFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let processes: [RecoveryManagedProcess]
    private var index = 0

    init(processes: [RecoveryManagedProcess]) { self.processes = processes }

    func make(_ configuration: ManagedProcessConfiguration) throws -> any ManagedProcess {
        lock.lock()
        defer { lock.unlock() }
        guard index < processes.count else { throw RecoveryTestError.noProcess }
        defer { index += 1 }
        return processes[index]
    }

    func rehydrate(
        _ configuration: ManagedProcessConfiguration,
        expectedIdentity: ManagedProcessIdentity
    ) throws -> any ManagedProcess {
        lock.lock()
        defer { lock.unlock() }
        guard index > 0 else { throw RecoveryTestError.noProcess }
        return processes[index - 1]
    }
}

private struct RecoveryListenerChecker: LoopbackListenerChecking {
    func presence(on port: UInt16) async -> LoopbackListenerPresence { .absent }
}

private actor TestMonotonicClock {
    private var instant: Duration = .zero
    private var recordedSleeps: [Duration] = []

    func now() -> Duration { instant }
    func advance(by duration: Duration) {
        recordedSleeps.append(duration)
        instant += duration
    }
    func sleeps() -> [Duration] { recordedSleeps }
}

private actor DurationRecorder {
    private var recorded: [Duration] = []
    func record(_ duration: Duration) { recorded.append(duration) }
    func values() -> [Duration] { recorded }
}

private actor RecoverySleepGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var sleeping = false

    func sleep(_ duration: Duration) async {
        sleeping = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSleeping() async throws {
        for _ in 0..<2_000 {
            if sleeping { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw RecoveryTestError.deadline
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CancellationAwareRecoverySleeper {
    private var sleeping = false

    func sleep(_ duration: Duration) async throws {
        sleeping = true
        try await Task.sleep(for: .seconds(60))
    }

    func waitUntilSleeping() async throws {
        for _ in 0..<2_000 {
            if sleeping { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw RecoveryTestError.deadline
    }
}

private actor HealthResultGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspended = false

    func suspend() async {
        suspended = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async throws {
        for _ in 0..<2_000 {
            if suspended { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw RecoveryTestError.deadline
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum RecoveryTestError: Error {
    case noProcess
    case deadline
}

private func recoveryManagedProcessConfiguration() -> ManagedProcessConfiguration {
    ManagedProcessConfiguration(
        executable: URL(fileURLWithPath: "/opt/inboxplus/synapse_homeserver"),
        arguments: [],
        environment: [:],
        workingDirectory: URL(fileURLWithPath: "/tmp"),
        profileRoot: URL(fileURLWithPath: "/tmp"),
        logsDirectory: URL(fileURLWithPath: "/tmp/logs"),
        standardOutputLog: URL(fileURLWithPath: "/tmp/logs/stdout.log"),
        standardErrorLog: URL(fileURLWithPath: "/tmp/logs/stderr.log")
    )
}
