import Foundation
import Testing
@testable import InboxPlusRuntime

@Test func renderedConfigurationHasExactlyOnePrivateClientListener() throws {
    // Break caught: a second, non-loopback, or federation-capable listener is rendered.
    let configuration = try fixtureConfiguration(port: 18_008)
    let document = try ParsedSynapseConfiguration(yaml: configuration.render())

    #expect(document.listeners == [
        .init(port: 18_008, bindAddresses: ["127.0.0.1"], resources: [["client"]]),
    ])
    #expect(document.booleanValue(for: "send_federation") == false)
    #expect(document.booleanValue(for: "enable_metrics") == false)
    #expect(!document.listeners.flatMap(\.resources).flatMap { $0 }.contains("federation"))
}

@Test func renderedConfigurationDisablesPublicFeaturesAndKeepsLocalAdminSecret() throws {
    // Break caught: an accidental change enables an unauthenticated/public Synapse feature or omits local admin setup.
    let document = try ParsedSynapseConfiguration(yaml: fixtureConfiguration().render())

    #expect(document.booleanValue(for: "enable_registration") == false)
    #expect(document.booleanValue(for: "allow_guest_access") == false)
    #expect(document.booleanValue(for: "enable_3pid_lookup") == false)
    #expect(document.booleanValue(for: "enable_room_list_search") == false)
    #expect(document.emptyArrayValue(for: "room_list_publication_rules"))
    #expect(document.booleanValue(for: "allow_public_rooms_without_auth") == false)
    #expect(document.booleanValue(for: "allow_public_rooms_over_federation") == false)
    #expect(document.booleanValue(for: "url_preview_enabled") == false)
    #expect(document.booleanValue(for: "enable_metrics") == false)
    #expect(document.booleanValue(for: "report_stats") == false)
    #expect(document.scalarValue(for: "registration_shared_secret") == "registration-secret")
}

@Test func quotedScalarsPreserveApostrophesAndUnicode() throws {
    // Break caught: YAML quoting corrupts an administration secret containing ordinary user data.
    let document = try ParsedSynapseConfiguration(
        yaml: fixtureConfiguration(registrationSecret: "O'Brien λ").render()
    )

    #expect(document.scalarValue(for: "registration_shared_secret") == "O'Brien λ")
}

@Test(arguments: ["line\nbreak", "control\u{0001}", "separator\u{0085}"])
func configurationRejectsControlScalarsInAdministrationSecrets(_ secret: String) throws {
    // Break caught: a control scalar changes or invalidates the rendered YAML secret.
    let configuration = try fixtureConfiguration(registrationSecret: secret)

    #expect(throws: SynapseConfigurationError.invalidYAMLScalar(secret)) {
        try configuration.render()
    }
}

@Test func configurationRejectsControlScalarsInProfilePaths() throws {
    // Break caught: a control scalar in a profile-derived path changes or invalidates rendered YAML.
    let root = testDirectory().appendingPathComponent("runtime\nroot", isDirectory: true)
    let profile = try RuntimePaths(root: root, profileName: "configuration-tests")
    let configuration = SynapseConfiguration(
        profile: profile,
        port: 18_008,
        credentials: SynapseCredentials(registrationSecret: "registration-secret")
    )

    #expect(throws: SynapseConfigurationError.self) {
        try configuration.render()
    }
}

@Test func nonLoopbackListenerIsRejected() throws {
    // Break caught: configuration validation accepts a remotely reachable listener.
    let configuration = try fixtureConfiguration(bindAddress: "0.0.0.0")

    #expect(throws: SynapseConfigurationError.nonLoopbackAddress("0.0.0.0")) {
        try configuration.validate()
    }
}

@Test func zeroPortIsRejected() throws {
    // Break caught: configuration validation accepts a port Synapse cannot bind.
    let configuration = try fixtureConfiguration(port: 0)

    #expect(throws: SynapseConfigurationError.invalidPort(0)) {
        try configuration.validate()
    }
}

@Test func configurationRequiresAnAdministrationSecret() throws {
    // Break caught: configuration renders without the secret required for authenticated local administration.
    let configuration = try fixtureConfiguration(registrationSecret: "")

    #expect(throws: SynapseConfigurationError.emptyRegistrationSecret) {
        try configuration.validate()
    }
}

