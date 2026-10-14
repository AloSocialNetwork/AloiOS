import SwiftUI
import AVFoundation
import Observation
import UIKit

struct AloCircleQueueItem: Equatable {
    let id: String
    let messageID: Int
    let url: URL
    let title: String
}

/// Presentation hosts borrow one video view, never a second AVPlayerLayer.
enum AloCircleSurfaceOwner: Equatable {
    case none
    case inline
    case floating
}

enum AloCirclePresentation {
    // Telegram reserves an additional 48 pt below docked media. Keep the
    // history-navigation control accessible even when the circle docks right.
    static let bottomControlsClearance: CGFloat = 48
    static let floatingEdgeInset: CGFloat = 4

    /// OverlayInstantVideoNode's compact/regular overlay sizes. The host already
    /// excludes the header, input panel and the extra bottom-control clearance.
    static func floatingDiameter(boundingSize: CGSize) -> CGFloat {
        let available = min(boundingSize.width, boundingSize.height)
        let preferred: CGFloat = available > 320 ? 150 : 120
        return min(preferred, max(44, available - floatingEdgeInset * 2))
    }

    static func diameter(available: CGFloat, expanded: Bool) -> CGFloat {
        min(max(44, available), expanded ? 404 : 212)
    }

    static func isVisible(_ frame: CGRect, viewport: CGRect, wasVisible: Bool) -> Bool {
        guard frame.width > 0, frame.height > 0, !viewport.isEmpty else { return false }
        let intersection = frame.intersection(viewport)
        guard !intersection.isNull else { return false }
        // Hysteresis prevents repeated transfers at a scroll edge.
        return intersection.height / frame.height >= (wasVisible ? 0.40 : 0.65)
    }

    static func bounded(_ point: CGPoint, size: CGSize, diameter: CGFloat) -> CGPoint {
        let inset = diameter / 2 + floatingEdgeInset
        return CGPoint(
            x: min(max(inset, point.x), max(inset, size.width - inset)),
            y: min(max(inset, point.y), max(inset, size.height - inset))
        )
    }

    struct FloatingRelease: Equatable {
        var corner: CGPoint
        var dismisses: Bool = false
    }

    /// Independently expressed from OverlayMediaControllerNode's release rule:
    /// nearest corner below 500 pt/s; directional sectors with 30° tolerance
    /// for a flick. Reflect into one canonical corner instead of four copied
    /// branches. A slow drag never closes playback, and cancellation never does.
    static func floatingRelease(center: CGPoint, velocity: CGPoint, container: CGSize,
                                cancelled: Bool = false) -> FloatingRelease {
        var result = FloatingRelease(corner: CGPoint(
            x: center.x < container.width / 2 ? 0 : 1,
            y: center.y < container.height / 2 ? 0 : 1))
        guard !cancelled, hypot(velocity.x, velocity.y) >= 500 else { return result }

        let inwardX = result.corner.x == 0 ? velocity.x : -velocity.x
        let inwardY = result.corner.y == 0 ? velocity.y : -velocity.y
        let degrees = atan2(-inwardY, inwardX) * 180 / .pi
        let heading = degrees < 0 ? degrees + 360 : degrees
        if heading <= 60 || heading >= 330 {
            result.corner.x = 1 - result.corner.x
        } else if heading >= 210 && heading <= 300 {
            result.corner.y = 1 - result.corner.y
        } else if heading > 300 && heading < 330 {
            result.corner.x = 1 - result.corner.x
            result.corner.y = 1 - result.corner.y
        } else {
            result.dismisses = true
        }
        return result
    }
}

/// One decoder per conversation. Scrolling transfers presentation, not ownership.
@MainActor @Observable
final class AloCirclePlayback {
    private(set) var item: AloCircleQueueItem?
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var progress = 0.0
    private(set) var inlineVisible = false
    private(set) var surfaceOwner: AloCircleSurfaceOwner = .none
    private(set) var error: String?
    private(set) var focusRequest = 0
    var viewport = CGRect.zero
    @ObservationIgnored private var queue: [AloCircleQueueItem] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored let videoView = CircleVideoPlayerView.PlayerView()
    @ObservationIgnored private var isFloatingInteracting = false
    @ObservationIgnored private var lastInlineFrame: CGRect?
    @ObservationIgnored var floatingCorner = CGPoint(x: 1, y: 0)

    func setQueue(_ items: [AloCircleQueueItem]) { queue = items }

    func toggle(_ requested: AloCircleQueueItem, startsInline: Bool = false) {
        if item?.id == requested.id {
            if isPlaying { player?.pause(); isPlaying = false }
            else { player?.play(); isPlaying = true }
        } else {
            play(requested, startsInline: startsInline)
            if !startsInline { focusRequest += 1 }
        }
    }

