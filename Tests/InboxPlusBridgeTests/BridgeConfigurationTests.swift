import Foundation
import Testing
@testable import InboxPlusBridge
@testable import InboxPlusBridgeService
@testable import InboxPlusRuntime

private func makeConfiguration(
    directory: URL,
    ownerUserID: String = "@inboxplus:inboxplus.localhost",
    secret: String = "0123456789abcdef0123456789abcdef",
    tokens: BridgeAppserviceTokens? = nil
) -> BridgeConfiguration {
    BridgeConfiguration(
        bridgeID: "instagram",
        displayName: "Instagram",
        directory: directory,
        homeserverURL: URL(string: "http://127.0.0.1:8008")!,
        serverName: "inboxplus.localhost",
        ownerUserID: ownerUserID,
        appservicePort: 29_337,
        provisioningSecret: secret,
        tokens: tokens
    )
}

private func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .resolvingSymlinksInPath()
        .appendingPathComponent("inboxplus-bridgeconfig-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func theRenderedConfigurationNamesTheHomeserverBridgeAndDatabase() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let rendered = try makeConfiguration(directory: directory).render()
    #expect(rendered.contains("address: 'http://127.0.0.1:8008'"))
    #expect(rendered.contains("domain: 'inboxplus.localhost'"))
    #expect(rendered.contains("id: 'instagram'"))
    #expect(rendered.contains("username: 'instagrambot'"))
    #expect(rendered.contains("port: 29337"))
    #expect(rendered.contains("type: sqlite3-fk-wal"))
    #expect(rendered.contains("'@inboxplus:inboxplus.localhost': admin"))
}

@Test func theBridgeIsNeverAllowedToReachANonLoopbackHomeserver() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let configuration = BridgeConfiguration(
        bridgeID: "instagram",
        displayName: "Instagram",
        directory: directory,
        homeserverURL: URL(string: "http://10.0.0.7:8008")!,
        serverName: "inboxplus.localhost",
        ownerUserID: "@inboxplus:inboxplus.localhost",
        appservicePort: 29_337,
        provisioningSecret: "0123456789abcdef0123456789abcdef"
    )
    #expect(throws: BridgeConfigurationError.nonLoopbackHomeserver("http://10.0.0.7:8008")) {
        try configuration.render()
    }
}

@Test func aShortProvisioningSecretIsRejectedBeforeTheBridgeEverSeesIt() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // mautrix requires at least 16 characters; catching it here beats a bridge that starts and
    // then refuses every provisioning call.
    #expect(throws: BridgeConfigurationError.emptySharedSecret) {
        try makeConfiguration(directory: directory, secret: "short").render()
    }
}

@Test func aHostileValueCannotBreakOutOfAYAMLScalar() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: (any Error).self) {
        try makeConfiguration(
            directory: directory,
            ownerUserID: "@a:b\npermissions:\n  '*': admin"
        ).render()
    }
}

@Test func aQuoteInAValueIsEscapedRatherThanRejected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let rendered = try makeConfiguration(directory: directory, ownerUserID: "@o'brien:inboxplus.localhost")
        .render()
    #expect(rendered.contains("'@o''brien:inboxplus.localhost': admin"))
}

@Test func aWrittenConfigurationIsUserOnly() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = try makeConfiguration(directory: directory).write()
    let permissions = try FileManager.default
        .attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600, "a config holding the provisioning secret must be user-only")
}

@Test func tokensAreRenderedAtTheAppserviceLevelSoTheBridgeCanFindThem() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let tokens = BridgeAppserviceTokens(asToken: "as-secret", hsToken: "hs-secret")
    let rendered = try makeConfiguration(directory: directory, tokens: tokens).render()

    // Break caught: an escaped newline in a multiline literal defeated Swift's indentation
    // stripping, nesting as_token under username_template and making the YAML unparseable.
    let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false)
    let asLine = try #require(lines.first { $0.contains("as_token:") })
    let hsLine = try #require(lines.first { $0.contains("hs_token:") })
    #expect(asLine == "    as_token: 'as-secret'")
    #expect(hsLine == "    hs_token: 'hs-secret'")
}

@Test func aConfigurationWithoutTokensOmitsThemEntirely() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let rendered = try makeConfiguration(directory: directory).render()
    #expect(!rendered.contains("as_token"))
    #expect(!rendered.contains("hs_token"))
}

@Test func tokensAreReadBackFromARegistrationInTheFormatBridgesWriteIt() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Exactly the shape mautrix-instagram v0.2607.0 emits: bare, unquoted scalars.
    let registration = directory.appendingPathComponent("registration.yaml")
    try """
    id: instagram
    url: http://127.0.0.1:29337
    as_token: l23UdfMVoLeQzk0NMvFELErfpMSZjz22
    hs_token: CmqCCxfb6Caia928DBzmrR9hmi8tEkqE
    sender_localpart: instagrambot
    """.write(to: registration, atomically: true, encoding: .utf8)

    let tokens = try BridgeAppserviceTokens.read(fromRegistrationAt: registration)
    #expect(tokens.asToken == "l23UdfMVoLeQzk0NMvFELErfpMSZjz22")
    #expect(tokens.hsToken == "CmqCCxfb6Caia928DBzmrR9hmi8tEkqE")
}

@Test func quotedRegistrationTokensAreUnquotedOnTheWayBackIn() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let registration = directory.appendingPathComponent("registration.yaml")
    try """
    as_token: 'quoted-as'
    hs_token: "quoted-hs"
    """.write(to: registration, atomically: true, encoding: .utf8)

    let tokens = try BridgeAppserviceTokens.read(fromRegistrationAt: registration)
    #expect(tokens.asToken == "quoted-as")
    #expect(tokens.hsToken == "quoted-hs")
}

@Test func aRegistrationMissingItsTokensIsRejected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let registration = directory.appendingPathComponent("registration.yaml")
    try "id: instagram\n".write(to: registration, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) {
        try BridgeAppserviceTokens.read(fromRegistrationAt: registration)
    }
}

@Test func everyGeneratedProvisioningSecretIsLongEnoughAndDistinct() {
    let secrets = (0..<32).map { _ in BridgeConfiguration.freshProvisioningSecret() }
    #expect(Set(secrets).count == secrets.count)
    #expect(secrets.allSatisfy { $0.count >= 16 })
}
