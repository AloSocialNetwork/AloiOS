import SwiftUI
import AVFoundation
import Combine

enum AloCircleRecordingLayout {
    static func diameter(viewport: CGSize, topChrome: CGFloat, bottomChrome: CGFloat) -> CGFloat {
        let side = min(viewport.width, viewport.height)
        let reference = side <= 320 ? CGFloat(216) : min(404, side - 24)
        // A keyboard/large accessibility composer can shrink the free area.
        return max(1, min(reference, max(1, viewport.height - topChrome - bottomChrome - 96)))
    }

    static func centerY(viewport: CGSize, diameter: CGFloat, topChrome: CGFloat, bottomChrome: CGFloat) -> CGFloat {
        let top = max(topChrome + diameter / 2 + 12, diameter / 2 + 61)
        let bottom = max(top, viewport.height - bottomChrome - diameter / 2 - 84)
        return min(bottom, max(top, viewport.height / 3 - 20))
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
    // lock at 110 pt; release intent is evaluated separately below.
    static let cancelDistance: CGFloat = 150
    static let lockDistance: CGFloat = 110

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

struct AloRecordingTimer: View {
    let startedAt: Date
    let ready: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = ready ? max(0, Int(context.date.timeIntervalSince(startedAt))) : 0
            HStack(spacing: 6) {
                Circle().fill(.red)
                    .frame(width: 6, height: 6)
                    .opacity(!reduceMotion && seconds.isMultiple(of: 2) ? 0.45 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: seconds)
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 15, weight: .regular)).monospacedDigit()
                    .foregroundStyle(AloTheme.text)
            }
            .fixedSize()
        }
        .accessibilityLabel(ready ? "Идёт запись" : "Подготовка записи")
    }
}

/// A stationary, tappable lock target; only its contents track vertical intent.
struct AloRecordingLock: View {
    let progress: CGFloat
    let onLock: () -> Void

    var body: some View {
        Button(action: onLock) {
            VStack(spacing: 10) {
                Image(systemName: progress > 0.85 ? "lock.fill" : "lock.open")
                    .font(.system(size: 16, weight: .medium))
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(1 - progress)
                    .offset(y: -progress * 8)
            }
            .foregroundStyle(progress > 0.6 ? AloTheme.accent : AloTheme.text)
            .frame(width: 44, height: 72)
            .modifier(AloChatGlass())
        }
        .buttonStyle(AloChatPressStyle())
        .accessibilityLabel("Зафиксировать запись")
        .accessibilityIdentifier("alo.recording.lock")
    }
}

struct AloRecordingOrb: View {
    let symbol: String
    let color: Color
    let level: CGFloat
    let cancelProgress: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18))
                .scaleEffect(reduceMotion ? 1 : 1 + min(1, max(0, level)) * (50 / 110))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
            Circle().fill(color)
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
        }
        .frame(width: 110, height: 110)
        .scaleEffect(reduceMotion ? 1 : 1 - cancelProgress * 0.5)
        .shadow(color: color.opacity(0.18), radius: 10, y: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
