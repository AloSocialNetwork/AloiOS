import AVFoundation
import CallKit
import Combine
import Foundation
import Security
import UIKit
import WebRTC

@MainActor
final class AloCallCoordinator: NSObject, ObservableObject {
    @Published private(set) var activeCall: AloDirectCallState?
    @Published var isMinimized = false
    @Published private(set) var isScreenShareStarting = false
    @Published private(set) var isCameraStarting = false
    @Published private(set) var isCameraSwitching = false

    private weak var app: AloAppModel?
    private let api: AloAPIClient
    private let provider: CXProvider
    private let callController = CXCallController()
    private let tonePlayer = AloCallTonePlayer()
    private var pollTask: Task<Void, Never>?
    private var ringTimeoutTask: Task<Void, Never>?
    private var disconnectTimeoutTask: Task<Void, Never>?
    private var reconnectAttemptTask: Task<Void, Never>?
    private var securityBootstrapRetryTask: Task<Void, Never>?
    private var terminalDismissTask: Task<Void, Never>?
    private var rtcConfiguration: AloRTCConfiguration?
    private var client: AloWebRTCCallClient?
    private weak var localVideoRenderer: RTCVideoRenderer?
    private weak var remoteVideoRenderer: RTCVideoRenderer?
    private var lastSignalId = 0
    private var remoteTermination = false
    private var resumeCameraAfterScreenShare = false
    private var videoSourcePreviewGeneration = 0
    private var securityHandshake: AloCallSecurityHandshake?

