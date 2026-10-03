import InboxPlusBridge
import InboxPlusCore
import SwiftUI

/// Menu bar panel section listing every network Inbox+ knows about and whether it is connected.
///
/// This mirrors `AccountPickerView`'s honesty rule: networks Inbox+ cannot bridge yet are listed
/// with the reason, because hiding them would misrepresent the roadmap as the product.
public struct PlatformConnectionsView: View {
    private let accounts: [ConnectedAccount]
    private let isAccountConnected: (String) -> Bool
    private let onConnect: (Platform) -> Void

    public init(
        accounts: [ConnectedAccount],
        isAccountConnected: @escaping (String) -> Bool,
        onConnect: @escaping (Platform) -> Void
    ) {
        self.accounts = accounts
        self.isAccountConnected = isAccountConnected
        self.onConnect = onConnect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connections")
                .font(.headline)
                .padding([.horizontal, .top], 14)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(BridgeCatalog.pickerOrder, id: \.self) { platform in
                        row(for: platform)
                        if platform != BridgeCatalog.pickerOrder.last {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(height: 360)
        .accessibilityIdentifier("platform-connections")
    }

    private func row(for platform: Platform) -> some View {
        let account = accounts.first { $0.platform == platform }
        let isAvailable = BridgeCatalog.canConnect(platform)

        return HStack(spacing: 10) {
            PlatformBadge(platform: platform)
            VStack(alignment: .leading, spacing: 2) {
                Text(platform.accessibilityLabel)
                    .fontWeight(.semibold)
                Text(statusLine(platform: platform, account: account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            statusAccessory(platform: platform, account: account, isAvailable: isAvailable)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-row-\(platform.rawValue)")
    }

    @ViewBuilder
    private func statusAccessory(
        platform: Platform,
        account: ConnectedAccount?,
        isAvailable: Bool
    ) -> some View {
        if let account {
            let connected = isAccountConnected(account.id)
            Circle()
                .fill(connected ? InboxPlusTheme.ink : Color.secondary)
                .frame(width: 8, height: 8)
                .accessibilityLabel(connected ? "Connected" : "Disconnected")
        } else if isAvailable {
            Button("Connect") { onConnect(platform) }
                .controlSize(.small)
                .accessibilityIdentifier("connect-\(platform.rawValue)")
        } else {
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Not available")
        }
    }

    private func statusLine(platform: Platform, account: ConnectedAccount?) -> String {
        if let account {
            return isAccountConnected(account.id)
                ? "Connected as \(account.displayName)"
                : "Disconnected — messages are kept"
        }
        if BridgeCatalog.comingSoon.contains(platform) { return "It's coming soon" }
        if BridgeCatalog.canConnect(platform) {
            return "Not connected"
        }
        return BridgeCatalog.unavailabilityReason(for: platform) ?? "Not yet available in Inbox+"
    }
}
