import Foundation
import Testing
@testable import InboxPlusCore
@testable import InboxPlusGateway
@testable import InboxPlusFeatures

private actor AppModelTestGateway: TextOnlyTestGateway {
    private let snapshot: MessagingSnapshot
    private var continuations: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]

    init(snapshot: MessagingSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot() async throws -> MessagingSnapshot {
        snapshot
    }

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

    func activeSubscriptionCount() -> Int {
        continuations.count
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

private actor ControlledSendGateway: TextOnlyTestGateway {
    struct Submission: Equatable, Sendable {
        let body: String
        let route: ConversationRoute
    }

    private let snapshot: MessagingSnapshot
    private var continuation: CheckedContinuation<SendReceipt, any Error>?
    private(set) var submission: Submission?

    init(snapshot: MessagingSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot() async throws -> MessagingSnapshot { snapshot }

    func events() async -> AsyncStream<GatewayEvent> {
        AsyncStream { $0.finish() }
    }

    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt {
        submission = Submission(body: body, route: route)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func completeSend() {
        continuation?.resume(
            returning: SendReceipt(
                messageID: "controlled-message",
                route: submission!.route,
                deliveryState: .acknowledged
            )
        )
        continuation = nil
    }
}

private actor RetrySendGateway: TextOnlyTestGateway {
    private let snapshot: MessagingSnapshot
    private var failsSends = true

    init(snapshot: MessagingSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot() async throws -> MessagingSnapshot { snapshot }

    func events() async -> AsyncStream<GatewayEvent> {
        AsyncStream { $0.finish() }
    }

    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt {
        if failsSends { throw AppModelTestError.gatewayUnavailable }
        return SendReceipt(messageID: "retry-message", route: route, deliveryState: .acknowledged)
    }

    func allowSends() {
        failsSends = false
    }
}

private actor OrderedSendGateway: TextOnlyTestGateway {
    private struct PendingSend {
        let route: ConversationRoute
        let continuation: CheckedContinuation<SendReceipt, any Error>
    }

    private let snapshot: MessagingSnapshot
    private var pendingSends: [String: PendingSend] = [:]

    init(snapshot: MessagingSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot() async throws -> MessagingSnapshot { snapshot }

    func events() async -> AsyncStream<GatewayEvent> {
        AsyncStream { $0.finish() }
    }

    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt {
        try await withCheckedThrowingContinuation {
            pendingSends[body] = PendingSend(route: route, continuation: $0)
        }
    }

    func pendingSendCount() -> Int {
        pendingSends.count
    }

    func succeed(_ body: String) {
        guard let pending = pendingSends.removeValue(forKey: body) else { return }
        pending.continuation.resume(
            returning: SendReceipt(
                messageID: "ordered-\(body)",
                route: pending.route,
                deliveryState: .acknowledged
            )
        )
    }

    func fail(_ body: String) {
        pendingSends.removeValue(forKey: body)?.continuation.resume(
            throwing: AppModelTestError.gatewayUnavailable
        )
    }
}

private actor ControlledStartGateway: TextOnlyTestGateway {
    private let snapshot: MessagingSnapshot
    private var snapshotContinuations: [CheckedContinuation<MessagingSnapshot, any Error>] = []
    private var eventContinuations: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private(set) var snapshotLoadCount = 0

    init(snapshot: MessagingSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot() async throws -> MessagingSnapshot {
        snapshotLoadCount += 1
        return try await withCheckedThrowingContinuation {
            snapshotContinuations.append($0)
        }
    }

    func events() async -> AsyncStream<GatewayEvent> {
        let id = UUID()
        let pair = AsyncStream<GatewayEvent>.makeStream()
        eventContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return pair.stream
    }

    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt {
        SendReceipt(messageID: UUID().uuidString, route: route, deliveryState: .acknowledged)
    }

    func publish(_ event: GatewayEvent) {
        eventContinuations.values.forEach { $0.yield(event) }
    }

    func completeSnapshotLoads() {
        snapshotContinuations.forEach { $0.resume(returning: snapshot) }
        snapshotContinuations.removeAll()
    }

    func failSnapshotLoads() {
        snapshotContinuations.forEach { $0.resume(throwing: AppModelTestError.gatewayUnavailable) }
        snapshotContinuations.removeAll()
    }

    func activeSubscriptionCount() -> Int {
        eventContinuations.count
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }
}

private actor CooperativeStartGateway: TextOnlyTestGateway {
    private let snapshot: MessagingSnapshot
    private var snapshotContinuations: [
        UUID: CheckedContinuation<MessagingSnapshot, any Error>
    ] = [:]
    private var eventContinuations: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private(set) var snapshotLoadCount = 0
    private(set) var snapshotCancellationCount = 0

    init(snapshot: MessagingSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot() async throws -> MessagingSnapshot {
        snapshotLoadCount += 1
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                snapshotContinuations[id] = $0
            }
        } onCancel: {
            Task { await self.cancelSnapshotLoad(id) }
        }
    }

    func events() async -> AsyncStream<GatewayEvent> {
        let id = UUID()
        let pair = AsyncStream<GatewayEvent>.makeStream()
        eventContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return pair.stream
    }

    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt {
        SendReceipt(messageID: UUID().uuidString, route: route, deliveryState: .acknowledged)
    }

    func publish(_ event: GatewayEvent) {
        eventContinuations.values.forEach { $0.yield(event) }
    }

    func completeSnapshotLoads() {
        let continuations = Array(snapshotContinuations.values)
        snapshotContinuations.removeAll()
        continuations.forEach { $0.resume(returning: snapshot) }
    }

    func pendingSnapshotLoadCount() -> Int {
        snapshotContinuations.count
    }

    func activeSubscriptionCount() -> Int {
        eventContinuations.count
    }

    private func cancelSnapshotLoad(_ id: UUID) {
        guard let continuation = snapshotContinuations.removeValue(forKey: id) else { return }
        snapshotCancellationCount += 1
        continuation.resume(throwing: CancellationError())
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }
}

private enum RecordedStartResult: Equatable, Sendable {
    case succeeded
    case cancelled
    case otherFailure
}

private actor StartResultRecorder {
    private var results: [String: RecordedStartResult] = [:]

    func record(_ result: RecordedStartResult, for caller: String) {
        results[caller] = result
    }

    func result(for caller: String) -> RecordedStartResult? {
        results[caller]
    }

    func count() -> Int {
        results.count
    }
}

private enum AppModelTestError: LocalizedError {
    case gatewayUnavailable

    var errorDescription: String? { "Fixture gateway unavailable" }
}

@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

@MainActor
private func startAndRecord(
    _ model: InboxPlusAppModel,
    caller: String,
    recorder: StartResultRecorder
) async {
    do {
        try await model.start()
        await recorder.record(.succeeded, for: caller)
    } catch is CancellationError {
        await recorder.record(.cancelled, for: caller)
    } catch {
        await recorder.record(.otherFailure, for: caller)
    }
}

@MainActor
@Test func linkedPersonOpensSummaryBeforeConversation() async throws {
    let gateway = InMemoryMessagingGateway(seed: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()

    let person = try #require(model.inboxItems.first { $0.id == .person("maya") })
    model.selectInboxItem(person)
    #expect(model.detailSelection == .personSummary("maya"))
}

@MainActor
@Test func sendingUsesOnlyTheExplicitlyOpenedRoute() async throws {
    let gateway = InMemoryMessagingGateway(seed: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    let instagram = ConversationRoute(accountID: "instagram-primary", conversationID: "maya-instagram")
    let whatsApp = ConversationRoute(accountID: "whatsapp-primary", conversationID: "maya-whatsapp")
    let whatsAppCountBefore = (try await gateway.loadSnapshot()).messagesByRoute[whatsApp]?.count

    model.openConversation(instagram)
    model.draft = "Sent through Instagram"
    try await model.sendDraft(model.captureDraft(to: instagram))

    #expect(model.openRoute == instagram)
    let snapshot = try await gateway.loadSnapshot()
    #expect(snapshot.messagesByRoute[instagram]?.last?.body == "Sent through Instagram")
    #expect(snapshot.messagesByRoute[whatsApp]?.count == whatsAppCountBefore)
}

@MainActor
@Test func inFlightSendKeepsCapturedRouteAndPreservesANewerDraft() async throws {
    let gateway = ControlledSendGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    let submittedRoute = Fixtures.instagramRoute
    let newerRoute = Fixtures.whatsAppRoute
    model.openConversation(submittedRoute)
    model.draft = "  route A draft  "
    let submission = model.captureDraft(to: submittedRoute)

    let sendTask = Task { @MainActor in
        try await model.sendDraft(submission)
    }
    let sendStarted = await eventually {
        await gateway.submission != nil
    }
    #expect(sendStarted)

    model.openConversation(newerRoute)
    model.draft = "route B newer draft"
    await gateway.completeSend()
    try await sendTask.value

    #expect(
        await gateway.submission
            == ControlledSendGateway.Submission(body: "route A draft", route: submittedRoute)
    )
    #expect(model.openRoute == newerRoute)
    #expect(model.draft == "route B newer draft")
}

@MainActor
@Test func inFlightSendDoesNotClearAReenteredSameTextDraft() async throws {
    let gateway = ControlledSendGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    model.draft = "same text"
    let submission = model.captureDraft(to: Fixtures.instagramRoute)

    let sendTask = Task { @MainActor in
        try await model.sendDraft(submission)
    }
    let sendStarted = await eventually {
        await gateway.submission != nil
    }
    #expect(sendStarted)

    model.draft = "intermediate edit"
    model.draft = "same text"
    await gateway.completeSend()
    try await sendTask.value

    #expect(model.draft == "same text")
}

@MainActor
@Test func sendFailureIsScopedToItsRouteAndSuccessfulRetryClearsIt() async throws {
    let gateway = RetrySendGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    let route = Fixtures.instagramRoute
    model.openConversation(route)
    model.draft = "retry this message"

    let failedSubmission = model.captureDraft(to: route)
    do {
        try await model.sendDraft(failedSubmission)
        Issue.record("Expected the fixture send to fail")
    } catch {
        model.reportSendFailure(error, for: failedSubmission)
    }

    #expect(model.sendFailure(for: route) == "Fixture gateway unavailable")
    #expect(model.sendFailure(for: Fixtures.whatsAppRoute) == nil)
    #expect(model.draft == "retry this message")

    await gateway.allowSends()
    try await model.sendDraft(model.captureDraft(to: route))

    #expect(model.sendFailure(for: route) == nil)
    #expect(model.draft.isEmpty)
}

@MainActor
@Test func olderSuccessCannotClearANewerFailureOrDraftOnTheSameRoute() async throws {
    let gateway = OrderedSendGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    let route = Fixtures.instagramRoute

    model.draft = "submission A"
    let older = model.captureDraft(to: route)
    let olderTask = Task { @MainActor in
        try await model.sendDraft(older)
    }

    model.draft = "submission B"
    let newer = model.captureDraft(to: route)
    let newerTask = Task { @MainActor in
        do {
            try await model.sendDraft(newer)
        } catch {
            model.reportSendFailure(error, for: newer)
        }
    }
    let bothStarted = await eventually { await gateway.pendingSendCount() == 2 }
    #expect(bothStarted)

    await gateway.fail("submission B")
    await newerTask.value
    #expect(model.sendFailure(for: route) == "Fixture gateway unavailable")
    #expect(model.draft == "submission B")

    await gateway.succeed("submission A")
    try await olderTask.value

    #expect(model.sendFailure(for: route) == "Fixture gateway unavailable")
    #expect(model.draft == "submission B")
}

@MainActor
@Test func olderFailureCannotReplaceANewerSuccessOnTheSameRoute() async throws {
    let gateway = OrderedSendGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    let route = Fixtures.instagramRoute

    model.draft = "submission A"
    let older = model.captureDraft(to: route)
    let olderTask = Task { @MainActor in
        do {
            try await model.sendDraft(older)
        } catch {
            model.reportSendFailure(error, for: older)
        }
    }

    model.draft = "submission B"
    let newer = model.captureDraft(to: route)
    let newerTask = Task { @MainActor in
        try await model.sendDraft(newer)
    }
    let bothStarted = await eventually { await gateway.pendingSendCount() == 2 }
    #expect(bothStarted)

    await gateway.succeed("submission B")
    try await newerTask.value
    #expect(model.sendFailure(for: route) == nil)
    #expect(model.draft.isEmpty)

    await gateway.fail("submission A")
    await olderTask.value

    #expect(model.sendFailure(for: route) == nil)
    #expect(model.draft.isEmpty)
}

@MainActor
@Test func userCanExplicitlyLinkAnOpenStandaloneConversation() async throws {
    let model = InboxPlusAppModel(gateway: InMemoryMessagingGateway(seed: Fixtures.snapshot), directory: Fixtures.directory)
    try await model.start()
    model.openConversation(Fixtures.telegramRoute)

    let personID = try model.createPersonAndLinkOpenConversation(displayName: "Family")

    #expect(model.detailSelection == .personSummary(personID))
    #expect(model.inboxItems.first { $0.id == .person(personID) }?.conversationSummaries.map(\.route) == [Fixtures.telegramRoute])
}

@MainActor
@Test func startRejectsMultipleAccountsForTheSamePlatform() async throws {
    let duplicateAccountSnapshot = MessagingSnapshot(
        accounts: [
            ConnectedAccount(id: "whatsapp-one", platform: .whatsApp, displayName: "One"),
            ConnectedAccount(id: "whatsapp-two", platform: .whatsApp, displayName: "Two"),
        ],
        identities: [],
        conversations: [],
        messagesByRoute: [:]
    )
    let model = InboxPlusAppModel(gateway: InMemoryMessagingGateway(seed: duplicateAccountSnapshot))

    await #expect(throws: AccountPolicyError.duplicatePlatform(.whatsApp)) {
        try await model.start()
    }
}

@MainActor
@Test func failedCreateAndLinkDoesNotLeaveAnUnlinkedPerson() async throws {
    let model = InboxPlusAppModel(gateway: InMemoryMessagingGateway(seed: Fixtures.snapshot), directory: Fixtures.directory)
    try await model.start()
    model.openConversation(Fixtures.instagramRoute)
    let peopleBefore = model.people

    #expect(throws: ContactDirectoryError.identityAlreadyLinked) {
        try model.createPersonAndLinkOpenConversation(displayName: "Duplicate Maya")
    }

    #expect(model.people == peopleBefore)
    #expect(model.detailSelection == .conversation(Fixtures.instagramRoute))
}

@MainActor
@Test func createAndLinkWithoutAnOpenConversationIsAtomic() async throws {
    let model = InboxPlusAppModel(gateway: InMemoryMessagingGateway(seed: Fixtures.snapshot), directory: Fixtures.directory)
    try await model.start()
    let peopleBefore = model.people

    #expect(throws: InboxPlusAppModelError.missingOpenConversation) {
        try model.createPersonAndLinkOpenConversation(displayName: "Orphan")
    }

    #expect(model.people == peopleBefore)
    #expect(model.detailSelection == .empty)
}

@MainActor
@Test func messageUpsertReplacesMatchingRouteAndIDWithoutDuplication() async throws {
    let gateway = AppModelTestGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    let original = try #require(model.messagesByRoute[Fixtures.instagramRoute]?.first)
    let deliveryUpdate = Message(
        id: original.id,
        route: original.route,
        senderIdentityID: original.senderIdentityID,
        body: original.body,
        timestamp: original.timestamp,
        deliveryState: .failed("offline")
    )

    await gateway.publish(.messageUpserted(deliveryUpdate))

    let updateApplied = await eventually {
        model.messagesByRoute[Fixtures.instagramRoute]?.first?.deliveryState == .failed("offline")
    }
    #expect(updateApplied)
    #expect(model.messagesByRoute[Fixtures.instagramRoute]?.count == 1)
}

@MainActor
@Test func newerOutgoingMessageRefreshesOnlyItsConversationAndReordersInbox() async throws {
    let gateway = AppModelTestGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    let originalInstagram = try #require(
        model.conversations.first { $0.route == Fixtures.instagramRoute }
    )
    let originalTelegramUnread = try #require(
        model.conversations.first { $0.route == Fixtures.telegramRoute }?.unreadCount
    )
    let sentAt = Date(timeIntervalSince1970: 400)
    let outgoing = Message(
        id: "telegram-outgoing",
        route: Fixtures.telegramRoute,
        senderIdentityID: nil,
        body: "Newest exact-route reply",
        timestamp: sentAt,
        deliveryState: .acknowledged
    )

    await gateway.publish(.messageUpserted(outgoing))
    let eventApplied = await eventually {
        model.messagesByRoute[Fixtures.telegramRoute]?.contains { $0.id == outgoing.id } == true
    }
    let telegram = try #require(
        model.conversations.first { $0.route == Fixtures.telegramRoute }
    )
    let telegramSummary = try #require(
        model.inboxItems
            .flatMap(\.conversationSummaries)
            .first { $0.route == Fixtures.telegramRoute }
    )

    #expect(eventApplied)
    #expect(telegram.latestPreview == "Newest exact-route reply")
    #expect(telegram.latestActivity == sentAt)
    #expect(telegram.unreadCount == originalTelegramUnread)
    #expect(model.conversations.first { $0.route == Fixtures.instagramRoute } == originalInstagram)
    #expect(telegramSummary.latestPreview == "Newest exact-route reply")
    #expect(telegramSummary.latestActivity == sentAt)
    #expect(model.inboxItems.first?.id == .conversation(Fixtures.telegramRoute))
}

