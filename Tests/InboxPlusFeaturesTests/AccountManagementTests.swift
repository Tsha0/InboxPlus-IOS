import Foundation
import Testing
@testable import InboxPlusCore
@testable import InboxPlusFeatures
@testable import InboxPlusGateway

@MainActor
private func startedModel(seed: MessagingSnapshot) async throws -> InboxPlusAppModel {
    let model = InboxPlusAppModel(gateway: InMemoryMessagingGateway(seed: seed))
    try await model.start()
    return model
}

private func snapshot(
    accounts: [ConnectedAccount],
    identities: [RemoteIdentity] = [],
    conversations: [RemoteConversation] = [],
    messages: [ConversationRoute: [Message]] = [:]
) -> MessagingSnapshot {
    MessagingSnapshot(
        accounts: accounts,
        identities: identities,
        conversations: conversations,
        messagesByRoute: messages
    )
}

private let instagramAccount = ConnectedAccount(
    id: "instagram:1784",
    platform: .instagram,
    displayName: "throwaway"
)

@MainActor
@Test func aSecondAccountOnTheSamePlatformIsRefused() async throws {
    let model = try await startedModel(seed: snapshot(accounts: [instagramAccount]))

    #expect(throws: AccountPolicyError.duplicatePlatform(.instagram)) {
        try model.addAccount(
            ConnectedAccount(id: "instagram:other", platform: .instagram, displayName: "second")
        )
    }
    #expect(model.accounts.count == 1)
}

@MainActor
@Test func adifferentPlatformIsAccepted() async throws {
    let model = try await startedModel(seed: snapshot(accounts: [instagramAccount]))

    try model.addAccount(
        ConnectedAccount(id: "whatsapp:1", platform: .whatsApp, displayName: "+15551234567")
    )
    #expect(model.platformsWithAccounts == [.instagram, .whatsApp])
}

@MainActor
@Test func disconnectingKeepsEveryMessageTheAccountDelivered() async throws {
    let route = ConversationRoute(accountID: instagramAccount.id, conversationID: "!room")
    let model = try await startedModel(seed: snapshot(
        accounts: [instagramAccount],
        identities: [RemoteIdentity(id: "maya", accountID: instagramAccount.id, displayName: "Maya")],
        conversations: [RemoteConversation(
            id: "!room",
            accountID: instagramAccount.id,
            identityID: "maya",
            title: "Maya",
            latestActivity: .now,
            unreadCount: 0
        )],
        messages: [route: [Message(
            id: "$1",
            route: route,
            senderIdentityID: "maya",
            body: "hello",
            timestamp: .now,
            deliveryState: .acknowledged
        )]]
    ))

    model.disconnect(accountID: instagramAccount.id)

    #expect(!model.isConnected(instagramAccount.id))
    #expect(model.accounts.count == 1, "disconnecting is not removing")
    #expect(model.messagesByRoute[route]?.count == 1, "history must survive a disconnection")
    #expect(model.healthBannerMessage != nil)
}

@MainActor
@Test func reconnectingClearsTheWarning() async throws {
    let model = try await startedModel(seed: snapshot(accounts: [instagramAccount]))

    model.disconnect(accountID: instagramAccount.id)
    model.reconnect(accountID: instagramAccount.id)

    #expect(model.isConnected(instagramAccount.id))
    #expect(model.health == .healthy)
}

@MainActor
@Test func erasingAnAccountRemovesEverythingItBrought() async throws {
    let route = ConversationRoute(accountID: instagramAccount.id, conversationID: "!room")
    let keptAccount = ConnectedAccount(id: "whatsapp:1", platform: .whatsApp, displayName: "kept")
    let keptRoute = ConversationRoute(accountID: keptAccount.id, conversationID: "!kept")
    let model = try await startedModel(seed: snapshot(
        accounts: [instagramAccount, keptAccount],
        identities: [
            RemoteIdentity(id: "maya", accountID: instagramAccount.id, displayName: "Maya"),
            RemoteIdentity(id: "sam", accountID: keptAccount.id, displayName: "Sam"),
        ],
        conversations: [
            RemoteConversation(
                id: "!room",
                accountID: instagramAccount.id,
                identityID: "maya",
                title: "Maya",
                latestActivity: .now,
                unreadCount: 0
            ),
            RemoteConversation(
                id: "!kept",
                accountID: keptAccount.id,
                identityID: "sam",
                title: "Sam",
                latestActivity: .now,
                unreadCount: 0
            ),
        ],
        messages: [
            route: [Message(
                id: "$1",
                route: route,
                senderIdentityID: "maya",
                body: "hello",
                timestamp: .now,
                deliveryState: .acknowledged
            )],
            keptRoute: [Message(
                id: "$2",
                route: keptRoute,
                senderIdentityID: "sam",
                body: "kept",
                timestamp: .now,
                deliveryState: .acknowledged
            )],
        ]
    ))

    model.openConversation(route)
    model.eraseAccount(accountID: instagramAccount.id)

    #expect(model.accounts.map(\.id) == [keptAccount.id])
    #expect(model.conversations.map(\.id) == ["!kept"])
    #expect(model.messagesByRoute[route] == nil)
    #expect(model.identities.map(\.id) == ["sam"])
    // The open conversation belonged to the erased account, so the detail pane cannot keep showing it.
    #expect(model.detailSelection == .empty)
    // Everything belonging to the other account is untouched.
    #expect(model.messagesByRoute[keptRoute]?.count == 1)
}

@MainActor
@Test func erasingOneAccountLeavesAnotherAccountsDisconnectionWarningIntact() async throws {
    let doomed = ConnectedAccount(id: "instagram:1", platform: .instagram, displayName: "a")
    let troubled = ConnectedAccount(id: "whatsapp:1", platform: .whatsApp, displayName: "b")
    let model = try await startedModel(seed: snapshot(accounts: [doomed, troubled]))

    model.disconnect(accountID: troubled.id)
    model.eraseAccount(accountID: doomed.id)

    #expect(!model.isConnected(troubled.id))
    #expect(model.healthBannerMessage != nil, "an unrelated account is still disconnected")
}

@MainActor
@Test func lastActivityTracksTheNewestMessagePerAccount() async throws {
    let route = ConversationRoute(accountID: instagramAccount.id, conversationID: "!room")
    let old = Date(timeIntervalSince1970: 1_000)
    let model = try await startedModel(seed: snapshot(
        accounts: [instagramAccount],
        identities: [RemoteIdentity(id: "maya", accountID: instagramAccount.id, displayName: "Maya")],
        conversations: [RemoteConversation(
            id: "!room",
            accountID: instagramAccount.id,
            identityID: "maya",
            title: "Maya",
            latestActivity: old,
            unreadCount: 0
        )]
    ))

    #expect(model.lastActivity(for: instagramAccount.id) == old)
    #expect(model.lastActivity(for: "nobody") == nil)
}
