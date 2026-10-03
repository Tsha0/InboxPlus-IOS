import Foundation
import Darwin
import Testing
@testable import InboxPlusRuntime

@Test func userStopTransitionsHealthyToStoppedWithoutRestart() async throws {
    // Break caught: a user stop relaunches Synapse or omits graceful termination.
    let fixture = SupervisorFixture()
    _ = try await fixture.supervisor.start()
    let stopped = try await fixture.supervisor.stop()
    let metrics = await fixture.process.metrics()

    #expect(stopped.phase == .stopped)
    #expect(stopped.processIdentity == nil)
    #expect(metrics.launchCalls == 1)
    #expect(metrics.signals == [.terminate])
}

@Test func startFromStartingIsRejectedDuringConcurrentLaunch() async throws {
    // Break caught: actor reentrancy launches a second process while the first launch is suspended.
    let launchGate = AsyncGate()
    let fixture = SupervisorFixture(launchGate: launchGate)
    let firstStart = Task { try await fixture.supervisor.start() }
    await waitForPhase(.starting, supervisor: fixture.supervisor)

    await #expect(throws: RuntimeStateError.invalidTransition(from: .starting, to: .starting)) {
        try await fixture.supervisor.start()
    }

    await launchGate.open()
    _ = try await firstStart.value
    _ = try await fixture.supervisor.stop()
    #expect(await fixture.process.metrics().launchCalls == 1)
}

@Test func concurrentStopCannotSignalTheSameIdentityTwice() async throws {
    // Break caught: reentrant stop requests both signal one child or race shutdown state.
    let waitGate = AsyncGate()
    let fixture = SupervisorFixture(waitGate: waitGate)
    _ = try await fixture.supervisor.start()
    let firstStop = Task { try await fixture.supervisor.stop() }
    await waitForPhase(.stopping, supervisor: fixture.supervisor)

    await #expect(throws: RuntimeStateError.invalidTransition(from: .stopping, to: .stopping)) {
        try await fixture.supervisor.stop()
    }

    await waitGate.open()
    _ = try await firstStop.value
    #expect(await fixture.process.metrics().signals == [.terminate])
}

@Test func stopDuringSuspendedLaunchIsRejectedWithoutCorruptingLaunch() async throws {
    // Break caught: stop reenters the actor during launch, loses the pending child identity, and strands the process.
    let launchGate = AsyncGate()
    let fixture = SupervisorFixture(launchGate: launchGate)
    let start = Task { try await fixture.supervisor.start() }
    await waitForPhase(.starting, supervisor: fixture.supervisor)

    await #expect(throws: RuntimeStateError.invalidTransition(from: .starting, to: .stopping)) {
        try await fixture.supervisor.stop()
    }

    await launchGate.open()
    #expect(try await start.value.phase == .healthy)
    #expect(try await fixture.supervisor.stop().phase == .stopped)
}

@Test func stopDuringSuspendedStartLifecycleProbeCannotSupersedeStartup() async throws {
    // Break caught: start loses its operation ownership while checking post-launch lifecycle I/O.
    let fixture = SupervisorFixture()
    let gate = AsyncGate()
    await fixture.process.configureLifecycleFailure(nil, gate: gate)
    let start = Task { try await fixture.supervisor.start() }
    try await gate.waitForWaiter()

    await #expect(throws: RuntimeStateError.invalidTransition(from: .starting, to: .stopping)) {
        try await fixture.supervisor.stop()
    }
    await gate.open()

    #expect(try await start.value.phase == .healthy)
    #expect(try await fixture.supervisor.stop().phase == .stopped)
    #expect(await fixture.process.metrics().signals == [.terminate])
}

@Test func processIdentityMismatchNeverReceivesAnySignal() async throws {
    // Break caught: a reused PID is terminated despite a different executable/start token.
    let fixture = SupervisorFixture()
    _ = try await fixture.supervisor.start()
    await fixture.process.replaceCurrentIdentity(with: .replacement)

    await #expect(throws: RuntimeStateError.processIdentityMismatch(
        expected: .expected,
        actual: .replacement
    )) {
        try await fixture.supervisor.stop()
    }

    #expect(await fixture.process.metrics().signals.isEmpty)
    #expect(await fixture.supervisor.status().phase == .failed)
}

@Test func indeterminateProcessIdentityNeverReceivesAnySignal() async throws {
    // Break caught: a failed process probe is treated as an exited or matching child and permits signalling.
    let fixture = SupervisorFixture()
    _ = try await fixture.supervisor.start()
    let failure = ManagedProcessError.childWaitFailed(code: EIO)
    await fixture.process.setIdentityStatusOverride(.indeterminate(failure))

    await #expect(throws: failure) {
        try await fixture.supervisor.stop()
    }

    #expect(await fixture.process.metrics().signals.isEmpty)
    #expect(await fixture.supervisor.status().phase == .failed)
}

@Test func statusDoesNotReportHealthyAfterProcessIdentityChanges() async throws {
    // Break caught: status trusts persisted PID metadata and reports a replacement process as healthy.
    let fixture = SupervisorFixture()
    _ = try await fixture.supervisor.start()
    await fixture.process.replaceCurrentIdentity(with: .replacement)

    let snapshot = await fixture.supervisor.status()

    #expect(snapshot.phase == .failed)
    #expect(snapshot.processIdentity == nil)
    #expect(snapshot.loopbackPort == nil)
    #expect(await fixture.process.metrics().signals.isEmpty)
}

@Test func suspendedLifecycleFailureProbeCannotOverwriteNewerStoppedState() async throws {
    // Break caught: status resumes a stale failure probe and overwrites a stop that completed meanwhile.
    let fixture = SupervisorFixture()
    _ = try await fixture.supervisor.start()
    let gate = AsyncGate()
    await fixture.process.configureLifecycleFailure(
        .logFailure(operation: "stale lifecycle probe", code: EIO),
        gate: gate
    )
    let status = Task { await fixture.supervisor.status() }
    try await gate.waitForWaiter()

    #expect(try await fixture.supervisor.stop().phase == .stopped)
    await gate.open()

    #expect(await status.value.phase == .stopped)
    #expect(await fixture.supervisor.status().phase == .stopped)
    #expect(await fixture.process.metrics().signals == [.terminate])
}

