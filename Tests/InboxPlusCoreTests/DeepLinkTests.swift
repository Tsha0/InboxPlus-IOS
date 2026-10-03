import Foundation
import Testing
@testable import InboxPlusCore

@Test func aPlatformsOwnLinkIsVerified() throws {
    let link = try DeepLinkVerifier.verify("https://www.instagram.com/reel/Cabc123/", for: .instagram)
    #expect(link.platform == .instagram)
    #expect(link.url.absoluteString == "https://www.instagram.com/reel/Cabc123/")
}

@Test func asubdomainOfAnOwnedDomainIsVerified() throws {
    _ = try DeepLinkVerifier.verify("https://www.instagram.com/p/1", for: .instagram)
}

@Test func aLookalikeDomainIsRejected() {
    // The leading dot in the suffix check is the whole defence here.
    #expect(throws: DeepLinkVerificationError.hostNotOwnedByPlatform(
        host: "evil-instagram.com", platform: .instagram
    )) {
        try DeepLinkVerifier.verify("https://evil-instagram.com/reel/1", for: .instagram)
    }
}

@Test func aLinkBelongingToAnotherPlatformIsRejected() {
    // A bridge naming the wrong owner is exactly the case verification exists for.
    #expect(throws: DeepLinkVerificationError.self) {
        try DeepLinkVerifier.verify("https://t.me/durov", for: .instagram)
    }
}

@Test(arguments: [
    "instagram://media?id=1",
    "javascript:alert(1)",
    "data:text/html,<script>",
    "file:///etc/passwd",
    "http://instagram.com/reel/1",
])
func onlyHttpsIsAccepted(_ raw: String) {
    // Any installed app can claim a custom scheme, so following one hands the message to whoever
    // registered it first. https is resolved by macOS against the domain itself.
    #expect(throws: DeepLinkVerificationError.self) {
        try DeepLinkVerifier.verify(raw, for: .instagram)
    }
}

@Test func credentialsEmbeddedInTheLinkAreRejected() {
    #expect(throws: DeepLinkVerificationError.embeddedCredentials) {
        try DeepLinkVerifier.verify("https://user:secret@instagram.com/p/1", for: .instagram)
    }
}

@Test func anExplicitNonStandardPortIsRejected() {
    #expect(throws: DeepLinkVerificationError.unexpectedPort(8080)) {
        try DeepLinkVerifier.verify("https://instagram.com:8080/p/1", for: .instagram)
    }
    // 443 is what https already means, so stating it is not a redirection.
    #expect(throws: Never.self) {
        try DeepLinkVerifier.verify("https://instagram.com:443/p/1", for: .instagram)
    }
}

@Test func aPlatformWithNoWebLinksVerifiesNothing() {
    #expect(DeepLinkVerifier.verifiableDomains(for: .iMessage).isEmpty)
    #expect(throws: DeepLinkVerificationError.platformHasNoVerifiableLinks(.iMessage)) {
        try DeepLinkVerifier.verify("https://apple.com/messages", for: .iMessage)
    }
}

@Test func everyPlatformWithDomainsListsThemLowercasedAndBare() {
    for platform in Platform.allCases {
        for domain in DeepLinkVerifier.verifiableDomains(for: platform) {
            #expect(domain == domain.lowercased())
            #expect(!domain.hasPrefix("."))
            #expect(!domain.contains("/"))
            #expect(domain.contains("."))
        }
    }
}

@Test func aStoredLinkIsVerifiedAgainWhenItIsRead() throws {
    let link = try DeepLinkVerifier.verify("https://ig.me/m/inboxplus", for: .instagram)
    let encoded = try JSONEncoder().encode(link)
    #expect(try JSONDecoder().decode(VerifiedDeepLink.self, from: encoded) == link)

    // A link that was trusted when written must not be trusted merely because it was written.
    let forged = Data(#"{"url":"https://evil.example/p","platform":"instagram"}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(VerifiedDeepLink.self, from: forged)
    }
}
