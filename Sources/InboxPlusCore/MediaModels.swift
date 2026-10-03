import Foundation

/// What a message actually is, so the transcript can render it rather than describe it.
///
/// This lives in `InboxPlusCore` rather than beside the Matrix normalizer because the renderer must be
/// able to switch on it without importing an SDK.
public enum MessageKind: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case notice
    case emote
    case image
    case gallery
    case sticker
    case audio
    case video
    case file
    case location
    case poll
    /// Content only the originating app can display — Reels, Stories, view-once media.
    case appNative
    case redacted
    case encrypted
    case membership
    case state
    case unsupported

    /// True when Inbox+ draws this kind itself rather than describing it in words.
    public var hasNativeRendering: Bool {
        switch self {
        case .text, .notice, .emote, .image, .gallery, .sticker, .audio, .video, .file: true
        default: false
        }
    }

    /// True when the user is shown a stand-in because the real content cannot be rendered here.
    ///
    /// A placeholder is never silence: the design forbids dropping an event, so every one of these
    /// still produces a visible card that says what the bridge reported.
    public var isPlaceholder: Bool { !hasNativeRendering }

    /// Whether playback controls belong on this kind. Inbox+ never autoplays.
    public var isPlayable: Bool {
        switch self {
        case .audio, .video: true
        default: false
        }
    }
}

/// A reference to remote bytes that have not been downloaded.
///
/// Media downloads lazily, so a message carries the means to fetch its payload rather than the
/// payload. `source` is opaque above the gateway — a Matrix `mxc://` URI today.
public struct MediaHandle: Codable, Hashable, Sendable {
    public let source: String
    public var mimeType: String?
    public var byteCount: Int?

    public init(source: String, mimeType: String? = nil, byteCount: Int? = nil) {
        self.source = source
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
}

public struct PixelSize: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Used to reserve layout space before the bytes arrive, so a transcript does not jump.
    public var aspectRatio: Double? {
        guard width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }
}

/// One payload attached to a message.
///
/// Everything here comes from what the bridge reported. A field is optional because a bridge may
/// genuinely not know it, and guessing would put a wrong duration or size on screen.
public struct MessageAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: MessageKind
    public var filename: String?
    public var caption: String?
    public var mimeType: String?
    public var byteCount: Int?
    public var pixelSize: PixelSize?
    public var duration: Duration?
    public var source: MediaHandle?
    public var thumbnail: MediaHandle?
    public var deepLink: VerifiedDeepLink?
    /// What the bridge said about content Inbox+ cannot fetch, shown verbatim on the card.
    public var reportedDescription: String?

    public init(
        id: String,
        kind: MessageKind,
        filename: String? = nil,
        caption: String? = nil,
        mimeType: String? = nil,
        byteCount: Int? = nil,
        pixelSize: PixelSize? = nil,
        duration: Duration? = nil,
        source: MediaHandle? = nil,
        thumbnail: MediaHandle? = nil,
        deepLink: VerifiedDeepLink? = nil,
        reportedDescription: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.caption = caption
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.pixelSize = pixelSize
        self.duration = duration
        self.source = source
        self.thumbnail = thumbnail
        self.deepLink = deepLink
        self.reportedDescription = reportedDescription
    }

    /// True when there are bytes to fetch. An app-native card has a deep link and nothing else.
    public var isDownloadable: Bool { source != nil }

    /// A short, human label for the payload, never empty.
    public var displayName: String {
        for candidate in [caption, filename] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        switch kind {
        case .image: return "Photo"
        case .gallery: return "Photos"
        case .sticker: return "Sticker"
        case .audio: return "Audio message"
        case .video: return "Video"
        case .location: return "Location"
        case .appNative: return "Shared post"
        default: return "File"
        }
    }
}
