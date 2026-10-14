import SwiftUI
import UIKit

/// A directional recognizer resolves navigation before child pans. Rejected
/// vertical drags immediately belong to the scroll view; every touch resets.
final class AloChatBackPan: UIPanGestureRecognizer, UIGestureRecognizerDelegate {
    var exclusions: [CGRect] = []
    var acceptsTouch: ((UITouch) -> Bool)?
    private(set) var startPoint = CGPoint.zero
    private var direction = AloChatBackDirection.pending

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        maximumNumberOfTouches = 1
        delaysTouchesBegan = false
        cancelsTouchesInView = true
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first, numberOfTouches <= 1 else {
            if state == .began || state == .changed { state = .cancelled }
            else if state == .possible { state = .failed }
            return
        }
        startPoint = touch.location(in: nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, state != .failed else { return }
        let point = touch.location(in: nil)
        // Raw movement is used only to decide intent. The transition is driven
        // by UIPan's native translation, without adding its recognition slop.
        if direction == .pending {
            direction = AloChatBackDirection.resolve(x: point.x - startPoint.x, y: point.y - startPoint.y)
            switch direction {
            case .pending: return
            case .rejected: state = .failed; return
            case .accepted: break
            }
        }
        super.touchesMoved(touches, with: event)
        if state == .possible { state = .began }
    }

    override func reset() {
        super.reset()
        direction = .pending
        startPoint = .zero
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        // SwiftUI also wraps child drags in non-UIPan recognizers. Keep receiving
        // movement until our directional gate can decide; excluded controls never
        // enter this recognizer at all. A clear vertical intent fails after 2 pt;
        // ambiguous diagonal intent resolves after 10 pt total movement.
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !exclusions.contains(where: { $0.contains(touch.location(in: nil)) }),
              !AloChatSwipeRegions.contains(touch),
              acceptsTouch?(touch) ?? true else { return false }
        return !touch.view.isEditableTextInput && !touch.view.isFloatingCircleControl
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Only scrolling observes the same initial touch. Two horizontal pans
        // must not move the message/miniature and navigate at the same time.
        otherGestureRecognizer.isScrollPanGesture
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Do not wait for a ScrollView pan. This recognizer resolves its axis
        // within the first few points: a vertical drag fails immediately and
        // stays a scroll; an intentional horizontal drag gets the interactive
        // back transition even when it begins in the middle of the chat.
        false
    }
}

extension UIGestureRecognizer {
    var isScrollPanGesture: Bool {
        // A child scrubber/tap may also live inside UIScrollView. That does
        // not make it the scroll pan: allowing both moves two surfaces at once.
        guard let scroll = view as? UIScrollView else { return false }
        return self === scroll.panGestureRecognizer
    }
}

private extension Optional where Wrapped == UIView {
    var isFloatingCircleControl: Bool {
        var current = self
        while let view = current {
            if view is AloFloatingCircleContainer { return true }
            current = view.superview
        }
        return false
    }

    var isEditableTextInput: Bool {
        var current = self
        while let view = current {
            if view is UITextField || view is UITextView { return true }
            current = view.superview
        }
        return false
    }
}

struct AloChatBackSwipe: ViewModifier {
    let enabled: Bool
    let exclusions: [CGRect]
    let onChanged: (CGFloat, CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    let onCancelled: () -> Void

    func body(content: Content) -> some View {
        // Install on the public controller view. SwiftUI `.gesture` arbitrates
        // before UIKit and can consume child taps/scrolls despite our delegate.
        content.background(HostedBackGesture(configuration: self).allowsHitTesting(false).accessibilityHidden(true))
    }

    fileprivate func handle(_ pan: AloChatBackPan) {
        // Telegram drives its transition with UIPan's native translation.
        // Recognition slop must not become a jump at the first changed event.
        let translation = pan.translation(in: nil).x
        switch pan.state {
        case .began, .changed: onChanged(translation, pan.startPoint.x)
        case .ended: onEnded(translation, pan.velocity(in: nil).x)
        case .cancelled, .failed: onCancelled()
        default: break
        }
    }
}

/// The same recognizer on iOS 18 and 26, using no private SwiftUI classes.
private struct HostedBackGesture: UIViewRepresentable {
    let configuration: AloChatBackSwipe

    func makeUIView(context: Context) -> Marker {
        let marker = Marker()
        marker.configuration = configuration
        return marker
    }

    func updateUIView(_ marker: Marker, context: Context) {
        marker.configuration = configuration
        marker.pan.exclusions = configuration.exclusions
        let enabled = configuration.enabled
        if marker.pan.isEnabled != enabled { marker.pan.isEnabled = enabled }
    }

    static func dismantleUIView(_ marker: Marker, coordinator: ()) {
        marker.pan.view?.removeGestureRecognizer(marker.pan)
    }

    final class Marker: UIView {
        var configuration: AloChatBackSwipe?
        let pan = AloChatBackPan(target: nil, action: nil)
        private weak var owner: UIViewController?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            pan.addTarget(self, action: #selector(changed))
            pan.acceptsTouch = { [weak self] touch in
                guard let self, let owner, owner.presentedViewController == nil,
                      let touchedView = touch.view, touchedView.isDescendant(of: owner.view),
                      window != nil else { return false }
                return bounds.contains(touch.location(in: self))
            }
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            pan.view?.removeGestureRecognizer(pan)
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController {
                    owner = controller
                    controller.view.addGestureRecognizer(pan)
                    break
                }
                responder = current.next
            }
        }

        @objc private func changed() { configuration?.handle(pan) }
    }
}

/// Non-observable presentation telemetry. Animation frames must not publish
/// updates to the history; a new pan only samples this value at touch-down.
final class AloChatTransitionPosition {
    var x: CGFloat = 0
}

struct AloChatMotionOffset: AnimatableModifier {
    var x: CGFloat
    let position: AloChatTransitionPosition
    var animatableData: CGFloat {
        get { x }
        set { x = newValue; position.x = newValue }
    }
    func body(content: Content) -> some View {
        position.x = x
        return content.offset(x: x)
    }
}