@MainActor
@Test func olderMessageAndDeliveryUpdateDoNotRegressConversationProjection() async throws {
    let gateway = AppModelTestGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    let newest = Message(
        id: "telegram-newest",
        route: Fixtures.telegramRoute,
        senderIdentityID: nil,
        body: "Keep this preview",
        timestamp: Date(timeIntervalSince1970: 400),
        deliveryState: .pending
    )
    let deliveryUpdate = Message(
        id: newest.id,
        route: newest.route,
        senderIdentityID: newest.senderIdentityID,
        body: newest.body,
        timestamp: newest.timestamp,
        deliveryState: .acknowledged
    )
    let older = Message(
        id: "telegram-older",
        route: Fixtures.telegramRoute,
        senderIdentityID: nil,
        body: "Do not regress to this preview",
        timestamp: Date(timeIntervalSince1970: 50),
        deliveryState: .acknowledged
    )

    await gateway.publish(.messageUpserted(newest))
    await gateway.publish(.messageUpserted(deliveryUpdate))
    await gateway.publish(.messageUpserted(older))
    let eventsApplied = await eventually {
        let messages = model.messagesByRoute[Fixtures.telegramRoute] ?? []
        return messages.contains { $0.id == older.id }
            && messages.first { $0.id == newest.id }?.deliveryState == .acknowledged
    }
    let telegram = try #require(
        model.conversations.first { $0.route == Fixtures.telegramRoute }
    )

    #expect(eventsApplied)
    #expect(telegram.latestPreview == "Keep this preview")
    #expect(telegram.latestActivity == Date(timeIntervalSince1970: 400))
    #expect(telegram.unreadCount == 0)
    #expect(model.inboxItems.first?.id == .conversation(Fixtures.telegramRoute))
}