@Test func suspendedOwnershipProbeCannotOverwriteNewerStoppedState() async throws {
    // Break caught: lifecycle cleanup resumes stale ownership and fails or signals after stop has won.
    let fixture = SupervisorFixture()
    _ = try await fixture.supervisor.start()
    let gate = AsyncGate()
    await fixture.process.configureLifecycleFailure(
        .logFailure(operation: "ownership probe", code: EIO),
        gate: nil
    )
    await fixture.process.suspendNextOwnership(on: gate)
    let status = Task { await fixture.supervisor.status() }
    try await gate.waitForWaiter()

    #expect(try await fixture.supervisor.stop().phase == .stopped)
    await gate.open()

    #expect(await status.value.phase == .stopped)
    #expect(await fixture.supervisor.status().phase == .stopped)
    #expect(await fixture.process.metrics().signals == [.terminate])
}

private enum ABASuspensionPoint: Sendable, CaseIterable {
    case lifecycleFailure
    case ownership
}

@Test(arguments: ABASuspensionPoint.allCases)
private func staleStatusProbeCannotAffectRestartedProcessWithReusedIdentity(
    suspensionPoint: ABASuspensionPoint
) async throws {
    // Break caught: phase/PID/token ABA fools a stale probe after stop replaces the managed process instance.
    let oldProcess = FakeManagedProcess(
        launchGate: nil,
        waitGate: nil,
        exitOnTerminate: true,
        replaceIdentityAfterFirstWait: false,
        launchFails: false
    )
    let newProcess = FakeManagedProcess(
        launchGate: nil,
        waitGate: nil,
        exitOnTerminate: true,
        replaceIdentityAfterFirstWait: false,
        launchFails: false
    )
    let supervisor = SynapseSupervisor(
        configuration: fakeManagedProcessConfiguration(),
        loopbackPort: 18_008,
        processFactory: SequencedFakeManagedProcessFactory(processes: [oldProcess, newProcess]),
        listenerChecker: FakeListenerChecker(responses: [false, false]),
        healthChecker: LifecycleHealthyChecker(),
        listenerVerificationAttempts: 1,
        listenerVerificationInterval: .zero,
        sleep: { _ in }
    )
    _ = try await supervisor.start()
    let gate = AsyncGate()
    await oldProcess.configureLifecycleFailure(
        .logFailure(operation: "old process status probe", code: EIO),
        gate: suspensionPoint == .lifecycleFailure ? gate : nil
    )
    if suspensionPoint == .ownership {
        await oldProcess.suspendNextOwnership(on: gate)
    }
    let staleStatus = Task { await supervisor.status() }
    try await gate.waitForWaiter()

    #expect(try await supervisor.stop().phase == .stopped)
    let restarted = try await supervisor.start()
    #expect(restarted.phase == .healthy)
    #expect(restarted.processIdentity == .expected)
    await gate.open()

    let staleResult = await staleStatus.value
    #expect(staleResult.phase == .healthy)
    #expect(staleResult.processIdentity == .expected)
    #expect(await oldProcess.metrics().signals == [.terminate])
    #expect(await newProcess.metrics().signals.isEmpty)
    #expect(await supervisor.status().phase == .healthy)

    #expect(try await supervisor.stop().phase == .stopped)
    #expect(await newProcess.metrics().signals == [.terminate])
}

@Test(arguments: [RuntimePhase.healthy, .degraded])
func publicConstructionRejectsActiveSnapshotWithoutIdentity(phase: RuntimePhase) async {
    // Break caught: persisted running metadata without a process identity is reported healthy/degraded.
    #expect(throws: RuntimeStateError.self) {
        try RuntimeSnapshot(
            phase: phase,
            processIdentity: nil,
            loopbackPort: 18_008,
            restartCount: 0,
            lastHealthResult: nil,
            diagnosticLogDirectory: nil,
            lastError: nil
        )
    }
}

@Test(arguments: [RuntimePhase.stopped, .unprepared])
func publicConstructionRejectsInactiveSnapshotWithRuntimeMetadata(
    phase: RuntimePhase
) async {
    // Break caught: stale PID/listener metadata in an inactive phase is trusted or silently discarded.
    #expect(throws: RuntimeStateError.self) {
        try RuntimeSnapshot(
            phase: phase,
            processIdentity: .expected,
            loopbackPort: 18_008,
            restartCount: 0,
            lastHealthResult: nil,
            diagnosticLogDirectory: nil,
            lastError: nil
        )
    }
}

@Test func supervisorQuarantinesInternallyMalformedPersistedSnapshotWithoutSignalAuthority() async {
    // Break caught: a malformed value reaching the supervisor bypasses public/decoding validation.
    let corrupt = RuntimeSnapshot(
        uncheckedPhase: .healthy,
        processIdentity: nil,
        loopbackPort: 18_008,
        restartCount: -1,
        lastHealthResult: nil,
        diagnosticLogDirectory: nil,
        lastError: nil
    )
    let fixture = SupervisorFixture(initialSnapshot: corrupt)

    let quarantined = await fixture.supervisor.status()
    #expect(quarantined.phase == .failed)
    #expect(quarantined.processIdentity == nil)
    #expect(quarantined.loopbackPort == nil)
    #expect(quarantined.restartCount == 0)
    #expect(quarantined.lastError?.contains("invalidSnapshot") == true)
    #expect(await fixture.process.metrics().signals.isEmpty)
}

@Test func rehydratedStatusRejectsAStalePersistedIdentity() async {
    // Break caught: a new supervisor trusts persisted healthy state without revalidating its process identity.
    let fixture = SupervisorFixture(
        initialSnapshot: .persistedHealthy,
        initialProcessIdentity: .replacement
    )

    #expect(await fixture.supervisor.status().phase == .failed)
    #expect(await fixture.process.metrics().signals.isEmpty)
}

@Test func rehydratedMatchingProcessIsNotReportedHealthyWithoutOwnership() async {
    // Break caught: a new supervisor treats an observed-but-unowned matching PID as controllable healthy state.
    let fixture = SupervisorFixture(
        initialSnapshot: .persistedHealthy,
        initialProcessIdentity: .expected
    )

    #expect(await fixture.supervisor.status().phase == .degraded)
    #expect(await fixture.process.metrics().signals.isEmpty)
}

@Test func rehydratedMatchingProcessIsNeverSignalledByANewSupervisor() async {
    // Break caught: stop uses a matching persisted PID as authority even though this supervisor does not own the child.
    let fixture = SupervisorFixture(
        initialSnapshot: .persistedHealthy,
        initialProcessIdentity: .expected
    )

    await #expect(throws: RuntimeStateError.uncontrolledProcess(.expected)) {
        try await fixture.supervisor.stop()
    }
    #expect(await fixture.process.metrics().signals.isEmpty)
}

