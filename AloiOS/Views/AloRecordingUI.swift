import SwiftUI
import AVFoundation
import Combine

enum AloCircleRecordingLayout {
    /// Telegram iOS VideoMessageCameraScreen: `min(369, width − 24)`; a short free area (keyboard, large text) shrinks it.
    static func diameter(viewport: CGSize, topChrome: CGFloat, bottomChrome: CGFloat) -> CGFloat {
        let reference = min(369, viewport.width - 24)
        return max(1, min(reference, max(1, viewport.height - topChrome - bottomChrome - 96)))
    }

    /// Telegram puts the circle's top at `max(status bar, 40 % of the height − side / 2)`: centred at 40 % of the
    /// screen, clear of the header above and of the flip button and composer below.
    static func centerY(viewport: CGSize, diameter: CGFloat, topChrome: CGFloat, bottomChrome: CGFloat) -> CGFloat {
        let top = max(topChrome + diameter / 2 + 12, diameter / 2 + 61)
        let bottom = max(top, viewport.height - bottomChrome - diameter / 2 - 84)
        return min(bottom, max(top, viewport.height * 0.4))
    }

    /// The flip and flash buttons: 40 pt glass circles 8 pt above the input panel, 8 pt in from the left
    /// (26 pt on phones without a home indicator), 11 pt apart.
    static let buttonSize: CGFloat = 40
    static func buttonSideInset(safeBottom: CGFloat) -> CGFloat { safeBottom <= 32 ? 26 : 8 }
}

/// Telegram's backdrop behind a circle being recorded: the chat blurred (dark or light with the theme), no dimming,
/// fading in over 0.4 s. With Reduce Transparency it is the plain page colour.
struct AloCircleRecordingBackdrop: UIViewRepresentable {
    var dark: Bool
    var opaque: Bool

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        view.isUserInteractionEnabled = false
        update(view)
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) { update(view) }

    private func update(_ view: UIVisualEffectView) {
        view.effect = opaque ? nil : UIBlurEffect(style: dark ? .dark : .light)
        view.backgroundColor = opaque ? (dark ? .black : .white) : .clear
    }
}

/// Own playback completion so a finished draft returns to Play without a timer.
@MainActor
final class AloRecordedAudioPreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?
    private var filePlayer: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var revision = 0
    private var isPreparing = false

    func toggle(attachment: AloLocalAttachment) async throws {
        guard let url = attachment.localPlaybackURL else {
            try toggle(data: attachment.data)
            return
        }
        guard !isPreparing else { return }
        if filePlayer == nil {
            isPreparing = true
            let currentRevision = revision
            defer { if currentRevision == revision { isPreparing = false } }
            let asset = AloSecureMediaStore.shared.makeAsset(url: url)
            let playable = try await asset.load(.isPlayable)
            guard currentRevision == revision, !Task.isCancelled else { return }
            guard playable else { throw CocoaError(.fileReadCorruptFile) }
            let prepared = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            filePlayer = prepared
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: prepared.currentItem, queue: .main
            ) { [weak self, weak prepared] _ in
                Task { @MainActor [weak self, weak prepared] in
                    guard let self, let prepared, self.filePlayer === prepared else { return }
                    prepared.seek(to: .zero)
                    self.isPlaying = false
                }
            }
        }
        guard let filePlayer else { return }
        if isPlaying { filePlayer.pause() } else { filePlayer.play() }
        isPlaying.toggle()
    }

    func toggle(data: Data) throws {
        if player == nil {
            let audio = try AVAudioPlayer(data: data)
            audio.delegate = self
            audio.prepareToPlay()
            player = audio
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            isPlaying = player.play()
        }
    }

    /// How much of the draft has played (0…1), for the preview's waveform.
    var progress: Double {
        if let filePlayer, let item = filePlayer.currentItem {
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else { return 0 }
            return min(1, max(0, filePlayer.currentTime().seconds / duration))
        }
        if let player, player.duration > 0 { return min(1, max(0, player.currentTime / player.duration)) }
        return 0
    }

    func stop() {
        revision += 1
        isPreparing = false
        filePlayer?.pause()
        filePlayer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        isPlaying = false
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
            current.currentTime = 0
            self.isPlaying = false
        }
    }
}

/// Touch-space progress is independent of the animated recording decoration.
struct AloRecordingDrag: Equatable {
    var translation: CGSize = .zero
    // TGModernConversationInputMicButton: drag cancellation at 150 pt,
    // lockness = dy / 105 pt; release intent is evaluated separately below.
    static let cancelDistance: CGFloat = 150
    static let lockDistance: CGFloat = 105

