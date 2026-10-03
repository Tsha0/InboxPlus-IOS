import Foundation
import MatrixRustSDK
import InboxPlusCore

/// Maps Matrix timeline events onto Inbox+'s domain model.
///
/// Conversation metadata is kept out of chat history and inbox previews. Actual messages Inbox+
/// cannot render natively still get a placeholder, including unknown or undecryptable messages.
public struct MatrixEventNormalizer: Sendable {
    public let accountID: String

    public init(accountID: String) {
        self.accountID = accountID
    }

    /// The account is passed in because one Matrix connection can carry several accounts: each
    /// bridge's portals belong to that network, not to Matrix.
    public func route(forRoom roomID: String, accountID: String? = nil) -> ConversationRoute {
        ConversationRoute(accountID: accountID ?? self.accountID, conversationID: roomID)
    }

    public func normalize(
        _ item: EventTimelineItem,
        roomID: String,
        accountID: String? = nil
    ) -> Message? {
        let identifier = identifier(for: item.eventOrTransactionId)
        guard var described = describe(item.content, identifier: identifier) else { return nil }

        // A shared Reel or Story reaches the bridge as plain text carrying a link; the link is the
        // only thing that says what it really is.
        if described.attachments.isEmpty, described.kind == .text,
           let card = AppNativeContentDetector.attachment(forBody: described.body, id: "\(identifier)#link") {
            described.kind = .appNative
            described.attachments = [card]
        }

        return Message(
            id: identifier,
            route: route(forRoom: roomID, accountID: accountID),
            // An outgoing message carries no remote sender identity, matching `Message.isOutgoing`.
            senderIdentityID: item.isOwn ? nil : item.sender,
            body: described.body,
            timestamp: Self.date(from: item.timestamp),
            deliveryState: Self.deliveryState(for: item.localSendState),
            kind: described.kind,
            attachments: described.attachments
        )
    }

    /// What one timeline event turned into: a line of text, a category, and any payloads.
    struct Described {
        var body: String
        var kind: MessageKind
        var attachments: [MessageAttachment] = []
    }

    /// Local echoes are keyed by transaction ID until the server assigns an event ID.
    public func identifier(for id: EventOrTransactionId) -> String {
        switch id {
        case let .eventId(eventId): eventId
        case let .transactionId(transactionId): "txn:\(transactionId)"
        }
    }

    /// A send is only `acknowledged` once the server confirms it.
    ///
    /// A remote event has no local send state — it exists because the server already accepted it.
    public static func deliveryState(for state: EventSendState?) -> MessageDeliveryState {
        switch state {
        case .none, .some(.sent):
            .acknowledged
        case .some(.notSentYet):
            .pending
        case let .some(.sendingFailed(error, isRecoverable)):
            .failed(isRecoverable ? "\(error) (will retry)" : "\(error)")
        }
    }

    public static func date(from timestamp: Timestamp) -> Date {
        Date(timeIntervalSince1970: Double(timestamp) / 1000)
    }

    // MARK: - Content

    func describe(_ content: TimelineItemContent, identifier: String) -> Described? {
        switch content {
        case let .msgLike(msgLike):
            describe(msgLike.kind, identifier: identifier)
        case let .roomMembership(_, displayName, change, _):
            Described(body: "\(displayName ?? "Someone") \(Self.describe(change))", kind: .membership)
        case .profileChange:
            Described(body: "Updated their profile", kind: .membership)
        case .state:
            // Bridges replay settings and avatars while syncing. These are metadata, not chat
            // messages; omit them before either historical or live events reach the inbox.
            nil
        case let .failedToParseMessageLike(eventType, _):
            Described(body: "Unsupported message (\(eventType))", kind: .unsupported)
        case .failedToParseState:
            nil
        case .callInvite:
            Described(body: "Call invitation", kind: .unsupported)
        case .rtcNotification:
            Described(body: "Call notification", kind: .unsupported)
        }
    }

