import Foundation
import Testing
@testable import InboxPlusRuntime

@Test func bundledRuntimeRejectsChangedLockBeforeInstallingAnything() throws {
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches").appendingPathComponent("InboxPlusBundle-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("package")
    let input = package.appendingPathComponent("Runtime/Synapse")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Runtime/Synapse")
    try FileManager.default.copyItem(at: repo.appendingPathComponent("runtime-manifest.json"), to: input.appendingPathComponent("runtime-manifest.json"))
    try Data("matrix-synapse==wrong\n".utf8).write(to: input.appendingPathComponent("requirements.lock"))
    let paths = try RuntimePaths(root: root.appendingPathComponent("profiles"), profileName: "default")
    #expect(throws: RuntimeManifestError.self) { try BundledRuntime(packageRoot: package).install(paths: paths) }
    #expect(!FileManager.default.fileExists(atPath: paths.runtime.path))
}

@Test func missingBundledPythonDoesNotCreateAPartialRuntime() throws {
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches").appendingPathComponent("InboxPlusBundle-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try RuntimePaths(root: root, profileName: "default")
    let package = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    #expect(throws: RuntimeManifestError.self) { try BundledRuntime(packageRoot: package).install(paths: paths) }
    #expect(!FileManager.default.fileExists(atPath: paths.runtime.path))
}

@Test func failedBundledImportRollsBackAndCanBeRetried() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/InboxPlusBundle-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    let package = root.appendingPathComponent("package")
    try fm.createDirectory(at: package.appendingPathComponent("Runtime"), withIntermediateDirectories: true)
    let inputs = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Runtime/Synapse")
    try fm.copyItem(at: inputs, to: package.appendingPathComponent("Runtime/Synapse"))
    let python = package.appendingPathComponent("Runtime/Python/bin/python3.12")
    try fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: python)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
    let paths = try RuntimePaths(root: root.appendingPathComponent("profiles"), profileName: "default")
    let installer = BundledRuntime(packageRoot: package)
    for _ in 0..<2 {
        #expect(throws: RuntimeManifestError.self) { try installer.install(paths: paths) }
        #expect(!fm.fileExists(atPath: paths.runtime.path))
        #expect(try fm.contentsOfDirectory(atPath: paths.profile.path).isEmpty)
    }
}
