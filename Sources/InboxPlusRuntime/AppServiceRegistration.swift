import Darwin
import Foundation
import Security

/// A single `users`/`aliases`/`rooms` namespace entry in a Matrix application service registration.
public struct AppServiceNamespace: Sendable, Equatable {
    public let exclusive: Bool
    public let regex: String

    public init(exclusive: Bool, regex: String) {
        self.exclusive = exclusive
        self.regex = regex
    }
}

/// The registration file a Matrix application service (bridge) needs Synapse to load.
///
/// Synapse only talks to bridges listed in `app_service_config_files`, and it reads each entry as
/// a standalone YAML document with a fixed key set.
public struct AppServiceRegistration: Sendable, Equatable {
    public static let filePermissions = 0o600
    public static let directoryPermissions = 0o700
    public static let minimumTokenLength = 32

    public let id: String
    public let asToken: String
    public let hsToken: String
    public let senderLocalpart: String
    public let users: [AppServiceNamespace]
    public let aliases: [AppServiceNamespace]
    public let rooms: [AppServiceNamespace]
    /// `nil` means the appservice pulls rather than receives pushes, which Synapse renders as a null URL.
    public let url: String?
    public let rateLimited: Bool

    public init(
        id: String,
        asToken: String,
        hsToken: String,
        senderLocalpart: String,
        users: [AppServiceNamespace] = [],
        aliases: [AppServiceNamespace] = [],
        rooms: [AppServiceNamespace] = [],
        url: String? = nil,
        rateLimited: Bool = false
    ) {
        self.id = id
        self.asToken = asToken
        self.hsToken = hsToken
        self.senderLocalpart = senderLocalpart
        self.users = users
        self.aliases = aliases
        self.rooms = rooms
        self.url = url
        self.rateLimited = rateLimited
    }

    /// Builds the namespaces a bridge conventionally claims: every `@<id>_*` user and `#<id>_*` alias.
    public static func bridge(
        id: String,
        senderLocalpart: String,
        serverName: String,
        asToken: String = AppServiceRegistration.randomToken(),
        hsToken: String = AppServiceRegistration.randomToken(),
        url: String? = nil
    ) -> AppServiceRegistration {
        let domain = escapingRegexMetacharacters(serverName)
        return AppServiceRegistration(
            id: id,
            asToken: asToken,
            hsToken: hsToken,
            senderLocalpart: senderLocalpart,
            users: [AppServiceNamespace(exclusive: true, regex: "@\(id)_.*:\(domain)")],
            aliases: [AppServiceNamespace(exclusive: true, regex: "#\(id)_.*:\(domain)")],
            rooms: [],
            url: url,
            rateLimited: false
        )
    }

    public static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return Data(bytes).base64EncodedString()
    }

    public func validate() throws {
        guard !id.isEmpty else { throw AppServiceRegistrationError.emptyIdentifier }
        guard !senderLocalpart.isEmpty else { throw AppServiceRegistrationError.emptySenderLocalpart }
        guard Self.isSafeIdentifier(id) else { throw AppServiceRegistrationError.invalidIdentifier(id) }
        guard Self.isSafeIdentifier(senderLocalpart) else {
            throw AppServiceRegistrationError.invalidSenderLocalpart(senderLocalpart)
        }
        guard !asToken.isEmpty else { throw AppServiceRegistrationError.emptyToken }
        guard !hsToken.isEmpty else { throw AppServiceRegistrationError.emptyToken }
        guard asToken.count >= Self.minimumTokenLength, hsToken.count >= Self.minimumTokenLength else {
            throw AppServiceRegistrationError.tokenTooShort(minimum: Self.minimumTokenLength)
        }
        for namespace in users + aliases + rooms {
            guard !namespace.regex.isEmpty else { throw AppServiceRegistrationError.emptyNamespaceRegex }
        }
    }

    public func render() throws -> String {
        try validate()

        var lines = [
            "id: \(Self.yamlString(id))",
            "url: \(url.map(Self.yamlString) ?? "null")",
            "as_token: \(Self.yamlString(asToken))",
            "hs_token: \(Self.yamlString(hsToken))",
            "sender_localpart: \(Self.yamlString(senderLocalpart))",
            "namespaces:",
        ]
        for (key, namespaces) in [("users", users), ("aliases", aliases), ("rooms", rooms)] {
            if namespaces.isEmpty {
                lines.append("  \(key): []")
            } else {
                lines.append("  \(key):")
                for namespace in namespaces {
                    lines.append("    - exclusive: \(namespace.exclusive)")
                    lines.append("      regex: \(Self.yamlString(namespace.regex))")
                }
            }
        }
        lines.append("rate_limited: \(rateLimited)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes `<id>.yaml` into `directory`, creating it user-only and publishing atomically.
    @discardableResult
    public func write(to directory: URL) throws -> URL {
        let yaml = try render()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.directoryPermissions],
            ofItemAtPath: directory.path
        )

        let destination = directory.appendingPathComponent("\(id).yaml", isDirectory: false)
        let staging = directory.appendingPathComponent(
            ".\(id).yaml.\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard FileManager.default.createFile(
            atPath: staging.path,
            contents: Data(yaml.utf8),
            attributes: [.posixPermissions: Self.filePermissions]
        ) else {
            throw AppServiceRegistrationError.cannotWrite(destination)
        }
        do {
            try Self.syncFile(at: staging)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: destination.path
        )
        return destination
    }

    static func escapingRegexMetacharacters(_ value: String) -> String {
        let metacharacters = Set(".^$*+?()[]{}|\\-/")
        return String(value.flatMap { character -> [Character] in
            metacharacters.contains(character) ? ["\\", character] : [character]
        })
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    private static func yamlString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func syncFile(at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY)
        guard descriptor >= 0 else { throw AppServiceRegistrationError.cannotWrite(url) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw AppServiceRegistrationError.cannotWrite(url) }
    }
}

public enum AppServiceRegistrationError: Error, Equatable, Sendable {
    case emptyIdentifier
    case invalidIdentifier(String)
    case emptySenderLocalpart
    case invalidSenderLocalpart(String)
    case emptyToken
    case tokenTooShort(minimum: Int)
    case emptyNamespaceRegex
    case cannotWrite(URL)
}
