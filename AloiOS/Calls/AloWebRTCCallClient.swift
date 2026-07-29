import AVFoundation
import Foundation
import ImageIO
import ReplayKit
import WebRTC

enum AloWebRTCConnectionState {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

final class AloWebRTCCallClient: NSObject {
    private let factory: RTCPeerConnectionFactory
    private let peerConnection: RTCPeerConnection
    private let onLocalDescription: (String, String) -> Void
    private let onIceCandidate: (String, Int32, String) -> Void
    private let onConnectionStateChanged: (AloWebRTCConnectionState) -> Void
    private let onError: (String) -> Void

    private var audioSource: RTCAudioSource?
    private var audioTrack: RTCAudioTrack?
    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    private var localPreviewTrack: RTCVideoTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var cameraCapturer: RTCCameraVideoCapturer?
    private var screenCapturer: AloReplayKitVideoCapturer?
    private var isCameraCapturing = false
    private var isCameraTransitioning = false
    private var cameraOperationGeneration = 0
    private var preferredCameraPosition: AVCaptureDevice.Position = .front
    private weak var localRenderer: RTCVideoRenderer?
    private weak var remoteRenderer: RTCVideoRenderer?

    init(
        configuration: AloRTCConfiguration,
        enableVideo: Bool,
        frontCamera: Bool,
        onLocalDescription: @escaping (String, String) -> Void,
        onIceCandidate: @escaping (String, Int32, String) -> Void,
        onConnectionStateChanged: @escaping (AloWebRTCConnectionState) -> Void,
        onError: @escaping (String) -> Void
    ) throws {
        RTCInitializeSSL()
        self.onLocalDescription = onLocalDescription
        self.onIceCandidate = onIceCandidate
        self.onConnectionStateChanged = onConnectionStateChanged
        self.onError = onError

        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        let factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
        self.factory = factory

        let rtcConfiguration = RTCConfiguration()
        rtcConfiguration.sdpSemantics = .unifiedPlan
        rtcConfiguration.continualGatheringPolicy = .gatherContinually
        rtcConfiguration.iceServers = configuration.iceServers.map {
            RTCIceServer(
                urlStrings: $0.urls,
                username: $0.username,
                credential: $0.credential
            )
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let peerConnection = factory.peerConnection(
            with: rtcConfiguration,
            constraints: constraints,
            delegate: nil
        ) else {
            throw AloAPIError(
                status: 0,
                code: "WEBRTC_CONNECTION_FAILED",
                message: "Не удалось создать защищённое соединение звонка.",
                payload: [:]
            )
        }
        self.peerConnection = peerConnection
        super.init()
        peerConnection.delegate = self
        configureAudioSession()
        createAudioTrack()
        ensureVideoTrack()
        if enableVideo {
            setVideoEnabled(true, frontCamera: frontCamera)
        } else {
            videoTrack?.isEnabled = false
        }
    }

    func prepareIncoming() {}

    func startOutgoing() {
        createLocalOffer(kind: "offer", restartingIce: false)
    }

    @discardableResult
    func restartIce() -> Bool {
        guard peerConnection.signalingState == .stable else { return false }
        createLocalOffer(kind: "reconnect-offer", restartingIce: true)
        return true
    }

    private func createLocalOffer(kind: String, restartingIce: Bool) {
        if restartingIce {
            peerConnection.restartIce()
        }
        peerConnection.offer(for: mediaConstraints()) { [weak self] description, error in
            guard let self else { return }
            if let error {
                if !restartingIce {
                    self.onError(error.localizedDescription)
                }
                return
            }
            guard let description else {
                if !restartingIce {
                    self.onError("WebRTC не создал offer.")
                }
                return
            }
            self.peerConnection.setLocalDescription(description) { error in
                if let error {
                    if !restartingIce {
                        self.onError(error.localizedDescription)
                    }
                } else {
                    self.onLocalDescription(kind, description.sdp)
                }
            }
        }
    }

    func handleRemoteOffer(_ sdp: String) {
        handleRemoteOffer(sdp, answerKind: "answer", reconnecting: false)
    }

    func handleRemoteReconnectOffer(_ sdp: String) {
        handleRemoteOffer(sdp, answerKind: "reconnect-answer", reconnecting: true)
    }

    private func handleRemoteOffer(
        _ sdp: String,
        answerKind: String,
        reconnecting: Bool
    ) {
        let description = RTCSessionDescription(type: .offer, sdp: sdp)
        peerConnection.setRemoteDescription(description) { [weak self] error in
            guard let self else { return }
            if let error {
                if !reconnecting {
                    self.onError(error.localizedDescription)
                }
                return
            }
            self.peerConnection.answer(for: self.mediaConstraints()) { description, error in
                if let error {
                    if !reconnecting {
                        self.onError(error.localizedDescription)
                    }
                    return
                }
                guard let description else {
                    if !reconnecting {
                        self.onError("WebRTC не создал answer.")
                    }
                    return
                }
                self.peerConnection.setLocalDescription(description) { error in
                    if let error {
                        if !reconnecting {
                            self.onError(error.localizedDescription)
                        }
                    } else {
                        self.onLocalDescription(answerKind, description.sdp)
                    }
                }
            }
        }
    }

    func handleRemoteAnswer(_ sdp: String) {
        handleRemoteAnswer(sdp, reconnecting: false)
    }

    func handleRemoteReconnectAnswer(_ sdp: String) {
        handleRemoteAnswer(sdp, reconnecting: true)
    }

    private func handleRemoteAnswer(_ sdp: String, reconnecting: Bool) {
        peerConnection.setRemoteDescription(
            RTCSessionDescription(type: .answer, sdp: sdp)
        ) { [weak self] error in
            if let error, !reconnecting {
                self?.onError(error.localizedDescription)
            }
        }
    }

    func addRemoteIceCandidate(sdpMid: String, lineIndex: Int32, candidate: String) {
        peerConnection.add(
            RTCIceCandidate(
                sdp: candidate,
                sdpMLineIndex: lineIndex,
                sdpMid: sdpMid
            )
        ) { [weak self] error in
            if let error { self?.onError(error.localizedDescription) }
        }
    }

    func setMuted(_ muted: Bool) {
        audioTrack?.isEnabled = !muted
    }

    func setSpeakerOn(_ enabled: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.overrideOutputAudioPort(enabled ? .speaker : .none)
        } catch {
            onError(error.localizedDescription)
        }
    }

