import Foundation
import CryptoKit

struct AloRTCIceServer {
    let urls: [String]
    let username: String
    let credential: String
}

struct AloRTCConfiguration {
    let iceServers: [AloRTCIceServer]
}

struct AloDirectCallSession {
    let id: Int
    let type: String
    let callerId: Int
    let calleeId: Int
    let status: String
}

struct AloDirectCallPeer {
    let id: Int
    let name: String
    let username: String
    let avatarURL: String
    let verified: Bool
}

struct AloDirectCallSignal {
    let id: Int
    let callId: Int
    let fromUserId: Int
    let toUserId: Int
    let kind: String
    let callType: String
    let callStatus: String
    let callerId: Int
    let calleeId: Int
    let fromUser: AloDirectCallPeer
    let payload: [String: Any]
}

struct AloGroupCallSession {
    let id: Int
    let roomId: Int
    let type: String
    let status: String
    let roomTitle: String
    let participants: [AloDirectCallPeer]
}

struct AloGroupCallSFUJoin {
    let serverURL: String
    let roomName: String
    let identity: String
    let token: String
    let expiresAt: Date?
}

struct AloGroupCallSignal {
    let id: Int
    let callId: Int
    let roomId: Int
    let fromUserId: Int
    let toUserId: Int
    let kind: String
    let payload: [String: Any]
}

struct AloGroupCallState: Identifiable {
    let id: Int
    let roomId: Int
    let roomTitle: String
    let participants: [AloDirectCallPeer]
    let videoParticipantIds: Set<Int>
    let isMuted: Bool
    let isSpeakerOn: Bool
    let isVideoEnabled: Bool
    let isFrontCamera: Bool
    let startedAt: Date

    func updating(
        participants: [AloDirectCallPeer]? = nil,
        videoParticipantIds: Set<Int>? = nil,
        isMuted: Bool? = nil,
        isSpeakerOn: Bool? = nil,
        isVideoEnabled: Bool? = nil,
        isFrontCamera: Bool? = nil
    ) -> AloGroupCallState {
        AloGroupCallState(
            id: id,
            roomId: roomId,
            roomTitle: roomTitle,
            participants: participants ?? self.participants,
            videoParticipantIds: videoParticipantIds ?? self.videoParticipantIds,
            isMuted: isMuted ?? self.isMuted,
            isSpeakerOn: isSpeakerOn ?? self.isSpeakerOn,
            isVideoEnabled: isVideoEnabled ?? self.isVideoEnabled,
            isFrontCamera: isFrontCamera ?? self.isFrontCamera,
            startedAt: startedAt
        )
    }
}

enum AloDirectCallPhase: String {
    case outgoing
    case incoming
    case connecting
    case reconnecting
    case active
    case noAnswer
    case interrupted
    case busy
    case declined

    var isTerminal: Bool {
        switch self {
        case .noAnswer, .interrupted, .busy, .declined:
            true
        case .outgoing, .incoming, .connecting, .reconnecting, .active:
            false
        }
    }
}

enum AloCallKitSupport {
    static var isAvailable: Bool {
#if targetEnvironment(simulator)
        false
#else
        true
#endif
    }
}

enum AloCallMinimizePolicy {
    static func shouldMinimize(
        translation: CGFloat,
        predictedTranslation: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        let height = max(1, viewportHeight)
        guard abs(translation) >= 28,
              translation * predictedTranslation >= 0 else { return false }
        let projectedTravel = abs(predictedTranslation) - abs(translation)
        // A reversal cancels, including after a long pull. A tiny fling never
        // hides the call while the user is aiming for a control.
        guard projectedTravel > -45 else { return false }
        return abs(translation) / height > 0.42 || projectedTravel >= 120
    }

    static func direction(
        translation: CGFloat,
        predictedTranslation: CGFloat
    ) -> CGFloat {
        let projected = predictedTranslation == 0 ? translation : predictedTranslation
        return projected < 0 ? -1 : 1
    }
}

struct AloDirectCallState: Identifiable {
    let id: Int
    let uuid: UUID
    let peer: AloDirectCallPeer
    let type: String
    let phase: AloDirectCallPhase
    let isIncoming: Bool
    let isMuted: Bool
    let isSpeakerOn: Bool
    let isVideoEnabled: Bool
    let isFrontCamera: Bool
    let isScreenSharing: Bool
    let isRemoteVideoEnabled: Bool
    let isRemoteScreenSharing: Bool
    let startedAt: Date?
    let callSecret: String
    let safetyEmojis: [String]
    let isSecurityConfirmed: Bool

    var isVideo: Bool { type == "video" }
    var hasLocalVideo: Bool { isVideoEnabled || isScreenSharing }
    var hasLocalPreviewVideo: Bool { isVideoEnabled && !isScreenSharing }
    var hasRemoteVideo: Bool { isRemoteVideoEnabled || isRemoteScreenSharing }
    var hasVideoSurface: Bool { isVideo || hasLocalVideo || hasRemoteVideo }

