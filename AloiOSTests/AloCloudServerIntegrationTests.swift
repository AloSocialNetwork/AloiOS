import Foundation
import Testing
import UIKit
@testable import AloiOS

/// The cloud-chat requests against a real Alo server on a throwaway database. Skipped unless
/// `ALO_CLOUD_SERVER_URL`, `ALO_CLOUD_TOKEN_A` and `ALO_CLOUD_TOKEN_B` are set (users 9101 and 9102 of a server with
/// `DIRECT_MESSAGES_E2EE_REQUIRED=0`); run with `TEST_RUNNER_ALO_CLOUD_SERVER_URL=… xcodebuild test`.
private let cloudEnvironment = ProcessInfo.processInfo.environment

@Suite(.serialized, .enabled(if: cloudEnvironment["ALO_CLOUD_SERVER_URL"] != nil && cloudEnvironment["ALO_CLOUD_TOKEN_A"] != nil))
struct AloCloudServerIntegrationTests {
    private let userA = 9_101
    private let userB = 9_102

    private func cookie(_ token: String, url: URL) -> HTTPCookie {
        HTTPCookie(properties: [.domain: url.host ?? "127.0.0.1", .path: "/", .name: "alo_session", .value: token])!
    }

    @Test @MainActor func plainMessagesFilesCardsEditsPollsAndGroupsRoundTripThroughTheRealServer() async throws {
        let url = try #require(URL(string: cloudEnvironment["ALO_CLOUD_SERVER_URL"] ?? ""))
        let tokenA = try #require(cloudEnvironment["ALO_CLOUD_TOKEN_A"]), tokenB = try #require(cloudEnvironment["ALO_CLOUD_TOKEN_B"])
        let run = String(UUID().uuidString.prefix(8)).lowercased()
        let pollId = "ios-cloud-poll-\(run)"
        let client = AloAPIClient(baseURLs: [url])
        client.messagingPolicyCache.forget()
        func signIn(_ token: String) async throws {
            client.replaceSessionCookies([cookie(token, url: url)])
            _ = try await client.loadBootstrap()
        }

        // 1. The server says ordinary chats are cloud chats.
        try await signIn(tokenA)
        let policy = await client.messagingPolicy(refresh: true)
        #expect(policy.isCloudEverywhere)

        // 2. Text with formatting, then files and cards in one message that replies to it.
        let first = try await client.sendCloudMessage(AloCloudSendRequest(
            peerId: userB, kind: "direct", body: "**Привет**, __мир__ https://example.com", clientMessageId: "ios-cloud-text-\(run)"))
        #expect(first.messageId > 0)
        let sample = await AloMessengerSampleMedia.make()
        let audio = try #require(sample.audio)
        let originalAudio = try Data(contentsOf: audio)
        let voiceDraft = try await Task.detached {
            try AloDraftAttachmentStore.makeRecordedVoice(sourceURL: audio, waveform: [0.2, 0.9, 0.5], durationSeconds: 4)
        }.value
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let photoDraft = try await Task.detached {
            try AloDraftAttachmentStore.makePickedMedia(data: try #require(image.pngData()), mime: "image/heic", type: "image", name: "media-1.heic")
        }.value
        let fileDraft = AloLocalAttachment(data: Data("договор".utf8), mime: "application/pdf", type: "file", name: "договор.pdf")
        defer { [voiceDraft, photoDraft].forEach(AloDraftAttachmentStore.discard) }
        let voice = try await client.uploadMessageAttachment(voiceDraft, cloud: true)
        let photo = try await client.uploadMessageAttachment(photoDraft, cloud: true)
        let file = try await client.uploadMessageAttachment(fileDraft, cloud: true)
        let gif = AloMessageAttachment(type: "gif", url: "https://media.example.com/cat.gif", name: "Кот", metadata: ["gifId": "g-1"])
        let media = try await client.sendCloudMessage(AloCloudSendRequest(
            peerId: userB, kind: "direct", body: "Всё сразу",
            attachments: [voice, photo, file, .location(latitude: 55.75, longitude: 37.61),
                          .contact(AloEntitySummary(["id": userA, "name": "Анна", "username": "anna_cloud"])), gif],
            replyToMessageId: first.messageId, silent: true, clientMessageId: "ios-cloud-media-\(run)"))
        #expect(media.messageId > first.messageId)
        _ = try await client.sendCloudMessageEdit(
            conversation: AloConversationDetail(peerId: userB, json: ["peer": ["id": userB, "name": "Борис"], "items": []]),
            messageId: first.messageId, body: "**Привет** снова")

        // 3. An anonymous poll: the create event is the body, the votes are counted by the server.
        let poll = AloPollDefinition(id: pollId, question: "Чай или кофе?",
                                     options: [AloPollOption(id: "tea", text: "Чай"), AloPollOption(id: "coffee", text: "Кофе")],
                                     allowsMultipleAnswers: false, isQuiz: false, correctOptionIds: [], isAnonymous: true, allowsRevoting: true)
        let pollAck = try await client.sendCloudMessage(AloCloudSendRequest(
            peerId: userB, kind: "direct", body: try #require(AloPollCodec.encodeCreate(poll)), clientMessageId: "ios-cloud-poll-\(run)"))
        let conversationForPoll = AloConversationDetail(peerId: userB, json: ["peer": ["id": userB, "name": "Борис"], "items": []])
        _ = try await client.registerPoll(poll, messageId: pollAck.messageId, conversation: conversationForPoll)

        // 4. A group message that names a member, and «Избранное».
        let group = try await client.createGroupChat(title: "Облачная группа", description: "", kind: "group", joinPolicy: "invite",
                                                     username: "", memberIds: [userB])
        _ = try await client.sendCloudMessage(AloCloudSendRequest(
            roomId: group.roomId, kind: "group", body: "Привет, @boris_cloud",
            clientMessageId: "ios-cloud-group-\(run)", mentionedUserIds: [userB]))
        let saved = try await client.sendCloudMessage(AloCloudSendRequest(
            peerId: userA, kind: "direct", body: "Заметка себе", clientMessageId: "ios-cloud-saved-\(run)"))
        #expect(saved.messageId > 0)

        // 5. The other person reads all of it.
        try await signIn(tokenB)
        let bootstrap = try await client.loadBootstrap()
        let row = try #require(bootstrap.conversations.first { $0.peerId == userA })
        #expect(!row.lastBody.isEmpty, "The chat list shows a preview of a cloud message: \(row.lastBody)")
        let history = try await client.loadConversation(peerId: userA)
        let text = try #require(history.items.first { $0.id == first.messageId })
        #expect(text.isCloud && text.body == "Привет снова" && text.entities.map(\.type) == ["bold"] && text.editedAt != "")
        let all = try #require(history.items.first { $0.id == media.messageId })
        #expect(all.isCloud && all.replyToMessageId == first.messageId)
        let types = all.attachments.map(\.type)
        #expect(types == ["voice", "image", "file", "location", "contact", "sticker"], "Got \(types)")
        let received = try #require(all.attachments.first)
        let receivedURL = try #require(URL(string: received.url))
        defer { AloSecureMediaStore.shared.remove(urls: [receivedURL]) }
        #expect(received.waveform.count == 3 && received.durationSeconds == 4 && AloSecureMediaStore.shared.isSecureURL(receivedURL))
        let remote = try #require(AloSecureMediaStore.shared.remoteURL(for: receivedURL))
        let downloaded = try await client.downloadData(from: try #require(client.absoluteURL(remote)))
        #expect(downloaded.data == originalAudio, "The server keeps the voice file as it was sent")
        let place = try #require(all.attachments.first { $0.isLocationCard })
        #expect(place.metadata["latitude"] == "55.75")
        let jpeg = try #require(all.attachments.first { $0.type == "image" })
        #expect(jpeg.url.hasSuffix(".jpg") || jpeg.url.hasSuffix(".jpeg"), "A HEIC photo is stored as JPEG: \(jpeg.url)")
        let size = try #require(jpeg.mediaDimensions)
        #expect(abs(size.width / size.height - 1.5) < 0.01, "The server adds the size of the photo")
        let pollState = AloPollProjection.applyingCanonical(history.canonicalPolls,
            to: AloPollProjection.states(messages: history.items, currentUserId: userB))[pollId]
        #expect(pollState?.isServerTallied == true)
        let voted = try await client.votePoll(pollId: pollId, optionIds: ["tea"])
        #expect(voted.selectedOptionIds == ["tea"] && voted.voteCounts["tea"] == 1 && voted.publicVoters.isEmpty)
        let groupHistory = try await client.loadConversation(peerId: group.peerId)
        let groupMessage = try #require(groupHistory.items.first { $0.body == "Привет, @boris_cloud" })
        #expect(groupMessage.isCloud && groupMessage.entities.contains { $0.type == "mention" })

        // 6. The first person sees the totals but not who voted; «Избранное» keeps the note.
        try await signIn(tokenA)
        let own = try await client.loadConversation(peerId: userB)
        let totals = try #require(own.canonicalPolls[pollId])
        #expect(totals.voteCounts["tea"] == 1 && totals.selectedOptionIds.isEmpty && totals.publicVoters.isEmpty)
        let notes = try await client.loadConversation(peerId: userA)
        #expect(notes.items.contains { $0.body == "Заметка себе" && $0.isCloud })
    }
}