@MainActor
@Test func healthRemainsUnhealthyUntilEveryDisconnectedAccountReconnects() async throws {
    let gateway = AppModelTestGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()

    await gateway.publish(.connectionChanged(accountID: "whatsapp-primary", isConnected: false))
    await gateway.publish(.connectionChanged(accountID: "instagram-primary", isConnected: false))
    await gateway.publish(.connectionChanged(accountID: "whatsapp-primary", isConnected: true))
    let reconnectBarrier = RemoteConversation(
        id: "reconnect-barrier",
        accountID: "telegram-primary",
        identityID: "family-telegram-identity",
        title: "Reconnect Barrier",
        latestActivity: .distantFuture,
        unreadCount: 0
    )
    await gateway.publish(.conversationUpserted(reconnectBarrier))

    let reconnectBarrierApplied = await eventually {
        model.conversations.contains { $0.route == reconnectBarrier.route }
    }
    #expect(reconnectBarrierApplied)
    #expect(model.health != .healthy)

    await gateway.publish(.connectionChanged(accountID: "instagram-primary", isConnected: true))

    let allAccountsReconnected = await eventually { model.health == .healthy }
    #expect(allAccountsReconnected)
}

@MainActor
@Test func connectionEventsForUnknownAccountsDoNotChangeHealth() async throws {
    let gateway = AppModelTestGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    let barrierConversation = RemoteConversation(
        id: "barrier",
        accountID: "telegram-primary",
        identityID: "family-telegram-identity",
        title: "Barrier",
        latestActivity: .distantFuture,
        unreadCount: 0
    )

    await gateway.publish(.connectionChanged(accountID: "unknown-account", isConnected: false))
    await gateway.publish(.conversationUpserted(barrierConversation))

    let barrierApplied = await eventually {
        model.conversations.contains { $0.route == barrierConversation.route }
    }
    #expect(barrierApplied)
    #expect(model.health == .healthy)
}

