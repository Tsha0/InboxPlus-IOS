import Darwin
import Foundation

/// Everything a later CLI invocation needs to rebuild the exact supervisor for a profile.
///
/// `start` exits while Synapse keeps running, so `status` and `stop` run in different
/// processes. They can only adopt the running child if they reconstruct byte-identical
/// launch metadata, which is why the resolved executable paths are persisted rather than
/// recomputed.
public struct RuntimeProfileState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let serverName: String
    public let registrationSecret: String
    public let launchExecutable: String
    public let virtualEnvironmentPython: String
    public let configurationFile: String
    public let snapshot: RuntimeSnapshot

    public init(
        schemaVersion: Int = RuntimeProfileState.currentSchemaVersion,
        serverName: String,
        registrationSecret: String,
        launchExecutable: String,
        virtualEnvironmentPython: String,
        configurationFile: String,
        snapshot: RuntimeSnapshot
    ) {
        self.schemaVersion = schemaVersion
        self.serverName = serverName
        self.registrationSecret = registrationSecret
        self.launchExecutable = launchExecutable
        self.virtualEnvironmentPython = virtualEnvironmentPython
        self.configurationFile = configurationFile
        self.snapshot = snapshot
    }

    public func replacing(snapshot: RuntimeSnapshot) -> RuntimeProfileState {
        RuntimeProfileState(
            schemaVersion: schemaVersion,
            serverName: serverName,
            registrationSecret: registrationSecret,
            launchExecutable: launchExecutable,
            virtualEnvironmentPython: virtualEnvironmentPython,
            configurationFile: configurationFile,
            snapshot: snapshot
        )
    }
}

/// Reads and atomically writes the profile session file with user-only permissions.
public struct RuntimeProfileStore: Sendable {
    public static let filePermissions = 0o600
    public static let fileName = "session.json"

    public let stateDirectory: URL
    public let stateFile: URL

    public init(paths: RuntimePaths) {
        stateDirectory = paths.state
        stateFile = paths.state.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public func load() throws -> RuntimeProfileState? {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return nil }
        try requireUserOnlyRegularFile()
        let data = try Data(contentsOf: stateFile)
        // Dates round-trip through the default `Double` strategy on purpose: ISO8601 truncates
        // sub-second precision, and process identity compares `launchTimestamp` exactly.
        let state = try JSONDecoder().decode(RuntimeProfileState.self, from: data)
        guard state.schemaVersion == RuntimeProfileState.currentSchemaVersion else {
            throw RuntimeProfileStoreError.unsupportedSchemaVersion(state.schemaVersion)
        }
        return state
    }

    public func save(_ state: RuntimeProfileState) throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)

        let staging = stateDirectory.appendingPathComponent(
            ".\(Self.fileName).\(UUID().uuidString)",
            isDirectory: false
        )
        guard FileManager.default.createFile(
            atPath: staging.path,
            contents: data,
            attributes: [.posixPermissions: Self.filePermissions]
        ) else {
            throw RuntimeProfileStoreError.cannotWrite
        }
        do {
            try syncFile(at: staging)
            _ = try FileManager.default.replaceItemAt(stateFile, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return }
        try FileManager.default.removeItem(at: stateFile)
    }

    private func requireUserOnlyRegularFile() throws {
        var metadata = stat()
        guard lstat(stateFile.path, &metadata) == 0 else {
            throw RuntimeProfileStoreError.cannotRead
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw RuntimeProfileStoreError.notRegularFile
        }
        let mode = Int(metadata.st_mode) & 0o777
        guard mode == Self.filePermissions else {
            throw RuntimeProfileStoreError.insecurePermissions(expected: Self.filePermissions, actual: mode)
        }
    }

    private func syncFile(at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY)
        guard descriptor >= 0 else { throw RuntimeProfileStoreError.cannotWrite }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw RuntimeProfileStoreError.cannotWrite }
    }
}

public enum RuntimeProfileStoreError: Error, Equatable, Sendable {
    case cannotRead
    case cannotWrite
    case notRegularFile
    case insecurePermissions(expected: Int, actual: Int)
    case unsupportedSchemaVersion(Int)
}
