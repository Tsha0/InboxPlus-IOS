import Foundation
import Security

/// Stores the Matrix client store passphrase in the macOS Keychain.
///
/// The design requires the SDK store key to live in the Keychain rather than on disk, so the
/// encrypted store cannot be opened from a stolen copy of the profile directory alone.
public struct MatrixKeychain: Sendable {
    public static let defaultService = "org.inboxplus.matrix.store"

    public let service: String

    public init(service: String = MatrixKeychain.defaultService) {
        self.service = service
    }

    public func passphrase(forAccount account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw MatrixKeychainError.malformedItem
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw MatrixKeychainError.unhandled(status: status)
        }
    }

    public func setPassphrase(_ passphrase: String, forAccount account: String) throws {
        guard !passphrase.isEmpty else { throw MatrixKeychainError.emptyPassphrase }
        let data = Data(passphrase.utf8)

        let update = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw MatrixKeychainError.unhandled(status: update)
        }

        var insert = baseQuery(account: account)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MatrixKeychainError.unhandled(status: status)
        }
    }

    /// Returns the stored passphrase, generating and persisting one on first use.
    public func existingOrNewPassphrase(
        forAccount account: String,
        generate: () -> String = { MatrixKeychain.randomPassphrase() }
    ) throws -> String {
        if let existing = try passphrase(forAccount: account) { return existing }
        let created = generate()
        try setPassphrase(created, forAccount: account)
        return created
    }

    public func deletePassphrase(forAccount account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MatrixKeychainError.unhandled(status: status)
        }
    }

    public static func randomPassphrase(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            // SecRandomCopyBytes only fails when the system entropy source is unavailable, which
            // would make any generated key unsafe. Refuse rather than fall back to a weak source.
            preconditionFailure("system random number generator is unavailable")
        }
        return Data(bytes).base64EncodedString()
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum MatrixKeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyPassphrase
    case malformedItem
    case unhandled(status: OSStatus)

    public var description: String {
        switch self {
        case .emptyPassphrase:
            "refusing to store an empty store passphrase"
        case .malformedItem:
            "keychain item is not valid UTF-8 text"
        case let .unhandled(status):
            "keychain operation failed with status \(status)"
        }
    }
}
