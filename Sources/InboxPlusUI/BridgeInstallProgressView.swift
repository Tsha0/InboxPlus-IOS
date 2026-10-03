import SwiftUI
import InboxPlusCore

/// Shown while a network's bridge is being fetched and registered.
///
/// The download is a pinned binary of tens of megabytes, so this is the difference between a click
/// that appears to do nothing and one that is visibly working. There is no Cancel: the install
/// writes into the profile, and abandoning it halfway would leave a half-registered bridge behind.
public struct BridgeInstallProgressView: View {
    private let platform: Platform

    public init(platform: Platform) {
        self.platform = platform
    }

    public var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 4) {
                Text("Setting up \(platform.accessibilityLabel)")
                    .font(.headline)
                Text("Downloading the bridge and registering it with your local homeserver. This happens once per network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(minWidth: 420, minHeight: 220)
        .background(.background)
        .accessibilityIdentifier("bridge-install-progress")
    }
}
