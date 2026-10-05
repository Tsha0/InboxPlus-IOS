import Foundation
import InboxPlusCore
import InboxPlusGateway
import InboxPlusBridge

public enum CompanionError: LocalizedError, Sendable {
    case invalidAddress, unauthorized, server(String), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter an HTTPS address for your Mac. HTTP is only supported on simulator loopback."
        case .unauthorized: "The pairing key was rejected. Check the key on your Mac."
        case .server(let message): message
        case .invalidResponse: "Your Mac returned an unreadable response."
        }
    }
}

public struct CompanionConfiguration: Codable, Equatable, Sendable {
    public let address: URL
    public let token: String
    public init(address: String, token: String) throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              token.count >= 32, token.count <= 512, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw CompanionError.invalidAddress }
        self.address = url
        self.token = token
    }
}

public struct CompanionRequest: Codable, Sendable {
    public var operation: String
    public var route: ConversationRoute?
    public var body: String?
    public var filename: String?
    public var data: Data?
    public var handle: MediaHandle?
    public var platform: Platform?
    public var sessionID: String?
    public var loginID: String?
    public var stepID: String?
    public var stepType: BridgeLoginStepType?
    public var values: [String: String]?
    public init(_ operation: String) { self.operation = operation }
}
public struct CompanionResponse: Codable, Sendable {
    public var disconnectedAccountIDs: Set<String>?
    public var snapshot: MessagingSnapshot?
    public var receipt: SendReceipt?
    public var data: Data?
    public var flows: [BridgeLoginFlow]?
    public var step: BridgeLoginStep?
    public var sessionID: String?
    public var error: String?
    public init() {}
}

public struct CompanionClient: Sendable {
    public let configuration: CompanionConfiguration
    private let session: URLSession
    public init(configuration: CompanionConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }
    public func call(_ payload: CompanionRequest) async throws -> CompanionResponse {
        var request = URLRequest(url: configuration.address.appendingPathComponent("v1/rpc"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionError.invalidResponse }
        if http.statusCode == 401 { throw CompanionError.unauthorized }
        guard http.statusCode == 200 else { throw CompanionError.server("Connection failed (HTTP \(http.statusCode)).") }
        let result = try JSONDecoder().decode(CompanionResponse.self, from: data)
        if let error = result.error { throw CompanionError.server(error) }
        return result
    }
}

public actor CompanionGateway: MessagingGateway {
    private let client: CompanionClient
    private let sleep: @Sendable () async throws -> Void
    private var polling: Task<Void, Never>?
    private var subscriptionID: UUID?
    private var pausedAccounts: Set<String> = []
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    private var accountIDs: [String] = []
    private var previous: MessagingSnapshot?
    public init(client: CompanionClient, sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) {
        self.client = client; self.sleep = sleep
    }
    deinit { polling?.cancel() }
    public func loadSnapshot() async throws -> MessagingSnapshot {
        guard let snapshot = try await client.call(CompanionRequest("snapshot")).snapshot else { throw CompanionError.invalidResponse }
        accountIDs = snapshot.accounts.map(\.id)
        previous = snapshot
        return snapshot
    }
    public func events() -> AsyncStream<GatewayEvent> {
        polling?.cancel()
        let id = UUID()
        subscriptionID = id
        let (stream, continuation) = AsyncStream<GatewayEvent>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.stop(id: id) } }
        let sleep = self.sleep
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep() } catch { break }
                guard let self else { break }
                await self.poll(subscription: id)
            }
        }
        return stream
    }
    public func setPaused(_ paused: Bool, accountID: String) {
        if paused { pausedAccounts.insert(accountID) } else { pausedAccounts.remove(accountID) }
        continuation?.yield(.connectionChanged(accountID: accountID, isConnected: !paused))
    }
    private func stop(id: UUID) {
        guard subscriptionID == id else { return }
        polling?.cancel(); polling = nil; continuation = nil; subscriptionID = nil
    }
    private func poll(subscription: UUID? = nil) async {
        do {
            let response = try await client.call(CompanionRequest("snapshot"))
            if let subscription, subscription != subscriptionID { return }
            guard let snapshot = response.snapshot else { throw CompanionError.invalidResponse }
            for account in snapshot.accounts { continuation?.yield(.connectionChanged(accountID: account.id, isConnected: !pausedAccounts.contains(account.id) && !(response.disconnectedAccountIDs ?? []).contains(account.id))) }
            for identity in snapshot.identities where !pausedAccounts.contains(identity.accountID) && previous?.identities.contains(identity) != true { continuation?.yield(.identityUpserted(identity)) }
            for conversation in snapshot.conversations where !pausedAccounts.contains(conversation.accountID) && previous?.conversations.contains(conversation) != true { continuation?.yield(.conversationUpserted(conversation)) }
            for (route, messages) in snapshot.messagesByRoute where !pausedAccounts.contains(route.accountID) {
                for message in messages where previous?.messagesByRoute[route]?.contains(message) != true { continuation?.yield(.messageUpserted(message)) }
            }
            var delivered = snapshot
            for id in pausedAccounts {
                delivered.identities.removeAll { $0.accountID == id }
                delivered.identities.append(contentsOf: previous?.identities.filter { $0.accountID == id } ?? [])
                delivered.conversations.removeAll { $0.accountID == id }
                delivered.conversations.append(contentsOf: previous?.conversations.filter { $0.accountID == id } ?? [])
                for route in delivered.messagesByRoute.keys where route.accountID == id { delivered.messagesByRoute[route] = previous?.messagesByRoute[route] }
            }
            previous = delivered
            accountIDs = snapshot.accounts.map(\.id)
        } catch {
            if let subscription, subscription != subscriptionID { return }
            for id in accountIDs { continuation?.yield(.connectionChanged(accountID: id, isConnected: false)) }
        }
    }
    public func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt {
        guard !pausedAccounts.contains(route.accountID) else { throw CompanionError.server("Resume this account in Settings before sending.") }
        var request = CompanionRequest("sendText"); request.body = body; request.route = route
        guard let receipt = try await client.call(request).receipt else { throw CompanionError.invalidResponse }
        await poll()
        return receipt
    }
    public func send(_ attachment: OutgoingAttachment, to route: ConversationRoute) async throws -> SendReceipt {
        guard !pausedAccounts.contains(route.accountID) else { throw CompanionError.server("Resume this account in Settings before sending.") }
        guard attachment.byteCount <= 25 * 1024 * 1024 else { throw CompanionError.server("Choose a file smaller than 25 MB.") }
        var request = CompanionRequest("sendAttachment")
        request.route = route; request.filename = attachment.filename
        let actualSize = try attachment.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard actualSize <= 25 * 1024 * 1024 else { throw CompanionError.server("Choose a file smaller than 25 MB.") }
        let data = try Data(contentsOf: attachment.fileURL, options: .mappedIfSafe)
        guard data.count <= 25 * 1024 * 1024 else { throw CompanionError.server("Choose a file smaller than 25 MB.") }
        request.data = data
        guard let receipt = try await client.call(request).receipt else { throw CompanionError.invalidResponse }
        await poll()
        return receipt
    }
}

