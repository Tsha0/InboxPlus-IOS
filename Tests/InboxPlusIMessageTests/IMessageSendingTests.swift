import Foundation
import Testing
import InboxPlusCore
import InboxPlusGateway
@testable import InboxPlusIMessage

// MARK: - Timestamps

@Test func messagesOwnClockIsConvertedFromBothUnits() throws {
    // Nanoseconds since 2001, written by macOS 10.13 and later.
    let modern = try #require(AppleTimestamp.date(fromAppleTime: 731_160_000_000_000_000))
    #expect(abs(modern.timeIntervalSince1970 - 1_709_467_200) < 1)

    // Whole seconds, written by older macOS and still present in an upgraded database.
    let legacy = try #require(AppleTimestamp.date(fromAppleTime: 731_160_000))
    #expect(abs(legacy.timeIntervalSince1970 - 1_709_467_200) < 1)
}

@Test func anAbsentTimestampIsNotTurnedIntoTheYear2001() {
    // Returning a date for 0 would file every such message under January 2001.
    #expect(AppleTimestamp.date(fromAppleTime: 0) == nil)
    #expect(AppleTimestamp.date(fromAppleTime: -1) == nil)
}

@Test func timestampsRoundTrip() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let restored = try #require(AppleTimestamp.date(fromAppleTime: AppleTimestamp.appleTime(from: now)))
    #expect(abs(restored.timeIntervalSince1970 - now.timeIntervalSince1970) < 0.001)
}

// MARK: - attributedBody

@Test func aShortBodyIsRecoveredFromTheArchive() throws {
    let data = Data(typedStream(containing: "see you at six"))
    #expect(TypedStreamText.text(fromAttributedBody: data) == "see you at six")
}

@Test func aLongBodyWithATwoByteLengthIsRecovered() throws {
    let long = String(repeating: "a", count: 300)
    let data = Data(typedStream(containing: long))
    #expect(TypedStreamText.text(fromAttributedBody: data) == long)
}

@Test func emojiAndAccentsSurviveIntact() throws {
    let text = "cafe\u{301} ☕️ 👋🏽 — dône"
    #expect(TypedStreamText.text(fromAttributedBody: Data(typedStream(containing: text))) == text)
}

@Test func garbageIsRefusedRatherThanGuessedAt() {
    // Inventing a body is worse than admitting one could not be read.
    #expect(TypedStreamText.text(fromAttributedBody: Data()) == nil)
    #expect(TypedStreamText.text(fromAttributedBody: Data(repeating: 0xFF, count: 64)) == nil)
    #expect(TypedStreamText.text(fromAttributedBody: Data("NSString".utf8)) == nil)
}

@Test func aTruncatedArchiveDoesNotReadPastItsEnd() {
    // A length prefix claiming more bytes than exist must not be honoured.
    var bytes = typedStream(containing: "hello")
    bytes = Array(bytes.dropLast(3))
    #expect(TypedStreamText.text(fromAttributedBody: Data(bytes)) == nil)
}

// MARK: - Sending

@Test func aReplyIsAddressedToTheChatItBelongsTo() throws {
    // Looking a buddy up by handle lets Messages pick a service, which is how a reply silently
    // leaves as green-bubble SMS. Targeting the chat keeps it in the same conversation.
    let script = IMessageSender.script(body: "on my way", chatGUID: "iMessage;-;+15555550123")
    #expect(script.contains("chat id \"iMessage;-;+15555550123\""))
    #expect(script.contains("send \"on my way\""))
    #expect(!script.lowercased().contains("buddy"))
}

