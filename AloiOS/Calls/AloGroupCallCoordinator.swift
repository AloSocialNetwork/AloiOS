import AVFoundation
import Combine
import Foundation
import LiveKit
import WebRTC

@MainActor
final class AloGroupCallCoordinator: ObservableObject {
    @Published private(set) var activeCall: AloGroupCallState?
    @Published private(set) var sfuRoom: AloGroupSFURoom?
    @Published var isMinimized = false
    @Published private(set) var isCameraStarting = false

    private weak var app: AloAppModel?
    private let api: AloAPIClient
    private var heartbeatTask: Task<Void, Never>?
    private var lastSignalId = 0
    private var isRefreshingSignals = false
    private var rtcConfiguration: AloRTCConfiguration?
    private var clients: [Int: AloWebRTCCallClient] = [:]
    private weak var localVideoRenderer: RTCVideoRenderer?
    private var remoteVideoRenderers: [Int: AloWeakVideoRenderer] = [:]
    private var sfuObservation: AnyCancellable?

    init(api: AloAPIClient, app: AloAppModel) {
        self.api = api
        self.app = app
    }

    func startPolling() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            await refreshSignals()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if Task.isCancelled { return }
                if let callId = activeCall?.id, callId > 0 {
                    try? await api.heartbeatGroupCall(callId: callId)
                }
                await refreshSignals()
            }
        }
    }

    func refreshSignals() async {
        guard !isRefreshingSignals else { return }
        isRefreshingSignals = true
        defer { isRefreshingSignals = false }
        do {
            let signals = try await api.pollGroupCallSignals(afterId: lastSignalId)
            if let maxId = signals.map(\.id).max() {
                lastSignalId = max(lastSignalId, maxId)
            }
            await process(signals)
        } catch {
            // The stream reconnect and heartbeat fallback will retry.
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        closeMedia()
        activeCall = nil
        isMinimized = false
        isCameraStarting = false
        lastSignalId = 0
    }

    func start(conversation: AloConversationDetail) async {
        guard activeCall == nil,
              conversation.kind == "group",
              conversation.roomId > 0 else {
            return
        }
        guard await requestMicrophonePermission() else {
            showMediaPermissionError(
                "Для видеочата разрешите Alo доступ к микрофону."
            )
            return
        }
        do {
            let session = try await api.startGroupCall(roomId: conversation.roomId)
            let participants = participantsIncludingCurrentUser(session.participants)
            let state = AloGroupCallState(
                id: session.id,
                roomId: session.roomId,
                roomTitle: session.roomTitle.ifBlank(conversation.title),
                participants: participants,
                videoParticipantIds: [],
                isMuted: false,
                isSpeakerOn: true,
                isVideoEnabled: false,
                isFrontCamera: true,
                startedAt: Date()
            )
            activeCall = state
            isMinimized = false
            if !(await connectSFU(state)) {
                guard AloGroupCallAudioPolicy.canUsePeerToPeerFallback(
                    participantCount: state.participants.count
                ) else {
                    try? await api.leaveGroupCall(callId: state.id)
                    activeCall = nil
                    app?.errorMessage = AloGroupCallAudioPolicy.sfuRequiredMessage
                    return
                }
                try await syncMesh(state)
            }
            await broadcastMediaState(state)
        } catch let error as AloAPIError {
            app?.errorMessage = error.message
        } catch {
            app?.errorMessage = "Не удалось подключиться к видеочату."
        }
    }

    func leave() {
        guard let call = activeCall else { return }
        activeCall = nil
        isMinimized = false
        closeMedia()
        Task { try? await api.leaveGroupCall(callId: call.id) }
    }

    func toggleMute() {
        guard let call = activeCall else { return }
        let muted = !call.isMuted
        let updated = call.updating(isMuted: muted)
        activeCall = updated
        if let sfuRoom {
            Task {
                do {
                    try await sfuRoom.setMuted(muted)
                    await broadcastMediaState(updated)
                } catch {
                    activeCall = call
                    app?.errorMessage = error.localizedDescription
                }
            }
        } else {
            clients.values.forEach { $0.setMuted(muted) }
            Task { await broadcastMediaState(updated) }
        }
    }

    func toggleSpeaker() {
        guard let call = activeCall else { return }
        let enabled = !call.isSpeakerOn
        if sfuRoom == nil {
            clients.values.forEach { $0.setSpeakerOn(enabled) }
        }
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        activeCall = call.updating(isSpeakerOn: enabled)
    }

    func toggleVideo() {
        guard let call = activeCall, !isCameraStarting else { return }
        if call.isVideoEnabled {
            Task {
                if let sfuRoom {
                    try? await sfuRoom.setVideoEnabled(false, frontCamera: call.isFrontCamera)
                } else {
                    clients.values.forEach { $0.setVideoEnabled(false) }
                }
                guard let latest = activeCall, latest.id == call.id else { return }
                let updated = latest.updating(
                    videoParticipantIds: latest.videoParticipantIds.subtracting([currentUserId]),
                    isVideoEnabled: false
                )
                activeCall = updated
                await broadcastMediaState(updated)
            }
            return
        }

        Task {
            guard await requestCameraPermission() else {
                showMediaPermissionError(
                    "Для включения камеры разрешите Alo доступ к камере."
                )
                return
            }
            guard let current = activeCall, current.id == call.id else { return }
            isCameraStarting = true
            defer { isCameraStarting = false }
            if let sfuRoom {
                do {
                    try await sfuRoom.setVideoEnabled(true, frontCamera: current.isFrontCamera)
                } catch {
                    app?.errorMessage = error.localizedDescription
                    return
                }
            } else {
                for client in clients.values {
                    let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                        client.setVideoEnabled(true, frontCamera: current.isFrontCamera) {
                            continuation.resume(returning: $0)
                        }
                    }
                    if case let .failure(error) = result {
                        app?.errorMessage = error.localizedDescription
                        return
                    }
                }
            }
            guard let latest = activeCall, latest.id == call.id else { return }
            if sfuRoom == nil {
                clients.values.forEach { $0.setSpeakerOn(true) }
            }
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            var videos = latest.videoParticipantIds
            videos.insert(currentUserId)
            let updated = latest.updating(
                videoParticipantIds: videos,
                isSpeakerOn: true,
                isVideoEnabled: true
            )
            activeCall = updated
            await broadcastMediaState(updated)
        }
    }

    func switchCamera() {
        guard let call = activeCall, call.isVideoEnabled, !isCameraStarting else { return }
        let front = !call.isFrontCamera
        isCameraStarting = true
        if let sfuRoom {
            Task {
                defer { isCameraStarting = false }
                do {
                    try await sfuRoom.setCameraPosition(frontCamera: front)
                    if let latest = activeCall, latest.id == call.id {
                        activeCall = latest.updating(isFrontCamera: front)
                    }
                } catch {
                    app?.errorMessage = error.localizedDescription
                }
            }
            return
        }
        let group = DispatchGroup()
        var firstError: Error?
        for client in clients.values {
            group.enter()
            client.setCameraPosition(frontCamera: front) { result in
                if case let .failure(error) = result, firstError == nil {
                    firstError = error
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.isCameraStarting = false
            if let firstError {
                self.app?.errorMessage = firstError.localizedDescription
            } else if let latest = self.activeCall, latest.id == call.id {
                self.activeCall = latest.updating(isFrontCamera: front)
            }
        }
    }

    func selectCamera(frontCamera: Bool) {
        guard let call = activeCall, !isCameraStarting else { return }
        if call.isVideoEnabled {
            guard call.isFrontCamera != frontCamera else { return }
            switchCamera()
            return
        }
        activeCall = call.updating(isFrontCamera: frontCamera)
        toggleVideo()
    }

    func bindLocalRenderer(_ renderer: RTCVideoRenderer?) {
        guard !sameRenderer(localVideoRenderer, renderer) else { return }
        localVideoRenderer = renderer
        clients.values.first?.bindLocalRenderer(renderer)
    }

    func bindRemoteRenderer(_ renderer: RTCVideoRenderer?, userId: Int) {
        let previous = remoteVideoRenderers[userId]?.value
        guard !sameRenderer(previous, renderer) else { return }
        remoteVideoRenderers[userId] = AloWeakVideoRenderer(renderer)
        clients[userId]?.bindRemoteRenderer(renderer)
    }

    private func process(_ signals: [AloGroupCallSignal]) async {
        for signal in signals {
            guard let call = activeCall, signal.callId == call.id else { continue }
            switch signal.kind {
            case "participant_joined":
                guard let peer = parsePeer(signal.payload.object("user")) else { continue }
                let participants = (call.participants + [peer])
                    .reduce(into: [Int: AloDirectCallPeer]()) { $0[$1.id] = $1 }
                    .values
                    .sorted { $0.id < $1.id }
                let updated = call.updating(participants: participants)
                activeCall = updated
                if sfuRoom == nil {
                    try? await syncMesh(updated)
                }
                await sendMediaState(updated, toUserId: peer.id)
            case "participant_left":
                let userId = signal.payload.int("userId")
                clients.removeValue(forKey: userId)?.close()
                remoteVideoRenderers.removeValue(forKey: userId)
                var videos = call.videoParticipantIds
                videos.remove(userId)
                activeCall = call.updating(
                    participants: call.participants.filter { $0.id != userId },
                    videoParticipantIds: videos
                )
            case "offer":
                guard sfuRoom == nil else { continue }
                let sdp = signal.payload.string("sdp")
                guard !sdp.isEmpty else { continue }
                let client = try? await ensureClient(call: call, remoteUserId: signal.fromUserId)
                client?.prepareIncoming()
                client?.handleRemoteOffer(sdp)
            case "answer":
                guard sfuRoom == nil else { continue }
                let sdp = signal.payload.string("sdp")
                guard !sdp.isEmpty else { continue }
                let client = try? await ensureClient(call: call, remoteUserId: signal.fromUserId)
                client?.handleRemoteAnswer(sdp)
            case "reconnect-offer":
                guard sfuRoom == nil else { continue }
                let sdp = signal.payload.string("sdp")
                guard !sdp.isEmpty else { continue }
                let client = try? await ensureClient(call: call, remoteUserId: signal.fromUserId)
                client?.handleRemoteReconnectOffer(sdp)
            case "reconnect-answer":
                guard sfuRoom == nil else { continue }
                let sdp = signal.payload.string("sdp")
                guard !sdp.isEmpty else { continue }
                let client = try? await ensureClient(call: call, remoteUserId: signal.fromUserId)
                client?.handleRemoteReconnectAnswer(sdp)
            case "ice":
                guard sfuRoom == nil else { continue }
                let candidate = signal.payload.string("candidate")
                let sdpMid = signal.payload.string("sdpMid")
                let lineIndex = signal.payload.int("sdpMLineIndex")
                guard !candidate.isEmpty, !sdpMid.isEmpty, lineIndex >= 0 else { continue }
                let client = try? await ensureClient(call: call, remoteUserId: signal.fromUserId)
                client?.addRemoteIceCandidate(
                    sdpMid: sdpMid,
                    lineIndex: Int32(lineIndex),
                    candidate: candidate
                )
            case "media-state":
                var videos = call.videoParticipantIds
                if signal.payload.bool("videoEnabled") {
                    videos.insert(signal.fromUserId)
                } else {
                    videos.remove(signal.fromUserId)
                }
                activeCall = call.updating(videoParticipantIds: videos)
            default:
                break
            }
        }
    }

    private func syncMesh(_ call: AloGroupCallState) async throws {
        guard AloGroupCallAudioPolicy.canUsePeerToPeerFallback(
            participantCount: call.participants.count
        ) else {
            app?.errorMessage = AloGroupCallAudioPolicy.sfuRequiredMessage
            return
        }
        let meId = currentUserId
        guard meId > 0 else { return }
        for peer in call.participants where peer.id > 0 && peer.id != meId {
            if meId < peer.id, clients[peer.id] == nil {
                let client = try await ensureClient(call: call, remoteUserId: peer.id)
                client.prepareIncoming()
                client.startOutgoing()
            }
        }
    }

    private func connectSFU(_ call: AloGroupCallState) async -> Bool {
        do {
            let join = try await api.loadGroupCallSFUJoin(callId: call.id)
            let room = AloGroupSFURoom()
            try await room.connect(join: join, muted: call.isMuted)
            sfuRoom = room
            sfuObservation = room.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            return true
        } catch let error as AloAPIError {
            if error.status != 503 {
                app?.notice = "Медиасервер недоступен, используется резервное соединение."
            }
            return false
        } catch {
            app?.notice = "Медиасервер недоступен, используется резервное соединение."
            return false
        }
    }

    private func ensureClient(
        call: AloGroupCallState,
        remoteUserId: Int
    ) async throws -> AloWebRTCCallClient {
        if let existing = clients[remoteUserId] { return existing }
        let configuration: AloRTCConfiguration
        if let rtcConfiguration {
            configuration = rtcConfiguration
        } else {
            configuration = try await api.loadRTCConfiguration()
            rtcConfiguration = configuration
        }
        let callId = call.id
        let created = try AloWebRTCCallClient(
            configuration: configuration,
            enableVideo: false,
            frontCamera: call.isFrontCamera,
            onLocalDescription: { [weak self] kind, sdp in
                Task { @MainActor in
                    await self?.sendSignal(
                        callId: callId,
                        kind: kind,
                        payload: ["sdp": sdp],
                        toUserId: remoteUserId
                    )
                }
            },
            onIceCandidate: { [weak self] sdpMid, lineIndex, candidate in
                Task { @MainActor in
                    await self?.sendSignal(
                        callId: callId,
                        kind: "ice",
                        payload: [
                            "sdpMid": sdpMid,
                            "sdpMLineIndex": Int(lineIndex),
                            "candidate": candidate
                        ],
                        toUserId: remoteUserId
                    )
                }
            },
            onConnectionStateChanged: { [weak self] connectionState in
                Task { @MainActor in
                    guard let self, self.activeCall?.id == callId else { return }
                    if connectionState == .failed || connectionState == .disconnected {
                        _ = self.clients[remoteUserId]?.restartIce()
                    }
                }
            },
            onError: { [weak self] message in
                Task { @MainActor in self?.app?.errorMessage = message }
            }
        )
        created.setMuted(call.isMuted)
        created.setSpeakerOn(call.isSpeakerOn)
        if clients.isEmpty {
            created.bindLocalRenderer(localVideoRenderer)
        }
        created.bindRemoteRenderer(remoteVideoRenderers[remoteUserId]?.value)
        clients[remoteUserId] = created
        return created
    }

    private func broadcastMediaState(_ call: AloGroupCallState) async {
        for peer in call.participants where peer.id > 0 && peer.id != currentUserId {
            await sendMediaState(call, toUserId: peer.id)
        }
    }

    private func sendMediaState(_ call: AloGroupCallState, toUserId: Int) async {
        await sendSignal(
            callId: call.id,
            kind: "media-state",
            payload: [
                "videoEnabled": call.isVideoEnabled,
                "muted": call.isMuted
            ],
            toUserId: toUserId
        )
    }

    private func sendSignal(
        callId: Int,
        kind: String,
        payload: [String: Any],
        toUserId: Int
    ) async {
        do {
            try await api.sendGroupCallSignal(
                callId: callId,
                kind: kind,
                payload: payload,
                toUserId: toUserId
            )
        } catch let error as AloAPIError {
            app?.errorMessage = error.message
        } catch {
            app?.errorMessage = "Не удалось синхронизировать видеочат."
        }
    }

    private func participantsIncludingCurrentUser(
        _ participants: [AloDirectCallPeer]
    ) -> [AloDirectCallPeer] {
        var result = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
        if let me = app?.bootstrap?.me {
            result[me.id] = AloDirectCallPeer(
                id: me.id,
                name: me.name,
                username: me.username,
                avatarURL: me.avatarUrl,
                verified: me.verified
            )
        }
        return result.values.sorted { $0.id < $1.id }
    }

    private func parsePeer(_ user: [String: Any]) -> AloDirectCallPeer? {
        let id = user.int("id")
        guard id > 0 else { return nil }
        return AloDirectCallPeer(
            id: id,
            name: user.string("name").ifBlank("Участник"),
            username: user.string("username"),
            avatarURL: user.string("avatarUrl").ifBlank(user.string("avatarEmoji")),
            verified: user.bool("verified") || user.bool("isVerified")
        )
    }

    var localUserId: Int {
        app?.bootstrap?.me.id ?? 0
    }

    private var currentUserId: Int { localUserId }

    private func closeMedia() {
        sfuRoom?.disconnect()
        sfuRoom = nil
        sfuObservation = nil
        clients.values.forEach { $0.close() }
        clients.removeAll()
        remoteVideoRenderers.removeAll()
        localVideoRenderer = nil
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
    }

    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private func showMediaPermissionError(_ message: String) {
        app?.shouldOfferAppSettings = true
        app?.errorMessage = message
    }

    private func sameRenderer(
        _ lhs: RTCVideoRenderer?,
        _ rhs: RTCVideoRenderer?
    ) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return (lhs as AnyObject) === (rhs as AnyObject)
    }
}

enum AloGroupCallAudioPolicy {
    static let maximumPeerToPeerParticipants = 2
    static let sfuRequiredMessage =
        "Для видеочата с тремя и более участниками требуется медиасервер."

    static func canUsePeerToPeerFallback(participantCount: Int) -> Bool {
        (1...maximumPeerToPeerParticipants).contains(participantCount)
    }
}

private final class AloWeakVideoRenderer {
    weak var value: RTCVideoRenderer?

    init(_ value: RTCVideoRenderer?) {
        self.value = value
    }
}
