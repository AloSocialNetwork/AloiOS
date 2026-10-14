import Foundation
import CoreGraphics
import ImageIO
import AVFoundation

struct AloMediaDimensions: Equatable, Sendable {
    let width: Double
    let height: Double

    init?(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 100_000, height <= 100_000 else { return nil }
        self.width = width
        self.height = height
    }

    init?(_ metadata: [String: String]) {
        guard let width = metadata["width"].flatMap(Double.init),
              let height = metadata["height"].flatMap(Double.init) else { return nil }
        self.init(width: width, height: height)
    }

    var metadata: [String: String] { ["width": String(width), "height": String(height)] }

    /// Header properties only: never decode a full-resolution photograph merely
    /// to choose a bubble height. EXIF rotations 5...8 swap the display axes.
    static func image(sourceURL: URL) -> Self? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? Self(width: height.doubleValue, height: width.doubleValue)
            : Self(width: width.doubleValue, height: height.doubleValue)
    }

    static func video(sourceURL: URL) async -> Self? {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let display = CGRect(origin: .zero, size: size).applying(transform)
        return Self(width: abs(display.width), height: abs(display.height))
    }
}

enum AloChatMediaSizing {
    static let maximumWidth: CGFloat = 300
    static let minimumWidth: CGFloat = 170
    static let minimumHeight: CGFloat = 74

    /// Compact Telegram message limits. Portrait media may be narrower; don't
    /// force a 9:16 movie into a full-width, fixed-height landscape thumbnail.
    static func single(dimensions: AloMediaDimensions?, video: Bool, availableWidth: CGFloat) -> CGSize {
        let limit = max(1, min(maximumWidth, availableWidth))
        // A size-less photo is drawn square until its real proportions are known: phone photos are
        // mostly portrait, and a landscape guess made them a low strip.
        let ratio = dimensions.map { CGFloat($0.width / $0.height) } ?? 1
        let maxHeight: CGFloat = video ? (ratio > 1 ? 250 : 360) : 380
        let width = min(limit, max(min(minimumWidth, limit), min(limit, maxHeight * ratio)))
        return CGSize(width: width, height: max(minimumHeight, min(maxHeight, width / ratio)))
    }
}

/// Telegram's album mosaic (`chatMessageBubbleMosaicLayout`) inside the compact 300 × 380 media box
/// with 1 pt gaps: hand-tuned schemes for 2–4 items, and Telegram's row search for 5–10 items or
/// any panorama wider than 2:1.
enum AloChatMosaic {
    static let spacing: CGFloat = 1
    static let maximumItems = 10
    private static let minWidth: CGFloat = 68
    private static let minHeight: CGFloat = 81

    static func layout(dimensions: [AloMediaDimensions?], availableWidth: CGFloat) -> (frames: [CGRect], size: CGSize) {
        let ratios = dimensions.prefix(maximumItems).map { value -> CGFloat in
            guard let value else { return 1 }
            return min(10, max(0.1, CGFloat(value.width / value.height)))
        }
        // `maxDimensions.fittedToWidthOrSmaller`: a narrow screen shrinks both sides.
        let W = min(AloChatMediaSizing.maximumWidth, max(1, availableWidth))
        let H = 380 * W / AloChatMediaSizing.maximumWidth
        guard ratios.count >= 2 else {
            let height = W / (ratios.first ?? 1)
            return ([CGRect(x: 0, y: 0, width: W, height: height)], CGSize(width: W, height: height))
        }
        // Telegram's average starts from 1 before adding every ratio.
        let average = (1 + ratios.reduce(0, +)) / CGFloat(ratios.count)
        let frames: [CGRect]
        if ratios.count <= 4, !ratios.contains(where: { $0 > 2 }) {
            frames = special(ratios, average: average, W: W, H: H)
        } else {
            frames = general(ratios, average: average, W: W)
        }
        let size = CGSize(width: (frames.map(\.maxX).max() ?? W).rounded(), height: (frames.map(\.maxY).max() ?? H).rounded())
        return (frames, size)
    }

