import Foundation
import Testing
@testable import InboxPlusMatrix

private func makeKeychain() -> (MatrixKeychain, String) {
    // A unique service per test keeps runs isolated and leaves the user's real items untouched.
    (MatrixKeychain(service: "org.inboxplus.tests.\(UUID().uuidString)"), "inboxplus-store")
}

@Test func anAbsentPassphraseReadsAsNil() throws {
    let (keychain, account) = makeKeychain()
    defer { try? keychain.deletePassphrase(forAccount: account) }
    #expect(try keychain.passphrase(forAccount: account) == nil)
}

@Test func aStoredPassphraseRoundTrips() throws {
    let (keychain, account) = makeKeychain()
    defer { try? keychain.deletePassphrase(forAccount: account) }

    try keychain.setPassphrase("correct horse battery staple", forAccount: account)
    #expect(try keychain.passphrase(forAccount: account) == "correct horse battery staple")
}

@Test func storingTwiceUpdatesRatherThanDuplicating() throws {
    // Break caught: SecItemAdd on an existing item fails with errSecDuplicateItem.
    let (keychain, account) = makeKeychain()
    defer { try? keychain.deletePassphrase(forAccount: account) }

    try keychain.setPassphrase("first", forAccount: account)
    try keychain.setPassphrase("second", forAccount: account)
    #expect(try keychain.passphrase(forAccount: account) == "second")
}

@Test func anEmptyPassphraseIsRejected() throws {
    let (keychain, account) = makeKeychain()
    #expect(throws: MatrixKeychainError.emptyPassphrase) {
        try keychain.setPassphrase("", forAccount: account)
    }
}

@Test func theFirstAccessGeneratesAndPersistsOnePassphrase() throws {
    // Break caught: regenerating on every launch makes the existing encrypted store unreadable.
    let (keychain, account) = makeKeychain()
    defer { try? keychain.deletePassphrase(forAccount: account) }

    let first = try keychain.existingOrNewPassphrase(forAccount: account)
    let second = try keychain.existingOrNewPassphrase(forAccount: account)

    #expect(first == second)
    #expect(!first.isEmpty)
}

@Test func aGeneratedPassphraseIsNotReused() {
    #expect(MatrixKeychain.randomPassphrase() != MatrixKeychain.randomPassphrase())
    #expect(MatrixKeychain.randomPassphrase().count >= 32)
}

@Test func deletingIsIdempotent() throws {
    let (keychain, account) = makeKeychain()
    try keychain.setPassphrase("value", forAccount: account)
    try keychain.deletePassphrase(forAccount: account)
    #expect(throws: Never.self) { try keychain.deletePassphrase(forAccount: account) }
    #expect(try keychain.passphrase(forAccount: account) == nil)
}

@Test func differentAccountsHoldDifferentPassphrases() throws {
    let (keychain, account) = makeKeychain()
    defer {
        try? keychain.deletePassphrase(forAccount: account)
        try? keychain.deletePassphrase(forAccount: "other")
    }

    try keychain.setPassphrase("a", forAccount: account)
    try keychain.setPassphrase("b", forAccount: "other")
    #expect(try keychain.passphrase(forAccount: account) == "a")
    #expect(try keychain.passphrase(forAccount: "other") == "b")
}