@Test func failedLaunchCanBeStoppedAndRetriedAfterChildCleanup() async throws {
    // Break caught: a failed launch leaves the supervisor terminally failed with no safe path back to stopped.
    let fixture = SupervisorFixture(launchFails: true)

    await #expect(throws: FakeProcessError.launchFailed) {
        try await fixture.supervisor.start()
    }
    #expect(await fixture.supervisor.status().phase == .failed)
    #expect(try await fixture.supervisor.stop().phase == .stopped)

    await fixture.process.setLaunchFailure(false)
    #expect(try await fixture.supervisor.start().phase == .healthy)
    #expect(try await fixture.supervisor.stop().phase == .stopped)
}

@Test func gracefulTimeoutEscalatesOnlyAfterReverifyingIdentity() async throws {
    // Break caught: timeout never escalates, or forced termination is sent without a second identity check.
    let fixture = SupervisorFixture(exitOnTerminate: false)
    _ = try await fixture.supervisor.start()

    #expect(try await fixture.supervisor.stop().phase == .stopped)
    let metrics = await fixture.process.metrics()
    #expect(metrics.signals == [.terminate, .kill])
    #expect(metrics.identityChecks >= 4)
}

@Test func identityChangeDuringGracefulWaitPreventsEscalation() async throws {
    // Break caught: forced termination targets a replacement process that appeared after SIGTERM.
    let fixture = SupervisorFixture(exitOnTerminate: false, replaceIdentityAfterFirstWait: true)
    _ = try await fixture.supervisor.start()

    await #expect(throws: RuntimeStateError.processIdentityMismatch(
        expected: .expected,
        actual: .replacement
    )) {
        try await fixture.supervisor.stop()
    }

    #expect(await fixture.process.metrics().signals == [.terminate])
}

@Test func listenerStillPresentAfterProcessExitFailsShutdown() async throws {
    // Break caught: shutdown reports stopped while the associated loopback listener remains reachable.
    let listener = FakeListenerChecker(responses: [true, true, true])
    let fixture = SupervisorFixture(listener: listener, listenerVerificationAttempts: 3)
    _ = try await fixture.supervisor.start()

    await #expect(throws: RuntimeStateError.shutdownIncomplete(
        processAlive: false,
        listenerPresence: .present
    )) {
        try await fixture.supervisor.stop()
    }

    #expect(await fixture.supervisor.status().phase == .failed)
    #expect(await listener.checkCount() == 3)
}

@Test func indeterminateListenerCheckNeverPermitsStoppedState() async throws {
    // Break caught: socket/fd/timeout errors are treated as proof that the loopback listener is absent.
    let listener = FakeListenerChecker(presences: [
        .indeterminate(.systemError(operation: "socket", code: EMFILE)),
    ])
    let fixture = SupervisorFixture(listener: listener, listenerVerificationAttempts: 1)
    _ = try await fixture.supervisor.start()

    await #expect(throws: RuntimeStateError.shutdownIncomplete(
        processAlive: false,
        listenerPresence: .indeterminate(.systemError(operation: "socket", code: EMFILE))
    )) {
        try await fixture.supervisor.stop()
    }
    #expect(await fixture.supervisor.status().phase == .failed)
}

@Test func repeatedStartStopCyclesCreateOneProcessPerCycle() async throws {
    // Break caught: stopped state retains stale identity or reuses a prior launch without making a new child.
    let fixture = SupervisorFixture()
    _ = try await fixture.supervisor.start()
    _ = try await fixture.supervisor.stop()
    _ = try await fixture.supervisor.start()
    _ = try await fixture.supervisor.stop()

    let metrics = await fixture.process.metrics()
    #expect(metrics.launchCalls == 2)
    #expect(metrics.signals == [.terminate, .terminate])
}

@Test func boundedLogWriterRotatesWithoutExceedingPerFileLimit() throws {
    // Break caught: a large output chunk bypasses rotation and grows a profile log without bound.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusBoundedLogTests")
    defer { fixture.remove() }
    let log = fixture.logs.appendingPathComponent("stdout.log")
    let writer = try BoundedRotatingLog(file: log, maximumBytesPerFile: 8, retainedFileCount: 3)

    try writer.append(Data("abcdefghijklmnopqrst".utf8))

    let files = try FileManager.default.contentsOfDirectory(at: fixture.logs, includingPropertiesForKeys: [.fileSizeKey])
    #expect(Set(files.map(\.lastPathComponent)) == ["stdout.log", "stdout.log.1", "stdout.log.2"])
    for file in files {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        #expect((values.fileSize ?? 0) <= 8)
    }
    #expect(try Data(contentsOf: log) == Data("qrst".utf8))
}

@Test func boundedLogWriterNormalizesOversizedExistingGenerations() throws {
    // Break caught: an oversized log from a prior crash remains unbounded after the writer takes ownership.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusExistingLogTests")
    defer { fixture.remove() }
    let log = fixture.logs.appendingPathComponent("stdout.log")
    try Data(repeating: 1, count: 32).write(to: log)
    let rotated = fixture.logs.appendingPathComponent("stdout.log.1")
    try Data(repeating: 2, count: 24).write(to: rotated)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rotated.path)

    _ = try BoundedRotatingLog(file: log, maximumBytesPerFile: 8, retainedFileCount: 2)

    for file in [log, rotated] {
        #expect((try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8)
    }
}

@Test func logSetupRejectsSymlinkedDirectoryWithoutChangingExternalPermissions() throws {
    // Break caught: log setup follows a symlink and chmods an attacker-selected external directory.
    let root = try canonicalTemporaryDirectory()
        .appendingPathComponent("InboxPlusLogSymlinkTests-\(UUID().uuidString)", isDirectory: true)
    let profile = root.appendingPathComponent("profile", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
    let outsideLogs = outside.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideLogs, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outsideLogs.path)
    try FileManager.default.createSymbolicLink(
        at: profile.appendingPathComponent("redirect", isDirectory: true),
        withDestinationURL: outside
    )
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: (any Error).self) {
        try FoundationManagedProcessFactory().make(ManagedProcessConfiguration(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["1"],
            environment: [:],
            workingDirectory: profile,
            profileRoot: profile,
            logsDirectory: profile.appendingPathComponent("redirect/logs"),
            standardOutputLog: profile.appendingPathComponent("redirect/logs/stdout.log"),
            standardErrorLog: profile.appendingPathComponent("redirect/logs/stderr.log")
        ))
    }
    #expect(try fileMode(outsideLogs) == 0o755)
}

