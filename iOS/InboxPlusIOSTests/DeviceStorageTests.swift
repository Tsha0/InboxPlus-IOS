import XCTest
import Security
@testable import InboxPlusMobile
import InboxPlusRemote

final class DeviceStorageTests: XCTestCase {
    @MainActor func testKeychainRoundTripUpdateAndDelete() throws {
        let store = PairingKeychain(service: "com.inboxplus.ios.tests.\(UUID().uuidString)")
        defer { try? store.delete() }
        XCTAssertNil(try store.load())
        let first = try CompanionConfiguration(address: "https://first.example", token: String(repeating: "a", count: 32))
        let second = try CompanionConfiguration(address: "https://second.example", token: String(repeating: "b", count: 32))
        try store.save(first); XCTAssertEqual(try store.load(), first)
        try store.save(second); XCTAssertEqual(try store.load(), second)
        try store.delete(); XCTAssertNil(try store.load())
        try store.delete()
    }
    @MainActor func testPairingKeyIsDeviceOnlyAndUnavailableWhenLocked() throws {
        let service = "com.inboxplus.ios.tests.\(UUID().uuidString)"
        let store = PairingKeychain(service: service); defer { try? store.delete() }
        try store.save(CompanionConfiguration(address: "https://mac.example", token: String(repeating: "a", count: 32)))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
}
