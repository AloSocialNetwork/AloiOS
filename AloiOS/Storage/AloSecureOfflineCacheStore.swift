import CryptoKit
import Foundation
import Security

final class AloSecureOfflineCacheStore {
    static let shared = AloSecureOfflineCacheStore()

    private let keychainService = "alo.ios.offline-cache"
    private let keychainAccount = "offline-cache-key.v2"
    private let lastOwnerKey = "alo.ios.offline-cache.owner.v2"
    private let fileName = "bootstrap-v2.bin"

    func save(_ data: Data, ownerUserId: Int) throws {
        guard ownerUserId > 0 else { throw AloSecureOfflineCacheError.invalidOwner }
        let root = try ownerRootURL(ownerUserId: ownerUserId)
        try writeEncrypted(data, to: root.appendingPathComponent(fileName), ownerUserId: ownerUserId)
        UserDefaults.standard.set(ownerUserId, forKey: lastOwnerKey)
    }

    func load() -> Data? {
        let ownerUserId = UserDefaults.standard.integer(forKey: lastOwnerKey)
        guard ownerUserId > 0,
              let url = try? ownerRootURL(ownerUserId: ownerUserId).appendingPathComponent(fileName),
              let combined = try? Data(contentsOf: url),
              let sealed = try? AES.GCM.SealedBox(combined: combined) else {
            return nil
        }
        return try? AES.GCM.open(sealed, using: encryptionKey())
    }

    func saveConversation(_ data: Data, peerId: Int, ownerUserId: Int) throws {
        guard peerId > 0, ownerUserId > 0 else { throw AloSecureOfflineCacheError.invalidOwner }
        let root = try ownerRootURL(ownerUserId: ownerUserId)
        try writeEncrypted(
            data,
            to: root.appendingPathComponent("conversation-\(peerId)-v1.bin"),
            ownerUserId: ownerUserId
        )
        UserDefaults.standard.set(ownerUserId, forKey: lastOwnerKey)
    }

    func loadConversation(peerId: Int, ownerUserId: Int) -> Data? {
        guard peerId > 0, ownerUserId > 0,
              let url = try? ownerRootURL(ownerUserId: ownerUserId)
                .appendingPathComponent("conversation-\(peerId)-v1.bin"),
              let combined = try? Data(contentsOf: url),
              let sealed = try? AES.GCM.SealedBox(combined: combined) else {
            return nil
        }
        return try? AES.GCM.open(sealed, using: encryptionKey())
    }

    func clearCurrentOwner() {
        let ownerUserId = UserDefaults.standard.integer(forKey: lastOwnerKey)
        if ownerUserId > 0, let root = try? ownerRootURL(ownerUserId: ownerUserId) {
            try? FileManager.default.removeItem(at: root)
        }
        UserDefaults.standard.removeObject(forKey: lastOwnerKey)
    }

    private func encryptionKey() throws -> SymmetricKey {
        if let stored = readKeychainData(), stored.count == 32 {
            return SymmetricKey(data: stored)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try storeKeychainData(raw)
        return key
    }

    private func writeEncrypted(_ data: Data, to url: URL, ownerUserId: Int) throws {
        let sealed = try AES.GCM.seal(data, using: try encryptionKey())
        guard let combined = sealed.combined else { throw AloSecureOfflineCacheError.encryptionFailed }
        let root = try ownerRootURL(ownerUserId: ownerUserId)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try protectAndExcludeFromBackup(root)
        try combined.write(to: url, options: [.atomic])
        try protectAndExcludeFromBackup(url)
    }

    private func readKeychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private func storeKeychainData(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AloSecureOfflineCacheError.keyStorageFailed }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw AloSecureOfflineCacheError.keyStorageFailed
        }
    }

    private func ownerRootURL(ownerUserId: Int) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("AloOfflineSecure", isDirectory: true)
            .appendingPathComponent("user-\(ownerUserId)", isDirectory: true)
    }

    private func protectAndExcludeFromBackup(_ url: URL) throws {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
    }
}

private enum AloSecureOfflineCacheError: Error {
    case encryptionFailed
    case invalidOwner
    case keyStorageFailed
}
