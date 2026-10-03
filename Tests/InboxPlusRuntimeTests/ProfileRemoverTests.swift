import Darwin
import Foundation
import Testing
@testable import InboxPlusRuntime

private func makeRemovalRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Caches", isDirectory: true)
        .appendingPathComponent("InboxPlusRemovalTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func populate(_ paths: RuntimePaths) throws {
    for directory in [paths.configuration, paths.data, paths.reports, paths.state] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
    try Data("db".utf8).write(to: paths.data.appendingPathComponent("homeserver.db"))
    try Data("# report".utf8).write(to: paths.reports.appendingPathComponent("latest.md"))
}

private func makeRemover(
    paths: RuntimePaths,
    phase: RuntimePhase = .stopped
) -> ProfileRemover {
    ProfileRemover(
        paths: paths,
        runtimeSnapshot: {
            guard phase != .stopped else { return .stopped }
            return try RuntimeSnapshot(
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
    )
}

@Test func confirmationMustExactlyMatchProfile() async throws {
    let root = try makeRemovalRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populate(paths)

    await #expect(throws: RemovalError.confirmationMismatch) {
        try await makeRemover(paths: paths).remove(confirmation: "wrong", exportReportTo: nil)
    }
    #expect(FileManager.default.fileExists(atPath: paths.profile.path))
}

@Test func removalRefusesWhileTheRuntimeIsLive() async throws {
    let root = try makeRemovalRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populate(paths)

    await #expect(throws: RemovalError.runtimeMustBeStopped) {
        try await makeRemover(paths: paths, phase: .healthy)
            .remove(confirmation: "alpha", exportReportTo: nil)
    }
    #expect(FileManager.default.fileExists(atPath: paths.profile.path))
}

@Test func removalDeletesExactlyTheNamedProfile() async throws {
    let root = try makeRemovalRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    let sibling = try RuntimePaths(root: root, profileName: "beta")
    try populate(paths)
    try populate(sibling)

    let result = try await makeRemover(paths: paths).remove(confirmation: "alpha", exportReportTo: nil)

    #expect(result.residuePaths.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: paths.profile.path))
    #expect(FileManager.default.fileExists(atPath: sibling.profile.path))
}

@Test func anEscapingSymlinkIsUnlinkedWithoutDeletingItsTarget() async throws {
    // Break caught: following a symlink out of the profile deletes unrelated user data.
    // Interior symlinks must still be removable — a Python virtual environment always has them.
    let root = try makeRemovalRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populate(paths)

    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent("keep.txt")
    try Data("precious".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(
        at: paths.data.appendingPathComponent("escape"),
        withDestinationURL: outside
    )

    let result = try await makeRemover(paths: paths).remove(confirmation: "alpha", exportReportTo: nil)

    #expect(result.removedProfile)
    #expect(result.residuePaths.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: paths.profile.path))
    // The link is gone with the profile; everything it pointed at is untouched.
    #expect(FileManager.default.fileExists(atPath: sentinel.path))
    #expect(try Data(contentsOf: sentinel) == Data("precious".utf8))
}

@Test func aProfilePathThatIsItselfASymlinkIsRefused() async throws {
    let root = try makeRemovalRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent("keep.txt")
    try Data("precious".utf8).write(to: sentinel)

    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try FileManager.default.createSymbolicLink(at: paths.profile, withDestinationURL: outside)

    await #expect(throws: RemovalError.unsafeSymlink(paths.profile)) {
        try await makeRemover(paths: paths).remove(confirmation: "alpha", exportReportTo: nil)
    }
    #expect(FileManager.default.fileExists(atPath: sentinel.path))
}

@Test func reportsAreExportedBeforeRemoval() async throws {
    let root = try makeRemovalRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populate(paths)
    let destination = root.appendingPathComponent("exported", isDirectory: true)

    let result = try await makeRemover(paths: paths)
        .remove(confirmation: "alpha", exportReportTo: destination)

    #expect(result.exportedReportCount == 1)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("latest.md").path))
    #expect(!FileManager.default.fileExists(atPath: paths.profile.path))
}

@Test func exportingIntoTheProfileItselfIsRejected() async throws {
    let root = try makeRemovalRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")
    try populate(paths)

    await #expect(throws: RemovalError.exportDestinationInsideProfile) {
        try await makeRemover(paths: paths).remove(
            confirmation: "alpha",
            exportReportTo: paths.profile.appendingPathComponent("exported")
        )
    }
    #expect(FileManager.default.fileExists(atPath: paths.profile.path))
}

@Test func removingAnAbsentProfileReportsNoResidue() async throws {
    let root = try makeRemovalRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "alpha")

    let result = try await makeRemover(paths: paths).remove(confirmation: "alpha", exportReportTo: nil)
    #expect(result.residuePaths.isEmpty)
    #expect(result.removedProfile == false)
}
