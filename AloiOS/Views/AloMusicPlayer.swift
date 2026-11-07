import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

// The app's «some media started» signal (declared privately in MessagesView.swift and AloCirclePlayback.swift).
private let aloMediaPlaybackDidStart = Notification.Name("aloMediaPlaybackDidStart")

/// Songs in chats, after Telegram (the same as the website, ~/alo/web/js/player.js): an audio file that is not a recorded
/// voice message is a track. Its bubble is a round play button with the title and performer (no seek line inside the
/// bubble); while it plays, an oval under the chat header holds «назад», play/pause, «далее», the speed and «закрыть»,
/// and the lock screen / headphones control it too. Tracks of the open chat play one after another.
struct AloMusicTrack: Identifiable, Equatable {
    let id: String
    let messageId: Int
    let url: URL
    let title: String
    let performer: String
    let duration: Double
}

enum AloMusicCatalog {
    private static let extensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "aiff", "aif", "alac"]

    /// The sender (web or app) marks a song with an audio mime type in the metadata; older ones are told by the extension.
    static func isMusic(_ attachment: AloMessageAttachment) -> Bool {
        let type = attachment.type.lowercased()
        guard type == "file" || type == "audio" else { return false }
        if attachment.name.lowercased().hasPrefix("voice") { return false }
        let mime = (attachment.metadata["mime"] ?? attachment.mediaEncryption["mime"] ?? "").lowercased()
        if mime.hasPrefix("audio/") { return true }
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        return extensions.contains(ext)
    }

    /// Title and performer from the tags the sender read, else «Исполнитель - Название.mp3».
    static func titles(_ attachment: AloMessageAttachment) -> (title: String, performer: String) {
        if let title = attachment.metadata["title"], !title.isEmpty {
            return (title, attachment.metadata["performer"] ?? "")
        }
        let base = (attachment.name as NSString).deletingPathExtension.ifBlank("Аудио")
        for separator in [" - ", " – ", " — "] {
            let parts = base.components(separatedBy: separator)
            if parts.count >= 2 { return (parts.dropFirst().joined(separator: " – "), parts[0]) }
        }
        return (base, "")
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds.rounded(.down) : 0))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
}

@MainActor
final class AloMusicPlayback: ObservableObject {
    static let shared = AloMusicPlayback()

    @Published private(set) var track: AloMusicTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var isWaiting = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 1
    @Published private(set) var queue: [AloMusicTrack] = []

    /// Tracks the open chat has drawn, by message: the queue is taken from here when one starts.
    private var known: [String: AloMusicTrack] = [:]
    private var scope = ""
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var mediaObserver: NSObjectProtocol?
    private static let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]

    private init() {
        // Another player (a voice message, a circle, a video) starting stops the song, as in Telegram.
        mediaObserver = NotificationCenter.default.addObserver(forName: aloMediaPlaybackDidStart, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? String) != "alo.music" else { return }
            Task { @MainActor in self?.pause() }
        }
        setUpRemoteCommands()
    }

    /// A chat was opened: its tracks start a new list (the song that plays keeps its own queue).
    func enter(scope: String) {
        guard scope != self.scope else { return }
        self.scope = scope
        known = [:]
    }

    func register(_ track: AloMusicTrack) {
        known[track.id] = track
        if let index = queue.firstIndex(where: { $0.id == track.id }) { queue[index] = track }
    }

    func isCurrent(_ id: String) -> Bool { track?.id == id }

    func toggle(_ tapped: AloMusicTrack) {
        if track?.id == tapped.id {
            isPlaying ? pause() : resume()
            return
        }
        known[tapped.id] = tapped
        queue = known.values.sorted { ($0.messageId, $0.id) < ($1.messageId, $1.id) }
        play(tapped)
    }

    func next() {
        guard let index = queue.firstIndex(where: { $0.id == track?.id }), index + 1 < queue.count else { return }
        play(queue[index + 1])
    }

    /// «Назад» in the first seconds goes to the previous track, later it starts this one again.
    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        guard let index = queue.firstIndex(where: { $0.id == track?.id }), index > 0 else { seek(to: 0); return }
        play(queue[index - 1])
    }

    var hasNext: Bool { (queue.firstIndex(where: { $0.id == track?.id }) ?? queue.count) + 1 < queue.count }
    var hasPrevious: Bool { (queue.firstIndex(where: { $0.id == track?.id }) ?? 0) > 0 || currentTime > 3 }

    func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
        if isPlaying { player?.rate = rate }
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, seconds)
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard let player else { return }
        NotificationCenter.default.post(name: aloMediaPlaybackDidStart, object: "alo.music")
        activateSession()
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, currentTime >= duration - 0.3 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    func stop() {
        tearDown()
        track = nil
        queue = []
        isPlaying = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func play(_ next: AloMusicTrack) {
        tearDown()
        track = next
        duration = next.duration
        currentTime = 0
        isWaiting = true
        NotificationCenter.default.post(name: aloMediaPlaybackDidStart, object: "alo.music")
        activateSession()
        let player = AloSecureMediaStore.shared.makePlayer(url: next.url)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let total = self.player?.currentItem?.duration.seconds, total.isFinite, total > 0 { self.duration = total }
            }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.player === player else { return }
                self.isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if player.timeControlStatus == .playing { self.isPlaying = true }
                self.updateNowPlaying()
            }
        })
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.hasNext { self.next() } else { self.isPlaying = false; self.currentTime = self.duration; self.updateNowPlaying() }
            }
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    private func tearDown() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        isWaiting = false
    }

    private func activateSession() { AloPlaybackAudioSession.activate() }

    // MARK: Lock screen and headphones
    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.isPlaying ? self.pause() : self.resume() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.performer,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0
        ]
    }
}