public struct CompanionMediaFetcher: RemoteMediaFetching {
    public let client: CompanionClient
    public init(client: CompanionClient) { self.client = client }
    public func fetch(_ handle: MediaHandle) async throws -> Data {
        var request = CompanionRequest("media"); request.handle = handle
        guard let data = try await client.call(request).data else { throw CompanionError.invalidResponse }
        return data
    }
}

public actor CompanionLoginSession: BridgeLoginSession {
    private let client: CompanionClient
    private let platform: Platform
    private var sessionID: String?
    public init(client: CompanionClient, platform: Platform) { self.client = client; self.platform = platform }
    public func loginFlows() async throws -> [BridgeLoginFlow] {
        var request = CompanionRequest("loginPrepare"); request.platform = platform
        let response = try await client.call(request)
        sessionID = response.sessionID
        return response.flows ?? []
    }
    public func startLogin(flowID: String) async throws -> BridgeLoginStep {
        var request = CompanionRequest("loginStart"); request.sessionID = sessionID; request.body = flowID
        guard let step = try await client.call(request).step else { throw CompanionError.invalidResponse }
        return step
    }
    public func submit(loginID: String, stepID: String, type: BridgeLoginStepType, values: [String: String]) async throws -> BridgeLoginStep {
        var request = CompanionRequest("loginSubmit")
        request.sessionID = sessionID; request.loginID = loginID; request.stepID = stepID; request.stepType = type; request.values = values
        guard let step = try await client.call(request).step else { throw CompanionError.invalidResponse }
        return step
    }
    public func cancelLogin(loginID: String) async throws {
        var request = CompanionRequest("loginCancel"); request.sessionID = sessionID; request.loginID = loginID
        _ = try await client.call(request)
    }
}
