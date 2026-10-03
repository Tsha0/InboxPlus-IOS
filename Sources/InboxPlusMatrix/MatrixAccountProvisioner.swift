import CryptoKit
import Foundation
import InboxPlusRuntime

/// Credentials for the single local Matrix account Inbox+ drives.
public struct MatrixAccountCredentials: Sendable, Equatable {
    public let userID: String
    public let localpart: String
    public let password: String

    public init(userID: String, localpart: String, password: String) {
        self.userID = userID
        self.localpart = localpart
        self.password = password
    }
}

public enum MatrixAccountError: Error, Equatable, Sendable, CustomStringConvertible {
    case nonceUnavailable
    case registrationRejected(status: Int, code: String?)

    public var description: String {
        switch self {
        case .nonceUnavailable:
            "the homeserver did not return a registration nonce"
        case let .registrationRejected(status, code):
            "registration was rejected with status \(status)\(code.map { " (\($0))" } ?? "")"
        }
    }
}

/// Creates Inbox+'s own local Matrix account through Synapse's shared-secret registration endpoint.
///
/// The account is deterministic: the password is derived from the profile's registration secret, so
/// a later launch can authenticate as the same user instead of colliding with it. The registration
/// secret never leaves the profile, and the derived password is never written to disk or logs.
public struct MatrixAccountProvisioner: Sendable {
    public static let defaultLocalpart = "inboxplus"

    public let serverName: String
    public let localpart: String
    private let registrationSecret: String
    private let client: MatrixHTTPClient

    public init(
        baseURL: URL,
        serverName: String,
        registrationSecret: String,
        localpart: String = MatrixAccountProvisioner.defaultLocalpart,
        transport: any SynapseHTTPTransport = URLSessionSynapseHTTPTransport()
    ) throws {
        self.serverName = serverName
        self.localpart = localpart
        self.registrationSecret = registrationSecret
        client = try MatrixHTTPClient(baseURL: baseURL, accessToken: nil, transport: transport)
    }

    public var userID: String { "@\(localpart):\(serverName)" }

    public var credentials: MatrixAccountCredentials {
        MatrixAccountCredentials(userID: userID, localpart: localpart, password: derivedPassword)
    }

    /// Registers the account, treating an already-registered account as success.
    @discardableResult
    public func ensureRegistered() async throws -> MatrixAccountCredentials {
        do {
            _ = try await register()
        } catch let MatrixHTTPError.matrix(failure) where failure.errorCode == "M_USER_IN_USE" {
            // Already provisioned by an earlier launch; the derived password still authenticates.
        }
        return credentials
    }

    private func register() async throws -> String {
        let nonce: NonceBody = try await client.send(
            .get,
            path: ["_synapse", "admin", "v1", "register"],
            idempotent: true
        )
        guard !nonce.nonce.isEmpty else { throw MatrixAccountError.nonceUnavailable }

        let password = derivedPassword
        let macInput = [nonce.nonce, localpart, password, "notadmin"].joined(separator: "\0")
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(macInput.utf8),
            using: SymmetricKey(data: Data(registrationSecret.utf8))
        ).map { String(format: "%02x", $0) }.joined()

        let body = try JSONSerialization.data(withJSONObject: [
            "nonce": nonce.nonce,
            "username": localpart,
            "password": password,
            "admin": false,
            "mac": mac,
        ])
        let registration: RegistrationBody = try await client.send(
            .post,
            path: ["_synapse", "admin", "v1", "register"],
            body: body
        )
        return registration.userID
    }

    /// Derived rather than random so the account can be re-authenticated on a later launch.
    var derivedPassword: String {
        HMAC<SHA256>.authenticationCode(
            for: Data("inboxplus-matrix-account:\(localpart)".utf8),
            using: SymmetricKey(data: Data(registrationSecret.utf8))
        ).map { String(format: "%02x", $0) }.joined()
    }
}

private struct NonceBody: Decodable {
    let nonce: String
}

private struct RegistrationBody: Decodable {
    let userID: String

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}
