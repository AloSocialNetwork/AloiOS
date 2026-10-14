import SwiftUI

/// A regular reply is two truncated lines, not a nested message bubble.
/// Keep the accent rule bounded; Shapes otherwise consume a vertical proposal.
struct AloMessageReplyPreview: View {
    let author: String
    let preview: String
    let accent: Color
    let foreground: Color
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(author)
                .font(.system(size: textSize, weight: .semibold))
                .foregroundStyle(accent)
                .lineLimit(1).truncationMode(.tail)
            Text(preview)
                .font(.system(size: textSize, weight: .regular))
                .foregroundStyle(foreground)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 4)
        .frame(minHeight: 44, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) {
            Capsule().fill(accent).frame(width: 2).padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
    }
}
