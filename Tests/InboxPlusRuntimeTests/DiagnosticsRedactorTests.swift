import Foundation
import Testing
@testable import InboxPlusRuntime

private let redactor = DiagnosticsRedactor(knownSecrets: ["hunter2-the-passphrase"], salt: "fixed-salt")

@Test func aKnownSecretDisappearsEntirely() {
    let out = redactor.redact("store opened with hunter2-the-passphrase ok")
    #expect(!out.contains("hunter2"))
    #expect(out.contains("[redacted-secret]"))
}

@Test func aTokenNobodyRegisteredIsStillCaught() {
    // The whole reason for pattern rules: a bundle can contain a token Inbox+ never held.
    let out = redactor.redact("GET /sync?access_token=syt_cGFsbG8_AbCdEf123456_xyz HTTP/1.1")
    #expect(!out.contains("syt_cGFsbG8"))
}

@Test func authorizationHeadersAreRemovedInAnyCasing() {
    #expect(!redactor.redact("Authorization: Bearer abc123def456").contains("abc123def456"))
    #expect(!redactor.redact("authorization=xyz789tokenvalue").contains("xyz789tokenvalue"))
}

@Test(arguments: [
    "as_token: J9aGsgS8QNoSecretValue",
    "hs_token = \"anotherSecretValue123\"",
    "registration_shared_secret: 'topSecretRegistration'",
    "password: correcthorsebattery",
    "shared_secret: abc123sharedsecret",
])
func namedSecretsInConfigFilesAreRemoved(_ line: String) {
    let out = redactor.redact(line)
    #expect(out.contains("[redacted-secret]"), "not redacted: \(out)")
}

@Test func cookiesAreRemovedWholeAndPerPair() {
    #expect(!redactor.redact("Cookie: sessionid=abc; csrftoken=def").contains("abc"))
    let pair = redactor.redact("captured sessionid=IGSESSION123456 for login")
    #expect(!pair.contains("IGSESSION123456"))
}

@Test func messageBodiesNeverSurviveIntoABundle() {
    // The single most sensitive thing in a messaging app's logs.
    let event = #"{"type":"m.room.message","content":{"body":"meet me at 6, bring the keys"}}"#
    let out = redactor.redact(event)
    #expect(!out.contains("bring the keys"))
    #expect(out.contains("[redacted-message]"))
    // The surrounding structure survives, which is what makes the log still worth reading.
    #expect(out.contains("m.room.message"))
}

@Test func aBodyContainingEscapedQuotesIsFullyRemoved() {
    let event = #"{"body":"she said \"no\" twice","other":"keep"}"#
    let out = redactor.redact(event)
    #expect(!out.contains("she said"))
    #expect(out.contains("keep"))
}

@Test func attachmentURLsAreRemovedBecauseTheIdAloneFetchesTheFile() {
    let out = redactor.redact("downloading mxc://inboxplus.localhost/qGshbmvwCrzxdDLwSEbYjZhI now")
    #expect(!out.contains("qGshbmvwCrzxdDLwSEbYjZhI"))
    #expect(out.contains("[redacted-media-url]"))
}

@Test func verificationCodesAreRemoved() {
    #expect(!redactor.redact("2fa code: 483920 accepted").contains("483920"))
    #expect(!redactor.redact("code=1234").contains("1234"))
}

@Test func aContactIsPseudonymisedRatherThanDeleted() {
    // A log where every user is "[redacted]" cannot show that two events concern one person, which
    // is usually the thing being debugged.
    let out = redactor.redact("@maya:inboxplus.localhost joined; @maya:inboxplus.localhost sent")
    #expect(!out.contains("maya"))
    let tokens = out.components(separatedBy: "[user-").dropFirst().map { $0.prefix(8) }
    #expect(tokens.count == 2)
    #expect(tokens[0] == tokens[1], "the same person must pseudonymise to the same token")
    // The server is kept: it is not personal and it is diagnostically important.
    #expect(out.contains("inboxplus.localhost"))
}

@Test func differentPeopleGetDifferentPseudonyms() {
    let out = redactor.redact("@maya:s.example and @jordan:s.example")
    let tokens = out.components(separatedBy: "[user-").dropFirst().map { $0.prefix(8) }
    #expect(tokens.count == 2)
    #expect(tokens[0] != tokens[1])
}

@Test func pseudonymsAreNotReversibleByGuessing() {
    // Without the salt, anyone could hash a suspected handle and confirm it appears in the bundle.
    let a = DiagnosticsRedactor(salt: "salt-a").redact("@maya:s.example")
    let b = DiagnosticsRedactor(salt: "salt-b").redact("@maya:s.example")
    #expect(a != b)
}

@Test func emailsAndPhoneNumbersArePseudonymised() {
    let out = redactor.redact("contact maya@example.com or +14155550123")
    #expect(!out.contains("maya@example.com"))
    #expect(!out.contains("+14155550123"))
    #expect(out.contains("[email-"))
    #expect(out.contains("[phone-"))
}

@Test func ordinaryDiagnosticTextIsLeftAlone() {
    // Redaction that eats the log defeats the purpose of collecting it.
    let line = "bridge telegram phase=healthy port=52295 restarts=0"
    #expect(redactor.redact(line) == line)
}

@Test func redactionRunsLineByLineWithoutLosingStructure() {
    let log = """
    starting
    Authorization: Bearer secrettokenvalue
    done
    """
    let out = redactor.redact(linesOf: log)
    #expect(out.split(separator: "\n").count == 3)
    #expect(out.hasPrefix("starting"))
    #expect(out.hasSuffix("done"))
    #expect(!out.contains("secrettokenvalue"))
}

@Test func aShortKnownValueIsNotUsedAsARedactionRule() {
    // Substituting every occurrence of a two-character "secret" would shred the whole log.
    let permissive = DiagnosticsRedactor(knownSecrets: ["ok"], salt: "s")
    #expect(permissive.redact("status ok") == "status ok")
}
