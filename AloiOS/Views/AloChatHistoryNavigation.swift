import SwiftUI

struct AloChatHistoryViewport: Equatable {
    let isAtBottom: Bool
    let showsDownButton: Bool

    init(contentHeight: CGFloat, offsetY: CGFloat, viewportHeight: CGFloat, bottomInset: CGFloat) {
        let remaining = contentHeight - offsetY - viewportHeight + bottomInset
        isAtBottom = remaining <= 48
        showsDownButton = remaining > 120
    }
}

/// Initial lazy-list measurements may precede its scroll-to-bottom placement.
/// Suppress that transient indicator, but an explicit user scroll must enable
/// navigation even if expansion/keyboard layout never reported the bottom.
struct AloChatHistoryNavigationState: Equatable {
    private var viewport: AloChatHistoryViewport?
    private var isReady = false

    var showsDownButton: Bool { isReady && viewport?.showsDownButton == true }

    mutating func update(_ viewport: AloChatHistoryViewport) {
        self.viewport = viewport
        if viewport.isAtBottom { isReady = true }
    }

    mutating func userInteracted() { isReady = true }
}

enum AloChatBottomScrollCorrection {
    static let maximumAttempts = 3

    static func isNeeded(footer: CGRect, viewportHeight: CGFloat, attempt: Int) -> Bool {
        guard attempt < maximumAttempts, viewportHeight > 0 else { return false }
        // A lazy layout can publish its real footer after the first scroll.
        guard footer != .zero else { return true }
        return abs(footer.maxY - viewportHeight) > 1
    }
}

/// Count actual incoming IDs not yet reached in this open history, not refresh
/// events, own optimistic/acknowledged sends, or a fabricated server total.
struct AloChatUnseenMessages {
    private var knownIDs = Set<Int>()
    private(set) var unseenIDs = Set<Int>()

    mutating func reset(messages: [AloChatMessage]) {
        knownIDs = Set(messages.map(\.id))
        unseenIDs.removeAll()
    }

    mutating func update(messages: [AloChatMessage], currentUserID: Int, isAtBottom: Bool) {
        let IDs = Set(messages.map(\.id))
        if isAtBottom {
            unseenIDs.removeAll()
        } else {
            unseenIDs.formIntersection(IDs)
            unseenIDs.formUnion(messages.filter {
                $0.id > 0 && !knownIDs.contains($0.id) && $0.senderId != currentUserID && !$0.isScheduled
            }.map(\.id))
        }
        knownIDs = IDs
    }

    mutating func reachedBottom() { unseenIDs.removeAll() }
}

struct AloChatHistoryDownButton: View {
    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(AloTheme.text)
                .frame(width: 40, height: 40)
                .modifier(AloChatGlass())
                .overlay(alignment: .top) {
                    if unreadCount > 0 {
                        Text(AloCompactCount.string(unreadCount))
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, unreadCount > 9 ? 5 : 0)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(AloTheme.accent, in: Capsule())
                            .offset(y: -7)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(AloControlPressStyle())
        .accessibilityIdentifier("alo.chat.scroll-bottom")
        .accessibilityLabel("К последним сообщениям")
        .accessibilityValue(unreadCount > 0 ? "Непрочитанных сообщений: \(unreadCount)" : "")
    }
}
