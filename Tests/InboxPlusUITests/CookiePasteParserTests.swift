import Foundation
import Testing
import InboxPlusBridge
@testable import InboxPlusUI

/// Modelled on what `mautrix-gvoice` actually asks for.
private let googleVoice = BridgeLoginCookiesParams(
    url: "https://voice.google.com/signup",
    fields: [
        field("SID"), field("HSID"), field("SSID"), field("APISID"), field("SAPISID"),
    ]
)

private func field(_ name: String, required: Bool = true) -> BridgeLoginCookieField {
    BridgeLoginCookieField(
        id: name,
        required: required,
        sources: [BridgeLoginCookieFieldSource(type: "cookie", name: name, cookieDomain: ".google.com")]
    )
}

@Test func aJSONObjectOfCookiesIsRead() {
    let pasted = #"{"SID":"sid-value","HSID":"hsid-value","SSID":"s","APISID":"a","SAPISID":"sa"}"#
    let captured = CookiePasteParser.match(pasted: pasted, to: googleVoice)
    #expect(captured["SID"] == "sid-value")
    #expect(captured.count == 5)
    #expect(CookiePasteParser.missingRequiredFieldIDs(pasted: pasted, to: googleVoice).isEmpty)
}

@Test func aCopiedCurlCommandIsRead() {
    // This is literally what "Copy as cURL" puts on the clipboard; asking someone to reformat it
    // by hand is how a login gets abandoned.
    let pasted = """
    curl 'https://voice.google.com/u/0/signup' \\
      -H 'authority: voice.google.com' \\
      -H 'accept: text/html' \\
      -H 'cookie: SID=sid-value; HSID=hsid-value; SSID=s; APISID=a; SAPISID=sa' \\
      --compressed
    """
    let captured = CookiePasteParser.match(pasted: pasted, to: googleVoice)
    #expect(captured["SID"] == "sid-value")
    #expect(captured["SAPISID"] == "sa")
    #expect(CookiePasteParser.missingRequiredFieldIDs(pasted: pasted, to: googleVoice).isEmpty)
}

@Test func aCurlCookieFlagIsRead() {
    let pasted = "curl https://voice.google.com -b 'SID=sid-value; HSID=h; SSID=s; APISID=a; SAPISID=sa'"
    #expect(CookiePasteParser.match(pasted: pasted, to: googleVoice)["SID"] == "sid-value")
}

@Test func aBareCookieListIsRead() {
    let pasted = "SID=sid-value; HSID=h; SSID=s; APISID=a; SAPISID=sa"
    #expect(CookiePasteParser.missingRequiredFieldIDs(pasted: pasted, to: googleVoice).isEmpty)
}

@Test func otherHeadersInTheSamePasteAreNeverMistakenForCookies() {
    // An Authorization header sits right next to the cookie header in a copied cURL command.
    let pasted = """
    curl 'https://voice.google.com' \\
      -H 'authorization: Bearer super-secret-token' \\
      -H 'cookie: SID=sid-value; HSID=h; SSID=s; APISID=a; SAPISID=sa'
    """
    let captured = CookiePasteParser.match(pasted: pasted, to: googleVoice)
    #expect(!captured.values.contains { $0.contains("super-secret-token") })
    #expect(captured["SID"] == "sid-value")
}

@Test func onlyWhatTheBridgeAskedForIsForwarded() {
    // A real cookie header carries dozens of values. Sending them all would hand the bridge more
    // of the user's session than it asked for.
    let pasted = "SID=sid-value; HSID=h; SSID=s; APISID=a; SAPISID=sa; NID=tracking; __Secure-3PSID=other"
    let captured = CookiePasteParser.match(pasted: pasted, to: googleVoice)
    #expect(Set(captured.keys) == ["SID", "HSID", "SSID", "APISID", "SAPISID"])
}

@Test func aPartialPasteNamesExactlyWhatIsStillMissing() {
    let pasted = "SID=sid-value; APISID=a"
    #expect(
        CookiePasteParser.missingRequiredFieldIDs(pasted: pasted, to: googleVoice)
            == ["HSID", "SAPISID", "SSID"]
    )
}

@Test func nothingIsInventedFromEmptyOrJunkInput() {
    for text in ["", "   \n ", "hello there", "{}", "{\"a\": 1}"] {
        #expect(CookiePasteParser.match(pasted: text, to: googleVoice).isEmpty, "invented from: \(text)")
    }
}

@Test func anEmptyCookieValueIsNotTreatedAsPresent() {
    // A cleared cookie would otherwise satisfy a required field and fail at the bridge instead.
    let pasted = "SID=; HSID=h; SSID=s; APISID=a; SAPISID=sa"
    #expect(CookiePasteParser.missingRequiredFieldIDs(pasted: pasted, to: googleVoice) == ["SID"])
}

@Test func aFieldWithoutDeclaredSourcesFallsBackToItsOwnName() {
    let params = BridgeLoginCookiesParams(
        url: "https://example.com",
        fields: [BridgeLoginCookieField(id: "sessionid", required: true, sources: [])]
    )
    #expect(CookiePasteParser.match(pasted: "sessionid=abc123", to: params)["sessionid"] == "abc123")
}

@Test func aValueContainingAnEqualsSignSurvivesIntact() {
    // Base64 cookie values routinely end in padding.
    let params = BridgeLoginCookiesParams(
        url: "https://example.com",
        fields: [BridgeLoginCookieField(id: "token", required: true, sources: [])]
    )
    #expect(CookiePasteParser.match(pasted: "token=YWJjZA==", to: params)["token"] == "YWJjZA==")
}
