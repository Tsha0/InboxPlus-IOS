import Foundation
import InboxPlusCore

public struct ConversationSummary: Identifiable, Hashable, Sendable {
    public var id: ConversationRoute { route }
    public let route: ConversationRoute
    public let platform: Platform
    public let title: String
    public let latestPreview: String
    public let latestActivity: Date
    public let unreadCount: Int
    /// What the composer is allowed to offer here.
    public let capabilities: ConversationCapabilities

    public init(
        route: ConversationRoute,
        platform: Platform,
        title: String,
        latestPreview: String,
        latestActivity: Date,
        unreadCount: Int,
        capabilities: ConversationCapabilities = .mediaCapable
    ) {
        self.route = route
        self.platform = platform
        self.title = title
        self.latestPreview = latestPreview
        self.latestActivity = latestActivity
        self.unreadCount = unreadCount
        self.capabilities = capabilities
    }
}

public struct InboxItem: Identifiable, Hashable, Sendable {
    public enum ID: Hashable, Sendable {
        case person(String)
        case conversation(ConversationRoute)
    }

    public let id: ID
    public let title: String
    public let latestActivity: Date
    public let unreadCount: Int
    public let conversationSummaries: [ConversationSummary]

    public init(
        id: ID,
        title: String,
        latestActivity: Date,
        unreadCount: Int,
        conversationSummaries: [ConversationSummary]
    ) {
        self.id = id
        self.title = title
        self.latestActivity = latestActivity
        self.unreadCount = unreadCount
        self.conversationSummaries = conversationSummaries
    }
}

public extension InboxItem.ID {
    var accessibilityIdentifier: String {
        switch self {
        case let .person(id): "person-\(id)"
        case let .conversation(route): "conversation-\(route.accountID)-\(route.conversationID)"
        }
    }
}

public enum InboxProjector {
    public static func project(
        accounts: [ConnectedAccount],
        identities: [RemoteIdentity],
        conversations: [RemoteConversation],
        directory: ContactDirectory
    ) -> [InboxItem] {
        let accountByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let identityByID = Dictionary(uniqueKeysWithValues: identities.map { ($0.id, $0) })
        let summaries = conversations.compactMap { conversation -> (RemoteIdentity, ConversationSummary)? in
            guard
                let identity = identityByID[conversation.identityID],
                let account = accountByID[conversation.accountID],
                identity.accountID == conversation.accountID
            else {
                return nil
            }

            return (
                identity,
                ConversationSummary(
                    route: conversation.route,
                    platform: account.platform,
                    title: conversation.title,
                    latestPreview: conversation.latestPreview,
                    latestActivity: conversation.latestActivity,
                    unreadCount: conversation.unreadCount,
                    capabilities: conversation.capabilities
                )
            )
        }

        var grouped: [InboxItem.ID: [ConversationSummary]] = [:]
        for (identity, summary) in summaries {
            let id = directory.personID(linkedTo: identity.id).map(InboxItem.ID.person) ?? .conversation(summary.route)
            grouped[id, default: []].append(summary)
        }

        return grouped.map { id, values in
            let sorted = values.sorted {
                if $0.latestActivity != $1.latestActivity {
                    return $0.latestActivity > $1.latestActivity
                }
                if $0.route.accountID != $1.route.accountID {
                    return $0.route.accountID < $1.route.accountID
                }
                return $0.route.conversationID < $1.route.conversationID
            }
            let title: String
            switch id {
            case let .person(personID):
                title = directory.people[personID]?.displayName ?? sorted[0].title
            case .conversation:
                title = sorted[0].title
            }
            return InboxItem(
                id: id,
                title: title,
                latestActivity: sorted[0].latestActivity,
                unreadCount: sorted.reduce(0) { $0 + $1.unreadCount },
                conversationSummaries: sorted
            )
        }
        .sorted {
            if $0.latestActivity == $1.latestActivity {
                return String(describing: $0.id) < String(describing: $1.id)
            }
            return $0.latestActivity > $1.latestActivity
        }
    }
}