@Test func logWriterRejectsProfileAncestorReplacementBeforeWriting() async throws {
    // Break caught: retained descriptors continue writing after the configured profile path is replaced.
    let root = try canonicalTemporaryDirectory()
        .appendingPathComponent("InboxPlusLogSwapTests-\(UUID().uuidString)", isDirectory: true)
    let profile = root.appendingPathComponent("profile", isDirectory: true)
    let logs = profile.appendingPathComponent("logs", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
    defer { try? FileManager.default.removeItem(at: root) }
    // The child must not write until the profile has been swapped, or there is nothing for the log
    // writer to reject. A timed sleep makes that a race the machine can lose — it did, on CI, where
    // the swap took longer than the half second the child waited. Widening the sleep would only
    // move the race, and past the `waitForExit` timeout it would make the test pass for the wrong
    // reason, since a timeout throws too. So the child waits for a file this test creates *after*
    // the swap, and the ordering stops depending on speed at all.
    let gate = root.appendingPathComponent("swap-complete")
    let process = try FoundationManagedProcessFactory().make(ManagedProcessConfiguration(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "while [ ! -e \"$1\" ]; do sleep 0.05; done; printf should-not-land", "sh", gate.path],
        environment: [:],
        workingDirectory: profile,
        profileRoot: profile,
        logsDirectory: logs,
        standardOutputLog: logs.appendingPathComponent("stdout.log"),
        standardErrorLog: logs.appendingPathComponent("stderr.log")
    ))
    let identity = try await process.launch()

    try FileManager.default.moveItem(at: profile, to: root.appendingPathComponent("moved-profile"))
    try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: outside)
    FileManager.default.createFile(atPath: gate.path, contents: Data())

    await #expect(throws: (any Error).self) {
        try await process.waitForExit(matching: identity, timeout: .seconds(2))
    }
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("stdout.log").path))
}

@Test func foundationManagedProcessCapturesBoundedOutputAndReleasesChild() async throws {
    // Break caught: the production process adapter leaks pipe resources or bypasses bounded stdout/stderr logs.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusManagedProcessTests")
    defer { fixture.remove() }
    let configuration = ManagedProcessConfiguration(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf 12345678901234567890; printf abcdefghijklmnopqrst >&2; sleep 0.2"],
        environment: ["PATH": "/usr/bin:/bin"],
        workingDirectory: fixture.profile,
        profileRoot: fixture.profile,
        logsDirectory: fixture.logs,
        standardOutputLog: fixture.logs.appendingPathComponent("stdout.log"),
        standardErrorLog: fixture.logs.appendingPathComponent("stderr.log"),
        maximumLogBytesPerFile: 8,
        retainedLogFileCount: 2
    )
    let process = try FoundationManagedProcessFactory().make(configuration)

    let identity = try await process.launch()
    #expect(identity.processIdentifier > 0)
    #expect(!identity.executablePath.isEmpty)
    #expect(!identity.startIdentityToken.isEmpty)
    #expect(try await process.waitForExit(matching: identity, timeout: .seconds(2)))

    try await Task.sleep(for: .milliseconds(50))
    for base in ["stdout.log", "stderr.log"] {
        let files = try FileManager.default.contentsOfDirectory(at: fixture.logs, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix(base) }
        #expect(!files.isEmpty)
        #expect(files.count <= 2)
        for file in files {
            #expect((try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8)
        }
    }
}

@Test func foundationManagedProcessNeverSignalsWhenStartTokenDoesNotMatch() async throws {
    // Break caught: the production adapter signals a live PID after its start token no longer matches metadata.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusIdentitySignalTests")
    defer { fixture.remove() }
    let process = try FoundationManagedProcessFactory().make(ManagedProcessConfiguration(
        executable: URL(fileURLWithPath: "/bin/sleep"),
        arguments: [childLifetimeSeconds],
        environment: [:],
        workingDirectory: fixture.profile,
        profileRoot: fixture.profile,
        logsDirectory: fixture.logs,
        standardOutputLog: fixture.logs.appendingPathComponent("stdout.log"),
        standardErrorLog: fixture.logs.appendingPathComponent("stderr.log")
    ))
    let actual = try await process.launch()
    let stale = ManagedProcessIdentity(
        executablePath: actual.executablePath,
        launchTimestamp: actual.launchTimestamp.addingTimeInterval(-1),
        processIdentifier: actual.processIdentifier,
        startIdentityToken: actual.startIdentityToken + "-stale"
    )

    await #expect(throws: RuntimeStateError.processIdentityMismatch(expected: stale, actual: actual)) {
        try await process.signal(.kill, ifMatching: stale)
    }
    #expect(await process.identityStatus(for: actual) == .matching)

    _ = try await process.signal(.kill, ifMatching: actual)
    #expect(try await process.waitForExit(matching: actual, timeout: .seconds(2)))
}

@Test func foundationManagedProcessNeverSignalsWhenLiveChildIdentityBecomesUnavailable() async throws {
    // Break caught: a failed post-launch identity read is mistaken for exit and authorizes a signal by PID alone.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusUnavailableIdentityTests")
    defer { fixture.remove() }
    let reads = IdentityReadSequence(successfulReadCount: 2)
    var process: (any ManagedProcess)? = try FoundationManagedProcessFactory(
        identityReader: { pid in reads.read(pid) }
    ).make(try managedConfiguration(
        fixture: fixture,
        executable: "/bin/sleep",
        arguments: [childLifetimeSeconds]
    ))
    let identity = try await process!.launch()

    await #expect(throws: ManagedProcessError.processIdentityUnavailable(identity.processIdentifier)) {
        try await process!.signal(.terminate, ifMatching: identity)
    }
    #expect(Darwin.kill(identity.processIdentifier, 0) == 0)

    process = nil
    #expect(await processDisappears(identity.processIdentifier))
}

