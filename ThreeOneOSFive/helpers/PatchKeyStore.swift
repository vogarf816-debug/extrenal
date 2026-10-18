import CryptoKit
import Foundation
import Security

enum PatchKeyStore {
    private static let service = "com.apple.mobile.MobileHouseArrest.patch-keys"
    private static let remoteVaultService = "com.apple.mobile.MobileHouseArrest.remote-vault"

    static func account(for summary: PatchPackageSummary) -> String {
        let fingerprint = summary.keyFingerprint.map { String(format: "%02x", $0) }.joined()
        return "\(summary.packageID.uuidString).\(fingerprint)"
    }

    static func store(_ contentKey: Data, for summary: PatchPackageSummary) throws {
        guard contentKey.count == 32,
              Data(SHA256.hash(data: contentKey)) == summary.keyFingerprint else {
            throw PatchPackageError.keychainFailed
        }
        let account = account(for: summary)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: contentKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PatchPackageError.keychainFailed
        }

        var newItem = query
        attributes.forEach { newItem[$0.key] = $0.value }
        guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else {
            throw PatchPackageError.keychainFailed
        }
    }

    static func load(for summary: PatchPackageSummary) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: summary),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              data.count == 32,
              Data(SHA256.hash(data: data)) == summary.keyFingerprint else {
            throw PatchPackageError.keychainFailed
        }
        return data
    }

    static func delete(for summary: PatchPackageSummary) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: summary)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PatchPackageError.keychainFailed
        }
    }

    static func remoteVaultEncryptionKey(createIfMissing: Bool = true) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: remoteVaultService,
            kSecAttrAccount as String: "remote-package-vault-v1",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else {
                throw PatchPackageError.keychainFailed
            }
            return data
        }
        guard status == errSecItemNotFound else {
            throw PatchPackageError.keychainFailed
        }
        guard createIfMissing else { return nil }

        let symmetricKey = SymmetricKey(size: .bits256)
        let keyData = symmetricKey.withUnsafeBytes { Data($0) }
        var newItem = query
        newItem.removeValue(forKey: kSecReturnData as String)
        newItem.removeValue(forKey: kSecMatchLimit as String)
        newItem[kSecValueData as String] = keyData
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        if addStatus == errSecSuccess { return keyData }
        if addStatus == errSecDuplicateItem {
            return try remoteVaultEncryptionKey(createIfMissing: false)
        }
        throw PatchPackageError.keychainFailed
    }
}
