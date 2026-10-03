import SwiftUI
import InboxPlusCore

struct LinkPersonSheet: View {
    let people: [InboxPlusPerson]
    let onSelect: (String) -> Void
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link to person")
                .font(.title2.bold())
            Text("Group this conversation under one person so it shows up once in your inbox.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if people.isEmpty {
                Text("No people yet — create one below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            } else {
                List(people) { person in
                    Button {
                        onSelect(person.id)
                        dismiss()
                    } label: {
                        HStack {
                            Text(person.displayName)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 140)
            }

            Divider()

            Text("Create a new person")
                .font(.subheadline.weight(.semibold))
            TextField("New person’s name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createAndDismiss)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create and link", action: createAndDismiss)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: 480)
    }

    private func createAndDismiss() {
        guard !trimmedName.isEmpty else { return }
        onCreate(newName)
        dismiss()
    }
}