/// A song in a message: round play button, title, performer · length · size.
struct AloMusicAttachmentView: View {
    @EnvironmentObject private var app: AloAppModel
    @ObservedObject private var playback = AloMusicPlayback.shared
    let attachment: AloMessageAttachment
    let messageId: Int
    let isMine: Bool
    let accent: Color
    /// The message's time and checks, when the song is all the message has: they sit at the end of the second line,
    /// as in Telegram, instead of taking a line of their own under the bubble.
    var meta: AnyView? = nil

    private var track: AloMusicTrack? {
        guard let url = app.api.absoluteURL(attachment.url) else { return nil }
        let names = AloMusicCatalog.titles(attachment)
        return AloMusicTrack(id: attachment.id, messageId: messageId, url: url, title: names.title, performer: names.performer,
                             duration: Double(attachment.metadata["durationSeconds"] ?? "") ?? 0)
    }

    private var isCurrent: Bool { playback.isCurrent(attachment.id) }

    private var size: String? {
        let bytes = AloChunkedMediaCrypto.Metadata(attachment.mediaEncryption.reduce(into: [String: Any]()) { $0[$1.key] = $1.value })?
            .plaintextSize ?? attachment.metadata["size"].flatMap(Int64.init)
        return bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    private var timeLabel: String {
        let total = isCurrent && playback.duration > 0 ? playback.duration : (track?.duration ?? 0)
        if isCurrent, playback.isPlaying || playback.currentTime > 0 {
            return "\(AloMusicCatalog.clock(playback.currentTime)) / \(AloMusicCatalog.clock(total))"
        }
        return total > 0 ? AloMusicCatalog.clock(total) : ""
    }

    var body: some View {
        let names = AloMusicCatalog.titles(attachment)
        HStack(spacing: 12) {
            Button {
                if let track { playback.toggle(track) }
            } label: {
                ZStack {
                    Circle().fill(isMine ? Color.white : accent)
                    Image(systemName: isCurrent && playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isMine ? accent : .white)
                        .offset(x: isCurrent && playback.isPlaying ? 0 : 1.5)
                        .contentTransition(.symbolEffect(.replace))
                    if isCurrent && playback.isWaiting {
                        Circle().trim(from: 0, to: 0.28)
                            .stroke(isMine ? accent : .white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                            .padding(3)
                            .rotationEffect(.degrees(playback.isWaiting ? 360 : 0))
                            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: playback.isWaiting)
                    }
                }
                .frame(width: 46, height: 46)
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityLabel(isCurrent && playback.isPlaying ? "Пауза" : "Слушать «\(names.title)»")
            .accessibilityIdentifier("alo.music.play")

            VStack(alignment: .leading, spacing: 2) {
                Text(names.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text([names.performer, timeLabel, size ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.72))
                        .lineLimit(1)
                    if let meta {
                        Spacer(minLength: 0)
                        meta.fixedSize()
                    }
                }
            }
            if meta == nil { Spacer(minLength: 0) }
        }
        .padding(.vertical, 2)
        .onAppear { if let track { playback.register(track) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.music.\(attachment.id)")
    }
}

/// The oval under the chat header while a song plays (the same place and shape as the voice message bar).
struct AloMusicPlaybackBar: View {
    @ObservedObject private var playback = AloMusicPlayback.shared
    var onOpen: (Int) -> Void = { _ in }
    /// Where the line is being dragged to (0…1): the song is silent meanwhile and plays from there when let go.
    @State private var scrubFraction: Double?

    var body: some View {
        if let track = playback.track {
            ZStack(alignment: .bottom) {
                HStack(spacing: 2) {
                    button("backward.fill", label: "Предыдущий трек", disabled: !playback.hasPrevious) { playback.previous() }
                    button(playback.isPlaying ? "pause.fill" : "play.fill", label: playback.isPlaying ? "Пауза" : "Воспроизвести", size: 15) {
                        playback.isPlaying ? playback.pause() : playback.resume()
                    }
                    .accessibilityIdentifier("alo.music.bar.toggle")
                    button("forward.fill", label: "Следующий трек", disabled: !playback.hasNext) { playback.next() }
                        .accessibilityIdentifier("alo.music.bar.next")

                    Button { onOpen(track.messageId) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(.system(size: 13, weight: .heavy, design: .rounded))
                                .foregroundStyle(AloTheme.text)
                                .lineLimit(1)
                                .accessibilityIdentifier("alo.music.bar.title")
                            Text([track.performer, "\(AloMusicCatalog.clock(shownTime)) / \(AloMusicCatalog.clock(playback.duration))"]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(AloTheme.muted)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { playback.cycleRate() } label: {
                        Text(rateTitle)
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .foregroundStyle(AloTheme.text)
                            .frame(minWidth: 40, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(AloControlPressStyle())
                    .accessibilityLabel("Скорость")

                    button("xmark", label: "Закрыть плеер", size: 13, tint: AloTheme.muted) { playback.stop() }
                        .accessibilityIdentifier("alo.music.bar.close")
                }
                .padding(.horizontal, 6)

                // The thin line along the bottom: drag it to seek. The song is silent while the finger moves (no
                // fast-forward squeak back and forth) and plays from the new place when it is let go (owner, 2026-10-28).
                GeometryReader { proxy in
                    ZStack(alignment: .bottomLeading) {
                        Color.clear.contentShape(Rectangle())
                        Capsule()
                            .fill(AloTheme.accent)
                            .frame(width: proxy.size.width * shownProgress, height: 2)
                            .animation(scrubFraction == nil ? .linear(duration: 0.25) : nil, value: shownProgress)
                        if scrubFraction != nil {
                            Circle().fill(AloTheme.accent).frame(width: 10, height: 10)
                                .offset(x: proxy.size.width * shownProgress - 5, y: 4)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard playback.duration > 0 else { return }
                                if scrubFraction == nil { playback.pause() }
                                scrubFraction = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                            }
                            .onEnded { value in
                                guard playback.duration > 0 else { return }
                                let fraction = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                                scrubFraction = nil
                                playback.seek(to: min(fraction * playback.duration, max(0, playback.duration - 0.5)))
                                playback.resume()
                            }
                    )
                }
                .frame(height: 16)
                .padding(.horizontal, 18)
                .accessibilityElement()
                .accessibilityLabel("Перемотка")
                .accessibilityValue(AloMusicCatalog.clock(shownTime))
                .accessibilityAdjustableAction { direction in
                    let step: Double = direction == .increment ? 5 : -5
                    playback.seek(to: min(playback.duration, max(0, playback.currentTime + step)))
                }
            }
            .modifier(AloChatPanelGlass(radius: 18, role: .control))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("alo.music.bar")
        }
    }

    private var progress: CGFloat {
        playback.duration > 0 ? CGFloat(min(1, max(0, playback.currentTime / playback.duration))) : 0
    }

    private var shownProgress: CGFloat { scrubFraction.map { CGFloat($0) } ?? progress }

    private var shownTime: Double { scrubFraction.map { $0 * playback.duration } ?? playback.currentTime }

    private var rateTitle: String {
        playback.rate == floor(playback.rate) ? "\(Int(playback.rate))x" : String(format: "%gx", playback.rate)
    }

    private func button(_ symbol: String, label: String, size: CGFloat = 13, tint: Color = AloTheme.text, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .heavy))
                .foregroundStyle(tint.opacity(disabled ? 0.35 : 1))
                .frame(width: 38, height: 44)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(AloControlPressStyle())
        .disabled(disabled)
        .accessibilityLabel(label)
        .aloChatSwipeControl()
    }
}
