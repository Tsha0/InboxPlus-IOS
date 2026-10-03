import Testing
@testable import InboxPlusCore
@testable import InboxPlusUI

@Test func installOutcomeNamesTheNetworkItInstalled() {
    for platform in Platform.allCases {
        let outcome = BridgeInstallOutcome(platform: platform, profile: "demo")
        #expect(outcome.title.contains(platform.accessibilityLabel))
        #expect(outcome.message.contains(platform.accessibilityLabel))
    }
}

@Test func installOutcomeSaysTheRuntimeMustRestartBeforeSigningIn() {
    let outcome = BridgeInstallOutcome(platform: .telegram, profile: "work")
    // The bridge is registered but the running homeserver has not read that registration, so an
    // outcome that read as "connected" would send the user to a login that cannot complete.
    #expect(outcome.message.contains("Quit and"))
    #expect(outcome.message.contains("reopen Inbox+"))
    #expect(!outcome.message.contains("RuntimeCLI"))
}