    private func describe(_ kind: MsgLikeKind, identifier: String) -> Described {
        switch kind {
        case let .message(content):
            return describe(content.msgType, identifier: identifier)
        case let .sticker(body, info, source):
            let attachment = Self.attachment(
                id: "\(identifier)#0",
                kind: .sticker,
                filename: body.isEmpty ? nil : body,
                caption: nil,
                mimeType: info.mimetype,
                byteCount: info.size,
                pixelSize: Self.pixelSize(width: info.width, height: info.height),
                duration: nil,
                source: source,
                sourceSize: info.size,
                thumbnail: info.thumbnailSource
            )
            return Described(body: body.isEmpty ? "Sticker" : body, kind: .sticker, attachments: [attachment])
        case let .poll(question, _, _, _, _, _, _):
            return Described(body: "Poll: \(question)", kind: .poll)
        case .redacted:
            return Described(body: "Message deleted", kind: .redacted)
        case .unableToDecrypt:
            return Described(body: "Message could not be decrypted", kind: .encrypted)
        case let .other(eventType):
            return Described(body: "Unsupported message (\(eventType))", kind: .unsupported)
        case .liveLocation:
            return Described(body: "Live location", kind: .location)
        }
    }

    private func describe(_ messageType: MessageType, identifier: String) -> Described {
        switch messageType {
        case let .text(content):
            return Described(body: content.body, kind: .text)
        case let .notice(content):
            return Described(body: content.body, kind: .notice)
        case let .emote(content):
            return Described(body: content.body, kind: .emote)
        // Attachments carry a filename plus an optional caption rather than a body. Prefer the
        // caption the sender wrote, fall back to the filename, and only then to a generic label,
        // so an attachment is never rendered as an empty message.
        case let .image(content):
            let attachment = Self.attachment(from: content, id: "\(identifier)#0")
            return Described(body: attachment.displayName, kind: attachment.kind, attachments: [attachment])
        case let .audio(content):
            let attachment = Self.attachment(from: content, id: "\(identifier)#0")
            return Described(body: attachment.displayName, kind: .audio, attachments: [attachment])
        case let .video(content):
            let attachment = Self.attachment(from: content, id: "\(identifier)#0")
            return Described(body: attachment.displayName, kind: .video, attachments: [attachment])
        case let .file(content):
            let attachment = Self.attachment(from: content, id: "\(identifier)#0")
            return Described(body: attachment.displayName, kind: .file, attachments: [attachment])
        case let .gallery(content):
            let attachments = content.itemtypes.enumerated().compactMap { index, item in
                Self.attachment(from: item, id: "\(identifier)#\(index)")
            }
            return Described(
                body: Self.caption(content.body, fallback: attachments.isEmpty ? "Photos" : "\(attachments.count) items"),
                kind: .gallery,
                attachments: attachments
            )
        case let .location(content):
            return Described(body: Self.caption(content.body, fallback: "Location"), kind: .location)
        case let .other(msgtype, body):
            return Described(
                body: body.isEmpty ? "Unsupported message (\(msgtype))" : body,
                kind: .unsupported
            )
        }
    }

    // MARK: - Attachments

    static func attachment(from item: GalleryItemType, id: String) -> MessageAttachment? {
        switch item {
        case let .image(content): attachment(from: content, id: id)
        case let .audio(content): attachment(from: content, id: id)
        case let .video(content): attachment(from: content, id: id)
        case let .file(content): attachment(from: content, id: id)
        // An item type Inbox+ does not know still becomes a visible card rather than a gap.
        case let .other(itemtype, body):
            MessageAttachment(
                id: id,
                kind: .unsupported,
                caption: body.isEmpty ? nil : body,
                reportedDescription: "Unsupported gallery item (\(itemtype))"
            )
        }
    }

    static func attachment(from content: ImageMessageContent, id: String) -> MessageAttachment {
        // An animated image is a GIF in practice; it is still drawn as an image, so it keeps the
        // image kind and only the mime type distinguishes it.
        attachment(
            id: id,
            kind: .image,
            filename: content.filename,
            caption: content.caption,
            mimeType: content.info?.mimetype,
            byteCount: content.info?.size,
            pixelSize: pixelSize(width: content.info?.width, height: content.info?.height),
            duration: nil,
            source: content.source,
            sourceSize: content.info?.size,
            thumbnail: content.info?.thumbnailSource
        )
    }

