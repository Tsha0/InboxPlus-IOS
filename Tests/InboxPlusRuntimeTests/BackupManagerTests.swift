import Darwin
import Foundation
import Testing
@testable import InboxPlusRuntime

// MARK: - Fixtures

private func makeBackupRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Caches", isDirectory: true)
        .appendingPathComponent("InboxPlusBackupTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func populateProfile(_ paths: RuntimePaths) throws {
    for directory in [paths.configuration, paths.data, paths.runtime, paths.state] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
    try Data("database".utf8).write(to: paths.data.appendingPathComponent("homeserver.db"))
    try FileManager.default.createDirectory(
        at: paths.data.appendingPathComponent("media"),
        withIntermediateDirectories: true
    )
    try Data("mediabytes".utf8).write(
        to: paths.data.appendingPathComponent("media/thumb.bin")
    )
    try Data("server_name: inboxplus.localhost".utf8).write(
        to: paths.configuration.appendingPathComponent("homeserver.yaml")
    )
    try Data("signingkey".utf8).write(
        to: paths.configuration.appendingPathComponent("inboxplus.signing.key")
    )
    try Data("{\"receipt\": true}".utf8).write(
        to: paths.runtime.appendingPathComponent(RuntimeBootstrapper.receiptName)
    )
}

private func makeManager(
    paths: RuntimePaths,
    phase: RuntimePhase = .stopped
) -> BackupManager {
    BackupManager(
        paths: paths,
        runtimeSnapshot: {
            phase == .stopped ? .stopped : try healthySnapshot()
        }
    )
}

private func healthySnapshot() throws -> RuntimeSnapshot {
    try RuntimeSnapshot(
        phase: .healthy,
        processIdentity: ManagedProcessIdentity(
            executablePath: "/usr/bin/true",
            launchTimestamp: Date(timeIntervalSince1970: 1),
            processIdentifier: 4_242,
            startIdentityToken: "4242:1:0"
        ),
        loopbackPort: 18_008,
        restartCount: 0,
        lastHealthResult: "healthy",
        diagnosticLogDirectory: nil,
        lastError: nil
    )
}

// MARK: - Create

@Test func backupRejectsRunningProfile() async throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populateProfile(paths)

    await #expect(throws: BackupError.runtimeMustBeStopped) {
        try await makeManager(paths: paths, phase: .healthy).create(name: "before-damage")
    }
}

@Test func backupCapturesEveryProtectedFileWithAChecksum() async throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populateProfile(paths)

    let manifest = try await makeManager(paths: paths).create(name: "before-damage")
    let captured = Set(manifest.files.map(\.relativePath))

    #expect(captured.contains("data/homeserver.db"))
    #expect(captured.contains("data/media/thumb.bin"))
    #expect(captured.contains("configuration/homeserver.yaml"))
    #expect(captured.contains("configuration/inboxplus.signing.key"))
    #expect(captured.contains("runtime/\(RuntimeBootstrapper.receiptName)"))
    #expect(manifest.files.allSatisfy { $0.sha256.count == 64 })
}

@Test func backupIsPublishedAtomicallyWithoutStagingResidue() async throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populateProfile(paths)

    _ = try await makeManager(paths: paths).create(name: "before-damage")

    let entries = try FileManager.default.contentsOfDirectory(atPath: paths.backups.path)
    #expect(entries == ["before-damage"])
    #expect(!entries.contains { $0.hasPrefix(".") })
}

@Test(arguments: ["../escape", "/absolute", "", "with/slash", "."])
func backupNamesCannotEscapeTheBackupDirectory(_ name: String) async throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populateProfile(paths)

    await #expect(throws: BackupError.invalidBackupName(name)) {
        try await makeManager(paths: paths).create(name: name)
    }
}

// MARK: - Restore

@Test func corruptedFilePreventsRestoreBeforeTargetMutation() async throws {
    // Break caught: restoring file-by-file leaves a half-written profile when a checksum fails.
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populateProfile(paths)
    let manager = makeManager(paths: paths)
    _ = try await manager.create(name: "before-damage")

    let stored = paths.backups
        .appendingPathComponent("before-damage/files/data/homeserver.db")
    try Data("corrupted".utf8).write(to: stored)

    let target = try RuntimePaths(root: root, profileName: "restored")
    try FileManager.default.createDirectory(at: target.profile, withIntermediateDirectories: true)

    await #expect(throws: BackupError.checksumMismatch) {
        try await manager.restore(name: "before-damage", into: target)
    }
    let residue = try FileManager.default.contentsOfDirectory(atPath: target.profile.path)
    #expect(residue.isEmpty)
}

@Test func restoreReproducesEveryFileByteForByte() async throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populateProfile(paths)
    let manager = makeManager(paths: paths)
    let manifest = try await manager.create(name: "before-damage")

    let target = try RuntimePaths(root: root, profileName: "restored")
    let result = try await manager.restore(name: "before-damage", into: target)

    #expect(result.restoredFileCount == manifest.files.count)
    #expect(
        try Data(contentsOf: target.data.appendingPathComponent("homeserver.db"))
            == Data("database".utf8)
    )
    #expect(
        try Data(contentsOf: target.data.appendingPathComponent("media/thumb.bin"))
            == Data("mediabytes".utf8)
    )
}

@Test func restoreRefusesANonEmptyTarget() async throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populateProfile(paths)
    let manager = makeManager(paths: paths)
    _ = try await manager.create(name: "before-damage")

    let target = try RuntimePaths(root: root, profileName: "occupied")
    try FileManager.default.createDirectory(at: target.data, withIntermediateDirectories: true)
    try Data("existing".utf8).write(to: target.data.appendingPathComponent("homeserver.db"))

    await #expect(throws: BackupError.targetNotEmpty(target.profile)) {
        try await manager.restore(name: "before-damage", into: target)
    }
    #expect(
        try Data(contentsOf: target.data.appendingPathComponent("homeserver.db"))
            == Data("existing".utf8)
    )
}

@Test func restoredSecretsKeepUserOnlyPermissions() async throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populateProfile(paths)
    let manager = makeManager(paths: paths)
    _ = try await manager.create(name: "before-damage")

    let target = try RuntimePaths(root: root, profileName: "restored")
    _ = try await manager.restore(name: "before-damage", into: target)

    var metadata = stat()
    #expect(lstat(target.configuration.appendingPathComponent("inboxplus.signing.key").path, &metadata) == 0)
    #expect(Int(metadata.st_mode) & 0o777 == 0o600)

    var directoryMetadata = stat()
    #expect(lstat(target.data.path, &directoryMetadata) == 0)
    #expect(Int(directoryMetadata.st_mode) & 0o777 == 0o700)
}

@Test func restoringAnAbsentBackupIsRejected() async throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populateProfile(paths)

    let target = try RuntimePaths(root: root, profileName: "restored")
    await #expect(throws: BackupError.backupNotFound("absent")) {
        try await makeManager(paths: paths).restore(name: "absent", into: target)
    }
}

@Test func manifestChecksumsDetectAnyAlteredByte() async throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populateProfile(paths)
    let manager = makeManager(paths: paths)
    let manifest = try await manager.create(name: "before-damage")

    let databaseEntry = try #require(manifest.files.first { $0.relativePath == "data/homeserver.db" })
    #expect(databaseEntry.sha256 == BackupManager.sha256Hex(Data("database".utf8)))
    #expect(databaseEntry.byteCount == 8)
}