@Test(arguments: [
    #"say "hello""#,
    #"back\slash"#,
    "line one\nline two",
    #"" & (do shell script "rm -rf ~") & ""#,
])
func aMessageBodyCanNeverEscapeIntoScriptCode(_ body: String) throws {
    let recorder = ScriptRecorder()
    let sender = IMessageSender { script in recorder.record(script); return "" }
    try sender.send(body, toChatGUID: "iMessage;-;a@b.com")
    let captured = recorder.script

    // Every quote in the script must be either the delimiters we wrote or an escaped one, so a
    // message body cannot close the literal and have the remainder run as AppleScript.
    let afterSend = try #require(captured.range(of: "send \""))
    let payload = captured[afterSend.upperBound...]
    let bare = zip(payload, payload.dropFirst()).filter { $0.1 == "\"" && $0.0 != "\\" }
    // Exactly one unescaped quote closes the body literal.
    #expect(bare.count == 1, "unescaped quote in: \(captured)")
    #expect(!captured.contains("\ndo shell script"))
}

@Test func theGUIDIsEscapedToo() {
    let script = IMessageSender.script(body: "x", chatGUID: #"evil";say "hacked"#)
    #expect(script.contains(##"chat id "evil\";say \"hacked""##))
}

/// Captures the script the sender built, without automating anything.
private final class ScriptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func record(_ script: String) {
        lock.lock(); defer { lock.unlock() }
        value = script
    }

    var script: String {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// MARK: - Composite routing

private actor StubGateway: MessagingGateway {
    let accountID: String
    private(set) var sentBodies: [String] = []

    init(accountID: String) { self.accountID = accountID }

    func loadSnapshot() async throws -> MessagingSnapshot {
        MessagingSnapshot(
            accounts: [ConnectedAccount(id: accountID, platform: .iMessage, displayName: accountID)],
            identities: [],
            conversations: [],
            messagesByRoute: [:]
        )
    }

    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }

    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt {
        sentBodies.append(body)
        return SendReceipt(messageID: "1", route: route, deliveryState: .pending)
    }

    func send(_ attachment: OutgoingAttachment, to route: ConversationRoute) async throws -> SendReceipt {
        SendReceipt(messageID: "1", route: route, deliveryState: .pending)
    }

    func bodies() -> [String] { sentBodies }
}

private struct BrokenGateway: MessagingGateway {
    struct Failure: Error {}
    func loadSnapshot() async throws -> MessagingSnapshot { throw Failure() }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func sendText(_ body: String, to route: ConversationRoute) async throws -> SendReceipt { throw Failure() }
    func send(_ attachment: OutgoingAttachment, to route: ConversationRoute) async throws -> SendReceipt { throw Failure() }
}

@Test func aSendGoesToTheSourceThatOwnsTheAccount() async throws {
    // Sending into whichever gateway happens to be first would deliver a private message to the
    // wrong network.
    let matrix = StubGateway(accountID: "matrix-local")
    let imessage = StubGateway(accountID: "imessage-local")
    let composite = CompositeMessagingGateway([matrix, imessage])
    _ = try await composite.loadSnapshot()

    _ = try await composite.sendText(
        "for iMessage",
        to: ConversationRoute(accountID: "imessage-local", conversationID: "c1")
    )
    #expect(await imessage.bodies() == ["for iMessage"])
    #expect(await matrix.bodies().isEmpty)
}

@Test func anUnknownAccountIsRefusedRatherThanGuessed() async throws {
    let composite = CompositeMessagingGateway([StubGateway(accountID: "matrix-local")])
    _ = try await composite.loadSnapshot()

    await #expect(throws: CompositeGatewayError.unknownAccount("nobody")) {
        try await composite.sendText("x", to: ConversationRoute(accountID: "nobody", conversationID: "c"))
    }
}

@Test func oneBrokenSourceDoesNotEmptyTheInbox() async throws {
    let composite = CompositeMessagingGateway([BrokenGateway(), StubGateway(accountID: "imessage-local")])
    let snapshot = try await composite.loadSnapshot()

    #expect(snapshot.accounts.map(\.id) == ["imessage-local"])
    // The failure is reported rather than swallowed, so the app can say a source is unavailable.
    #expect(await composite.failures.count == 1)
}
