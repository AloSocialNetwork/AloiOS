import CryptoKit
import Foundation
import LibSignalClient

struct AloLibSignalPreKeyBundle: Codable, Equatable {
    let registrationId: UInt32
    let deviceId: UInt32
    let identityKey: Data
    let preKeyId: UInt32
    let preKey: Data
    let signedPreKeyId: UInt32
    let signedPreKey: Data
    let signedPreKeySignature: Data
    let kyberPreKeyId: UInt32
    let kyberPreKey: Data
    let kyberPreKeySignature: Data
}

struct AloLibSignalCiphertext: Codable, Equatable {
    let type: UInt8
    let bytes: Data
}

struct AloLibSignalOneTimePreKey: Codable, Equatable {
    let preKeyId: UInt32
    let preKey: Data
    let kyberPreKeyId: UInt32
    let kyberPreKey: Data
    let kyberPreKeySignature: Data
}

struct AloLibSignalDeviceBundle: Codable, Equatable {
    let registrationId: UInt32
    let protocolDeviceId: UInt32
    let identityKey: Data
    let signedPreKeyId: UInt32
    let signedPreKey: Data
    let signedPreKeySignature: Data
    let preKeys: [AloLibSignalOneTimePreKey]
}

final class AloLibSignalSessionEngine {
    private let identityStore: any IdentityKeyStore
    private let preKeyStore: any PreKeyStore
    private let signedPreKeyStore: any SignedPreKeyStore
    private let kyberPreKeyStore: any KyberPreKeyStore
    private let sessionStore: any SessionStore
    private let senderKeyStore: any SenderKeyStore
    private let localUserId: Int
    let localDeviceId: UInt32

    private let context = AloLibSignalStoreContext()
    private let lock = NSRecursiveLock()

    init<Store>(store: Store, localUserId: Int, localDeviceId: UInt32)
    where Store: IdentityKeyStore, Store: PreKeyStore, Store: SignedPreKeyStore,
        Store: KyberPreKeyStore, Store: SessionStore, Store: SenderKeyStore
    {
        precondition(localUserId > 0)
        precondition((1...127).contains(localDeviceId))
        self.identityStore = store
        self.preKeyStore = store
        self.signedPreKeyStore = store
        self.kyberPreKeyStore = store
        self.sessionStore = store
        self.senderKeyStore = store
        self.localUserId = localUserId
        self.localDeviceId = localDeviceId
    }

    func generatePreKeyBundle() throws -> AloLibSignalPreKeyBundle {
        let bundle = try generateDeviceBundle(preKeyCount: 1)
        let oneTime = bundle.preKeys[0]
        return AloLibSignalPreKeyBundle(
            registrationId: bundle.registrationId,
            deviceId: bundle.protocolDeviceId,
            identityKey: bundle.identityKey,
            preKeyId: oneTime.preKeyId,
            preKey: oneTime.preKey,
            signedPreKeyId: bundle.signedPreKeyId,
            signedPreKey: bundle.signedPreKey,
            signedPreKeySignature: bundle.signedPreKeySignature,
            kyberPreKeyId: oneTime.kyberPreKeyId,
            kyberPreKey: oneTime.kyberPreKey,
            kyberPreKeySignature: oneTime.kyberPreKeySignature
        )
    }