    func setVideoEnabled(
        _ enabled: Bool,
        frontCamera: Bool? = nil,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        if let frontCamera {
            preferredCameraPosition = frontCamera ? .front : .back
        }
        ensureVideoTrack()
        if enabled {
            stopScreenCapture()
            videoTrack?.isEnabled = true
            localPreviewTrack?.isEnabled = true
            startCameraCapture(completion: completion)
        } else {
            stopCameraCapture()
            videoTrack?.isEnabled = false
            localPreviewTrack?.isEnabled = false
            completion?(.success(()))
        }
    }

    func prepareCameraPreview(
        frontCamera: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        preferredCameraPosition = frontCamera ? .front : .back
        ensureVideoTrack()
        guard screenCapturer == nil else {
            completion(.failure(AloCallCaptureError.screenShareActive))
            return
        }
        localPreviewTrack?.isEnabled = true
        startCameraCapture(completion: completion)
    }

    func cancelCameraPreview() {
        guard videoTrack?.isEnabled != true, screenCapturer == nil else {
            return
        }
        stopCameraCapture()
        localPreviewTrack?.isEnabled = false
    }

    func setScreenSharingEnabled(
        _ enabled: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        ensureVideoTrack()
        if !enabled {
            stopScreenCapture()
            videoTrack?.isEnabled = false
            localPreviewTrack?.isEnabled = false
            completion(.success(()))
            return
        }

        guard let videoSource else {
            completion(.failure(AloReplayKitCaptureError.missingVideoSource))
            return
        }
        let capturer = AloReplayKitVideoCapturer(delegate: videoSource)
        screenCapturer = capturer
        capturer.startCapture { [weak self, weak capturer] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.stopCameraCapture()
                    self.videoTrack?.isEnabled = true
                    self.localPreviewTrack?.isEnabled = true
                    completion(.success(()))
                case let .failure(error):
                    if self.screenCapturer === capturer {
                        self.screenCapturer = nil
                    }
                    completion(.failure(error))
                }
            }
        }
    }

    func setCameraPosition(
        frontCamera: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        preferredCameraPosition = frontCamera ? .front : .back
        guard screenCapturer == nil else {
            completion(.failure(AloCallCaptureError.screenShareActive))
            return
        }
        guard !isCameraTransitioning else {
            completion(.failure(AloCallCaptureError.cameraBusy))
            return
        }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let next = devices.first(where: { $0.position == preferredCameraPosition }),
              let format = preferredFormat(for: next) else {
            completion(.failure(AloCallCaptureError.cameraUnavailable))
            return
        }

        guard let source = videoSource else {
            completion(.failure(AloReplayKitCaptureError.missingVideoSource))
            return
        }
        let capturer = cameraCapturer ?? RTCCameraVideoCapturer(delegate: source)
        cameraCapturer = capturer
        cameraOperationGeneration += 1
        let generation = cameraOperationGeneration
        isCameraTransitioning = true

        let startNextCamera = { [weak self, weak capturer] in
            guard let self, let capturer else {
                completion(.failure(AloCallCaptureError.operationSuperseded))
                return
            }
            guard self.cameraOperationGeneration == generation else {
                completion(.failure(AloCallCaptureError.operationSuperseded))
                return
            }
            self.beginCameraCapture(
                capturer: capturer,
                device: next,
                format: format,
                generation: generation,
                completion: completion
            )
        }
        guard isCameraCapturing else {
            startNextCamera()
            return
        }

        isCameraCapturing = false
        capturer.stopCapture {
            DispatchQueue.main.async(execute: startNextCamera)
        }
    }

    func bindLocalRenderer(_ renderer: RTCVideoRenderer?) {
        if let localRenderer { localPreviewTrack?.remove(localRenderer) }
        localRenderer = renderer
        if let renderer { localPreviewTrack?.add(renderer) }
    }

    func bindRemoteRenderer(_ renderer: RTCVideoRenderer?) {
        if let remoteRenderer { remoteVideoTrack?.remove(remoteRenderer) }
        remoteRenderer = renderer
        if let renderer { remoteVideoTrack?.add(renderer) }
    }

    func close() {
        if let localRenderer { localPreviewTrack?.remove(localRenderer) }
        if let remoteRenderer { remoteVideoTrack?.remove(remoteRenderer) }
        stopCameraCapture()
        stopScreenCapture()
        peerConnection.close()
        deactivateAudioSession()
        onConnectionStateChanged(.closed)
    }

    private func createAudioTrack() {
        let source = factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true"
            ]
        ))
        let track = factory.audioTrack(with: source, trackId: "alo-audio")
        audioSource = source
        audioTrack = track
        peerConnection.add(track, streamIds: ["alo-stream"])
    }

    private func ensureVideoTrack() {
        guard videoTrack == nil else { return }
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "alo-video")
        let previewTrack = factory.videoTrack(
            with: source,
            trackId: "alo-video-preview"
        )
        videoSource = source
        videoTrack = track
        localPreviewTrack = previewTrack
        previewTrack.isEnabled = false
        peerConnection.add(track, streamIds: ["alo-stream"])
        if let localRenderer { previewTrack.add(localRenderer) }
    }

    private func startCameraCapture(
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard !isCameraCapturing else {
            completion?(.success(()))
            return
        }
        guard !isCameraTransitioning else {
            completion?(.failure(AloCallCaptureError.cameraBusy))
            return
        }
        guard let device = RTCCameraVideoCapturer.captureDevices()
            .first(where: { $0.position == preferredCameraPosition })
                ?? RTCCameraVideoCapturer.captureDevices().first,
              let format = preferredFormat(for: device) else {
            let error = AloCallCaptureError.cameraUnavailable
            onError(error.localizedDescription)
            completion?(.failure(error))
            return
        }
        guard let source = videoSource else {
            let error = AloReplayKitCaptureError.missingVideoSource
            onError(error.localizedDescription)
            completion?(.failure(error))
            return
        }
        let capturer = cameraCapturer ?? RTCCameraVideoCapturer(delegate: source)
        cameraCapturer = capturer
        cameraOperationGeneration += 1
        let generation = cameraOperationGeneration
        isCameraTransitioning = true
        beginCameraCapture(
            capturer: capturer,
            device: device,
            format: format,
            generation: generation,
            completion: completion
        )
    }

    private func stopCameraCapture() {
        cameraOperationGeneration += 1
        isCameraTransitioning = false
        guard isCameraCapturing || cameraCapturer != nil else { return }
        isCameraCapturing = false
        cameraCapturer?.stopCapture()
    }

    private func beginCameraCapture(
        capturer: RTCCameraVideoCapturer,
        device: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        generation: Int,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let width = Int32(min(dimensions.width, 1280))
        let height = Int32(min(dimensions.height, 1280))
        let fps = preferredFramesPerSecond(for: format)
        videoSource?.adaptOutputFormat(toWidth: width, height: height, fps: Int32(fps))
        capturer.startCapture(with: device, format: format, fps: fps) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.cameraOperationGeneration == generation else {
                    completion?(.failure(AloCallCaptureError.operationSuperseded))
                    return
                }
                self.isCameraTransitioning = false
                if let error {
                    self.isCameraCapturing = false
                    self.onError(error.localizedDescription)
                    completion?(.failure(error))
                } else {
                    self.isCameraCapturing = true
                    completion?(.success(()))
                }
            }
        }
    }

    private func stopScreenCapture() {
        screenCapturer?.stopCapture()
        screenCapturer = nil
    }

    private func preferredFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        RTCCameraVideoCapturer.supportedFormats(for: device)
            .filter {
                let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return dimensions.width <= 1280 && dimensions.height <= 1280
            }
            .max {
                let left = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let right = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return left.width * left.height < right.width * right.height
            }
            ?? RTCCameraVideoCapturer.supportedFormats(for: device).first
    }

    private func preferredFramesPerSecond(for format: AVCaptureDevice.Format) -> Int {
        guard let range = format.videoSupportedFrameRateRanges.first else { return 24 }
        let target = 30.0
        return Int(min(max(target, range.minFrameRate), range.maxFrameRate).rounded())
    }

    private func mediaConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true"
            ],
            optionalConstraints: nil
        )
    }

    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP]
            )
            try session.setActive(true)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func deactivateAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setActive(false)
        } catch {
            onError(error.localizedDescription)
        }
    }
}

