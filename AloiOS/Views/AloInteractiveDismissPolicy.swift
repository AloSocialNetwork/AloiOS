import CoreGraphics

/// Shared dismissal decision for interactive horizontal navigation.
/// A short accidental pull always returns to its starting position; a decisive
/// pull or a quick rightward fling finishes the navigation.
enum AloInteractiveDismissPolicy {
    static func shouldDismiss(
        translation: CGFloat,
        velocity: CGFloat,
        width: CGFloat
    ) -> Bool {
        guard width > 0, translation >= 24, velocity > -300 else { return false }
        let progress = max(0, translation) / width
        let projectedProgress = max(0, translation + max(0, velocity) * 0.14) / width
        return progress >= 0.30 || projectedProgress >= 0.46 || velocity >= 980
    }
}

/// Direction is locked once per touch sequence. Vertical scrolls must never
/// turn into back navigation halfway through a gesture.
enum AloChatBackIntent {
    static func dismissalWidth(viewport: CGFloat, startX: CGFloat) -> CGFloat {
        // On the rightmost tenth of the screen, 54 pt is physically impossible.
        // Keep the shared 24 pt accident guard, but scale to the remaining runway.
        min(viewport, max(80, (viewport - startX) * 2))
    }
    static func accepts(x: CGFloat, y: CGFloat, startX: CGFloat) -> Bool {
        x > 0 && abs(x) > abs(y) * (startX <= 24 ? 1.15 : 1.6)
    }
}

enum AloChatBackDirection {
    case pending, accepted, rejected

    static func resolve(x: CGFloat, y: CGFloat) -> Self {
        // Telegram's full-screen transition resolves a clear axis after 2 pt,
        // otherwise waits for 10 pt total travel and uses the dominant axis.
        // The old 1.25 ratio permanently rejected normal diagonal back drags.
        let horizontal = abs(x), vertical = abs(y)
        if x < -2 { return .rejected }
        if hypot(horizontal, vertical) > 10 {
            return x > 0 && horizontal >= vertical ? .accepted : .rejected
        }
        if vertical > 2, vertical > horizontal * 2 { return .rejected }
        if x > 2, horizontal > vertical * 2 { return .accepted }
        return .pending
    }
}

enum AloChatNavigationTiming {
    /// NavigationTransitionCoordinator uses remaining distance / release speed
    /// clamped to 50–200 ms, not one bouncy duration for every gesture.
    static func completionDuration(distance: CGFloat, velocity: CGFloat) -> Double {
        guard abs(velocity) > .ulpOfOne else { return 0.2 }
        return Double(max(0.05, min(0.2, abs(distance / velocity))))
    }
}
