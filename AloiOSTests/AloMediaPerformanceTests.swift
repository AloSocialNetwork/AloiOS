import AVFoundation
import Foundation
import Testing
@testable import AloiOS

@Suite(.serialized)
struct AloMediaPerformanceTests {
    @Test func durationSurvivesDraftAndWireProjection() {
        let draft = AloLocalAttachment(data: Data(), mime: "audio/m4a", type: "audio", name: "voice")
            .withDuration(61.25)
        let copy = draft.replacingWaveform([0.2, 0.8])
        #expect(copy.id == draft.id)
        #expect(AloMessageAttachment(local: copy).durationSeconds == 61.25)
        #expect(AloMessageAttachment(["type": "audio", "metadata": copy.durationMetadata]).durationSeconds == 61.25)
        #expect(draft.withDuration(.nan).durationSeconds == nil)
        #expect(AloMessageAttachment(["metadata": ["durationSeconds": "inf"]]).durationSeconds == nil)
    }

    @Test @MainActor func protectedMetadataAndPosterWorkWithoutPlayer() async throws {
        let media = await AloMessengerSampleMedia.make()
        let video = try #require(media.video)
        let draft = try await Task.detached {
            try AloDraftAttachmentStore.makeRecordedCircle(sourceURL: video, durationSeconds: 3)
        }.value
        defer { AloDraftAttachmentStore.discard(draft) }
        let url = try #require(draft.localPlaybackURL)
        async let first = AloMediaPreviewCache.shared.preview(url: url, video: true)
        async let second = AloMediaPreviewCache.shared.preview(url: url, video: true)
        let (a, b) = await (first, second)
        #expect((a.duration ?? 0) > 2.8)
        #expect(a.image != nil)
        #expect(a.image === b.image)
        #expect((a.image?.size.width ?? 999) <= 320)
        AloSecureMediaStore.shared.remove(urls: [url])
        let expired = await AloMediaPreviewCache.shared.preview(url: url, video: true)
        #expect(expired.image == nil && expired.duration == nil)
    }

    @Test @MainActor func voiceDurationLoadsBeforePlaybackAndDraftIsFileBacked() async throws {
        let media = await AloMessengerSampleMedia.make()
        let audio = try #require(media.audio)
        let draft = try await Task.detached {
            let waveform = AloAudioWaveformAnalysis.samples(from: audio, count: 28)
            #expect(waveform.count == 28)
            #expect(waveform.allSatisfy { $0.isFinite && (0...1).contains($0) })
            return try AloDraftAttachmentStore.makeRecordedVoice(sourceURL: audio, waveform: waveform, durationSeconds: 3)
        }.value
        defer { AloDraftAttachmentStore.discard(draft) }
        #expect(draft.data.isEmpty && draft.encryptedSourceURL != nil)
        let url = try #require(draft.localPlaybackURL)
        let preview = await AloMediaPreviewCache.shared.preview(url: url, video: false)
        #expect(abs((preview.duration ?? 0) - 3) < 0.05)
        #expect(preview.image == nil)
        let playback = AloRecordedAudioPreview()
        try await playback.toggle(attachment: draft)
        #expect(playback.isPlaying)
        try await playback.toggle(attachment: draft)
        #expect(!playback.isPlaying)
        playback.stop()
    }

    @Test @MainActor func pickedVideoPreviewIsBoundedAndFileBacked() async throws {
        let media = await AloMessengerSampleMedia.make()
        let source = try #require(media.video)
        let draft = try await Task.detached {
            try AloDraftAttachmentStore.makePickedVideo(sourceURL: source, mime: "video/mp4", name: "selected.mp4")
        }.value
        defer { AloDraftAttachmentStore.discard(draft) }
        #expect(draft.data.isEmpty)
        #expect(draft.localPlaybackURL != nil)
        let first = await AloMediaPreviewCache.shared.preview(localVideo: draft)
        let second = await AloMediaPreviewCache.shared.preview(localVideo: draft)
        #expect(first.image != nil)
        #expect(first.image === second.image)
        #expect((first.image?.size.width ?? 999) <= 320)
        #expect((first.image?.size.height ?? 999) <= 320)
    }

    @Test @MainActor func cachedAppOpensBeforeOfflineRequestCompletes() async throws {
        let raw: [String: Any] = ["data": ["me": ["id": 1_999_998_765, "name": "Offline test"]]]
        let data = try JSONSerialization.data(withJSONObject: raw)
        let api = AloAPIClient(baseURLs: [URL(string: "http://127.0.0.1:9/")!])
        let model = AloAppModel(api: api, startupCacheLoader: { data })
        model.start()
        // No await: cached UI is already usable in the first actor turn.
        #expect(model.phase == .app)
        #expect(model.bootstrap?.me.id == 1_999_998_765)
        #expect(!model.isBusy)
        for _ in 0..<100 {
            if model.connectionState == .unavailable { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.phase == .app)
        #expect(model.connectionState == .unavailable)
        model.suspendConnectionRefresh()
    }

    @Test @MainActor func firstInstallOpensSignInWithoutWaitingForNetwork() {
        let api = AloAPIClient(baseURLs: [URL(string: "http://127.0.0.1:9/")!])
        let model = AloAppModel(api: api, startupCacheLoader: { nil })
        model.start()
        #expect(model.phase == .auth)
        #expect(!model.isBusy)
        model.suspendConnectionRefresh()
    }
}
