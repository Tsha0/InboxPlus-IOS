import CryptoKit
import Darwin
import Foundation

public struct BackupFile: Codable, Sendable, Equatable {
    public let relativePath: String
    public let sha256: String
    public let byteCount: UInt64
    public let permissions: Int

    public init(relativePath: String, sha256: String, byteCount: UInt64, permissions: Int) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.permissions = permissions
    }
}

public struct BackupManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let createdAt: Date
    public let profileName: String
    public let runtimeManifestSHA256: String
    public let files: [BackupFile]
    public let expectedRoomCount: Int
    public let expectedEventCount: Int

    public init(
        schemaVersion: Int = BackupManifest.currentSchemaVersion,
        createdAt: Date,
        profileName: String,
        runtimeManifestSHA256: String,
        files: [BackupFile],
        expectedRoomCount: Int,
        expectedEventCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.profileName = profileName
        self.runtimeManifestSHA256 = runtimeManifestSHA256
        self.files = files
        self.expectedRoomCount = expectedRoomCount
        self.expectedEventCount = expectedEventCount
    }
}

public struct RestoreResult: Sendable, Equatable {
    public let restoredFileCount: Int
    public let verifiedChecksums: Int
}

public struct RecoveryResult: Sendable, Equatable {
    public let integrity: String
    public let roomCount: Int
    public let eventCount: Int
    public let acceptedNewWrite: Bool

    public var succeeded: Bool { integrity == "ok" && acceptedNewWrite }
}

public enum BackupError: Error, Equatable, Sendable {
    case runtimeMustBeStopped
    case checksumMismatch
    case backupNotFound(String)
    case targetNotEmpty(URL)
    case invalidBackupName(String)
    case missingSourceFile(URL)
    case cannotWrite(URL)
}

/// Creates and restores offline, checksummed profile backups.
///
/// Backups are only taken from a stopped runtime, are published by atomic rename, and are fully
/// verified before a restore touches the target profile.
public struct BackupManager: Sendable {
    public typealias SnapshotProvider = @Sendable () async throws -> RuntimeSnapshot

    /// Profile-relative trees worth preserving: database, media, configuration, keys, receipt.
    static let protectedSources = [
        "data",
        "configuration",
        "runtime/\(RuntimeBootstrapper.receiptName)",
        "state/\(RuntimeProfileStore.fileName)",
    ]

    public let paths: RuntimePaths
    private let runtimeSnapshot: SnapshotProvider
    private let now: @Sendable () -> Date

    public init(
        paths: RuntimePaths,
        runtimeSnapshot: @escaping SnapshotProvider,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.paths = paths
        self.runtimeSnapshot = runtimeSnapshot
        self.now = now
    }

    // MARK: - Create

