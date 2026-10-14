import Foundation
import Testing
import UIKit
@testable import AloiOS

@Suite(.serialized)
struct AloChatNavigationAndMediaTests {
    private func message(_ id: Int, sender: Int = 2, scheduled: Bool = false) -> AloChatMessage {
        AloChatMessage(["id": id, "senderId": sender, "body": "Сообщение", "sendWhenOnline": scheduled])
    }

    @Test func viewportNavigationDoesNotDependOnAnInstantiatedBottomRow() {
        #expect(AloChatHistoryViewport(contentHeight: 4_000, offsetY: 3_220, viewportHeight: 780, bottomInset: 0).isAtBottom)
        #expect(!AloChatHistoryViewport(contentHeight: 4_000, offsetY: 3_220, viewportHeight: 780, bottomInset: 0).showsDownButton)
        #expect(AloChatHistoryViewport(contentHeight: 4_000, offsetY: 1_000, viewportHeight: 780, bottomInset: 0).showsDownButton)
        #expect(AloChatHistoryViewport(contentHeight: 4_000, offsetY: 3_220, viewportHeight: 780, bottomInset: 200).showsDownButton)
        #expect(AloChatHistoryViewport(contentHeight: 4_000, offsetY: 3_220, viewportHeight: 480, bottomInset: 0).showsDownButton,
                "An occluding keyboard reduces the actually visible history")
    }

    @Test func manualScrollEnablesNavigationWithoutPreviouslyReachingBottom() {
        var navigation = AloChatHistoryNavigationState()
        let olderHistory = AloChatHistoryViewport(contentHeight: 4_000, offsetY: 1_000,
            viewportHeight: 647, bottomInset: 0)
        #expect(!navigation.showsDownButton)
        navigation.update(olderHistory)
        #expect(!navigation.showsDownButton, "Do not flash during initial lazy placement")
        navigation.userInteracted()
        // No second geometry callback is required: both boolean viewport
        // values may stay unchanged throughout the user's first scroll.
        #expect(navigation.showsDownButton)
        navigation.update(olderHistory)
        #expect(navigation.showsDownButton)
        navigation.update(AloChatHistoryViewport(contentHeight: 4_000, offsetY: 3_353,
            viewportHeight: 647, bottomInset: 0))
        #expect(!navigation.showsDownButton)
        navigation.update(olderHistory)
        #expect(navigation.showsDownButton)
    }

    @Test func reachingBottomEnablesLaterNavigationWithoutManualScroll() {
        var navigation = AloChatHistoryNavigationState()
        navigation.update(AloChatHistoryViewport(contentHeight: 800, offsetY: 153,
            viewportHeight: 647, bottomInset: 0))
        #expect(!navigation.showsDownButton)
        navigation.update(AloChatHistoryViewport(contentHeight: 1_100, offsetY: 153,
            viewportHeight: 647, bottomInset: 0))
        #expect(navigation.showsDownButton)
    }

    @Test func bottomCorrectionIsMeasuredAndBounded() {
        let viewport: CGFloat = 778
        let hiddenFooter = CGRect(x: 0, y: 780, width: 402, height: 55)
        #expect(AloChatBottomScrollCorrection.isNeeded(footer: hiddenFooter,
            viewportHeight: viewport, attempt: 0))
        #expect(AloChatBottomScrollCorrection.isNeeded(footer: .zero,
            viewportHeight: viewport, attempt: 0))
        #expect(!AloChatBottomScrollCorrection.isNeeded(footer: hiddenFooter,
            viewportHeight: viewport, attempt: AloChatBottomScrollCorrection.maximumAttempts))
        #expect(!AloChatBottomScrollCorrection.isNeeded(footer: CGRect(x: 0, y: 724, width: 402, height: 54.5),
            viewportHeight: viewport, attempt: 1))
        #expect(!AloChatBottomScrollCorrection.isNeeded(footer: hiddenFooter,
            viewportHeight: 0, attempt: 0))
    }

    @Test func unseenCountsIncomingIDsNotRefreshesOrOwnAcknowledgements() {
        var tracker = AloChatUnseenMessages()
        let initial = [message(1), message(2, sender: 1)]
        tracker.reset(messages: initial)
        let updated = initial + [message(3), message(4), message(-1, sender: 1), message(5, sender: 1), message(6, scheduled: true)]
        tracker.update(messages: updated, currentUserID: 1, isAtBottom: false)
        #expect(tracker.unseenIDs == [3, 4])
        tracker.update(messages: updated, currentUserID: 1, isAtBottom: false)
        #expect(tracker.unseenIDs.count == 2)
        tracker.update(messages: updated.filter { $0.id != 3 }, currentUserID: 1, isAtBottom: false)
        #expect(tracker.unseenIDs == [4])
        tracker.reachedBottom()
        #expect(tracker.unseenIDs.isEmpty)
        tracker.update(messages: updated + [message(7)], currentUserID: 1, isAtBottom: true)
        #expect(tracker.unseenIDs.isEmpty)
        tracker.reset(messages: [message(100)])
        tracker.update(messages: [message(100), message(101)], currentUserID: 1, isAtBottom: false)
        #expect(tracker.unseenIDs == [101])
    }

    @Test @MainActor func pickedPhotoUsesProtectedURLAndNoInlineCopy() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 800))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
        }
        let bytes = try #require(image.jpegData(compressionQuality: 0.85))
        let draft = try await Task.detached {
            try AloDraftAttachmentStore.makePickedMedia(data: bytes, mime: "image/jpeg", type: "image", name: "photo.jpg")
        }.value
        defer { AloDraftAttachmentStore.discard(draft) }
        #expect(draft.data.isEmpty)
        let playback = try #require(draft.localPlaybackURL)
        #expect(AloSecureMediaStore.shared.isSecureURL(playback))
        let message = AloMessageAttachment(local: draft, includeInlineData: false)
        #expect(message.url == playback.absoluteString && message.posterUrl == message.url)
        let decrypted = try await Task.detached { try AloSecureMediaStore.shared.payload(for: playback).data }.value
        #expect(decrypted == bytes)
        let preview = try await AloImageCache.draftImage(draft, maxPixelSize: 512)
        #expect(max(preview.size.width * preview.scale, preview.size.height * preview.scale) <= 512)
        let legacy = AloLocalAttachment(data: bytes, mime: "image/jpeg", type: "image", name: "old.jpg")
        #expect(AloMessageAttachment(local: legacy, includeInlineData: false).url.isEmpty)
    }

    @Test @MainActor func largeOutboxSnapshotsAreOrderedAndDoNotHoldMainActor() async throws {
        let owner = 1_999_998_782 // isolated test owner, never a user's account
        let store = AloSecureOutboxStore.shared
        let bytes = Data(repeating: 17, count: 24 * 1_024 * 1_024)
        let draft = AloLocalAttachment(data: bytes, mime: "application/octet-stream", type: "file", name: "large.bin")
        let writes = [AloSecureOutboxStore.AttachmentWrite(id: "test-large", attachment: draft)]
        let start = Date()
        let first = store.scheduleSave(records: [["revision": 1]], attachments: writes, ownerUserId: owner)
        let second = store.scheduleSave(records: [["revision": 2]], attachments: writes, ownerUserId: owner)
        #expect(Date().timeIntervalSince(start) < 0.1, "Enqueue must not encrypt or write the attachment on UI")
        var mainActorResponded = false
        let heartbeat = Task { @MainActor in mainActorResponded = true }
        try await first.value
        try await second.value
        await heartbeat.value
        #expect(mainActorResponded)
        let snapshot = await Task.detached { store.load(ownerUserId: owner) }.value
        #expect(snapshot.first?["revision"] as? Int == 2)
        let restored = await Task.detached { store.loadAttachment(id: "test-large", ownerUserId: owner) }.value
        #expect(restored == bytes)
        // Serialized logout cannot resurrect old snapshots.
        store.scheduleClear(ownerUserId: owner)
        await store.finishPendingWrites()
        #expect(store.load(ownerUserId: owner).isEmpty)
        #expect(store.loadAttachment(id: "test-large", ownerUserId: owner) == nil)
    }
}
