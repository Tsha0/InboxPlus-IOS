import Foundation
import Testing
@testable import InboxPlusRuntime

@Test func installedRuntimeFindsBundledInputsWithoutCheckout() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InboxPlusBundle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Inbox+.app/Contents/Resources")
    let inputs = resources.appendingPathComponent("Runtime/Synapse")
    try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: inputs.appendingPathComponent("runtime-manifest.json"))
    for name in ["InboxPlus", "InboxPlusRuntimeCLI"] {
        let executable = root.appendingPathComponent("Inbox+.app/Contents/MacOS/\(name)")
        #expect(RuntimeProfileService.resolvedPackageRoot(
            environment: [:], executableURL: executable
        ) == resources.standardizedFileURL)
        #expect(RuntimeProfileService.resolvedPackageRoot(
            environment: ["INBOXPLUS_RUNTIME_PACKAGE_ROOT": root.path], executableURL: executable
        ) == root.standardizedFileURL)
    }
}
