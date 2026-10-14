import UIKit

/// Temporarily covers protected media before iOS captures an app-switcher snapshot.
/// iOS does not offer an API that can prevent a user screenshot before it is taken.
final class AloProtectedContentShield {
    static let shared = AloProtectedContentShield()

    private var visibleViewCount = 0
    private weak var privacyOverlay: UIView?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showPrivacyOverlayIfNeeded()
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.removePrivacyOverlay()
            }
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func beginViewingProtectedContent() {
        dispatchPrecondition(condition: .onQueue(.main))
        visibleViewCount += 1
    }

    func endViewingProtectedContent() {
        dispatchPrecondition(condition: .onQueue(.main))
        visibleViewCount = max(0, visibleViewCount - 1)
        if visibleViewCount == 0 {
            removePrivacyOverlay()
        }
    }

    private func showPrivacyOverlayIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard visibleViewCount > 0,
              let window = activeWindow else { return }

        if let privacyOverlay, privacyOverlay.superview === window {
            privacyOverlay.frame = window.bounds
            return
        }

        let overlay = UIView(frame: window.bounds)
        overlay.backgroundColor = .black
        overlay.isUserInteractionEnabled = false
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(overlay)
        privacyOverlay = overlay
    }

    private func removePrivacyOverlay() {
        dispatchPrecondition(condition: .onQueue(.main))
        privacyOverlay?.removeFromSuperview()
        privacyOverlay = nil
    }

    private var activeWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}