    public func create(
        name: String,
        expectedRoomCount: Int = 0,
        expectedEventCount: Int = 0
    ) async throws -> BackupManifest {
        try Self.validateBackupName(name)
        let snapshot = try await runtimeSnapshot()
        guard snapshot.phase == .stopped else { throw BackupError.runtimeMustBeStopped }

        let destination = paths.backups.appendingPathComponent(name, isDirectory: true)
        let staging = paths.backups.appendingPathComponent(
            ".staging-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try createSecureDirectory(paths.backups)
        try createSecureDirectory(staging)

        do {
            var files: [BackupFile] = []
            let filesRoot = staging.appendingPathComponent("files", isDirectory: true)
            try createSecureDirectory(filesRoot)

            for source in Self.protectedSources {
                let sourceURL = paths.profile.appendingPathComponent(source)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
                files.append(
                    contentsOf: try copyTree(
                        from: sourceURL,
                        relativeTo: paths.profile,
                        into: filesRoot
                    )
                )
            }

            let manifest = BackupManifest(
                createdAt: now(),
                profileName: paths.profile.lastPathComponent,
                runtimeManifestSHA256: Self.sha256Hex(
                    (try? Data(
                        contentsOf: paths.runtime
                            .appendingPathComponent(RuntimeBootstrapper.receiptName)
                    )) ?? Data()
                ),
                files: files.sorted { $0.relativePath < $1.relativePath },
                expectedRoomCount: expectedRoomCount,
                expectedEventCount: expectedEventCount
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try writeSecureFile(
                try encoder.encode(manifest),
                to: staging.appendingPathComponent("manifest.json")
            )

            try syncDirectory(staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            return manifest
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Restore

    public func restore(name: String, into target: RuntimePaths) async throws -> RestoreResult {
        try Self.validateBackupName(name)
        let backup = paths.backups.appendingPathComponent(name, isDirectory: true)
        let manifestURL = backup.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BackupError.backupNotFound(name)
        }
        guard try isEffectivelyEmpty(target.profile) else {
            throw BackupError.targetNotEmpty(target.profile)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        let filesRoot = backup.appendingPathComponent("files", isDirectory: true)

        // Verify every checksum before mutating the target: a partial restore is worse than none.
        var verified = 0
        for file in manifest.files {
            let stored = filesRoot.appendingPathComponent(file.relativePath)
            guard let data = try? Data(contentsOf: stored) else {
                throw BackupError.missingSourceFile(stored)
            }
            guard Self.sha256Hex(data) == file.sha256 else { throw BackupError.checksumMismatch }
            verified += 1
        }

        // Stage the whole profile, then publish it, so a failure cannot leave a partial target.
        let staging = target.profile.deletingLastPathComponent()
            .appendingPathComponent(
                ".restore-\(target.profile.lastPathComponent)-\(UUID().uuidString)",
                isDirectory: true
            )
        try createSecureDirectory(staging)
        do {
            for file in manifest.files {
                let stored = filesRoot.appendingPathComponent(file.relativePath)
                let destination = staging.appendingPathComponent(file.relativePath)
                try createSecureDirectory(destination.deletingLastPathComponent())
                // Restored profiles are always tightened to user-only, whatever the source mode
                // recorded in the manifest was.
                try writeSecureFile(try Data(contentsOf: stored), to: destination)
            }
            try syncDirectory(staging)

            if FileManager.default.fileExists(atPath: target.profile.path) {
                try FileManager.default.removeItem(at: target.profile)
            }
            try createSecureDirectory(target.profile.deletingLastPathComponent())
            try FileManager.default.moveItem(at: staging, to: target.profile)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        return RestoreResult(restoredFileCount: manifest.files.count, verifiedChecksums: verified)
    }

    public func listBackups() throws -> [String] {
        guard FileManager.default.fileExists(atPath: paths.backups.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: paths.backups.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    // MARK: - Helpers

    static func validateBackupName(_ name: String) throws {
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil
        else {
            throw BackupError.invalidBackupName(name)
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Copies one file or directory tree, hashing every regular file it captures.
    private func copyTree(from source: URL, relativeTo base: URL, into filesRoot: URL) throws -> [BackupFile] {
        var metadata = stat()
        guard lstat(source.path, &metadata) == 0 else {
            throw BackupError.missingSourceFile(source)
        }

        if metadata.st_mode & S_IFMT == S_IFDIR {
            var captured: [BackupFile] = []
            for entry in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
                captured.append(
                    contentsOf: try copyTree(
                        from: source.appendingPathComponent(entry),
                        relativeTo: base,
                        into: filesRoot
                    )
                )
            }
            return captured
        }
        // Skip anything that is not a regular file: sockets, symlinks, and devices are not data.
        guard metadata.st_mode & S_IFMT == S_IFREG else { return [] }

        let relativePath = source.path.replacingOccurrences(of: base.path + "/", with: "")
        let data = try Data(contentsOf: source)
        let destination = filesRoot.appendingPathComponent(relativePath)
        let permissions = Int(metadata.st_mode) & 0o777
        try createSecureDirectory(destination.deletingLastPathComponent())
        try writeSecureFile(data, to: destination, permissions: permissions)

        return [
            BackupFile(
                relativePath: relativePath,
                sha256: Self.sha256Hex(data),
                byteCount: UInt64(data.count),
                permissions: permissions
            ),
        ]
    }

    private func isEffectivelyEmpty(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty
    }

    private func createSecureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func writeSecureFile(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: permissions]
        ) else {
            throw BackupError.cannotWrite(url)
        }
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw BackupError.cannotWrite(url) }
        defer { _ = close(descriptor) }
        _ = fsync(descriptor)
    }
}
