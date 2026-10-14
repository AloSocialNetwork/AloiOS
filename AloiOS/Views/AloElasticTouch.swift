import SwiftUI
import UIKit

/// Passive observer: never claims a touch from selection, scrolling or recording.
private struct AloPassiveTouch: UIViewRepresentable {
    let changed: (CGSize?) -> Void
    func makeUIView(context: Context) -> Marker { Marker(changed: changed) }
    func updateUIView(_ marker: Marker, context: Context) { marker.observer.changed = changed }
    static func dismantleUIView(_ marker: Marker, coordinator: ()) {
        marker.observer.view?.removeGestureRecognizer(marker.observer)
    }

    /// Attach a passive UIKit observer, not a SwiftUI `.gesture` on a Button's
    /// label: the latter replaces the Button's semantic tap recognizer.
    final class Marker: UIView {
        let observer: Observer
        init(changed: @escaping (CGSize?) -> Void) {
            observer = Observer(changed: changed)
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            observer.marker = self
        }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            observer.view?.removeGestureRecognizer(observer)
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController {
                    controller.view.addGestureRecognizer(observer)
                    break
                }
                responder = current.next
            }
        }
    }

    final class Observer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var changed: (CGSize?) -> Void
        weak var marker: UIView?
        private var origin: CGPoint?
        init(changed: @escaping (CGSize?) -> Void) {
            self.changed = changed
            super.init(target: nil, action: nil)
            delegate = self
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            requiresExclusiveTouchType = false
        }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let marker, marker.window != nil, marker.window === touch.view?.window else { return false }
            return marker.bounds.contains(touch.location(in: marker))
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard origin == nil, let touch = touches.first else { return }
            origin = touch.location(in: view?.window)
            changed(.zero)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let origin, let touch = touches.first else { return }
            let point = touch.location(in: view?.window)
            let delta = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            changed(delta)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { changed(nil); state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { changed(nil); state = .cancelled }
        override func reset() { super.reset(); origin = nil; changed(nil) }
    }
}

private struct AloPassiveTouchModifier: ViewModifier {
    let changed: (CGSize?) -> Void
    func body(content: Content) -> some View {
        content.background(AloPassiveTouch(changed: changed).allowsHitTesting(false).accessibilityHidden(true))
    }
}

private struct AloElasticTouchModifier: ViewModifier {
    var enabled: Bool
    private var accessibility = AloVisualAccessibility()
    @State private var translation: CGSize?
    @State private var size = CGSize(width: 44, height: 44)
    init(enabled: Bool) { self.enabled = enabled }
    func body(content: Content) -> some View {
        let pressed = enabled && translation != nil
        let effect = AloElasticTransform.resolve(size: size, translation: translation)
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .scaleEffect(x: accessibility.reduceMotion ? 1 : effect.scale.width,
                         y: accessibility.reduceMotion ? 1 : effect.scale.height)
            .offset(x: accessibility.reduceMotion ? 0 : effect.offset.width,
                    y: accessibility.reduceMotion ? 0 : effect.offset.height)
            .brightness(pressed ? 0.025 : 0)
            .modifier(AloPassiveTouchModifier { value in
                guard enabled else { return }
                if value == nil || translation == nil {
                    let spring: Animation = value == nil
                        ? .interpolatingSpring(mass: 2, stiffness: 460, damping: 21.8)
                        : .interpolatingSpring(mass: 1.36, stiffness: 568, damping: 39.7)
                    withAnimation(accessibility.reduceMotion ? .easeOut(duration: 0.12) : spring) { translation = value }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { translation = value }
                }
            })
            .onChange(of: enabled) { _, _ in translation = nil }
    }
}

/// Size-aware lift, directional stretch and resistant displacement. The lift
/// and spring parameters follow Telegram's TouchEffect; the transform is local
/// to the control and never changes its layout or the surrounding hit regions.
enum AloElasticTransform {
    static func resolve(size: CGSize, translation: CGSize?) -> (scale: CGSize, offset: CGSize) {
        guard let translation else { return (CGSize(width: 1, height: 1), .zero) }
        let width = max(44, size.width), height = max(44, size.height)
        let lift = 1 + 20 / max(width, height)
        let dx = translation.width / width, dy = translation.height / height
        let length = hypot(dx, dy)
        guard length > 0 else { return (CGSize(width: lift, height: lift), .zero) }
        let resistance = length / (length + 5)
        let stretch = 1 + min(0.18, 16 / min(width, height) * resistance)
        let isHorizontal = abs(dx) > abs(dy)
        return (CGSize(width: lift * (isHorizontal ? stretch : 1 / stretch),
                       height: lift * (isHorizontal ? 1 / stretch : stretch)),
                CGSize(width: dx / length * 24 * resistance, height: dy / length * 24 * resistance))
    }
}
extension View {
    func aloElasticTouch(enabled: Bool = true) -> some View { modifier(AloElasticTouchModifier(enabled: enabled)) }

    /// Movement telemetry for a scrub/long-press guard. It must never add a
    /// competing SwiftUI DragGesture to the scroll view's message content.
    @ViewBuilder func aloObserveTouch(enabled: Bool, changed: @escaping (CGSize?) -> Void) -> some View {
        if enabled { modifier(AloPassiveTouchModifier(changed: changed)) }
        else { self }
    }
}
