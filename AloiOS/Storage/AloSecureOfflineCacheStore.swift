import CryptoKit
import Foundation
import Security

/// A search hit is assembled only after the encrypted local history has been
/// opened on-device. Neither the query nor a message body is sent to the API.
struct AloOfflineMessageSearchHit: Identifiable {
    let conversation: AloConversationDetail
    let message: AloChatMessage

    var id: String {
        "\(conversation.kind):\(conversation.peerId):\(conversation.roomId):\(message.id)"
    }
}

final class AloSecureOfflineCacheStore: @unchecked Sendable {
    static let shared = AloSecureOfflineCacheStore()

    private let keychainService = "alo.ios.offline-cache"
    private let keychainAccount = "offline-cache-key.v2"
    private let lastOwnerKey = "alo.ios.offline-cache.owner.v2"
    private let fileName = "bootstrap-v2.bin"
    private let historyLock = NSLock()

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
        mergeSearchHistory(data, peerId: peerId, ownerUserId: ownerUserId, complete: false)
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

    /// Avatar and non-E2EE preview bytes are still private account data. Keep
    /// them encrypted alongside the bootstrap cache so an offline launch can
    /// render the last known people and media instead of empty placeholders.
    func saveRemoteImage(_ data: Data, cacheKey: String) {
        let ownerUserId = UserDefaults.standard.integer(forKey: lastOwnerKey)
        guard ownerUserId > 0, !data.isEmpty else { return }
        let url = (try? ownerRootURL(ownerUserId: ownerUserId))?
            .appendingPathComponent(remoteImageFileName(for: cacheKey))
        guard let url else { return }
        try? writeEncrypted(data, to: url, ownerUserId: ownerUserId)
    }

    func loadRemoteImage(cacheKey: String) -> Data? {
        let ownerUserId = UserDefaults.standard.integer(forKey: lastOwnerKey)
        guard ownerUserId > 0,
              let url = try? ownerRootURL(ownerUserId: ownerUserId)
                .appendingPathComponent(remoteImageFileName(for: cacheKey)),
              let combined = try? Data(contentsOf: url),
              let sealed = try? AES.GCM.SealedBox(combined: combined) else {
            return nil
        }
        return try? AES.GCM.open(sealed, using: encryptionKey())
    }