@Test func foundationManagedProcessRejectsSequentialSecondLaunchAndRetainsFirstChild() async throws {
    // Break caught: a second launch overwrites direct-child ownership and orphans the first PID.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusSequentialLaunchReservationTests")
    defer { fixture.remove() }
    let process = try FoundationManagedProcessFactory().make(try managedConfiguration(
        fixture: fixture,
        executable: "/bin/sleep",
        arguments: [childLifetimeSeconds]
    ))
    let first = try await process.launch()
    var unexpectedSecond: ManagedProcessIdentity?

    do {
        unexpectedSecond = try await process.launch()
        Issue.record("second launch unexpectedly succeeded")
    } catch let error as ManagedProcessError {
        #expect(error == .alreadyLaunched)
    }

    if let unexpectedSecond {
        _ = Darwin.kill(unexpectedSecond.processIdentifier, SIGKILL)
        _ = Darwin.kill(first.processIdentifier, SIGKILL)
        var status: Int32 = 0
        _ = Darwin.waitpid(unexpectedSecond.processIdentifier, &status, 0)
        _ = Darwin.waitpid(first.processIdentifier, &status, 0)
    } else {
        _ = try await process.signal(.kill, ifMatching: first)
        #expect(try await process.waitForExit(matching: first, timeout: .seconds(2)))
    }
}

@Test func foundationManagedProcessReservesConcurrentLaunchBeforeSpawning() async throws {
    // Break caught: two concurrent launch callers both pass an unreserved pre-spawn state.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusConcurrentLaunchReservationTests")
    defer { fixture.remove() }
    let gate = ConcurrentSpawnGate()
    let process = try FoundationManagedProcessFactory(afterSpawn: { pid in
        gate.recordAndBlockFirst(pid)
    }).make(try managedConfiguration(
        fixture: fixture,
        executable: "/bin/sleep",
        arguments: [childLifetimeSeconds]
    ))
    let firstLaunch = Task { try await process.launch() }
    try #require(gate.waitForFirstSpawn() != nil)
    var unexpectedSecond: ManagedProcessIdentity?

    do {
        unexpectedSecond = try await process.launch()
        Issue.record("concurrent launch unexpectedly spawned a second child")
    } catch let error as ManagedProcessError {
        #expect(error == .alreadyLaunched)
    }
    gate.releaseFirst()

    if unexpectedSecond != nil {
        for pid in gate.pids {
            _ = Darwin.kill(pid, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(pid, &status, 0)
        }
        _ = try? await firstLaunch.value
    } else {
        let first = try await firstLaunch.value
        #expect(gate.pids == [first.processIdentifier])
        _ = try await process.signal(.kill, ifMatching: first)
        #expect(try await process.waitForExit(matching: first, timeout: .seconds(2)))
    }
}

@Test func supervisorGracefullyStopsARealFoundationChild() async throws {
    // Break caught: the lifecycle passes with fakes while the production process adapter cannot terminate and reap its child.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusRealSupervisorTests")
    defer { fixture.remove() }
    let supervisor = SynapseSupervisor(
        configuration: ManagedProcessConfiguration(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: [childLifetimeSeconds],
            environment: [:],
            workingDirectory: fixture.profile,
            profileRoot: fixture.profile,
            logsDirectory: fixture.logs,
            standardOutputLog: fixture.logs.appendingPathComponent("stdout.log"),
            standardErrorLog: fixture.logs.appendingPathComponent("stderr.log")
        ),
        loopbackPort: 18_008,
        listenerChecker: FakeListenerChecker(responses: [false]),
        healthChecker: LifecycleHealthyChecker(),
        gracefulTerminationTimeout: .seconds(2),
        forcedTerminationTimeout: .seconds(1),
        listenerVerificationAttempts: 1,
        listenerVerificationInterval: .zero
    )

    let started = try await supervisor.start()
    #expect(started.processIdentity != nil)
    #expect(try await supervisor.stop().phase == .stopped)
}

@Test func directChildPIDRemainsReservedAcrossVerifySignalRace() async throws {
    // Break caught: the child is reaped between identity verification and kill(2), allowing PID reuse to retarget the signal.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusSignalRaceTests")
    defer { fixture.remove() }
    let evidence = SignalRaceEvidence()
    let factory = FoundationManagedProcessFactory(afterIdentityBeforeSignal: { pid in
        _ = Darwin.kill(pid, SIGKILL)
        var information = siginfo_t()
        for _ in 0..<200 {
            if waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) == 0,
               information.si_pid == pid {
                evidence.recordUnreapedChild(pid)
                return
            }
            usleep(1_000)
        }
    })
    let process = try factory.make(try managedConfiguration(
        fixture: fixture,
        executable: "/bin/sleep",
        arguments: [childLifetimeSeconds]
    ))
    let identity = try await process.launch()

    _ = try await process.signal(.terminate, ifMatching: identity)

    #expect(evidence.unreapedPID == identity.processIdentifier)
    #expect(try await process.waitForExit(matching: identity, timeout: .seconds(2)))
}

@Test func cancelledIdentityAcquisitionTerminatesAndReapsSpawnedChild() async throws {
    // Break caught: cancellation after posix_spawn leaves an unidentified child alive and unrecoverable.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusCancelledLaunchTests")
    defer { fixture.remove() }
    let spawn = SpawnEvidence()
    let factory = FoundationManagedProcessFactory(
        identityReader: { _ in nil },
        afterSpawn: { pid in spawn.record(pid) }
    )
    let process = try factory.make(try managedConfiguration(
        fixture: fixture,
        executable: "/bin/sleep",
        arguments: [childLifetimeSeconds]
    ))
    let launch = Task { try await process.launch() }
    try #require(spawn.waitForPID() != nil)

    launch.cancel()
    await #expect(throws: CancellationError.self) { try await launch.value }

    if let pid = spawn.pid {
        #expect(await processDisappears(pid))
    }
}

@Test func identityAcquisitionFailureReapsChildAndAllowsIntentionalRetry() async throws {
    // Break caught: failed identity acquisition strands a child or leaves launch reservation terminally occupied.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusIdentityFailureTests")
    defer { fixture.remove() }
    let spawn = SpawnEvidence()
    let identityReader = ToggleIdentityReader()
    let factory = FoundationManagedProcessFactory(
        identityReader: { pid in identityReader.read(pid) },
        afterSpawn: { pid in spawn.record(pid) }
    )
    let process = try factory.make(try managedConfiguration(
        fixture: fixture,
        executable: "/bin/sleep",
        arguments: [childLifetimeSeconds]
    ))

    do {
        _ = try await process.launch()
        Issue.record("identity acquisition unexpectedly succeeded")
    } catch let error as ManagedProcessError {
        guard case let .launchIdentityUnavailable(pid) = error else {
            Issue.record("unexpected launch error: \(error)")
            return
        }
        #expect(pid == spawn.pid)
    }

    if let pid = spawn.pid {
        #expect(await processDisappears(pid))
    }

    identityReader.enable()
    let retried = try await process.launch()
    _ = try await process.signal(.kill, ifMatching: retried)
    #expect(try await process.waitForExit(matching: retried, timeout: .seconds(2)))
}

