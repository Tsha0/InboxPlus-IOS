import SwiftUI
import InboxPlusCore

public struct PlatformBadgeDescriptor: Sendable {
    public let symbolName: String
    public let accessibilityLabel: String

    public init(platform: Platform) {
        symbolName = platform.symbolName
        accessibilityLabel = platform.accessibilityLabel
    }
}

public struct ContactConversationCardDescriptor: Sendable {
    public let route: ConversationRoute
    public let platform: Platform
    public let title: String
    public let preview: String
    public let timestampDescription: String
    public let unreadCount: Int

    public var accessibilityLabel: String {
        let readState = unreadCount > 0 ? "\(unreadCount) unread" : "Read"
        return "\(platform.accessibilityLabel), \(title), \(preview), \(timestampDescription), \(readState)"
    }

    public init(
        route: ConversationRoute,
        platform: Platform,
        title: String,
        preview: String,
        timestampDescription: String,
        unreadCount: Int
    ) {
        self.route = route
        self.platform = platform
        self.title = title
        self.preview = preview
        self.timestampDescription = timestampDescription
        self.unreadCount = unreadCount
    }
}

/// The network's recognizable mark, drawn in the app's monochrome palette.
///
/// A platform Inbox+ has no mark for falls back to the SF Symbol it always used, so a new network
/// is never a blank square while its icon is being added.
public struct PlatformBadge: View {
    let platform: Platform
    var size: CGFloat = 22

    public init(platform: Platform, size: CGFloat = 22) {
        self.platform = platform
        self.size = size
    }

    public var body: some View {
        let descriptor = PlatformBadgeDescriptor(platform: platform)
        Group {
            if PlatformGlyph.plateColor(for: platform) != nil {
                PlatformGlyphMark(platform: platform)
                    // Invert the mark against its plate in both light and dark appearances.
                    .fill(InboxPlusTheme.paper)
                    .padding(size * 0.22)
                    .frame(width: size, height: size)
                    .background(InboxPlusTheme.ink, in: .rect(cornerRadius: size * 0.28))
            } else {
                Image(systemName: descriptor.symbolName)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityLabel(descriptor.accessibilityLabel)
        .help(descriptor.accessibilityLabel)
    }
}

/// Wraps the generated path so it can be filled, scaled and animated like any other shape.
struct PlatformGlyphMark: Shape {
    let platform: Platform

    func path(in rect: CGRect) -> Path {
        PlatformGlyph.path(for: platform, in: rect) ?? Path()
    }
}
