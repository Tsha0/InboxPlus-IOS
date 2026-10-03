import Testing
@testable import InboxPlusCore
@testable import InboxPlusGateway
@testable import InboxPlusFeatures

private struct FailingGateway: TextOnlyTestGateway {
    struct Failure: Error {}

    func loadSnapshot() async throws -> MessagingSnapshot { throw Failure() }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt { throw Failure() }
}

@MainActor
@Test func startupFailureBecomesVisibleHealthState() async {
    let model = InboxPlusAppModel(gateway: FailingGateway())
    do { try await model.start() } catch { model.reportStartupFailure(error) }
    guard case let .needsAttention(message) = model.health else {
        Issue.record("Expected needs-attention health")
        return
    }
    #expect(message.hasPrefix("Inbox+ could not start:"))
    #expect(model.healthBannerMessage?.hasPrefix("Inbox+ could not start:") == true)
}
