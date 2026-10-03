import Darwin
import Foundation
import Testing
@testable import InboxPlusRuntime

private func makeProfilePaths(_ name: String) throws -> (RuntimePaths, URL) {
    // The temporary directory lives under /var, a symlink that `RuntimePaths` refuses and that
    // `standardizedFileURL` maps back from /private/var. The home directory has no such ancestor.
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Caches", isDirectory: true)
        .appendingPathComponent("InboxPlusProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (try RuntimePaths(root: root, profileName: name), root)
}

private func makeState(
    identity: ManagedProcessIdentity,
    port: UInt16 = 18_008
) throws -> RuntimeProfileState {
    RuntimeProfileState(
        serverName: "inboxplus.localhost",
        registrationSecret: "secret-value",
        launchExecutable: "/usr/bin/true",
        virtualEnvironmentPython: "/tmp/venv/bin/python",
        configurationFile: "/tmp/homeserver.yaml",
        snapshot: try RuntimeSnapshot(
            phase: .healthy,
            processIdentity: identity,
            loopbackPort: port,
            restartCount: 0,
            lastHealthResult: "healthy",
            diagnosticLogDirectory: nil,
            lastError: nil
        )
    )
}

@Test func persistedProcessIdentitySurvivesRoundTripExactly() throws {
    // Break caught: an ISO8601 date strategy truncates sub-second precision, so a reloaded
    // identity never compares equal to the live process and `status` reports a stopped runtime.
    let (paths, root) = try makeProfilePaths("alpha")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RuntimeProfileStore(paths: paths)

    let identity = ManagedProcessIdentity(
        executablePath: "/usr/bin/true",
        launchTimestamp: Date(timeIntervalSince1970: 1_786_674_492.156983),
        processIdentifier: 4_242,
        startIdentityToken: "4242:1786674492:156983"
    )
    try store.save(try makeState(identity: identity))

    let loaded = try #require(try store.load())
    #expect(loaded.snapshot.processIdentity == identity)
    #expect(loaded.snapshot.processIdentity?.launchTimestamp == identity.launchTimestamp)
}

@Test func everyPersistedFieldSurvivesRoundTrip() throws {
    let (paths, root) = try makeProfilePaths("alpha")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RuntimeProfileStore(paths: paths)

    let identity = ManagedProcessIdentity(
        executablePath: "/usr/bin/true",
        launchTimestamp: Date(timeIntervalSince1970: 1_786_674_492.5),
        processIdentifier: 99,
        startIdentityToken: "99:1786674492:500000"
    )
    let state = try makeState(identity: identity, port: 51_515)
    try store.save(state)

    #expect(try store.load() == state)
}

@Test func absentStateLoadsAsNil() throws {
    let (paths, root) = try makeProfilePaths("alpha")
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try RuntimeProfileStore(paths: paths).load() == nil)
}

@Test func savedStateIsUserOnlyReadable() throws {
    let (paths, root) = try makeProfilePaths("alpha")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RuntimeProfileStore(paths: paths)
    try store.save(
        try makeState(
            identity: ManagedProcessIdentity(
                executablePath: "/usr/bin/true",
                launchTimestamp: Date(timeIntervalSince1970: 1),
                processIdentifier: 7,
                startIdentityToken: "7:1:0"
            )
        )
    )

    var metadata = stat()
    #expect(lstat(store.stateFile.path, &metadata) == 0)
    #expect(Int(metadata.st_mode) & 0o777 == 0o600)
}

@Test func aWorldReadableStateFileIsRejected() throws {
    let (paths, root) = try makeProfilePaths("alpha")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RuntimeProfileStore(paths: paths)
    try store.save(
        try makeState(
            identity: ManagedProcessIdentity(
                executablePath: "/usr/bin/true",
                launchTimestamp: Date(timeIntervalSince1970: 1),
                processIdentifier: 7,
                startIdentityToken: "7:1:0"
            )
        )
    )
    #expect(chmod(store.stateFile.path, 0o644) == 0)

    #expect(throws: RuntimeProfileStoreError.insecurePermissions(expected: 0o600, actual: 0o644)) {
        try store.load()
    }
}

@Test func anUnknownSchemaVersionIsRejected() throws {
    let (paths, root) = try makeProfilePaths("alpha")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RuntimeProfileStore(paths: paths)
    let future = RuntimeProfileState(
        schemaVersion: RuntimeProfileState.currentSchemaVersion + 1,
        serverName: "inboxplus.localhost",
        registrationSecret: "secret-value",
        launchExecutable: "/usr/bin/true",
        virtualEnvironmentPython: "/tmp/venv/bin/python",
        configurationFile: "/tmp/homeserver.yaml",
        snapshot: .stopped
    )
    try store.save(future)

    #expect(
        throws: RuntimeProfileStoreError.unsupportedSchemaVersion(
            RuntimeProfileState.currentSchemaVersion + 1
        )
    ) {
        try store.load()
    }
}

@Test func savingReplacesThePreviousStateWithoutLeavingStagingFiles() throws {
    let (paths, root) = try makeProfilePaths("alpha")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RuntimeProfileStore(paths: paths)
    let identity = ManagedProcessIdentity(
        executablePath: "/usr/bin/true",
        launchTimestamp: Date(timeIntervalSince1970: 1),
        processIdentifier: 7,
        startIdentityToken: "7:1:0"
    )
    let state = try makeState(identity: identity)
    try store.save(state)
    try store.save(state.replacing(snapshot: .stopped))

    #expect(try store.load()?.snapshot.phase == .stopped)
    let residue = try FileManager.default.contentsOfDirectory(atPath: paths.state.path)
        .filter { $0 != RuntimeProfileStore.fileName }
    #expect(residue.isEmpty)
}
