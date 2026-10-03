import Foundation
import MatrixRustSDK
import InboxPlusRuntime

/// A Codable mirror of the SDK's `Session`, which is not itself Codable.
public struct PersistedSession: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let userID: String
    public let deviceID: String
    public let homeserverURL: String
    public let oauthData: String?
    public let usesNativeSlidingSync: Bool

    public init(
        accessToken: String,
        refreshToken: String?,
        userID: String,
        deviceID: String,
        homeserverURL: String,
        oauthData: String?,
        usesNativeSlidingSync: Bool
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.deviceID = deviceID
        self.homeserverURL = homeserverURL
        self.oauthData = oauthData
        self.usesNativeSlidingSync = usesNativeSlidingSync
    }

    public init(_ session: Session) {
        self.init(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userID: session.userId,
            deviceID: session.deviceId,
            homeserverURL: session.homeserverUrl,
            oauthData: session.oauthData,
            usesNativeSlidingSync: session.slidingSyncVersion == .native
        )
    }

    public var session: Session {
        Session(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userID,
            deviceId: deviceID,
            homeserverUrl: homeserverURL,
            oauthData: oauthData,
            slidingSyncVersion: usesNativeSlidingSync ? .native : .none
        )
    }
}

/// Owns the on-disk locations for the encrypted Matrix client store and the saved session.
///
/// The store passphrase lives in the Keychain, never beside the data it protects.
public struct MatrixClientStore: Sendable {
    public static let sessionFileName = "matrix-session.json"
    public static let filePermissions = 0o600
    public static let directoryPermissions = 0o700

    public let dataDirectory: URL
    public let cacheDirectory: URL
    public let sessionFile: URL
    public let keychainAccount: String

    private let keychain: MatrixKeychain

    public init(
        profile: RuntimePaths,
        keychain: MatrixKeychain = MatrixKeychain(),
        keychainAccount: String? = nil
    ) {
        dataDirectory = profile.data.appendingPathComponent("matrix", isDirectory: true)
        cacheDirectory = profile.data.appendingPathComponent("matrix-cache", isDirectory: true)
        sessionFile = profile.state.appendingPathComponent(Self.sessionFileName, isDirectory: false)
        // Scoping the Keychain item to the profile keeps disposable test profiles from colliding
        // with a real one.
        self.keychainAccount = keychainAccount ?? "store:\(profile.profile.lastPathComponent)"
        self.keychain = keychain
    }

    public func prepareDirectories() throws {
        for directory in [dataDirectory, cacheDirectory, sessionFile.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryPermissions]
            )
        }
    }

    public func storePassphrase() throws -> String {
        try keychain.existingOrNewPassphrase(forAccount: keychainAccount)
    }

    // MARK: - Session persistence

    public func saveSession(_ session: PersistedSession) throws {
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeSecurely(try encoder.encode(session), to: sessionFile)
    }

    public func loadSession() throws -> PersistedSession? {
        guard FileManager.default.fileExists(atPath: sessionFile.path) else { return nil }
        return try JSONDecoder().decode(PersistedSession.self, from: Data(contentsOf: sessionFile))
    }

    public func clearSession() throws {
        if FileManager.default.fileExists(atPath: sessionFile.path) {
            try FileManager.default.removeItem(at: sessionFile)
        }
    }

    /// Removes the encrypted store, the saved session, and the Keychain key together.
    ///
    /// Leaving the key behind after deleting the data, or vice versa, produces a profile that can
    /// never be opened again.
    public func destroy() throws {
        try clearSession()
        for directory in [dataDirectory, cacheDirectory] {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        try keychain.deletePassphrase(forAccount: keychainAccount)
    }

    // MARK: - Client assembly

    /// Builds a client bound to this profile's encrypted store.
    public func makeClientBuilder(homeserverURL: URL) throws -> ClientBuilder {
        try prepareDirectories()
        // The store builder carries its own paths, so it supersedes `sessionPaths`. The passphrase
        // comes from the Keychain, never from a file next to the database it protects.
        let sqlite = SqliteStoreBuilder(dataPath: dataDirectory.path, cachePath: cacheDirectory.path)
            .passphrase(passphrase: try storePassphrase())
        return ClientBuilder()
            .homeserverUrl(url: homeserverURL.absoluteString)
            .sqliteStore(config: sqlite)
            .userAgent(userAgent: "InboxPlus/0.1 (macOS; local-first)")
            // Inbox+ pins the homeserver it talks to, and that Synapse enables MSC3575/MSC4186
            // sliding sync by default, so the version is declared rather than discovered. Without
            // it the sync service fails to start with "Sliding sync version is missing".
            .slidingSyncVersionBuilder(versionBuilder: .native)
    }

    private func writeSecurely(_ data: Data, to url: URL) throws {
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: staging.path,
            contents: data,
            attributes: [.posixPermissions: Self.filePermissions]
        ) else {
            throw MatrixClientStoreError.cannotWrite(url)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}

public enum MatrixClientStoreError: Error, Equatable, Sendable {
    case cannotWrite(URL)
}
