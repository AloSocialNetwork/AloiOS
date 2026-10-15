import AVFoundation
import Combine
import Foundation
import LiveKit

@MainActor
final class AloGroupSFURoom: NSObject, ObservableObject, RoomDelegate, @unchecked Sendable {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var participantIds: Set<Int> = []
    @Published private(set) var speakingParticipantIds: Set<Int> = []
    /// Remote people whose microphone is off (muted, or not published at all).
    @Published private(set) var mutedParticipantIds: Set<Int> = []
    @Published private(set) var localVideoTrack: VideoTrack?
    @Published private(set) var remoteVideoTracks: [Int: VideoTrack] = [:]

    private lazy var room = LiveKit.Room(delegate: self)

    var isConnected: Bool {
        connectionState == .connected || connectionState == .reconnecting
    }

    func connect(join: AloGroupCallSFUJoin, muted: Bool) async throws {
        try await room.connect(url: join.serverURL, token: join.token)
        // Someone an admin muted has no microphone permission; they still listen.
        try? await room.localParticipant.setMicrophone(enabled: !muted)
        refreshState()
    }

    func disconnect() {
        let activeRoom = room
        Task {
            await activeRoom.disconnect()
        }
        connectionState = .disconnected
        participantIds = []
        speakingParticipantIds = []
        mutedParticipantIds = []
        localVideoTrack = nil
        remoteVideoTracks = [:]
    }

    func setMuted(_ muted: Bool) async throws {
        try await room.localParticipant.setMicrophone(enabled: !muted)
        refreshState()
    }

    func setVideoEnabled(_ enabled: Bool, frontCamera: Bool) async throws {
        let options = CameraCaptureOptions(position: frontCamera ? .front : .back)
        try await room.localParticipant.setCamera(
            enabled: enabled,
            captureOptions: enabled ? options : nil
        )
        refreshState()
    }

    func setCameraPosition(frontCamera: Bool) async throws {
        guard
            let publication = room.localParticipant.videoTracks.first(where: {
                $0.source == .camera && !$0.isMuted
            }),
            let localTrack = publication.track as? LocalVideoTrack,
            let capturer = localTrack.capturer as? CameraCapturer
        else {
            throw AloGroupSFUError.cameraNotActive
        }
        try await capturer.set(cameraPosition: frontCamera ? .front : .back)
        refreshState()
    }

    func videoTrack(for userId: Int) -> VideoTrack? {
        if userId == localUserId {
            return localVideoTrack
        }
        return remoteVideoTracks[userId]
    }

    var localUserId: Int {
        Self.userId(from: room.localParticipant.identity)
    }

    nonisolated func room(
        _ room: LiveKit.Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        Task { @MainActor [weak self] in
            self?.connectionState = connectionState
            self?.refreshState()
        }
    }

    nonisolated func room(
        _ room: LiveKit.Room,
        participantDidConnect participant: RemoteParticipant
    ) {
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    nonisolated func room(
        _ room: LiveKit.Room,
        participantDidDisconnect participant: RemoteParticipant
    ) {
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    nonisolated func room(
        _ room: LiveKit.Room,
        participant: RemoteParticipant,
        didSubscribeTrack publication: RemoteTrackPublication
    ) {
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    nonisolated func room(
        _ room: LiveKit.Room,
        participant: RemoteParticipant,
        didUnsubscribeTrack publication: RemoteTrackPublication
    ) {
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    nonisolated func room(
        _ room: LiveKit.Room,
        participant: Participant,
        trackPublication: TrackPublication,
        didUpdateIsMuted isMuted: Bool
    ) {
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    nonisolated func room(
        _ room: LiveKit.Room,
        didUpdateSpeakingParticipants participants: [Participant]
    ) {
        let ids = Set(participants.map { Self.userId(from: $0.identity) }.filter { $0 > 0 })
        Task { @MainActor [weak self] in
            self?.speakingParticipantIds = ids
        }
    }

    private func refreshState() {
        connectionState = room.connectionState

        var ids = Set<Int>()
        var muted = Set<Int>()
        var tracks: [Int: VideoTrack] = [:]
        for participant in room.remoteParticipants.values {
            let userId = Self.userId(from: participant.identity)
            guard userId > 0 else { continue }
            ids.insert(userId)
            let microphone = participant.audioTracks.first { $0.source == .microphone }
            if microphone == nil || microphone?.isMuted == true { muted.insert(userId) }
            if let track = preferredVideoTrack(for: participant) {
                tracks[userId] = track
            }
        }
        participantIds = ids
        mutedParticipantIds = muted
        remoteVideoTracks = tracks
        localVideoTrack = preferredVideoTrack(for: room.localParticipant)
    }

    private func preferredVideoTrack(for participant: Participant) -> VideoTrack? {
        let publications = participant.videoTracks.filter {
            !$0.isMuted && $0.track != nil
        }
        let preferred = publications.first(where: { $0.source == .screenShareVideo })
            ?? publications.first(where: { $0.source == .camera })
            ?? publications.first
        return preferred?.track as? VideoTrack
    }

    private nonisolated static func userId(
        from identity: Participant.Identity?
    ) -> Int {
        guard let raw = identity?.stringValue else { return 0 }
        return Int(raw.replacingOccurrences(of: "alo-user-", with: "")) ?? 0
    }
}

enum AloGroupSFUError: LocalizedError {
    case cameraNotActive

    var errorDescription: String? {
        switch self {
        case .cameraNotActive:
            "Камера ещё не запущена."
        }
    }
}
