import Darwin
import Foundation
import InboxPlusRuntime
import Security

public enum BridgeConfigurationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidYAMLScalar(String)
    case invalidPort(UInt16)
    case nonLoopbackHomeserver(String)
    case emptySharedSecret
    case cannotWrite(URL)

    public var description: String {
        switch self {
        case let .invalidYAMLScalar(value):
            "a configuration value contains characters that cannot be rendered safely: \(value)"
        case let .invalidPort(port):
            "\(port) is not a usable bridge port"
        case let .nonLoopbackHomeserver(address):
            "the bridge may only reach a loopback homeserver, not \(address)"
        case .emptySharedSecret:
            "the provisioning shared secret is empty"
        case let .cannotWrite(url):
            "cannot write \(url.path)"
        }
    }
}

/// Renders the `config.yaml` one mautrix `bridgev2` bridge needs.
///
/// Only the fields Inbox+ owns are written. mautrix upgrades a partial config against its own
/// defaults on startup, so pinning a full 555-line file would mean silently freezing hundreds of
/// upstream defaults at whatever they happened to be when this was written.
public struct BridgeConfiguration: Sendable {
    public static let filePermissions = 0o600
    public static let directoryPermissions = 0o700

    public let bridgeID: String
    public let displayName: String
    public let directory: URL
    public let homeserverURL: URL
    public let serverName: String
    public let ownerUserID: String
    public let appservicePort: UInt16
    public let provisioningSecret: String
    /// The appservice tokens the bridge minted when it generated its registration.
    ///
    /// They are rendered back into every config Inbox+ writes: the bridge stores them in the config
    /// itself, so re-rendering without them would silently strip its credentials, and the bridge
    /// would refuse to start against a registration Synapse has already loaded.
    public let tokens: BridgeAppserviceTokens?

    /// The `@<sender>:<server>` localpart of the bridge's own bot.
    public var senderLocalpart: String { "\(bridgeID)bot" }

    public init(
        bridgeID: String,
        displayName: String,
        directory: URL,
        homeserverURL: URL,
        serverName: String,
        ownerUserID: String,
        appservicePort: UInt16,
        provisioningSecret: String,
        tokens: BridgeAppserviceTokens? = nil
    ) {
        self.bridgeID = bridgeID
        self.displayName = displayName
        self.directory = directory
        self.homeserverURL = homeserverURL
        self.serverName = serverName
        self.ownerUserID = ownerUserID
        self.appservicePort = appservicePort
        self.provisioningSecret = provisioningSecret
        self.tokens = tokens
    }

    public var configurationFile: URL {
        directory.appendingPathComponent("config.yaml", isDirectory: false)
    }

    public var registrationFile: URL {
        directory.appendingPathComponent("registration.yaml", isDirectory: false)
    }

    public var databaseFile: URL {
        directory.appendingPathComponent("bridge.db", isDirectory: false)
    }

    public var logFile: URL {
        directory.appendingPathComponent("logs/bridge.log", isDirectory: false)
    }

    /// Where Inbox+ talks to this bridge's provisioning API.
    public var provisioningBaseURL: URL {
        URL(string: "http://127.0.0.1:\(appservicePort)")!
    }

