import Darwin
import Foundation
import Testing
@testable import InboxPlusMatrix
@testable import InboxPlusRuntime

/// `RuntimePaths` refuses symlinked ancestors, and `standardizedFileURL` maps /private/var back to
/// /var, so the temporary directory cannot be used as a profile root.
private func makeProfile() throws -> (RuntimePaths, URL) {
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Caches", isDirectory: true)
        .appendingPathComponent("InboxPlusMatrixStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (try RuntimePaths(root: root, profileName: "alpha"), root)
}

private func makeStore(_ paths: RuntimePaths) -> MatrixClientStore {
    MatrixClientStore(
        profile: paths,
        keychain: MatrixKeychain(service: "org.inboxplus.tests.\(UUID().uuidString)")
    )
}

private func fixtureSession(accessToken: String = "syt_secret") -> PersistedSession {
    PersistedSession(
        accessToken: accessToken,
        refreshToken: "refresh",
        userID: "@inboxplus:inboxplus.localhost",
        deviceID: "INBOXPLUSDEVICE",
        homeserverURL: "http://127.0.0.1:8008",
        oauthData: nil,
        usesNativeSlidingSync: true
    )
}

@Test func directoriesAreCreatedUserOnly() throws {
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(paths)
    try store.prepareDirectories()

    for directory in [store.dataDirectory, store.cacheDirectory] {
        var metadata = stat()
        #expect(lstat(directory.path, &metadata) == 0)
        #expect(Int(metadata.st_mode) & 0o777 == 0o700)
    }
}

@Test func theStorePassphraseIsStableAcrossCalls() throws {
    // Break caught: a passphrase regenerated per launch makes the existing store unreadable.
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(paths)
    defer { try? store.destroy() }

    #expect(try store.storePassphrase() == store.storePassphrase())
    #expect(try !store.storePassphrase().isEmpty)
}

@Test func aSessionRoundTripsThroughDisk() throws {
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(paths)
    defer { try? store.destroy() }

    let session = fixtureSession()
    try store.saveSession(session)
    #expect(try store.loadSession() == session)
}

@Test func anAbsentSessionLoadsAsNil() throws {
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try makeStore(paths).loadSession() == nil)
}

@Test func theSavedSessionIsUserOnlyReadable() throws {
    // The session file holds a live access token.
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(paths)
    defer { try? store.destroy() }
    try store.saveSession(fixtureSession())

    var metadata = stat()
    #expect(lstat(store.sessionFile.path, &metadata) == 0)
    #expect(Int(metadata.st_mode) & 0o777 == 0o600)
}

@Test func savingTwiceLeavesNoStagingResidue() throws {
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(paths)
    defer { try? store.destroy() }

    try store.saveSession(fixtureSession())
    try store.saveSession(fixtureSession(accessToken: "syt_rotated"))

    #expect(try store.loadSession()?.accessToken == "syt_rotated")
    let residue = try FileManager.default.contentsOfDirectory(atPath: paths.state.path)
        .filter { $0.hasPrefix(".") }
    #expect(residue.isEmpty)
}

@Test func destroyRemovesDataAndKeyTogether() throws {
    // Break caught: deleting the store but keeping the Keychain key, or the reverse, leaves a
    // profile that can never be opened again.
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }
    let keychainService = "org.inboxplus.tests.\(UUID().uuidString)"
    let keychain = MatrixKeychain(service: keychainService)
    let store = MatrixClientStore(profile: paths, keychain: keychain)

    try store.saveSession(fixtureSession())
    _ = try store.storePassphrase()
    #expect(try keychain.passphrase(forAccount: store.keychainAccount) != nil)

    try store.destroy()

    #expect(try store.loadSession() == nil)
    #expect(!FileManager.default.fileExists(atPath: store.dataDirectory.path))
    #expect(try keychain.passphrase(forAccount: store.keychainAccount) == nil)
}

@Test func distinctProfilesUseDistinctKeychainAccounts() throws {
    let (first, firstRoot) = try makeProfile()
    let (second, secondRoot) = try makeProfile()
    defer {
        try? FileManager.default.removeItem(at: firstRoot)
        try? FileManager.default.removeItem(at: secondRoot)
    }
    let shared = MatrixKeychain(service: "org.inboxplus.tests.\(UUID().uuidString)")
    let a = MatrixClientStore(profile: first, keychain: shared, keychainAccount: "profile-a")
    let b = MatrixClientStore(profile: second, keychain: shared, keychainAccount: "profile-b")
    defer {
        try? a.destroy()
        try? b.destroy()
    }

    #expect(try a.storePassphrase() != b.storePassphrase())
}

@Test func aClientBuilderBindsToTheProfileStore() throws {
    let (paths, root) = try makeProfile()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(paths)
    defer { try? store.destroy() }

    // Building the builder must not throw and must have created its store directories.
    _ = try store.makeClientBuilder(homeserverURL: URL(string: "http://127.0.0.1:8008")!)
    #expect(FileManager.default.fileExists(atPath: store.dataDirectory.path))
    #expect(FileManager.default.fileExists(atPath: store.cacheDirectory.path))
}
