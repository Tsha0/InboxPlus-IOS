import Foundation
import InboxPlusCore

/// Labels for attachments, kept out of the views so they can be tested without a main actor.
enum AttachmentFormatting {
    static func byteLabel(_ byteCount: Int?) -> String? {
        guard let byteCount, byteCount > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// `m:ss`, or `h:mm:ss` once there is an hour to show.
    static func durationLabel(_ duration: Duration?) -> String? {
        guard let duration else { return nil }
        let totalSeconds = Int(duration.components.seconds)
        guard totalSeconds > 0 else { return nil }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// What VoiceOver reads for an attachment: what it is, then whatever is actually known about
    /// it. Nothing is invented — an unknown size simply goes unmentioned.
    static func accessibilityLabel(for attachment: MessageAttachment) -> String {
        var parts = [noun(for: attachment.kind), attachment.displayName]
        if let duration = durationLabel(attachment.duration) { parts.append(duration) }
        if let bytes = byteLabel(attachment.byteCount) { parts.append(bytes) }
        if let link = attachment.deepLink {
            parts.append("opens in \(link.platform.accessibilityLabel)")
        }
        return parts.joined(separator: ", ")
    }

    static func symbol(for kind: MessageKind) -> String {
        switch kind {
        case .image, .gallery, .sticker: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .location: "mappin.and.ellipse"
        default: "doc"
        }
    }

    static func noun(for kind: MessageKind) -> String {
        switch kind {
        case .image: "Photo"
        case .gallery: "Photo gallery"
        case .sticker: "Sticker"
        case .audio: "Audio message"
        case .video: "Video"
        case .file: "File"
        case .location: "Location"
        case .appNative: "Shared post"
        case .poll: "Poll"
        case .redacted: "Deleted message"
        case .encrypted: "Undecryptable message"
        default: "Attachment"
        }
    }
}
