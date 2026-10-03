import Foundation

public struct ConnectedAccount: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let platform: Platform
    public var displayName: String

    public init(id: String, platform: Platform, displayName: String) {
        self.id = id
        self.platform = platform
        self.displayName = displayName
    }
}

public enum AccountPolicyError: Error, Equatable {
    case duplicatePlatform(Platform)
}

public enum AccountPolicy {
    public static func validate(_ accounts: [ConnectedAccount]) throws {
        var seen: Set<Platform> = []
        for account in accounts where !seen.insert(account.platform).inserted {
            throw AccountPolicyError.duplicatePlatform(account.platform)
        }
    }
}

public struct RemoteIdentity: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let accountID: String
    public var displayName: String

    public init(id: String, accountID: String, displayName: String) {
        self.id = id
        self.accountID = accountID
        self.displayName = displayName
    }
}

public struct ConversationRoute: Codable, Hashable, Sendable {
    public let accountID: String
    public let conversationID: String

    public init(accountID: String, conversationID: String) {
        self.accountID = accountID
        self.conversationID = conversationID
    }
}

/// What a conversation will actually accept.
///
/// The design requires compose controls to be capability-driven: an action a network does not
/// support is absent or disabled rather than attempted optimistically and failed afterwards.
public struct ConversationCapabilities: Codable, Hashable, Sendable {
    public var canSendText: Bool
    /// The attachment kinds this conversation accepts. Empty means text only.
    public var attachmentKinds: Set<MessageKind>
    /// Nil when the network has not told us a limit, which is not the same as having none.
    public var maximumAttachmentBytes: Int?

    public init(
        canSendText: Bool = true,
        attachmentKinds: Set<MessageKind> = [],
        maximumAttachmentBytes: Int? = nil
    ) {
        self.canSendText = canSendText
        self.attachmentKinds = attachmentKinds
        self.maximumAttachmentBytes = maximumAttachmentBytes
    }

    public var acceptsAttachments: Bool { !attachmentKinds.isEmpty }

    public func accepts(_ kind: MessageKind) -> Bool { attachmentKinds.contains(kind) }

    /// Matrix itself accepts all four, so a bridge that has not declared otherwise gets them.
    public static let mediaCapable = ConversationCapabilities(
        canSendText: true,
        attachmentKinds: [.image, .video, .audio, .file]
    )

    public static let textOnly = ConversationCapabilities()
}

/// Why a chosen file cannot be sent here, phrased for the person who chose it.
public enum AttachmentRejection: Error, Equatable, Sendable {
    case kindNotSupported(MessageKind)
    case tooLarge(byteCount: Int, limit: Int)
    case unreadable(String)

    public var message: String {
        switch self {
        case let .kindNotSupported(kind):
            return "This conversation does not accept \(kind.rawValue) attachments."
        case let .tooLarge(byteCount, limit):
            let formatter = ByteCountFormatter()
            return "That file is \(formatter.string(fromByteCount: Int64(byteCount))); "
                + "this conversation accepts up to \(formatter.string(fromByteCount: Int64(limit)))."
        case let .unreadable(reason):
            return "That file could not be read: \(reason)"
        }
    }
}

public struct RemoteConversation: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let accountID: String
    public let identityID: String
    public var title: String
    public var latestPreview: String
    public var latestActivity: Date
    public var unreadCount: Int
    public var capabilities: ConversationCapabilities

    public var route: ConversationRoute { .init(accountID: accountID, conversationID: id) }

    public init(
        id: String,
        accountID: String,
        identityID: String,
        title: String,
        latestPreview: String = "",
        latestActivity: Date,
        unreadCount: Int,
        capabilities: ConversationCapabilities = .mediaCapable
    ) {
        self.id = id
        self.accountID = accountID
        self.identityID = identityID
        self.title = title
        self.latestPreview = latestPreview
        self.latestActivity = latestActivity
        self.unreadCount = unreadCount
        self.capabilities = capabilities
    }
}

public enum MessageDeliveryState: Codable, Hashable, Sendable { case pending, acknowledged, failed(String) }

public struct Message: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let route: ConversationRoute
    public let senderIdentityID: String?
    public var body: String
    public let timestamp: Date
    public var deliveryState: MessageDeliveryState
    public var kind: MessageKind
    public var attachments: [MessageAttachment]

    /// Messages this account sent carry no remote sender identity.
    public var isOutgoing: Bool { senderIdentityID == nil }

    /// True when the transcript shows a card explaining the event instead of the event itself.
    public var isPlaceholder: Bool { kind.isPlaceholder && attachments.isEmpty }

    public init(
        id: String,
        route: ConversationRoute,
        senderIdentityID: String?,
        body: String,
        timestamp: Date,
        deliveryState: MessageDeliveryState,
        kind: MessageKind = .text,
        attachments: [MessageAttachment] = []
    ) {
        self.id = id
        self.route = route
        self.senderIdentityID = senderIdentityID
        self.body = body
        self.timestamp = timestamp
        self.deliveryState = deliveryState
        self.kind = kind
        self.attachments = attachments
    }
}
