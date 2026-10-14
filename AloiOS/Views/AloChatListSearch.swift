import SwiftUI

/// Telegram-style chat list search: the field sits above the first row, is hidden
/// on open, appears when the list is pulled down and snaps to either state.
enum AloChatListSearchMetrics {
    /// The same height and glass as the Search tab's field: one search standard everywhere.
    static let fieldHeight: CGFloat = AloSocialMetrics.searchHeight
    /// 40pt glass inside a 44pt touch row; a 10pt title gap gives a 54pt reveal range.
    static let barHeight: CGFloat = AloSocialMetrics.controlHeight + AloSocialMetrics.searchSpacing
    static func barHeight(visualHeight: CGFloat) -> CGFloat {
        max(AloSocialMetrics.controlHeight, min(visualHeight, AloSocialMetrics.maximumControlHeight)) + AloSocialMetrics.searchSpacing
    }
    static func settledOffset(_ proposed: CGFloat, revealHeight: CGFloat) -> CGFloat {
        guard proposed >= 0, proposed < revealHeight else { return proposed }
        return proposed < revealHeight * 0.5 ? 0 : revealHeight
    }
}

/// Releasing the scroll within the search bar's height settles on fully shown or fully hidden.
struct AloSearchRevealBehavior: ScrollTargetBehavior {
    let revealHeight: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.y = AloChatListSearchMetrics.settledOffset(target.rect.minY, revealHeight: revealHeight)
    }
}

struct AloChatListSearchBar: View {
    @Binding var text: String
    var focused: Binding<Bool>
    let isActive: Bool
    let onCancel: () -> Void
    private var accessibility = AloVisualAccessibility()
    @ScaledMetric(relativeTo: .subheadline) private var height = AloSocialMetrics.searchHeight

    init(text: Binding<String>, focused: Binding<Bool>, isActive: Bool, onCancel: @escaping () -> Void) {
        _text = text
        self.focused = focused
        self.isActive = isActive
        self.onCancel = onCancel
    }

    var body: some View {
        AloSocialSearchField(text: $text, identifier: "alo.chats.search",
            focused: focused)
            .padding(.horizontal, AloSocialMetrics.inset)
            .padding(.top, AloSocialMetrics.searchSpacing)
            .frame(height: AloChatListSearchMetrics.barHeight(visualHeight: height))
            .accessibilityAction(named: "Завершить поиск", onCancel)
    }
}

/// Telegram's row highlight: instant on touch-down, soft fade on release.
struct AloChatRowHighlight: ViewModifier {
    let pressed: Bool

    func body(content: Content) -> some View {
        content.background(Color.white.opacity(pressed ? 0.08 : 0))
            .animation(pressed ? nil : .easeOut(duration: 0.3), value: pressed)
    }
}

struct AloChatMessageHitRow: View {
    let hit: AloOfflineMessageSearchHit
    let preview: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                AloAvatar(name: hit.conversation.title, url: hit.conversation.avatarUrl, size: 46,
                          colorSeed: "search-\(hit.conversation.peerId)")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(hit.conversation.title).font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AloTheme.text).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(AloFormatters.messageTime(hit.message.createdAt))
                            .font(.system(size: 14)).foregroundStyle(AloTheme.muted)
                    }
                    Text(preview).font(.system(size: 15)).foregroundStyle(AloTheme.muted).lineLimit(2)
                }
            }
            .padding(.horizontal, AloSocialMetrics.inset).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloChatRowPressStyle())
    }
}

struct AloChatRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(AloChatRowHighlight(pressed: configuration.isPressed))
    }
}

struct AloChatSectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AloTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AloSocialMetrics.inset).padding(.top, 14).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
