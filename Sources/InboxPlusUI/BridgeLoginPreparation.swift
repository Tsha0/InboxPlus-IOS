import Foundation
import InboxPlusBridge
import InboxPlusCore

/// What came back from asking to connect a network.
///
/// A network whose bridge this profile has never installed is not an error — it is the first
/// connection to that network — but it cannot go straight to a login either, so the two outcomes
/// are distinct rather than one being reported as a failure of the other.
public enum BridgeLoginPreparation {
    /// The bridge is installed and running; sign in through this session.
    case ready(any BridgeLoginSession)
    /// The bridge was installed just now and needs the profile runtime restarted to be loaded.
    case installedPendingRuntimeRestart(BridgeInstallOutcome)
}

/// A bridge installed on demand, and what still has to happen before it can be signed in to.
public struct BridgeInstallOutcome: Sendable, Equatable {
    public let platform: Platform
    public let profile: String

    public init(platform: Platform, profile: String) {
        self.platform = platform
        self.profile = profile
    }

    public var title: String { "\(platform.accessibilityLabel) is installed" }

    /// Names the restart rather than implying the network is ready: the homeserver reads its
    /// appservice registrations once at startup, so this bridge stays invisible until then.
    public var message: String {
        """
        Inbox+ downloaded and registered the \(platform.accessibilityLabel) connection. Quit and \
        reopen Inbox+ to finish setup, then choose \(platform.accessibilityLabel) again to sign in.
        """
    }
}
