import Foundation
import Testing
@testable import AloiOS

/// The logic of secret chats that needs no server: rows in the chat list, read marks and timers, the envelope rule.
struct AloSecretChatTests {
    private func chat(id: Int, status: String = "active", role: String = "started", created: String,
                      last: AloSecretMessage? = nil, unread: Int = 0, ttl: Int = 0) -> AloSecretChat {
        AloSecretChatCodec.parseChat([
            "id": id, "status": status, "role": role, "peerUserId": 7,
            "peerUser": ["id": 7, "name": "Мария", "username": "maria"],
            "localDeviceId": "ios_a", "remoteDeviceId": status == "active" ? "web_b" : "",
            "ttlSeconds": ttl, "createdAt": created, "unreadCount": unread
        ], lastMessage: last)!
    }

    private func message(id: Int, sender: Int, body: String = "текст", seconds: Int = 0, created: String,
                         read: String = "", expires: String = "") -> AloSecretMessage {
        AloSecretChatCodec.parseMessage([
            "id": id, "secretChatId": 1, "senderUserId": sender, "body": body, "selfDestructSeconds": seconds,
            "createdAt": created, "readAt": read, "expiresAt": expires
        ])
    }

    @Test func aRequestAndAWaitingChatSayWhatIsGoingOn() {
        let request = chat(id: 1, status: "pending", role: "incoming", created: "2026-10-25T10:00:00.000Z")
        let waiting = chat(id: 2, status: "pending", role: "started", created: "2026-10-25T10:00:00.000Z")
        #expect(request.isIncomingRequest && !request.isWaiting)
        #expect(AloSecretChatList.preview(request) == "Запрос секретного чата")
        #expect(AloSecretChatList.preview(waiting) == "Ждём, пока Мария зайдёт в сеть…")
        // A request always shows as unread in the list.
        #expect(AloSecretChatList.summary(request).unreadCount == 1)
    }

    @Test func secretRowsHaveTheirOwnIdSpaceAndSitAmongChatsByTime() {
        let older = AloConversationSummary(peerId: 5, kind: "direct", roomId: 0, memberCount: 0, lastAt: "2026-10-25T09:00:00.000Z",
            lastBody: "a", peer: AloConversationPeer(id: 5, name: "A", username: "a", avatarUrl: "", verified: false, online: false,
                                                    lastSeenAt: "", isTyping: false, entityType: ""),
            lastMessageId: 1, lastSenderId: 5, unreadCount: 0, hasServerUnreadCount: true)
        let newer = AloConversationSummary(peerId: 6, kind: "direct", roomId: 0, memberCount: 0, lastAt: "2026-10-25T12:00:00.000Z",
            lastBody: "b", peer: AloConversationPeer(id: 6, name: "B", username: "b", avatarUrl: "", verified: false, online: false,
                                                    lastSeenAt: "", isTyping: false, entityType: ""),
            lastMessageId: 2, lastSenderId: 6, unreadCount: 0, hasServerUnreadCount: true)
        let secret = chat(id: 3, created: "2026-10-25T10:30:00.000Z")
        let rows = AloSecretChatList.merge(arranged: [newer, older], isPinned: { _ in false }, secrets: [secret])
        #expect(rows.map(\.peerId) == [6, -3, 5])
        #expect(rows[1].kind == "secret" && rows[1].roomId == 3)
        // A pinned chat stays on top even when the secret chat is newer.
        let pinnedFirst = AloSecretChatList.merge(arranged: [older, newer], isPinned: { $0.peerId == 5 }, secrets: [secret])
        #expect(pinnedFirst.map(\.peerId) == [5, 6, -3])
    }

    @Test func readingStartsTheTimerOnlyForWhatTheOtherPersonSent() {
        let now = AloSecretTime.millis("2026-10-25T10:00:00.000Z")
        let mine = message(id: 1, sender: 1, seconds: 5, created: "2026-10-25T09:59:00.000Z")
        let theirs = message(id: 2, sender: 7, seconds: 5, created: "2026-10-25T09:59:30.000Z")
        let plain = message(id: 3, sender: 7, created: "2026-10-25T09:59:40.000Z")
        let result = AloSecretTimers.applyRead([mine, theirs, plain], myUserId: 1, nowMillis: now)
        #expect(result.upToMessageId == 3)
        #expect(result.messages[0].expiresAt.isEmpty)
        #expect(AloSecretTime.millis(result.messages[1].expiresAt) == now + 5_000)
        #expect(!result.messages[2].readAt.isEmpty && result.messages[2].expiresAt.isEmpty)
        // Five seconds later the timed one is gone, the rest stay.
        let later = AloSecretTimers.visible(result.messages, nowMillis: now + 5_000)
        #expect(later.map(\.id) == [1, 3])
        #expect(AloSecretChatCodec.countdownLabel(millisLeft: 4_200) == "5 с")
        #expect(AloSecretChatCodec.countdownLabel(millisLeft: 90_000) == "2 мин")
    }

