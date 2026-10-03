import Foundation
import UniformTypeIdentifiers

/// A local file chosen for sending, described well enough that the receiving end can render it.
public struct OutgoingAttachment: Hashable, Sendable {
    public let fileURL: URL
    public let kind: MessageKind
    public let filename: String
    public let mimeType: String
    public let byteCount: Int
    public var caption: String?
    public var pixelSize: PixelSize?
    public var duration: Duration?

    public init(
        fileURL: URL,
        kind: MessageKind,
        filename: String,
        mimeType: String,
        byteCount: Int,
        caption: String? = nil,
        pixelSize: PixelSize? = nil,
        duration: Duration? = nil
    ) {
        self.fileURL = fileURL
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.caption = caption
        self.pixelSize = pixelSize
        self.duration = duration
    }

    /// Reads what the file actually is, rather than trusting its extension alone.
    ///
    /// Throws rather than guessing: a file that cannot be read is a problem to report at the
    /// moment of choosing, not a failed send several seconds later.
    public static func describing(
        fileURL: URL,
        caption: String? = nil,
        fileManager: FileManager = .default
    ) throws -> OutgoingAttachment {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else {
            throw AttachmentRejection.unreadable("it is not a regular file")
        }
        guard let byteCount = values?.fileSize else {
            throw AttachmentRejection.unreadable("its size could not be determined")
        }
        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            throw AttachmentRejection.unreadable("Inbox+ does not have permission to read it")
        }

        let type = values?.contentType
        return OutgoingAttachment(
            fileURL: fileURL,
            kind: kind(for: type),
            filename: fileURL.lastPathComponent,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            byteCount: byteCount,
            caption: caption
        )
    }

    /// Maps a content type onto the kind that decides which message the receiver gets.
    ///
    /// Anything unrecognised is a file, which every network that takes attachments at all accepts.
    public static func kind(for type: UTType?) -> MessageKind {
        guard let type else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .file
    }

    /// Checks a chosen file against what the conversation will take.
    public func validate(against capabilities: ConversationCapabilities) throws {
        guard capabilities.accepts(kind) else {
            // Falling back to `.file` is a real send that usually works, but silently downgrading
            // what the user picked would be a surprise; the caller decides.
            throw AttachmentRejection.kindNotSupported(kind)
        }
        if let limit = capabilities.maximumAttachmentBytes, byteCount > limit {
            throw AttachmentRejection.tooLarge(byteCount: byteCount, limit: limit)
        }
    }
}