@MainActor
@Test func repeatedStartLeavesExactlyOneActiveEventSubscription() async throws {
    let gateway = AppModelTestGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    let firstSubscriptionStarted = await eventually {
        await gateway.activeSubscriptionCount() == 1
    }
    #expect(firstSubscriptionStarted)

    try await model.start()

    let oldSubscriptionCancelled = await eventually {
        await gateway.activeSubscriptionCount() == 1
    }
    #expect(oldSubscriptionCancelled)
}

@MainActor
@Test func concurrentStartCallsShareOneGaplessSubscription() async throws {
    let gateway = ControlledStartGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)

    let firstStart = Task { @MainActor in try await model.start() }
    let secondStart = Task { @MainActor in try await model.start() }
    let subscribedBeforeSnapshotCompletes = await eventually {
        let subscriptions = await gateway.activeSubscriptionCount()
        let loads = await gateway.snapshotLoadCount
        return subscriptions == 1 && loads == 1
    }
    let snapshotLoadCount = await gateway.snapshotLoadCount
    await gateway.completeSnapshotLoads()
    try await firstStart.value
    try await secondStart.value

    #expect(subscribedBeforeSnapshotCompletes)
    #expect(snapshotLoadCount == 1)
    #expect(await gateway.activeSubscriptionCount() == 1)
}

