#if DEBUG
import CryptoKit
import Foundation
import LibSignalClient

enum AloLibSignalSelfTest {
    static func run() throws {
        let aliceStore = InMemorySignalProtocolStore()
        let bobStore = InMemorySignalProtocolStore()
        let alice = AloLibSignalSessionEngine(store: aliceStore, localUserId: 1, localDeviceId: 1)
        let bob = AloLibSignalSessionEngine(store: bobStore, localUserId: 2, localDeviceId: 1)

        let bobBundle = try bob.generatePreKeyBundle()
        try alice.processRemotePreKeyBundle(remoteUserId: 2, bundle: bobBundle)

        let first = Data("first pqxdh message".utf8)
        let firstCiphertext = try alice.encrypt(remoteUserId: 2, remoteDeviceId: 1, plaintext: first)
        try require(firstCiphertext.type == CiphertextMessage.MessageType.preKey.rawValue)
        try require(
            try bob.decrypt(
                remoteUserId: 1,
                remoteDeviceId: 1,
                ciphertextType: firstCiphertext.type,
                ciphertext: firstCiphertext.bytes
            ) == first
        )

        let reply = Data("double ratchet reply".utf8)
        let replyCiphertext = try bob.encrypt(remoteUserId: 1, remoteDeviceId: 1, plaintext: reply)
        try require(replyCiphertext.type == CiphertextMessage.MessageType.whisper.rawValue)
        try require(
            try alice.decrypt(
                remoteUserId: 2,
                remoteDeviceId: 1,
                ciphertextType: replyCiphertext.type,
                ciphertext: replyCiphertext.bytes
            ) == reply
        )

        let outOfOrder = try (0..<8).map { index in
            let plaintext = Data("message-\(index)".utf8)
            let encrypted = try alice.encrypt(remoteUserId: 2, remoteDeviceId: 1, plaintext: plaintext)
            return (plaintext, encrypted)
        }
        for index in [5, 1, 7, 0, 6, 3, 2, 4] {
            let item = outOfOrder[index]
            let opened = try bob.decrypt(
                remoteUserId: 1,
                remoteDeviceId: 1,
                ciphertextType: item.1.type,
                ciphertext: item.1.bytes
            )
            try require(opened == item.0)
        }

        let distributionId = UUID()
        let distribution = try alice.createSenderKeyDistribution(distributionId: distributionId)
        try bob.processSenderKeyDistribution(
            remoteUserId: 1,
            remoteDeviceId: 1,
            serialized: distribution
        )
        let groupPlaintext = Data("sender-key group message".utf8)
        let groupCiphertext = try alice.groupEncrypt(
            distributionId: distributionId,
            plaintext: groupPlaintext
        )
        try require(
            try bob.groupDecrypt(
                remoteUserId: 1,
                remoteDeviceId: 1,
                ciphertext: groupCiphertext
            ) == groupPlaintext
        )

        var reorderedGroupMessages = [(Data, Data, Data)]()
        for index in 0..<6 {
            let nextDistribution = try alice.createSenderKeyDistribution(distributionId: distributionId)
            let plaintext = Data("sender-key-\(index)".utf8)
            let ciphertext = try alice.groupEncrypt(
                distributionId: distributionId,
                plaintext: plaintext
            )
            reorderedGroupMessages.append((plaintext, nextDistribution, ciphertext))
        }
        for index in [4, 1, 5, 0, 3, 2] {
            let packet = reorderedGroupMessages[index]
            try bob.processSenderKeyDistribution(
                remoteUserId: 1,
                remoteDeviceId: 1,
                serialized: packet.1
            )
            try require(
                try bob.groupDecrypt(
                    remoteUserId: 1,
                    remoteDeviceId: 1,
                    ciphertext: packet.2
                ) == packet.0
            )
        }

        try runSecureMediaStoreTest()
    }

    private static func runSecureMediaStoreTest() throws {
        let plaintext = Data("secure-media-runtime-test".utf8)
        let keyData = Data((0..<32).map { UInt8($0) })
        let ivData = Data((0..<12).map { UInt8(32 + $0) })
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: ivData))
        let encrypted = sealed.ciphertext + sealed.tag
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let root = caches.appendingPathComponent("AloE2EEMedia", isDirectory: true)
        let encryptedRoot = root.appendingPathComponent("encrypted", isDirectory: true)
        try FileManager.default.createDirectory(at: encryptedRoot, withIntermediateDirectories: true)
        let encryptedURL = encryptedRoot.appendingPathComponent("runtime-self-test.bin")
        try encrypted.write(to: encryptedURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: encryptedURL) }

        let secureURL = try AloSecureMediaStore.shared.register(
            encryptedURL: encryptedURL,
            encryption: [
                "algorithm": "aes-256-gcm-v1",
                "key": base64URL(keyData),
                "iv": base64URL(ivData),
                "mime": "application/octet-stream"
            ],
            type: "file",
            name: "runtime.bin"
        )
        let payload = try AloSecureMediaStore.shared.payload(for: secureURL)
        try require(secureURL.scheme == AloSecureMediaStore.scheme)
        try require(payload.data == plaintext)
        try require(payload.mime == "application/octet-stream")
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("decoded").path))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool) throws {
        guard try condition() else { throw SelfTestError.assertionFailed }
    }

    private enum SelfTestError: Error {
        case assertionFailed
    }
}
#endif
