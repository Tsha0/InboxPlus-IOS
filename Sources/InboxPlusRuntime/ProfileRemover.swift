import Darwin
import Foundation

public struct RemovalResult: Sendable, Equatable {
    public let removedProfile: Bool
    public let exportedReportCount: Int
    public let residuePaths: [String]

    public var succeeded: Bool { residuePaths.isEmpty }
}

public enum RemovalError: Error, Equatable, Sendable {
    case confirmationMismatch
    case runtimeMustBeStopped
    case unsafeSymlink(URL)
    case exportDestinationInsideProfile
    case residueRemains([String])
}

/// Removes exactly one contained profile after explicit confirmation.
///
/// Removal stops at the first sign that deletion would leave the profile tree: a symlink could
/// point anywhere, so the whole operation is refused rather than partially applied.
public struct ProfileRemover: Sendable {
    public typealias SnapshotProvider = @Sendable () async throws -> RuntimeSnapshot

    public let paths: RuntimePaths
    private let runtimeSnapshot: SnapshotProvider

    public init(paths: RuntimePaths, runtimeSnapshot: @escaping SnapshotProvider) {
        self.paths = paths
        self.runtimeSnapshot = runtimeSnapshot
    }

    public func remove(confirmation: String, exportReportTo destination: URL?) async throws -> RemovalResult {
        guard confirmation == paths.profile.lastPathComponent else {
            throw RemovalError.confirmationMismatch
        }
        guard try await runtimeSnapshot().phase == .stopped else {
            throw RemovalError.runtimeMustBeStopped
        }

        if let destination {
            let standardized = destination.standardizedFileURL
            guard !standardized.path.hasPrefix(paths.profile.path + "/"),
                  standardized.path != paths.profile.path
            else {
                throw RemovalError.exportDestinationInsideProfile
            }
        }

        guard FileManager.default.fileExists(atPath: paths.profile.path) else {
            return RemovalResult(removedProfile: false, exportedReportCount: 0, residuePaths: [])
        }

        // The profile itself must be a real directory. Interior symlinks are expected — a Python
        // virtual environment links to its base interpreter — and are safe, because removal
        // unlinks them rather than following them, so no target outside the profile is touched.
        try requireRealDirectory(paths.profile)

        var exported = 0
        if let destination {
            exported = try exportReports(to: destination)
        }

        try FileManager.default.removeItem(at: paths.profile)

        let residue = FileManager.default.fileExists(atPath: paths.profile.path)
            ? [paths.profile.path]
            : []
        guard residue.isEmpty else { throw RemovalError.residueRemains(residue) }

        return RemovalResult(
            removedProfile: true,
            exportedReportCount: exported,
            residuePaths: residue
        )
    }

    private func exportReports(to destination: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: paths.reports.path) else { return 0 }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        var exported = 0
        for entry in try FileManager.default.contentsOfDirectory(atPath: paths.reports.path).sorted()
        where !entry.hasPrefix(".") {
            let source = paths.reports.appendingPathComponent(entry)
            let target = destination.appendingPathComponent(entry)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
            exported += 1
        }
        return exported
    }

    private func requireRealDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return }
        guard metadata.st_mode & S_IFMT != S_IFLNK else {
            throw RemovalError.unsafeSymlink(url)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw RemovalError.unsafeSymlink(url)
        }
    }
}
