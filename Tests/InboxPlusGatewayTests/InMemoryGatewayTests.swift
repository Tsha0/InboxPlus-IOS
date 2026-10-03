import Foundation
import Testing
@testable import InboxPlusCore
@testable import InboxPlusGateway

@Test func snapshotReturnsSeededRecords() async throws {
    let route = ConversationRoute(accountID: "telegram-primary", conversationID: "family")
    let gateway = InMemoryMessagingGateway(seed: .init(
        accounts: [.init(id: route.accountID, platform: .telegram, displayName: "Personal")],
        identities: [.init(id: "family-id", accountID: route.accountID, displayName: "Family")],
        conversations: [.init(id: route.conversationID, accountID: route.accountID, identityID: "family-id", title: "Family", latestActivity: .distantPast, unreadCount: 1)],
        messagesByRoute: [route: []]
    ))

    let snapshot = try await gateway.loadSnapshot()
    #expect(snapshot.accounts.count == 1)
    #expect(snapshot.conversations.first?.route == route)
}

@Test func sendAcknowledgesTheExactRouteAndPublishesEvent() async throws {
    let expected = ConversationRoute(accountID: "instagram-primary", conversationID: "maya-ig")
    let gateway = InMemoryMessagingGateway(seed: .empty)
    let stream = await gateway.events()

    let receipt = try await gateway.sendText("Hello", to: expected)
    #expect(receipt.route == expected)
    #expect(receipt.deliveryState == .acknowledged)

    for await event in stream {
        guard case let .messageUpserted(message) = event else { continue }
        #expect(message.route == expected)
        #expect(message.body == "Hello")
        break
    }
}
