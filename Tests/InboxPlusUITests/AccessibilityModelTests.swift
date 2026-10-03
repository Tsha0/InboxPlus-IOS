import Testing
@testable import InboxPlusCore
@testable import InboxPlusFeatures
@testable import InboxPlusUI

@Test func platformBadgeDescriptorAlwaysNamesTheNetwork() {
    for platform in Platform.allCases {
        let descriptor = PlatformBadgeDescriptor(platform: platform)
        #expect(descriptor.accessibilityLabel == platform.accessibilityLabel)
        #expect(!descriptor.symbolName.isEmpty)
    }
}

@Test func linkedContactCardDescriptorRetainsExactRoute() {
    let route = ConversationRoute(accountID: "wa", conversationID: "chat")
    let descriptor = ContactConversationCardDescriptor(
        route: route,
        platform: .whatsApp,
        title: "Latest message",
        preview: "Hello",
        timestampDescription: "12 Aug 2026 at 10:15 PM",
        unreadCount: 0
    )
    #expect(descriptor.route == route)
    #expect(descriptor.accessibilityLabel.contains("WhatsApp"))
}

@Test func linkedContactCardDescriptorNamesCompleteAccessibleState() {
    let route = ConversationRoute(accountID: "wa", conversationID: "chat")
    let unread = ContactConversationCardDescriptor(
        route: route,
        platform: .whatsApp,
        title: "Latest message",
        preview: "Hello",
        timestampDescription: "12 Aug 2026 at 10:15 PM",
        unreadCount: 2
    )
    let read = ContactConversationCardDescriptor(
        route: route,
        platform: .whatsApp,
        title: "Latest message",
        preview: "Hello",
        timestampDescription: "12 Aug 2026 at 10:15 PM",
        unreadCount: 0
    )

    #expect(unread.route == route)
    #expect(
        unread.accessibilityLabel
            == "WhatsApp, Latest message, Hello, 12 Aug 2026 at 10:15 PM, 2 unread"
    )
    #expect(
        read.accessibilityLabel
            == "WhatsApp, Latest message, Hello, 12 Aug 2026 at 10:15 PM, Read"
    )
}

@Test func inboxAccessibilityIdentifiersAreStable() {
    #expect(InboxItem.ID.person("maya").accessibilityIdentifier == "person-maya")
    let route = ConversationRoute(accountID: "wa", conversationID: "chat")
    #expect(InboxItem.ID.conversation(route).accessibilityIdentifier == "conversation-wa-chat")
}

@Test func sendFailureDescriptorExposesRouteScopedAccessibleState() {
    let route = ConversationRoute(accountID: "instagram-primary", conversationID: "maya-instagram")
    let descriptor = ConversationSendFailureDescriptor(
        route: route,
        message: "Fixture gateway unavailable"
    )

    #expect(descriptor.message == "Fixture gateway unavailable")
    #expect(descriptor.accessibilityLabel == "Message could not be sent: Fixture gateway unavailable")
    #expect(descriptor.accessibilityIdentifier == "send-error-instagram-primary-maya-instagram")
}