@Test func writesOnlyToProfileConfigurationWithUserOnlyPermissions() throws {
    // Break caught: a secret-bearing config is written outside the validated profile or is visible to other local users.
    let directory = testDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = try RuntimePaths(
        root: directory.appendingPathComponent("runtime", isDirectory: true),
        profileName: "configuration-tests"
    )
    let configuration = SynapseConfiguration(
        profile: profile,
        port: 18_008,
        credentials: SynapseCredentials(registrationSecret: "registration-secret")
    )

    let configurationFile = try configuration.write()

    #expect(configurationFile == profile.configuration.appendingPathComponent("homeserver.yaml", isDirectory: false))
    #expect(try permissions(of: profile.profile) == 0o700)
    #expect(try permissions(of: profile.configuration) == 0o700)
    #expect(try permissions(of: configurationFile) == 0o600)
    #expect(try String(contentsOf: configurationFile, encoding: .utf8) == configuration.render())
}

@Test func writerRejectsASymlinkedConfigurationAncestor() throws {
    // Break caught: a profile configuration write follows a replaced directory symlink outside the profile.
    let directory = testDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = try RuntimePaths(
        root: directory.appendingPathComponent("runtime", isDirectory: true),
        profileName: "configuration-tests"
    )
    let outsideDirectory = directory.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: profile.profile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: profile.configuration, withDestinationURL: outsideDirectory)
    let configuration = SynapseConfiguration(
        profile: profile,
        port: 18_008,
        credentials: SynapseCredentials(registrationSecret: "registration-secret")
    )

    #expect(throws: SynapseConfigurationError.symlinkedConfigurationAncestor(profile.configuration)) {
        try configuration.write()
    }
}

private func fixtureConfiguration(
    bindAddress: String = "127.0.0.1",
    port: UInt16 = 18_008,
    registrationSecret: String = "registration-secret"
) throws -> SynapseConfiguration {
    SynapseConfiguration(
        profile: try fixtureProfile(),
        bindAddress: bindAddress,
        port: port,
        credentials: SynapseCredentials(registrationSecret: registrationSecret)
    )
}

private func fixtureProfile() throws -> RuntimePaths {
    try RuntimePaths(
        root: testDirectory().appendingPathComponent("runtime", isDirectory: true),
        profileName: "configuration-tests"
    )
}

private func testDirectory() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build/SynapseConfigurationTests-\(UUID().uuidString)", isDirectory: true)
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue & 0o777
}

private struct ParsedSynapseConfiguration {
    struct Listener: Equatable {
        let port: UInt16
        let bindAddresses: [String]
        let resources: [[String]]
    }

    let listeners: [Listener]
    private let topLevelValues: [String: String]

    init(yaml: String) throws {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var topLevelValues: [String: String] = [:]
        var listeners: [Listener] = []
        var listenerPort: UInt16?
        var listenerAddresses: [String] = []
        var listenerResources: [[String]] = []

        for line in lines {
            if !line.hasPrefix(" "), let separator = line.firstIndex(of: ":") {
                topLevelValues[String(line[..<separator])] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("  - port: ") {
                if let listenerPort {
                    listeners.append(.init(port: listenerPort, bindAddresses: listenerAddresses, resources: listenerResources))
                }
                listenerPort = UInt16(line.dropFirst("  - port: ".count))
                listenerAddresses = []
                listenerResources = []
            } else if line.hasPrefix("    bind_addresses: ") {
                listenerAddresses = try Self.flowSequence(String(line.dropFirst("    bind_addresses: ".count)))
            } else if line.hasPrefix("      - names: ") {
                listenerResources.append(try Self.flowSequence(String(line.dropFirst("      - names: ".count))))
            }
        }
        if let listenerPort {
            listeners.append(.init(port: listenerPort, bindAddresses: listenerAddresses, resources: listenerResources))
        }

        self.listeners = listeners
        self.topLevelValues = topLevelValues
    }

    func booleanValue(for key: String) -> Bool? {
        switch topLevelValues[key] {
        case "true": true
        case "false": false
        default: nil
        }
    }

    func emptyArrayValue(for key: String) -> Bool {
        topLevelValues[key] == "[]"
    }

    func scalarValue(for key: String) -> String? {
        guard let value = topLevelValues[key], value.count >= 2,
              value.first == "'", value.last == "'"
        else {
            return nil
        }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }

    private static func flowSequence(_ value: String) throws -> [String] {
        guard value.first == "[", value.last == "]" else {
            throw ParseError.invalidFlowSequence(value)
        }
        let contents = value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !contents.isEmpty else {
            return []
        }
        return contents.split(separator: ",").map { item in
            item.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        }
    }

    enum ParseError: Error {
        case invalidFlowSequence(String)
    }
}
