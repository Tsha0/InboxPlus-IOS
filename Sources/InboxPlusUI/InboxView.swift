import SwiftUI
import InboxPlusFeatures

public struct InboxView: View {
    let items: [InboxItem]
    let selectedID: InboxItem.ID?
    let onSelect: (InboxItem) -> Void
    @State private var showsUnreadOnly = false
    @State private var query = ""

    public init(
        items: [InboxItem],
        selectedID: InboxItem.ID? = nil,
        onSelect: @escaping (InboxItem) -> Void
    ) {
        self.items = items
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    private var visibleItems: [InboxItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            if showsUnreadOnly, item.unreadCount == 0 { return false }
            guard !trimmed.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(trimmed)
                || item.conversationSummaries.contains {
                    $0.title.localizedCaseInsensitiveContains(trimmed)
                        || $0.latestPreview.localizedCaseInsensitiveContains(trimmed)
                }
        }
    }

    private var unreadTotal: Int {
        items.reduce(0) { $0 + $1.unreadCount }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Inbox")
                    .font(.title2.bold())
                Spacer()
                if unreadTotal > 0 {
                    Text("\(unreadTotal)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(InboxPlusTheme.paper)
                        .background(InboxPlusTheme.ink, in: .capsule)
                        .accessibilityLabel("\(unreadTotal) unread in total")
                }
            }
            .padding(.horizontal)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("inbox-search")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            .padding(.horizontal)

            HStack(spacing: 6) {
                filterButton("All", isSelected: !showsUnreadOnly) {
                    showsUnreadOnly = false
                }
                filterButton("Unread", isSelected: showsUnreadOnly) {
                    showsUnreadOnly = true
                }
            }
            .padding(.horizontal)

            if visibleItems.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: showsUnreadOnly ? "checkmark.circle" : "magnifyingglass"
                )
                .frame(maxHeight: .infinity)
            } else {
                List(visibleItems) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        row(for: item)
                    }
                    .buttonStyle(.plain)
                    .selectedRowBackground(selectedID == item.id)
                    .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
                    .accessibilityIdentifier("inbox-item-\(item.id.accessibilityIdentifier)")
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
        .screenAccessibilityIdentifier("inboxplus-inbox")
    }

    private var emptyTitle: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No matches" }
        return showsUnreadOnly ? "Nothing unread" : "Inbox is empty"
    }

    private func row(for item: InboxItem) -> some View {
        HStack(spacing: 8) {
            if let first = item.conversationSummaries.first {
                PlatformBadge(platform: first.platform)
            }
            if item.conversationSummaries.count > 1 {
                Text("+\(item.conversationSummaries.count - 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "\(item.conversationSummaries.count - 1) additional network\(item.conversationSummaries.count == 2 ? "" : "s")"
                    )
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .fontWeight(.semibold)
                Text(item.conversationSummaries.first?.latestPreview ?? "")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(RelativeTime.short(item.latestActivity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.unreadCount > 0 {
                    Text("\(item.unreadCount)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(InboxPlusTheme.paper)
                        .background(InboxPlusTheme.ink, in: .capsule)
                        .accessibilityLabel("\(item.unreadCount) unread")
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
    }

    private func filterButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.primary.opacity(0.1) : .clear, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