    init(
        id: Int,
        uuid: UUID,
        peer: AloDirectCallPeer,
        type: String,
        phase: AloDirectCallPhase,
        isIncoming: Bool,
        isMuted: Bool,
        isSpeakerOn: Bool,
        isVideoEnabled: Bool,
        isFrontCamera: Bool,
        isScreenSharing: Bool = false,
        isRemoteVideoEnabled: Bool? = nil,
        isRemoteScreenSharing: Bool = false,
        startedAt: Date?,
        callSecret: String,
        safetyEmojis: [String],
        isSecurityConfirmed: Bool = false
    ) {
        self.id = id
        self.uuid = uuid
        self.peer = peer
        self.type = type
        self.phase = phase
        self.isIncoming = isIncoming
        self.isMuted = isMuted
        self.isSpeakerOn = isSpeakerOn
        self.isVideoEnabled = isVideoEnabled
        self.isFrontCamera = isFrontCamera
        self.isScreenSharing = isScreenSharing
        self.isRemoteVideoEnabled = isRemoteVideoEnabled ?? false
        self.isRemoteScreenSharing = isRemoteScreenSharing
        self.startedAt = startedAt
        self.callSecret = callSecret
        self.safetyEmojis = safetyEmojis
        self.isSecurityConfirmed = isSecurityConfirmed
    }

    func updating(
        phase: AloDirectCallPhase? = nil,
        isMuted: Bool? = nil,
        isSpeakerOn: Bool? = nil,
        isVideoEnabled: Bool? = nil,
        isFrontCamera: Bool? = nil,
        isScreenSharing: Bool? = nil,
        isRemoteVideoEnabled: Bool? = nil,
        isRemoteScreenSharing: Bool? = nil,
        startedAt: Date? = nil,
        callSecret: String? = nil,
        safetyEmojis: [String]? = nil,
        isSecurityConfirmed: Bool? = nil
    ) -> AloDirectCallState {
        AloDirectCallState(
            id: id,
            uuid: uuid,
            peer: peer,
            type: type,
            phase: phase ?? self.phase,
            isIncoming: isIncoming,
            isMuted: isMuted ?? self.isMuted,
            isSpeakerOn: isSpeakerOn ?? self.isSpeakerOn,
            isVideoEnabled: isVideoEnabled ?? self.isVideoEnabled,
            isFrontCamera: isFrontCamera ?? self.isFrontCamera,
            isScreenSharing: isScreenSharing ?? self.isScreenSharing,
            isRemoteVideoEnabled: isRemoteVideoEnabled ?? self.isRemoteVideoEnabled,
            isRemoteScreenSharing: isRemoteScreenSharing ?? self.isRemoteScreenSharing,
            startedAt: startedAt ?? self.startedAt,
            callSecret: callSecret ?? self.callSecret,
            safetyEmojis: safetyEmojis ?? self.safetyEmojis,
            isSecurityConfirmed: isSecurityConfirmed ?? self.isSecurityConfirmed
        )
    }
}

struct AloCallVideoLayout: Equatable {
    let showsPrimaryVideo: Bool
    let primaryIsLocal: Bool
    let showsPreview: Bool
    let previewIsLocal: Bool

    var showsIdentity: Bool { !showsPrimaryVideo }

    func isPrimary(isLocal: Bool) -> Bool {
        showsPrimaryVideo && primaryIsLocal == isLocal
    }

    func renders(isLocal: Bool) -> Bool {
        isPrimary(isLocal: isLocal) || (showsPreview && previewIsLocal == isLocal)
    }

    static func resolve(
        phase: AloDirectCallPhase,
        hasLocalVideo: Bool,
        hasRemoteVideo: Bool,
        prefersLocalPrimary: Bool
    ) -> AloCallVideoLayout {
        let canRenderVideo = phase != .incoming && !phase.isTerminal
        let showsPrimaryVideo = canRenderVideo && hasRemoteVideo
        let primaryIsLocal = showsPrimaryVideo
            && hasLocalVideo
            && prefersLocalPrimary
        let previewIsLocal = !primaryIsLocal
        let showsPreview = canRenderVideo
            && (
                (previewIsLocal && hasLocalVideo)
                    || (!previewIsLocal && hasRemoteVideo)
            )
        return AloCallVideoLayout(
            showsPrimaryVideo: showsPrimaryVideo,
            primaryIsLocal: primaryIsLocal,
            showsPreview: showsPreview,
            previewIsLocal: previewIsLocal
        )
    }
}

enum AloCallSecurity {
    static func emojis(callId: Int, ownerUserId: Int, peerId: Int, secret: String) -> [String] {
        let low = min(ownerUserId, peerId)
        let high = max(ownerUserId, peerId)
        let material = "alo-direct-call-safety-v1|\(callId)|\(low)|\(high)|\(secret)"
        return SHA256.hash(data: Data(material.utf8)).prefix(4).map {
            emojiSet[Int($0) % emojiSet.count]
        }
    }

    static func callUUID(callId: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("alo-call|\(callId)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static let emojiSet = [
        "🔐", "🛡️", "⭐", "⚡", "🔥", "💎", "🌙", "☀️",
        "🍀", "🎯", "🎵", "🚀", "🌊", "🔔", "✅", "🔷",
        "🟢", "🟣", "🟡", "🧩", "🎲", "🏆", "💡", "📌",
        "🔑", "🧿", "🪙", "🎬", "📎", "🧭", "🔭", "🕹️"
    ]
}
