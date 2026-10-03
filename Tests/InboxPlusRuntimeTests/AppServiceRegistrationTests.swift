import Darwin
import Foundation
import Testing
@testable import InboxPlusRuntime

private func testRoot() -> URL {
    // The temporary directory lives under /var, a symlink that `RuntimePaths` refuses and that
    // `standardizedFileURL` maps back from /private/var. The home directory has no such ancestor.
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Caches", isDirectory: true)
        .appendingPathComponent("InboxPlusAppServiceTests-\(UUID().uuidString)", isDirectory: true)
}

private func fixtureRegistration(
    id: String = "telegram",
    senderLocalpart: String = "telegrambot",
    serverName: String = "inboxplus.localhost",
    url: String? = "http://127.0.0.1:29328"
) -> AppServiceRegistration {
    AppServiceRegistration.bridge(
        id: id,
        senderLocalpart: senderLocalpart,
        serverName: serverName,
        asToken: String(repeating: "a", count: 43),
        hsToken: String(repeating: "h", count: 43),
        url: url
    )
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let value = try #require(attributes[.posixPermissions] as? NSNumber)
    return value.intValue & 0o777
}

@Test func renderedRegistrationCarriesEverySynapseRequiredKey() throws {
    // Break caught: a missing key makes Synapse reject the registration and refuse to start.
    let yaml = try fixtureRegistration().render()

    for key in ["id:", "url:", "as_token:", "hs_token:", "sender_localpart:", "namespaces:", "rate_limited:"] {
        #expect(yaml.contains(key))
    }
    #expect(yaml.contains("  users:"))
    #expect(yaml.contains("  aliases:"))
    #expect(yaml.contains("  rooms: []"))
    #expect(yaml.contains("    - exclusive: true"))
    #expect(yaml.contains("rate_limited: false"))
    #expect(yaml.contains("url: 'http://127.0.0.1:29328'"))
}

@Test func aPullOnlyBridgeRendersANullURL() throws {
    // Break caught: an empty string instead of null makes Synapse push to an unroutable address.
    #expect(try fixtureRegistration(url: nil).render().contains("url: null"))
}

@Test func bridgeNamespacesEscapeTheServerNameDots() throws {
    // Break caught: an unescaped dot makes the namespace regex claim users on other domains.
    let registration = fixtureRegistration()

    #expect(registration.users == [
        AppServiceNamespace(exclusive: true, regex: "@telegram_.*:inboxplus\\.localhost"),
    ])
    #expect(registration.aliases == [
        AppServiceNamespace(exclusive: true, regex: "#telegram_.*:inboxplus\\.localhost"),
    ])
    #expect(registration.rooms.isEmpty)
}

@Test func anEmptyIdentifierIsRejected() throws {
    #expect(throws: AppServiceRegistrationError.emptyIdentifier) {
        try fixtureRegistration(id: "").validate()
    }
}

@Test func anEmptySenderLocalpartIsRejected() throws {
    #expect(throws: AppServiceRegistrationError.emptySenderLocalpart) {
        try fixtureRegistration(senderLocalpart: "").validate()
    }
}

@Test(arguments: ["tele gram", "telegram/../etc", "telegram:bridge"])
func anUnsafeIdentifierIsRejected(_ id: String) throws {
    // Break caught: an id containing path or Matrix separators escapes the registration directory.
    #expect(throws: AppServiceRegistrationError.invalidIdentifier(id)) {
        try fixtureRegistration(id: id).validate()
    }
}

@Test func anUnsafeSenderLocalpartIsRejected() throws {
    #expect(throws: AppServiceRegistrationError.invalidSenderLocalpart("telegram bot")) {
        try fixtureRegistration(senderLocalpart: "telegram bot").validate()
    }
}

@Test func anEmptyTokenIsRejected() throws {
    let registration = AppServiceRegistration(
        id: "telegram",
        asToken: "",
        hsToken: String(repeating: "h", count: 43),
        senderLocalpart: "telegrambot"
    )

    #expect(throws: AppServiceRegistrationError.emptyToken) {
        try registration.validate()
    }
}

@Test func aShortTokenIsRejected() throws {
    // Break caught: a guessable appservice token lets any local process impersonate the bridge.
    let registration = AppServiceRegistration(
        id: "telegram",
        asToken: String(repeating: "a", count: 31),
        hsToken: String(repeating: "h", count: 43),
        senderLocalpart: "telegrambot"
    )

    #expect(throws: AppServiceRegistrationError.tokenTooShort(minimum: 32)) {
        try registration.validate()
    }
}

@Test func anEmptyNamespaceRegexIsRejected() throws {
    // Break caught: an empty regex matches every user, giving the bridge the whole homeserver.
    let registration = AppServiceRegistration(
        id: "telegram",
        asToken: String(repeating: "a", count: 43),
        hsToken: String(repeating: "h", count: 43),
        senderLocalpart: "telegrambot",
        users: [AppServiceNamespace(exclusive: true, regex: "")]
    )

    #expect(throws: AppServiceRegistrationError.emptyNamespaceRegex) {
        try registration.validate()
    }
}

@Test func writtenRegistrationIsUserOnlyInAUserOnlyDirectory() throws {
    // Break caught: a token-bearing registration is readable by every other local user.
    let root = testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("appservices", isDirectory: true)
    let registration = fixtureRegistration()

    let file = try registration.write(to: directory)

    #expect(file == directory.appendingPathComponent("telegram.yaml", isDirectory: false))
    #expect(try permissions(of: directory) == 0o700)
    #expect(try permissions(of: file) == 0o600)
    #expect(try String(contentsOf: file, encoding: .utf8) == registration.render())
}

@Test func rewritingARegistrationLeavesNoStagingResidue() throws {
    let root = testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("appservices", isDirectory: true)
    try fixtureRegistration().write(to: directory)
    try fixtureRegistration(url: nil).write(to: directory)

    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(contents == ["telegram.yaml"])
}

@Test func randomTokensAreLongAndDoNotRepeat() throws {
    // Break caught: a constant or short token makes every profile's bridge credentials guessable.
    let tokens = (0 ..< 32).map { _ in AppServiceRegistration.randomToken() }

    #expect(tokens.allSatisfy { $0.count >= 32 })
    #expect(Set(tokens).count == tokens.count)
}

@Test func configurationEmitsAnEmptyAppServiceListWhenNoBridgesAreRegistered() throws {
    // Break caught: Synapse fails to parse a dangling `app_service_config_files:` key.
    let root = testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try fixtureConfiguration(root: root)

    #expect(try configuration.render().contains("app_service_config_files: []"))
}

@Test func configurationListsEveryRegisteredBridgeInSortedOrder() throws {
    // Break caught: a written registration is never referenced, so the bridge cannot connect.
    let root = testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try fixtureConfiguration(root: root)
    let whatsapp = try fixtureRegistration(id: "whatsapp", senderLocalpart: "whatsappbot")
        .write(to: configuration.appServiceDirectory)
    let telegram = try fixtureRegistration().write(to: configuration.appServiceDirectory)

    let yaml = try configuration.render()

    #expect(yaml.contains("""
    app_service_config_files:
      - '\(telegram.path)'
      - '\(whatsapp.path)'
    """))
}

private func fixtureConfiguration(root: URL) throws -> SynapseConfiguration {
    SynapseConfiguration(
        profile: try RuntimePaths(
            root: root.appendingPathComponent("runtime", isDirectory: true),
            profileName: "appservice-tests"
        ),
        port: 18_008,
        credentials: SynapseCredentials(registrationSecret: "registration-secret")
    )
}
