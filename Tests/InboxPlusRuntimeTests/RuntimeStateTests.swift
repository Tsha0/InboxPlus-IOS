import Foundation
import Testing
@testable import InboxPlusRuntime

@Test func runtimeStateAcceptsOnlyDeclaredLifecycleTransitions() throws {
    // Break caught: the lifecycle silently skips a state or allows a stopped runtime to claim health.
    #expect(try RuntimeState(phase: .stopped).transitioning(to: .starting).phase == .starting)
    #expect(try RuntimeState(phase: .starting).transitioning(to: .healthy).phase == .healthy)
    #expect(try RuntimeState(phase: .healthy).transitioning(to: .stopping).phase == .stopping)
    #expect(try RuntimeState(phase: .stopping).transitioning(to: .stopped).phase == .stopped)

    #expect(throws: RuntimeStateError.invalidTransition(from: .stopped, to: .healthy)) {
        try RuntimeState(phase: .stopped).transitioning(to: .healthy)
    }
    #expect(throws: RuntimeStateError.invalidTransition(from: .starting, to: .starting)) {
        try RuntimeState(phase: .starting).transitioning(to: .starting)
    }
}

@Test func runtimeSnapshotRoundTripsStableProcessMetadata() throws {
    // Break caught: persisted status loses the start token needed to distinguish PID reuse.
    let identity = ManagedProcessIdentity(
        executablePath: "/opt/inboxplus/synapse_homeserver",
        launchTimestamp: Date(timeIntervalSince1970: 1_789_000_000.125),
        processIdentifier: 42,
        startIdentityToken: "42:1789000000:125000"
    )
    let snapshot = try RuntimeSnapshot(
        phase: .healthy,
        processIdentity: identity,
        loopbackPort: 18_008,
        restartCount: 0,
        lastHealthResult: nil,
        diagnosticLogDirectory: URL(fileURLWithPath: "/tmp/inboxplus/logs"),
        lastError: nil
    )

    let encoded = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(RuntimeSnapshot.self, from: encoded) == snapshot)
}

@Test(arguments: RuntimePhase.allCases)
func runtimeSnapshotRequiresExactMetadataShapeForEveryPhase(_ phase: RuntimePhase) throws {
    // Break caught: a phase accepts missing authority or stale PID/listener authority.
    let requiresRuntimeMetadata: Bool = switch phase {
    case .healthy, .degraded, .stopping: true
    case .unprepared, .stopped, .starting, .recovering, .failed: false
    }
    let identity: ManagedProcessIdentity? = requiresRuntimeMetadata ? .snapshotTestIdentity : nil
    let port: UInt16? = requiresRuntimeMetadata ? 18_008 : nil

    let valid = try RuntimeSnapshot(
        phase: phase,
        processIdentity: identity,
        loopbackPort: port,
        restartCount: 0,
        lastHealthResult: nil,
        diagnosticLogDirectory: nil,
        lastError: phase == .failed ? "actionable failure" : nil
    )
    #expect(try JSONDecoder().decode(RuntimeSnapshot.self, from: JSONEncoder().encode(valid)) == valid)
    #expect(valid.phase == phase)

    if requiresRuntimeMetadata {
        #expect(throws: RuntimeStateError.self) {
            try RuntimeSnapshot(
                phase: phase,
                processIdentity: nil,
                loopbackPort: port,
                restartCount: 0,
                lastHealthResult: nil,
                diagnosticLogDirectory: nil,
                lastError: nil
            )
        }
        #expect(throws: RuntimeStateError.self) {
            try RuntimeSnapshot(
                phase: phase,
                processIdentity: identity,
                loopbackPort: nil,
                restartCount: 0,
                lastHealthResult: nil,
                diagnosticLogDirectory: nil,
                lastError: nil
            )
        }
    } else {
        #expect(throws: RuntimeStateError.self) {
            try RuntimeSnapshot(
                phase: phase,
                processIdentity: .snapshotTestIdentity,
                loopbackPort: nil,
                restartCount: 0,
                lastHealthResult: nil,
                diagnosticLogDirectory: nil,
                lastError: phase == .failed ? "actionable failure" : nil
            )
        }
        #expect(throws: RuntimeStateError.self) {
            try RuntimeSnapshot(
                phase: phase,
                processIdentity: nil,
                loopbackPort: 18_008,
                restartCount: 0,
                lastHealthResult: nil,
                diagnosticLogDirectory: nil,
                lastError: phase == .failed ? "actionable failure" : nil
            )
        }
    }
}

