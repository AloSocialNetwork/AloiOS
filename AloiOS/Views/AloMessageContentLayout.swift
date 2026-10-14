import SwiftUI
import UIKit

/// The message establishes its width. Reactions may add rows, never resize or
/// rewrap the text/media above them. Keep the two subviews stable across updates.
struct AloMessageContentLayout: Layout {
    var spacing: CGFloat = 2
    /// Narrowest content width. Cards and media keep 84; a text bubble uses Telegram's 40 pt bubble.
    var minimumWidth: CGFloat = 84

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified)
        let limit = min(proposal.width ?? ideal.width, max(minimumWidth, ideal.width))
        let fitted = content.sizeThatFits(ProposedViewSize(width: limit, height: nil))
        let width = min(limit, max(minimumWidth, fitted.width))
        let primary = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let footer = subviews.dropFirst().first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
        return CGSize(width: width, height: primary.height + footer.height + (footer.height > 0 ? spacing : 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let proposed = ProposedViewSize(width: bounds.width, height: nil)
        let primary = content.sizeThatFits(proposed)
        content.place(at: bounds.origin, anchor: .topLeading, proposal: proposed)
        subviews.dropFirst().first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + primary.height + spacing),
            anchor: .topLeading, proposal: proposed
        )
    }
}

/// Measure text first, then pin status to the actual trailing edge. Unlike an
/// HStack this never reserves a full-height empty column alongside every line.
/// Telegram's date node: 5 pt after the last line's text; the time sits 1 pt below the line's
/// bottom, on the same line when it fits, otherwise on a line of its own.
struct AloTextStatusLayout: Layout {
    var spacing: CGFloat = 5
    var showsStatus = true
    var attributedText: AttributedString? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let result = measure(ProposedViewSize(width: bounds.width, height: nil), subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: result.textWidth, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.maxY + 1), anchor: .bottomTrailing,
                          proposal: .unspecified)
    }

    private func measure(_ proposal: ProposedViewSize, _ views: Subviews) -> (size: CGSize, textWidth: CGFloat) {
        guard views.count == 2 else { return (.zero, 0) }
        let ideal = views[0].sizeThatFits(.unspecified)
        let meta = views[1].sizeThatFits(.unspecified)
        let limit = max(meta.width, proposal.width ?? (ideal.width + spacing + meta.width))
        if ideal.width + spacing + meta.width <= limit {
            return (CGSize(width: ideal.width + spacing + meta.width, height: max(ideal.height, meta.height)), ideal.width)
        }
        // Keep the measured wrapping width. Shrinking to used glyph width then
        // proposing that narrower width during placement can add a line *after*
        // height/status have been computed (device-dependent overlap/drift).
        let width = limit
        let text = views[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let fitsLastLine = attributedText.map {
            Self.lastLineWidth(NSAttributedString($0), width: width) + spacing + meta.width + 1 <= width
        } ?? false
        return (CGSize(width: width, height: text.height + (showsStatus && !fitsLastLine ? meta.height : 0)), width)
    }

    static func lastLineWidth(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        var lastWidth: CGFloat = width
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, _ in
            lastWidth = used.width
        }
        return lastWidth
    }
}

/// Visual shorthand only; accessibility always exposes the unabridged count.
enum AloCompactCount {
    static func string(_ count: Int) -> String {
        let value = max(0, count)
        for (divisor, suffix) in [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")] {
            if value >= divisor {
                let tenths = value / (divisor / 10)
                let whole = tenths / 10
                let fraction = tenths % 10
                return fraction == 0 || whole >= 100 ? "\(whole)\(suffix)" : "\(whole).\(fraction)\(suffix)"
            }
        }
        return String(value)
    }
}
