import InboxPlusBridge
import InboxPlusCore
import SwiftUI

/// Lets the user choose a network to connect.
///
/// Offered platforms are listed with connectable networks first and coming-soon networks last.
/// Networks that cannot be added are disabled and explain their availability.
public struct AccountPickerView: View {
    private let connectedPlatforms: Set<Platform>
    private let onSelect: (Platform) -> Void
    private let onCancel: () -> Void

    public init(
        connectedPlatforms: Set<Platform>,
        onSelect: @escaping (Platform) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.connectedPlatforms = connectedPlatforms
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 12)]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add an account")
                    .font(.title2.bold())
                Text("Pick the network you want to bring into Inbox+.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(BridgeCatalog.pickerOrder, id: \.self) { platform in
                        tile(for: platform)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .screenAccessibilityIdentifier("account-picker")
    }

    @ViewBuilder
    private func tile(for platform: Platform) -> some View {
        let descriptor = BridgeCatalog.descriptor(for: platform)
        let isConnected = connectedPlatforms.contains(platform)
        // The one-account-per-platform rule is the app's, enforced in `AccountPolicy`; showing an
        // already-connected network as selectable would invite an error rather than prevent one.
        let isEnabled = BridgeCatalog.canConnect(platform) && !isConnected

        Button {
            onSelect(platform)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    PlatformBadge(platform: platform)
                    Text(platform.accessibilityLabel)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isConnected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(InboxPlusTheme.ink)
                    }
                }
                Text(subtitle(platform: platform, descriptor: descriptor, isConnected: isConnected))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(isEnabled ? 0.3 : 0.12), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .help(subtitle(platform: platform, descriptor: descriptor, isConnected: isConnected))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(platform.accessibilityLabel)
        .accessibilityHint(subtitle(platform: platform, descriptor: descriptor, isConnected: isConnected))
        .accessibilityIdentifier("picker-\(platform.rawValue)")
    }

    /// Explain whether the network is coming soon, connected, or ready for setup.
    private func subtitle(platform: Platform, descriptor: BridgeDescriptor?, isConnected: Bool) -> String {
        if BridgeCatalog.comingSoon.contains(platform) { return "It's coming soon" }
        if isConnected { return "Already connected" }
        guard let descriptor else {
            return BridgeCatalog.unavailabilityReason(for: platform) ?? "Not yet available in Inbox+"
        }
        return descriptor.credentialStyle.summary
    }
}
