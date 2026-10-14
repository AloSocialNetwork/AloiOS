import SwiftUI
import UIKit

/// Read control hit regions only when a touch begins. Publishing all control
/// frames while scrolling used to invalidate the whole chat on every frame.
enum AloChatSwipeRegions {
    private static let markers = NSHashTable<Marker>.weakObjects()

    final class Marker: UIView {
        var ring = false
        var enabled = true

        func owns(_ touch: UITouch) -> Bool {
            guard enabled, window != nil, window === touch.view?.window else { return false }
            var ancestor: UIView? = self
            while let view = ancestor {
                if view.isHidden || view.alpha < 0.01 { return false }
                if view.clipsToBounds, !view.bounds.contains(touch.location(in: view)) { return false }
                ancestor = view.superview
            }
            let location = touch.location(in: self)
            guard bounds.contains(location) else { return false }
            guard ring else { return true }
            let radius = min(bounds.width, bounds.height) / 2
            let distance = hypot(location.x - bounds.midX, location.y - bounds.midY)
            return abs(distance - radius) <= 28
        }
    }

    static func contains(_ touch: UITouch) -> Bool {
        markers.allObjects.contains { $0.owns(touch) }
    }

    struct Region: UIViewRepresentable {
        var ring = false
        var enabled = true

        func makeUIView(context: Context) -> Marker {
            let view = Marker()
            view.isUserInteractionEnabled = false
            view.ring = ring
            view.enabled = enabled
            markers.add(view)
            return view
        }

        func updateUIView(_ view: Marker, context: Context) { view.ring = ring; view.enabled = enabled }
    }
}

extension View {
    func aloChatSwipeControl(ring: Bool = false, enabled: Bool = true) -> some View {
        background(AloChatSwipeRegions.Region(ring: ring, enabled: enabled).allowsHitTesting(false).accessibilityHidden(true))
    }
}
