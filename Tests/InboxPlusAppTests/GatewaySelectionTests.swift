import Foundation
import Testing
@testable import InboxPlusApp

@MainActor
@Test func launchWithoutPreparedProfileContainsNoDemoData() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InboxPlusEmptyLaunch-\(UUID().uuidString)")
    // A nonexistent, isolated root represents a fresh install without touching real profiles.
    let services = GatewaySelection.makeServices(environment: ["INBOXPLUS_RUNTIME_ROOT": root.path])
    let snapshot = try await services.gateway.loadSnapshot()
    #expect(snapshot.accounts.isEmpty)
    #expect(snapshot.conversations.isEmpty)
    #expect(snapshot.messagesByRoute.isEmpty)
    #expect(services.directory.people.isEmpty)
    #expect(services.directory.links.isEmpty)
}

@Test func bundledFreshInstallSelectsDefaultProfileWithoutManualSetup() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("InboxPlusSelection-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("package")
    let python = package.appendingPathComponent("Runtime/Python/bin/python3.12")
    try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("placeholder".utf8).write(to: python)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
    let environment = ["INBOXPLUS_RUNTIME_ROOT": root.appendingPathComponent("profiles").path,
                       "INBOXPLUS_RUNTIME_PACKAGE_ROOT": package.path]
    #expect(GatewaySelection.resolveProfileName(environment: environment) == "default")
    var named = environment
    named["INBOXPLUS_PROFILE"] = "work"
    #expect(GatewaySelection.resolveProfileName(environment: named) == "work")
}