    init(api: AloAPIClient, app: AloAppModel) {
        self.api = api
        self.app = app
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = true
        self.provider = CXProvider(configuration: configuration)
        super.init()
        if AloCallKitSupport.isAvailable {
            provider.setDelegate(self, queue: nil)
        }
        AloVoIPPushCoordinator.shared.setIncomingHandler { [weak self] payload in
            await self?.handleVoIPPush(payload)
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            var retryDelay: UInt64 = 900_000_000
            while !Task.isCancelled {
                do {
                    let signals = try await api.pollDirectCallSignals(
                        afterId: lastSignalId,
                        activeCallId: activeCall?.id
                    )
                    if let maxId = signals.map(\.id).max() {
                        lastSignalId = max(lastSignalId, maxId)
                    }
                    await process(signals)
                    retryDelay = 900_000_000
                } catch let error as AloAPIError {
                    if error.status == 401 { break }
                    retryDelay = min(retryDelay * 2, 8_000_000_000)
                } catch {
                    retryDelay = min(retryDelay * 2, 8_000_000_000)
                }
                try? await Task.sleep(nanoseconds: retryDelay)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil
        disconnectTimeoutTask?.cancel()
        disconnectTimeoutTask = nil
        reconnectAttemptTask?.cancel()
        reconnectAttemptTask = nil
        securityBootstrapRetryTask?.cancel()
        securityBootstrapRetryTask = nil
        terminalDismissTask?.cancel()
        terminalDismissTask = nil
        tonePlayer.stop()
        client?.close()
        client = nil
        securityHandshake = nil
        if AloCallKitSupport.isAvailable, let activeCall {
            provider.reportCall(with: activeCall.uuid, endedAt: Date(), reason: .unanswered)
        }
        activeCall = nil
        isMinimized = false
        isScreenShareStarting = false
        isCameraStarting = false
        isCameraSwitching = false
        resumeCameraAfterScreenShare = false
        videoSourcePreviewGeneration += 1
        lastSignalId = 0
    }

#if DEBUG
    func installDebugPreviewCall() {
        let video = UserDefaults.standard.bool(
            forKey: "ALO_UI_CALL_VIDEO_PREVIEW"
        )
        let remoteVideo = UserDefaults.standard.bool(
            forKey: "ALO_UI_CALL_REMOTE_VIDEO_PREVIEW"
        )
        activeCall = AloDirectCallState(
            id: -42,
            uuid: AloCallSecurity.callUUID(callId: -42),
            peer: AloDirectCallPeer(
                id: 42,
                name: "Слава",
                username: "slava",
                avatarURL: "",
                verified: false
            ),
            type: video ? "video" : "voice",
            phase: remoteVideo ? .active : .outgoing,
            isIncoming: false,
            isMuted: false,
            isSpeakerOn: video,
            isVideoEnabled: video,
            isFrontCamera: true,
            isRemoteVideoEnabled: remoteVideo,
            startedAt: remoteVideo ? Date() : nil,
            callSecret: "ui-test-call",
            safetyEmojis: ["🔐", "🟢", "🎯", "💎"],
            isSecurityConfirmed: true
        )
        isMinimized = !video
    }
#endif

    func startCall(conversation: AloConversationDetail, video: Bool) async {
        guard activeCall == nil else { return }
        guard conversation.kind != "group", conversation.peerId > 0 else {
            app?.errorMessage = "Защищённые звонки пока доступны только в личных чатах."
            return
        }
        guard await requestMediaPermissions(video: video) else {
            app?.errorMessage = video
                ? "Для видеозвонка нужны доступ к микрофону и камере."
                : "Для звонка нужен доступ к микрофону."
            return
        }
        do {
            let session = try await api.startDirectCall(
                peerId: conversation.peerId,
                type: video ? "video" : "voice"
            )
            let handshake = try AloCallSecurityHandshake(
                role: .caller,
                callId: session.id,
                callerId: session.callerId,
                calleeId: session.calleeId
            )
            securityHandshake = handshake
            let peer = AloDirectCallPeer(
                id: conversation.peerId,
                name: conversation.title,
                username: "",
                avatarURL: conversation.avatarUrl,
                verified: false
            )
            let state = AloDirectCallState(
                id: session.id,
                uuid: callUUID(callId: session.id),
                peer: peer,
                type: session.type,
                phase: .outgoing,
                isIncoming: false,
                isMuted: false,
                isSpeakerOn: video,
                isVideoEnabled: video,
                isFrontCamera: true,
                startedAt: nil,
                callSecret: "",
                safetyEmojis: [],
                isSecurityConfirmed: false
            )
            activeCall = state
            isMinimized = false
            tonePlayer.prepareAudioRoute(
                speakerOn: state.isSpeakerOn,
                activate: !AloCallKitSupport.isAvailable
            )
            if AloCallKitSupport.isAvailable {
                try await requestCallKitStart(state)
            }
            if video {
                try await ensureClient()
            }
            tonePlayer.play(.ringback)
            scheduleRingTimeout(callId: state.id, outgoing: true)
            guard await sendSecurityCommit(handshake) else { return }
        } catch let error as AloAPIError {
            securityHandshake = nil
            if activeCall != nil {
                await endNetworkCall(terminalTone: .failed)
            }
            app?.errorMessage = error.message
        } catch {
            securityHandshake = nil
            if activeCall != nil {
                await endNetworkCall(terminalTone: .failed)
            }
            app?.errorMessage = "Не удалось начать звонок."
        }
    }

    func accept() {
        guard let call = activeCall, call.isIncoming else { return }
        Task {
            guard await requestMediaPermissions(video: call.isVideo) else {
                await decline()
                app?.errorMessage = call.isVideo
                    ? "Для видеозвонка нужны доступ к микрофону и камере."
                    : "Для звонка нужен доступ к микрофону."
                return
            }
            do {
                try await api.acceptDirectCall(callId: call.id)
                ringTimeoutTask?.cancel()
                activeCall = call.updating(phase: .connecting)
                securityHandshake?.didAccept = true
                tonePlayer.play(.connecting)
                try await ensureClient()
                client?.prepareIncoming()
                guard await sendSecurityResponseIfReady() else { return }
            } catch let error as AloAPIError {
                app?.errorMessage = error.message
                finish(reason: .failed, terminalTone: .failed)
            } catch {
                app?.errorMessage = "Не удалось принять звонок."
                finish(reason: .failed, terminalTone: .failed)
            }
        }
    }

    func decline() async {
        guard let call = activeCall else { return }
        try? await api.endDirectCall(callId: call.id, reason: "declined")
        finish(reason: .declinedElsewhere, terminalTone: .ended)
    }

    func end() {
        guard let call = activeCall else { return }
        guard AloCallKitSupport.isAvailable else {
            Task { await endNetworkCall(terminalTone: .ended) }
            return
        }
        let action = CXEndCallAction(call: call.uuid)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    await self?.endNetworkCall(terminalTone: .ended)
                }
            }
        }
    }

    func toggleMute() {
        guard let call = activeCall else { return }
        let muted = !call.isMuted
        client?.setMuted(muted)
        activeCall = call.updating(isMuted: muted)
    }

    func toggleSpeaker() {
        guard let call = activeCall else { return }
        let speaker = !call.isSpeakerOn
        client?.setSpeakerOn(speaker)
        tonePlayer.prepareAudioRoute(speakerOn: speaker, activate: false)
        activeCall = call.updating(isSpeakerOn: speaker)
    }

    func toggleVideo() {
        guard let call = activeCall else { return }
        guard !isCameraStarting, !isCameraSwitching, !isScreenShareStarting else { return }
        let enabled = !call.isVideoEnabled || call.isScreenSharing
        if !enabled {
            client?.setVideoEnabled(false)
            let updated = call.updating(
                isVideoEnabled: false,
                isScreenSharing: false
            )
            resumeCameraAfterScreenShare = false
            activeCall = updated
            reportMediaCapabilityChange(updated)
            Task { await sendLocalMediaState(updated) }
            return
        }

        Task {
            let permissionGranted = await requestCameraPermission()
            if !permissionGranted {
                app?.errorMessage = "Для включения камеры разрешите Alo доступ к камере."
                return
            }
            guard let current = activeCall, current.id == call.id else { return }
            isCameraStarting = true
            defer { isCameraStarting = false }
            do {
                try await ensureClient()
            } catch {
                app?.errorMessage = "Не удалось подготовить камеру звонка."
                return
            }
            guard let client,
                  let latest = activeCall,
                  latest.id == current.id else { return }
            let result = await withCheckedContinuation { continuation in
                client.setVideoEnabled(true, frontCamera: latest.isFrontCamera) {
                    continuation.resume(returning: $0)
                }
            }
            guard activeCall?.id == current.id else { return }
            if case let .failure(error) = result {
                app?.errorMessage = error.localizedDescription
                return
            }
            let updated = latest.updating(
                isSpeakerOn: true,
                isVideoEnabled: true,
                isScreenSharing: false
            )
            resumeCameraAfterScreenShare = false
            activeCall = updated
            if !current.isSpeakerOn {
                client.setSpeakerOn(true)
                tonePlayer.prepareAudioRoute(speakerOn: true, activate: false)
            }
            reportMediaCapabilityChange(updated)
            await sendLocalMediaState(updated)
        }
    }

    func beginVideoSourcePreview(frontCamera: Bool) {
        guard let call = activeCall,
              !call.isVideoEnabled,
              !call.isScreenSharing else {
            return
        }
#if DEBUG
        if call.id == -42 {
            activeCall = call.updating(isFrontCamera: frontCamera)
            return
        }
#endif
        guard !isCameraStarting, !isCameraSwitching else { return }
        videoSourcePreviewGeneration += 1
        let generation = videoSourcePreviewGeneration

        Task {
            guard await requestCameraPermission() else {
                guard generation == videoSourcePreviewGeneration else {
                    return
                }
                app?.errorMessage =
                    "Для предпросмотра разрешите Alo доступ к камере."
                return
            }
            guard generation == videoSourcePreviewGeneration,
                  activeCall?.id == call.id else {
                return
            }

            isCameraStarting = true
            do {
                try await ensureClient()
            } catch {
                guard generation == videoSourcePreviewGeneration else {
                    return
                }
                isCameraStarting = false
                app?.errorMessage = "Не удалось подготовить предпросмотр видео."
                return
            }

            guard generation == videoSourcePreviewGeneration,
                  let client,
                  let current = activeCall,
                  current.id == call.id else {
                isCameraStarting = false
                return
            }
            let result: Result<Void, Error> = await withCheckedContinuation {
                continuation in
                client.prepareCameraPreview(frontCamera: frontCamera) {
                    continuation.resume(returning: $0)
                }
            }
            guard generation == videoSourcePreviewGeneration,
                  let latest = activeCall,
                  latest.id == call.id else {
                return
            }
            isCameraStarting = false
            switch result {
            case .success:
                activeCall = latest.updating(isFrontCamera: frontCamera)
            case let .failure(error):
                app?.errorMessage = error.localizedDescription
            }
        }
    }

    func previewVideoSource(frontCamera: Bool) {
        guard let call = activeCall,
              !call.isVideoEnabled,
              !call.isScreenSharing,
              call.isFrontCamera != frontCamera,
              !isCameraStarting,
              !isCameraSwitching else {
            return
        }
#if DEBUG
        if call.id == -42 {
            activeCall = call.updating(isFrontCamera: frontCamera)
            return
        }
#endif
        guard let client else {
            beginVideoSourcePreview(frontCamera: frontCamera)
            return
        }

        let generation = videoSourcePreviewGeneration
        isCameraSwitching = true
        client.setCameraPosition(frontCamera: frontCamera) { [weak self] result in
            Task { @MainActor in
                guard let self,
                      generation == self.videoSourcePreviewGeneration,
                      let current = self.activeCall,
                      current.id == call.id else {
                    self?.isCameraSwitching = false
                    return
                }
                self.isCameraSwitching = false
                switch result {
                case .success:
                    self.activeCall = current.updating(
                        isFrontCamera: frontCamera
                    )
                case let .failure(error):
                    self.app?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelVideoSourcePreview() {
        videoSourcePreviewGeneration += 1
        isCameraStarting = false
        isCameraSwitching = false
        client?.cancelCameraPreview()
    }

    func commitVideoSource(_ source: AloCallVideoSource) {
        guard let call = activeCall else { return }
        videoSourcePreviewGeneration += 1
        isCameraStarting = false
        isCameraSwitching = false
#if DEBUG
        if call.id == -42 {
            activeCall = call.updating(
                isVideoEnabled: source.isCamera,
                isFrontCamera: source.usesFrontCamera,
                isScreenSharing: source == .screen
            )
            return
        }
#endif
        switch source {
        case .screen:
            client?.cancelCameraPreview()
            toggleScreenShare()
        case .frontCamera, .backCamera:
            activeCall = call.updating(
                isFrontCamera: source.usesFrontCamera
            )
            toggleVideo()
        }
    }

    func toggleScreenShare() {
        guard let call = activeCall else { return }
        guard !isScreenShareStarting, !isCameraStarting, !isCameraSwitching else { return }
#if DEBUG
        if call.id == -42 {
            let enabled = !call.isScreenSharing
            activeCall = call.updating(
                isVideoEnabled: enabled ? false : call.isVideo,
                isScreenSharing: enabled
            )
            return
        }
#endif
        if call.isScreenSharing {
            client?.setScreenSharingEnabled(false) { _ in }
            let shouldResumeCamera = resumeCameraAfterScreenShare
            resumeCameraAfterScreenShare = false
            if shouldResumeCamera {
                client?.setVideoEnabled(true, frontCamera: call.isFrontCamera)
            }
            let updated = call.updating(
                isVideoEnabled: shouldResumeCamera,
                isScreenSharing: false
            )
            activeCall = updated
            reportMediaCapabilityChange(updated)
            Task { await sendLocalMediaState(updated) }
            return
        }

        guard call.phase != .incoming else {
            app?.notice = "Сначала примите звонок."
            return
        }

        Task {
            do {
                try await ensureClient()
            } catch {
                app?.errorMessage = "Не удалось подготовить демонстрацию экрана."
                return
            }
            guard let client,
                  let current = activeCall,
                  current.id == call.id else { return }
            isScreenShareStarting = true
            resumeCameraAfterScreenShare = current.isVideoEnabled
            client.setScreenSharingEnabled(true) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.isScreenShareStarting = false
                    guard let latest = self.activeCall, latest.id == call.id else { return }
                    switch result {
                    case .success:
                        let updated = latest.updating(
                            isVideoEnabled: false,
                            isScreenSharing: true
                        )
                        self.activeCall = updated
                        self.reportMediaCapabilityChange(updated)
                        await self.sendLocalMediaState(updated)
                    case let .failure(error):
                        self.resumeCameraAfterScreenShare = false
                        self.app?.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func switchCamera() {
        guard let call = activeCall,
              call.isVideoEnabled,
              !call.isScreenSharing,
              !isCameraSwitching,
              !isScreenShareStarting else { return }
        let targetIsFrontCamera = !call.isFrontCamera
        isCameraSwitching = true
        Task {
            do {
                try await ensureClient()
                guard let client else {
                    throw AloAPIError(
                        status: 0,
                        code: "CAMERA_NOT_READY",
                        message: "Камера звонка ещё не готова.",
                        payload: [:]
                    )
                }
                let result = await withCheckedContinuation { continuation in
                    client.setCameraPosition(frontCamera: targetIsFrontCamera) {
                        continuation.resume(returning: $0)
                    }
                }
                guard let current = activeCall, current.id == call.id else {
                    isCameraSwitching = false
                    return
                }
                switch result {
                case .success:
                    activeCall = current.updating(isFrontCamera: targetIsFrontCamera)
                case let .failure(error):
                    app?.errorMessage = error.localizedDescription
                }
            } catch {
                app?.errorMessage = "Не удалось переключить камеру."
            }
            isCameraSwitching = false
        }
    }

    func bindLocalRenderer(_ renderer: RTCVideoRenderer?) {
        guard !sameRenderer(localVideoRenderer, renderer) else { return }
        localVideoRenderer = renderer
        client?.bindLocalRenderer(renderer)
    }

    func bindRemoteRenderer(_ renderer: RTCVideoRenderer?) {
        guard !sameRenderer(remoteVideoRenderer, renderer) else { return }
        remoteVideoRenderer = renderer
        client?.bindRemoteRenderer(renderer)
    }

    func unbindLocalRenderer(_ renderer: RTCVideoRenderer) {
        guard sameRenderer(localVideoRenderer, renderer) else { return }
        client?.bindLocalRenderer(nil)
        localVideoRenderer = nil
    }

    func unbindRemoteRenderer(_ renderer: RTCVideoRenderer) {
        guard sameRenderer(remoteVideoRenderer, renderer) else { return }
        client?.bindRemoteRenderer(nil)
        remoteVideoRenderer = nil
    }

    private func sameRenderer(
        _ lhs: RTCVideoRenderer?,
        _ rhs: RTCVideoRenderer?
    ) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return (lhs as AnyObject) === (rhs as AnyObject)
    }

    private func process(_ signals: [AloDirectCallSignal]) async {
        for signal in signals {
            switch signal.kind {
            case "invite":
                await handleInvite(signal)
            case "accept":
                await handleAccept(signal)
            case "security-commit":
                await handleSecurityCommit(signal)
            case "security-response":
                await handleSecurityResponse(signal)
            case "offer":
                await handleOffer(signal)
            case "answer":
                await handleAnswer(signal)
            case "security-confirm":
                await handleSecurityConfirm(signal)
            case "reconnect-offer":
                await handleReconnectOffer(signal)
            case "reconnect-answer":
                await handleReconnectAnswer(signal)
            case "ice":
                await handleICE(signal)
            case "media-state":
                handleMediaState(signal)
            case "busy":
                showTerminalState(
                    phase: .busy,
                    reason: .remoteEnded,
                    terminalTone: .busy
                )
            case "decline":
                showTerminalState(
                    phase: .declined,
                    reason: .declinedElsewhere,
                    terminalTone: .ended
                )
            case "hangup":
                handleRemoteHangup(signal)
            default:
                break
            }
        }
    }

    private func handleRemoteHangup(_ signal: AloDirectCallSignal) {
        guard let call = activeCall, call.id == signal.callId else { return }
        let status = signal.payload.string("status").ifBlank(signal.callStatus)
        let reason = signal.payload.string("reason")
        if call.phase == .outgoing, status == "missed" {
            showTerminalState(
                phase: .noAnswer,
                reason: .unanswered,
                terminalTone: .noAnswer
            )
        } else if status == "declined" || reason == "declined" {
            showTerminalState(
                phase: .declined,
                reason: .declinedElsewhere,
                terminalTone: .ended
            )
        } else {
            finish(reason: .remoteEnded, terminalTone: .ended)
        }
    }

    private func handleInvite(_ signal: AloDirectCallSignal) async {
        if activeCall?.phase.isTerminal == true {
            finish(reason: .remoteEnded, terminalTone: nil)
        }
        if let activeCall {
            if activeCall.id == signal.callId { return }
            try? await api.endDirectCall(callId: signal.callId, reason: "busy")
            return
        }
        do {
            securityHandshake = try AloCallSecurityHandshake(
                role: .callee,
                callId: signal.callId,
                callerId: signal.callerId,
                calleeId: signal.calleeId
            )
        } catch {
            try? await api.endDirectCall(callId: signal.callId, reason: "security_mismatch")
            return
        }
        let state = AloDirectCallState(
            id: signal.callId,
            uuid: callUUID(callId: signal.callId),
            peer: signal.fromUser,
            type: signal.callType,
            phase: .incoming,
            isIncoming: true,
            isMuted: false,
            isSpeakerOn: signal.callType == "video",
            isVideoEnabled: signal.callType == "video",
            isFrontCamera: true,
            startedAt: nil,
            callSecret: "",
            safetyEmojis: [],
            isSecurityConfirmed: false
        )
        activeCall = state
        isMinimized = false
        tonePlayer.prepareAudioRoute(
            speakerOn: state.isSpeakerOn,
            activate: !AloCallKitSupport.isAvailable
        )
        reportIncomingCall(state)
        scheduleRingTimeout(callId: state.id, outgoing: false)
    }

    private func handleAccept(_ signal: AloDirectCallSignal) async {
        guard let call = activeCall,
              call.id == signal.callId,
              call.phase == .outgoing else { return }
        ringTimeoutTask?.cancel()
        activeCall = call.updating(phase: .connecting)
        securityHandshake?.didAccept = true
        tonePlayer.play(.connecting)
        if AloCallKitSupport.isAvailable {
            provider.reportOutgoingCall(with: call.uuid, startedConnectingAt: Date())
        }
        if let handshake = securityHandshake, !handshake.didSendCommit {
            _ = await sendSecurityCommit(handshake)
        }
        await beginOutgoingIfSecurityReady()
    }

    private func sendSecurityCommit(
        _ handshake: AloCallSecurityHandshake,
        scheduleRetryOnFailure: Bool = true
    ) async -> Bool {
        guard handshake.role == .caller,
              let commitment = handshake.callerCommitment,
              let call = activeCall,
              call.id == handshake.callId else {
            return false
        }
        if handshake.didSendCommit { return true }
        let sent = await sendSignal(
            callId: call.id,
            peerId: call.peer.id,
            kind: "security-commit",
            payload: [
                "securityVersion": AloCallSecurityV2.version,
                "callerCommitment": AloCallSecurityV2.base64URL(commitment)
            ],
            retryBootstrapOnFailure: true
        )
        handshake.didSendCommit = sent
        if !sent, scheduleRetryOnFailure {
            scheduleSecurityBootstrapRetry(callId: call.id)
        }
        return sent
    }

    private func sendSecurityResponseIfReady(
        scheduleRetryOnFailure: Bool = true
    ) async -> Bool {
        guard let handshake = securityHandshake,
              handshake.role == .callee,
              handshake.didAccept,
              let commitment = handshake.callerCommitment,
              let call = activeCall,
              call.id == handshake.callId else {
            return true
        }
        if handshake.didSendResponse { return true }
        let sent = await sendSignal(
            callId: call.id,
            peerId: call.peer.id,
            kind: "security-response",
            payload: [
                "securityVersion": AloCallSecurityV2.version,
                "callerCommitment": AloCallSecurityV2.base64URL(commitment),
                "calleePublicKey": AloCallSecurityV2.base64URL(handshake.localKeyPair.publicKey),
                "calleeNonce": AloCallSecurityV2.base64URL(handshake.localNonce)
            ],
            retryBootstrapOnFailure: true
        )
        handshake.didSendResponse = sent
        if !sent, scheduleRetryOnFailure {
            scheduleSecurityBootstrapRetry(callId: call.id)
        }
        return sent
    }

    private func handleSecurityCommit(_ signal: AloDirectCallSignal) async {
        guard let handshake = securityHandshake,
              handshake.role == .callee,
              handshake.callId == signal.callId,
              signal.fromUserId == handshake.callerId,
              signal.payload.int("securityVersion") == AloCallSecurityV2.version else {
            await failCallSecurity()
            return
        }
        do {
            let commitment = try AloCallSecurityV2.decode32(
                signal.payload.string("callerCommitment")
            )
            if let current = handshake.callerCommitment,
               !AloCallSecurityV2.timingSafeEqual(current, commitment) {
                throw AloCallSecurityV2Error.invalidPayload
            }
            handshake.callerCommitment = commitment
            guard await sendSecurityResponseIfReady() else { return }
        } catch {
            await failCallSecurity()
        }
    }

    private func handleSecurityResponse(_ signal: AloDirectCallSignal) async {
        guard let handshake = securityHandshake,
              handshake.role == .caller,
              handshake.callId == signal.callId,
              signal.fromUserId == handshake.calleeId,
              signal.payload.int("securityVersion") == AloCallSecurityV2.version,
              let expectedCommitment = handshake.callerCommitment else {
            await failCallSecurity()
            return
        }
        do {
            let commitment = try AloCallSecurityV2.decode32(
                signal.payload.string("callerCommitment")
            )
            let publicKey = try AloCallSecurityV2.decode32(
                signal.payload.string("calleePublicKey")
            )
            let nonce = try AloCallSecurityV2.decode32(
                signal.payload.string("calleeNonce")
            )
            guard AloCallSecurityV2.timingSafeEqual(commitment, expectedCommitment) else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            if let current = handshake.remotePublicKey,
               !AloCallSecurityV2.timingSafeEqual(current, publicKey) {
                throw AloCallSecurityV2Error.invalidPayload
            }
            if let current = handshake.remoteNonce,
               !AloCallSecurityV2.timingSafeEqual(current, nonce) {
                throw AloCallSecurityV2Error.invalidPayload
            }
            handshake.remotePublicKey = publicKey
            handshake.remoteNonce = nonce
            _ = try handshake.deriveSharedKeyIfPossible()
            await beginOutgoingIfSecurityReady()
        } catch {
            await failCallSecurity()
        }
    }

    private func beginOutgoingIfSecurityReady() async {
        guard let handshake = securityHandshake,
              handshake.role == .caller,
              handshake.didAccept,
              handshake.remotePublicKey != nil,
              handshake.remoteNonce != nil,
              !handshake.didStartOffer else {
            return
        }
        handshake.didStartOffer = true
        do {
            _ = try handshake.deriveSharedKeyIfPossible()
            try await ensureClient()
            client?.prepareIncoming()
            client?.startOutgoing()
        } catch {
            await endNetworkCall(
                message: "Не удалось подготовить проверяемый защищённый звонок.",
                terminalTone: .failed
            )
        }
    }

    private func handleOffer(_ signal: AloDirectCallSignal) async {
        let sdp = signal.payload.string("sdp")
        guard let call = activeCall,
              let handshake = securityHandshake,
              call.id == signal.callId,
              handshake.role == .callee,
              signal.fromUserId == handshake.callerId,
              signal.payload.int("securityVersion") == AloCallSecurityV2.version,
              !sdp.isEmpty else {
            await failCallSecurity()
            return
        }
        do {
            let actualFingerprint = try requireDTLSFingerprint(sdp)
            let claimedFingerprint = signal.payload.string("offerFingerprint")
            guard actualFingerprint == claimedFingerprint,
                  let expectedCommitment = handshake.callerCommitment else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            let callerPublicKey = try AloCallSecurityV2.decode32(
                signal.payload.string("callerPublicKey")
            )
            let callerNonce = try AloCallSecurityV2.decode32(
                signal.payload.string("callerNonce")
            )
            let commitment = try AloCallSecurityV2.decode32(
                signal.payload.string("callerCommitment")
            )
            let echoedCalleePublicKey = try AloCallSecurityV2.decode32(
                signal.payload.string("calleePublicKey")
            )
            let echoedCalleeNonce = try AloCallSecurityV2.decode32(
                signal.payload.string("calleeNonce")
            )
            let callerProof = try AloCallSecurityV2.decode32(
                signal.payload.string("callerProof")
            )
            let recomputedCommitment = try AloCallSecurityV2.commitment(
                callId: handshake.callId,
                callerId: handshake.callerId,
                calleeId: handshake.calleeId,
                callerPublicKey: callerPublicKey,
                callerNonce: callerNonce
            )
            guard AloCallSecurityV2.timingSafeEqual(commitment, expectedCommitment),
                  AloCallSecurityV2.timingSafeEqual(commitment, recomputedCommitment),
                  AloCallSecurityV2.timingSafeEqual(
                      echoedCalleePublicKey,
                      handshake.localKeyPair.publicKey
                  ),
                  AloCallSecurityV2.timingSafeEqual(
                      echoedCalleeNonce,
                      handshake.localNonce
                  ) else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            handshake.remotePublicKey = callerPublicKey
            handshake.remoteNonce = callerNonce
            handshake.offerFingerprint = actualFingerprint
            let sharedKey = try handshake.deriveSharedKeyIfPossible()
            let offerHash = try offerTranscriptHash(handshake)
            let expectedProof = try AloCallSecurityV2.proof(
                sharedKey: sharedKey,
                role: "caller-offer",
                transcriptHash: offerHash
            )
            guard AloCallSecurityV2.timingSafeEqual(callerProof, expectedProof) else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            try await ensureClient()
            client?.prepareIncoming()
            client?.handleRemoteOffer(sdp)
            if call.phase == .incoming {
                activeCall = call.updating(phase: .connecting)
                tonePlayer.play(.connecting)
            }
        } catch {
            await failCallSecurity()
        }
    }

    private func handleAnswer(_ signal: AloDirectCallSignal) async {
        let sdp = signal.payload.string("sdp")
        guard let call = activeCall,
              let handshake = securityHandshake,
              call.id == signal.callId,
              handshake.role == .caller,
              signal.fromUserId == handshake.calleeId,
              signal.payload.int("securityVersion") == AloCallSecurityV2.version,
              !sdp.isEmpty else {
            await failCallSecurity()
            return
        }
        do {
            let actualFingerprint = try requireDTLSFingerprint(sdp)
            let claimedFingerprint = signal.payload.string("answerFingerprint")
            let echoedOfferFingerprint = signal.payload.string("offerFingerprint")
            let commitment = try AloCallSecurityV2.decode32(
                signal.payload.string("callerCommitment")
            )
            let calleePublicKey = try AloCallSecurityV2.decode32(
                signal.payload.string("calleePublicKey")
            )
            let calleeNonce = try AloCallSecurityV2.decode32(
                signal.payload.string("calleeNonce")
            )
            let claimedTranscript = try AloCallSecurityV2.decode32(
                signal.payload.string("transcriptHash")
            )
            let calleeProof = try AloCallSecurityV2.decode32(
                signal.payload.string("calleeProof")
            )
            guard actualFingerprint == claimedFingerprint,
                  echoedOfferFingerprint == handshake.offerFingerprint,
                  let expectedCommitment = handshake.callerCommitment,
                  let expectedCalleePublicKey = handshake.remotePublicKey,
                  let expectedCalleeNonce = handshake.remoteNonce,
                  AloCallSecurityV2.timingSafeEqual(commitment, expectedCommitment),
                  AloCallSecurityV2.timingSafeEqual(calleePublicKey, expectedCalleePublicKey),
                  AloCallSecurityV2.timingSafeEqual(calleeNonce, expectedCalleeNonce) else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            handshake.answerFingerprint = actualFingerprint
            let transcript = try fullTranscriptHash(handshake)
            guard AloCallSecurityV2.timingSafeEqual(transcript, claimedTranscript) else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            let sharedKey = try handshake.deriveSharedKeyIfPossible()
            let expectedProof = try AloCallSecurityV2.proof(
                sharedKey: sharedKey,
                role: "callee-answer",
                transcriptHash: transcript
            )
            guard AloCallSecurityV2.timingSafeEqual(calleeProof, expectedProof) else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            handshake.transcriptHash = transcript
            try await ensureClient()
            client?.handleRemoteAnswer(sdp)
            let callerProof = try AloCallSecurityV2.proof(
                sharedKey: sharedKey,
                role: "caller-confirm",
                transcriptHash: transcript
            )
            handshake.didSendConfirm = true
            let sent = await sendSignal(
                callId: call.id,
                peerId: call.peer.id,
                kind: "security-confirm",
                payload: [
                    "securityVersion": AloCallSecurityV2.version,
                    "transcriptHash": AloCallSecurityV2.base64URL(transcript),
                    "callerProof": AloCallSecurityV2.base64URL(callerProof)
                ]
            )
            guard sent else { return }
            try markCallSecurityConfirmed(handshake)
        } catch {
            await failCallSecurity()
        }
    }

    private func handleSecurityConfirm(_ signal: AloDirectCallSignal) async {
        guard let handshake = securityHandshake,
              handshake.role == .callee,
              handshake.callId == signal.callId,
              signal.fromUserId == handshake.callerId,
              signal.payload.int("securityVersion") == AloCallSecurityV2.version,
              let expectedTranscript = handshake.transcriptHash else {
            await failCallSecurity()
            return
        }
        do {
            let transcript = try AloCallSecurityV2.decode32(
                signal.payload.string("transcriptHash")
            )
            let callerProof = try AloCallSecurityV2.decode32(
                signal.payload.string("callerProof")
            )
            let sharedKey = try handshake.deriveSharedKeyIfPossible()
            let expectedProof = try AloCallSecurityV2.proof(
                sharedKey: sharedKey,
                role: "caller-confirm",
                transcriptHash: expectedTranscript
            )
            guard AloCallSecurityV2.timingSafeEqual(transcript, expectedTranscript),
                  AloCallSecurityV2.timingSafeEqual(callerProof, expectedProof) else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            try markCallSecurityConfirmed(handshake)
        } catch {
            await failCallSecurity()
        }
    }

    private func handleReconnectOffer(_ signal: AloDirectCallSignal) async {
        guard let call = activeCall,
              let handshake = securityHandshake,
              call.id == signal.callId,
              handshake.role == .callee,
              handshake.isConfirmed,
              signal.fromUserId == handshake.callerId,
              signal.payload.int("securityVersion") == AloCallSecurityV2.version,
              let initialTranscript = handshake.transcriptHash,
              let sharedKey = handshake.sharedKey,
              let client else {
            return
        }
        do {
            let generation = signal.payload.int("generation")
            guard generation > handshake.lastHandledReconnectGeneration else { return }
            let sdp = signal.payload.string("sdp")
            let fingerprint = try requireDTLSFingerprint(sdp)
            let claimedInitialTranscript = try AloCallSecurityV2.decode32(
                signal.payload.string("initialTranscriptHash")
            )
            let claimedOfferHash = try AloCallSecurityV2.decode32(
                signal.payload.string("offerSdpHash")
            )
            let callerProof = try AloCallSecurityV2.decode32(
                signal.payload.string("callerProof")
            )
            let computedOfferHash = AloCallSecurityV2.sdpHash(sdp)
            guard fingerprint == handshake.offerFingerprint,
                  signal.payload.string("offerFingerprint") == fingerprint,
                  AloCallSecurityV2.timingSafeEqual(
                      claimedInitialTranscript,
                      initialTranscript
                  ),
                  AloCallSecurityV2.timingSafeEqual(
                      claimedOfferHash,
                      computedOfferHash
                  ) else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            let reconnectHash = try AloCallSecurityV2.reconnectTranscriptHash(
                callId: call.id,
                generation: generation,
                initialTranscriptHash: initialTranscript,
                offerFingerprint: fingerprint,
                offerSdpHash: computedOfferHash
            )
            let expectedProof = try AloCallSecurityV2.proof(
                sharedKey: sharedKey,
                role: "caller-reconnect-offer",
                transcriptHash: reconnectHash
            )
            guard AloCallSecurityV2.timingSafeEqual(callerProof, expectedProof) else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            handshake.reconnectGeneration = generation
            handshake.lastHandledReconnectGeneration = generation
            handshake.reconnectOfferHash = computedOfferHash
            enterReconnecting(callId: call.id)
            client.handleRemoteReconnectOffer(sdp)
        } catch {
            await failCallSecurity()
        }
    }

    private func handleReconnectAnswer(_ signal: AloDirectCallSignal) async {
        guard let call = activeCall,
              let handshake = securityHandshake,
              call.id == signal.callId,
              handshake.role == .caller,
              handshake.isConfirmed,
              signal.fromUserId == handshake.calleeId,
              signal.payload.int("securityVersion") == AloCallSecurityV2.version,
              let initialTranscript = handshake.transcriptHash,
              let sharedKey = handshake.sharedKey,
              let expectedOfferHash = handshake.reconnectOfferHash,
              let client else {
            return
        }
        do {
            let generation = signal.payload.int("generation")
            guard generation == handshake.reconnectGeneration,
                  generation > handshake.lastHandledReconnectGeneration else {
                return
            }
            let sdp = signal.payload.string("sdp")
            let fingerprint = try requireDTLSFingerprint(sdp)
            let claimedInitialTranscript = try AloCallSecurityV2.decode32(
                signal.payload.string("initialTranscriptHash")
            )
            let claimedOfferHash = try AloCallSecurityV2.decode32(
                signal.payload.string("offerSdpHash")
            )
            let claimedAnswerHash = try AloCallSecurityV2.decode32(
                signal.payload.string("answerSdpHash")
            )
            let calleeProof = try AloCallSecurityV2.decode32(
                signal.payload.string("calleeProof")
            )
            let computedAnswerHash = AloCallSecurityV2.sdpHash(sdp)
            guard fingerprint == handshake.answerFingerprint,
                  signal.payload.string("offerFingerprint") == handshake.offerFingerprint,
                  signal.payload.string("answerFingerprint") == fingerprint,
                  AloCallSecurityV2.timingSafeEqual(
                      claimedInitialTranscript,
                      initialTranscript
                  ),
                  AloCallSecurityV2.timingSafeEqual(
                      claimedOfferHash,
                      expectedOfferHash
                  ),
                  AloCallSecurityV2.timingSafeEqual(
                      claimedAnswerHash,
                      computedAnswerHash
                  ) else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            let reconnectHash = try AloCallSecurityV2.reconnectTranscriptHash(
                callId: call.id,
                generation: generation,
                initialTranscriptHash: initialTranscript,
                offerFingerprint: handshake.offerFingerprint,
                offerSdpHash: expectedOfferHash,
                answerFingerprint: fingerprint,
                answerSdpHash: computedAnswerHash
            )
            let expectedProof = try AloCallSecurityV2.proof(
                sharedKey: sharedKey,
                role: "callee-reconnect-answer",
                transcriptHash: reconnectHash
            )
            guard AloCallSecurityV2.timingSafeEqual(calleeProof, expectedProof) else {
                throw AloCallSecurityV2Error.invalidPayload
            }
            handshake.lastHandledReconnectGeneration = generation
            client.handleRemoteReconnectAnswer(sdp)
        } catch {
            await failCallSecurity()
        }
    }

    private func handleICE(_ signal: AloDirectCallSignal) async {
        guard let call = activeCall, call.id == signal.callId else { return }
        let candidate = signal.payload.string("candidate")
        let sdpMid = signal.payload.string("sdpMid")
        let lineIndex = signal.payload.int("sdpMLineIndex")
        guard !candidate.isEmpty, !sdpMid.isEmpty, lineIndex >= 0 else { return }
        do {
            try await ensureClient()
            client?.addRemoteIceCandidate(
                sdpMid: sdpMid,
                lineIndex: Int32(lineIndex),
                candidate: candidate
            )
        } catch {
            await endNetworkCall(message: "Не удалось подключить звонок.")
        }
    }

    private func handleMediaState(_ signal: AloDirectCallSignal) {
        guard let call = activeCall,
              call.id == signal.callId,
              signal.fromUserId == call.peer.id else {
            return
        }
        let updated = call.updating(
            isRemoteVideoEnabled: signal.payload.bool("videoEnabled"),
            isRemoteScreenSharing: signal.payload.bool("screenSharing")
        )
        activeCall = updated
        reportMediaCapabilityChange(updated)
    }

    private func ensureClient() async throws {
        if client != nil { return }
        guard let call = activeCall else { return }
        let configuration: AloRTCConfiguration
        if let cached = rtcConfiguration {
            configuration = cached
        } else {
            configuration = try await api.loadRTCConfiguration()
            rtcConfiguration = configuration
        }
        let callId = call.id
        let peerId = call.peer.id
        let created = try AloWebRTCCallClient(
            configuration: configuration,
            enableVideo: false,
            frontCamera: call.isFrontCamera,
            onLocalDescription: { [weak self] kind, sdp in
                Task { @MainActor in
                    await self?.sendLocalDescription(
                        callId: callId,
                        peerId: peerId,
                        kind: kind,
                        sdp: sdp
                    )
                }
            },
            onIceCandidate: { [weak self] sdpMid, lineIndex, candidate in
                Task { @MainActor in
                    await self?.sendSignal(
                        callId: callId,
                        peerId: peerId,
                        kind: "ice",
                        payload: [
                            "sdpMid": sdpMid,
                            "sdpMLineIndex": Int(lineIndex),
                            "candidate": candidate
                        ]
                    )
                }
            },
            onConnectionStateChanged: { [weak self] state in
                Task { @MainActor in
                    self?.handleConnectionState(state, callId: callId)
                }
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    self?.app?.errorMessage = message
                }
            }
        )
        created.bindLocalRenderer(localVideoRenderer)
        created.bindRemoteRenderer(remoteVideoRenderer)
        created.setMuted(call.isMuted)
        created.setSpeakerOn(call.isSpeakerOn)
        client = created
        if call.isVideoEnabled {
            let result = await withCheckedContinuation { continuation in
                created.setVideoEnabled(true, frontCamera: call.isFrontCamera) {
                    continuation.resume(returning: $0)
                }
            }
            if case let .failure(error) = result {
                throw error
            }
        }
    }

    private func sendLocalDescription(
        callId: Int,
        peerId: Int,
        kind: String,
        sdp: String
    ) async {
        guard let handshake = securityHandshake,
              handshake.callId == callId else {
            await failCallSecurity()
            return
        }
        do {
            let fingerprint = try requireDTLSFingerprint(sdp)
            let payload: [String: Any]
            switch kind {
            case "offer":
                guard handshake.role == .caller,
                      let commitment = handshake.callerCommitment,
                      let callerPublicKey = handshake.callerPublicKey,
                      let callerNonce = handshake.callerNonce,
                      let calleePublicKey = handshake.calleePublicKey,
                      let calleeNonce = handshake.calleeNonce else {
                    throw AloCallSecurityV2Error.invalidPayload
                }
                if !handshake.offerFingerprint.isEmpty,
                   handshake.offerFingerprint != fingerprint {
                    throw AloCallSecurityV2Error.invalidPayload
                }
                handshake.offerFingerprint = fingerprint
                let sharedKey = try handshake.deriveSharedKeyIfPossible()
                let offerHash = try offerTranscriptHash(handshake)
                let callerProof = try AloCallSecurityV2.proof(
                    sharedKey: sharedKey,
                    role: "caller-offer",
                    transcriptHash: offerHash
                )
                payload = [
                    "sdp": sdp,
                    "securityVersion": AloCallSecurityV2.version,
                    "callerCommitment": AloCallSecurityV2.base64URL(commitment),
                    "callerPublicKey": AloCallSecurityV2.base64URL(callerPublicKey),
                    "callerNonce": AloCallSecurityV2.base64URL(callerNonce),
                    "calleePublicKey": AloCallSecurityV2.base64URL(calleePublicKey),
                    "calleeNonce": AloCallSecurityV2.base64URL(calleeNonce),
                    "offerFingerprint": fingerprint,
                    "callerProof": AloCallSecurityV2.base64URL(callerProof)
                ]
            case "answer":
                guard handshake.role == .callee,
                      let commitment = handshake.callerCommitment,
                      let calleePublicKey = handshake.calleePublicKey,
                      let calleeNonce = handshake.calleeNonce,
                      !handshake.offerFingerprint.isEmpty else {
                    throw AloCallSecurityV2Error.invalidPayload
                }
                if !handshake.answerFingerprint.isEmpty,
                   handshake.answerFingerprint != fingerprint {
                    throw AloCallSecurityV2Error.invalidPayload
                }
                handshake.answerFingerprint = fingerprint
                let sharedKey = try handshake.deriveSharedKeyIfPossible()
                let transcript = try fullTranscriptHash(handshake)
                handshake.transcriptHash = transcript
                let calleeProof = try AloCallSecurityV2.proof(
                    sharedKey: sharedKey,
                    role: "callee-answer",
                    transcriptHash: transcript
                )
                payload = [
                    "sdp": sdp,
                    "securityVersion": AloCallSecurityV2.version,
                    "callerCommitment": AloCallSecurityV2.base64URL(commitment),
                    "calleePublicKey": AloCallSecurityV2.base64URL(calleePublicKey),
                    "calleeNonce": AloCallSecurityV2.base64URL(calleeNonce),
                    "offerFingerprint": handshake.offerFingerprint,
                    "answerFingerprint": fingerprint,
                    "transcriptHash": AloCallSecurityV2.base64URL(transcript),
                    "calleeProof": AloCallSecurityV2.base64URL(calleeProof)
                ]
            case "reconnect-offer":
                guard handshake.role == .caller,
                      handshake.isConfirmed,
                      handshake.reconnectGeneration > 0,
                      let initialTranscript = handshake.transcriptHash,
                      let sharedKey = handshake.sharedKey,
                      fingerprint == handshake.offerFingerprint else {
                    throw AloCallSecurityV2Error.invalidPayload
                }
                let offerSdpHash = AloCallSecurityV2.sdpHash(sdp)
                handshake.reconnectOfferHash = offerSdpHash
                let reconnectHash = try AloCallSecurityV2.reconnectTranscriptHash(
                    callId: callId,
                    generation: handshake.reconnectGeneration,
                    initialTranscriptHash: initialTranscript,
                    offerFingerprint: fingerprint,
                    offerSdpHash: offerSdpHash
                )
                let proof = try AloCallSecurityV2.proof(
                    sharedKey: sharedKey,
                    role: "caller-reconnect-offer",
                    transcriptHash: reconnectHash
                )
                payload = [
                    "sdp": sdp,
                    "securityVersion": AloCallSecurityV2.version,
                    "generation": handshake.reconnectGeneration,
                    "initialTranscriptHash": AloCallSecurityV2.base64URL(initialTranscript),
                    "offerFingerprint": fingerprint,
                    "offerSdpHash": AloCallSecurityV2.base64URL(offerSdpHash),
                    "callerProof": AloCallSecurityV2.base64URL(proof)
                ]
            case "reconnect-answer":
                guard handshake.role == .callee,
                      handshake.isConfirmed,
                      handshake.reconnectGeneration > 0,
                      let initialTranscript = handshake.transcriptHash,
                      let sharedKey = handshake.sharedKey,
                      let offerSdpHash = handshake.reconnectOfferHash,
                      fingerprint == handshake.answerFingerprint else {
                    throw AloCallSecurityV2Error.invalidPayload
                }
                let answerSdpHash = AloCallSecurityV2.sdpHash(sdp)
                let reconnectHash = try AloCallSecurityV2.reconnectTranscriptHash(
                    callId: callId,
                    generation: handshake.reconnectGeneration,
                    initialTranscriptHash: initialTranscript,
                    offerFingerprint: handshake.offerFingerprint,
                    offerSdpHash: offerSdpHash,
                    answerFingerprint: fingerprint,
                    answerSdpHash: answerSdpHash
                )
                let proof = try AloCallSecurityV2.proof(
                    sharedKey: sharedKey,
                    role: "callee-reconnect-answer",
                    transcriptHash: reconnectHash
                )
                payload = [
                    "sdp": sdp,
                    "securityVersion": AloCallSecurityV2.version,
                    "generation": handshake.reconnectGeneration,
                    "initialTranscriptHash": AloCallSecurityV2.base64URL(initialTranscript),
                    "offerFingerprint": handshake.offerFingerprint,
                    "offerSdpHash": AloCallSecurityV2.base64URL(offerSdpHash),
                    "answerFingerprint": fingerprint,
                    "answerSdpHash": AloCallSecurityV2.base64URL(answerSdpHash),
                    "calleeProof": AloCallSecurityV2.base64URL(proof)
                ]
            default:
                throw AloCallSecurityV2Error.invalidPayload
            }
            _ = await sendSignal(
                callId: callId,
                peerId: peerId,
                kind: kind,
                payload: payload
            )
        } catch {
            await failCallSecurity()
        }
    }

    private func offerTranscriptHash(
        _ handshake: AloCallSecurityHandshake
    ) throws -> Data {
        guard let commitment = handshake.callerCommitment,
              let callerPublicKey = handshake.callerPublicKey,
              let callerNonce = handshake.callerNonce,
              let calleePublicKey = handshake.calleePublicKey,
              let calleeNonce = handshake.calleeNonce else {
            throw AloCallSecurityV2Error.invalidPayload
        }
        return try AloCallSecurityV2.offerTranscriptHash(
            callId: handshake.callId,
            callerId: handshake.callerId,
            calleeId: handshake.calleeId,
            callerCommitment: commitment,
            callerPublicKey: callerPublicKey,
            callerNonce: callerNonce,
            calleePublicKey: calleePublicKey,
            calleeNonce: calleeNonce,
            offerFingerprint: handshake.offerFingerprint
        )
    }

    private func fullTranscriptHash(
        _ handshake: AloCallSecurityHandshake
    ) throws -> Data {
        guard let commitment = handshake.callerCommitment,
              let callerPublicKey = handshake.callerPublicKey,
              let callerNonce = handshake.callerNonce,
              let calleePublicKey = handshake.calleePublicKey,
              let calleeNonce = handshake.calleeNonce else {
            throw AloCallSecurityV2Error.invalidPayload
        }
        return try AloCallSecurityV2.transcriptHash(
            callId: handshake.callId,
            callerId: handshake.callerId,
            calleeId: handshake.calleeId,
            callerCommitment: commitment,
            callerPublicKey: callerPublicKey,
            callerNonce: callerNonce,
            calleePublicKey: calleePublicKey,
            calleeNonce: calleeNonce,
            offerFingerprint: handshake.offerFingerprint,
            answerFingerprint: handshake.answerFingerprint
        )
    }

    private func markCallSecurityConfirmed(
        _ handshake: AloCallSecurityHandshake
    ) throws {
        guard let call = activeCall,
              call.id == handshake.callId,
              let sharedKey = handshake.sharedKey,
              let transcript = handshake.transcriptHash,
              let callerPublicKey = handshake.callerPublicKey else {
            throw AloCallSecurityV2Error.invalidPayload
        }
        let emojis = try AloCallSecurityV2.emojis(
            sharedKey: sharedKey,
            transcriptHash: transcript,
            callerPublicKey: callerPublicKey
        )
        handshake.isConfirmed = true
        activeCall = call.updating(
            callSecret: AloCallSecurityV2.base64URL(sharedKey),
            safetyEmojis: emojis,
            isSecurityConfirmed: true
        )
    }

    private func requireDTLSFingerprint(_ sdp: String) throws -> String {
        guard let fingerprint = AloCallSecurityV2.dtlsFingerprint(from: sdp) else {
            throw AloCallSecurityV2Error.missingDTLSFingerprint
        }
        return fingerprint
    }

    private func failCallSecurity() async {
        await endNetworkCall(
            message: "Проверка защищённого соединения звонка не прошла.",
            terminalTone: .failed
        )
    }

    @discardableResult
    private func sendSignal(
        callId: Int,
        peerId: Int,
        kind: String,
        payload: [String: Any],
        retryBootstrapOnFailure: Bool = false
    ) async -> Bool {
        guard activeCall?.id == callId else { return false }
        let failureMessage: String
        let failureIsRetryable: Bool
        do {
            try await api.sendDirectCallSignal(
                callId: callId,
                kind: kind,
                payload: payload,
                peerId: peerId
            )
            return true
        } catch let error as AloAPIError {
            failureMessage = error.message
            failureIsRetryable = isRetryableSecurityBootstrapFailure(error)
        } catch {
            failureMessage = "Не удалось отправить защищённый сигнал звонка."
            failureIsRetryable = true
        }

        if retryBootstrapOnFailure, failureIsRetryable {
            return false
        }
        guard kind != "ice", kind != "media-state" else {
            // A later ICE candidate or media state update can still arrive.
            return false
        }
        if kind == "reconnect-offer" || kind == "reconnect-answer" {
            // The reconnect loop retries after transport or signaling recovers.
            return false
        }
        await endNetworkCall(message: failureMessage, terminalTone: .failed)
        return false
    }

    private func isRetryableSecurityBootstrapFailure(_ error: AloAPIError) -> Bool {
        let fatalSecurityCodes: Set<String> = [
            "E2EE_KEY_CHANGED",
            "E2EE_IDENTITY_DOWNGRADE_BLOCKED",
            "E2EE_SENDER_IDENTITY_INVALID",
            "E2EE_SENDER_IDENTITY_MISMATCH",
            "LIBSIGNAL_IDENTITY_FINGERPRINT_INVALID"
        ]
        if fatalSecurityCodes.contains(error.code) {
            return false
        }
        if error.status <= 0 {
            return true
        }
        return error.status == 408 ||
            error.status == 425 ||
            error.status == 429 ||
            error.status >= 500
    }

    private func sendLocalMediaState(_ call: AloDirectCallState) async {
        await sendSignal(
            callId: call.id,
            peerId: call.peer.id,
            kind: "media-state",
            payload: [
                "videoEnabled": call.isVideoEnabled,
                "screenSharing": call.isScreenSharing
            ]
        )
    }

    private func reportMediaCapabilityChange(_ call: AloDirectCallState) {
        guard AloCallKitSupport.isAvailable else { return }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: call.peer.name)
        update.localizedCallerName = call.peer.name
        update.hasVideo = call.hasVideoSurface
        provider.reportCall(with: call.uuid, updated: update)
    }

    private func handleConnectionState(_ state: AloWebRTCConnectionState, callId: Int) {
        guard let call = activeCall, call.id == callId else { return }
        switch state {
        case .connected:
            guard !call.phase.isTerminal else { return }
            disconnectTimeoutTask?.cancel()
            disconnectTimeoutTask = nil
            reconnectAttemptTask?.cancel()
            reconnectAttemptTask = nil
            ringTimeoutTask?.cancel()
            tonePlayer.stop()
            tonePlayer.play(.connected)
            let startedAt = call.startedAt ?? Date()
            let connected = call.updating(phase: .active, startedAt: startedAt)
            activeCall = connected
            Task { await sendLocalMediaState(connected) }
            if AloCallKitSupport.isAvailable, !call.isIncoming {
                provider.reportOutgoingCall(with: call.uuid, connectedAt: startedAt)
            }
        case .connecting:
            if call.phase != .active, call.phase != .reconnecting, !call.phase.isTerminal {
                tonePlayer.play(.connecting)
                activeCall = call.updating(phase: .connecting)
            }
        case .disconnected:
            enterReconnecting(callId: callId)
        case .failed:
            enterReconnecting(callId: callId)
        case .closed:
            if !remoteTermination, !call.phase.isTerminal {
                finish(reason: .remoteEnded, terminalTone: .ended)
            }
        case .new:
            break
        }
    }

    private func handleVoIPPush(_ payload: [AnyHashable: Any]) async {
        let alo = payload["alo"] as? [String: Any] ?? payload as? [String: Any] ?? [:]
        let callId = (alo["callId"] as? NSNumber)?.intValue
            ?? Int(String(describing: alo["callId"] ?? "")) ?? 0
        guard callId > 0 else {
            startPolling()
            return
        }
        if activeCall?.phase.isTerminal == true {
            finish(reason: .remoteEnded, terminalTone: nil)
        }
        if activeCall?.id == callId { return }
        if activeCall != nil {
            try? await api.endDirectCall(callId: callId, reason: "busy")
            return
        }
        let peer = AloDirectCallPeer(
            id: (alo["callerId"] as? NSNumber)?.intValue
                ?? Int(String(describing: alo["callerId"] ?? "")) ?? 0,
            name: String(describing: alo["callerName"] ?? "Собеседник"),
            username: String(describing: alo["callerUsername"] ?? ""),
            avatarURL: String(describing: alo["callerAvatar"] ?? ""),
            verified: (alo["callerVerified"] as? NSNumber)?.boolValue ?? false
        )
        guard let meId = app?.bootstrap?.me.id,
              let handshake = try? AloCallSecurityHandshake(
                  role: .callee,
                  callId: callId,
                  callerId: peer.id,
                  calleeId: meId
              ) else {
            startPolling()
            return
        }
        securityHandshake = handshake
        let state = AloDirectCallState(
            id: callId,
            uuid: callUUID(callId: callId),
            peer: peer,
            type: String(describing: alo["callType"] ?? "voice"),
            phase: .incoming,
            isIncoming: true,
            isMuted: false,
            isSpeakerOn: String(describing: alo["callType"] ?? "voice") == "video",
            isVideoEnabled: String(describing: alo["callType"] ?? "voice") == "video",
            isFrontCamera: true,
            startedAt: nil,
            callSecret: "",
            safetyEmojis: [],
            isSecurityConfirmed: false
        )
        activeCall = state
        tonePlayer.prepareAudioRoute(
            speakerOn: state.isSpeakerOn,
            activate: !AloCallKitSupport.isAvailable
        )
        reportIncomingCall(state)
        scheduleRingTimeout(callId: state.id, outgoing: false)
        startPolling()
    }

    private func requestCallKitStart(_ call: AloDirectCallState) async throws {
        guard AloCallKitSupport.isAvailable else { return }
        let handle = CXHandle(type: .generic, value: call.peer.name)
        let action = CXStartCallAction(call: call.uuid, handle: handle)
        action.isVideo = call.isVideo
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callController.request(CXTransaction(action: action)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func reportIncomingCall(_ call: AloDirectCallState) {
        guard AloCallKitSupport.isAvailable else {
            tonePlayer.play(.incoming)
            return
        }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: call.peer.name)
        update.localizedCallerName = call.peer.name
        update.hasVideo = call.isVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportNewIncomingCall(with: call.uuid, update: update) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                await self?.decline()
            }
        }
    }

    private func endNetworkCall(
        message: String? = nil,
        terminalTone: AloCallTone = .ended
    ) async {
        guard let call = activeCall else { return }
        let reason = call.phase == .outgoing ? "ended" : ""
        if message?.isEmpty == false {
            showTerminalState(
                phase: .interrupted,
                reason: .failed,
                terminalTone: terminalTone
            )
        } else {
            finish(reason: .remoteEnded, terminalTone: terminalTone)
        }
        try? await api.endDirectCall(callId: call.id, reason: reason)
    }

    private func finish(
        message: String? = nil,
        reason: CXCallEndedReason,
        terminalTone: AloCallTone?
    ) {
        guard let call = activeCall else { return }
        remoteTermination = true
        client?.close()
        client = nil
        securityHandshake = nil
        remoteTermination = false
        ringTimeoutTask?.cancel()
        disconnectTimeoutTask?.cancel()
        disconnectTimeoutTask = nil
        reconnectAttemptTask?.cancel()
        reconnectAttemptTask = nil
        securityBootstrapRetryTask?.cancel()
        securityBootstrapRetryTask = nil
        terminalDismissTask?.cancel()
        terminalDismissTask = nil
        tonePlayer.stop()
        if AloCallKitSupport.isAvailable {
            provider.reportCall(with: call.uuid, endedAt: Date(), reason: reason)
        }
        activeCall = nil
        isMinimized = false
        isScreenShareStarting = false
        isCameraStarting = false
        isCameraSwitching = false
        resumeCameraAfterScreenShare = false
        videoSourcePreviewGeneration += 1
        if let terminalTone {
            tonePlayer.play(terminalTone)
        }
        if let message, !message.isEmpty {
            app?.errorMessage = message
        }
    }

    private func showTerminalState(
        phase: AloDirectCallPhase,
        reason: CXCallEndedReason,
        terminalTone: AloCallTone
    ) {
        guard phase.isTerminal, let call = activeCall else { return }
        remoteTermination = true
        client?.close()
        client = nil
        securityHandshake = nil
        remoteTermination = false
        ringTimeoutTask?.cancel()
        disconnectTimeoutTask?.cancel()
        disconnectTimeoutTask = nil
        reconnectAttemptTask?.cancel()
        reconnectAttemptTask = nil
        securityBootstrapRetryTask?.cancel()
        securityBootstrapRetryTask = nil
        terminalDismissTask?.cancel()
        tonePlayer.stop()
        if AloCallKitSupport.isAvailable {
            provider.reportCall(with: call.uuid, endedAt: Date(), reason: reason)
        }

        activeCall = call.updating(
            phase: phase,
            isVideoEnabled: false,
            isScreenSharing: false,
            isRemoteVideoEnabled: false,
            isRemoteScreenSharing: false
        )
        isScreenShareStarting = false
        isCameraStarting = false
        isCameraSwitching = false
        resumeCameraAfterScreenShare = false
        videoSourcePreviewGeneration += 1
        app?.errorMessage = ""
        tonePlayer.prepareAudioRoute(speakerOn: call.isSpeakerOn, activate: true)
        tonePlayer.play(terminalTone)

        let callId = call.id
        terminalDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_450_000_000)
            guard !Task.isCancelled,
                  let self,
                  let current = self.activeCall,
                  current.id == callId,
                  current.phase == phase else { return }
            self.activeCall = nil
            self.isMinimized = false
            self.terminalDismissTask = nil
        }
    }

    private func scheduleRingTimeout(callId: Int, outgoing: Bool) {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  let call = self.activeCall,
                  call.id == callId,
                  call.phase == .outgoing || call.phase == .incoming else { return }
            try? await self.api.endDirectCall(callId: callId)
            if outgoing {
                self.showTerminalState(
                    phase: .noAnswer,
                    reason: .unanswered,
                    terminalTone: .noAnswer
                )
            } else {
                self.finish(reason: .remoteEnded, terminalTone: .ended)
            }
        }
    }

    private func scheduleSecurityBootstrapRetry(callId: Int) {
        guard securityBootstrapRetryTask == nil else { return }
        securityBootstrapRetryTask = Task { [weak self] in
            defer { self?.securityBootstrapRetryTask = nil }
            var delay: UInt64 = 700_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled,
                      let self,
                      let call = self.activeCall,
                      call.id == callId,
                      !call.phase.isTerminal,
                      let handshake = self.securityHandshake,
                      handshake.callId == callId else {
                    return
                }

                let sent: Bool
                switch handshake.role {
                case .caller:
                    if handshake.didSendCommit { return }
                    sent = await self.sendSecurityCommit(
                        handshake,
                        scheduleRetryOnFailure: false
                    )
                case .callee:
                    guard handshake.didAccept, handshake.callerCommitment != nil else {
                        delay = 1_200_000_000
                        continue
                    }
                    if handshake.didSendResponse { return }
                    sent = await self.sendSecurityResponseIfReady(
                        scheduleRetryOnFailure: false
                    )
                }
                if sent { return }
                delay = min(delay + 500_000_000, 2_000_000_000)
            }
        }
    }

    private func enterReconnecting(callId: Int) {
        guard let call = activeCall,
              call.id == callId,
              !call.phase.isTerminal else {
            return
        }
        if call.phase != .reconnecting {
            tonePlayer.stop()
            activeCall = call.updating(phase: .reconnecting)
        }
        scheduleDisconnectTimeout(callId: callId)
        scheduleReconnectAttempts(callId: callId)
    }

    private func scheduleReconnectAttempts(callId: Int) {
        guard reconnectAttemptTask == nil,
              let handshake = securityHandshake,
              handshake.callId == callId,
              handshake.role == .caller,
              handshake.isConfirmed else {
            return
        }
        reconnectAttemptTask = Task { [weak self] in
            defer { self?.reconnectAttemptTask = nil }
            let delays: [UInt64] = [
                350_000_000,
                3_000_000_000,
                6_000_000_000,
                9_000_000_000
            ]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled,
                      let self,
                      let call = self.activeCall,
                      call.id == callId,
                      call.phase == .reconnecting,
                      let handshake = self.securityHandshake,
                      handshake.callId == callId,
                      handshake.isConfirmed,
                      let client = self.client else {
                    return
                }
                handshake.reconnectGeneration += 1
                handshake.reconnectOfferHash = nil
                if !client.restartIce() {
                    handshake.reconnectGeneration -= 1
                }
            }
        }
    }

    private func scheduleDisconnectTimeout(callId: Int) {
        guard disconnectTimeoutTask == nil else { return }
        disconnectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  let call = self.activeCall,
                  call.id == callId,
                  call.phase == .reconnecting else { return }
            try? await self.api.endDirectCall(callId: callId)
            self.showTerminalState(
                phase: .interrupted,
                reason: .failed,
                terminalTone: .failed
            )
        }
    }

    private func requestMediaPermissions(video: Bool) async -> Bool {
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
        guard microphone else { return false }
        guard video else { return true }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
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

    private func callUUID(callId: Int) -> UUID {
        AloCallSecurity.callUUID(callId: callId)
    }
}

extension AloCallCoordinator: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            stop()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
        Task { @MainActor in
            accept()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        Task { @MainActor in
            await endNetworkCall()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        Task { @MainActor in
            if let call = activeCall {
                tonePlayer.prepareAudioRoute(speakerOn: call.isSpeakerOn, activate: false)
            }
            tonePlayer.resumeIfNeeded(restart: true)
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    }
}
