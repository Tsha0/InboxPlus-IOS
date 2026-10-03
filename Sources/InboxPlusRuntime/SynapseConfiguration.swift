import Darwin
import Foundation

public struct SynapseCredentials: Sendable, Equatable {
    public let registrationSecret: String

    public init(registrationSecret: String) {
        self.registrationSecret = registrationSecret
    }
}

public struct SynapseConfiguration: Sendable {
    public static let filePermissions = 0o600

    public let serverName: String
    public let bindAddress: String
    public let port: UInt16
    public let databasePath: URL
    public let mediaPath: URL
    public let signingKeyPath: URL
    public let credentials: SynapseCredentials
    /// Where `AppServiceRegistration.write(to:)` drops the bridge registrations Synapse must load.
    public let appServiceDirectory: URL

    private let profile: RuntimePaths
    private let configurationFilePath: URL
    private let pidFilePath: URL

    public init(profile: RuntimePaths, port: UInt16, credentials: SynapseCredentials) {
        self.init(
            profile: profile,
            bindAddress: "127.0.0.1",
            port: port,
            credentials: credentials
        )
    }

    init(
        profile: RuntimePaths,
        bindAddress: String,
        port: UInt16,
        credentials: SynapseCredentials
    ) {
        serverName = "inboxplus.localhost"
        self.bindAddress = bindAddress
        self.port = port
        databasePath = profile.data.appendingPathComponent("homeserver.db", isDirectory: false)
        mediaPath = profile.data.appendingPathComponent("media", isDirectory: true)
        signingKeyPath = profile.configuration.appendingPathComponent("inboxplus.signing.key", isDirectory: false)
        self.credentials = credentials
        appServiceDirectory = profile.configuration.appendingPathComponent("appservices", isDirectory: true)
        self.profile = profile
        configurationFilePath = profile.configuration.appendingPathComponent("homeserver.yaml", isDirectory: false)
        pidFilePath = profile.state.appendingPathComponent("homeserver.pid", isDirectory: false)
    }

    public func validate() throws {
        guard bindAddress == "127.0.0.1" else {
            throw SynapseConfigurationError.nonLoopbackAddress(bindAddress)
        }
        guard port != 0 else {
            throw SynapseConfigurationError.invalidPort(port)
        }
        guard !credentials.registrationSecret.isEmpty else {
            throw SynapseConfigurationError.emptyRegistrationSecret
        }
        for scalar in renderedScalarValues {
            guard !Self.containsForbiddenYAMLScalar(scalar) else {
                throw SynapseConfigurationError.invalidYAMLScalar(scalar)
            }
        }
    }

    public func render() throws -> String {
        try validate()

        return """
        server_name: \(yamlString(serverName))
        pid_file: \(yamlString(pidFilePath.path))
        listeners:
          - port: \(port)
            bind_addresses: ['127.0.0.1']
            type: http
            tls: false
            x_forwarded: false
            resources:
              - names: [client]
                compress: false
        database:
          name: sqlite3
          args:
            database: \(yamlString(databasePath.path))
        media_store_path: \(yamlString(mediaPath.path))
        signing_key_path: \(yamlString(signingKeyPath.path))
        \(renderedAppServiceConfigFiles)
        trusted_key_servers: []
        suppress_key_server_warning: true
        enable_registration: false
        registration_shared_secret: \(yamlString(credentials.registrationSecret))
        allow_guest_access: false
        enable_3pid_lookup: false
        enable_room_list_search: false
        room_list_publication_rules: []
        allow_public_rooms_without_auth: false
        allow_public_rooms_over_federation: false
        url_preview_enabled: false
        enable_metrics: false
        report_stats: false
        federation_domain_whitelist: []
        federation_whitelist_endpoint_enabled: false
        send_federation: false
        rc_message:
          per_second: 10000
          burst_count: 100000
        rc_room_creation:
          per_second: 10000
          burst_count: 100000
        rc_registration:
          per_second: 1000
          burst_count: 10000
        rc_joins:
          local:
            per_second: 10000
            burst_count: 100000
          remote:
            per_second: 10000
            burst_count: 100000
        rc_invites:
          per_room:
            per_second: 10000
            burst_count: 100000
          per_user:
            per_second: 10000
            burst_count: 100000
          per_issuer:
            per_second: 10000
            burst_count: 100000
        rc_login:
          address:
            per_second: 1000
            burst_count: 10000
          account:
            per_second: 1000
            burst_count: 10000
          failed_attempts:
            per_second: 1000
            burst_count: 10000
        """
    }