@Test func releasingProcessOwnerTerminatesAndReapsItsDirectChild() async throws {
    // Break caught: dropping the last process owner orphans a live runtime child.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusOwnerReleaseTests")
    defer { fixture.remove() }
    var process: (any ManagedProcess)? = try FoundationManagedProcessFactory().make(
        try managedConfiguration(fixture: fixture, executable: "/bin/sleep", arguments: [childLifetimeSeconds])
    )
    let identity = try await process!.launch()

    process = nil

    #expect(await processDisappears(identity.processIdentifier))
}

@Test func outputIsDrainedThroughEOFAndSensitiveValuesAreRedacted() async throws {
    // Break caught: termination drops tail bytes or profile logs expose launch-context credentials.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusLogDrainTests")
    defer { fixture.remove() }
    let configuration = try managedConfiguration(
        fixture: fixture,
        executable: "/bin/sh",
        arguments: [
            "-c",
            "sleep 0.05; printf 'alpha admin-secret env %s omega' \"$ACCESS_TOKEN\"; printf 'stderr token-123 tail' >&2",
        ],
        environment: ["ACCESS_TOKEN": "environment-token"],
        sensitiveLogValues: ["admin-secret", "token-123"]
    )
    let process = try FoundationManagedProcessFactory().make(configuration)
    let identity = try await process.launch()

    #expect(try await process.waitForExit(matching: identity, timeout: .seconds(2)))

    let stdout = try String(contentsOf: configuration.standardOutputLog, encoding: .utf8)
    let stderr = try String(contentsOf: configuration.standardErrorLog, encoding: .utf8)
    #expect(stdout == "alpha [REDACTED] env [REDACTED] omega")
    #expect(stderr == "stderr [REDACTED] tail")
    #expect(!stdout.contains("admin-secret"))
    #expect(!stdout.contains("environment-token"))
    #expect(!stderr.contains("token-123"))
}

@Test func asynchronousLogWriteFailureIsSurfacedAfterExactChildCleanup() async throws {
    // Break caught: output writer errors are discarded while the supervisor continues reporting a live healthy child.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusLogFailureTests")
    defer { fixture.remove() }
    let injected = ManagedProcessError.logFailure(operation: "injected write", code: EIO)
    let factory = FoundationManagedProcessFactory(logWriteHook: { _ in throw injected })
    let trigger = fixture.profile.appendingPathComponent("emit-output")
    let process = try factory.make(try managedConfiguration(
        fixture: fixture,
        executable: "/bin/sh",
        arguments: [
            "-c",
            "while [ ! -e \"$1\" ]; do /bin/sleep 0.01; done; printf trigger; while :; do :; done",
            "inboxplus-log-failure-test",
            trigger.path,
        ]
    ))
    let identity = try await process.launch()
    try Data().write(to: trigger)

    await #expect(throws: injected) {
        try await process.waitForExit(matching: identity, timeout: .seconds(10))
    }
    #expect(await processDisappears(identity.processIdentifier))
}

@Test func supervisorSurfacesAsynchronousLogFailureAndCleansExactChild() async throws {
    // Break caught: the process adapter records a log failure but supervisor status remains healthy.
    let fixture = try SecureProcessDirectories(prefix: "InboxPlusSupervisorLogFailureTests")
    defer { fixture.remove() }
    let injected = ManagedProcessError.logFailure(operation: "injected supervisor write", code: EIO)
    let trigger = fixture.profile.appendingPathComponent("emit-output")
    let configuration = try managedConfiguration(
        fixture: fixture,
        executable: "/bin/sh",
        arguments: [
            "-c",
            "while [ ! -e \"$1\" ]; do /bin/sleep 0.01; done; printf trigger; while :; do :; done",
            "inboxplus-supervisor-log-failure-test",
            trigger.path,
        ]
    )
    let supervisor = SynapseSupervisor(
        configuration: configuration,
        loopbackPort: 18_008,
        processFactory: FoundationManagedProcessFactory(logWriteHook: { _ in throw injected }),
        listenerChecker: FakeListenerChecker(responses: [false]),
        healthChecker: LifecycleHealthyChecker(),
        forcedTerminationTimeout: .seconds(2),
        listenerVerificationAttempts: 1
    )
    let identity = try #require(try await supervisor.start().processIdentity)
    try Data().write(to: trigger)

    for _ in 0..<1_000 where await supervisor.status().phase != .failed {
        try await Task.sleep(for: .milliseconds(10))
    }
    let failed = await supervisor.status()

    #expect(failed.phase == .failed)
    #expect(failed.lastError?.contains("injected supervisor write") == true)
    #expect(await processDisappears(identity.processIdentifier))
}

private func waitForPhase(_ phase: RuntimePhase, supervisor: SynapseSupervisor) async {
    for _ in 0..<100 {
        if await supervisor.status().phase == phase { return }
        await Task.yield()
    }
}

private struct SupervisorFixture {
    let process: FakeManagedProcess
    let supervisor: SynapseSupervisor

    init(
        launchGate: AsyncGate? = nil,
        waitGate: AsyncGate? = nil,
        exitOnTerminate: Bool = true,
        replaceIdentityAfterFirstWait: Bool = false,
        launchFails: Bool = false,
        listener: FakeListenerChecker = FakeListenerChecker(responses: [false]),
        listenerVerificationAttempts: Int = 1,
        initialSnapshot: RuntimeSnapshot = .stopped,
        initialProcessIdentity: ManagedProcessIdentity? = nil
    ) {
        process = FakeManagedProcess(
            launchGate: launchGate,
            waitGate: waitGate,
            exitOnTerminate: exitOnTerminate,
            replaceIdentityAfterFirstWait: replaceIdentityAfterFirstWait,
            launchFails: launchFails,
            initialIdentity: initialProcessIdentity
        )
        let configuration = ManagedProcessConfiguration(
            executable: URL(fileURLWithPath: ManagedProcessIdentity.expected.executablePath),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            profileRoot: URL(fileURLWithPath: "/tmp"),
            logsDirectory: URL(fileURLWithPath: "/tmp/logs"),
            standardOutputLog: URL(fileURLWithPath: "/tmp/logs/inboxplus-stdout.log"),
            standardErrorLog: URL(fileURLWithPath: "/tmp/logs/inboxplus-stderr.log")
        )
        supervisor = SynapseSupervisor(
            configuration: configuration,
            loopbackPort: 18_008,
            processFactory: FakeManagedProcessFactory(process: process),
            listenerChecker: listener,
            healthChecker: LifecycleHealthyChecker(),
            initialSnapshot: initialSnapshot,
            gracefulTerminationTimeout: .seconds(5),
            forcedTerminationTimeout: .seconds(1),
            listenerVerificationAttempts: listenerVerificationAttempts,
            listenerVerificationInterval: .zero,
            sleep: { _ in }
        )
    }
}

