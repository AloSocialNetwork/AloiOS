import CryptoKit
import Foundation
import Security

struct AloCallSecurityV2KeyPair {
    let privateKey: Data
    let publicKey: Data
}

final class AloCallSecurityHandshake {
    enum Role {
        case caller
        case callee
    }

    let role: Role
    let callId: Int
    let callerId: Int
    let calleeId: Int
    let localKeyPair: AloCallSecurityV2KeyPair
    let localNonce: Data

    var callerCommitment: Data?
    var remotePublicKey: Data?
    var remoteNonce: Data?
    var sharedKey: Data?
    var offerFingerprint = ""
    var answerFingerprint = ""
    var transcriptHash: Data?
    var didAccept = false
    var didSendCommit = false
    var didSendResponse = false
    var didStartOffer = false
    var didSendConfirm = false
    var isConfirmed = false
    var reconnectGeneration = 0
    var lastHandledReconnectGeneration = 0
    var reconnectOfferHash: Data?

    init(
        role: Role,
        callId: Int,
        callerId: Int,
        calleeId: Int
    ) throws {
        guard callId > 0, callerId > 0, calleeId > 0, callerId != calleeId else {
            throw AloCallSecurityV2Error.invalidPayload
        }
        self.role = role
        self.callId = callId
        self.callerId = callerId
        self.calleeId = calleeId
        self.localKeyPair = AloCallSecurityV2.generateKeyPair()
        self.localNonce = try AloCallSecurityV2.randomNonce()
        if role == .caller {
            self.callerCommitment = try AloCallSecurityV2.commitment(
                callId: callId,
                callerId: callerId,
                calleeId: calleeId,
                callerPublicKey: localKeyPair.publicKey,
                callerNonce: localNonce
            )
        }
    }

    var callerPublicKey: Data? {
        role == .caller ? localKeyPair.publicKey : remotePublicKey
    }

    var callerNonce: Data? {
        role == .caller ? localNonce : remoteNonce
    }

    var calleePublicKey: Data? {
        role == .callee ? localKeyPair.publicKey : remotePublicKey
    }

    var calleeNonce: Data? {
        role == .callee ? localNonce : remoteNonce
    }

    func deriveSharedKeyIfPossible() throws -> Data {
        if let sharedKey { return sharedKey }
        guard let remotePublicKey else {
            throw AloCallSecurityV2Error.invalidPayload
        }
        let key = try AloCallSecurityV2.sharedKey(
            privateKey: localKeyPair.privateKey,
            remotePublicKey: remotePublicKey,
            callId: callId,
            callerId: callerId,
            calleeId: calleeId
        )
        sharedKey = key
        return key
    }
}

enum AloCallSecurityV2Error: LocalizedError {
    case invalidKey
    case invalidPayload
    case missingDTLSFingerprint
    case keyAgreementFailed

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            "Некорректный одноразовый ключ звонка."
        case .invalidPayload:
            "Повреждены данные проверки звонка."
        case .missingDTLSFingerprint:
            "Не удалось проверить DTLS-отпечаток звонка."
        case .keyAgreementFailed:
            "Не удалось согласовать ключ звонка."
        }
    }
}

enum AloCallSecurityV2 {
    static let version = 2
    static let encodedByteCount = 43

    static func generateKeyPair() -> AloCallSecurityV2KeyPair {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return AloCallSecurityV2KeyPair(
            privateKey: privateKey.rawRepresentation,
            publicKey: privateKey.publicKey.rawRepresentation
        )
    }

