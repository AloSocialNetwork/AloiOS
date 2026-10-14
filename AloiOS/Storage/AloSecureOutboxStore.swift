import CryptoKit
import Foundation
import Security

final class AloSecureOutboxStore {
    static let shared = AloSecureOutboxStore()

    private let keychainService = "alo.ios.secure-outbox"
    private let keychainAccount = "outbox-key.v1"
    private let queueFileName = "queue-v1.bin"
    private let persistenceQueue = DispatchQueue(label: "alo.secure-outbox.persistence", qos: .utility)
    private let keyLock = NSLock()

    struct AttachmentWrite {
        let id: String
        let attachment: AloLocalAttachment
    }

    /// Enqueue synchronously so snapshots cannot overtake one another. The
    /// receipt is awaited before network delivery, not before rendering the
    /// optimistic message. Encryption/copies/JSON and disk writes stay off UI.
    func scheduleSave(records: [[String: Any]], attachments: [AttachmentWrite], ownerUserId: Int) -> Task<Void, Error> {
        let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        persistenceQueue.async { [self] in
            do {
                for write in attachments {
                    let attachment = write.attachment
                    if let source = attachment.encryptedSourceURL {
                        try saveChunkedAttachment(from: source, id: write.id, ownerUserId: ownerUserId)
                    } else {
                        // Immutable upload IDs: later queue/checkpoint snapshots
                        // must not repeatedly encrypt the same large photo.
                        let destination = try attachmentURL(id: write.id, ownerUserId: ownerUserId)
                        if !FileManager.default.fileExists(atPath: destination.path) {
                            try saveAttachment(attachment.data, id: write.id, ownerUserId: ownerUserId)
                        }
                    }
                }
                try save(records: records, ownerUserId: ownerUserId)
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        return Task { for try await _ in stream {} }
    }

    func scheduleAttachmentRemoval(ids: [String], drafts: [AloLocalAttachment] = [], ownerUserId: Int) {
        persistenceQueue.async { [self] in
            ids.forEach { deleteAttachment(id: $0, ownerUserId: ownerUserId) }
            drafts.forEach(AloDraftAttachmentStore.remove)
        }
    }

    func finishPendingWrites() async {
        await withCheckedContinuation { continuation in
            persistenceQueue.async { continuation.resume() }
        }
    }

    func scheduleClear(ownerUserId: Int) {
        // Logout must run after already-enqueued writes; otherwise a late
        // snapshot could recreate the logged-out account's outbox.
        persistenceQueue.async { [self] in clear(ownerUserId: ownerUserId) }
    }

    struct QuizRevealSecret {
        let correctOptionIds: Set<String>
        let salt: String
    }

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

    /// A quiz answer must remain available to its author until the quiz is
    /// closed, but it must never travel through the canonical poll API.
    func saveQuizReveal(
        pollId: String,
        correctOptionIds: Set<String>,
        salt: String,
        ownerUserId: Int
    ) throws {
        guard correctOptionIds.count == 1,
              correctOptionIds.allSatisfy(isSafeQuizOptionId),
              AloPollQuizCommitment.isValidSalt(salt) else {
            throw AloSecureOutboxError.invalidQuizReveal
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "correctOptionIds": Array(correctOptionIds).sorted(),
            "salt": salt
        ], options: [.sortedKeys])
        try writeEncrypted(
            data,
            to: try quizRevealURL(pollId: pollId, ownerUserId: ownerUserId),
            ownerUserId: ownerUserId
        )
    }

    func loadQuizReveal(pollId: String, ownerUserId: Int) -> QuizRevealSecret? {
        guard let data = try? readEncrypted(
            from: try quizRevealURL(pollId: pollId, ownerUserId: ownerUserId)
        ), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let correctOptionIds = Set((json["correctOptionIds"] as? [String]) ?? [])
        let salt = json["salt"] as? String ?? ""
        guard correctOptionIds.count == 1,
              correctOptionIds.allSatisfy(isSafeQuizOptionId),
              AloPollQuizCommitment.isValidSalt(salt) else { return nil }
        return QuizRevealSecret(correctOptionIds: correctOptionIds, salt: salt)
    }

    /// The input is already encrypted with the media key carried in the E2EE
    /// message payload. Copy it as ciphertext so offline retry never needs the
    /// original plaintext file again.
    func saveChunkedAttachment(
        from sourceURL: URL,
        id: String,
        ownerUserId: Int
    ) throws {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw AloSecureOutboxError.invalidAttachment
        }
        let destination = try chunkedAttachmentFileURL(id: id, ownerUserId: ownerUserId)
        try ensureRootDirectory(ownerUserId: ownerUserId)
        // A restored draft already points at its outbox file. Removing that
        // destination used to delete the source before trying to copy it.
        if source == destination.standardizedFileURL.resolvingSymlinksInPath() { return }
        // IDs are immutable per upload. Checkpoints/reactions must not recopy
        // every pending movie on each queue snapshot.
        if FileManager.default.fileExists(atPath: destination.path) {
            let stored = try destination.resourceValues(forKeys: [.fileSizeKey])
            guard stored.fileSize == values.fileSize else { throw AloSecureOutboxError.invalidAttachment }
            return
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw AloSecureOutboxError.attachmentCopyFailed
        }
        try protectAndExclude(destination)
    }