    public func write() throws -> URL {
        let yaml = try render()
        try validateConfigurationDestination()
        try createSecureProfileDirectories()
        try validateConfigurationDestination()

        let temporaryFilePath = profile.configuration
            .appendingPathComponent(".homeserver.yaml.\(UUID().uuidString).tmp", isDirectory: false)
            .standardizedFileURL
        var published = false
        defer {
            if !published {
                _ = unlink(temporaryFilePath.path)
            }
        }

        let descriptor = open(
            temporaryFilePath.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(Self.filePermissions)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fchmod(descriptor, mode_t(Self.filePermissions)) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(yaml.utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        guard rename(temporaryFilePath.path, configurationFilePath.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        published = true
        return configurationFilePath
    }

    /// Registration files present right now, sorted so a re-render of an unchanged profile is byte-identical.
    public var appServiceRegistrationFiles: [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: appServiceDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return (contents ?? [])
            .filter { $0.pathExtension == "yaml" }
            .sorted { $0.path < $1.path }
    }

    private var renderedAppServiceConfigFiles: String {
        let files = appServiceRegistrationFiles
        guard !files.isEmpty else {
            return "app_service_config_files: []"
        }
        return (["app_service_config_files:"] + files.map { "  - \(yamlString($0.path))" })
            .joined(separator: "\n")
    }

    private var renderedScalarValues: [String] {
        [
            serverName,
            appServiceDirectory.path,
            pidFilePath.path,
            databasePath.path,
            mediaPath.path,
            signingKeyPath.path,
            credentials.registrationSecret,
        ] + appServiceRegistrationFiles.map(\.path)
    }

    private func validateConfigurationDestination() throws {
        guard profile.root.isFileURL,
              profile.profile.isFileURL,
              profile.configuration.isFileURL,
              configurationFilePath.isFileURL
        else {
            throw SynapseConfigurationError.nonFileConfigurationPath(configurationFilePath)
        }
        let root = profile.root.standardizedFileURL
        let profilePath = profile.profile.standardizedFileURL
        let configurationPath = profile.configuration.standardizedFileURL
        let expectedFilePath = configurationPath.appendingPathComponent("homeserver.yaml", isDirectory: false).standardizedFileURL

        guard configurationFilePath.standardizedFileURL == expectedFilePath,
              Self.isContained(profilePath, by: root),
              Self.isContained(configurationPath, by: profilePath),
              Self.isContained(configurationFilePath.standardizedFileURL, by: configurationPath)
        else {
            throw SynapseConfigurationError.configurationEscapesProfile(configurationFilePath)
        }
        try Self.rejectSymlinkedAncestors(of: configurationFilePath.standardizedFileURL)
    }

    private func createSecureProfileDirectories() throws {
        for directory in [profile.root, profile.profile, profile.configuration] {
            try Self.rejectSymlinkedAncestors(of: directory.standardizedFileURL)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try Self.rejectSymlinkedAncestors(of: directory.standardizedFileURL)
        }
    }

    private static func isContained(_ child: URL, by root: URL) -> Bool {
        if root.path == "/" {
            return child.path.hasPrefix("/")
        }
        return child.path.hasPrefix(root.path + "/")
    }

    private static func rejectSymlinkedAncestors(of url: URL) throws {
        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            ancestor.appendPathComponent(component, isDirectory: true)
            var metadata = stat()
            guard lstat(ancestor.path, &metadata) == 0 else {
                if errno != ENOENT {
                    throw SynapseConfigurationError.cannotInspectConfigurationPath(ancestor)
                }
                break
            }
            if metadata.st_mode & S_IFMT == S_IFLNK {
                throw SynapseConfigurationError.symlinkedConfigurationAncestor(ancestor)
            }
        }
    }

    private static func containsForbiddenYAMLScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                true
            default:
                false
            }
        }
    }

    private func yamlString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}

public enum SynapseConfigurationError: Error, Equatable, Sendable {
    case nonLoopbackAddress(String)
    case invalidPort(UInt16)
    case emptyRegistrationSecret
    case invalidYAMLScalar(String)
    case nonFileConfigurationPath(URL)
    case configurationEscapesProfile(URL)
    case symlinkedConfigurationAncestor(URL)
    case cannotInspectConfigurationPath(URL)
}
