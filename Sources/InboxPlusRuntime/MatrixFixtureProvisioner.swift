import CryptoKit
import Foundation

/// Deterministic fixture identifiers derived entirely from a recorded seed.
public struct MatrixFixturePlan: Sendable, Equatable {
    public let seed: UInt64
    public let roomAliases: [String]

    public init(seed: UInt64, roomAliases: [String]) {
        self.seed = seed
        self.roomAliases = roomAliases
    }

    /// A stable transaction ID so a retried send can never commit a duplicate event.
    public static func transactionIdentifier(
        seed: UInt64,
        roomIndex: Int,
        messageIndex: Int
    ) -> String {
        var generator = SplitMix64(
            seed: seed
                &+ (UInt64(bitPattern: Int64(roomIndex)) &* 0x9E37_79B9_7F4A_7C15)
                &+ (UInt64(bitPattern: Int64(messageIndex)) &* 0xBF58_476D_1CE4_E5B9)
        )
        return "inboxplus-\(String(generator.next(), radix: 36))-\(roomIndex)-\(messageIndex)"
    }
}

public struct FixtureContext: Codable, Sendable, Equatable {
    public let seed: UInt64
    public let userID: String
    public let accessToken: String
    public let deviceID: String
    public let roomIDs: [String]

    public init(
        seed: UInt64,
        userID: String,
        accessToken: String,
        deviceID: String,
        roomIDs: [String]
    ) {
        self.seed = seed
        self.userID = userID
        self.accessToken = accessToken
        self.deviceID = deviceID
        self.roomIDs = roomIDs
    }
}

public enum MatrixFixtureError: Error, Equatable, Sendable {
    case registrationFailed(status: Int)
    case invalidRegistrationResponse
    case roomCreationFailed(alias: String)
    case invalidRoomCount(Int)
}

/// Creates the local benchmark user and its deterministic set of rooms.
public struct MatrixFixtureProvisioner: Sendable {
    public let baseURL: URL
    private let serverName: String
    private let registrationSecret: String
    private let client: MatrixHTTPClient

    public init(
        baseURL: URL,
        serverName: String,
        registrationSecret: String,
        transport: any SynapseHTTPTransport = URLSessionSynapseHTTPTransport()
    ) throws {
        self.baseURL = baseURL
        self.serverName = serverName
        self.registrationSecret = registrationSecret
        client = try MatrixHTTPClient(baseURL: baseURL, accessToken: nil, transport: transport)
    }

    /// Derives the room aliases for a seed without performing any I/O.
    public func plan(seed: UInt64, roomCount: Int) -> MatrixFixturePlan {
        var generator = SplitMix64(seed: seed)
        let aliases = (0..<roomCount).map { index in
            "inboxplus-\(String(seed, radix: 36))-\(index)-\(String(generator.next(), radix: 36))"
        }
        return MatrixFixturePlan(seed: seed, roomAliases: aliases)
    }

    /// Registers the benchmark user and creates every planned room.
    public func prepare(seed: UInt64, roomCount: Int) async throws -> FixtureContext {
        guard roomCount > 0 else { throw MatrixFixtureError.invalidRoomCount(roomCount) }
        let plan = plan(seed: seed, roomCount: roomCount)
        let account = try await registerBenchmarkUser(seed: seed)
        let authenticated = try client.withAccessToken(account.accessToken)

        var roomIDs: [String] = []
        roomIDs.reserveCapacity(roomCount)
        for alias in plan.roomAliases {
            let body = try JSONSerialization.data(withJSONObject: [
                "preset": "private_chat",
                "room_alias_name": alias,
                "visibility": "private",
            ])
            do {
                let response: CreateRoomResponse = try await authenticated.send(
                    .post,
                    path: ["_matrix", "client", "v3", "createRoom"],
                    body: body
                )
                roomIDs.append(response.roomID)
            } catch let MatrixHTTPError.matrix(failure) where failure.errorCode == "M_ROOM_IN_USE" {
                // A previous run already created this deterministic alias; adopt its room.
                let resolved: ResolvedAliasResponse = try await authenticated.send(
                    .get,
                    path: ["_matrix", "client", "v3", "directory", "room", "#\(alias):\(serverName)"],
                    idempotent: true
                )
                roomIDs.append(resolved.roomID)
            }
        }

        return FixtureContext(
            seed: seed,
            userID: account.userID,
            accessToken: account.accessToken,
            deviceID: account.deviceID,
            roomIDs: roomIDs
        )
    }

    /// Registers the deterministic local benchmark account, or logs in when it already exists.
    ///
    /// The password is derived from the seed and the profile's registration secret so a repeated
    /// run can authenticate as the same account instead of colliding with it.
    private func registerBenchmarkUser(seed: UInt64) async throws -> BenchmarkAccount {
        let localpart = "inboxplus_bench_\(String(seed, radix: 36))"
        let password = HMAC<SHA256>.authenticationCode(
            for: Data("inboxplus-benchmark-password:\(seed)".utf8),
            using: SymmetricKey(data: Data(registrationSecret.utf8))
        ).map { String(format: "%02x", $0) }.joined()

        do {
            return try await register(localpart: localpart, password: password)
        } catch let MatrixHTTPError.matrix(failure) where failure.errorCode == "M_USER_IN_USE" {
            return try await logIn(localpart: localpart, password: password)
        }
    }

    private func register(localpart: String, password: String) async throws -> BenchmarkAccount {
        let nonceResponse: NonceBody = try await client.send(
            .get,
            path: ["_synapse", "admin", "v1", "register"],
            idempotent: true
        )
        let macInput = [nonceResponse.nonce, localpart, password, "notadmin"].joined(separator: "\0")
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(macInput.utf8),
            using: SymmetricKey(data: Data(registrationSecret.utf8))
        ).map { String(format: "%02x", $0) }.joined()

        let body = try JSONSerialization.data(withJSONObject: [
            "nonce": nonceResponse.nonce,
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
        return BenchmarkAccount(
            userID: registration.userID,
            accessToken: registration.accessToken,
            deviceID: registration.deviceID ?? "INBOXPLUSBENCH"
        )
    }

    private func logIn(localpart: String, password: String) async throws -> BenchmarkAccount {
        let body = try JSONSerialization.data(withJSONObject: [
            "type": "m.login.password",
            "identifier": ["type": "m.id.user", "user": localpart],
            "password": password,
        ])
        let login: RegistrationBody = try await client.send(
            .post,
            path: ["_matrix", "client", "v3", "login"],
            body: body
        )
        return BenchmarkAccount(
            userID: login.userID,
            accessToken: login.accessToken,
            deviceID: login.deviceID ?? "INBOXPLUSBENCH"
        )
    }
}

struct BenchmarkAccount: Sendable {
    let userID: String
    let accessToken: String
    let deviceID: String
}

private struct NonceBody: Decodable {
    let nonce: String
}

private struct RegistrationBody: Decodable {
    let userID: String
    let accessToken: String
    let deviceID: String?

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case accessToken = "access_token"
        case deviceID = "device_id"
    }
}

private struct CreateRoomResponse: Decodable {
    let roomID: String

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
    }
}

private struct ResolvedAliasResponse: Decodable {
    let roomID: String

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
    }
}

/// A small, stable PRNG so fixture identifiers depend only on the recorded seed.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var result = state
        result = (result ^ (result >> 30)) &* 0xBF58_476D_1CE4_E5B9
        result = (result ^ (result >> 27)) &* 0x94D0_49BB_1331_11EB
        return result ^ (result >> 31)
    }
}