    func play(_ requested: AloCircleQueueItem, startsInline: Bool = false) {
        stop()
        item = requested
        inlineVisible = startsInline
        surfaceOwner = startsInline ? .inline : .floating
        let currentGeneration = generation
        let prepared = AloSecureMediaStore.shared.makePlayer(url: requested.url)
        player = prepared
        videoView.playerLayer.videoGravity = .resizeAspectFill
        videoView.playerLayer.player = prepared
        videoView.isUserInteractionEnabled = false
        NotificationCenter.default.post(name: Notification.Name("aloMediaPlaybackDidStart"), object: requested.id)
        timeObserver = prepared.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.15, preferredTimescale: 600), queue: .main) { [weak self, weak prepared] time in
            MainActor.assumeIsolated {
                guard let self, self.generation == currentGeneration,
                      let total = prepared?.currentItem?.duration.seconds, total.isFinite, total > 0 else { return }
                self.progress = min(1, max(0, time.seconds / total))
            }
        }
        if let currentItem = prepared.currentItem {
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: currentItem, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == currentGeneration else { return }
                    self.playNext()
                }
            }
            failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: currentItem, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == currentGeneration else { return }
                    self.fail()
                }
            }
            statusObserver = currentItem.observe(\.status, options: [.new]) { [weak self] currentItem, _ in
                guard currentItem.status == .failed else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    self.fail()
                }
            }
        }
        prepared.play()
        isPlaying = true
    }

    func seek(_ fraction: Double) {
        guard let total = player?.currentItem?.duration.seconds, total.isFinite, total > 0 else { return }
        progress = min(1, max(0, fraction))
        player?.seek(to: CMTime(seconds: total * progress, preferredTimescale: 600),
                     toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                     toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600))
    }

    func updateVisibility(id: String, frame: CGRect) {
        guard item?.id == id else { return }
        lastInlineFrame = frame
        guard !isFloatingInteracting else { return }
        let visible = AloCirclePresentation.isVisible(frame, viewport: viewport, wasVisible: inlineVisible)
        guard inlineVisible != visible else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            inlineVisible = visible
        }
        transferSurface(to: visible ? .inline : .floating)
    }

    func leaveInline(id: String) {
        guard item?.id == id else { return }
        lastInlineFrame = nil
        inlineVisible = false
        transferSurface(to: .floating)
    }

    func stop() {
        generation = UUID()
        player?.pause()
        videoView.playerLayer.player = nil
        videoView.removeFromSuperview()
        isFloatingInteracting = false
        lastInlineFrame = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        statusObserver?.invalidate()
        statusObserver = nil
        timeObserver = nil
        endObserver = nil
        failureObserver = nil
        player = nil
        item = nil
        progress = 0
        isPlaying = false
        inlineVisible = false
        surfaceOwner = .none
        error = nil
    }

    private func transferSurface(to destination: AloCircleSurfaceOwner) {
        guard surfaceOwner != destination else { return }
        surfaceOwner = destination
    }

    func attachVideo(to host: UIView, owner: AloCircleSurfaceOwner) {
        guard item != nil, surfaceOwner == owner else {
            detachVideo(from: host)
            return
        }
        // addSubview atomically reparents the SAME view. A late dismantle of
        // the old SwiftUI host cannot clear the new host's player or surface.
        if videoView.superview !== host { host.addSubview(videoView) }
        videoView.frame = host.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func detachVideo(from host: UIView) {
        if videoView.superview === host { videoView.removeFromSuperview() }
    }

    func beginFloatingInteraction() { isFloatingInteracting = true }

    func endFloatingInteraction() {
        isFloatingInteracting = false
        if let id = item?.id, let frame = lastInlineFrame { updateVisibility(id: id, frame: frame) }
    }

    private func fail() {
        player?.pause()
        isPlaying = false
        error = "Не удалось воспроизвести кружок"
    }

    private func playNext() {
        guard let id = item?.id, let index = queue.firstIndex(where: { $0.id == id }),
              queue.indices.contains(index + 1) else { stop(); return }
        play(queue[index + 1])
    }
}

private struct AloCirclePlaybackKey: EnvironmentKey {
    static let defaultValue: AloCirclePlayback? = nil
}
extension EnvironmentValues {
    var aloCirclePlayback: AloCirclePlayback? {
        get { self[AloCirclePlaybackKey.self] }
        set { self[AloCirclePlaybackKey.self] = newValue }
    }
}

struct AloCirclePlayerSurface: View {
    let playback: AloCirclePlayback
    let accent: Color
    private var accessibility = AloVisualAccessibility()