    func loadChunkedAttachmentURL(id: String, ownerUserId: Int) -> URL? {
        guard let url = try? chunkedAttachmentFileURL(id: id, ownerUserId: ownerUserId),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func saveUploadCheckpoint(
        _ checkpoint: AloResumableUploadCheckpoint,
        id: String,
        ownerUserId: Int
    ) throws {
        guard checkpoint.isValid else { throw AloSecureOutboxError.invalidCheckpoint }
        let data = try JSONSerialization.data(withJSONObject: [
            "uploadId": checkpoint.uploadId,
            "offset": checkpoint.offset,
            "total": checkpoint.total,
            "checksum": checkpoint.checksum
        ], options: [])
        try writeEncrypted(
            data,
            to: try uploadCheckpointURL(id: id, ownerUserId: ownerUserId),
            ownerUserId: ownerUserId
        )
    }

    func loadUploadCheckpoint(id: String, ownerUserId: Int) -> AloResumableUploadCheckpoint? {
        guard let data = try? readEncrypted(
            from: try uploadCheckpointURL(id: id, ownerUserId: ownerUserId)
        ),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let checkpoint = AloResumableUploadCheckpoint(
            uploadId: (json["uploadId"] as? String ?? "").lowercased(),
            offset: (json["offset"] as? NSNumber)?.int64Value ?? -1,
            total: (json["total"] as? NSNumber)?.int64Value ?? -1,
            checksum: (json["checksum"] as? String ?? "").lowercased()
        )
        return checkpoint.isValid ? checkpoint : nil
    }

    func deleteUploadCheckpoint(id: String, ownerUserId: Int) {
        if let url = try? uploadCheckpointURL(id: id, ownerUserId: ownerUserId) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func deleteAttachment(id: String, ownerUserId: Int) {
        if let url = try? attachmentURL(id: id, ownerUserId: ownerUserId) {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = try? chunkedAttachmentFileURL(id: id, ownerUserId: ownerUserId) {
            try? FileManager.default.removeItem(at: url)
        }
        deleteUploadCheckpoint(id: id, ownerUserId: ownerUserId)
    }

    func deleteQuizReveal(pollId: String, ownerUserId: Int) {
        if let url = try? quizRevealURL(pollId: pollId, ownerUserId: ownerUserId) {
            try? FileManager.default.removeItem(at: url)
        }
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
        try protectAndExclude(url)
    }

    private func readEncrypted(from url: URL) throws -> Data {
        let combined = try Data(contentsOf: url)
        let sealed = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealed, using: try encryptionKey())
    }

    private func encryptionKey() throws -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }
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
        guard updateStatus == errSecItemNotFound else {
            throw AloSecureOutboxError.keyStorageFailed(updateStatus)
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AloSecureOutboxError.keyStorageFailed(addStatus)
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
        try protectAndExclude(root)
    }

    private func attachmentURL(id: String, ownerUserId: Int) throws -> URL {
        let safeId = id.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard safeId.count >= 8 else { throw AloSecureOutboxError.invalidIdentifier }
        return try rootURL(ownerUserId: ownerUserId).appendingPathComponent("attachment-\(safeId).bin")
    }

    private func chunkedAttachmentFileURL(id: String, ownerUserId: Int) throws -> URL {
        let safeId = id.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard safeId.count >= 8 else { throw AloSecureOutboxError.invalidIdentifier }
        return try rootURL(ownerUserId: ownerUserId).appendingPathComponent("attachment-\(safeId).stream")
    }

    private func uploadCheckpointURL(id: String, ownerUserId: Int) throws -> URL {
        let safeId = id.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard safeId.count >= 8 else { throw AloSecureOutboxError.invalidIdentifier }
        return try rootURL(ownerUserId: ownerUserId).appendingPathComponent("upload-\(safeId).cursor")
    }

    private func quizRevealURL(pollId: String, ownerUserId: Int) throws -> URL {
        let safeId = pollId.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard safeId.count >= 8 else { throw AloSecureOutboxError.invalidIdentifier }
        return try rootURL(ownerUserId: ownerUserId).appendingPathComponent("quiz-\(safeId).reveal")
    }

    private func isSafeQuizOptionId(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }

    private func protectAndExclude(_ url: URL) throws {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedURL.setResourceValues(values)
    }
}

private enum AloSecureOutboxError: Error {
    case encryptionFailed
    case invalidIdentifier
    case keyStorageFailed(OSStatus)
    case invalidAttachment
    case attachmentCopyFailed
    case invalidCheckpoint
    case invalidQuizReveal
}
