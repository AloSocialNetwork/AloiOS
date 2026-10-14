import SwiftUI
import UIKit

/// Context activation yields to the history's scroll pan and navigation pan.
/// It never installs a competing SwiftUI gesture on the scroll content.
struct AloMessageLongPress: ViewModifier {
    var enabled = true
    var allowedBounds: (() -> CGRect?)?
    let onPrepare: () -> Void
    let onBegan: () -> Void

    func body(content: Content) -> some View {
        content.background(Host(enabled: enabled, allowedBounds: allowedBounds, onPrepare: onPrepare, onBegan: onBegan)
            .allowsHitTesting(false).accessibilityHidden(true))
    }

    private struct Host: UIViewRepresentable {
        let enabled: Bool
        let allowedBounds: (() -> CGRect?)?
        let onPrepare: () -> Void
        let onBegan: () -> Void
        func makeUIView(context: Context) -> Marker { Marker() }
        func updateUIView(_ view: Marker, context: Context) {
            view.enabled = enabled
            view.allowedBounds = allowedBounds
            view.onPrepare = onPrepare
            view.onBegan = onBegan
        }
        static func dismantleUIView(_ view: Marker, coordinator: ()) {
            view.press.view?.removeGestureRecognizer(view.press)
        }
    }

    private final class Press: UILongPressGestureRecognizer {
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool {
            // SwiftUI may lift the touch handlers of an image/reaction into a
            // shared platform container. Such a child tap must not suppress a
            // stationary context hold on the caption/text beside it. Real
            // scroll and navigation pans still win as soon as the finger moves.
            if other is AloChatBackPan || (other is UIPanGestureRecognizer && other.view is UIScrollView) {
                return true
            }
            return false
        }
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool {
            if other.view is UIScrollView || other is AloChatBackPan { return false }
            return super.canPrevent(other)
        }
    }

    private final class Marker: UIView, UIGestureRecognizerDelegate {
        var onPrepare: (() -> Void)?
        var onBegan: (() -> Void)?
        var enabled = true
        var allowedBounds: (() -> CGRect?)?
        let press = Press()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            press.minimumPressDuration = 0.26
            press.allowableMovement = 18
            press.delegate = self
            press.addTarget(self, action: #selector(changed))
        }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            press.view?.removeGestureRecognizer(press)
            // A caption can live in a separate hosting controller while its
            // touch is routed through the history's platform container. The
            // window is the stable common ancestor; the row's bounds below
            // still restrict which touches this recognizer can receive.
            window?.addGestureRecognizer(press)
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard enabled, window != nil, window === touch.view?.window,
                  window?.rootViewController?.presentedViewController == nil,
                  bounds.contains(touch.location(in: self)) else { return false }
            // A header/composer can visually overlap this row.
            // SwiftUI can place the row's UIKit marker outside the scroll
            // view's native ancestry. Read its visible viewport at touch-down
            // instead of depending on that implementation detail or publishing
            // viewport changes to every row while navigation is animating.
            if let allowed = allowedBounds?(), !allowed.isEmpty,
               !allowed.contains(touch.location(in: nil)) { return false }
            onPrepare?()
            return true
        }
        @objc private func changed() {
            if press.state == .began { onBegan?() }
        }
    }
}
