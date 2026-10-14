import SwiftUI
import UIKit
import AVFoundation
import Combine
import AVKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - Zoomable image

/// A photo that can be pinched, panned and double-tapped, the way every full-screen viewer should behave.
/// `zoomScale == 1` is the fitted image; at that scale the page can still be swiped away.
struct AloZoomableImage: UIViewRepresentable {
    let image: UIImage
    var onZoomChanged: (Bool) -> Void = { _ in }
    var onSingleTap: () -> Void = {}
    var dismiss: AloViewerDismissDrag? = nil

    func makeUIView(context: Context) -> AloZoomScrollView {
        let view = AloZoomScrollView()
        apply(to: view)
        view.setImage(image)
        return view
    }

    func updateUIView(_ view: AloZoomScrollView, context: Context) {
        apply(to: view)
        if view.imageView.image !== image { view.setImage(image) }
    }

    private func apply(to view: AloZoomScrollView) {
        view.onZoomChanged = onZoomChanged
        view.onSingleTap = onSingleTap
        view.dismissDrag = dismiss
    }
}

/// Vertical drag that closes a full-screen viewer (photo or video), as in Telegram.
struct AloViewerDismissDrag {
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
}

final class AloZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onZoomChanged: (Bool) -> Void = { _ in }
    var onSingleTap: () -> Void = {}
    var dismissDrag: AloViewerDismissDrag?
    private var laidOutSize = CGSize.zero
    private lazy var dismissPan = AloVerticalPanGestureRecognizer(target: self, action: #selector(dismissPanned(_:)))
    private var zoomed = false { didSet { if oldValue != zoomed { onZoomChanged(zoomed) } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        isDirectionalLockEnabled = true
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        // Zoomed photos may draw under the status bar and home indicator instead of stopping at the safe area.
        clipsToBounds = false
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        addGestureRecognizer(single)
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.canStart = { [weak self] in
            guard let self else { return false }
            return self.dismissDrag != nil && self.zoomScale <= 1.01
        }
        addGestureRecognizer(dismissPan)
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = "Фото. Дважды нажмите, чтобы приблизить"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        imageView.image = image
        laidOutSize = .zero
        zoomScale = 1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        if laidOutSize != bounds.size {
            laidOutSize = bounds.size
            zoomScale = 1
            let fit = min(bounds.width / max(1, image.size.width), bounds.height / max(1, image.size.height))
            // Never a fraction of a point wider than the page: that made the photo itself scrollable
            // sideways, so it jiggled under the finger and the page swipe never happened.
            let width = min(bounds.width, (image.size.width * fit).rounded(.down))
            let height = min(bounds.height, (image.size.height * fit).rounded(.down))
            imageView.frame = CGRect(x: 0, y: 0, width: width, height: height)
            contentSize = imageView.frame.size
            zoomed = false
            updatePanning()
        }
        centerContent()
    }

    private func centerContent() {
        let insetX = max((bounds.width - contentSize.width) / 2, 0)
        let insetY = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        zoomed = zoomScale > 1.02
        updatePanning()
    }

    /// Panning belongs to the zoomed photo only. At the fitted size horizontal drags go to the
    /// page swipe and vertical ones to the close gesture.
    private func updatePanning() {
        panGestureRecognizer.isEnabled = zoomScale > 1.01
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale < 1.05 { setZoomScale(1, animated: true) }
        zoomed = zoomScale > 1.02
        updatePanning()
    }

    @objc private func singleTapped() { onSingleTap() }

    @objc private func dismissPanned(_ pan: UIPanGestureRecognizer) {
        guard let dismissDrag else { return }
        let dy = pan.translation(in: self).y
        switch pan.state {
        case .changed: dismissDrag.changed(dy)
        case .ended, .cancelled, .failed: dismissDrag.ended(dy, pan.velocity(in: self).y)
        default: break
        }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.05 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let target: CGFloat = 2.6
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}

/// The close drag of a full-screen viewer. It claims only mostly vertical drags on the fitted photo
/// and fails on the first sideways movement, before it can begin, so the page swipe gets the touch.
/// (A `gestureRecognizerShouldBegin` override on the scroll view is not enough: UIKit asks the
/// touched image view instead, and the close drag then swallowed horizontal swipes, shaking the photo.)
final class AloVerticalPanGestureRecognizer: UIPanGestureRecognizer {
    var canStart: () -> Bool = { true }
    private var origin: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard canStart() else { state = .failed; return }
        if origin == nil { origin = touches.first?.location(in: nil) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let origin, let point = touches.first?.location(in: nil) {
            let dx = abs(point.x - origin.x), dy = abs(point.y - origin.y)
            if max(dx, dy) > 4, dy <= dx * 1.2 {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        origin = nil
    }
}

/// One page of a photo gallery: loads, zooms, and reports whether it is zoomed.
struct AloZoomableImagePage<Placeholder: View>: View {
    let url: URL?
    let isActive: Bool
    var onZoomChanged: (Bool) -> Void = { _ in }
    var onSingleTap: () -> Void = {}
    var dismiss: AloViewerDismissDrag? = nil
    @ViewBuilder let placeholder: (Bool) -> Placeholder

    var body: some View {
        AloAsyncUIImage(url: url) { phase in
            switch phase {
            case .success(let image):
                AloZoomableImage(image: image, onZoomChanged: { if isActive { onZoomChanged($0) } }, onSingleTap: onSingleTap,
                                 dismiss: dismiss)
                    .ignoresSafeArea()
            case .loading:
                placeholder(false)
            case .failure:
                placeholder(true)
            }
        }
    }
}

/// Shared close-by-drag state for full-screen viewers: offset, backdrop fade and the decision.
struct AloViewerDismissState {
    var offset: CGFloat = 0
    var progress: Double { min(1, Double(abs(offset)) / 320) }

    /// Returns true when the drag should close the viewer.
    static func shouldDismiss(translation: CGFloat, velocity: CGFloat) -> Bool {
        abs(translation) > 120 || abs(velocity) > 900
    }
}

struct AloViewerDismissModifier: ViewModifier {
    @Binding var state: AloViewerDismissState

    func body(content: Content) -> some View {
        content
            .offset(y: state.offset)
            .scaleEffect(1 - 0.12 * state.progress)
    }
}

// MARK: - Video player

/// Playback state for one full-screen video. The periodic observer runs at 4 Hz, not per frame.
@MainActor
final class AloVideoPlayerModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    let player: AVPlayer
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var isPictureInPictureActive = false
    private var pipController: AVPictureInPictureController?
    private var pipPossibleObservation: NSKeyValueObservation?
    /// The viewer closed while the video was floating; release everything when it stops.
    private var detachedForPictureInPicture = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var isEnded = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var rate: Float = 1
    @Published private(set) var isMuted = false

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var durationTask: Task<Void, Never>?

    init(player: AVPlayer) {
        self.player = player
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                self?.isPlaying = status == .playing
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        }
        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isEnded = true }
            }
            durationTask = Task { [weak self] in
                let seconds = (try? await item.asset.load(.duration).seconds) ?? 0
                await MainActor.run { if seconds.isFinite, seconds > 0 { self?.duration = seconds } }
            }
        }
    }

    var isScrubbing = false

    func play() {
        if isEnded { seek(to: 0); isEnded = false }
        player.playImmediately(atRate: rate)
    }

    func pause() { player.pause() }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration > 0 ? duration : seconds)
        currentTime = clamped
        isEnded = false
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func setRate(_ value: Float) {
        rate = value
        if isPlaying { player.rate = value }
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    // MARK: Picture in Picture

    func attach(layer: AVPlayerLayer) {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // PiP is only offered with a playback audio session. Never take the session from a call.
        let session = AVAudioSession.sharedInstance()
        if session.mode != .voiceChat && session.mode != .videoChat {
            try? session.setCategory(.playback, mode: .moviePlayback)
        }
        guard let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.delegate = self
        pipController = controller
        pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPictureInPicturePossible = possible }
        }
    }

    func startPictureInPicture() {
        try? AVAudioSession.sharedInstance().setActive(true)
        if !isPlaying { play() }
        pipController?.startPictureInPicture()
    }

    /// Called when the viewer goes away. A floating video keeps playing until the user closes it.
    func viewerDidClose() {
        if isPictureInPictureActive {
            detachedForPictureInPicture = true
            AloPictureInPictureKeeper.keep(self)
        } else {
            tearDown()
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isPictureInPictureActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPictureInPictureActive = false
            if self.detachedForPictureInPicture {
                self.tearDown()
                AloPictureInPictureKeeper.release(self)
            }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    func tearDown() {
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        pipController?.delegate = nil
        pipController = nil
        durationTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

/// Keeps a floating (PiP) video alive after its viewer was closed.
@MainActor
enum AloPictureInPictureKeeper {
    private static var kept: [AloVideoPlayerModel] = []
    static func keep(_ model: AloVideoPlayerModel) { if !kept.contains(where: { $0 === model }) { kept.append(model) } }
    static func release(_ model: AloVideoPlayerModel) { kept.removeAll { $0 === model } }
}

struct AloPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var onLayer: (AVPlayerLayer) -> Void = { _ in }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        view.backgroundColor = .black
        onLayer(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Full-screen video: tap to show or hide controls, double-tap the sides to skip 10 s, drag the
/// bar to scrub, pick a speed, mute. Controls hide by themselves while playing.
struct AloVideoPlayerView: View {
    @StateObject private var model: AloVideoPlayerModel
    var autoplay = true
    var dismiss: AloViewerDismissDrag?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double?
    /// The axis of the current drag, decided once: vertical closes the viewer, horizontal belongs to the pager.
    @State private var dragIsVertical: Bool?
    @State private var skipFlash: (side: Int, id: Int)?

    init(player: AVPlayer, autoplay: Bool = true, dismiss: AloViewerDismissDrag? = nil) {
        _model = StateObject(wrappedValue: AloVideoPlayerModel(player: player))
        self.autoplay = autoplay
        self.dismiss = dismiss
    }

    var body: some View {
        ZStack {
            AloPlayerLayerView(player: model.player, onLayer: { model.attach(layer: $0) })
                .ignoresSafeArea()
            // Tap zones: single tap toggles controls, double tap on a side skips.
            HStack(spacing: 0) {
                tapZone(side: -1)
                tapZone(side: 1)
            }
            .ignoresSafeArea()

            if let flash = skipFlash {
                Label(flash.side < 0 ? "−10 с" : "+10 с", systemImage: flash.side < 0 ? "gobackward.10" : "goforward.10")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 36)
                    .modifier(AloChatGlass(interactive: false, role: .chrome))
                    .frame(maxWidth: .infinity, alignment: flash.side < 0 ? .leading : .trailing)
                    .padding(.horizontal, 40)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .id(flash.id)
                    .allowsHitTesting(false)
            }

            if model.isBuffering && !model.isEnded {
                AloVideoSpinner().allowsHitTesting(false)
            }

            if showsControls {
                controls.transition(.opacity)
            }
        }
        .background(Color.black)
        .simultaneousGesture(dismissGesture)
        .task {
            if autoplay { model.play() }
            scheduleHide()
        }
        .onChange(of: model.isPlaying) { _, _ in scheduleHide() }
        .onDisappear {
            hideTask?.cancel()
            model.viewerDidClose()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.video.player")
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                if dragIsVertical == nil {
                    dragIsVertical = abs(value.translation.height) > abs(value.translation.width) * 1.2
                }
                guard let dismiss, scrubValue == nil, dragIsVertical == true else { return }
                dismiss.changed(value.translation.height)
            }
            .onEnded { value in
                defer { dragIsVertical = nil }
                guard let dismiss, scrubValue == nil, dragIsVertical == true else { return }
                let velocity = (value.predictedEndTranslation.height - value.translation.height) * 4
                dismiss.ended(value.translation.height, velocity)
            }
    }

    private func tapZone(side: Int) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.skip(by: Double(side) * 10)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { skipFlash = (side, (skipFlash?.id ?? 0) + 1) }
                Task {
                    try? await Task.sleep(for: .milliseconds(650))
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { skipFlash = nil }
                }
                scheduleHide()
            }
            .onTapGesture {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsControls.toggle() }
                scheduleHide()
            }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Spacer()
            Button(action: { model.toggle(); scheduleHide() }) {
                Image(systemName: model.isEnded ? "arrow.counterclockwise" : (model.isPlaying ? "pause.fill" : "play.fill"))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .animation(.spring(response: 0.26, dampingFraction: 0.8), value: model.isPlaying)
                    .frame(width: 72, height: 72)
                    .modifier(AloChatGlass(interactive: false, role: .chrome))
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityLabel(model.isPlaying ? "Пауза" : "Воспроизвести")
            .accessibilityIdentifier("alo.video.play")
            Spacer()
            bottomBar
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            AloVideoScrubber(value: displayedTime, duration: model.duration,
                onScrub: { scrubValue = $0; model.isScrubbing = true },
                onEnd: { value in
                    model.seek(to: value)
                    scrubValue = nil
                    model.isScrubbing = false
                    scheduleHide()
                })
            HStack(spacing: 14) {
                Text(format(displayedTime)).accessibilityIdentifier("alo.video.elapsed")
                Spacer()
                Menu {
                    ForEach([Float(0.5), 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Button { model.setRate(speed); scheduleHide() } label: {
                            if model.rate == speed { Label(speedLabel(speed), systemImage: "checkmark") } else { Text(speedLabel(speed)) }
                        }
                    }
                } label: {
                    Text(speedLabel(model.rate)).frame(minWidth: 44, minHeight: 32)
                }
                .accessibilityLabel("Скорость воспроизведения")
                if model.isPictureInPicturePossible {
                    Button { model.startPictureInPicture() } label: {
                        Image(systemName: "pip.enter").frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Картинка в картинке")
                    .accessibilityIdentifier("alo.video.pip")
                }
                Button { model.toggleMute(); scheduleHide() } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(model.isMuted ? "Включить звук" : "Выключить звук")
                Text("−" + format(max(0, model.duration - displayedTime))).accessibilityIdentifier("alo.video.remaining")
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .modifier(AloChatPanelGlass(radius: 24, role: .chrome))
        .padding(.horizontal, 12)
        .padding(.bottom, 48)
    }

    private var displayedTime: Double { scrubValue ?? model.currentTime }

    private func speedLabel(_ speed: Float) -> String {
        speed == floor(speed) ? "\(Int(speed))×" : String(format: "%g×", speed)
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded()))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard model.isPlaying, scrubValue == nil else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showsControls = false }
        }
    }
}

