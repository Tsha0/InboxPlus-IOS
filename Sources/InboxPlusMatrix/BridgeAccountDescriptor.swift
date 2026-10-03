import Foundation
import InboxPlusCore

/// What a prepared bridge should look like as an account in the inbox.
///
/// Supplied by the app layer rather than looked up here: the bridge catalog lives in `InboxPlusBridge`,
/// and the Matrix gateway has no business importing it. All the gateway needs is the mapping from a
/// bridge identifier to the network the user actually thinks they are using.
public struct BridgeAccountDescriptor: Sendable, Equatable, Identifiable {
    public let bridgeID: String
    public let platform: Platform
    public let displayName: String

    public var id: String { bridgeID }

    public init(bridgeID: String, platform: Platform, displayName: String) {
        self.bridgeID = bridgeID
        self.platform = platform
        self.displayName = displayName
    }
}
