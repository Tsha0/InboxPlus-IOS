import CryptoKit
import Darwin
import Foundation
import InboxPlusBridge
import InboxPlusRuntime

public enum BridgeInstallError: Error, Equatable, Sendable, CustomStringConvertible {
    case nothingToInstall(String)
    case downloadFailed(bridge: String, status: Int)
    case transport(bridge: String, reason: String)
    case checksumMismatch(bridge: String, expected: String, actual: String)
    case emptyDownload(String)
    case cannotWrite(URL)
    case notExecutable(URL)

    public var description: String {
        switch self {
        case let .nothingToInstall(id):
            "bridge '\(id)' has no downloadable artifact"
        case let .downloadFailed(bridge, status):
            "downloading bridge '\(bridge)' failed with HTTP \(status)"
        case let .transport(bridge, reason):
            "downloading bridge '\(bridge)' failed: \(reason)"
        case let .checksumMismatch(bridge, expected, actual):
            "bridge '\(bridge)' failed verification: expected SHA-256 \(expected), got \(actual)"
        case let .emptyDownload(bridge):
            "bridge '\(bridge)' downloaded zero bytes"
        case let .cannotWrite(url):
            "cannot write \(url.path)"
        case let .notExecutable(url):
            "\(url.path) is not executable"
        }
    }
}

/// Fetches bytes for the installer. Split out so tests never reach the network.
public protocol BridgeArtifactFetching: Sendable {
    func fetch(_ url: URL) async throws -> (status: Int, body: Data)
}

public struct URLSessionBridgeArtifactFetcher: BridgeArtifactFetching {
    private let maximumBytes: Int

    public init(maximumBytes: Int = 256 * 1_024 * 1_024) {
        self.maximumBytes = maximumBytes
    }

    public func fetch(_ url: URL) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count <= maximumBytes else {
            throw BridgeInstallError.transport(
                bridge: url.lastPathComponent,
                reason: "response exceeded \(maximumBytes) bytes"
            )
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

public struct InstalledBridge: Sendable, Equatable {
    public let descriptor: BridgeDescriptor
    public let executable: URL
    public let sha256: String

    public init(descriptor: BridgeDescriptor, executable: URL, sha256: String) {
        self.descriptor = descriptor
        self.executable = executable
        self.sha256 = sha256
    }
}

/// Downloads a pinned bridge binary, verifies it, and installs it under the profile.
///
/// The ordering here is the whole point: bytes are hashed and compared *before* anything is marked
/// executable, and a mismatch never touches the install path. A bridge binary is code Inbox+ runs
/// with the user's messages in reach, so a release page alone is not sufficient provenance.
public struct BridgeInstaller: Sendable {
    public static let executablePermissions = 0o700
    public static let directoryPermissions = 0o700

    private let paths: RuntimePaths
    private let fetcher: any BridgeArtifactFetching

    public init(paths: RuntimePaths, fetcher: any BridgeArtifactFetching = URLSessionBridgeArtifactFetcher()) {
        self.paths = paths
        self.fetcher = fetcher
    }

    /// `<profile>/bridges/<id>` — binary, configuration, database, and logs for one bridge.
    public func directory(for descriptor: BridgeDescriptor) -> URL {
        paths.profile
            .appendingPathComponent("bridges", isDirectory: true)
            .appendingPathComponent(descriptor.id, isDirectory: true)
    }

    /// Installed binaries carry their version in the name, so a version bump cannot be mistaken
    /// for the binary already on disk.
    public func executable(for descriptor: BridgeDescriptor) -> URL {
        directory(for: descriptor)
            .appendingPathComponent("\(descriptor.id)-\(descriptor.version)", isDirectory: false)
    }

    public func isInstalled(_ descriptor: BridgeDescriptor) -> Bool {
        FileManager.default.isExecutableFile(atPath: executable(for: descriptor).path)
    }

    /// Installs `descriptor` if it is not already present and verified.
    ///
    /// An already-installed binary is re-hashed rather than trusted by path: the check is cheap
    /// next to the download, and it catches a binary that was swapped after installation.
    @discardableResult
    public func install(_ descriptor: BridgeDescriptor) async throws -> InstalledBridge {
        guard let artifact = descriptor.artifact else {
            throw BridgeInstallError.nothingToInstall(descriptor.id)
        }
        let destination = executable(for: descriptor)

        if FileManager.default.fileExists(atPath: destination.path),
           let existing = try? Data(contentsOf: destination),
           Self.hash(existing) == artifact.sha256 {
            try Self.setPermissions(Self.executablePermissions, on: destination)
            return InstalledBridge(
                descriptor: descriptor,
                executable: destination,
                sha256: artifact.sha256
            )
        }

        let (status, body): (Int, Data)
        do {
            (status, body) = try await fetcher.fetch(artifact.downloadURL)
        } catch let error as BridgeInstallError {
            throw error
        } catch {
            throw BridgeInstallError.transport(
                bridge: descriptor.id,
                reason: error.localizedDescription
            )
        }
        guard (200..<300).contains(status) else {
            throw BridgeInstallError.downloadFailed(bridge: descriptor.id, status: status)
        }
        guard !body.isEmpty else {
            throw BridgeInstallError.emptyDownload(descriptor.id)
        }

        let actual = Self.hash(body)
        guard actual == artifact.sha256 else {
            throw BridgeInstallError.checksumMismatch(
                bridge: descriptor.id,
                expected: artifact.sha256,
                actual: actual
            )
        }

        try publish(body, to: destination)
        guard FileManager.default.isExecutableFile(atPath: destination.path) else {
            throw BridgeInstallError.notExecutable(destination)
        }
        return InstalledBridge(descriptor: descriptor, executable: destination, sha256: actual)
    }

    /// Verifies an installed binary still hashes to its pinned value.
    public func verify(_ descriptor: BridgeDescriptor) throws {
        guard let artifact = descriptor.artifact else {
            throw BridgeInstallError.nothingToInstall(descriptor.id)
        }
        let destination = executable(for: descriptor)
        guard let bytes = try? Data(contentsOf: destination) else {
            throw BridgeInstallError.cannotWrite(destination)
        }
        let actual = Self.hash(bytes)
        guard actual == artifact.sha256 else {
            throw BridgeInstallError.checksumMismatch(
                bridge: descriptor.id,
                expected: artifact.sha256,
                actual: actual
            )
        }
    }

    /// Writes verified bytes to a staging file and renames into place.
    ///
    /// Staging is created non-executable and only promoted after the bytes are fully written, so
    /// no partially written file is ever runnable, even for an instant.
    private func publish(_ bytes: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        try Self.setPermissions(Self.directoryPermissions, on: directory)

        let staging = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard FileManager.default.createFile(
            atPath: staging.path,
            contents: bytes,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw BridgeInstallError.cannotWrite(destination)
        }
        do {
            try Self.syncFile(at: staging)
            try Self.setPermissions(Self.executablePermissions, on: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try Self.setPermissions(Self.executablePermissions, on: destination)
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func setPermissions(_ permissions: Int, on url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private static func syncFile(at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY)
        guard descriptor >= 0 else { throw BridgeInstallError.cannotWrite(url) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw BridgeInstallError.cannotWrite(url) }
    }
}