    /// A shared secret long enough for mautrix to accept (it requires at least 16 characters).
    public static func freshProvisioningSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return Data(bytes).base64EncodedString()
    }

    public func validate() throws {
        guard appservicePort != 0 else { throw BridgeConfigurationError.invalidPort(appservicePort) }
        guard homeserverURL.host == "127.0.0.1" else {
            throw BridgeConfigurationError.nonLoopbackHomeserver(homeserverURL.absoluteString)
        }
        guard provisioningSecret.count >= 16 else {
            throw BridgeConfigurationError.emptySharedSecret
        }
        for scalar in renderedScalarValues {
            guard !Self.containsForbiddenYAMLScalar(scalar) else {
                throw BridgeConfigurationError.invalidYAMLScalar(scalar)
            }
        }
    }

    private var renderedScalarValues: [String] {
        [
            homeserverURL.absoluteString,
            serverName,
            ownerUserID,
            bridgeID,
            senderLocalpart,
            displayName,
            provisioningSecret,
            tokens?.asToken ?? "",
            tokens?.hsToken ?? "",
            databaseFile.path,
            logFile.path,
        ]
    }

    public func render() throws -> String {
        try validate()

        return """
        homeserver:
            address: \(yaml(homeserverURL.absoluteString))
            domain: \(yaml(serverName))
            software: standard

        appservice:
            address: \(yaml("http://127.0.0.1:\(appservicePort)"))
            hostname: 127.0.0.1
            port: \(appservicePort)
            id: \(yaml(bridgeID))
            bot:
                username: \(yaml(senderLocalpart))
                displayname: \(yaml("\(displayName) bridge bot"))
                avatar: ""
            ephemeral_events: true
            async_transactions: false
            username_template: \(yaml("\(bridgeID)_{{.}}"))\(renderedTokens)

        database:
            type: sqlite3-fk-wal
            uri: \(yaml("file:\(databaseFile.path)?_txlock=immediate"))
            max_open_conns: 5
            max_idle_conns: 1

        bridge:
            command_prefix: \(yaml("!\(bridgeID)"))
            personal_filtering_spaces: true
            private_chat_portal_meta: true
            permissions:
                \(yaml(ownerUserID)): admin

        backfill:
            enabled: true
            max_initial_messages: 50
            max_catchup_messages: 500

        provisioning:
            shared_secret: \(yaml(provisioningSecret))
            allow_matrix_auth: false
            debug_endpoints: false

        double_puppet:
            secrets: {}

        # Synapse is loopback-only and the store is already encrypted at rest, so end-to-bridge
        # encryption would add a second key hierarchy without adding a boundary.
        encryption:
            allow: false
            default: false
            require: false

        logging:
            min_level: info
            writers:
                - type: file
                  format: json
                  filename: \(yaml(logFile.path))
                  max_size: 10
                  max_backups: 3
                  compress: false
        """
    }

    public func withTokens(_ tokens: BridgeAppserviceTokens) -> BridgeConfiguration {
        BridgeConfiguration(
            bridgeID: bridgeID,
            displayName: displayName,
            directory: directory,
            homeserverURL: homeserverURL,
            serverName: serverName,
            ownerUserID: ownerUserID,
            appservicePort: appservicePort,
            provisioningSecret: provisioningSecret,
            tokens: tokens
        )
    }

    private var renderedTokens: String {
        guard let tokens else { return "" }
        // Joined explicitly rather than written as a multiline literal: an escaped newline inside
        // one defeats Swift's indentation stripping for the line that follows it, which YAML then
        // reads as a nested key.
        return "\n    as_token: \(yaml(tokens.asToken))\n    hs_token: \(yaml(tokens.hsToken))"
    }

    /// Writes `config.yaml` `0600` into a `0700` directory, publishing atomically.
    @discardableResult
    public func write() throws -> URL {
        let contents = try render()
        try FileManager.default.createDirectory(
            at: logFile.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.directoryPermissions],
            ofItemAtPath: directory.path
        )

        let staging = directory.appendingPathComponent(
            ".config.yaml.\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard FileManager.default.createFile(
            atPath: staging.path,
            contents: Data(contents.utf8),
            attributes: [.posixPermissions: Self.filePermissions]
        ) else { throw BridgeConfigurationError.cannotWrite(configurationFile) }
        do {
            try Self.syncFile(at: staging)
            _ = try FileManager.default.replaceItemAt(configurationFile, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: configurationFile.path
        )
        return configurationFile
    }

    /// Every value a hostile input could reach is single-quoted, so the check only has to reject
    /// what single quoting cannot contain.
    static func containsForbiddenYAMLScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\0"
                || (scalar.value < 0x20 && scalar != "\t")
        }
    }

    private func yaml(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func syncFile(at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY)
        guard descriptor >= 0 else { throw BridgeConfigurationError.cannotWrite(url) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw BridgeConfigurationError.cannotWrite(url) }
    }
}

/// The `as_token`/`hs_token` pair a bridge writes into its own appservice registration.
public struct BridgeAppserviceTokens: Sendable, Equatable {
    public let asToken: String
    public let hsToken: String

    public init(asToken: String, hsToken: String) {
        self.asToken = asToken
        self.hsToken = hsToken
    }

    /// Reads the pair back out of a registration file.
    ///
    /// The registration is the single source of truth: Synapse has loaded exactly these tokens, so
    /// reading them beats caching a copy that could drift out of step with the homeserver.
    public static func read(fromRegistrationAt url: URL) throws -> BridgeAppserviceTokens {
        let contents = try String(contentsOf: url, encoding: .utf8)
        func scalar(_ key: String) -> String? {
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\(key):") else { continue }
                var value = String(trimmed.dropFirst(key.count + 1))
                    .trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
                    value = String(value.dropFirst().dropLast())
                        .replacingOccurrences(of: "''", with: "'")
                } else if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                return value.isEmpty ? nil : value
            }
            return nil
        }
        guard let asToken = scalar("as_token"), let hsToken = scalar("hs_token") else {
            throw BridgeConfigurationError.cannotWrite(url)
        }
        return BridgeAppserviceTokens(asToken: asToken, hsToken: hsToken)
    }
}
