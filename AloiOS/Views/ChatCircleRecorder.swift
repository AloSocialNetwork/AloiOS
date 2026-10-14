import AVFoundation
import Combine
import Foundation

/// Capture mutations and delegate state live exclusively on `queue`. The main
/// actor owns request cancellation and the small set of observable UI values.
final class ChatCircleRecorder: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let objectWillChange = ObservableObjectPublisher()
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "alo.circle.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var writer: AloCircleSampleWriter?
    private var isFinalizing = false
    private var awaitingCameraFrame = false
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var outputURL: URL?
    private var wantsStop = false
    private var discarding = false
    private var completion: ((AloLocalAttachment?) -> Void)?
    private var ready: ((String?) -> Void)?
    private var didStop: (() -> Void)?
    private var finishedAttachment: AloLocalAttachment?
    @MainActor private var requestID: UUID?
    @MainActor private(set) var isTorchEnabled = false
    @MainActor private(set) var isFrontCamera = true
    @MainActor private(set) var isSwitchingCamera = false
    private var gestureZoom: CGFloat = 1

    @MainActor func updateZoom(magnification: CGFloat, ended: Bool) {
        queue.async { [self] in
            guard let device = input?.device, !wantsStop else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = min(min(3, device.maxAvailableVideoZoomFactor),
                    max(device.minAvailableVideoZoomFactor, gestureZoom * magnification))
                if ended { gestureZoom = device.videoZoomFactor }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    @MainActor func start(onReady: @escaping (String?) -> Void, onStopped: @escaping () -> Void) {
        let id = UUID()
        requestID = id
        Task {
            let camera = await Self.access(.video)
            let microphone = await Self.access(.audio)
            guard requestID == id else { return }
            guard camera && microphone else {
                requestID = nil
                onReady("Для записи кружка разрешите доступ к камере и микрофону в настройках iPhone.")
                return
            }
            queue.async { [self] in
                guard outputURL == nil else {
                    DispatchQueue.main.async { onReady("Предыдущая запись ещё завершается. Повторите попытку.") }
                    return
                }
                do {
                    try configure()
                    wantsStop = false
                    discarding = false
                    completion = nil
                    if let previous = finishedAttachment { AloDraftAttachmentStore.discard(previous) }
                    finishedAttachment = nil
                    ready = { error in
                        DispatchQueue.main.async { [self] in
                            guard requestID == id else { return }
                            onReady(error)
                        }
                    }
                    didStop = {
                        DispatchQueue.main.async { [self] in
                            guard requestID == id else { return }
                            onStopped()
                        }
                    }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("alo-circle-\(UUID().uuidString).mov")
                    outputURL = url
                    configureConnection()
                    writer = try AloCircleSampleWriter(url: url)
                    isFinalizing = false
                    if !session.isRunning { session.startRunning() }
                } catch {
                    if session.isRunning { session.stopRunning() }
                    if let fileURL = outputURL { try? FileManager.default.removeItem(at: fileURL) }
                    outputURL = nil
                    writer = nil
                    ready = nil
                    didStop = nil
                    isFinalizing = false
                    DispatchQueue.main.async { [self] in
                        guard requestID == id else { return }
                        onReady("Не удалось запустить камеру. Проверьте, не используется ли она звонком.")
                    }
                }
            }
        }
    }

    @MainActor func stop(completion: @escaping (AloLocalAttachment?) -> Void) {
        requestID = nil
        queue.async { [self] in
            if let attachment = finishedAttachment {
                finishedAttachment = nil
                DispatchQueue.main.async { completion(attachment) }
                return
            }
            guard outputURL != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.completion = completion
            wantsStop = true
            finalizeCapture()
        }
    }

    @MainActor func cancel() {
        requestID = nil
        queue.async { [self] in
            completion = nil
            if let attachment = finishedAttachment { AloDraftAttachmentStore.discard(attachment) }
            finishedAttachment = nil
            ready = nil
            didStop = nil
            discarding = true
            wantsStop = true
            if outputURL != nil { finalizeCapture() }
            else if session.isRunning { session.stopRunning() }
        }
    }

    @MainActor func switchCamera() {
        guard !isSwitchingCamera else { return }
        objectWillChange.send()
        isSwitchingCamera = true
        queue.async { [self] in
            defer { if !awaitingCameraFrame { publishSwitching(false) } }
            guard configured, !wantsStop, let previous = input else { return }
            let position: AVCaptureDevice.Position = previous.device.position == .front ? .back : .front
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let next = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            session.removeInput(previous)
            if session.canAddInput(next) {
                session.addInput(next)
                input = next
                awaitingCameraFrame = true
            } else {
                session.addInput(previous)
            }
            session.commitConfiguration()
            configureFraming()
            configureConnection()
            publishCameraState()
        }
    }

    @MainActor func toggleTorch() {
        queue.async { [self] in
            guard let device = input?.device, device.hasTorch, device.isTorchAvailable else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = device.torchMode == .on ? .off : .on
                device.unlockForConfiguration()
                publishCameraState()
            } catch { }
        }
    }

    // Both outputs deliver on the same capture queue. Replacing the video input
    // never stops the writer or replaces the microphone: one file and one clock.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let writer, !wantsStop, !isFinalizing else { return }
        do {
            if output === videoOutput {
                let appended = try writer.appendVideo(sampleBuffer)
                if appended {
                    if awaitingCameraFrame {
                        awaitingCameraFrame = false
                        publishSwitching(false)
                    }
                    ready?(nil)
                    ready = nil
                    if writer.duration >= 60 { wantsStop = true; finalizeCapture() }
                }
            } else {
                try writer.appendAudio(sampleBuffer)
            }
        } catch {
            wantsStop = true
            ready?("Не удалось сохранить запись кружка.")
            ready = nil
            finalizeCapture()
        }
    }

    private func publishSwitching(_ switching: Bool) {
        DispatchQueue.main.async { [self] in
            objectWillChange.send()
            isSwitchingCamera = switching
        }
    }

    private func finalizeCapture() {
        guard !isFinalizing, let fileURL = outputURL, let writer else { return }
        isFinalizing = true
        awaitingCameraFrame = false
        publishSwitching(false)
        if session.isRunning { session.stopRunning() }
        writer.finish { [self] succeeded in
            queue.async { [self] in
                let shouldExport = !discarding && succeeded
                let squareURL = fileURL.deletingPathExtension().appendingPathExtension("mp4")
                Task {
                    var exported = false
                    var duration: Double?
                    if shouldExport {
                        do {
                            duration = try await AloCircleVideoExport.square(fileURL, output: squareURL)
                            exported = true
                        } catch { }
                    }
                    let didExport = exported
                    let recordedDuration = duration
                    self.queue.async { [self] in
                        finish(fileURL: fileURL, squareURL: squareURL,
                               succeeded: succeeded && didExport, duration: recordedDuration)
                    }
                }
            }
        }
    }

    private func finish(fileURL: URL, squareURL: URL, succeeded: Bool, duration: Double?) {
        guard outputURL == fileURL else { return }
        var attachment: AloLocalAttachment?
        if !discarding && succeeded {
            do {
                attachment = try AloDraftAttachmentStore.makeRecordedCircle(sourceURL: squareURL, durationSeconds: duration)
            } catch { attachment = nil }
        }
        let callback = completion
        let stopped = didStop
        didStop = nil
        if callback == nil, !discarding { finishedAttachment = attachment }
        let pendingReady = ready
        ready = nil
        completion = nil
        outputURL = nil
        writer = nil
        isFinalizing = false
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: squareURL)
        if session.isRunning { session.stopRunning() }
        publishCameraState()
        if !discarding && !succeeded { pendingReady?("Не удалось сохранить запись кружка.") }
        let result = attachment
        DispatchQueue.main.async { callback?(result) }
        // At the 60 s limit end the UI timer too. Camera switching does not
        // call this path and never becomes a finish/send gesture.
        if callback == nil, !discarding { stopped?() }
    }

    private func configure() throws {
        guard !configured else { return }
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            configureFraming()
        }
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureError.unavailable }
        let video = try AVCaptureDeviceInput(device: camera)
        let audio = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(video) else { throw CaptureError.unavailable }
        session.addInput(video)
        guard session.canAddInput(audio) else {
            session.removeInput(video)
            throw CaptureError.unavailable
        }
        session.addInput(audio)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        guard session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else {
            session.removeInput(video); session.removeInput(audio)
            throw CaptureError.unavailable
        }
        session.addOutput(videoOutput)
        session.addOutput(audioOutput)
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        input = video
        configured = true
        publishCameraState()
    }

    private func configureFraming() {
        guard let device = input?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            // Prefer the video format's native selfie crop, not an ultra-wide
            // sensor mode. No preview-only scaling: the movie sees this too.
            let candidates = device.formats.filter { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return size.width == 1920 && size.height == 1080 &&
                    format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 } &&
                    format.videoSupportedFrameRateRanges.allSatisfy { $0.maxFrameRate <= 60 }
            }
            if let format = candidates.min(by: { $0.videoFieldOfView < $1.videoFieldOfView }) {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
            gestureZoom = max(1, device.minAvailableVideoZoomFactor)
            device.videoZoomFactor = gestureZoom
        } catch { }
    }

    private func configureConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = input?.device.position == .front
        }
    }

    private func publishCameraState() {
        let front = input?.device.position == .front
        let torch = input?.device.torchMode == .on
        DispatchQueue.main.async { [self] in
            objectWillChange.send()
            isFrontCamera = front
            isTorchEnabled = torch
        }
    }

    private static func access(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    private enum CaptureError: Error { case unavailable }
}

