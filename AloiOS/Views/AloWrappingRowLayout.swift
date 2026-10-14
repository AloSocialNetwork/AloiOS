import SwiftUI

/// Content-sized rows keep reaction chips anchored when counts or widths change.
struct AloWrappingRowLayout: Layout {
    var spacing: CGFloat = 4
    var rowSpacing: CGFloat = 4
    var trailingLastSubview = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + result.origins[index].x,
                                   y: bounds.minY + result.origins[index].y),
                       anchor: .topLeading, proposal: ProposedViewSize(result.sizes[index]))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        let available = max(1, width ?? .greatestFiniteMagnitude)
        let sizes = subviews.map { view in
            let ideal = view.sizeThatFits(.unspecified)
            return view.sizeThatFits(ProposedViewSize(width: min(ideal.width, available), height: nil))
        }
        var origins = [CGPoint]()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let isMetadata = trailingLastSubview && index == sizes.count - 1
            if x > 0 && x + size.width > available + 0.5 {
                x = 0
                y += lineHeight + rowSpacing
                lineHeight = 0
            }
            let originX = isMetadata && width != nil ? max(0, available - size.width) : x
            let originY = isMetadata ? y + max(0, lineHeight - size.height - 6) : y
            origins.append(CGPoint(x: originX, y: originY))
            maxX = max(maxX, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        // Report the same constraint used to wrap. Reporting only maxX caused
        // SwiftUI's placement pass to wrap a second time at a smaller width.
        return (CGSize(width: width == nil ? maxX : available, height: y + lineHeight), origins, sizes)
    }
}