struct AloVideoScrubber: View {
    let value: Double
    let duration: Double
    let onScrub: (Double) -> Void
    let onEnd: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let progress = duration > 0 ? min(1, max(0, value / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28)).frame(height: dragging ? 8 : 4)
                Capsule().fill(Color.white).frame(width: max(0, proxy.size.width * progress), height: dragging ? 8 : 4)
                Circle().fill(Color.white)
                    .frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12)
                    .offset(x: max(0, proxy.size.width * progress - (dragging ? 9 : 6)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    onScrub(duration * min(1, max(0, drag.location.x / max(1, proxy.size.width))))
                }
                .onEnded { drag in
                    dragging = false
                    onEnd(duration * min(1, max(0, drag.location.x / max(1, proxy.size.width))))
                })
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: dragging)
        }
        .frame(height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Перемотка")
        .accessibilityValue("\(Int(value)) из \(Int(duration)) секунд")
        .accessibilityAdjustableAction { direction in
            onEnd(value + (direction == .increment ? 10 : -10))
        }
        .accessibilityIdentifier("alo.video.scrubber")
    }
}

struct AloVideoSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let angle = reduceMotion ? 0 : (context.date.timeIntervalSinceReferenceDate * 360).truncatingRemainder(dividingBy: 360)
            Circle().trim(from: 0, to: 0.28)
                .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 34, height: 34)
                .rotationEffect(.degrees(angle))
                .frame(width: 64, height: 64)
                .background(Color.black.opacity(0.42), in: Circle())
        }
    }
}