@MainActor
@Test func cancellingAConcurrentStartCallerDoesNotCancelTheSharedLeader() async throws {
    let gateway = CooperativeStartGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    let recorder = StartResultRecorder()
    let leader = Task { @MainActor in
        await startAndRecord(model, caller: "leader", recorder: recorder)
    }
    let leaderIsSuspended = await eventually {
        let loads = await gateway.snapshotLoadCount
        let subscriptions = await gateway.activeSubscriptionCount()
        return loads == 1 && subscriptions == 1
    }
    #expect(leaderIsSuspended)

    let waiter = Task { @MainActor in
        await startAndRecord(model, caller: "waiter", recorder: recorder)
    }
    for _ in 0..<20 { await Task.yield() }
    waiter.cancel()

    let waiterCancelledPromptly = await eventually {
        await recorder.result(for: "waiter") == .cancelled
    }
    #expect(waiterCancelledPromptly)
    #expect(await recorder.result(for: "leader") == nil)
    #expect(await gateway.snapshotCancellationCount == 0)
    #expect(await gateway.activeSubscriptionCount() == 1)

    await gateway.completeSnapshotLoads()
    await leader.value
    await waiter.value

    #expect(await recorder.result(for: "leader") == .succeeded)
    #expect(await gateway.activeSubscriptionCount() == 1)
}

