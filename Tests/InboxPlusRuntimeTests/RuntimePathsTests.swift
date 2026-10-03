import Foundation
import Testing
@testable import InboxPlusRuntime

@Test(arguments: ["../escape", "/tmp/escape", "a/b", "", "."])
func profileNameCannotEscapeRoot(_ name: String) {
    #expect(throws: RuntimePathError.self) {
        try RuntimePaths(root: URL(fileURLWithPath: "/tmp/inboxplus-runtime"), profileName: name)
    }
}

@Test func profileLayoutUsesStandardizedContainedPaths() throws {
    let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let root = workingDirectory.appendingPathComponent(".build/inboxplus-runtime/../inboxplus-runtime")
    let paths = try RuntimePaths(root: root, profileName: "primary_profile")

    let expectedRoot = workingDirectory
        .appendingPathComponent(".build/inboxplus-runtime")
        .standardizedFileURL
    #expect(paths.root == expectedRoot)
    #expect(paths.profile == expectedRoot.appendingPathComponent("primary_profile", isDirectory: true))
    #expect(paths.runtime == paths.profile.appendingPathComponent("runtime", isDirectory: true))
    #expect(paths.configuration == paths.profile.appendingPathComponent("configuration", isDirectory: true))
    #expect(paths.data == paths.profile.appendingPathComponent("data", isDirectory: true))
    #expect(paths.logs == paths.profile.appendingPathComponent("logs", isDirectory: true))
    #expect(paths.backups == paths.profile.appendingPathComponent("backups", isDirectory: true))
    #expect(paths.reports == paths.profile.appendingPathComponent("reports", isDirectory: true))
    #expect(paths.state == paths.profile.appendingPathComponent("state", isDirectory: true))
}

@Test func symlinkedRootAncestorIsRejected() throws {
    let temporaryDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build/InboxPlusRuntimeTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let realRoot = temporaryDirectory.appendingPathComponent("real-root", isDirectory: true)
    let symlink = temporaryDirectory.appendingPathComponent("linked-root", isDirectory: true)
    try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realRoot)

    #expect(throws: RuntimePathError.self) {
        try RuntimePaths(root: symlink, profileName: "primary")
    }
}

@Test func danglingSymlinkedRootAncestorIsRejected() throws {
    let temporaryDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build/InboxPlusRuntimeTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let symlink = temporaryDirectory.appendingPathComponent("dangling-root", isDirectory: true)
    let missingDestination = temporaryDirectory.appendingPathComponent("missing-root", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: missingDestination)

    #expect(throws: RuntimePathError.self) {
        try RuntimePaths(root: symlink, profileName: "primary")
    }
}
