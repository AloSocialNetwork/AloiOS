import CoreGraphics

enum AloVoiceWaveform {
    /// Resample the whole recording to the visible width; never cut off its tail.
    static func samples(_ levels: [CGFloat], width: CGFloat) -> [CGFloat] {
        guard width.isFinite, width > 0 else { return [] }
        let count = Int(max(1, min(64, ((width + 2) / 5).rounded(.down))))
        let source = levels.filter(\.isFinite).map { max(0, min(1, $0)) }
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
}
