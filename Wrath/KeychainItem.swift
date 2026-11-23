import Foundation
import Security

/// One generic-password Keychain item that stays on this device and never syncs.
struct KeychainItem {
    let service: String
    let account: String
    /// A `kSecAttrAccessible…` value; the default allows background downloads to read it.
    var accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
        ]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data, kSecAttrAccessible as String: accessibility,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            if status == errSecInteractionNotAllowed { return "Unlock your device, then try again." }
            return "Secure storage is unavailable (error \(status))."
        }
    }
}