    private static func special(_ ratios: [CGFloat], average: CGFloat, W: CGFloat, H: CGFloat) -> [CGRect] {
        let s = spacing
        let proportions = ratios.map { $0 > 1.2 ? "w" : $0 < 0.8 ? "n" : "q" }.joined()
        switch ratios.count {
        case 2:
            if proportions == "ww", average > 1.4 * (W / H), abs(ratios[0] - ratios[1]) < 0.2 {
                let height = floor(min(W / ratios[0], min(W / ratios[1], (H - s) / 2)))
                return [CGRect(x: 0, y: 0, width: W, height: height), CGRect(x: 0, y: height + s, width: W, height: height)]
            } else if proportions == "ww" || proportions == "qq" {
                let width = (W - s) / 2
                let height = floor(min(width / ratios[0], min(width / ratios[1], H)))
                return [CGRect(x: 0, y: 0, width: width, height: height), CGRect(x: width + s, y: 0, width: width, height: height)]
            } else {
                let second = floor(min(0.5 * (W - s), ((W - s) / ratios[0] / (1 / ratios[0] + 1 / ratios[1])).rounded()))
                let first = W - second - s
                let height = floor(min(H, min(first / ratios[0], second / ratios[1]).rounded()))
                return [CGRect(x: 0, y: 0, width: first, height: height), CGRect(x: first + s, y: 0, width: second, height: height)]
            }
        case 3:
            if proportions.hasPrefix("n") {
                let thirdHeight = min((H - s) * 0.5, (ratios[1] * (W - s) / (ratios[2] + ratios[1])).rounded())
                let secondHeight = H - thirdHeight - s
                let rightWidth = max(minWidth, min((W - s) * 0.5, min(thirdHeight * ratios[2], secondHeight * ratios[1]).rounded()))
                let leftWidth = min(H * ratios[0], W - s - rightWidth).rounded()
                return [CGRect(x: 0, y: 0, width: leftWidth, height: H),
                        CGRect(x: leftWidth + s, y: 0, width: rightWidth, height: secondHeight),
                        CGRect(x: leftWidth + s, y: secondHeight + s, width: rightWidth, height: thirdHeight)]
            } else {
                let firstHeight = floor(min(W / ratios[0], (H - s) * 0.66))
                let half = (W - s) / 2
                let secondHeight = min(H - firstHeight - s, min(half / ratios[1], half / ratios[2]).rounded())
                return [CGRect(x: 0, y: 0, width: W, height: firstHeight),
                        CGRect(x: 0, y: firstHeight + s, width: half, height: secondHeight),
                        CGRect(x: half + s, y: firstHeight + s, width: half, height: secondHeight)]
            }
        default:
            if proportions.hasPrefix("w") {
                let h0 = min(W / ratios[0], (H - s) * 0.66).rounded()
                var h = ((W - 2 * s) / (ratios[1] + ratios[2] + ratios[3])).rounded()
                let w0 = max(minWidth, min((W - 2 * s) * 0.4, h * ratios[1]))
                let w2 = max(max(minWidth, (W - 2 * s) * 0.33), h * ratios[3])
                let w1 = W - w0 - w2 - 2 * s
                h = max(minHeight, min(H - h0 - s, h))
                return [CGRect(x: 0, y: 0, width: W, height: h0),
                        CGRect(x: 0, y: h0 + s, width: w0, height: h),
                        CGRect(x: w0 + s, y: h0 + s, width: w1, height: h),
                        CGRect(x: w0 + w1 + 2 * s, y: h0 + s, width: w2, height: h)]
            } else {
                let w0 = min(H * ratios[0], (W - s) * 0.6).rounded()
                var w = ((H - 2 * s) / (1 / ratios[1] + 1 / ratios[2] + 1 / ratios[3])).rounded()
                let h0 = floor(w / ratios[1])
                let h1 = floor(w / ratios[2])
                let h2 = H - h0 - h1 - 2 * s
                w = max(minWidth, min(W - w0 - s, w))
                return [CGRect(x: 0, y: 0, width: w0, height: H),
                        CGRect(x: w0 + s, y: 0, width: w, height: h0),
                        CGRect(x: w0 + s, y: h0 + s, width: w, height: h1),
                        CGRect(x: w0 + s, y: h0 + h1 + 2 * s, width: w, height: h2)]
            }
        }
    }