@Test(arguments: RuntimePhase.allCases)
func runtimeSnapshotDecodingRejectsAuthorityMutationForEveryPhase(_ phase: RuntimePhase) throws {
    // Break caught: custom construction is safe but corrupt persisted JSON bypasses phase invariants.
    let requiresRuntimeMetadata: Bool = switch phase {
    case .healthy, .degraded, .stopping: true
    case .unprepared, .stopped, .starting, .recovering, .failed: false
    }
    let valid = try RuntimeSnapshot(
        phase: phase,
        processIdentity: requiresRuntimeMetadata ? .snapshotTestIdentity : nil,
        loopbackPort: requiresRuntimeMetadata ? 18_008 : nil,
        restartCount: 0,
        lastHealthResult: nil,
        diagnosticLogDirectory: nil,
        lastError: phase == .failed ? "actionable failure" : nil
    )
    let encodedIdentity = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(ManagedProcessIdentity.snapshotTestIdentity)
    )
    var identityMutation = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
    )
    var listenerMutation = identityMutation
    if requiresRuntimeMetadata {
        identityMutation.removeValue(forKey: "processIdentity")
        listenerMutation.removeValue(forKey: "loopbackPort")
    } else {
        identityMutation["processIdentity"] = encodedIdentity
        listenerMutation["loopbackPort"] = 18_008
    }

    for object in [identityMutation, listenerMutation] {
        let corruptData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RuntimeSnapshot.self, from: corruptData)
        }
    }
}

@Test func failedSnapshotRequiresActionableErrorAndNeverCarriesSignalAuthority() {
    // Break caught: a terminal failed snapshot retains stale PID authority or no diagnostic reason.
    #expect(throws: RuntimeStateError.self) {
        try RuntimeSnapshot(
            phase: .failed,
            processIdentity: nil,
            loopbackPort: nil,
            restartCount: 0,
            lastHealthResult: nil,
            diagnosticLogDirectory: nil,
            lastError: nil
        )
    }
    #expect(throws: RuntimeStateError.self) {
        try RuntimeSnapshot(
            phase: .failed,
            processIdentity: .snapshotTestIdentity,
            loopbackPort: 18_008,
            restartCount: 0,
            lastHealthResult: nil,
            diagnosticLogDirectory: nil,
            lastError: "failure"
        )
    }
}

@Test func runtimeExitCodesRemainDistinctForLifecycleSafetyFailures() {
    // Break caught: CLI callers cannot distinguish invalid state, stale identity, and incomplete shutdown.
    #expect(RuntimeExitCode.success.rawValue == 0)
    #expect(RuntimeExitCode.invalidTransition.rawValue != RuntimeExitCode.processIdentityMismatch.rawValue)
    #expect(RuntimeExitCode.processIdentityMismatch.rawValue != RuntimeExitCode.shutdownIncomplete.rawValue)
    #expect(RuntimeExitCode.processLaunchFailed.rawValue != RuntimeExitCode.shutdownIncomplete.rawValue)
}

private extension ManagedProcessIdentity {
    static let snapshotTestIdentity = ManagedProcessIdentity(
        executablePath: "/opt/inboxplus/synapse_homeserver",
        launchTimestamp: Date(timeIntervalSince1970: 1_789_000_000.125),
        processIdentifier: 42,
        startIdentityToken: "42:1789000000:125000"
    )
}
