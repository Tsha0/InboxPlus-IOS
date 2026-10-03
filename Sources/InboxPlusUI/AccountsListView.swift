import InboxPlusBridge
import InboxPlusCore
import InboxPlusFeatures
import SwiftUI

struct AccountsListView: View {
    let accounts: [ConnectedAccount]
    let health: ServiceHealth
    let isConnected: (String) -> Bool
    let lastActivity: (String) -> Date?
    let onAddAccount: () -> Void
    let onDisconnect: (ConnectedAccount) -> Void
    let onReconnect: (ConnectedAccount) -> Void
    let onErase: (ConnectedAccount) -> Void

    /// Erasing is irreversible, so it goes through a confirmation naming the account.
    @State private var pendingErase: ConnectedAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.title2.bold())
                .padding(.horizontal)

            HStack(spacing: 8) {
                Image(systemName: health.symbolName)
                    .foregroundStyle(health == .healthy ? InboxPlusTheme.ink : .secondary)
                Text(health.menuBarTitle)
                    .font(.callout)
            }
            .padding(.horizontal)

            HStack {
                Text("Connected accounts")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onAddAccount()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
                .accessibilityIdentifier("add-account")
            }
            .padding(.horizontal)

            if accounts.isEmpty {
                ContentUnavailableView(
                    "No accounts yet",
                    systemImage: "person.badge.plus",
                    description: Text("Add a network to start bringing conversations into Inbox+.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(accounts) { account in
                    row(account)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
        .accessibilityIdentifier("inboxplus-settings")
        .confirmationDialog(
            "Remove \(pendingErase?.displayName ?? "this account")?",
            isPresented: Binding(
                get: { pendingErase != nil },
                set: { if !$0 { pendingErase = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove account and delete its messages", role: .destructive) {
                if let account = pendingErase { onErase(account) }
                pendingErase = nil
            }
            Button("Cancel", role: .cancel) { pendingErase = nil }
        } message: {
            Text("""
            Every conversation and message from this account is deleted from Inbox+. \
            This cannot be undone. To keep the history, disconnect instead.
            """)
        }
    }

    private func row(_ account: ConnectedAccount) -> some View {
        let connected = isConnected(account.id)
        return HStack(spacing: 10) {
            PlatformBadge(platform: account.platform)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.platform.accessibilityLabel)
                    .fontWeight(.semibold)
                Text(account.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(statusLine(account, connected: connected))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Circle()
                .fill(connected ? InboxPlusTheme.ink : Color.secondary)
                .frame(width: 8, height: 8)
                .accessibilityLabel(connected ? "Connected" : "Disconnected")
            Menu {
                if connected {
                    Button("Disconnect") { onDisconnect(account) }
                } else {
                    Button("Reconnect") { onReconnect(account) }
                }
                Divider()
                Button("Remove account…", role: .destructive) { pendingErase = account }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Manage \(account.platform.accessibilityLabel)")
            .accessibilityIdentifier("account-menu-\(account.id)")
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-row-\(account.id)")
    }

    private func statusLine(_ account: ConnectedAccount, connected: Bool) -> String {
        guard connected else { return "Disconnected — messages are kept" }
        guard let activity = lastActivity(account.id) else { return "Connected" }
        return "Last message \(activity.formatted(.relative(presentation: .named)))"
    }
}
