import SwiftUI
import InboxPlusCore
import InboxPlusFeatures

struct ContactsListView: View {
    let people: [InboxPlusPerson]
    let items: [InboxItem]
    let selectedPersonID: String?
    let onSelect: (String) -> Void

    private func summaries(for personID: String) -> [ConversationSummary] {
        items.first { $0.id == .person(personID) }?.conversationSummaries ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Contacts")
                .font(.title2.bold())
                .padding(.horizontal)

            if people.isEmpty {
                ContentUnavailableView(
                    "No people yet",
                    systemImage: "person.2",
                    description: Text("Link a conversation to a person to group it here.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(people) { person in
                    let linked = summaries(for: person.id)
                    Button {
                        onSelect(person.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text(initials(for: person.displayName))
                                .font(.caption.weight(.semibold))
                                .frame(width: 28, height: 28)
                                .background(.quaternary, in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.displayName)
                                    .fontWeight(.semibold)
                                Text(linked.isEmpty ? "No linked conversations" : linkedDescription(linked))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            ForEach(linked) { summary in
                                PlatformBadge(platform: summary.platform)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .selectedRowBackground(selectedPersonID == person.id)
                    .accessibilityAddTraits(selectedPersonID == person.id ? .isSelected : [])
                    .accessibilityIdentifier("contact-row-\(person.id)")
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
        .screenAccessibilityIdentifier("inboxplus-contacts")
    }

    private func linkedDescription(_ summaries: [ConversationSummary]) -> String {
        let networks = summaries.map(\.platform.accessibilityLabel)
        return networks.count == 1 ? networks[0] : networks.joined(separator: " · ")
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
