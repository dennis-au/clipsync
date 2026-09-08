import Foundation
import Security

enum ClipSyncSecret: String, CaseIterable {
    case password = "clipboard-password"
    case tunnelToken = "cloudflare-tunnel-token"
}

enum KeychainSecretStoreError: LocalizedError {
    case unavailable(OSStatus)
    case invalidSecret

    var errorDescription: String? {
        switch self {
        case .unavailable: "macOS Keychain could not store the ClipSync secret."
        case .invalidSecret: "The secret cannot be empty or contain a line break."
        }
    }
}

struct KeychainSecretStore {
    static let service = "io.clipsync.control"

    func value(for secret: ClipSyncSecret) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: secret.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainSecretStoreError.unavailable(result)
        }
        return value
    }

    func set(_ value: String, for secret: ClipSyncSecret) throws {
        guard Self.valid(value) else { throw KeychainSecretStoreError.invalidSecret }
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: secret.rawValue,
        ]
        let update: [CFString: Any] = [kSecValueData: Data(value.utf8)]
        let result = SecItemUpdate(attributes as CFDictionary, update as CFDictionary)
        if result == errSecItemNotFound {
            var add = attributes
            add[kSecValueData] = Data(value.utf8)
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainSecretStoreError.unavailable(added) }
        } else if result != errSecSuccess {
            throw KeychainSecretStoreError.unavailable(result)
        }
    }

    func remove(_ secret: ClipSyncSecret) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: secret.rawValue,
        ]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw KeychainSecretStoreError.unavailable(result)
        }
    }

    static func valid(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("\n") && !value.contains("\r")
    }
}
