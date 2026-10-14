import SwiftUI

/// Telegram's reply/forward accessory is 45 pt high with a 44 pt close
/// target and a 2 pt rule. Bound the rule instead of letting a Shape greedily
/// claim the composer's entire vertical proposal. Larger type grows the row.
struct AloComposerAccessory: View {
    enum Kind: String {
        case reply, edit, forward
        var action: String {
            switch self {
            case .reply: return "ответ"
            case .edit: return "редактирование"
            case .forward: return "пересылку"
            }
        }
    }
    let title: String
    let preview: String
    let symbol: String
    let kind: Kind
    let onCancel: () -> Void
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 45

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(AloTheme.accent)
                .frame(width: 32)
                .accessibilityHidden(true)
            Capsule()
                .fill(AloTheme.accent)
                .frame(width: 3, height: max(30, rowHeight - 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: textSize, weight: .medium))
                    .foregroundStyle(AloTheme.accent)
                    .lineLimit(1).truncationMode(.tail)
                Text(preview).font(.system(size: textSize, weight: .regular))
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 44, height: max(44, rowHeight))
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityLabel("Отменить \(kind.action)")
            .accessibilityIdentifier("alo.composer.\(kind.rawValue).cancel")
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: max(45, rowHeight))
        .modifier(AloChatPanelGlass(radius: 22, role: .control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.composer.accessory.\(kind.rawValue)")
    }
}
