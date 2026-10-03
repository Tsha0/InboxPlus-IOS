import Foundation
import Testing
@testable import InboxPlusCore
@testable import InboxPlusGateway
@testable import InboxPlusFeatures

private actor OrderingTestGateway: TextOnlyTestGateway {
    private let snapshot: MessagingSnapshot
    private var continuations: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]

    init(snapshot: MessagingSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot() async throws -> MessagingSnapshot { snapshot }

    func events() async -> AsyncStream<GatewayEvent> {
        let id = UUID()
        let pair = AsyncStream<GatewayEvent>.makeStream()
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return pair.stream
    }

    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt {
        SendReceipt(messageID: UUID().uuidString, route: route, deliveryState: .acknowledged)
    }

    func publish(_ event: GatewayEvent) {
        continuations.values.forEach { $0.yield(event) }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }
}

@MainActor
private func settle(until condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
@Test func openingAConversationClearsOnlyItsUnreadBadge() async throws {
    let model = InboxPlusAppModel(
        gateway: InMemoryMessagingGateway(seed: Fixtures.snapshot),
        directory: Fixtures.directory
    )
    try await model.start()
    let instagramBefore = try #require(
        model.conversations.first { $0.route == Fixtures.instagramRoute }?.unreadCount
    )
    #expect(instagramBefore == 2)

    model.openConversation(Fixtures.instagramRoute)

    #expect(model.conversations.first { $0.route == Fixtures.instagramRoute }?.unreadCount == 0)
    #expect(model.conversations.first { $0.route == Fixtures.whatsAppRoute }?.unreadCount == 1)
    let maya = try #require(model.inboxItems.first { $0.id == .person("maya") })
    #expect(maya.unreadCount == 1)
}

@MainActor
@Test func selectingAStandaloneInboxConversationMarksItRead() async throws {
    let unreadFamily = Fixtures.makeSnapshot(
        familyActivity: Date(timeIntervalSince1970: 100),
        whatsAppActivity: Date(timeIntervalSince1970: 200),
        instagramActivity: Date(timeIntervalSince1970: 300)
    )
    var seeded = unreadFamily
    seeded.conversations = seeded.conversations.map { conversation in
        var copy = conversation
        if copy.route == Fixtures.telegramRoute { copy.unreadCount = 4 }
        return copy
    }
    let model = InboxPlusAppModel(
        gateway: InMemoryMessagingGateway(seed: seeded),
        directory: Fixtures.directory
    )
    try await model.start()
    let item = try #require(
        model.inboxItems.first { $0.id == .conversation(Fixtures.telegramRoute) }
    )
    #expect(item.unreadCount == 4)

    model.selectInboxItem(item)

    #expect(model.detailSelection == .conversation(Fixtures.telegramRoute))
    #expect(model.conversations.first { $0.route == Fixtures.telegramRoute }?.unreadCount == 0)
}

@MainActor
@Test func markingAnAlreadyReadConversationIsANoOp() async throws {
    let model = InboxPlusAppModel(
        gateway: InMemoryMessagingGateway(seed: Fixtures.snapshot),
        directory: Fixtures.directory
    )
    try await model.start()
    model.markConversationRead(Fixtures.telegramRoute)
    let itemsAfterFirst = model.inboxItems

    model.markConversationRead(Fixtures.telegramRoute)

    #expect(model.inboxItems == itemsAfterFirst)
}

