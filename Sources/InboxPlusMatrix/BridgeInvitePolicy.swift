import Foundation

/// Decides which room invitations Inbox+ may accept on the user's behalf.
///
/// A bridge does not put you in a conversation; it creates a portal room and *invites* you, so an
/// unaccepted invite is an invisible conversation. Accepting automatically is therefore necessary —
/// but accepting anything at all would mean any local account could put a room in someone's inbox.
/// Only users inside a prepared bridge's own namespace are trusted, and the namespace is derived
/// from the bridge identifier rather than supplied as free text.
public struct BridgeInvitePolicy: Sendable, Equatable {
    /// Localpart prefixes that may invite, e.g. `instagram_` for ghosts and `instagrambot` for the
    /// bridge's own bot.
    public let trustedLocalpartPrefixes: [String]
    public let serverName: String
    /// The bridges these prefixes came from, kept so a room can be attributed back to one.
    public let bridgeIDs: [String]

    public init(trustedLocalpartPrefixes: [String], serverName: String, bridgeIDs: [String] = []) {
        self.trustedLocalpartPrefixes = trustedLocalpartPrefixes
        self.serverName = serverName
        self.bridgeIDs = bridgeIDs
    }

    /// Trusts nothing. The default, so a profile with no bridges behaves exactly as it did before.
    public static let trustingNobody = BridgeInvitePolicy(
        trustedLocalpartPrefixes: [],
        serverName: ""
    )

    /// The namespace a mautrix bridge claims: `@<id>_*` ghosts plus the `@<id>bot` bot.
    public static func forBridges(ids: [String], serverName: String) -> BridgeInvitePolicy {
        BridgeInvitePolicy(
            trustedLocalpartPrefixes: ids.flatMap { ["\($0)_", "\($0)bot"] },
            serverName: serverName,
            bridgeIDs: ids
        )
    }

    /// Which bridge, if any, this user belongs to.
    ///
    /// A portal room always contains the bridge's own ghost or bot, so the members of a room are
    /// what says which network it really is. Without this every bridged conversation is reported
    /// as plain Matrix, which is what the transport happens to be rather than what the user is
    /// looking at.
    ///
    /// Longest identifier first: `whatsapp` and `whatsappbusiness` would otherwise both match a
    /// `@whatsappbusiness_1` ghost and the shorter one could win.
    public func bridgeID(owning userID: String) -> String? {
        guard let localpart = Self.localpart(of: userID, on: serverName) else { return nil }
        return bridgeIDs
            .sorted { $0.count > $1.count }
            .first { localpart.hasPrefix("\($0)_") || localpart == "\($0)bot" }
    }

    /// The localpart, but only for a user on the server this policy pins.
    static func localpart(of userID: String, on serverName: String) -> String? {
        guard !serverName.isEmpty, userID.hasPrefix("@") else { return nil }
        guard let colon = userID.firstIndex(of: ":") else { return nil }
        guard String(userID[userID.index(after: colon)...]) == serverName else { return nil }
        let localpart = String(userID[userID.index(after: userID.startIndex)..<colon])
        return localpart.isEmpty ? nil : localpart
    }

    public func trusts(inviterUserID: String) -> Bool {
        guard !trustedLocalpartPrefixes.isEmpty else { return false }
        guard inviterUserID.hasPrefix("@") else { return false }
        guard let colon = inviterUserID.firstIndex(of: ":") else { return false }

        let localpart = String(inviterUserID[inviterUserID.index(after: inviterUserID.startIndex)..<colon])
        let host = String(inviterUserID[inviterUserID.index(after: colon)...])
        // The homeserver is loopback-only and never federates, but pinning the server name keeps
        // the rule true rather than true-by-accident.
        guard host == serverName else { return false }
        return trustedLocalpartPrefixes.contains { localpart.hasPrefix($0) }
    }
}
