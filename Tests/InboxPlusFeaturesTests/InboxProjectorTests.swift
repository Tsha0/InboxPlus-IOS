import Foundation
import Testing
@testable import InboxPlusCore
@testable import InboxPlusFeatures

@Test func linkedIdentitiesBecomeOneInboxPersonWithSummedUnread() throws {
    let accounts = [
        ConnectedAccount(id: "wa", platform: .whatsApp, displayName: "Personal"),
        ConnectedAccount(id: "ig", platform: .instagram, displayName: "Personal")
    ]
    let identities = [
        RemoteIdentity(id: "maya-wa", accountID: "wa", displayName: "Maya"),
        RemoteIdentity(id: "maya-ig", accountID: "ig", displayName: "@maya")
    ]
    let conversations = [
        RemoteConversation(id: "wa-chat", accountID: "wa", identityID: "maya-wa", title: "Maya", latestActivity: Date(timeIntervalSince1970: 10), unreadCount: 2),
        RemoteConversation(id: "ig-chat", accountID: "ig", identityID: "maya-ig", title: "@maya", latestActivity: Date(timeIntervalSince1970: 20), unreadCount: 3)
    ]
    var directory = ContactDirectory()
    try directory.createPerson(id: "maya", displayName: "Maya")
    try directory.link(remoteIdentityID: "maya-wa", to: "maya")
    try directory.link(remoteIdentityID: "maya-ig", to: "maya")

    let result = InboxProjector.project(accounts: accounts, identities: identities, conversations: conversations, directory: directory)

    #expect(result.count == 1)
    #expect(result[0].id == .person("maya"))
    #expect(result[0].unreadCount == 5)
    #expect(result[0].conversationSummaries.map(\.route) == [
        ConversationRoute(accountID: "ig", conversationID: "ig-chat"),
        ConversationRoute(accountID: "wa", conversationID: "wa-chat")
    ])
}

@Test func unlinkedConversationRemainsStandalone() {
    let account = ConnectedAccount(id: "tg", platform: .telegram, displayName: "Personal")
    let identity = RemoteIdentity(id: "family", accountID: "tg", displayName: "Family")
    let conversation = RemoteConversation(id: "family-chat", accountID: "tg", identityID: "family", title: "Family", latestActivity: .distantPast, unreadCount: 1)

    let result = InboxProjector.project(accounts: [account], identities: [identity], conversations: [conversation], directory: ContactDirectory())

    #expect(result.map(\.id) == [.conversation(conversation.route)])
}

@Test func equalActivityUsesRoutesForStableOrderingAcrossInputPermutations() throws {
    let accounts = [
        ConnectedAccount(id: "account-b", platform: .whatsApp, displayName: "Personal"),
        ConnectedAccount(id: "account-a", platform: .instagram, displayName: "Personal"),
        ConnectedAccount(id: "account-c", platform: .telegram, displayName: "Personal")
    ]
    let identities = [
        RemoteIdentity(id: "maya-b", accountID: "account-b", displayName: "Maya"),
        RemoteIdentity(id: "maya-a", accountID: "account-a", displayName: "Maya"),
        RemoteIdentity(id: "family", accountID: "account-c", displayName: "Family")
    ]
    let conversations = [
        RemoteConversation(id: "chat-b", accountID: "account-b", identityID: "maya-b", title: "Maya", latestActivity: .distantPast, unreadCount: 1),
        RemoteConversation(id: "family-chat", accountID: "account-c", identityID: "family", title: "Family", latestActivity: .distantPast, unreadCount: 1),
        RemoteConversation(id: "chat-a", accountID: "account-a", identityID: "maya-a", title: "Maya", latestActivity: .distantPast, unreadCount: 1)
    ]
    var directory = ContactDirectory()
    try directory.createPerson(id: "maya", displayName: "Maya")
    try directory.link(remoteIdentityID: "maya-a", to: "maya")
    try directory.link(remoteIdentityID: "maya-b", to: "maya")

    let original = InboxProjector.project(accounts: accounts, identities: identities, conversations: conversations, directory: directory)
    let permuted = InboxProjector.project(accounts: accounts, identities: identities, conversations: conversations.reversed(), directory: directory)
    let expectedInboxIDs: [InboxItem.ID] = [
        .conversation(ConversationRoute(accountID: "account-c", conversationID: "family-chat")),
        .person("maya")
    ]
    let expectedMayaRoutes = [
        ConversationRoute(accountID: "account-a", conversationID: "chat-a"),
        ConversationRoute(accountID: "account-b", conversationID: "chat-b")
    ]

    #expect(original.map(\.id) == expectedInboxIDs)
    #expect(permuted.map(\.id) == expectedInboxIDs)
    #expect(original[1].conversationSummaries.map(\.route) == expectedMayaRoutes)
    #expect(permuted[1].conversationSummaries.map(\.route) == expectedMayaRoutes)
}

@Test func crossAccountIdentityReferenceCannotAggregateIntoALinkedPerson() throws {
    let accounts = [
        ConnectedAccount(id: "wa", platform: .whatsApp, displayName: "Personal"),
        ConnectedAccount(id: "ig", platform: .instagram, displayName: "Personal"),
    ]
    let identities = [
        RemoteIdentity(id: "maya-wa", accountID: "wa", displayName: "Maya"),
        RemoteIdentity(id: "maya-ig", accountID: "ig", displayName: "@maya"),
    ]
    let validRoute = ConversationRoute(accountID: "wa", conversationID: "wa-chat")
    let malformedRoute = ConversationRoute(accountID: "ig", conversationID: "malformed-chat")
    let conversations = [
        RemoteConversation(
            id: validRoute.conversationID,
            accountID: validRoute.accountID,
            identityID: "maya-wa",
            title: "Maya",
            latestActivity: Date(timeIntervalSince1970: 10),
            unreadCount: 1
        ),
        RemoteConversation(
            id: malformedRoute.conversationID,
            accountID: malformedRoute.accountID,
            identityID: "maya-wa",
            title: "Malformed cross-account reference",
            latestActivity: Date(timeIntervalSince1970: 20),
            unreadCount: 9
        ),
    ]
    var directory = ContactDirectory()
    try directory.createPerson(id: "maya", displayName: "Maya")
    try directory.link(remoteIdentityID: "maya-wa", to: "maya")

    let result = InboxProjector.project(
        accounts: accounts,
        identities: identities,
        conversations: conversations,
        directory: directory
    )

    #expect(result.map(\.id) == [.person("maya")])
    #expect(result[0].conversationSummaries.map(\.route) == [validRoute])
    #expect(result[0].unreadCount == 1)
    #expect(result.flatMap(\.conversationSummaries).contains { $0.route == malformedRoute } == false)
}