    var cancelProgress: CGFloat { min(1, max(0, -translation.width / Self.cancelDistance)) }
    var lockProgress: CGFloat { min(1, max(0, -translation.height / Self.lockDistance)) }
    var shouldLock: Bool {
        -translation.height > Self.lockDistance && -translation.height > abs(translation.width) * 1.2
    }
    var shouldCancel: Bool { -translation.width > Self.cancelDistance && !shouldLock }
    var offset: CGSize {
        CGSize(width: min(0, max(-Self.cancelDistance, translation.width)),
               height: min(0, max(-Self.lockDistance, translation.height)))
    }
    /// Telegram's inner circle: 1 → 0.4 over 300 pt to the left.
    var orbScale: CGFloat { max(0.4, min(1, 1 + min(0, translation.width) / 300)) }

    enum ReleaseIntent { case finish, cancel, lock }

    func releaseIntent(velocity: CGSize) -> ReleaseIntent {
        // Telegram resolves the dominant displacement before considering a
        // deliberate release/flick. A cancelled gesture never reaches Send.
        let horizontal = abs(translation.width) > abs(translation.height)
        if (horizontal && translation.width < -100) || velocity.width < -400 { return .cancel }
        if (!horizontal && translation.height < -60) || velocity.height < -400 { return .lock }
        return .finish
    }
}

/// Telegram iOS geometry of the voice recording panel and mic (TGModernConversationInputMicButton,
/// ChatTextInputPanelNode, ChatRecordingPreviewInputPanelNode).
enum AloRecordingMetrics {
    static let dotSize: CGFloat = 10
    static let dotX: CGFloat = 16
    static let timeX: CGFloat = 34
    static let dotColor = Color(red: 1, green: 0x2D / 255, blue: 0x55 / 255)
    static let innerCircle: CGFloat = 110
    static let outerCircle: CGFloat = 160
    static let lockSize = CGSize(width: 40, height: 72)
    /// Lock panel centre above the mic centre, and the pause button's after locking.
    static let lockLift: CGFloat = 122
    static let pauseLift: CGFloat = 102
}

/// "0:03,45": Telegram shows hundredths while recording.
enum AloRecordingClock {
    static func label(_ elapsed: TimeInterval) -> String {
        let value = max(0, elapsed)
        let seconds = Int(value)
        let hundredths = min(99, Int((value - Double(seconds)) * 100))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d,%02d", seconds / 3600, seconds / 60 % 60, seconds % 60, hundredths)
        }
        return String(format: "%d:%02d,%02d", seconds / 60, seconds % 60, hundredths)
    }

    /// Telegram's dot: opacity 1 → 1 → 0 over 0.5 s (key times 0, 0.4546, 0.9091), then back.
    static func dotOpacity(_ elapsed: TimeInterval) -> Double {
        let cycle = elapsed.truncatingRemainder(dividingBy: 1.0)
        let t = cycle < 0.5 ? cycle / 0.5 : (1.0 - cycle) / 0.5
        if t <= 0.4546 { return 1 }
        if t >= 0.9091 { return 0 }
        return 1 - (t - 0.4546) / (0.9091 - 0.4546)
    }
}

struct AloRecordingTimer: View {
    let startedAt: Date
    let ready: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !ready)) { context in
            let elapsed = ready ? max(0, context.date.timeIntervalSince(startedAt)) : 0
            HStack(spacing: AloRecordingMetrics.timeX - AloRecordingMetrics.dotX - AloRecordingMetrics.dotSize) {
                Circle().fill(AloRecordingMetrics.dotColor)
                    .frame(width: AloRecordingMetrics.dotSize, height: AloRecordingMetrics.dotSize)
                    .opacity(reduceMotion || !ready ? 1 : AloRecordingClock.dotOpacity(elapsed))
                Text(AloRecordingClock.label(elapsed))
                    .font(.system(size: 15, weight: .regular)).monospacedDigit()
                    .foregroundStyle(AloTheme.text)
            }
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ready ? "Идёт запись" : "Подготовка записи")
    }
}

/// Telegram's «‹ Slide to cancel»: centred, swaying 6 pt each second, following the finger left
/// after 8 pt and fading out before it reaches the timer. Once locked it becomes «Отмена».
struct AloRecordingCancelIndicator: View {
    let isLocked: Bool
    let ready: Bool
    let drag: AloRecordingDrag
    let accentColor: Color
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            content(width: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var translation: CGFloat { max(0, -drag.translation.width - 8) }
    /// The mic button and its gap, which the panel stops short of.
    private static let micInset: CGFloat = 52
    @State private var hintWidth: CGFloat = 130

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if isLocked {
            Button(action: onCancel) {
                Text("Отмена")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(accentColor)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloChatPressStyle())
            .accessibilityLabel("Удалить запись")
            .transition(.opacity.combined(with: .offset(y: 12)))
        } else {
            // Telegram centres the hint on the whole input row (under the mic too), follows the
            // finger at half its pace and fades it out as it nears the timer (alpha = (minX − 100) / 10).
            let shift: CGFloat = translation / 2
            let left: CGFloat = (width + Self.micInset - hintWidth) / 2 - shift
            hint(swaying: !reduceMotion && translation == 0 && width > 240)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { hintWidth = $0 }
                .offset(x: Self.micInset / 2 - shift)
                .opacity(Double(max(0, min(1, (left - 100) / 10))))
        }
    }

