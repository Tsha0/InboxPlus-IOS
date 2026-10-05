import Foundation
import Security
import InboxPlusRemote

@MainActor protocol PairingCredentialStore {
    func save(_ configuration: CompanionConfiguration) throws
    func load() throws -> CompanionConfiguration?
    func delete() throws
}

@MainActor struct PairingKeychain: PairingCredentialStore {
    let service: String
    init(service: String = "com.inboxplus.ios.pairing") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "companion"]
    }
    func save(_ configuration: CompanionConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw failure("update", update) }
        var item = query; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure("store", status) }
    }
    func load() throws -> CompanionConfiguration? {
        var item = query; item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure("read", status) }
        let saved = try JSONDecoder().decode(CompanionConfiguration.self, from: data)
        return try CompanionConfiguration(address: saved.address.absoluteString, token: saved.token)
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("delete", status) }
    }
    private func failure(_ action: String, _ status: OSStatus) -> CompanionError {
        .server("Could not \(action) the pairing key (\(status)).")
    }
}