@MainActor
@Test func stopCancelsSuspendedStartupAndAllStartCallersPromptly() async {
    let gateway = CooperativeStartGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    let recorder = StartResultRecorder()
    let leader = Task { @MainActor in
        await startAndRecord(model, caller: "leader", recorder: recorder)
    }
    let waiter = Task { @MainActor in
        await startAndRecord(model, caller: "waiter", recorder: recorder)
    }
    let startupIsSuspended = await eventually {
        let loads = await gateway.snapshotLoadCount
        let subscriptions = await gateway.activeSubscriptionCount()
        return loads == 1 && subscriptions == 1
    }
    #expect(startupIsSuspended)
    for _ in 0..<20 { await Task.yield() }

    model.stop()

    let allCallersCancelledPromptly = await eventually {
        await recorder.count() == 2
    }
    let subscriptionCancelled = await eventually {
        await gateway.activeSubscriptionCount() == 0
    }
    let snapshotLoadCancelled = await eventually {
        let cancellations = await gateway.snapshotCancellationCount
        let pendingLoads = await gateway.pendingSnapshotLoadCount()
        return cancellations == 1 && pendingLoads == 0
    }

    if !allCallersCancelledPromptly {
        await gateway.completeSnapshotLoads()
    }
    await leader.value
    await waiter.value

    #expect(allCallersCancelledPromptly)
    #expect(subscriptionCancelled)
    #expect(snapshotLoadCancelled)
    #expect(await recorder.result(for: "leader") == .cancelled)
    #expect(await recorder.result(for: "waiter") == .cancelled)
}