private final class AloReplayKitVideoCapturer: RTCVideoCapturer {
    private weak var frameDelegate: RTCVideoCapturerDelegate?
    private weak var videoSource: RTCVideoSource?
    private let recorder = RPScreenRecorder.shared()
    private var isCapturing = false
    private var lastFrameTimestampNs: Int64 = 0
    private var adaptedDimensions: (width: Int32, height: Int32)?

    override init(delegate: RTCVideoCapturerDelegate) {
        frameDelegate = delegate
        videoSource = delegate as? RTCVideoSource
        super.init(delegate: delegate)
    }

    func startCapture(completion: @escaping (Result<Void, Error>) -> Void) {
        guard recorder.isAvailable else {
            completion(.failure(AloReplayKitCaptureError.unavailable))
            return
        }
        guard !isCapturing else {
            completion(.success(()))
            return
        }

        recorder.isMicrophoneEnabled = false
        recorder.startCapture(
            handler: { [weak self] sampleBuffer, sampleType, error in
                guard let self, sampleType == .video, error == nil else { return }
                self.consume(sampleBuffer)
            },
            completionHandler: { [weak self] error in
                if let error {
                    completion(.failure(error))
                } else {
                    self?.isCapturing = true
                    completion(.success(()))
                }
            }
        )
    }