    func generateDeviceBundle(preKeyCount: Int) throws -> AloLibSignalDeviceBundle {
        try synchronized {
            guard (1...80).contains(preKeyCount) else { throw AloLibSignalSessionError.invalidPreKeyCount }
            let identity = try identityStore.identityKeyPair(context: context)
            let signedPreKeyId = randomKeyId()
            let signedPreKeyPrivate = PrivateKey.generate()
            let signedPreKeySignature = identity.privateKey.generateSignature(
                message: signedPreKeyPrivate.publicKey.serialize()
            )
            let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000)
            try signedPreKeyStore.storeSignedPreKey(
                SignedPreKeyRecord(
                    id: signedPreKeyId,
                    timestamp: timestamp,
                    privateKey: signedPreKeyPrivate,
                    signature: signedPreKeySignature
                ),
                id: signedPreKeyId,
                context: context
            )

            let preKeys = try (0..<preKeyCount).map { _ in
                let preKeyId = randomKeyId()
                let kyberPreKeyId = randomKeyId()
                let preKeyPrivate = PrivateKey.generate()
                let kyberPreKeyPair = KEMKeyPair.generate()
                let kyberPreKeySignature = identity.privateKey.generateSignature(
                    message: kyberPreKeyPair.publicKey.serialize()
                )
                try preKeyStore.storePreKey(
                    PreKeyRecord(id: preKeyId, privateKey: preKeyPrivate),
                    id: preKeyId,
                    context: context
                )
                try kyberPreKeyStore.storeKyberPreKey(
                    KyberPreKeyRecord(
                        id: kyberPreKeyId,
                        timestamp: timestamp,
                        keyPair: kyberPreKeyPair,
                        signature: kyberPreKeySignature
                    ),
                    id: kyberPreKeyId,
                    context: context
                )
                return AloLibSignalOneTimePreKey(
                    preKeyId: preKeyId,
                    preKey: preKeyPrivate.publicKey.serialize(),
                    kyberPreKeyId: kyberPreKeyId,
                    kyberPreKey: kyberPreKeyPair.publicKey.serialize(),
                    kyberPreKeySignature: kyberPreKeySignature
                )
            }
            return AloLibSignalDeviceBundle(
                registrationId: try identityStore.localRegistrationId(context: context),
                protocolDeviceId: localDeviceId,
                identityKey: identity.publicKey.serialize(),
                signedPreKeyId: signedPreKeyId,
                signedPreKey: signedPreKeyPrivate.publicKey.serialize(),
                signedPreKeySignature: signedPreKeySignature,
                preKeys: preKeys
            )
        }
    }

    func processRemotePreKeyBundle(remoteUserId: Int, bundle: AloLibSignalPreKeyBundle) throws {
        try synchronized {
            let remoteAddress = try protocolAddress(userId: remoteUserId, deviceId: bundle.deviceId)
            let remoteBundle = try PreKeyBundle(
                registrationId: bundle.registrationId,
                deviceId: bundle.deviceId,
                prekeyId: bundle.preKeyId,
                prekey: PublicKey(bundle.preKey),
                signedPrekeyId: bundle.signedPreKeyId,
                signedPrekey: PublicKey(bundle.signedPreKey),
                signedPrekeySignature: bundle.signedPreKeySignature,
                identity: IdentityKey(bytes: bundle.identityKey),
                kyberPrekeyId: bundle.kyberPreKeyId,
                kyberPrekey: KEMPublicKey(bundle.kyberPreKey),
                kyberPrekeySignature: bundle.kyberPreKeySignature
            )
            try processPreKeyBundle(
                remoteBundle,
                for: remoteAddress,
                ourAddress: localAddress,
                sessionStore: sessionStore,
                identityStore: identityStore,
                context: context
            )
        }
    }

    func hasSession(remoteUserId: Int, remoteDeviceId: UInt32) -> Bool {
        synchronized {
            guard let address = try? protocolAddress(userId: remoteUserId, deviceId: remoteDeviceId) else {
                return false
            }
            return (try? sessionStore.loadSession(for: address, context: context)) != nil
        }
    }

    func encrypt(remoteUserId: Int, remoteDeviceId: UInt32, plaintext: Data) throws -> AloLibSignalCiphertext {
        try synchronized {
            let ciphertext = try signalEncrypt(
                message: plaintext,
                for: protocolAddress(userId: remoteUserId, deviceId: remoteDeviceId),
                localAddress: localAddress,
                sessionStore: sessionStore,
                identityStore: identityStore,
                context: context
            )
            return AloLibSignalCiphertext(type: ciphertext.messageType.rawValue, bytes: ciphertext.serialize())
        }
    }

    func decrypt(
        remoteUserId: Int,
        remoteDeviceId: UInt32,
        ciphertextType: UInt8,
        ciphertext: Data
    ) throws -> Data {
        try synchronized {
            let remoteAddress = try protocolAddress(userId: remoteUserId, deviceId: remoteDeviceId)
            switch CiphertextMessage.MessageType(rawValue: ciphertextType) {
            case .preKey:
                return try signalDecryptPreKey(
                    message: PreKeySignalMessage(bytes: ciphertext),
                    from: remoteAddress,
                    localAddress: localAddress,
                    sessionStore: sessionStore,
                    identityStore: identityStore,
                    preKeyStore: preKeyStore,
                    signedPreKeyStore: signedPreKeyStore,
                    kyberPreKeyStore: kyberPreKeyStore,
                    context: context
                )
            case .whisper:
                return try signalDecrypt(
                    message: SignalMessage(bytes: ciphertext),
                    from: remoteAddress,
                    to: localAddress,
                    sessionStore: sessionStore,
                    identityStore: identityStore,
                    context: context
                )
            default:
                throw AloLibSignalSessionError.unsupportedCiphertextType(ciphertextType)
            }
        }
    }

    func createSenderKeyDistribution(distributionId: UUID) throws -> Data {
        try synchronized {
            try SenderKeyDistributionMessage(
                from: localAddress,
                distributionId: distributionId,
                store: senderKeyStore,
                context: context
            ).serialize()
        }
    }

    func processSenderKeyDistribution(
        remoteUserId: Int,
        remoteDeviceId: UInt32,
        serialized: Data
    ) throws {
        try synchronized {
            try processSenderKeyDistributionMessage(
                SenderKeyDistributionMessage(bytes: serialized),
                from: protocolAddress(userId: remoteUserId, deviceId: remoteDeviceId),
                store: senderKeyStore,
                context: context
            )
        }
    }

    func groupEncrypt(distributionId: UUID, plaintext: Data) throws -> Data {
        try synchronized {
            try LibSignalClient.groupEncrypt(
                plaintext,
                from: localAddress,
                distributionId: distributionId,
                store: senderKeyStore,
                context: context
            ).serialize()
        }
    }

    func groupDecrypt(remoteUserId: Int, remoteDeviceId: UInt32, ciphertext: Data) throws -> Data {
        try synchronized {
            try LibSignalClient.groupDecrypt(
                ciphertext,
                from: protocolAddress(userId: remoteUserId, deviceId: remoteDeviceId),
                store: senderKeyStore,
                context: context
            )
        }
    }

    private var localAddress: ProtocolAddress {
        get throws { try protocolAddress(userId: localUserId, deviceId: localDeviceId) }
    }

    private func protocolAddress(userId: Int, deviceId: UInt32) throws -> ProtocolAddress {
        guard userId > 0 else { throw AloLibSignalSessionError.invalidUserId }
        guard (1...127).contains(deviceId) else { throw AloLibSignalSessionError.invalidDeviceId }
        return try ProtocolAddress(name: "alo-user-\(userId)", deviceId: deviceId)
    }

    private func randomKeyId() -> UInt32 {
        UInt32.random(in: 1...0x00ff_ffff)
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private enum AloLibSignalSessionError: Error {
    case invalidDeviceId
    case invalidPreKeyCount
    case invalidUserId
    case unsupportedCiphertextType(UInt8)
}
