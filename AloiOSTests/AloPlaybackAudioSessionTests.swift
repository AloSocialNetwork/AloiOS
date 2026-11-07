import AVFoundation
import Testing
@testable import AloiOS

@Suite(.serialized)
struct AloPlaybackAudioSessionTests {
    /// A circle recorded or a call made leaves `.playAndRecord` (earpiece, silenced by the switch for the default
    /// category); playing a circle, a video or a voice message must take the loudspeaker `.playback` session.
    @MainActor @Test func playbackTakesThePlaybackSessionAfterRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat)
        AloPlaybackAudioSession.activate()
        #expect(session.category == .playback)
        #expect(session.mode == .default)
        AloPlaybackAudioSession.activate(mode: .spokenAudio)
        #expect(session.category == .playback)
        #expect(session.mode == .spokenAudio)
    }
}