/// Queue-confined writer. Camera changes are gaps between video frames, not a
/// new movie/session; audio keeps its original timestamps during the gap.
/// Reference: Telegram Camera/VideoRecorder, implemented with public AV APIs.
final class AloCircleSampleWriter {
    private let writer: AVAssetWriter
    private let audio: AVAssetWriterInput
    private var video: AVAssetWriterInput?
    private var startTime: CMTime?
    private var lastVideoTime: CMTime?
    private var lastAudioTime: CMTime?
    private var isFinished = false

    var duration: Double {
        guard let startTime, let lastVideoTime else { return 0 }
        return max(0, (lastVideoTime - startTime).seconds)
    }

    init(url: URL) throws {
        writer = try AVAssetWriter(url: url, fileType: .mov)
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(audio) else { throw WriterError.unavailable }
        writer.add(audio)
    }

    @discardableResult func appendVideo(_ sample: CMSampleBuffer) throws -> Bool {
        guard !isFinished, CMSampleBufferDataIsReady(sample),
              let pixel = CMSampleBufferGetImageBuffer(sample) else { return false }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isNumeric, lastVideoTime.map({ timestamp > $0 }) ?? true else { return false }
        if video == nil {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: CVPixelBufferGetWidth(pixel), AVVideoHeightKey: CVPixelBufferGetHeight(pixel),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 30]
            ], sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw WriterError.unavailable }
            writer.add(input)
            video = input
            guard writer.startWriting() else { throw writer.error ?? WriterError.unavailable }
            writer.startSession(atSourceTime: timestamp)
            startTime = timestamp
        }
        guard writer.status == .writing else { throw writer.error ?? WriterError.unavailable }
        guard let video, video.isReadyForMoreMediaData else { return false }
        guard video.append(sample) else { throw writer.error ?? WriterError.unavailable }
        lastVideoTime = timestamp
        return true
    }

    func appendAudio(_ sample: CMSampleBuffer) throws {
        guard !isFinished, let startTime, CMSampleBufferDataIsReady(sample) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isNumeric, timestamp >= startTime,
              lastAudioTime.map({ timestamp > $0 }) ?? true else { return }
        guard writer.status == .writing else { throw writer.error ?? WriterError.unavailable }
        // Backpressure drops a sample, never stalls the camera queue/UI.
        guard audio.isReadyForMoreMediaData else { return }
        guard audio.append(sample) else { throw writer.error ?? WriterError.unavailable }
        lastAudioTime = timestamp
    }

    func finish(completion: @escaping (Bool) -> Void) {
        guard !isFinished else { return }
        isFinished = true
        guard startTime != nil, writer.status == .writing else {
            writer.cancelWriting()
            completion(false)
            return
        }
        video?.markAsFinished()
        audio.markAsFinished()
        writer.finishWriting { [writer] in completion(writer.status == .completed) }
    }

    private enum WriterError: Error { case unavailable }
}