private func fakeManagedProcessConfiguration() -> ManagedProcessConfiguration {
    ManagedProcessConfiguration(
        executable: URL(fileURLWithPath: ManagedProcessIdentity.expected.executablePath),
        arguments: [],
        environment: [:],
        workingDirectory: URL(fileURLWithPath: "/tmp"),
        profileRoot: URL(fileURLWithPath: "/tmp"),
        logsDirectory: URL(fileURLWithPath: "/tmp/logs"),
        standardOutputLog: URL(fileURLWithPath: "/tmp/logs/inboxplus-stdout.log"),
        standardErrorLog: URL(fileURLWithPath: "/tmp/logs/inboxplus-stderr.log")
    )
}

private struct LifecycleHealthyChecker: SynapseHealthChecking {
    func check(snapshot: RuntimeSnapshot) async -> HealthResult {
        .healthy(latency: .zero)
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var waiterCount = 0

    func wait() async {
        if isOpen { return }
        waiterCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }

    func waitForWaiter(timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while waiterCount == 0 {
            guard clock.now < deadline else { throw AsyncGateError.waiterDeadlineExceeded }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum AsyncGateError: Error {
    case waiterDeadlineExceeded
}

private actor FakeManagedProcess: ManagedProcess {
    struct Metrics: Sendable {
        var launchCalls = 0
        var signals: [ManagedProcessSignal] = []
        var identityChecks = 0
    }

    private let launchGate: AsyncGate?
    private let waitGate: AsyncGate?
    private let exitOnTerminate: Bool
    private let replaceIdentityAfterFirstWait: Bool
    private var launchFails: Bool
    private var currentIdentity: ManagedProcessIdentity?
    private var ownsCurrentIdentity = false
    private var identityStatusOverride: ManagedProcessIdentityStatus?
    private var lifecycleFailureValue: ManagedProcessError?
    private var lifecycleFailureGate: AsyncGate?
    private var nextOwnershipGate: AsyncGate?
    private var state = Metrics()
    private var waitCalls = 0

    init(
        launchGate: AsyncGate?,
        waitGate: AsyncGate?,
        exitOnTerminate: Bool,
        replaceIdentityAfterFirstWait: Bool,
        launchFails: Bool,
        initialIdentity: ManagedProcessIdentity? = nil
    ) {
        self.launchGate = launchGate
        self.waitGate = waitGate
        self.exitOnTerminate = exitOnTerminate
        self.replaceIdentityAfterFirstWait = replaceIdentityAfterFirstWait
        self.launchFails = launchFails
        currentIdentity = initialIdentity
    }

    func launch() async throws -> ManagedProcessIdentity {
        state.launchCalls += 1
        if let launchGate { await launchGate.wait() }
        if launchFails { throw FakeProcessError.launchFailed }
        currentIdentity = .expected
        ownsCurrentIdentity = true
        return .expected
    }

    func identityStatus(for expected: ManagedProcessIdentity) async -> ManagedProcessIdentityStatus {
        state.identityChecks += 1
        if let identityStatusOverride { return identityStatusOverride }
        guard let currentIdentity else { return .exited }
        return currentIdentity == expected ? .matching : .mismatched(actual: currentIdentity)
    }

    func ownership(for expected: ManagedProcessIdentity) async -> ManagedProcessOwnership {
        let result: ManagedProcessOwnership = ownsCurrentIdentity && currentIdentity == expected
            ? .directChild
            : .observedOnly
        if let gate = nextOwnershipGate {
            nextOwnershipGate = nil
            await gate.wait()
        }
        return result
    }

    func signal(_ signal: ManagedProcessSignal, ifMatching expected: ManagedProcessIdentity) async throws -> Bool {
        switch await identityStatus(for: expected) {
        case .matching:
            state.signals.append(signal)
            if signal == .kill || exitOnTerminate { currentIdentity = nil }
            return true
        case .exited:
            return false
        case let .mismatched(actual):
            throw RuntimeStateError.processIdentityMismatch(expected: expected, actual: actual)
        case let .indeterminate(failure):
            throw failure
        }
    }

    func waitForExit(matching expected: ManagedProcessIdentity, timeout: Duration) async throws -> Bool {
        waitCalls += 1
        if let waitGate { await waitGate.wait() }
        if replaceIdentityAfterFirstWait, waitCalls == 1 { currentIdentity = .replacement }
        switch await identityStatus(for: expected) {
        case .exited: return true
        case .matching: return false
        case let .mismatched(actual):
            throw RuntimeStateError.processIdentityMismatch(expected: expected, actual: actual)
        case let .indeterminate(failure):
            throw failure
        }
    }

    func replaceCurrentIdentity(with identity: ManagedProcessIdentity) {
        currentIdentity = identity
    }

    func setLaunchFailure(_ value: Bool) {
        launchFails = value
    }

    func setIdentityStatusOverride(_ value: ManagedProcessIdentityStatus?) {
        identityStatusOverride = value
    }

    func configureLifecycleFailure(_ value: ManagedProcessError?, gate: AsyncGate?) {
        lifecycleFailureValue = value
        lifecycleFailureGate = gate
    }

    func suspendNextOwnership(on gate: AsyncGate) {
        nextOwnershipGate = gate
    }

    func lifecycleFailure() async -> ManagedProcessError? {
        if let lifecycleFailureGate { await lifecycleFailureGate.wait() }
        return lifecycleFailureValue
    }

    func metrics() -> Metrics { state }
}

private enum FakeProcessError: Error, Equatable {
    case launchFailed
}

private final class IdentityReadSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let successfulReadCount: Int
    private var readCount = 0

    init(successfulReadCount: Int) {
        self.successfulReadCount = successfulReadCount
    }

    func read(_ pid: pid_t) -> ManagedProcessIdentity? {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        guard readCount <= successfulReadCount else { return nil }
        return FoundationManagedProcess.readIdentity(for: pid)
    }
}

private final class ToggleIdentityReader: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    func enable() {
        lock.lock()
        enabled = true
        lock.unlock()
    }

    func read(_ pid: pid_t) -> ManagedProcessIdentity? {
        lock.lock()
        let shouldRead = enabled
        lock.unlock()
        return shouldRead ? FoundationManagedProcess.readIdentity(for: pid) : nil
    }
}

private struct FakeManagedProcessFactory: ManagedProcessFactory, Sendable {
    let process: FakeManagedProcess
    func make(_ configuration: ManagedProcessConfiguration) throws -> any ManagedProcess { process }
    func rehydrate(
        _ configuration: ManagedProcessConfiguration,
        expectedIdentity: ManagedProcessIdentity
    ) throws -> any ManagedProcess { process }
}

private final class SequencedFakeManagedProcessFactory: ManagedProcessFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let processes: [FakeManagedProcess]
    private var nextIndex = 0

    init(processes: [FakeManagedProcess]) {
        self.processes = processes
    }

    func make(_ configuration: ManagedProcessConfiguration) throws -> any ManagedProcess {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex < processes.count else { throw FakeProcessError.launchFailed }
        defer { nextIndex += 1 }
        return processes[nextIndex]
    }

    func rehydrate(
        _ configuration: ManagedProcessConfiguration,
        expectedIdentity: ManagedProcessIdentity
    ) throws -> any ManagedProcess {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex > 0 else { throw FakeProcessError.launchFailed }
        return processes[nextIndex - 1]
    }
}

private actor FakeListenerChecker: LoopbackListenerChecking {
    private let responses: [LoopbackListenerPresence]
    private var index = 0

    init(responses: [Bool]) {
        self.responses = responses.map { $0 ? .present : .absent }
    }

    init(presences: [LoopbackListenerPresence]) { responses = presences }

    func presence(on port: UInt16) async -> LoopbackListenerPresence {
        defer { index += 1 }
        return responses[min(index, responses.count - 1)]
    }

    func checkCount() -> Int { index }
}

private extension ManagedProcessIdentity {
    static let expected = ManagedProcessIdentity(
        executablePath: "/opt/inboxplus/synapse_homeserver",
        launchTimestamp: Date(timeIntervalSince1970: 1_789_000_000),
        processIdentifier: 42,
        startIdentityToken: "42:1789000000:0"
    )
    static let replacement = ManagedProcessIdentity(
        executablePath: "/usr/bin/unrelated",
        launchTimestamp: Date(timeIntervalSince1970: 1_789_000_001),
        processIdentifier: 42,
        startIdentityToken: "42:1789000001:0"
    )
}

private extension RuntimeSnapshot {
    static let persistedHealthy = try! RuntimeSnapshot(
        phase: .healthy,
        processIdentity: .expected,
        loopbackPort: 18_008,
        restartCount: 0,
        lastHealthResult: nil,
        diagnosticLogDirectory: URL(fileURLWithPath: "/tmp"),
        lastError: nil
    )
}

private func fileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private struct SecureProcessDirectories {
    let root: URL
    let profile: URL
    let logs: URL

    init(prefix: String) throws {
        root = try canonicalTemporaryDirectory()
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        profile = root.appendingPathComponent("profile", isDirectory: true)
        logs = profile.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func canonicalTemporaryDirectory() throws -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    guard let resolved = realpath(temporaryPath, nil) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

private func managedConfiguration(
    fixture: SecureProcessDirectories,
    executable: String,
    arguments: [String],
    environment: [String: String] = [:],
    sensitiveLogValues: [String] = []
) throws -> ManagedProcessConfiguration {
    guard executable.hasPrefix("/") else {
        throw ManagedProcessError.invalidConfiguration("test executable must be absolute")
    }
    return ManagedProcessConfiguration(
        executable: URL(fileURLWithPath: executable),
        arguments: arguments,
        environment: environment,
        workingDirectory: fixture.profile,
        profileRoot: fixture.profile,
        logsDirectory: fixture.logs,
        standardOutputLog: fixture.logs.appendingPathComponent("stdout.log"),
        standardErrorLog: fixture.logs.appendingPathComponent("stderr.log"),
        sensitiveLogValues: sensitiveLogValues
    )
}

private final class SignalRaceEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPID: pid_t?

    var unreapedPID: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return storedPID
    }

    func recordUnreapedChild(_ pid: pid_t) {
        lock.lock()
        storedPID = pid
        lock.unlock()
    }
}

private final class SpawnEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var storedPID: pid_t?

