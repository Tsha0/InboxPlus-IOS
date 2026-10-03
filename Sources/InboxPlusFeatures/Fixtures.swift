import Foundation
import InboxPlusCore
import InboxPlusGateway

public enum Fixtures {
    public static let whatsAppRoute = ConversationRoute(accountID: "whatsapp-primary", conversationID: "maya-whatsapp")
    public static let instagramRoute = ConversationRoute(accountID: "instagram-primary", conversationID: "maya-instagram")
    public static let telegramRoute = ConversationRoute(accountID: "telegram-primary", conversationID: "family-telegram")

    /// Fixed timestamps so tests can reason about ordering against absolute dates.
    public static let snapshot = makeSnapshot(
        familyActivity: Date(timeIntervalSince1970: 100),
        whatsAppActivity: Date(timeIntervalSince1970: 200),
        instagramActivity: Date(timeIntervalSince1970: 300)
    )

    /// The same fixtures anchored to launch time, so the running app shows plausible
    /// relative dates instead of "56 years ago", plus enough history to scroll.
    public static var demoSnapshot: MessagingSnapshot {
        let now = Date()
        return makeSnapshot(
            familyActivity: now.addingTimeInterval(-3 * 60 * 60),
            whatsAppActivity: now.addingTimeInterval(-42 * 60),
            instagramActivity: now.addingTimeInterval(-6 * 60),
            includeHistory: true
        )
    }

    public static var directory: ContactDirectory {
        var value = ContactDirectory()
        try! value.createPerson(id: "maya", displayName: "Maya")
        try! value.link(remoteIdentityID: "maya-whatsapp-identity", to: "maya")
        try! value.link(remoteIdentityID: "maya-instagram-identity", to: "maya")
        return value
    }

    static func makeSnapshot(
        familyActivity: Date,
        whatsAppActivity: Date,
        instagramActivity: Date,
        includeHistory: Bool = false
    ) -> MessagingSnapshot {
        MessagingSnapshot(
            accounts: [
                .init(id: "whatsapp-primary", platform: .whatsApp, displayName: "Personal"),
                .init(id: "instagram-primary", platform: .instagram, displayName: "Personal"),
                .init(id: "telegram-primary", platform: .telegram, displayName: "Personal"),
            ],
            identities: [
                .init(id: "maya-whatsapp-identity", accountID: "whatsapp-primary", displayName: "Maya"),
                .init(id: "maya-instagram-identity", accountID: "instagram-primary", displayName: "@maya"),
                .init(id: "family-telegram-identity", accountID: "telegram-primary", displayName: "Family"),
            ],
            conversations: [
                .init(id: "maya-whatsapp", accountID: "whatsapp-primary", identityID: "maya-whatsapp-identity", title: "Maya", latestPreview: "Are we still meeting tonight?", latestActivity: whatsAppActivity, unreadCount: 1),
                .init(id: "maya-instagram", accountID: "instagram-primary", identityID: "maya-instagram-identity", title: "@maya", latestPreview: "I sent the address here.", latestActivity: instagramActivity, unreadCount: 2),
                .init(id: "family-telegram", accountID: "telegram-primary", identityID: "family-telegram-identity", title: "Family", latestPreview: "Dinner this weekend?", latestActivity: familyActivity, unreadCount: 0),
            ],
            messagesByRoute: [
                whatsAppRoute: history(
                    includeHistory,
                    [
                        ("wa-0", "maya-whatsapp-identity", "Hey! Long time.", -90 * 60),
                        ("wa-0b", nil, "I know — how have you been?", -70 * 60),
                    ],
                    latest: .init(id: "wa-1", route: whatsAppRoute, senderIdentityID: "maya-whatsapp-identity", body: "Are we still meeting tonight?", timestamp: whatsAppActivity, deliveryState: .acknowledged),
                    anchor: whatsAppActivity
                ),
                instagramRoute: history(
                    includeHistory,
                    [
                        ("ig-0", nil, "Can you send the address?", -20 * 60),
                    ],
                    latest: .init(id: "ig-1", route: instagramRoute, senderIdentityID: "maya-instagram-identity", body: "I sent the address here.", timestamp: instagramActivity, deliveryState: .acknowledged),
                    anchor: instagramActivity
                ),
                telegramRoute: history(
                    includeHistory,
                    [
                        ("tg-0", "family-telegram-identity", "Everyone free Saturday?", -30 * 60),
                    ],
                    latest: .init(id: "tg-1", route: telegramRoute, senderIdentityID: "family-telegram-identity", body: "Dinner this weekend?", timestamp: familyActivity, deliveryState: .acknowledged),
                    anchor: familyActivity
                ),
            ]
        )
    }

    private static func history(
        _ include: Bool,
        _ earlier: [(String, String?, String, TimeInterval)],
        latest: Message,
        anchor: Date
    ) -> [Message] {
        guard include else { return [latest] }
        let preceding = earlier.map { id, sender, body, offset in
            Message(
                id: id,
                route: latest.route,
                senderIdentityID: sender,
                body: body,
                timestamp: anchor.addingTimeInterval(offset),
                deliveryState: .acknowledged
            )
        }
        return preceding + [latest]
    }
}