    init(playback: AloCirclePlayback, accent: Color) {
        self.playback = playback
        self.accent = accent
    }

    var body: some View {
        ZStack {
            Color.black
            AloCircleVideoHost(playback: playback, owner: .inline, active: playback.surfaceOwner == .inline)
            Circle().stroke(.white.opacity(0.25), lineWidth: 2).padding(2)
            AloCircleProgressRing(playback: playback, accent: accent)
            if !playback.isPlaying {
                Image(systemName: playback.error == nil ? "play.fill" : "exclamationmark")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 52, height: 52).background(.black.opacity(0.35), in: Circle())
                    .transition(accessibility.reduceMotion ? .opacity : .scale(scale: 0.88).combined(with: .opacity))
            }
        }
        .clipShape(Circle())
        .animation(
            accessibility.reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.28, dampingFraction: 0.9),
            value: playback.isPlaying
        )
    }
}

/// Only this tiny shape observes the playback clock. The borrowed video host,
/// overlay controls and their layout do not need to update on every tick.
private struct AloCircleProgressRing: View {
    let playback: AloCirclePlayback
    let accent: Color
    private var accessibility = AloVisualAccessibility()

    init(playback: AloCirclePlayback, accent: Color) {
        self.playback = playback
        self.accent = accent
    }

    var body: some View {
        Circle().trim(from: 0, to: max(0.001, playback.progress))
            .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(-90)).padding(2)
            .animation(accessibility.reduceMotion ? nil : .linear(duration: 0.15), value: playback.progress)
            .accessibilityHidden(true)
    }
}

/// A small presentation host, with no decoder and no time observer of its own.
private struct AloCircleVideoHost: UIViewRepresentable {
    let playback: AloCirclePlayback
    let owner: AloCircleSurfaceOwner
    let active: Bool

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.isUserInteractionEnabled = false
        return host
    }
    func updateUIView(_ host: UIView, context: Context) {
        playback.attachVideo(to: host, owner: owner)
        context.coordinator.playback = playback
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ host: UIView, coordinator: Coordinator) {
        coordinator.playback?.detachVideo(from: host)
    }
    final class Coordinator { weak var playback: AloCirclePlayback? }
}

struct AloFloatingCircle: View {
    let playback: AloCirclePlayback
    let accent: Color
    let isPresented: Bool
    let onShowMessage: (Int) -> Void
    private var accessibility = AloVisualAccessibility()

    init(playback: AloCirclePlayback, accent: Color, isPresented: Bool = true,
         onShowMessage: @escaping (Int) -> Void) {
        self.playback = playback
        self.accent = accent
        self.isPresented = isPresented
        self.onShowMessage = onShowMessage
    }

    var body: some View {
        AloFloatingCircleHost(playback: playback, accent: UIColor(accent),
            active: isPresented && playback.surfaceOwner == .floating, progress: playback.progress,
            isPlaying: playback.isPlaying, reduceMotion: accessibility.reduceMotion,
            onShowMessage: onShowMessage)
            .allowsHitTesting(isPresented && playback.surfaceOwner == .floating)
    }
}

private struct AloFloatingCircleHost: UIViewRepresentable {
    let playback: AloCirclePlayback
    let accent: UIColor
    let active: Bool
    let progress: Double
    let isPlaying: Bool
    let reduceMotion: Bool
    let onShowMessage: (Int) -> Void

    func makeUIView(context: Context) -> AloFloatingCircleContainer { AloFloatingCircleContainer() }
    func updateUIView(_ view: AloFloatingCircleContainer, context: Context) {
        view.configure(playback: playback, accent: accent, active: active,
            progress: progress, isPlaying: isPlaying, reduceMotion: reduceMotion,
            onShowMessage: onShowMessage)
    }
    static func dismantleUIView(_ view: AloFloatingCircleContainer, coordinator: ()) { view.detach() }
}

