import SwiftUI

/// Telegram's swipe to reply: a message follows the finger to the left, an arrow slides in behind it, and letting go past the
/// threshold starts the reply. Only a leftward, mostly horizontal drag takes part, so scrolling and the edge swipe back are untouched.
struct AloSwipeToReply: ViewModifier {
    let enabled: Bool
    let onReply: () -> Void

    @State private var offset: CGFloat = 0
    @State private var decided = false
    @State private var tracking = false
    @State private var passed = false
    private let trigger: CGFloat = 56
    private let maximum: CGFloat = 86

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(AloTheme.accent.opacity(passed ? 0.9 : 0.55), in: Circle())
                    .scaleEffect(min(1, max(0.3, -offset / trigger)))
                    .opacity(min(1, -offset / 24))
                    // Sits just past the row's trailing edge and comes into view as the row moves away.
                    .offset(x: 44 + offset * 0.0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .simultaneousGesture(enabled ? drag : nil)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                let width = value.translation.width
                let height = value.translation.height
                if !decided {
                    decided = true
                    tracking = width < 0 && abs(width) > abs(height) * 1.4
                }
                guard tracking else { return }
                let pulled = min(-width, trigger + (maximum - trigger) * 3)
                // Past the threshold the row resists.
                let shown = pulled <= trigger ? pulled : trigger + (pulled - trigger) * 0.35
                offset = -min(maximum, shown)
                if pulled >= trigger, !passed {
                    passed = true
                    AloHaptics.impact(.light)
                } else if pulled < trigger, passed {
                    passed = false
                }
            }
            .onEnded { _ in
                let fire = tracking && passed
                decided = false
                tracking = false
                passed = false
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { offset = 0 }
                if fire { onReply() }
            }
    }
}

/// A message the person jumped to (from a quote or the pinned bar) is lit across the whole width for a moment.
struct AloMessageHighlight: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.background {
            Rectangle()
                .fill(AloTheme.accent.opacity(active ? 0.16 : 0))
                .padding(.horizontal, -16)
                .padding(.vertical, -4)
                .allowsHitTesting(false)
        }
    }
}

/// Which message's media a viewer opens from, so the viewer can grow out of it (iOS 18's zoom transition).
private struct AloMediaZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var aloMediaZoom: Namespace.ID? {
        get { self[AloMediaZoomNamespaceKey.self] }
        set { self[AloMediaZoomNamespaceKey.self] = newValue }
    }
}

struct AloMediaZoomSource: ViewModifier {
    let messageId: Int
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace, messageId > 0 {
            content.matchedTransitionSource(id: AloMediaZoomSourceID.chat(messageId), in: namespace)
        } else {
            content
        }
    }
}

struct AloMediaZoomDestination: ViewModifier {
    let messageId: Int
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if messageId > 0 {
            content.navigationTransition(.zoom(sourceID: AloMediaZoomSourceID.chat(messageId), in: namespace))
        } else {
            content
        }
    }
}

enum AloMediaZoomSourceID {
    static func chat(_ messageId: Int) -> String { "chat-media-\(messageId)" }
}
