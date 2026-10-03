import InboxPlusCore

public struct MessagingSnapshot: Codable, Sendable {
    public var accounts: [ConnectedAccount]
    public var identities: [RemoteIdentity]
    public var conversations: [RemoteConversation]
    public var messagesByRoute: [ConversationRoute: [Message]]

    public init(accounts: [ConnectedAccount], identities: [RemoteIdentity], conversations: [RemoteConversation], messagesByRoute: [ConversationRoute: [Message]]) {
        self.accounts = accounts
        self.identities = identities
        self.conversations = conversations
        self.messagesByRoute = messagesByRoute
    }

    public static let empty = Self(accounts: [], identities: [], conversations: [], messagesByRoute: [:])
}

public enum GatewayEvent: Codable, Sendable {
    case messageUpserted(Message)
    case conversationUpserted(RemoteConversation)
    /// Must be delivered before any conversation that names this identity.
    ///
    /// The inbox can only project a conversation whose identity it knows, so a conversation that
    /// arrives without one is dropped and the user simply never sees it.
    case identityUpserted(RemoteIdentity)
    case connectionChanged(accountID: String, isConnected: Bool)
}

public struct SendReceipt: Codable, Sendable {
    public let messageID: String
    public let route: ConversationRoute
    public let deliveryState: MessageDeliveryState

    public init(messageID: String, route: ConversationRoute, deliveryState: MessageDeliveryState) {
        self.messageID = messageID
        self.route = route
        self.deliveryState = deliveryState
    }
}

public protocol MessagingGateway: Sendable {
    func loadSnapshot() async throws -> MessagingSnapshot
    func events() async -> AsyncStream<GatewayEvent>
    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt
    /// Uploads and sends a local file. Like `sendText`, the receipt is only `acknowledged` once
    /// the server has confirmed it.
    func send(_ attachment: OutgoingAttachment, to route: ConversationRoute) async throws -> SendReceipt
}
