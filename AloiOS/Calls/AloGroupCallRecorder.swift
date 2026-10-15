import AVFoundation
import Foundation
import LiveKit

/// Records a video chat's sound on the admin's phone, as Telegram does: what the others say
/// (LiveKit's mixed playout) plus this phone's microphone, into one AAC file that goes to
/// "Избранное" when the recording stops.
///
/// Both taps deliver 10 ms PCM chunks on WebRTC's audio threads. Playout runs steadily even in
/// silence, so it is the clock: microphone samples wait in a short queue and are added to the
/// next playout chunk. While the microphone is muted the queue stays empty.
final class AloGroupCallRecorder: @unchecked Sendable {
    let fileURL: URL
    let startedAt = Date()
    private let queue = DispatchQueue(label: "alo.group-call.recorder")
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private var file: AVAudioFile?
    private var micQueue: [Float] = []
    private var converters: [String: AVAudioConverter] = [:]
    private lazy var remoteTap = Tap { [weak self] in self?.receive($0, fromMicrophone: false) }
    private lazy var microphoneTap = Tap { [weak self] in self?.receive($0, fromMicrophone: true) }
    /// At most half a second of microphone sound waits for playout; older samples are dropped.
    private static let maxQueuedMicSamples = 24_000

    init(directory: URL = FileManager.default.temporaryDirectory) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        fileURL = directory.appendingPathComponent("alo-video-chat-\(stamp).m4a")
    }

    func start() throws {
        try? FileManager.default.removeItem(at: fileURL)
        file = try AVAudioFile(
            forWriting: fileURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        AudioManager.shared.add(remoteAudioRenderer: remoteTap)
        AudioManager.shared.add(localAudioRenderer: microphoneTap)
    }

    /// Stops listening and closes the file; nil when nothing was recorded.
    func stop() -> (url: URL, duration: TimeInterval)? {
        AudioManager.shared.remove(remoteAudioRenderer: remoteTap)
        AudioManager.shared.remove(localAudioRenderer: microphoneTap)
        let length: AVAudioFramePosition = queue.sync {
            let frames = file?.length ?? 0
            file = nil
            micQueue.removeAll()
            return frames
        }
        guard length > 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return (fileURL, Double(length) / format.sampleRate)
    }

    /// LiveKit makes a new buffer for each chunk, so it can be handed to the queue as is.
    private func receive(_ buffer: AVAudioPCMBuffer, fromMicrophone: Bool) {
        queue.async { [weak self] in
            guard let self, self.file != nil,
                  let samples = self.convert(buffer, source: fromMicrophone ? "mic" : "remote") else { return }
            if fromMicrophone {
                self.micQueue.append(contentsOf: samples)
                if self.micQueue.count > Self.maxQueuedMicSamples {
                    self.micQueue.removeFirst(self.micQueue.count - Self.maxQueuedMicSamples)
                }
            } else {
                self.write(remote: samples)
            }
        }
    }

    private func write(remote: [Float]) {
        var mixed = remote
        let fromMic = min(mixed.count, micQueue.count)
        for index in 0..<fromMic {
            // A soft limiter keeps two loud voices from clipping.
            let sum = mixed[index] + micQueue[index]
            mixed[index] = sum / (1 + abs(sum) * 0.25)
        }
        if fromMic > 0 { micQueue.removeFirst(fromMic) }
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mixed.count)),
              let channel = output.floatChannelData?[0] else { return }
        output.frameLength = AVAudioFrameCount(mixed.count)
        mixed.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: mixed.count) }
        try? file?.write(from: output)
    }

    /// LiveKit hands over Int16 chunks at the device's rate; the file is 48 kHz mono Float32.
    /// Each source keeps its own converter, whose resampler carries state between chunks.
    private func convert(_ buffer: AVAudioPCMBuffer, source name: String) -> [Float]? {
        let source = buffer.format
        let key = "\(name)-\(source.sampleRate)-\(source.channelCount)-\(source.commonFormat.rawValue)"
        if converters[key] == nil { converters[key] = AVAudioConverter(from: source, to: format) }
        guard let converter = converters[key] else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / source.sampleRate) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private final class Tap: NSObject, AudioRenderer, @unchecked Sendable {
        let onBuffer: (AVAudioPCMBuffer) -> Void
        init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) { self.onBuffer = onBuffer }
        func render(pcmBuffer: AVAudioPCMBuffer) { onBuffer(pcmBuffer) }
    }
}