    var pid: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return storedPID
    }

    func record(_ pid: pid_t) {
        lock.lock()
        storedPID = pid
        lock.unlock()
        semaphore.signal()
    }

    func waitForPID() -> pid_t? {
        guard semaphore.wait(timeout: .now() + spawnWaitSeconds) == .success else { return nil }
        return pid
    }
}

/// How long the throwaway child processes these tests spawn stay alive.
///
/// These tests assert on a *live* child: that it is still owned, still signalable, still there.
/// The child was `sleep 5`, which on a CI runner expired part-way through a test body that took
/// thirteen seconds — the child was reaped and every ownership check then failed with
/// `processNotOwned`, which reads like a supervision bug and is actually a fixture that did not
/// outlive its test. Long enough that no plausible machine outruns it, short enough that a leaked
/// one is gone in two minutes.
private let childLifetimeSeconds = "120"

/// How long to wait for a real child process to appear.
///
/// This is a guard against hanging forever, not an assertion about speed. It was two seconds, which
/// held on a developer machine and failed on a CI runner: the first `posix_spawn` of a test run
/// competes with the harness starting up on a slower, shared, virtualised host. A test that fails
/// because the machine is busy reports nothing about the code.
private let spawnWaitSeconds: Double = 30

private final class ConcurrentSpawnGate: @unchecked Sendable {
    private let lock = NSLock()
    private let firstSpawned = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var storedPIDs: [pid_t] = []

    var pids: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return storedPIDs
    }

    func recordAndBlockFirst(_ pid: pid_t) {
        lock.lock()
        storedPIDs.append(pid)
        let isFirst = storedPIDs.count == 1
        lock.unlock()
        guard isFirst else { return }
        firstSpawned.signal()
        release.wait()
    }

    func waitForFirstSpawn() -> pid_t? {
        guard firstSpawned.wait(timeout: .now() + spawnWaitSeconds) == .success else { return nil }
        return pids.first
    }

    func releaseFirst() {
        release.signal()
    }
}

private func processDisappears(_ pid: pid_t) async -> Bool {
    for _ in 0..<1_000 {
        if Darwin.kill(pid, 0) == -1, errno == ESRCH { return true }
        _ = await Task.detached(priority: .utility) { usleep(5_000) }.value
    }
    return false
}