    func stopCapture() {
        guard isCapturing || recorder.isRecording else { return }
        isCapturing = false
        recorder.stopCapture { _ in }
    }

    private func consume(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(presentationTime)
        let timestamp = seconds.isFinite
            ? Int64(seconds * Double(NSEC_PER_SEC))
            : Int64(ProcessInfo.processInfo.systemUptime * Double(NSEC_PER_SEC))
        let minimumFrameInterval = Int64(Double(NSEC_PER_SEC) / 15.0)
        guard timestamp - lastFrameTimestampNs >= minimumFrameInterval else { return }
        lastFrameTimestampNs = timestamp
        adaptOutputFormat(for: pixelBuffer)
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: videoRotation(for: sampleBuffer),
            timeStampNs: timestamp
        )
        frameDelegate?.capturer(self, didCapture: frame)
    }

    private func adaptOutputFormat(for pixelBuffer: CVPixelBuffer) {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return }
        let longestEdge = max(sourceWidth, sourceHeight)
        let scale = min(1.0, 1280.0 / Double(longestEdge))
        let width = evenDimension(Double(sourceWidth) * scale)
        let height = evenDimension(Double(sourceHeight) * scale)
        if let adaptedDimensions,
           adaptedDimensions.width == width,
           adaptedDimensions.height == height {
            return
        }
        adaptedDimensions = (width, height)
        videoSource?.adaptOutputFormat(toWidth: width, height: height, fps: 15)
    }

    private func evenDimension(_ value: Double) -> Int32 {
        let rounded = max(2, Int(value.rounded()))
        return Int32(rounded.isMultiple(of: 2) ? rounded : rounded - 1)
    }

    private func videoRotation(for sampleBuffer: CMSampleBuffer) -> RTCVideoRotation {
        var mode: CMAttachmentMode = 0
        guard let value = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: &mode
        ) as? NSNumber else {
            return ._0
        }
        switch CGImagePropertyOrientation(rawValue: value.uint32Value) {
        case .right:
            return ._90
        case .down:
            return ._180
        case .left:
            return ._270
        default:
            return ._0
        }
    }
}