    static func attachment(from content: AudioMessageContent, id: String) -> MessageAttachment {
        attachment(
            id: id,
            kind: .audio,
            filename: content.filename,
            caption: content.caption,
            mimeType: content.info?.mimetype,
            byteCount: content.info?.size,
            pixelSize: nil,
            duration: duration(content.info?.duration),
            source: content.source,
            sourceSize: content.info?.size,
            thumbnail: nil
        )
    }

    static func attachment(from content: VideoMessageContent, id: String) -> MessageAttachment {
        attachment(
            id: id,
            kind: .video,
            filename: content.filename,
            caption: content.caption,
            mimeType: content.info?.mimetype,
            byteCount: content.info?.size,
            pixelSize: pixelSize(width: content.info?.width, height: content.info?.height),
            duration: duration(content.info?.duration),
            source: content.source,
            sourceSize: content.info?.size,
            thumbnail: content.info?.thumbnailSource
        )
    }

    static func attachment(from content: FileMessageContent, id: String) -> MessageAttachment {
        attachment(
            id: id,
            kind: .file,
            filename: content.filename,
            caption: content.caption,
            mimeType: content.info?.mimetype,
            byteCount: content.info?.size,
            pixelSize: nil,
            duration: nil,
            source: content.source,
            sourceSize: content.info?.size,
            thumbnail: content.info?.thumbnailSource
        )
    }

    private static func attachment(
        id: String,
        kind: MessageKind,
        filename: String?,
        caption: String?,
        mimeType: String?,
        byteCount: UInt64?,
        pixelSize: PixelSize?,
        duration: Duration?,
        source: MediaSource?,
        sourceSize: UInt64?,
        thumbnail: MediaSource?
    ) -> MessageAttachment {
        MessageAttachment(
            id: id,
            kind: kind,
            filename: text(filename),
            caption: text(caption),
            mimeType: text(mimeType),
            byteCount: count(byteCount),
            pixelSize: pixelSize,
            duration: duration,
            source: source.map {
                MediaHandle(source: $0.url(), mimeType: text(mimeType), byteCount: count(sourceSize))
            },
            thumbnail: thumbnail.map { MediaHandle(source: $0.url()) }
        )
    }

    /// A blank string from a bridge means "not known", and storing it would put an empty label on
    /// screen where a sensible fallback belongs.
    static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Sizes cross the FFI as `UInt64`. Anything that cannot be represented is reported as unknown
    /// rather than wrapped into a nonsense number.
    static func count(_ value: UInt64?) -> Int? {
        guard let value, value <= UInt64(Int.max) else { return nil }
        return Int(value)
    }

    static func pixelSize(width: UInt64?, height: UInt64?) -> PixelSize? {
        guard let width = count(width), let height = count(height), width > 0, height > 0 else {
            return nil
        }
        return PixelSize(width: width, height: height)
    }

    /// Matrix reports durations in seconds as a floating-point value; milliseconds are the finest
    /// unit any of it is actually measured in.
    static func duration(_ value: TimeInterval?) -> Duration? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return .milliseconds(Int((value * 1000).rounded()))
    }

    private static func caption(_ body: String, fallback: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : body
    }

    private static func describe(_ change: MembershipChange?) -> String {
        switch change {
        case .some(.joined): "joined"
        case .some(.left): "left"
        case .some(.invited): "was invited"
        case .some(.banned): "was banned"
        case .some(.kicked): "was removed"
        default: "membership changed"
        }
    }

}

/// Orders a conversation deterministically.
///
/// Bridged events can arrive out of order, so ordering uses the remote timestamp with the event
/// identifier as a stable tie-break rather than arrival order.
public func inboxplusMessageOrdering(_ lhs: Message, _ rhs: Message) -> Bool {
    if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
    return lhs.id < rhs.id
}
