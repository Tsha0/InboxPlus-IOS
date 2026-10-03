import Testing
import MatrixRustSDK
@testable import InboxPlusMatrix

@Test func conversationMetadataDoesNotBecomeChatHistory() {
    let normalizer = MatrixEventNormalizer(accountID: "bridge")
    let updates: [OtherState] = [
        .roomAvatar(url: "mxc://example/avatar"),
        .roomName(name: "Friends"),
        .roomTopic(topic: "Weekend"),
        .roomEncryption,
        .custom(eventType: "com.example.bridge.settings")
    ]
    for update in updates {
        #expect(normalizer.describe(.state(stateKey: "", content: update), identifier: "event") == nil)
    }
    #expect(normalizer.describe(
        .failedToParseState(eventType: "com.example.settings", stateKey: "", error: "unknown"),
        identifier: "event"
    ) == nil)
}

@Test func unsupportedMessagesRemainVisible() throws {
    let normalizer = MatrixEventNormalizer(accountID: "bridge")
    let message = try #require(normalizer.describe(
        .failedToParseMessageLike(eventType: "com.example.message", error: "unknown"),
        identifier: "event"
    ))
    #expect(message.body == "Unsupported message (com.example.message)")
    #expect(message.kind == .unsupported)
}
