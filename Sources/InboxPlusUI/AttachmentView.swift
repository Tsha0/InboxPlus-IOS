import AVKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import SwiftUI
import InboxPlusCore
import InboxPlusFeatures

/// Renders one attachment, choosing its presentation from the kind the bridge reported.
///
/// Every branch produces something visible. The design forbids silently dropping a message, so an
/// attachment Inbox+ cannot draw becomes a card that says what the bridge actually said about it.
public struct AttachmentView: View {
    @Bindable var model: InboxPlusAppModel
    let attachment: MessageAttachment
    let accountID: String
    let messageID: String

    public init(model: InboxPlusAppModel, attachment: MessageAttachment, accountID: String, messageID: String) {
        self.model = model
        self.attachment = attachment
        self.accountID = accountID
        self.messageID = messageID
    }

    private var state: MediaController.State {
        model.media.state(for: attachment)
    }

    public var body: some View {
        content
            .frame(maxWidth: 320, alignment: .leading)
            .onAppear { model.media.load(attachment, accountID: accountID, messageID: messageID) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("attachment-\(attachment.id)")
    }

    @ViewBuilder private var content: some View {
        switch attachment.kind {
        case .image, .sticker, .gallery:
            imageContent
        case .audio, .video:
            playableContent
        case .appNative:
            AppNativeCard(attachment: attachment)
        case .file:
            fileContent
        default:
            UnsupportedAttachmentCard(attachment: attachment)
        }
    }

    // MARK: - Images

    @ViewBuilder private var imageContent: some View {
        switch state {
        case let .ready(url):
            if let image = PlatformImage(contentsOfFile: url.path) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 320)
                    .clipShape(.rect(cornerRadius: 10))
                    .accessibilityLabel(attachment.displayName)
            } else {
                // The bytes arrived but are not an image this Mac can decode. Say so rather than
                // showing an empty frame.
                UnsupportedAttachmentCard(
                    attachment: attachment,
                    reason: "This image could not be displayed."
                )
            }
        case .idle, .loading:
            MediaPlaceholder(attachment: attachment)
        case let .failed(reason):
            MediaRetryCard(attachment: attachment, reason: reason) {
                model.media.retry(attachment, accountID: accountID, messageID: messageID)
            }
        case let .paused(reason):
            MediaPausedCard(attachment: attachment, reason: reason)
        }
    }

    // MARK: - Audio and video

    @ViewBuilder private var playableContent: some View {
        switch state {
        case let .ready(url):
            // Inbox+ never autoplays: `VideoPlayer` presents controls and waits for the user.
            VideoPlayer(player: AVPlayer(url: url))
                .frame(maxWidth: 320)
                .frame(height: attachment.kind == .audio ? 60 : 200)
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityLabel("\(attachment.displayName), \(durationLabel ?? "playable")")
        case .idle, .loading:
            MediaPlaceholder(attachment: attachment, durationLabel: durationLabel)
        case let .failed(reason):
            MediaRetryCard(attachment: attachment, reason: reason) {
                model.media.retry(attachment, accountID: accountID, messageID: messageID)
            }
        case let .paused(reason):
            MediaPausedCard(attachment: attachment, reason: reason)
        }
    }

    // MARK: - Files

    @ViewBuilder private var fileContent: some View {
        switch state {
        case let .ready(url):
            ShareLink(item: url) {
                AttachmentCardLabel(
                    symbol: "doc.fill",
                    title: attachment.displayName,
                    detail: [attachment.mimeType, byteLabel].compactMap { $0 }.joined(separator: " · ")
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share \(attachment.displayName)")
        case .idle, .loading:
            MediaPlaceholder(attachment: attachment)
        case let .failed(reason):
            MediaRetryCard(attachment: attachment, reason: reason) {
                model.media.retry(attachment, accountID: accountID, messageID: messageID)
            }
        case let .paused(reason):
            MediaPausedCard(attachment: attachment, reason: reason)
        }
    }

    // MARK: - Labels

    private var byteLabel: String? {
        AttachmentFormatting.byteLabel(attachment.byteCount)
    }

    private var durationLabel: String? {
        AttachmentFormatting.durationLabel(attachment.duration)
    }

    private var accessibilityLabel: String {
        AttachmentFormatting.accessibilityLabel(for: attachment)
    }
}

// MARK: - Cards

/// Reserves the right amount of space while bytes are on their way, so a transcript does not jump
/// as images arrive.
struct MediaPlaceholder: View {
    let attachment: MessageAttachment
    var durationLabel: String?

    private var height: CGFloat {
        guard let ratio = attachment.pixelSize?.aspectRatio, ratio > 0 else { return 120 }
        return min(320, max(80, 320 / ratio))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            VStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text([attachment.displayName, durationLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 320)
        .frame(height: attachment.kind == .audio ? 60 : height)
        .accessibilityLabel("Loading \(attachment.displayName)")
    }
}

struct MediaRetryCard: View {
    let attachment: MessageAttachment
    let reason: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttachmentCardLabel(
                symbol: "exclamationmark.triangle.fill",
                title: attachment.displayName,
                detail: reason
            )
            Button("Try again", action: retry)
                .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
        .accessibilityIdentifier("attachment-retry-\(attachment.id)")
    }
}

struct MediaPausedCard: View {
    let attachment: MessageAttachment
    let reason: String

    var body: some View {
        AttachmentCardLabel(symbol: "internaldrive.fill", title: attachment.displayName, detail: reason)
            .padding(10)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
            .accessibilityIdentifier("attachment-paused-\(attachment.id)")
    }
}

/// Content only the originating app can display.
///
/// The button opens a link that has already been verified as belonging to the platform that claims
/// it, so this never hands an arbitrary URL from a bridge to the system.
struct AppNativeCard: View {
    let attachment: MessageAttachment
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AttachmentCardLabel(
                symbol: attachment.deepLink?.platform.symbolName ?? "square.and.arrow.up",
                title: attachment.displayName,
                detail: attachment.reportedDescription
            )
            if let link = attachment.deepLink {
                Button("Open in \(link.platform.accessibilityLabel)") {
                    openURL(link.url)
                }
                .controlSize(.small)
                .accessibilityIdentifier("open-in-app-\(attachment.id)")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
    }
}

/// The visible fallback the design requires: never a dropped message, always an explanation.
struct UnsupportedAttachmentCard: View {
    let attachment: MessageAttachment
    var reason: String?

    var body: some View {
        AttachmentCardLabel(
            symbol: "questionmark.square.dashed",
            title: attachment.displayName,
            detail: reason ?? attachment.reportedDescription
                ?? "Inbox+ cannot display this yet, so it is shown as reported."
        )
        .padding(10)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
    }
}

struct AttachmentCardLabel: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