    static func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AloCallSecurityV2Error.invalidPayload
        }
        return Data(bytes)
    }

    static func sharedKey(
        privateKey: Data,
        remotePublicKey: Data,
        callId: Int,
        callerId: Int,
        calleeId: Int
    ) throws -> Data {
        guard privateKey.count == 32, remotePublicKey.count == 32 else {
            throw AloCallSecurityV2Error.invalidKey
        }
        let local = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let rawSecret = try local.sharedSecretFromKeyAgreement(with: remote)
        let salt = SHA256.hash(data: canonicalData(
            label: "kdf",
            fields: [
                ("call-id", String(callId)),
                ("caller-id", String(callerId)),
                ("callee-id", String(calleeId))
            ]
        ))
        let derived = rawSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(salt),
            sharedInfo: Data("alo-call-security-v2/shared-key".utf8),
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    static func commitment(
        callId: Int,
        callerId: Int,
        calleeId: Int,
        callerPublicKey: Data,
        callerNonce: Data
    ) throws -> Data {
        try require32(callerPublicKey)
        try require32(callerNonce)
        return Data(SHA256.hash(data: canonicalData(
            label: "commit",
            fields: [
                ("call-id", String(callId)),
                ("caller-id", String(callerId)),
                ("callee-id", String(calleeId)),
                ("caller-public", base64URL(callerPublicKey)),
                ("caller-nonce", base64URL(callerNonce))
            ]
        )))
    }

    static func offerTranscriptHash(
        callId: Int,
        callerId: Int,
        calleeId: Int,
        callerCommitment: Data,
        callerPublicKey: Data,
        callerNonce: Data,
        calleePublicKey: Data,
        calleeNonce: Data,
        offerFingerprint: String
    ) throws -> Data {
        try requireHandshakeValues(
            callerCommitment,
            callerPublicKey,
            callerNonce,
            calleePublicKey,
            calleeNonce
        )
        guard isNormalizedFingerprint(offerFingerprint) else {
            throw AloCallSecurityV2Error.missingDTLSFingerprint
        }
        return Data(SHA256.hash(data: canonicalData(
            label: "offer-transcript",
            fields: [
                ("call-id", String(callId)),
                ("caller-id", String(callerId)),
                ("callee-id", String(calleeId)),
                ("caller-commitment", base64URL(callerCommitment)),
                ("caller-public", base64URL(callerPublicKey)),
                ("caller-nonce", base64URL(callerNonce)),
                ("callee-public", base64URL(calleePublicKey)),
                ("callee-nonce", base64URL(calleeNonce)),
                ("offer-dtls", offerFingerprint)
            ]
        )))
    }

    static func transcriptHash(
        callId: Int,
        callerId: Int,
        calleeId: Int,
        callerCommitment: Data,
        callerPublicKey: Data,
        callerNonce: Data,
        calleePublicKey: Data,
        calleeNonce: Data,
        offerFingerprint: String,
        answerFingerprint: String
    ) throws -> Data {
        try requireHandshakeValues(
            callerCommitment,
            callerPublicKey,
            callerNonce,
            calleePublicKey,
            calleeNonce
        )
        guard isNormalizedFingerprint(offerFingerprint),
              isNormalizedFingerprint(answerFingerprint) else {
            throw AloCallSecurityV2Error.missingDTLSFingerprint
        }
        return Data(SHA256.hash(data: canonicalData(
            label: "transcript",
            fields: [
                ("call-id", String(callId)),
                ("caller-id", String(callerId)),
                ("callee-id", String(calleeId)),
                ("caller-commitment", base64URL(callerCommitment)),
                ("caller-public", base64URL(callerPublicKey)),
                ("caller-nonce", base64URL(callerNonce)),
                ("callee-public", base64URL(calleePublicKey)),
                ("callee-nonce", base64URL(calleeNonce)),
                ("offer-dtls", offerFingerprint),
                ("answer-dtls", answerFingerprint)
            ]
        )))
    }

    static func proof(sharedKey: Data, role: String, transcriptHash: Data) throws -> Data {
        try require32(sharedKey)
        try require32(transcriptHash)
        guard [
            "caller-offer",
            "callee-answer",
            "caller-confirm",
            "caller-reconnect-offer",
            "callee-reconnect-answer"
        ].contains(role) else {
            throw AloCallSecurityV2Error.invalidPayload
        }
        var material = Data("alo-call-security-v2/proof/\(role)\n".utf8)
        material.append(transcriptHash)
        let authentication = HMAC<SHA256>.authenticationCode(
            for: material,
            using: SymmetricKey(data: sharedKey)
        )
        return Data(authentication)
    }

    static func reconnectTranscriptHash(
        callId: Int,
        generation: Int,
        initialTranscriptHash: Data,
        offerFingerprint: String,
        offerSdpHash: Data,
        answerFingerprint: String? = nil,
        answerSdpHash: Data? = nil
    ) throws -> Data {
        guard callId > 0, generation > 0 else {
            throw AloCallSecurityV2Error.invalidPayload
        }
        try require32(initialTranscriptHash)
        try require32(offerSdpHash)
        guard isNormalizedFingerprint(offerFingerprint) else {
            throw AloCallSecurityV2Error.missingDTLSFingerprint
        }
        var fields: [(String, String)] = [
            ("call-id", String(callId)),
            ("generation", String(generation)),
            ("initial-transcript", base64URL(initialTranscriptHash)),
            ("offer-dtls", offerFingerprint),
            ("offer-sdp", base64URL(offerSdpHash))
        ]
        if let answerFingerprint, let answerSdpHash {
            try require32(answerSdpHash)
            guard isNormalizedFingerprint(answerFingerprint) else {
                throw AloCallSecurityV2Error.missingDTLSFingerprint
            }
            fields.append(("answer-dtls", answerFingerprint))
            fields.append(("answer-sdp", base64URL(answerSdpHash)))
        } else if answerFingerprint != nil || answerSdpHash != nil {
            throw AloCallSecurityV2Error.invalidPayload
        }
        return Data(SHA256.hash(data: canonicalData(
            label: answerFingerprint == nil ? "reconnect-offer" : "reconnect-answer",
            fields: fields
        )))
    }

    static func sdpHash(_ sdp: String) -> Data {
        Data(SHA256.hash(data: Data(sdp.utf8)))
    }

    static func emojis(
        sharedKey: Data,
        transcriptHash: Data,
        callerPublicKey: Data
    ) throws -> [String] {
        try require32(sharedKey)
        try require32(transcriptHash)
        try require32(callerPublicKey)
        var material = Data("alo-call-security-v2/emoji\n".utf8)
        material.append(transcriptHash)
        material.append(callerPublicKey)
        let digest = Data(HMAC<SHA256>.authenticationCode(
            for: material,
            using: SymmetricKey(data: sharedKey)
        ))
        return stride(from: 0, to: 32, by: 8).map { offset in
            var value: UInt64 = 0
            for byte in digest[offset..<(offset + 8)] {
                value = (value << 8) | UInt64(byte)
            }
            value &= 0x7fff_ffff_ffff_ffff
            return emojiTable[Int(value % UInt64(emojiTable.count))]
        }
    }

    static func dtlsFingerprint(from sdp: String) -> String? {
        for rawLine in sdp.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("a=fingerprint:") else { continue }
            let value = String(line.dropFirst("a=fingerprint:".count))
            let components = value.split(
                maxSplits: 1,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard components.count == 2,
                  components[0].lowercased() == "sha-256" else {
                continue
            }
            let hex = components[1]
                .replacingOccurrences(of: ":", with: "")
                .uppercased()
            guard hex.count == 64,
                  hex.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "0123456789ABCDEF").contains($0)
                  }) else {
                continue
            }
            return "sha-256:\(hex)"
        }
        return nil
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode32(_ value: String) throws -> Data {
        var encoded = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: encoded), data.count == 32 else {
            throw AloCallSecurityV2Error.invalidPayload
        }
        return data
    }

    static func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func requireHandshakeValues(_ values: Data...) throws {
        for value in values {
            try require32(value)
        }
    }

    private static func require32(_ data: Data) throws {
        guard data.count == 32 else {
            throw AloCallSecurityV2Error.invalidPayload
        }
    }

    private static func isNormalizedFingerprint(_ value: String) -> Bool {
        guard value.hasPrefix("sha-256:"), value.count == 72 else { return false }
        return value.dropFirst("sha-256:".count).unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789ABCDEF").contains($0)
        }
    }

    private static func canonicalData(
        label: String,
        fields: [(String, String)]
    ) -> Data {
        var value = "alo-call-security-v2/\(label)\n"
        for field in fields {
            value += "\(field.0)=\(field.1)\n"
        }
        return Data(value.utf8)
    }

    private static let emojiTable = [
        "😉", "😍", "😛", "😭", "😱", "😡", "😎", "😴", "😵", "😈", "😬", "😇", "😏", "👮", "👷", "💂",
        "👶", "👨", "👩", "👴", "👵", "😻", "😽", "🙀", "👺", "🙈", "🙉", "🙊", "💀", "👽", "💩", "🔥",
        "💥", "💤", "👂", "👀", "👃", "👅", "👄", "👍", "👎", "👌", "👊", "✌", "✋", "👐", "👆", "👇",
        "👉", "👈", "🙏", "👏", "💪", "🚶", "🏃", "💃", "👫", "👨‍👩‍👦", "👬", "👭", "💅", "🎩", "👑", "👒", "👟",
        "👞", "👠", "👕", "👗", "👖", "👙", "👜", "👓", "🎀", "💄", "💛", "💙", "💜", "💚", "💍", "💎",
        "🐶", "🐺", "🐱", "🐭", "🐹", "🐰", "🐸", "🐯", "🐨", "🐻", "🐷", "🐮", "🐗", "🐴", "🐑", "🐘",
        "🐼", "🐧", "🐥", "🐔", "🐍", "🐢", "🐛", "🐝", "🐜", "🐞", "🐌", "🐙", "🐚", "🐟", "🐬", "🐋",
        "🐐", "🐊", "🐫", "🍀", "🌹", "🌻", "🍁", "🌾", "🍄", "🌵", "🌴", "🌳", "🌞", "🌚", "🌙", "🌎",
        "🌋", "⚡", "☔", "❄", "⛄", "🌀", "🌈", "🌊", "🎓", "🎆", "🎃", "👻", "🎅", "🎄", "🎁", "🎈",
        "🔮", "🎥", "📷", "💿", "💻", "☎", "📡", "📺", "📻", "🔉", "🔔", "⏳", "⏰", "⌚", "🔒", "🔑",
        "🔎", "💡", "🔦", "🔌", "🔋", "🚿", "🚽", "🔧", "🔨", "🚪", "🚬", "💣", "🔫", "🔪", "💊", "💉",
        "💰", "💵", "💳", "✉", "📫", "📦", "📅", "📁", "✂", "📌", "📎", "✒", "✏", "📐", "📚", "🔬",
        "🔭", "🎨", "🎬", "🎤", "🎧", "🎵", "🎹", "🎻", "🎺", "🎸", "👾", "🎮", "🃏", "🎲", "🎯", "🏈",
        "🏀", "⚽", "⚾", "🎾", "🎱", "🏉", "🎳", "🏁", "🏇", "🏆", "🏊", "🏄", "☕", "🍼", "🍺", "🍷",
        "🍴", "🍕", "🍔", "🍟", "🍗", "🍱", "🍚", "🍜", "🍡", "🍳", "🍞", "🍩", "🍦", "🎂", "🍰", "🍪",
        "🍫", "🍭", "🍯", "🍎", "🍏", "🍊", "🍋", "🍒", "🍇", "🍉", "🍓", "🍑", "🍌", "🍐", "🍍", "🍆",
        "🍅", "🌽", "🏡", "🏥", "🏦", "⛪", "🏰", "⛺", "🏭", "🗻", "🗽", "🎠", "🎡", "⛲", "🎢", "🚢",
        "🚤", "⚓", "🚀", "✈", "🚁", "🚂", "🚋", "🚎", "🚌", "🚙", "🚗", "🚕", "🚛", "🚨", "🚔", "🚒",
        "🚑", "🚲", "🚠", "🚜", "🚦", "⚠", "🚧", "⛽", "🎰", "🗿", "🎪", "🎭", "🇯🇵", "🇰🇷", "🇩🇪", "🇨🇳",
        "🇺🇸", "🇫🇷", "🇪🇸", "🇮🇹", "🇷🇺", "🇬🇧", "1⃣", "2⃣", "3⃣", "4⃣", "5⃣", "6⃣", "7⃣", "8⃣", "9⃣", "0⃣",
        "🔟", "❗", "❓", "♥", "♦", "💯", "🔗", "🔱", "🔴", "🔵", "🔶", "🔷"
    ]
}