    /// Telegram's search over 2-, 3- and 4-row splits: rows fill the width, the total height
    /// should be near 4/3 of the width, and rows that shrink downwards or are too low lose.
    private static func general(_ ratios: [CGFloat], average: CGFloat, W: CGFloat) -> [CGRect] {
        let s = spacing
        let cropped = ratios.map { ratio -> CGFloat in
            let value = average > 1.1 ? max(1, ratio) : min(1, ratio)
            return max(0.66667, min(1.7, value))
        }
        let n = cropped.count
        func rowHeight(_ range: Range<Int>) -> CGFloat {
            (W - CGFloat(range.count - 1) * s) / cropped[range].reduce(0, +)
        }
        var attempts: [[Int]] = []
        for first in 1..<n where first <= 3 && n - first <= 3 {
            attempts.append([first, n - first])
        }
        if n >= 3 {
            for first in 1...(n - 2) {
                for second in 1...(n - first - 1) {
                    let third = n - first - second
                    if first <= 3, second <= (average < 0.85 ? 4 : 3), third <= 3 { attempts.append([first, second, third]) }
                }
            }
        }
        if n >= 4 {
            for first in 1...(n - 3) {
                for second in 1...(n - first - 2) {
                    for third in 1...(n - first - second - 1) {
                        let fourth = n - first - second - third
                        if first <= 3, second <= 3, third <= 3, fourth <= 3 { attempts.append([first, second, third, fourth]) }
                    }
                }
            }
        }
        let maxHeight = floor(W / 3 * 4)
        var best: (counts: [Int], heights: [CGFloat], diff: CGFloat)?
        for counts in attempts {
            var heights: [CGFloat] = []
            var start = 0
            for count in counts {
                heights.append(rowHeight(start..<(start + count)))
                start += count
            }
            var total = s * CGFloat(counts.count - 1)
            var minLineHeight = CGFloat.greatestFiniteMagnitude
            for height in heights {
                total += floor(height)
                minLineHeight = min(minLineHeight, total)
            }
            var diff = abs(total - maxHeight)
            if counts.count > 1, counts[0] > counts[1]
                || (counts.count > 2 && counts[1] > counts[2])
                || (counts.count > 3 && counts[2] > counts[3]) {
                diff *= 1.5
            }
            if minLineHeight < minWidth { diff *= 1.5 }
            if best == nil || diff < best!.diff { best = (counts, heights, diff) }
        }
        guard let best else { return [] }
        var frames: [CGRect] = []
        var lastInRow: [Int] = []
        var index = 0
        var y: CGFloat = 0
        for (row, count) in best.counts.enumerated() {
            let height = ceil(best.heights[row])
            var x: CGFloat = 0
            for _ in 0..<count {
                let width = ceil(cropped[index] * height)
                frames.append(CGRect(x: x, y: y, width: width, height: height))
                x += width + s
                index += 1
            }
            lastInRow.append(index - 1)
            y += height + s
        }
        // Every row ends on the same right edge.
        let maxRight = lastInRow.map { frames[$0].maxX }.max() ?? W
        for last in lastInRow {
            frames[last].size.width = max(frames[last].width, maxRight - frames[last].minX)
        }
        return frames
    }
}

/// Sizes picked for size-less media while a chat is open. A photo whose size becomes known while
/// it is on screen keeps the frame it was first laid out with, so the history never jumps; the
/// real proportions apply the next time the chat opens.
@MainActor
enum AloChatMediaSession {
    private static var resolved: [String: AloMediaDimensions?] = [:]

    static func dimensions(forKey key: String, resolve: () -> AloMediaDimensions?) -> AloMediaDimensions? {
        if let known = resolved[key] { return known }
        let value = resolve()
        resolved[key] = value
        return value
    }

    static func reset() { resolved.removeAll() }
}

/// Post media in the feed, with Telegram's limits: portrait media is at most 380 pt tall
/// for 300 pt of width (ratio 0.79), landscape is allowed up to 1.6. Unknown size
/// uses a tall 4:5 frame, so photos are never shown as a 16:9 strip.
enum AloPostMediaSizing {
    static let defaultRatio: CGFloat = 4.0 / 5.0
    static let minimumRatio: CGFloat = 0.79
    static let maximumRatio: CGFloat = 1.6

    static func ratio(for dimensions: AloMediaDimensions?) -> CGFloat {
        guard let dimensions else { return defaultRatio }
        return min(maximumRatio, max(minimumRatio, CGFloat(dimensions.width / dimensions.height)))
    }
}