    @Test func anEnvelopeIsForExactlyOneDevice() {
        let one: [String: Any] = ["purpose": "message", "mode": "direct", "senderDeviceId": "ios_a",
                                  "recipients": [["userId": 7, "deviceId": "web_b"]]]
        #expect(AloSecretChatCodec.isSingleRecipientEnvelope(one, peerUserId: 7, peerDeviceId: "web_b", senderDeviceId: "ios_a"))
        var two = one
        two["recipients"] = [["userId": 7, "deviceId": "web_b"], ["userId": 1, "deviceId": "ios_other"]]
        #expect(!AloSecretChatCodec.isSingleRecipientEnvelope(two, peerUserId: 7, peerDeviceId: "web_b", senderDeviceId: "ios_a"))
        #expect(!AloSecretChatCodec.isSingleRecipientEnvelope(one, peerUserId: 7, peerDeviceId: "android_c", senderDeviceId: "ios_a"))
        // Files go to the server as opaque e2ee files only.
        let attachment = AloMessageAttachment(["type": "image", "url": "/uploads/messages/x.bin", "name": "фото.jpg"])
        let body = AloSecretChatCodec.messageBody(deviceId: "ios_a", encrypted: one, attachments: [attachment],
                                                  clientMessageId: "c1", selfDestructSeconds: 30)
        let files = body["attachments"] as? [[String: Any]]
        #expect(files?.first?["type"] as? String == "e2ee")
        #expect(body["selfDestructSeconds"] as? Int == 30)
    }

    // MARK: Voice messages and circles (docs/qa/test-run-2026-10-26.md, P2)

    @Test func aRecordedVoiceGoesIntoTheEnvelopeAsAVoiceMessage() {
        // What uploadE2EEAttachment returns for the recorder's draft: type `audio`, the bars, "4" seconds.
        let uploaded = AloMessageAttachment(type: "audio", url: "/uploads/messages/v.bin", name: "voice-1.m4a",
            waveform: [0.2, 0.9, 0.5], mediaEncryption: ["algorithm": "alo-aes-gcm-chunked-v1", "mime": "audio/mp4"],
            metadata: ["durationSeconds": "4"])
        let sealed = AloSecretChatCodec.sealedAttachment(uploaded)
        #expect(sealed.type == "voice")
        #expect(sealed.waveform.count == 3)
        #expect(sealed.metadata["durationSeconds"] == "4")
        #expect(sealed.mediaEncryption["mime"] == "audio/mp4")
        #expect(sealed.url == uploaded.url && sealed.name == "voice-1.m4a")
        #expect(sealed.isVoiceAttachment && !sealed.isCircleAttachment)
    }

    @Test func aRecordedCircleIsASquareCircleWithItsLength() {
        let uploaded = AloMessageAttachment(type: "circle", url: "/uploads/messages/c.bin", name: "circle-1.mp4",
            waveform: [0.4], metadata: ["durationSeconds": "3"])
        let sealed = AloSecretChatCodec.sealedAttachment(uploaded)
        #expect(sealed.type == "circle")
        #expect(sealed.metadata["width"] == "400" && sealed.metadata["height"] == "400")
        #expect(sealed.metadata["durationSeconds"] == "3")
        #expect(sealed.waveform.isEmpty)
        // A size the sender knew stays; a photo stays a photo.
        let sized = AloSecretChatCodec.sealedAttachment(AloMessageAttachment(type: "circle", url: "/u", metadata: ["width": "480", "height": "480"]))
        #expect(sized.metadata["width"] == "480")
        #expect(AloSecretChatCodec.sealedAttachment(AloMessageAttachment(type: "image", url: "/u")).type == "image")
    }

    @Test func theChatListNamesARecordingByWhatItIs() {
        func last(_ attachment: [String: Any]) -> AloSecretMessage {
            AloSecretChatCodec.parseMessage(["id": 9, "secretChatId": 1, "senderUserId": 7, "body": "",
                                             "createdAt": "2026-10-26T10:00:00.000Z", "attachments": [attachment]])
        }
        #expect(AloSecretChatList.messagePreview(last(["type": "voice", "url": "/a", "name": "voice-1.m4a"])) == "Голосовое сообщение")
        #expect(AloSecretChatList.messagePreview(last(["type": "audio", "url": "/a", "name": "voice-1.m4a"])) == "Голосовое сообщение")
        #expect(AloSecretChatList.messagePreview(last(["type": "circle", "url": "/a", "name": "circle-1.mp4"])) == "Видеосообщение")
        #expect(AloSecretChatList.messagePreview(last(["type": "video", "url": "/a", "name": "video-circle-1.mp4"])) == "Видеосообщение")
        #expect(AloSecretChatList.messagePreview(last(["type": "video", "url": "/a", "name": "trip.mp4"])) == "Видео")
        // The recorder's own types are what the composer keeps as a recording.
        #expect(AloSecretChatView.isRecording(AloLocalAttachment(data: Data(), mime: "audio/mp4", type: "audio", name: "voice-1.m4a")))
        #expect(AloSecretChatView.isRecording(AloLocalAttachment(data: Data(), mime: "video/mp4", type: "circle", name: "circle-1.mp4")))
        #expect(!AloSecretChatView.isRecording(AloLocalAttachment(data: Data(), mime: "image/png", type: "image", name: "a.png")))
    }
}

