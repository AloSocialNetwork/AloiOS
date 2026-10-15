import Combine
import SwiftUI

/// Telegram's call palettes (CallBackgroundLayer): blue–violet while waiting, connecting or after
/// the call, green while talking, orange–pink when the link is weak. Mute doesn't change it.
enum AloCallBackdropPalette: Int, Equatable {
    case waiting = 0, active = 1, weak = 2

    static func resolve(phase: AloDirectCallPhase, quality: Double?) -> Self {
        guard phase == .active else { return .waiting }
        if let quality, quality <= 0.2 { return .weak }
        return .active
    }

    var rgb: [SIMD3<Double>] {
        switch self {
        case .waiting: return [0x568FD6, 0x626ED5, 0xA667D5, 0x7664DA].map(Self.components)
        case .active: return [0xACBD65, 0x459F8D, 0x53A4D1, 0x3E917A].map(Self.components)
        case .weak: return [0xC0508D, 0xF09536, 0xCE5081, 0xFC7C4C].map(Self.components)
        }
    }

    /// The two colours of the minimized call bar.
    var barColors: [Color] { [rgb[1], rgb[2]].map(Self.color) }

    static func components(_ hex: Int) -> SIMD3<Double> {
        SIMD3(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)) / 255
    }

    static func color(_ rgb: SIMD3<Double>) -> Color {
        Color(.sRGB, red: rgb.x, green: rgb.y, blue: rgb.z, opacity: 1)
    }
}

/// The moving gradient behind a call. Four colour points travel round Telegram's eight positions,
/// one step every two seconds (a 16 s loop), a little faster for two seconds after the state
/// changes; colours cross-fade in 0.3 s. With Reduce Motion it holds still. Like Telegram's
/// SoftwareGradientBackground it is computed small (48 × 80) and scaled up smoothly.
struct AloCallBackdrop: View {
    let palette: AloCallBackdropPalette
    let animated: Bool
    @State private var previous: [SIMD3<Double>]?
    @State private var changedAt = Date.distantPast

    /// SoftwareGradientBackground.basePositions.
    private static let positions: [SIMD2<Double>] = [
        [0.80, 0.10], [0.60, 0.20], [0.35, 0.25], [0.25, 0.60],
        [0.20, 0.90], [0.40, 0.80], [0.65, 0.75], [0.75, 0.40]
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
            let now = timeline.date
            let points = Self.points(phase: animated ? phase(at: now) : 0)
            if let image = Self.gradient(points: points, colors: currentColors(at: now)) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            }
        }
        .ignoresSafeArea()
        .onChange(of: palette) { old, _ in
            previous = currentColors(rgbOf: old, at: .now)
            changedAt = .now
        }
        .accessibilityHidden(true)
    }

    /// Steps travelled: 0.5 a second, plus up to a quarter step more right after a state change.
    private func phase(at date: Date) -> Double {
        let base = date.timeIntervalSinceReferenceDate * 0.5
        let u = min(1, max(0, date.timeIntervalSince(changedAt) / 2))
        return base + 0.25 * 2 * (u - u * u / 2)
    }

    private static func points(phase: Double) -> [CGPoint] {
        let step = Int(floor(phase))
        let fraction = phase - floor(phase)
        var result: [CGPoint] = []
        for index in 0..<4 {
            let from: SIMD2<Double> = positions[((step + 2 * index) % 8 + 8) % 8]
            let to: SIMD2<Double> = positions[((step + 1 + 2 * index) % 8 + 8) % 8]
            let point: SIMD2<Double> = from + (to - from) * fraction
            result.append(CGPoint(x: point.x, y: 1 - point.y))
        }
        return result
    }

    private func currentColors(at date: Date) -> [SIMD3<Double>] {
        currentColors(rgbOf: palette, at: date)
    }

    /// SoftwareGradientBackground.generateGradient: the pixel swirls slightly round the centre,
    /// then each colour weighs max(0, 0.92 − distance)³ to its point.
    static func gradient(points: [CGPoint], colors: [SIMD3<Double>], width: Int = 48, height: Int = 80) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let cx = Double(x) / Double(width) - 0.5, cy = Double(y) / Double(height) - 0.5
                let swirl = 0.35 * (cx * cx + cy * cy).squareRoot()
                let theta = swirl * swirl * 0.8 * 8
                let px = min(1, max(0, 0.5 + cx * cos(theta) - cy * sin(theta)))
                let py = min(1, max(0, 0.5 + cx * sin(theta) + cy * cos(theta)))
                var sum = 0.0
                var rgb = SIMD3<Double>(0, 0, 0)
                for index in 0..<4 {
                    let dx = px - Double(points[index].x), dy = py - Double(points[index].y)
                    let reach = max(0, 0.92 - (dx * dx + dy * dy).squareRoot())
                    let weight = reach * reach * reach
                    sum += weight
                    rgb += colors[index] * weight
                }
                rgb /= max(sum, 0.00001)
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(min(255, rgb.x * 255))
                bytes[offset + 1] = UInt8(min(255, rgb.y * 255))
                bytes[offset + 2] = UInt8(min(255, rgb.z * 255))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func currentColors(rgbOf target: AloCallBackdropPalette, at date: Date) -> [SIMD3<Double>] {
        let to = target.rgb
        guard animated, let previous, target == palette else { return to }
        let u = min(1, max(0, date.timeIntervalSince(changedAt) / 0.3))
        let t = u * u * (3 - 2 * u)
        return zip(previous, to).map { $0 + ($1 - $0) * t }
    }
}

