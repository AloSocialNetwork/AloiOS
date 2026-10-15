import SwiftUI
import UIKit

/// Touches on the status bar never reach the app's views: iOS turns them into "scroll to top".
/// Telegram's ScrollToTopProxyView answers that request instead: a 1 pt scroll view just above
/// the window that is always scrolled down, whose delegate runs an action and declines to scroll.
/// iOS only asks a scroll view when no other one competes, so while this view is on screen the
/// window's other scroll views give up scroll-to-top (also ones that appear later), and get it
/// back when it goes. A tap on the clock or the battery then runs `action`.
struct AloStatusBarTapCatcher: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.action = action
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.action = action
    }

    static func dismantleUIView(_ view: HostView, coordinator: ()) {
        view.detach()
    }

    final class HostView: UIView {
        var action: (() -> Void)? {
            didSet { proxy.action = action }
        }
        private let proxy = ProxyScrollView()
        /// Scroll views whose scroll-to-top was switched off here, to switch back on.
        private let silenced = NSHashTable<UIScrollView>.weakObjects()
        private var sweep: Timer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else {
                detach()
                return
            }
            if proxy.superview !== window { window.addSubview(proxy) }
            proxy.frame = CGRect(x: 0, y: -1, width: window.bounds.width, height: 1)
            proxy.scrollsToTop = true
            silenceOthers(in: window)
            // Screens opened while the call is minimized bring their own scroll views.
            sweep?.invalidate()
            sweep = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.silenceOthers(in: window)
            }
        }

        func detach() {
            sweep?.invalidate()
            sweep = nil
            proxy.scrollsToTop = false
            proxy.removeFromSuperview()
            for scrollView in silenced.allObjects { scrollView.scrollsToTop = true }
            silenced.removeAllObjects()
        }

        private func silenceOthers(in view: UIView) {
            if let scrollView = view as? UIScrollView, scrollView !== proxy, scrollView.scrollsToTop {
                scrollView.scrollsToTop = false
                silenced.add(scrollView)
            }
            view.subviews.forEach(silenceOthers)
        }
    }

    final class ProxyScrollView: UIScrollView, UIScrollViewDelegate {
        var action: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            delegate = self
            scrollsToTop = true
            contentInsetAdjustmentBehavior = .never
            allowsKeyboardScrolling = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { nil }

        // Always scrolled down, so iOS thinks there is a top to go back to.
        override var frame: CGRect {
            didSet {
                contentSize = CGSize(width: frame.width, height: frame.height + 1_000)
                contentOffset = CGPoint(x: 0, y: 1_000)
            }
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            action?()
            return false
        }
    }
}