@MainActor
@Test func lateArrivingOlderMessageIsPlacedInTimestampOrder() async throws {
    let gateway = OrderingTestGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()

    let older = Message(
        id: "tg-older",
        route: Fixtures.telegramRoute,
        senderIdentityID: "family-telegram-identity",
        body: "Arrived late, happened first",
        timestamp: Date(timeIntervalSince1970: 50),
        deliveryState: .acknowledged
    )
    let newer = Message(
        id: "tg-newer",
        route: Fixtures.telegramRoute,
        senderIdentityID: nil,
        body: "Newest",
        timestamp: Date(timeIntervalSince1970: 500),
        deliveryState: .acknowledged
    )

    await gateway.publish(.messageUpserted(newer))
    await gateway.publish(.messageUpserted(older))

    let applied = await settle {
        (model.messagesByRoute[Fixtures.telegramRoute] ?? []).count == 3
    }
    #expect(applied)

    let timestamps = (model.messagesByRoute[Fixtures.telegramRoute] ?? []).map(\.timestamp)
    #expect(timestamps == timestamps.sorted())
    #expect(model.messagesByRoute[Fixtures.telegramRoute]?.first?.id == older.id)
    #expect(model.messagesByRoute[Fixtures.telegramRoute]?.last?.id == newer.id)
}

@MainActor
@Test func snapshotMessagesAreSortedRegardlessOfSeedOrder() async throws {
    var scrambled = Fixtures.snapshot
    let route = Fixtures.telegramRoute
    scrambled.messagesByRoute[route] = [
        Message(id: "c", route: route, senderIdentityID: nil, body: "third", timestamp: Date(timeIntervalSince1970: 300), deliveryState: .acknowledged),
        Message(id: "a", route: route, senderIdentityID: nil, body: "first", timestamp: Date(timeIntervalSince1970: 100), deliveryState: .acknowledged),
        Message(id: "b", route: route, senderIdentityID: nil, body: "second", timestamp: Date(timeIntervalSince1970: 200), deliveryState: .acknowledged),
    ]
    let model = InboxPlusAppModel(
        gateway: InMemoryMessagingGateway(seed: scrambled),
        directory: Fixtures.directory
    )

    try await model.start()

    #expect(model.messagesByRoute[route]?.map(\.id) == ["a", "b", "c"])
}

@Test func outgoingMessagesAreTheOnesWithoutARemoteSender() {
    let route = ConversationRoute(accountID: "wa", conversationID: "chat")
    let mine = Message(id: "1", route: route, senderIdentityID: nil, body: "hi", timestamp: .now, deliveryState: .acknowledged)
    let theirs = Message(id: "2", route: route, senderIdentityID: "them", body: "hi", timestamp: .now, deliveryState: .acknowledged)

    #expect(mine.isOutgoing)
    #expect(!theirs.isOutgoing)
}

@Test func demoSnapshotIsRecentEnoughToReadAsRelativeTime() throws {
    let demo = Fixtures.demoSnapshot
    let newest = try #require(demo.conversations.map(\.latestActivity).max())

    #expect(newest.timeIntervalSinceNow > -60 * 60)
    #expect(newest <= Date())
    #expect(demo.conversations.count == Fixtures.snapshot.conversations.count)
}

@Test func deterministicSnapshotKeepsItsFixedTimestamps() {
    let whatsApp = Fixtures.snapshot.conversations.first { $0.route == Fixtures.whatsAppRoute }
    let instagram = Fixtures.snapshot.conversations.first { $0.route == Fixtures.instagramRoute }
    let telegram = Fixtures.snapshot.conversations.first { $0.route == Fixtures.telegramRoute }

    #expect(whatsApp?.latestActivity == Date(timeIntervalSince1970: 200))
    #expect(instagram?.latestActivity == Date(timeIntervalSince1970: 300))
    #expect(telegram?.latestActivity == Date(timeIntervalSince1970: 100))
    #expect(Fixtures.snapshot.messagesByRoute[Fixtures.instagramRoute]?.count == 1)
}

@MainActor
@Test func disconnectedAccountsReportTheirConnectionState() async throws {
    let gateway = OrderingTestGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    #expect(model.isConnected("whatsapp-primary"))

    await gateway.publish(.connectionChanged(accountID: "whatsapp-primary", isConnected: false))

    let applied = await settle { !model.isConnected("whatsapp-primary") }
    #expect(applied)
    #expect(model.isConnected("instagram-primary"))
}