    private func hint(swaying: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !swaying)) { context in
            Button(action: onCancel) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text(ready ? "Влево — отмена" : "Подготовка…")
                        .font(.system(size: 14))
                }
                .foregroundStyle(AloTheme.muted)
                .lineLimit(1)
                .fixedSize()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(AloChatPressStyle())
            .offset(x: swaying ? Self.sway(context.date) : 0)
        }
        .accessibilityLabel("Отменить запись")
        .accessibilityHint("Также можно сдвинуть палец влево")
    }

    /// 0 → 6 pt in one second, ease-in-out, and back (CABasicAnimation autoreverses).
    private static func sway(_ date: Date) -> CGFloat {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2)
        let t = cycle < 1 ? cycle : 2 - cycle
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        return CGFloat(eased) * 6
    }
}

/// Telegram's lock panel above a held mic (40×72): as the finger rises it shrinks from the top
/// to 40 pt, the lock climbs 16 pt and the arrow fades away upwards. A tap locks too.
struct AloRecordingLock: View {
    let progress: CGFloat
    let onLock: () -> Void

    var body: some View {
        let size = AloRecordingMetrics.lockSize
        Button(action: onLock) {
            ZStack(alignment: .top) {
                Color.clear.frame(width: size.width, height: size.height)
                Color.clear
                    .frame(width: size.width, height: size.height - 32 * progress)
                    .modifier(AloChatGlass())
                    .offset(y: 40 * progress)
                Image(systemName: progress > 0.85 ? "lock.fill" : "lock")
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 24)
                    .offset(y: 8 + 24 * progress)
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: 12)
                    .opacity(Double(max(0, 1 - progress * 1.6)))
                    .offset(y: 46 + progress)
            }
            .foregroundStyle(progress > 0.6 ? AloTheme.accent : AloTheme.text)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloChatPressStyle())
        .accessibilityLabel("Зафиксировать запись")
        .accessibilityIdentifier("alo.recording.lock")
    }
}

/// After locking, Telegram turns the lock into a 40 pt pause button (two 5×14 bars) that stops
/// the recording into a preview.
struct AloRecordingPauseButton: View {
    let enabled: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1, style: .continuous).frame(width: 5, height: 14)
                RoundedRectangle(cornerRadius: 1, style: .continuous).frame(width: 5, height: 14)
            }
            .foregroundStyle(AloTheme.text)
            .frame(width: 40, height: 40)
            .modifier(AloChatGlass())
            .contentShape(Circle())
        }
        .buttonStyle(AloChatPressStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier("alo.recording.pause")
    }
}

/// Telegram's mic under the finger: a 110 pt accent circle with a 160 pt halo that breathes with
/// the voice (from 110/160 at silence), shrinking towards 0.4 as the finger slides to cancel.
struct AloRecordingOrb: View {
    let symbol: String
    let color: Color
    let level: CGFloat
    let cancelProgress: CGFloat
    var scale: CGFloat? = nil
    var hitTesting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var effectiveLevel: CGFloat {
        let value = min(1, max(0, level))
#if DEBUG
        // The screenshot fixture has no microphone: show a voice at half volume.
        if value == 0, UserDefaults.standard.string(forKey: "ALO_UI_VOICE_RECORDING") != nil { return 0.55 }
#endif
        return value
    }

    var body: some View {
        let minimum = AloRecordingMetrics.innerCircle / AloRecordingMetrics.outerCircle
        let level = effectiveLevel
        let inner = scale ?? (1 - cancelProgress * 0.5)
        ZStack {
            Circle().fill(color.opacity(0.2))
                .frame(width: AloRecordingMetrics.outerCircle, height: AloRecordingMetrics.outerCircle)
                .scaleEffect(reduceMotion ? minimum : minimum + level * (1 - minimum))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
            ZStack {
                Circle().fill(color)
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: AloRecordingMetrics.innerCircle, height: AloRecordingMetrics.innerCircle)
            .scaleEffect(reduceMotion ? 1 : inner)
        }
        .frame(width: AloRecordingMetrics.innerCircle, height: AloRecordingMetrics.innerCircle)
        .allowsHitTesting(hitTesting)
        .accessibilityHidden(!hitTesting)
    }
}

/// The backdrop owns the full viewport. Never scale it with a foreground card:
/// that exposes hard rectangular edges during transitions, especially over glass.
struct AloChatModalBackdrop: View {
    var darkness: Double = 0.28
    private var accessibility = AloVisualAccessibility()

    init(darkness: Double = 0.28) { self.darkness = darkness }

    var body: some View {
        AloBlackChatBackdrop(darkness: darkness,
            opaque: accessibility.reduceTransparency || accessibility.increasedContrast)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
