import CryptoKit
import Foundation
import LibSignalClient
import Security

struct AloLibSignalStoreContext: StoreContext {}

final class AloLibSignalStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
    KyberPreKeyStore, SessionStore, SenderKeyStore
{
    private static let service = "com.alo.ios.libsignal.v1"
    private static let wrappingKeyAccount = "state-wrapping-key"

    private let lock = NSRecursiveLock()
    private let namespace: String
    private let rootURL: URL

    init(namespace: String = "primary") throws {
        self.namespace = namespace

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = appSupport
            .appendingPathComponent("AloLibSignal", isDirectory: true)
            .appendingPathComponent(namespaceToken(namespace), isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(resourceValues)
        self.rootURL = root
    }

    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        try synchronized {
            if let stored = try readRecord("identity-pair") {
                return try IdentityKeyPair(bytes: stored)
            }
            let pair = IdentityKeyPair.generate()
            try writeRecord(pair.serialize(), key: "identity-pair")
            return pair
        }
    }

    func localRegistrationId(context: StoreContext) throws -> UInt32 {
        try synchronized {
            if let stored = try readRecord("registration-id"), stored.count == 4 {
                return stored.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
            let registrationId = UInt32.random(in: 1...16_380)
            let bytes = Data([
                UInt8((registrationId >> 24) & 0xff),
                UInt8((registrationId >> 16) & 0xff),
                UInt8((registrationId >> 8) & 0xff),
                UInt8(registrationId & 0xff),
            ])
            try writeRecord(bytes, key: "registration-id")
            return registrationId
        }
    }

    func saveIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        try synchronized {
            let key = remoteIdentityStorageKey(address)
            let previous = try readRecord(key).flatMap { try? IdentityKey(bytes: $0) }
            try writeRecord(identity.serialize(), key: key)
            return previous == nil || previous == identity ? .newOrUnchanged : .replacedExisting
        }
    }

    func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        try synchronized {
            guard let stored = try readRecord(remoteIdentityStorageKey(address)) else { return true }
            return try IdentityKey(bytes: stored) == identity
        }
    }

    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        try synchronized {
            guard let stored = try readRecord(remoteIdentityStorageKey(address)) else { return nil }
            return try IdentityKey(bytes: stored)
        }
    }

    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        try synchronized {
            guard let stored = try readRecord(preKeyStorageKey(id)) else {
                throw SignalError.invalidKeyIdentifier("Missing libsignal prekey \(id)")
            }
            return try PreKeyRecord(bytes: stored)
        }
    }

    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try synchronized { try writeRecord(record.serialize(), key: preKeyStorageKey(id)) }
    }

    func removePreKey(id: UInt32, context: StoreContext) throws {
        try synchronized { try removeRecord(preKeyStorageKey(id)) }
    }

    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        try synchronized {
            guard let stored = try readRecord(signedPreKeyStorageKey(id)) else {
                throw SignalError.invalidKeyIdentifier("Missing libsignal signed prekey \(id)")
            }
            return try SignedPreKeyRecord(bytes: stored)
        }
    }

    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try synchronized { try writeRecord(record.serialize(), key: signedPreKeyStorageKey(id)) }
    }

    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        try synchronized {
            guard let stored = try readRecord(kyberPreKeyStorageKey(id)) else {
                throw SignalError.invalidKeyIdentifier("Missing libsignal Kyber prekey \(id)")
            }
            return try KyberPreKeyRecord(bytes: stored)
        }
    }

    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try synchronized { try writeRecord(record.serialize(), key: kyberPreKeyStorageKey(id)) }
    }

    func markKyberPreKeyUsed(
        id: UInt32,
        signedPreKeyId: UInt32,
        baseKey: PublicKey,
        context: StoreContext
    ) throws {
        try synchronized {
            guard try readRecord(kyberPreKeyStorageKey(id)) != nil else {
                throw SignalError.invalidKeyIdentifier("Missing libsignal Kyber prekey \(id)")
            }
            let baseKeyDigest = SHA256.hash(data: baseKey.serialize()).hexString
            let replayKey = "kyber-use.\(id).\(signedPreKeyId).\(baseKeyDigest)"
            if try readRecord(replayKey) != nil {
                throw SignalError.invalidMessage("Reused libsignal Kyber base key")
            }
            try writeRecord(Data([1]), key: replayKey)
        }
    }

    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        try synchronized {
            guard let stored = try readRecord(sessionStorageKey(address)) else { return nil }
            return try SessionRecord(bytes: stored)
        }
    }

    func loadExistingSessions(
        for addresses: [ProtocolAddress],
        context: StoreContext
    ) throws -> [SessionRecord] {
        try synchronized {
            try addresses.map { address in
                guard let stored = try readRecord(sessionStorageKey(address)) else {
                    throw SignalError.sessionNotFound("Missing libsignal session for \(address.debugDescription)")
                }
                return try SessionRecord(bytes: stored)
            }
        }
    }

    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try synchronized { try writeRecord(record.serialize(), key: sessionStorageKey(address)) }
    }

    func storeSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
        context: StoreContext
    ) throws {
        try synchronized {
            try writeRecord(record.serialize(), key: senderKeyStorageKey(sender, distributionId))
        }
    }

    func loadSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        context: StoreContext
    ) throws -> SenderKeyRecord? {
        try synchronized {
            guard let stored = try readRecord(senderKeyStorageKey(sender, distributionId)) else { return nil }
            return try SenderKeyRecord(bytes: stored)
        }
    }

    func identityFingerprint() throws -> String {
        let identity = try identityKeyPair(context: AloLibSignalStoreContext()).publicKey.serialize()
        return SHA256.hash(data: identity).hexString.chunked(every: 5).joined(separator: "-")
    }

    func storeMessagePlaintext(contextId: String, plaintext: Data) throws {
        guard contextId.range(of: "^[a-zA-Z0-9_-]{12,160}$", options: .regularExpression) != nil else {
            throw AloLibSignalStoreError.invalidContextId
        }
        try synchronized { try writeRecord(plaintext, key: messagePlaintextStorageKey(contextId)) }
    }

    func loadMessagePlaintext(contextId: String) throws -> Data? {
        guard contextId.range(of: "^[a-zA-Z0-9_-]{12,160}$", options: .regularExpression) != nil else {
            return nil
        }
        return try synchronized { try readRecord(messagePlaintextStorageKey(contextId)) }
    }

    private func sessionStorageKey(_ address: ProtocolAddress) -> String {
        "session.\(address.name).\(address.deviceId)"
    }

    private func remoteIdentityStorageKey(_ address: ProtocolAddress) -> String {
        "remote-identity.\(address.name).\(address.deviceId)"
    }

    private func preKeyStorageKey(_ id: UInt32) -> String { "prekey.\(id)" }

    private func signedPreKeyStorageKey(_ id: UInt32) -> String { "signed-prekey.\(id)" }

    private func kyberPreKeyStorageKey(_ id: UInt32) -> String { "kyber-prekey.\(id)" }

    private func senderKeyStorageKey(_ sender: ProtocolAddress, _ distributionId: UUID) -> String {
        "sender-key.\(sender.name).\(sender.deviceId).\(distributionId.uuidString.lowercased())"
    }

    private func messagePlaintextStorageKey(_ contextId: String) -> String { "plaintext.\(contextId)" }

    private func readRecord(_ key: String) throws -> Data? {
        let url = recordURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let combined = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: wrappingKey(), authenticating: Data(key.utf8))
    }

    private func writeRecord(_ data: Data, key: String) throws {
        let sealed = try AES.GCM.seal(data, using: wrappingKey(), authenticating: Data(key.utf8))
        guard let combined = sealed.combined else { throw AloLibSignalStoreError.encryptionFailed }
        let url = recordURL(for: key)
        try combined.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func removeRecord(_ key: String) throws {
        let url = recordURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func recordURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).hexString
        return rootURL.appendingPathComponent("\(digest).state", isDirectory: false)
    }

    private func wrappingKey() throws -> SymmetricKey {
        if let stored = try readKeychainData(), stored.count == 32 {
            return SymmetricKey(data: stored)
        }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw AloLibSignalStoreError.randomGenerationFailed }
        try storeKeychainData(bytes)
        return SymmetricKey(data: bytes)
    }

    private func readKeychainData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "\(Self.wrappingKeyAccount).\(namespace)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AloLibSignalStoreError.keychain(status)
        }
        return data
    }

    private func storeKeychainData(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "\(Self.wrappingKeyAccount).\(namespace)",
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AloLibSignalStoreError.keychain(update) }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(attributes as CFDictionary, nil)
        guard add == errSecSuccess else { throw AloLibSignalStoreError.keychain(add) }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private enum AloLibSignalStoreError: Error {
    case encryptionFailed
    case invalidContextId
    case keychain(OSStatus)
    case randomGenerationFailed
}

private func namespaceToken(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).hexString
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    func chunked(every length: Int) -> [String] {
        guard length > 0 else { return [self] }
        return stride(from: 0, to: count, by: length).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: Swift.min(length, count - offset))
            return String(self[start..<end])
        }
    }
}
