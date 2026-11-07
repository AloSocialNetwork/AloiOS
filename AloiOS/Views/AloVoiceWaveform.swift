import CoreGraphics

enum AloVoiceWaveform {
    /// Resample the whole recording to the visible width; never cut off its tail.
    /// A message with no waveform, or a flat one (Safari on iPhone recorded silence into the levels: every bar 0.08),
    /// gets a steady pattern seeded by its file address when `seed` is given — the rule of the website and Android,
    /// so the same message looks alike everywhere instead of a straight line.
    static func samples(_ levels: [CGFloat], width: CGFloat, seed: String = "") -> [CGFloat] {
        guard width.isFinite, width > 0 else { return [] }
        let count = Int(max(1, min(64, ((width + 2) / 5).rounded(.down))))
        let source = levels.filter(\.isFinite).map { max(0, min(1, $0)) }
        let flat = (source.max() ?? 0) - (source.min() ?? 0) < 0.03
        if flat, !seed.isEmpty { return pattern(seed: seed, count: count) }
        guard !source.isEmpty else { return Array(repeating: 0, count: count) }
        if source.count > count {
            return (0..<count).map { index in
                let start = index * source.count / count
                let end = max(start + 1, (index + 1) * source.count / count)
                return source[start..<end].max() ?? 0
            }
        }
        return (0..<count).map { index in
            let position = CGFloat(index) / CGFloat(max(1, count - 1)) * CGFloat(source.count - 1)
            let lower = Int(position)
            let upper = min(lower + 1, source.count - 1)
            let fraction = position - CGFloat(lower)
            return source[lower] * (1 - fraction) + source[upper] * fraction
        }
    }

    /// The same numbers as the website's and Android's stand-in (seed 7, ×31 per character, then an LCG).
    static func pattern(seed: String, count: Int) -> [CGFloat] {
        var value: UInt32 = 7
        for unit in seed.utf16 { value = value &* 31 &+ UInt32(unit) }
        return (0..<max(1, count)).map { _ in
            value = value &* 1_103_515_245 &+ 12_345
            return CGFloat(0.25 + Double((value >> 8) % 1000) / 1000 * 0.7)
        }
    }
}