@MainActor
@Test func restartAfterCancelledStartupOwnsOneGaplessSubscription() async {
    let gateway = CooperativeStartGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    let recorder = StartResultRecorder()
    let cancelledStart = Task { @MainActor in
        await startAndRecord(model, caller: "cancelled", recorder: recorder)
    }
    let firstLoadStarted = await eventually {
        let loads = await gateway.snapshotLoadCount
        let subscriptions = await gateway.activeSubscriptionCount()
        return loads == 1 && subscriptions == 1
    }
    #expect(firstLoadStarted)
    model.stop()
    let firstStartCancelled = await eventually {
        await recorder.result(for: "cancelled") == .cancelled
    }
    #expect(firstStartCancelled)

    let restarted = Task { @MainActor in
        await startAndRecord(model, caller: "restarted", recorder: recorder)
    }
    let restartIsGapless = await eventually {
        let loads = await gateway.snapshotLoadCount
        let pendingLoads = await gateway.pendingSnapshotLoadCount()
        let subscriptions = await gateway.activeSubscriptionCount()
        return loads == 2 && pendingLoads == 1 && subscriptions == 1
    }
    let eventConversation = RemoteConversation(
        id: "after-cancelled-start",
        accountID: "telegram-primary",
        identityID: "family-telegram-identity",
        title: "After Cancelled Start",
        latestActivity: .distantFuture,
        unreadCount: 0
    )
    await gateway.publish(.conversationUpserted(eventConversation))
    await gateway.completeSnapshotLoads()
    await cancelledStart.value
    await restarted.value

    #expect(restartIsGapless)
    #expect(await recorder.result(for: "restarted") == .succeeded)
    #expect(model.conversations.contains { $0.route == eventConversation.route })
    #expect(await gateway.activeSubscriptionCount() == 1)
}

