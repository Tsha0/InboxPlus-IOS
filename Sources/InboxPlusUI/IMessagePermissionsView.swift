#if os(macOS)
import AppKit
import SwiftUI

/// What iMessage needs instead of a password.
///
/// iMessage is reached through macOS itself, so there is no account to sign in to and no credential
/// for Inbox+ to hold. What it needs is two system permissions, which only the user can grant.
public struct IMessagePermissionsView: View {
    @State private var status = IMessagePermissions.current()
    private let onCancel: () -> Void
    private let onConnect: () -> Void

    public init(onConnect: @escaping () -> Void, onCancel: @escaping () -> Void = {}) {
        self.onConnect = onConnect
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect iMessage")
                    .font(.headline)
                Text("iMessage uses your Mac's own account. Inbox+ never asks for your Apple ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                row(
                    title: "Full Disk Access",
                    detail: "Lets Inbox+ read the local Messages database to show your conversations.",
                    granted: status.fullDiskAccess,
                    settingsURL: IMessagePermissions.fullDiskAccessSettingsURL
                )
                row(
                    title: "Automation",
                    detail: "Lets Inbox+ ask Messages to send a reply on your behalf.",
                    granted: status.automation,
                    settingsURL: IMessagePermissions.automationSettingsURL
                )
                Text("""
                After granting a permission in System Settings, come back here and choose Re-check. \
                macOS only applies some of these once Inbox+ is relaunched.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)

            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("Re-check") { status = IMessagePermissions.current() }
                    .accessibilityIdentifier("imessage-recheck")
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: onConnect)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!status.isComplete)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(.background)
        .accessibilityIdentifier("imessage-permissions")
    }

    private func row(
        title: String,
        detail: String,
        granted: Bool,
        settingsURL: URL
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? InboxPlusTheme.ink : Color.secondary)
                .accessibilityLabel(granted ? "Granted" : "Not granted")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !granted {
                Button("Open Settings") { NSWorkspace.shared.open(settingsURL) }
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("imessage-permission-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

/// Reports which of the two permissions iMessage needs are currently granted.
public struct IMessagePermissions: Equatable, Sendable {
    public let fullDiskAccess: Bool
    public let automation: Bool

    public var isComplete: Bool { fullDiskAccess && automation }

    public init(fullDiskAccess: Bool, automation: Bool) {
        self.fullDiskAccess = fullDiskAccess
        self.automation = automation
    }

    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
    public static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )!

    /// Probes by attempting the read that Full Disk Access actually gates.
    ///
    /// macOS exposes no API that answers "do I have Full Disk Access"; the only honest test is to
    /// try the protected read and see whether it is refused.
    public static func current(
        chatDatabase: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Messages/chat.db")
    ) -> IMessagePermissions {
        let readable = FileManager.default.isReadableFile(atPath: chatDatabase.path)
            && ((try? FileHandle(forReadingFrom: chatDatabase)) != nil)
        return IMessagePermissions(
            fullDiskAccess: readable,
            // Automation is only decided when the first Apple event is sent, and macOS shows its
            // own prompt then. Reporting it as granted here would be a guess, so it tracks the
            // permission that can actually be observed.
            automation: readable
        )
    }
}

#endif
