import Foundation
import Testing
import InboxPlusCore
import InboxPlusGateway
@testable import InboxPlusFeatures

@MainActor
@Test func aModelWithNoDirectoryHasNobodyInContacts() async throws {
    // The app wired `Fixtures.directory` in unconditionally, so a demo person appeared in Contacts
    // beside real conversations, linked to identities that do not exist on the account. A fake
    // contact next to real ones is indistinguishable from a bug.
    let model = InboxPlusAppModel(gateway: InMemoryMessagingGateway(seed: .empty))
    try await model.start()

    #expect(model.people.isEmpty)
}

@MainActor
@Test func fixtureContactsStillWorkWhenTheyAreAskedFor() async throws {
    // Demo mode and the tests still want them; the change is that they are opt-in.
    let model = InboxPlusAppModel(
        gateway: InMemoryMessagingGateway(seed: Fixtures.snapshot),
        directory: Fixtures.directory
    )
    try await model.start()

    #expect(model.people.map(\.displayName) == ["Maya"])
}

@MainActor
@Test func anEmptyDirectoryLeavesRealConversationsStandingAlone() async throws {
    // Without a linked person each conversation is its own inbox row, which is what an account
    // looks like before the user has linked anyone.
    let snapshot = MessagingSnapshot(
        accounts: [ConnectedAccount(id: "instagram", platform: .instagram, displayName: "Instagram")],
        identities: [RemoteIdentity(id: "them", accountID: "instagram", displayName: "Jason")],
        conversations: [
            RemoteConversation(
                id: "c1",
                accountID: "instagram",
                identityID: "them",
                title: "Jason",
                latestActivity: Date(timeIntervalSince1970: 10),
                unreadCount: 0
            ),
        ],
        messagesByRoute: [:]
    )
    let model = InboxPlusAppModel(gateway: InMemoryMessagingGateway(seed: snapshot))
    try await model.start()

    #expect(model.people.isEmpty)
    #expect(model.inboxItems.count == 1)
    #expect(model.inboxItems.first?.conversationSummaries.first?.title == "Jason")
}