@MainActor
@Test func eventPublishedDuringSnapshotLoadIsAppliedAfterTheSnapshot() async throws {
    let gateway = ControlledStartGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    let eventConversation = RemoteConversation(
        id: "during-start",
        accountID: "telegram-primary",
        identityID: "family-telegram-identity",
        title: "During Start",
        latestPreview: "arrived while loading",
        latestActivity: .distantFuture,
        unreadCount: 0
    )

    let startTask = Task { @MainActor in try await model.start() }
    let subscribedBeforeSnapshotCompletes = await eventually {
        let subscriptions = await gateway.activeSubscriptionCount()
        let loads = await gateway.snapshotLoadCount
        return subscriptions == 1 && loads == 1
    }
    await gateway.publish(.conversationUpserted(eventConversation))
    await gateway.completeSnapshotLoads()
    try await startTask.value

    #expect(subscribedBeforeSnapshotCompletes)
    #expect(model.conversations.contains { $0.route == eventConversation.route })
    #expect(model.inboxItems.first?.latestActivity == .distantFuture)
}

@MainActor
@Test func startupFailureCancelsItsOwnedEventSubscription() async {
    let gateway = ControlledStartGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)

    let startTask = Task { @MainActor in try await model.start() }
    let subscribedBeforeFailure = await eventually {
        let subscriptions = await gateway.activeSubscriptionCount()
        let loads = await gateway.snapshotLoadCount
        return subscriptions == 1 && loads == 1
    }
    await gateway.failSnapshotLoads()

    await #expect(throws: AppModelTestError.gatewayUnavailable) {
        try await startTask.value
    }
    let subscriptionCancelled = await eventually {
        await gateway.activeSubscriptionCount() == 0
    }
    #expect(subscribedBeforeFailure)
    #expect(subscriptionCancelled)
}

@MainActor
@Test func stopCancelsTheActiveEventSubscription() async throws {
    let gateway = AppModelTestGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    let subscriptionStarted = await eventually {
        await gateway.activeSubscriptionCount() == 1
    }
    #expect(subscriptionStarted)

    model.stop()

    let subscriptionCancelled = await eventually {
        await gateway.activeSubscriptionCount() == 0
    }
    #expect(subscriptionCancelled)
}

@MainActor
@Test func startAfterStopCreatesAFreshWorkingSubscription() async throws {
    let gateway = AppModelTestGateway(snapshot: Fixtures.snapshot)
    let model = InboxPlusAppModel(gateway: gateway, directory: Fixtures.directory)
    try await model.start()
    model.stop()
    let firstSubscriptionCancelled = await eventually {
        await gateway.activeSubscriptionCount() == 0
    }
    #expect(firstSubscriptionCancelled)

    try await model.start()
    let restartedSubscription = await eventually {
        await gateway.activeSubscriptionCount() == 1
    }
    let eventConversation = RemoteConversation(
        id: "after-restart",
        accountID: "telegram-primary",
        identityID: "family-telegram-identity",
        title: "After Restart",
        latestActivity: .distantFuture,
        unreadCount: 0
    )
    await gateway.publish(.conversationUpserted(eventConversation))
    let eventApplied = await eventually {
        model.conversations.contains { $0.route == eventConversation.route }
    }

    #expect(restartedSubscription)
    #expect(eventApplied)
}

@MainActor
@Test func healthTitleIsQuietWhenHealthyAndActionableWhenDisconnected() async throws {
    let model = InboxPlusAppModel(gateway: InMemoryMessagingGateway(seed: Fixtures.snapshot), directory: Fixtures.directory)
    try await model.start()
    #expect(model.health.menuBarTitle == "Inbox+ is running")
    #expect(ServiceHealth.needsAttention("Reconnect Instagram").menuBarTitle == "Inbox+ needs attention")
}

@Test func healthSymbolReflectsLifecycleState() {
    #expect(ServiceHealth.starting.symbolName == "ellipsis.circle")
    #expect(ServiceHealth.healthy.symbolName == "checkmark.circle.fill")
    #expect(ServiceHealth.needsAttention("Reconnect Instagram").symbolName == "exclamationmark.triangle.fill")
}

@MainActor
@Test func reportingStartupFailureMakesHealthActionable() {
    let model = InboxPlusAppModel(gateway: InMemoryMessagingGateway(seed: Fixtures.snapshot))

    model.reportStartupFailure(AppModelTestError.gatewayUnavailable)

    #expect(model.health == .needsAttention("Inbox+ could not start: Fixture gateway unavailable"))
}
