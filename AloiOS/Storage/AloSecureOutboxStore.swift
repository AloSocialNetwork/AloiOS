import CryptoKit
import Foundation
import Security

final class AloSecureOutboxStore {
    static let shared = AloSecureOutboxStore()

    private let keychainService = "alo.ios.secure-outbox"
    private let keychainAccount = "outbox-key.v1"
    private let queueFileName = "queue-v1.bin"

    func save(records: [[String: Any]], ownerUserId: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: records, options: [])
        try writeEncrypted(
            data,
            to: try rootURL(ownerUserId: ownerUserId).appendingPathComponent(queueFileName),
            ownerUserId: ownerUserId
        )
    }

    func load(ownerUserId: Int) -> [[String: Any]] {
        guard let data = try? readEncrypted(
            from: try rootURL(ownerUserId: ownerUserId).appendingPathComponent(queueFileName)
        ),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return records
    }

    func saveAttachment(_ data: Data, id: String, ownerUserId: Int) throws {
        try writeEncrypted(
            data,
            to: try attachmentURL(id: id, ownerUserId: ownerUserId),
            ownerUserId: ownerUserId
        )
    }

    func loadAttachment(id: String, ownerUserId: Int) -> Data? {
        try? readEncrypted(from: try attachmentURL(id: id, ownerUserId: ownerUserId))
    }

    func deleteAttachment(id: String, ownerUserId: Int) {
        guard let url = try? attachmentURL(id: id, ownerUserId: ownerUserId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func clear(ownerUserId: Int) {
        guard let root = try? rootURL(ownerUserId: ownerUserId) else { return }
        try? FileManager.default.removeItem(at: root)
    }

    func discardLegacyUnscopedData() {
        guard let root = try? baseRootURL(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
              ) else { return }
        for entry in entries where entry.lastPathComponent == queueFileName || entry.lastPathComponent.hasPrefix("attachment-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func writeEncrypted(_ data: Data, to url: URL, ownerUserId: Int) throws {
        let sealed = try AES.GCM.seal(data, using: try encryptionKey())
        guard let combined = sealed.combined else { throw AloSecureOutboxError.encryptionFailed }
        try ensureRootDirectory(ownerUserId: ownerUserId)
        try combined.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func readEncrypted(from url: URL) throws -> Data {
        let combined = try Data(contentsOf: url)
        let sealed = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealed, using: try encryptionKey())
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
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw AloSecureOutboxError.keyStorageFailed }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw AloSecureOutboxError.keyStorageFailed
        }
    }

    private func baseRootURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("AloSecureOutbox", isDirectory: true)
    }

    private func rootURL(ownerUserId: Int) throws -> URL {
        guard ownerUserId > 0 else { throw AloSecureOutboxError.invalidIdentifier }
        return try baseRootURL().appendingPathComponent("user-\(ownerUserId)", isDirectory: true)
    }

    private func ensureRootDirectory(ownerUserId: Int) throws {
        let root = try rootURL(ownerUserId: ownerUserId)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: root.path
        )
    }

    private func attachmentURL(id: String, ownerUserId: Int) throws -> URL {
        let safeId = id.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard safeId.count >= 8 else { throw AloSecureOutboxError.invalidIdentifier }
        return try rootURL(ownerUserId: ownerUserId).appendingPathComponent("attachment-\(safeId).bin")
    }
}

private enum AloSecureOutboxError: Error {
    case encryptionFailed
    case invalidIdentifier
    case keyStorageFailed
}