/// Telegram's speaking blobs (CallBlobsLayer): two white shapes at 35 % behind the avatar, the
/// second 90 % of the first, eight points each that morph to new random radii three times a
/// second. They swell with the other person's voice: the avatar by up to 25 %, the blobs twice as
/// much.
struct AloCallSpeakingBlobs: View {
    let avatarSize: CGFloat
    /// Smoothed voice level, 0…5 (Telegram's scale).
    let level: Double
    let animated: Bool

    var body: some View {
        let diameter = avatarSize + 40
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
            let phase = animated ? timeline.date.timeIntervalSinceReferenceDate * 3 : 0
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for blob in 0..<2 {
                    let radius = size.width / 2 * (blob == 0 ? 1 : 0.9)
                    context.fill(Self.blobPath(center: center, radius: radius, phase: phase, seed: blob),
                                 with: .color(.white.opacity(0.35)))
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(1 + min(5, max(0, level)) * 0.05 * 2)
        .animation(.easeOut(duration: 0.15), value: level)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A smooth closed curve through eight points whose radii glide between random sets.
    static func blobPath(center: CGPoint, radius: CGFloat, phase: Double, seed: Int) -> Path {
        let cycle = Int(floor(phase))
        let fraction = phase - floor(phase)
        let count = 8
        let points: [CGPoint] = (0..<count).map { index in
            let from = random(cycle, seed, index)
            let to = random(cycle + 1, seed, index)
            let value = from + (to - from) * fraction
            // Each point sits between 82 % and 100 % of the radius.
            let length = radius * (0.82 + 0.18 * value)
            let angle = Double(index) / Double(count) * 2 * .pi
            return CGPoint(x: center.x + CGFloat(cos(angle)) * length, y: center.y + CGFloat(sin(angle)) * length)
        }
        var path = Path()
        // Catmull–Rom through the points, as cubic Béziers.
        for index in 0..<count {
            let p0 = points[(index - 1 + count) % count], p1 = points[index]
            let p2 = points[(index + 1) % count], p3 = points[(index + 2) % count]
            if index == 0 { path.move(to: p1) }
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    /// A repeatable 0…1 value for (cycle, blob, point), so no state has to be kept per frame.
    private static func random(_ cycle: Int, _ seed: Int, _ index: Int) -> Double {
        var x = UInt64(bitPattern: Int64(cycle &* 73_856_093 ^ seed &* 19_349_663 ^ index &* 83_492_791))
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd; x ^= x >> 33; x &*= 0xc4ceb9fe1a85ec53; x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }
}

/// Telegram's call status (StatusView), 16 pt white: while waiting, the words and three dots that
/// pulse one after another; while talking, four signal bars and the duration.
struct AloCallStatusLine: View {
    enum Content: Equatable {
        case waiting(String)
        case talking(since: Date?, quality: Double?)
        case final(String)
    }

    let content: Content
    let animated: Bool

    var body: some View {
        switch content {
        case .waiting(let text):
            HStack(spacing: 6) {
                Text(text)
                waitingDots
            }
        case .talking(let since, let quality):
            HStack(spacing: 7) {
                signalBars(quality: quality)
                TimelineView(.periodic(from: since ?? .now, by: 1)) { context in
                    Text(Self.duration(from: since, to: context.date)).monospacedDigit()
                }
            }
        case .final(let text):
            Text(text)
        }
    }

    /// 5 pt dots 1 pt apart; each scales 0.3 → 1 and back over 0.6 s, 0.198 s after the one before.
    private var waitingDots: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { index in
                    let cycle = ((t - Double(index) * 0.198) / 0.6).truncatingRemainder(dividingBy: 2)
                    let wave = cycle < 0 ? cycle + 2 : cycle
                    let scale = animated ? 0.3 + 0.7 * (wave < 1 ? wave : 2 - wave) : 1
                    Circle().fill(.white).frame(width: 5, height: 5).scaleEffect(scale)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Four 3 pt bars, 2 pt apart, 3–12 pt tall; a bar is dimmed when the link is below its share.
    private func signalBars(quality: Double?) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity((quality ?? 1) >= Double(index + 1) / 4 - 0.001 ? 1 : 0.5))
                    .frame(width: 3, height: CGFloat(3 * (index + 1)))
            }
        }
        .frame(height: 12, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Качество связи")
        .accessibilityValue("\(Int(((quality ?? 1) * 4).rounded())) из 4")
    }

    static func duration(from start: Date?, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start ?? now)))
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The other person's voice level and the link quality, sampled from WebRTC while a call is on
/// screen. Kept apart from the coordinator so seven updates a second redraw only what uses them.
final class AloCallMeter: ObservableObject {
    /// Telegram's 0…5 voice level, smoothed.
    @Published private(set) var level: Double = 0
    /// 0…1, nil until there is something to measure.
    @Published private(set) var quality: Double?
    private var lastLost: Double?
    private var lastReceived: Double?

    func ingest(audioLevel: Double, packetsLost: Double, packetsReceived: Double, roundTrip: Double?) {
        // WebRTC's level is linear amplitude; ordinary speech is around 0.05–0.3.
        let target = min(5, max(0, audioLevel * 10))
        let next = level * 0.5 + target * 0.5
        level = next < 0.01 ? 0 : next

        defer { lastLost = packetsLost; lastReceived = packetsReceived }
        guard let lastLost, let lastReceived else { return }
        let lost = max(0, packetsLost - lastLost)
        let received = max(0, packetsReceived - lastReceived)
        guard lost + received > 0 else { return }
        let lossScore = 1 - min(1, lost / (lost + received) / 0.12)
        let delayScore = roundTrip.map { 1 - min(1, max(0, ($0 - 0.25) / 0.75)) } ?? 1
        let sample = min(lossScore, delayScore)
        quality = quality.map { $0 * 0.7 + sample * 0.3 } ?? sample
    }

#if DEBUG
    func debugSet(level: Double, quality: Double?) {
        self.level = level
        self.quality = quality
    }
#endif

    func reset() {
        level = 0
        quality = nil
        lastLost = nil
        lastReceived = nil
    }
}
