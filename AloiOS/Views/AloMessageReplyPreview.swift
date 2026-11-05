import SwiftUI

/// A regular reply is two truncated lines, not a nested message bubble: Telegram iOS's ChatMessageReplyInfoNode on a
/// MessageInlineBlockBackgroundView — 4 pt corners, a 3 pt stripe on the left, the colour at 10 % behind, 14 pt title
/// (semibold) and text, 11 pt from the left and 6 pt from the right.
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
        // The title's line starts 3 pt down and the text's line box ends at the block's edge: 37⅓ pt for two lines.
        .padding(.leading, 11).padding(.trailing, 6).padding(.top, 3)
        .frame(alignment: .leading)
        .background(accent.opacity(0.1))
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .circular))
        .accessibilityElement(children: .combine)
    }
}