    func searchMessages(
        peerId: Int,
        ownerUserId: Int,
        query: String,
        limit: Int = 100
    ) -> [AloChatMessage] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let data = loadSearchHistory(peerId: peerId, ownerUserId: ownerUserId)
                ?? loadConversation(peerId: peerId, ownerUserId: ownerUserId),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return AloConversationDetail(peerId: peerId, json: json).items
            .reversed()
            .filter { matchesSearch(message: $0, query: normalized) }
            .prefix(max(1, min(limit, 500)))
            .map { $0 }
    }

    /// Searches every encrypted conversation index available to the currently
    /// signed-in account. The filenames contain no message text; each file is
    /// authenticated and decrypted with the device-local Keychain key before
    /// it is inspected.
    func searchAllMessages(
        ownerUserId: Int,
        query: String,
        limit: Int = 100
    ) -> [AloOfflineMessageSearchHit] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ownerUserId > 0, !normalized.isEmpty else { return [] }

        historyLock.lock()
        defer { historyLock.unlock() }

        guard let root = try? ownerRootURL(ownerUserId: ownerUserId),
              let files = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let peerIds = Set(files.compactMap { peerIdForConversationFile($0.lastPathComponent) })
        var seen = Set<String>()
        var matches = [AloOfflineMessageSearchHit]()

        for peerId in peerIds.sorted() {
            guard let data = loadSearchHistoryUnlocked(peerId: peerId, ownerUserId: ownerUserId)
                    ?? loadConversation(peerId: peerId, ownerUserId: ownerUserId),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let conversation = AloConversationDetail(peerId: peerId, json: json)
            for message in conversation.items where matchesSearch(message: message, query: normalized) {
                let key = "\(peerId):\(message.id)"
                guard seen.insert(key).inserted else { continue }
                matches.append(AloOfflineMessageSearchHit(conversation: conversation, message: message))
            }
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.message.createdAt == rhs.message.createdAt {
                    return lhs.id > rhs.id
                }
                return lhs.message.createdAt > rhs.message.createdAt
            }
            .prefix(max(1, min(limit, 500)))
            .map { $0 }
    }

    func mergeSearchHistory(
        _ data: Data,
        peerId: Int,
        ownerUserId: Int,
        complete: Bool
    ) {
        guard peerId > 0,
              ownerUserId > 0,
              let incoming = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let incomingItems = incoming["items"] as? [[String: Any]] else {
            return
        }

        historyLock.lock()
        defer { historyLock.unlock() }

        var indexedById = [Int: [String: Any]]()
        var wasComplete = false
        if let existingData = loadSearchHistoryUnlocked(peerId: peerId, ownerUserId: ownerUserId),
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            wasComplete = existing["complete"] as? Bool ?? false
            for item in existing["items"] as? [[String: Any]] ?? [] {
                let messageId = item["id"] as? Int ?? 0
                if messageId > 0 { indexedById[messageId] = item }
            }
        }
        for item in incomingItems {
            let messageId = item["id"] as? Int ?? 0
            if messageId > 0 { indexedById[messageId] = item }
        }
        let payload: [String: Any] = [
            "items": indexedById.values.sorted {
                ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0)
            },
            "complete": wasComplete || complete
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let root = try? ownerRootURL(ownerUserId: ownerUserId) else {
            return
        }
        try? writeEncrypted(
            encoded,
            to: root.appendingPathComponent("conversation-\(peerId)-search-v1.bin"),
            ownerUserId: ownerUserId
        )
    }

    func removeSearchMessages(
        peerId: Int,
        ownerUserId: Int,
        messageIds: Set<Int>
    ) {
        guard peerId > 0, ownerUserId > 0, !messageIds.isEmpty else { return }
        updateSearchHistory(peerId: peerId, ownerUserId: ownerUserId) { items in
            items.filter { item in
                !messageIds.contains(item["id"] as? Int ?? 0)
            }
        }
    }

    func reassignSearchHistoryTopic(
        peerId: Int,
        ownerUserId: Int,
        sourceTopicId: Int,
        targetTopicId: Int
    ) {
        guard peerId > 0,
              ownerUserId > 0,
              sourceTopicId > 0,
              targetTopicId > 0,
              sourceTopicId != targetTopicId else {
            return
        }
        updateSearchHistory(peerId: peerId, ownerUserId: ownerUserId) { items in
            items.map { item in
                guard item["topicId"] as? Int == sourceTopicId else { return item }
                var updated = item
                updated["topicId"] = targetTopicId
                return updated
            }
        }
    }

    func isSearchHistoryComplete(peerId: Int, ownerUserId: Int) -> Bool {
        historyLock.lock()
        defer { historyLock.unlock() }
        guard let data = loadSearchHistoryUnlocked(peerId: peerId, ownerUserId: ownerUserId),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["complete"] as? Bool ?? false
    }

    func markSearchHistoryComplete(peerId: Int, ownerUserId: Int) {
        guard peerId > 0, ownerUserId > 0 else { return }

        historyLock.lock()
        defer { historyLock.unlock() }

        let existing: [String: Any]
        if let data = loadSearchHistoryUnlocked(peerId: peerId, ownerUserId: ownerUserId),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = json
        } else {
            existing = [:]
        }
        let payload: [String: Any] = [
            "items": existing["items"] as? [[String: Any]] ?? [],
            "complete": true
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let root = try? ownerRootURL(ownerUserId: ownerUserId) else {
            return
        }
        try? writeEncrypted(
            encoded,
            to: root.appendingPathComponent("conversation-\(peerId)-search-v1.bin"),
            ownerUserId: ownerUserId
        )
    }

    func oldestSearchMessageId(peerId: Int, ownerUserId: Int) -> Int {
        historyLock.lock()
        defer { historyLock.unlock() }
        guard let data = loadSearchHistoryUnlocked(peerId: peerId, ownerUserId: ownerUserId),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        return (json["items"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? Int }
            .filter { $0 > 0 }
            .min() ?? 0
    }

    private func updateSearchHistory(
        peerId: Int,
        ownerUserId: Int,
        transform: ([[String: Any]]) -> [[String: Any]]
    ) {
        historyLock.lock()
        defer { historyLock.unlock() }
        guard let data = loadSearchHistoryUnlocked(peerId: peerId, ownerUserId: ownerUserId),
              let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let payload: [String: Any] = [
            "items": transform(existing["items"] as? [[String: Any]] ?? []),
            "complete": existing["complete"] as? Bool ?? false
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let root = try? ownerRootURL(ownerUserId: ownerUserId) else {
            return
        }
        try? writeEncrypted(
            encoded,
            to: root.appendingPathComponent("conversation-\(peerId)-search-v1.bin"),
            ownerUserId: ownerUserId
        )
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

    private func loadSearchHistory(peerId: Int, ownerUserId: Int) -> Data? {
        historyLock.lock()
        defer { historyLock.unlock() }
        return loadSearchHistoryUnlocked(peerId: peerId, ownerUserId: ownerUserId)
    }

    private func loadSearchHistoryUnlocked(peerId: Int, ownerUserId: Int) -> Data? {
        guard peerId > 0, ownerUserId > 0,
              let url = try? ownerRootURL(ownerUserId: ownerUserId)
                .appendingPathComponent("conversation-\(peerId)-search-v1.bin"),
              let combined = try? Data(contentsOf: url),
              let sealed = try? AES.GCM.SealedBox(combined: combined) else {
            return nil
        }
        return try? AES.GCM.open(sealed, using: encryptionKey())
    }

    private func matchesSearch(message: AloChatMessage, query: String) -> Bool {
        message.body.localizedCaseInsensitiveContains(query) ||
            message.attachmentName.localizedCaseInsensitiveContains(query) ||
            message.sender?.name.localizedCaseInsensitiveContains(query) == true
    }

    private func peerIdForConversationFile(_ fileName: String) -> Int? {
        let prefix = "conversation-"
        guard fileName.hasPrefix(prefix) else { return nil }
        for suffix in ["-search-v1.bin", "-v1.bin"] {
            guard fileName.hasSuffix(suffix) else { continue }
            let start = fileName.index(fileName.startIndex, offsetBy: prefix.count)
            let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
            let value = Int(fileName[start..<end]) ?? 0
            if value > 0 { return value }
        }
        return nil
    }

    private func remoteImageFileName(for cacheKey: String) -> String {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "remote-image-\(digest)-v1.bin"
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
