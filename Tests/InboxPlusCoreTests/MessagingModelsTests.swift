import Foundation
import Testing
@testable import InboxPlusCore

@Test func everyPlatformHasAccessibleIconMetadata() {
    for platform in Platform.allCases {
        #expect(!platform.accessibilityLabel.isEmpty)
        #expect(!platform.symbolName.isEmpty)
    }
}

@Test func conversationRouteIncludesAccountAndRemoteID() {
    let account = ConnectedAccount(id: "whatsapp-primary", platform: .whatsApp, displayName: "Personal")
    let identity = RemoteIdentity(id: "maya-wa", accountID: account.id, displayName: "Maya")
    let conversation = RemoteConversation(
        id: "wa-chat-42",
        accountID: account.id,
        identityID: identity.id,
        title: "Maya",
        latestActivity: Date(timeIntervalSince1970: 10),
        unreadCount: 2
    )

    #expect(conversation.route == ConversationRoute(accountID: "whatsapp-primary", conversationID: "wa-chat-42"))
}

@Test func personLinkContainsOnlyExplicitRemoteIdentities() {
    let link = PersonLink(personID: "maya", remoteIdentityIDs: ["maya-wa", "maya-ig"])
    #expect(link.remoteIdentityIDs == ["maya-wa", "maya-ig"])
}

@Test func accountPolicyRejectsTwoAccountsForOnePlatform() {
    let accounts = [
        ConnectedAccount(id: "wa-1", platform: .whatsApp, displayName: "One"),
        ConnectedAccount(id: "wa-2", platform: .whatsApp, displayName: "Two")
    ]
    #expect(throws: AccountPolicyError.duplicatePlatform(.whatsApp)) {
        try AccountPolicy.validate(accounts)
    }
}