/// UIKit moves only this layer while dragging. No SwiftUI layout, blur rebuild
/// or observation publication is needed on each finger movement.
final class AloFloatingCircleContainer: UIView {
    private let circle = UIView()
    private let videoHost = UIView()
    private let ring = CAShapeLayer()
    private let status = UIImageView()
    private weak var playback: AloCirclePlayback?
    private var onShowMessage: ((Int) -> Void)?
    private var active = false
    private var reduceMotion = false
    private var corner = CGPoint(x: 1, y: 0)
    private var dragOrigin: CGPoint?
    private var layoutSize = CGSize.zero
    private var animator: UIViewPropertyAnimator?
    private var diameter: CGFloat { AloCirclePresentation.floatingDiameter(boundingSize: bounds.size) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        circle.alpha = 0
        circle.layer.shadowColor = UIColor.black.cgColor
        circle.layer.shadowOpacity = 0.4
        circle.layer.shadowRadius = 12
        circle.layer.shadowOffset = CGSize(width: 0, height: 5)
        videoHost.clipsToBounds = true
        videoHost.backgroundColor = .black
        circle.addSubview(videoHost)
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 2.5
        ring.lineCap = .round
        ring.actions = ["strokeEnd": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
        circle.layer.addSublayer(ring)
        status.contentMode = .center
        status.tintColor = .white
        circle.addSubview(status)
        addSubview(circle)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        pan.maximumNumberOfTouches = 1
        circle.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: pan)
        circle.addGestureRecognizer(tap)
        circle.isAccessibilityElement = true
        circle.accessibilityIdentifier = "alo.circle.floating"
        circle.accessibilityLabel = "Плавающее видеосообщение"
        circle.accessibilityTraits = .button
        circle.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Показать сообщение", target: self, selector: #selector(showMessage)),
            UIAccessibilityCustomAction(name: "Остановить кружок", target: self, selector: #selector(stopPlayback))
        ]
    }

    required init?(coder: NSCoder) { nil }

    func configure(playback: AloCirclePlayback, accent: UIColor, active: Bool,
                   progress: Double, isPlaying: Bool, reduceMotion: Bool,
                   onShowMessage: @escaping (Int) -> Void) {
        if self.playback !== playback { corner = playback.floatingCorner }
        self.playback = playback
        self.reduceMotion = reduceMotion
        self.onShowMessage = onShowMessage
        ring.strokeColor = accent.cgColor
        updateProgress(progress, active: active, reduceMotion: reduceMotion)
        status.image = isPlaying ? nil : UIImage(systemName: playback.error == nil ? "play.fill" : "exclamationmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .medium))
        if active { playback.attachVideo(to: videoHost, owner: .floating) }
        else { playback.detachVideo(from: videoHost) }
        guard self.active != active else { return }
        self.active = active
        circle.accessibilityElementsHidden = !active
        stopAnimationAtPresentationPosition()
        if active {
            corner = playback.floatingCorner
            circle.center = dockedCenter()
            circle.alpha = 0
            circle.transform = reduceMotion ? .identity : CGAffineTransform(scaleX: 0.88, y: 0.88)
        } else {
            dragOrigin = nil
            playback.endFloatingInteraction()
        }
        UIView.animate(withDuration: reduceMotion ? 0.12 : 0.22, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            self.circle.alpha = active ? 1 : 0
            self.circle.transform = active || reduceMotion ? .identity : CGAffineTransform(scaleX: 0.88, y: 0.88)
        }
    }

    private func updateProgress(_ progress: Double, active: Bool, reduceMotion: Bool) {
        let next = CGFloat(max(0.001, min(1, progress)))
        guard ring.strokeEnd != next else { return }
        let previous = ring.presentation()?.strokeEnd ?? ring.strokeEnd
        ring.removeAnimation(forKey: "playbackProgress")
        ring.strokeEnd = next // Model value is always authoritative for seeking.
        guard active, !reduceMotion, next >= previous, next - previous < 0.1 else { return }
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = previous
        animation.toValue = next
        animation.duration = 0.15
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.add(animation, forKey: "playbackProgress")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != layoutSize else { return }
        layoutSize = bounds.size
        circle.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        videoHost.frame = circle.bounds
        videoHost.layer.cornerRadius = diameter / 2
        status.frame = circle.bounds
        ring.frame = circle.bounds
        ring.path = UIBezierPath(arcCenter: CGPoint(x: diameter / 2, y: diameter / 2),
            radius: diameter / 2 - 3, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: true).cgPath
        circle.layer.shadowPath = UIBezierPath(ovalIn: circle.bounds).cgPath
        if dragOrigin == nil {
            stopAnimationAtPresentationPosition()
            circle.center = dockedCenter()
        }
    }

    /// The transparent full-screen host NEVER captures taps on the header,
    /// composer or message history. Only the actual visible circle is hit-testable.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard active, !isHidden, alpha > 0.01 else { return nil }
        let local = circle.convert(point, from: self)
        guard hypot(local.x - circle.bounds.midX, local.y - circle.bounds.midY) <= diameter / 2 else { return nil }
        return circle.hitTest(local, with: event)
    }

    private func dockedCenter() -> CGPoint {
        AloCirclePresentation.bounded(CGPoint(x: corner.x * bounds.width, y: corner.y * bounds.height),
            size: bounds.size, diameter: diameter)
    }

