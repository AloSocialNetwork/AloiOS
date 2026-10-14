import AVFoundation

enum AloAudioWaveformAnalysis {
    /// Fixed 16 KiB mono buffer rather than allocating the entire decoded voice
    /// recording (minutes of PCM can otherwise exhaust memory). Call off-main.
    static func samples(from url: URL, count: Int) -> [CGFloat] {
        guard count > 0, count <= 64,
              let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096)
        else { return [] }
        var sums = [Double](repeating: 0, count: count)
        var frames = [Int](repeating: 0, count: count)
        do {
            while file.framePosition < file.length {
                let start = file.framePosition
                try file.read(into: buffer, frameCount: 4_096)
                guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
                for frame in 0..<Int(buffer.frameLength) {
                    let bucket = min(count - 1, Int((start + Int64(frame)) * Int64(count) / file.length))
                    let value = Double(channel[frame])
                    sums[bucket] += value * value
                    frames[bucket] += 1
                }
            }
        } catch { return [] }
        return zip(sums, frames).map { sum, frames in
            let rms = sqrt(sum / Double(max(1, frames)))
            return CGFloat(max(0.10, min(1, sqrt(rms) * 1.6)))
        }
    }
}