private enum AloCallCaptureError: LocalizedError {
    case cameraBusy
    case cameraUnavailable
    case operationSuperseded
    case screenShareActive

    var errorDescription: String? {
        switch self {
        case .cameraBusy:
            "Камера ещё переключается."
        case .cameraUnavailable:
            "На устройстве не найдена другая камера."
        case .operationSuperseded:
            "Операция с камерой была отменена."
        case .screenShareActive:
            "Сначала остановите демонстрацию экрана."
        }
    }
}

private enum AloReplayKitCaptureError: LocalizedError {
    case unavailable
    case missingVideoSource

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Демонстрация экрана сейчас недоступна."
        case .missingVideoSource:
            "Не удалось подготовить видеоканал для демонстрации экрана."
        }
    }
}

extension AloWebRTCCallClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            attachRemoteVideoTrack(track)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .checking:
            onConnectionStateChanged(.connecting)
        case .connected, .completed:
            onConnectionStateChanged(.connected)
        case .disconnected:
            onConnectionStateChanged(.disconnected)
        case .failed:
            onConnectionStateChanged(.failed)
        case .closed:
            onConnectionStateChanged(.closed)
        default:
            onConnectionStateChanged(.new)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate(candidate.sdpMid ?? "", candidate.sdpMLineIndex, candidate.sdp)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        switch newState {
        case .connecting:
            onConnectionStateChanged(.connecting)
        case .connected:
            onConnectionStateChanged(.connected)
        case .disconnected:
            onConnectionStateChanged(.disconnected)
        case .failed:
            onConnectionStateChanged(.failed)
        case .closed:
            onConnectionStateChanged(.closed)
        default:
            onConnectionStateChanged(.new)
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams: [RTCMediaStream]
    ) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            attachRemoteVideoTrack(track)
        }
    }

    private func attachRemoteVideoTrack(_ track: RTCVideoTrack) {
        if let remoteVideoTrack, let remoteRenderer {
            remoteVideoTrack.remove(remoteRenderer)
        }
        remoteVideoTrack = track
        if let remoteRenderer { track.add(remoteRenderer) }
    }
}
