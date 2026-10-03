import Foundation
import Testing
@testable import InboxPlusBridge
@testable import InboxPlusUI

private func cookie(name: String, value: String, domain: String) -> HTTPCookie {
    HTTPCookie(properties: [
        .name: name,
        .value: value,
        .domain: domain,
        .path: "/",
    ])!
}

private let instagramCookies = BridgeLoginCookiesParams(
    url: "https://www.instagram.com/accounts/login/",
    fields: ["sessionid", "csrftoken", "ds_user_id", "mid", "ig_did"].map {
        BridgeLoginCookieField(
            id: $0,
            required: true,
            sources: [
                BridgeLoginCookieFieldSource(type: "cookie", name: $0, cookieDomain: "instagram.com"),
            ]
        )
    },
    waitForURLPattern: "^https://www\\.instagram\\.com/"
)

@Test func exactlyTheDeclaredCookiesAreCapturedAndNothingElse() {
    let captured = CookieMatcher.match(
        cookies: [
            cookie(name: "sessionid", value: "S", domain: ".instagram.com"),
            cookie(name: "csrftoken", value: "C", domain: ".instagram.com"),
            cookie(name: "ds_user_id", value: "1784", domain: ".instagram.com"),
            cookie(name: "mid", value: "M", domain: ".instagram.com"),
            cookie(name: "ig_did", value: "D", domain: ".instagram.com"),
            // Nothing the bridge did not ask for may be taken.
            cookie(name: "shbid", value: "tracking", domain: ".instagram.com"),
            cookie(name: "datr", value: "facebook-tracking", domain: ".facebook.com"),
        ],
        to: instagramCookies
    )

    #expect(captured == [
        "sessionid": "S", "csrftoken": "C", "ds_user_id": "1784", "mid": "M", "ig_did": "D",
    ])
}

@Test func aPartialCaptureIsReportedAsPartialRatherThanPaddedOut() {
    let captured = CookieMatcher.match(
        cookies: [cookie(name: "sessionid", value: "S", domain: ".instagram.com")],
        to: instagramCookies
    )
    #expect(captured == ["sessionid": "S"])
    #expect(Set(instagramCookies.requiredFieldIDs).isSubset(of: Set(captured.keys)) == false)
}

@Test func aCookieFromAnotherSiteWithTheSameNameIsNotAccepted() {
    // A page can host a third-party frame that sets `sessionid` for its own domain; taking it
    // would hand the bridge someone else's session.
    let captured = CookieMatcher.match(
        cookies: [cookie(name: "sessionid", value: "WRONG", domain: ".evil.example")],
        to: instagramCookies
    )
    #expect(captured.isEmpty)
}

@Test(arguments: [
    (".instagram.com", "instagram.com", true),
    ("instagram.com", "instagram.com", true),
    ("www.instagram.com", "instagram.com", true),
    ("i.instagram.com", ".instagram.com", true),
    ("notinstagram.com", "instagram.com", false),
    ("instagram.com.evil.example", "instagram.com", false),
    ("evil.example", "instagram.com", false),
])
func cookieDomainsMatchTheirSubdomainsButNotLookalikes(
    _ actual: String,
    _ declared: String,
    _ expected: Bool
) {
    #expect(
        CookieMatcher.domainMatches(actual, declared) == expected,
        "\(actual) against \(declared)"
    )
}

@Test func aFieldWithNoDeclaredSourceFallsBackToItsOwnIdentifier() {
    let parameters = BridgeLoginCookiesParams(
        url: "https://example.com/",
        fields: [BridgeLoginCookieField(id: "token", required: true, sources: [])]
    )
    let captured = CookieMatcher.match(
        cookies: [cookie(name: "token", value: "T", domain: "example.com")],
        to: parameters
    )
    #expect(captured == ["token": "T"])
}

@Test func aSourceNamedDifferentlyFromItsFieldIsHonoured() {
    // The field id is what the bridge wants back; the source name is what the site actually sets.
    let parameters = BridgeLoginCookiesParams(
        url: "https://example.com/",
        fields: [BridgeLoginCookieField(
            id: "session_token",
            required: true,
            sources: [BridgeLoginCookieFieldSource(type: "cookie", name: "sid", cookieDomain: "example.com")]
        )]
    )
    let captured = CookieMatcher.match(
        cookies: [cookie(name: "sid", value: "V", domain: "example.com")],
        to: parameters
    )
    #expect(captured == ["session_token": "V"])
}

@Test func anonCookieSourceIsIgnoredRatherThanGuessedAt() {
    let parameters = BridgeLoginCookiesParams(
        url: "https://example.com/",
        fields: [BridgeLoginCookieField(
            id: "token",
            required: true,
            sources: [BridgeLoginCookieFieldSource(type: "local_storage", name: "token")]
        )]
    )
    let captured = CookieMatcher.match(
        cookies: [cookie(name: "token", value: "T", domain: "example.com")],
        to: parameters
    )
    #expect(captured.isEmpty, "a local-storage source must not be satisfied from a cookie")
}