    private func stopAnimationAtPresentationPosition() {
        let position = circle.layer.presentation()?.position ?? circle.center
        animator?.stopAnimation(true)
        animator = nil
        circle.layer.removeAllAnimations()
        circle.center = position
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            stopAnimationAtPresentationPosition()
            circle.transform = .identity
            playback?.beginFloatingInteraction()
            dragOrigin = circle.center
        case .changed:
            guard let origin = dragOrigin else { return }
            let translation = pan.translation(in: self)
            // Exactly 1:1, in the stationary container's coordinates. Clamping
            // here previously fought the finger and made dismissing impossible.
            circle.center = CGPoint(x: origin.x + translation.x, y: origin.y + translation.y)
        case .ended, .cancelled:
            guard dragOrigin != nil else { return }
            dragOrigin = nil
            let velocity = pan.state == .ended ? pan.velocity(in: self) : .zero
            let release = AloCirclePresentation.floatingRelease(center: circle.center, velocity: velocity,
                container: bounds.size, cancelled: pan.state == .cancelled)
            if release.dismisses {
                let id = playback?.item?.id
                let targetX = release.corner.x == 0 ? -diameter : bounds.width + diameter
                animate(to: CGPoint(x: targetX, y: circle.center.y), velocity: velocity) { [weak self] in
                    guard let self, self.playback?.item?.id == id else { return }
                    self.playback?.stop()
                }
            } else {
                corner = release.corner
                playback?.floatingCorner = corner
                let id = playback?.item?.id
                // Keep surface ownership stable until settling ends. A history
                // measurement must not reparent the video halfway through a drag.
                animate(to: dockedCenter(), velocity: velocity) { [weak self] in
                    guard let self, self.playback?.item?.id == id else { return }
                    self.playback?.endFloatingInteraction()
                }
            }
        default: break
        }
    }

    private func animate(to target: CGPoint, velocity: CGPoint, completion: (() -> Void)? = nil) {
        if reduceMotion { circle.center = target; completion?(); return }
        let delta = CGPoint(x: target.x - circle.center.x, y: target.y - circle.center.y)
        func relative(_ speed: CGFloat, _ distance: CGFloat) -> CGFloat {
            abs(distance) > 1 ? min(8, max(-8, speed / distance)) : 0
        }
        let timing = UISpringTimingParameters(dampingRatio: 0.88,
            initialVelocity: CGVector(dx: relative(velocity.x, delta.x), dy: relative(velocity.y, delta.y)))
        let animation = UIViewPropertyAnimator(duration: 0.3, timingParameters: timing)
        animation.addAnimations { self.circle.center = target }
        animation.addCompletion { [weak self] position in
            self?.animator = nil
            if position == .end { completion?() }
        }
        animator = animation
        animation.startAnimation()
    }

    @objc private func tapped() { _ = showMessage() }
    @objc private func showMessage() -> Bool {
        guard let id = playback?.item?.messageID else { return false }
        onShowMessage?(id)
        return true
    }
    @objc private func stopPlayback() -> Bool { playback?.stop(); return true }
    func detach() {
        animator?.stopAnimation(true)
        playback?.detachVideo(from: videoHost)
        playback?.endFloatingInteraction()
    }
}

struct AloCirclePlaybackBar: View {
    let playback: AloCirclePlayback
    let onShowMessage: (Int) -> Void
    private var accessibility = AloVisualAccessibility()
    init(playback: AloCirclePlayback, onShowMessage: @escaping (Int) -> Void) {
        self.playback = playback
        self.onShowMessage = onShowMessage
    }
    var body: some View {
        if let item = playback.item {
            HStack(spacing: 0) {
                Button { playback.toggle(item) } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
.contentTransition(.symbolEffect(.replace.downUp))
.animation(.spring(response: 0.26, dampingFraction: 0.8), value: playback.isPlaying)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.accessibilityLabel(playback.isPlaying ? "Приостановить кружок" : "Продолжить кружок")
                Button { onShowMessage(item.messageID) } label: {
                    VStack(spacing: 1) {
                        Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(playback.error ?? "Видеосообщение").font(.system(size: 11)).foregroundStyle(AloTheme.muted)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                Button {
                    withAnimation(accessibility.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 1)) {
                        playback.stop()
                    }
                } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Остановить кружок")
                    .accessibilityIdentifier("alo.circle.close")
            }
            .foregroundStyle(AloTheme.text)
            .modifier(AloChatPanelGlass(radius: 18, role: .control))
            .buttonStyle(AloControlPressStyle())
            .aloChatSwipeControl()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("alo.circle.player-bar")
        }
    }
}
