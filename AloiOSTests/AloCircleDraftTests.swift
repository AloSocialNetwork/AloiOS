import Foundation
import AVFoundation
import Testing
@testable import AloiOS

@Suite(.serialized)
struct AloCircleDraftTests {
    @Test @MainActor func encryptedCirclePlaysAndSeeksWithoutPlaintextCopy() async throws {
        let sample = await AloMessengerSampleMedia.make()
        let source = try #require(sample.video)
        let draft = try await Task.detached(priority: .userInitiated) {
            try AloDraftAttachmentStore.makeRecordedCircle(sourceURL: source)
        }.value
        defer { AloDraftAttachmentStore.discard(draft) }
        let playback = try #require(draft.localPlaybackURL)
        let player = AloSecureMediaStore.shared.makePlayer(url: playback)
        defer { player.pause() }
        let item = try #require(player.currentItem)
        #expect(draft.data.isEmpty)
        #expect((item.asset as? AVURLAsset)?.url.scheme == AloSecureMediaStore.scheme)
        for _ in 0..<100 {
            if item.status != .unknown { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(item.status == .readyToPlay, "Encrypted circle must reach AVPlayer ready state: \(String(describing: item.error))")
        let didSeek = await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(didSeek)
        player.play()
        for _ in 0..<60 {
            if player.currentTime().seconds > 1.2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(player.currentTime().seconds > 1.2)
    }

    @Test func circleDraftStaysEncryptedAndDoesNotInlineTheMovie() async throws {
        try await Task.detached(priority: .userInitiated) {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("circle-test-\(UUID()).mp4")
            let content = Data(repeating: 0x3B, count: 4 * 1_024 * 1_024)
            try content.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            let draft = try AloDraftAttachmentStore.makeRecordedCircle(sourceURL: source)
            let playback = try #require(draft.localPlaybackURL)
            defer {
                AloDraftAttachmentStore.remove(draft)
                AloSecureMediaStore.shared.remove(urls: [playback])
            }
            #expect(draft.data.isEmpty)
            #expect(draft.encryptedSourceURL != nil)
            #expect(AloSecureMediaStore.shared.isSecureURL(playback))
            #expect(AloMessageAttachment(local: draft).url == playback.absoluteString)
            #expect(!AloMessageAttachment(local: draft).url.hasPrefix("data:"))
            #expect(try AloSecureMediaStore.shared.payload(for: playback).data == content)
        }.value
    }

    @Test func restoredChunkedDraftIsNotDeletedWhenPersistedAgain() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-test-\(UUID()).bin")
        let content = Data(repeating: 0x7C, count: 512 * 1_024)
        try content.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let owner = Int.random(in: 1_000_000_000..<2_000_000_000)
        let id = UUID().uuidString.lowercased()
        let store = AloSecureOutboxStore.shared
        defer { store.clear(ownerUserId: owner) }
        try store.saveChunkedAttachment(from: source, id: id, ownerUserId: owner)
        let stored = try #require(store.loadChunkedAttachmentURL(id: id, ownerUserId: owner))
        let modified = try stored.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try store.saveChunkedAttachment(from: source, id: id, ownerUserId: owner)
        #expect(try stored.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        try store.saveChunkedAttachment(from: stored, id: id, ownerUserId: owner)
        #expect(try Data(contentsOf: stored) == content)
    }
}
