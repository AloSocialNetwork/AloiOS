import AVFoundation
import Foundation

enum AloCallTone: Equatable {
    case incoming
    case ringback
    case connecting
    case connected
    case busy
    case noAnswer
    case failed
    case ended

    var loops: Bool {
        switch self {
        case .incoming, .ringback, .connecting:
            true
        case .connected, .busy, .noAnswer, .failed, .ended:
            false
        }
    }
}

@MainActor
final class AloCallTonePlayer {
    private var player: AVAudioPlayer?
    private(set) var currentTone: AloCallTone?

    func play(_ tone: AloCallTone) {
        if currentTone == tone, player?.isPlaying == true {
            return
        }
        stop()
        do {
            let player = try AVAudioPlayer(data: AloCallToneWaveform.wavData(for: tone))
            player.numberOfLoops = tone.loops ? -1 : 0
            player.volume = 0.9
            player.prepareToPlay()
            player.play()
            self.player = player
            currentTone = tone
        } catch {
            player = nil
            currentTone = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        currentTone = nil
    }

    func resumeIfNeeded(restart: Bool = false) {
        guard currentTone?.loops == true else { return }
        if restart {
            player?.stop()
            player?.currentTime = 0
            player?.play()
            return
        }
        guard player?.isPlaying == false else { return }
        player?.play()
    }

    func prepareAudioRoute(speakerOn: Bool, activate: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP]
            )
            if activate {
                try session.setActive(true)
            }
            try session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
        } catch {
            // CallKit can own activation while a system call transaction is pending.
        }
    }
}

enum AloCallToneWaveform {
    private struct Segment {
        let frequencies: [Double]
        let duration: Double
        let gain: Double

        init(_ frequencies: [Double], _ duration: Double, gain: Double = 0.72) {
            self.frequencies = frequencies
            self.duration = duration
            self.gain = gain
        }

        static func silence(_ duration: Double) -> Segment {
            Segment([], duration, gain: 0)
        }
    }

    private static let sampleRate = 44_100

    static func wavData(for tone: AloCallTone) -> Data {
        let segments: [Segment]
        switch tone {
        case .incoming:
            segments = [
                Segment([523.25, 659.25], 0.42),
                .silence(0.16),
                Segment([659.25, 783.99], 0.42),
                .silence(1.45)
            ]
        case .ringback:
            segments = [
                Segment([440, 480], 0.72, gain: 0.56),
                .silence(2.25)
            ]
        case .connecting:
            segments = [
                Segment([425], 0.11, gain: 0.38),
                .silence(0.89)
            ]
        case .connected:
            segments = [
                Segment([659.25], 0.08, gain: 0.46),
                Segment([880], 0.12, gain: 0.5)
            ]
        case .busy:
            segments = Array(
                repeating: [
                    Segment([480, 620], 0.24, gain: 0.62),
                    .silence(0.24)
                ],
                count: 3
            ).flatMap { $0 }
        case .noAnswer:
            segments = [
                Segment([587.33], 0.11, gain: 0.58),
                .silence(0.07),
                Segment([440], 0.14, gain: 0.58),
                .silence(0.06),
                Segment([329.63], 0.24, gain: 0.62)
            ]
        case .failed:
            segments = [
                Segment([620], 0.14, gain: 0.62),
                Segment([480], 0.16, gain: 0.62),
                Segment([330], 0.24, gain: 0.62)
            ]
        case .ended:
            segments = [
                Segment([523.25], 0.10, gain: 0.52),
                Segment([392], 0.18, gain: 0.52)
            ]
        }

        let samples = render(segments)
        return encodeWAV(samples)
    }

    private static func render(_ segments: [Segment]) -> [Int16] {
        var result: [Int16] = []
        let fadeSamples = max(1, Int(Double(sampleRate) * 0.008))

        for segment in segments {
            let count = max(1, Int(segment.duration * Double(sampleRate)))
            for index in 0..<count {
                guard !segment.frequencies.isEmpty else {
                    result.append(0)
                    continue
                }
                let time = Double(index) / Double(sampleRate)
                let wave = segment.frequencies.reduce(0.0) {
                    $0 + sin(2 * Double.pi * $1 * time)
                } / Double(segment.frequencies.count)
                let fadeIn = min(1, Double(index) / Double(fadeSamples))
                let fadeOut = min(1, Double(count - index - 1) / Double(fadeSamples))
                let envelope = max(0, min(fadeIn, fadeOut))
                let sample = wave * segment.gain * envelope * Double(Int16.max)
                result.append(Int16(clamping: Int(sample.rounded())))
            }
        }
        return result
    }

    private static func encodeWAV(_ samples: [Int16]) -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        let payloadSize = UInt32(samples.count * MemoryLayout<Int16>.size)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + payloadSize, to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(channelCount, to: &data)
        append(UInt32(sampleRate), to: &data)
        append(byteRate, to: &data)
        append(blockAlign, to: &data)
        append(bitsPerSample, to: &data)
        data.append(contentsOf: "data".utf8)
        append(payloadSize, to: &data)
        samples.forEach { append(UInt16(bitPattern: $0), to: &data) }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
