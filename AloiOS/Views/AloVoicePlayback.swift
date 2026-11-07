import AVFoundation
import Combine
import SwiftUI

// The app's «some media started» signal (declared privately in MessagesView.swift, AloCirclePlayback.swift and
// AloMusicPlayer.swift too).
private let aloMediaPlaybackDidStart = Notification.Name("aloMediaPlaybackDidStart")

/// The voice message that plays, one for the whole app (the website does the same, ~/alo/web/js/views/chat.js).
/// It used to belong to the bubble, so leaving the chat (or scrolling the bubble away) stopped the clip; now the
/// bubbles and the bar under the chat header only show and steer this player, and the clip goes on until it ends,
/// is closed, or another sound starts.
@MainActor
final class AloVoicePlayback: ObservableObject {
    static let shared = AloVoicePlayback()

    /// The attachment that plays or is paused part-way (`nil`: no bar).
    @Published private(set) var attachmentId: String?
    @Published private(set) var title = "Голосовое сообщение"
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var speed: Double = 1

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var mediaObserver: NSObjectProtocol?
    private var isSeeking = false

    private init() {
        // A song takes the player's place (the bar closes); a circle or a video only pauses the clip.
        mediaObserver = NotificationCenter.default.addObserver(forName: aloMediaPlaybackDidStart, object: nil, queue: .main) { [weak self] note in
            let source = note.object as? String
            Task { @MainActor in
                guard let self, let id = self.attachmentId, source != id else { return }
                if source == "alo.music" { self.stop() } else { self.pause() }
            }
        }
    }

    func isCurrent(_ id: String) -> Bool { attachmentId == id }

    /// The bubble's play button: the same clip pauses or goes on, another one starts from the beginning.
    func toggle(id: String, url: URL, title: String, duration hint: Double) {
        if attachmentId == id, player != nil {
            isPlaying ? pause() : resume()
            return
        }
        start(id: id, url: url, title: title, duration: hint, at: 0, play: true)
    }

    /// Dragging along a bubble's waveform; a clip that is not open yet is opened there, paused.
    func seek(id: String, url: URL, title: String, duration hint: Double, to seconds: Double) {
        if attachmentId != id || player == nil {
            start(id: id, url: url, title: title, duration: hint, at: seconds, play: false)
            return
        }
        seek(to: seconds)
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(duration, seconds) : seconds)
        currentTime = target
        isSeeking = true
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSeeking = false
                if self.isPlaying { self.player?.rate = Float(self.speed) }
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        guard let player else { return }
        NotificationCenter.default.post(name: aloMediaPlaybackDidStart, object: attachmentId)
        AloMusicPlayback.shared.stop() // a voice message takes the player's place, as in Telegram
        activateSession()
        player.rate = Float(speed)
        isPlaying = true
    }

    /// 1× → 1,5× → 2× → 1×, kept for the next clips too.
    func cycleSpeed() {
        switch speed {
        case ..<1.25: speed = 1.5
        case ..<1.75: speed = 2
        default: speed = 1
        }
        if isPlaying { player?.rate = Float(speed) }
    }

    func stop() {
        tearDown()
        attachmentId = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func start(id: String, url: URL, title: String, duration hint: Double, at seconds: Double, play: Bool) {
        tearDown()
        attachmentId = id
        self.title = title.ifBlank("Голосовое сообщение")
        duration = hint
        currentTime = 0
        let player = AloSecureMediaStore.shared.makePlayer(url: url)
        self.player = player
        if let item = player.currentItem {
            Task { [weak self] in
                let loaded = try? await item.asset.load(.duration)
                guard let seconds = loaded?.seconds, seconds.isFinite, seconds > 0 else { return }
                await MainActor.run {
                    guard let self, self.player === player else { return }
                    self.duration = seconds
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.12, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.player === player, !self.isSeeking else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player === player else { return }
                self.stop()
            }
        }
        if seconds > 0 { seek(to: seconds) }
        if play { resume() }
    }

    private func tearDown() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        isSeeking = false
    }

    private func activateSession() { AloPlaybackAudioSession.activate(mode: .spokenAudio) }
}

/// Everything the person plays (circles, videos, voice messages, songs) is heard with the silent switch on and
/// through the loudspeaker. Without this a circle kept the app's default session (muted by the switch) or the
/// earpiece route a call or a recording had left. During a call the call owns the session.
@MainActor
enum AloPlaybackAudioSession {
    static func activate(mode: AVAudioSession.Mode = .default) {
        if let calls = AloAppModel.current?.calls,
           calls.activeCall != nil || calls.groupCall.activeCall != nil { return }
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != mode {
            try? session.setCategory(.playback, mode: mode)
        }
        try? session.setActive(true)
    }
}
