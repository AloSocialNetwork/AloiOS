import Foundation
import Testing
import UIKit
@testable import AloiOS

/// Cloud chats: ordinary chats are plain on the server. All traffic is intercepted; nothing reaches a real server.
private final class CloudURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest, Data) throws -> (Int, [String: Any])
    private static let lock = NSLock()
    private static var handlers = [String: Handler]()
    private static var log = [String: [(path: String, method: String, body: Data)]]()

    static func install(host: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler; log[host] = [] }
    }
    static func remove(host: String) { lock.withLock { handlers[host] = nil; log[host] = nil } }
    static func requests(host: String) -> [(path: String, method: String, body: Data)] { lock.withLock { log[host] ?? [] } }
    static func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host else { throw URLError(.badURL) }
            let body = try Self.readBody(request)
            let handler: Handler? = Self.lock.withLock {
                Self.log[host, default: []].append((url.path, request.httpMethod ?? "GET", body))
                return Self.handlers[host]
            }
            guard let handler else { throw URLError(.cannotConnectToHost) }
            let (status, json) = try handler(request, body)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private func cloudConfig(direct: Bool = true, group: Bool = true) -> [String: Any] {
    ["security": ["plaintextDirectMessagesAllowed": direct, "plaintextGroupMessagesAllowed": group]]
}

private func makeClient(host: String) -> AloAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudURLProtocol.self]
    let client = AloAPIClient(baseURLs: [URL(string: "http://\(host)/")!], configuration: configuration)
    client.messagingPolicyCache.forget()
    return client
}

@Suite(.serialized)
struct AloCloudWireTests {
    @Test func policyFollowsTheServerFlags() {
        let cloud = AloMessagingPolicy(config: cloudConfig())
        #expect(cloud.allowsCloud(kind: "direct", roomId: 0) && cloud.allowsCloud(kind: "group", roomId: 5))
        let split = AloMessagingPolicy(config: cloudConfig(direct: false, group: true))
        #expect(!split.allowsCloud(kind: "direct", roomId: 0))
        #expect(split.allowsCloud(kind: "group", roomId: 5))
        #expect(!split.isCloudEverywhere)
        #expect(AloMessagingPolicy(config: [:]) == .encryptedOnly, "A server that does not know the flags keeps end-to-end messages")
    }

    @Test func directTextKeepsBodyAndFormattingApartAndNeverCarriesEncryptedField() {
        let request = AloCloudSendRequest(peerId: 12, kind: "direct", body: "**Привет**, __мир__",
                                          replyToMessageId: 5, silent: true, clientMessageId: "cloud-wire-0000001")
        let json = request.jsonBody
        #expect(request.path == "/api/messages/send")
        #expect(json["body"] as? String == "Привет, мир")
        let entities = json["entities"] as? [[String: Any]] ?? []
        #expect(entities.map { $0["type"] as? String } == ["bold", "italic"])
        #expect(entities.map { $0["offset"] as? Int } == [0, 8])
        #expect(entities.map { $0["length"] as? Int } == [6, 3])
        #expect(json["encrypted"] == nil)
        #expect(json["peerId"] as? Int == 12 && json["replyToMessageId"] as? Int == 5 && json["silent"] as? Bool == true)
        #expect(json["clientMessageId"] as? String == "cloud-wire-0000001")
        #expect(json["scheduledAt"] == nil && json["forwardFrom"] == nil)
    }

    @Test func groupMessageGoesToTheRoomWithMentionsAndTopic() {
        var request = AloCloudSendRequest(roomId: 77, kind: "group", body: "всем привет @anna", topicId: 3,
                                          clientMessageId: "cloud-group-000001")
        request.mentionedUserIds = [9]
        let json = request.jsonBody
        #expect(request.path == "/api/group-chats/77/messages/send")
        #expect(json["peerId"] == nil && json["topicId"] as? Int == 3 && json["mentionedUserIds"] as? [Int] == [9])
        let entities = json["entities"] as? [[String: Any]] ?? []
        #expect(entities.contains { $0["type"] as? String == "mention" })
    }

    @Test func scheduledForwardedSelfDestructingMediaCarriesItsFields() {
        var request = AloCloudSendRequest(peerId: 3, kind: "direct", body: "", forwardFrom: AloForwardMeta(userId: 3, messageId: 55, user: nil),
                                          selfDestructSeconds: 10, scheduledAt: "2026-10-26T09:00:00.000Z",
                                          sendWhenOnline: false, clientMessageId: "cloud-later-0000001")
        request.scheduledPoll = ["pollId": "p1"]
        request.captchaToken = "token"
        let json = request.jsonBody
        #expect(json["scheduledAt"] as? String == "2026-10-26T09:00:00.000Z")
        #expect((json["forwardFrom"] as? [String: Int]) == ["userId": 3, "messageId": 55])
        #expect(json["selfDestructSeconds"] as? Int == 10)
        #expect((json["scheduledPoll"] as? [String: String])?["pollId"] == "p1")
        #expect(json["captchaToken"] as? String == "token")
    }

    @Test func spacesAroundTheTextAreRemovedAndFormattingFollowsTheTrimmedText() {
        let markup = AloCloudMessage.trimmedMarkup("** жирный** хвост  ")
        #expect(markup.body == "жирный хвост")
        #expect(markup.entities.map { [$0.offset, $0.length] } == [[0, 6]])
    }

    @Test func attachmentsUseTheKindsTheServerAccepts() {
        let voice = AloMessageAttachment(type: "audio", url: "/uploads/messages/v.m4a", name: "voice-1.m4a",
                                         waveform: [0.1, 0.9], metadata: ["durationSeconds": "7"])
        let location = AloMessageAttachment.location(latitude: 55.75, longitude: 37.61)
        let contact = AloMessageAttachment.contact(AloEntitySummary(["id": 4, "name": "Анна", "username": "anna"]))
        let gif = AloMessageAttachment(type: "gif", url: "https://media.example/cat.gif", name: "Кот",
                                       posterUrl: "https://media.example/cat-small.gif", metadata: ["gifId": "g1"])
        let payloads = [voice, location, contact, gif].map(AloCloudMessage.attachmentPayload)
        #expect(payloads.map { $0["type"] as? String } == ["voice", "location", "contact", "sticker"])
        #expect(payloads[0]["waveform"] as? [Double] == [0.1, 0.9])
        #expect((payloads[0]["metadata"] as? [String: Any])?["durationSeconds"] as? String == "7")
        #expect(payloads[0]["mediaEncryption"] == nil)
        let place = payloads[1]["metadata"] as? [String: Any] ?? [:]
        #expect(place["latitude"] as? Double == 55.75 && place["longitude"] as? Double == 37.61)
        #expect(payloads[1]["url"] as? String == "")
        #expect((payloads[2]["metadata"] as? [String: Any])?["userId"] as? String == "4")
        #expect(payloads[3]["posterUrl"] as? String == "https://media.example/cat-small.gif")
    }

    @Test func recordingKeepsTheExtensionOfTheBytesTheServerStored() {
        #expect(AloCloudMessage.name("voice-1.m4a", matching: "/uploads/messages/1-a.ogg") == "voice-1.ogg")
        #expect(AloCloudMessage.name("voice-1.m4a", matching: "/uploads/messages/1-a.m4a") == "voice-1.m4a")
        #expect(AloCloudMessage.name("voice", matching: "/uploads/messages/1-a.ogg") == "voice.ogg")
    }
}

@Suite(.serialized)
struct AloCloudMessageDecodingTests {
    @Test func cloudMessageShowsItsTextAsItIsAndFormattingFromEntities() {
        let literal = AloChatMessage(["id": 1, "senderId": 2, "body": "a **b** c", "entities": [], "encryptionScheme": ""])
        #expect(literal.body == "a **b** c" && literal.entities.isEmpty, "A cloud body is never read for markers")
        #expect(!literal.isEncrypted)
        let formatted = AloChatMessage(["id": 2, "senderId": 2, "body": "Привет, мир", "encryptionScheme": "",
                                        "entities": [["type": "bold", "offset": 0, "length": 6],
                                                     ["type": "link", "offset": 8, "length": 3, "url": "https://example.com"]]])
        #expect(formatted.entities.map(\.type) == ["bold", "link"])
        #expect(formatted.entities.last?.url == "https://example.com")
        let legacy = AloChatMessage(["id": 3, "senderId": 2, "body": "a **b** c"])
        #expect(legacy.body == "a b c" && legacy.entities.map(\.type) == ["bold"], "Messages without the entities field keep working")
        let encrypted = AloChatMessage(["id": 4, "senderId": 2, "body": "**x**", "entities": [], "encryptionScheme": "alo-libsignal-v1",
                                        "encryptedPayload": ["scheme": "alo-libsignal-v1"]])
        #expect(encrypted.isEncrypted && encrypted.body == "x", "A decrypted message is read the way it was")
    }

    @Test func historyOfACloudChatFeedsVoiceCardsPollsAndFormattingIntoTheSameModels() async throws {
        let host = "cloud-decode.invalid"
        let peer = 1_999_970_001
        let poll = AloPollDefinition(id: "poll-cloud-1", question: "Чай?", options: [AloPollOption(id: "a", text: "Да"), AloPollOption(id: "b", text: "Нет")],
                                     allowsMultipleAnswers: false, isQuiz: false, correctOptionIds: [], isAnonymous: true, allowsRevoting: true)
        let pollBody = try #require(AloPollCodec.encodeCreate(poll))
        CloudURLProtocol.install(host: host) { request, _ in
            if request.url?.path == "/api/messages/\(peer)" {
                return (200, ["peer": ["id": peer, "name": "Анна"], "items": [
                    ["id": 10, "senderId": peer, "body": "Привет, мир", "encryptionScheme": "", "encryptedPayload": NSNull(),
                     "entities": [["type": "bold", "offset": 0, "length": 6]], "attachments": []],
                    ["id": 11, "senderId": peer, "body": "", "encryptionScheme": "", "encryptedPayload": NSNull(), "entities": [],
                     "attachmentType": "voice", "attachmentUrl": "/uploads/messages/cloud-voice-1.ogg",
                     "attachments": [["type": "voice", "url": "/uploads/messages/cloud-voice-1.ogg", "name": "voice-1.m4a",
                                      "waveform": [0.2, 0.8], "metadata": ["durationSeconds": "7"]]]],
                    ["id": 12, "senderId": peer, "body": "", "encryptionScheme": "", "encryptedPayload": NSNull(), "entities": [],
                     "attachments": [["type": "location", "url": "", "name": "Москва",
                                      "metadata": ["latitude": 55.75, "longitude": 37.61, "title": "Москва"]]]],
                    ["id": 13, "senderId": peer, "body": pollBody, "encryptionScheme": "", "encryptedPayload": NSNull(), "entities": []]
                ], "polls": [["id": "poll-cloud-1", "messageId": 13, "voteCounts": ["a": 2, "b": 1], "selectedOptionIds": ["a"],
                              "totalVoters": 3, "isClosed": false, "allowsRevoting": true, "isAnonymous": true]]])
            }
            throw URLError(.unsupportedURL)
        }
        defer { CloudURLProtocol.remove(host: host) }
        let detail = try await makeClient(host: host).loadConversation(peerId: peer)
        #expect(detail.items.count == 4)
        #expect(detail.items[0].body == "Привет, мир" && detail.items[0].entities.map(\.type) == ["bold"])
        let voice = try #require(detail.items[1].attachments.first)
        let voiceURL = try #require(URL(string: voice.url))
        defer { AloSecureMediaStore.shared.remove(urls: [voiceURL]) }
        #expect(voice.type == "voice" && voice.waveform == [0.2, 0.8] && voice.durationSeconds == 7)
        #expect(AloSecureMediaStore.shared.isSecureURL(voiceURL), "A cloud voice message is played like a decrypted one")
        #expect(AloSecureMediaStore.shared.remoteURL(for: voiceURL) == "/uploads/messages/cloud-voice-1.ogg")
        let card = try #require(detail.items[2].attachments.first)
        #expect(card.isLocationCard && card.metadata["latitude"] == "55.75" && card.url.isEmpty)
        // Totals come from the server, also for an anonymous poll of a cloud chat.
        let states = AloPollProjection.applyingCanonical(detail.canonicalPolls, to: AloPollProjection.states(messages: detail.items, currentUserId: 1))
        let state = try #require(states["poll-cloud-1"])
        #expect(state.isServerTallied && state.voteCounts["a"] == 2 && state.selectedOptionIds == ["a"] && state.totalVoters == 3)
    }

    @Test func anOldEncryptedAnonymousPollKeepsCountingFromEvents() throws {
        let poll = AloPollDefinition(id: "poll-old-1", question: "Чай?", options: [AloPollOption(id: "a", text: "Да"), AloPollOption(id: "b", text: "Нет")],
                                     allowsMultipleAnswers: false, isQuiz: false, correctOptionIds: [], isAnonymous: true, allowsRevoting: true)
        let create = AloChatMessage(["id": 1, "senderId": 2, "body": try #require(AloPollCodec.encodeCreate(poll)),
                                     "encryptionScheme": "alo-libsignal-v1", "encryptedPayload": ["scheme": "alo-libsignal-v1"]])
        let vote = AloChatMessage(["id": 2, "senderId": 3, "body": try #require(AloPollCodec.encodeVote(pollId: "poll-old-1", optionIds: ["a"])),
                                   "encryptionScheme": "alo-libsignal-v1", "encryptedPayload": ["scheme": "alo-libsignal-v1"]])
        let server = AloCanonicalPollState(["id": "poll-old-1", "voteCounts": ["a": 9], "totalVoters": 9, "isAnonymous": true])
        let state = try #require(AloPollProjection.applyingCanonical(["poll-old-1": server],
            to: AloPollProjection.states(messages: [create, vote], currentUserId: 1))["poll-old-1"])
        #expect(!state.isServerTallied && state.voteCounts["a"] == 1, "An anonymous end-to-end poll is not counted by the server")
    }
}

@Suite(.serialized)
struct AloCloudClientTests {
    @Test func policyIsReadOnceKeptAndFallsBackToEndToEndWhenTheServerIsSilent() async {
        let host = "cloud-policy.invalid"
        CloudURLProtocol.install(host: host) { request, _ in
            request.url?.path == "/api/config" ? (200, cloudConfig(direct: true, group: false)) : (404, [:])
        }
        defer { CloudURLProtocol.remove(host: host) }
        let client = makeClient(host: host)
        #expect(await client.usesCloudMessages(kind: "direct", roomId: 0))
        #expect(await client.usesCloudMessages(kind: "group", roomId: 4) == false)
        #expect(CloudURLProtocol.requests(host: host).filter { $0.path == "/api/config" }.count == 1, "The flags are kept for a while")
        client.messagingPolicyCache.forget()
        CloudURLProtocol.remove(host: host)
        #expect(await client.messagingPolicy() == .encryptedOnly, "Unknown flags: the old behaviour")
    }

    @Test func cloudSendPostsPlainJSONAndReadsTheAcknowledgement() async throws {
        let host = "cloud-send.invalid"
        CloudURLProtocol.install(host: host) { request, _ in
            if request.url?.path == "/api/messages/send" { return (200, ["message": ["id": 901, "createdAt": "2026-10-25T10:00:00Z"]]) }
            return (404, [:])
        }
        defer { CloudURLProtocol.remove(host: host) }
        let client = makeClient(host: host)
        let ack = try await client.sendCloudMessage(AloCloudSendRequest(peerId: 8, kind: "direct", body: "~~старое~~ новое",
                                                                       clientMessageId: "cloud-client-0000001"))
        #expect(ack.messageId == 901)
        let sent = try #require(CloudURLProtocol.requests(host: host).first { $0.path == "/api/messages/send" })
        let json = CloudURLProtocol.json(sent.body)
        #expect(json["body"] as? String == "старое новое" && json["encrypted"] == nil)
        #expect((json["entities"] as? [[String: Any]])?.first?["type"] as? String == "strikethrough")
        #expect(!CloudURLProtocol.requests(host: host).contains { $0.path.hasPrefix("/api/e2ee") }, "A cloud message never asks for keys")
    }

    @Test func serverThatRequiresEncryptionAgainMakesTheNextSendAskForTheFlagsAgain() async throws {
        let host = "cloud-426.invalid"
        CloudURLProtocol.install(host: host) { request, _ in
            switch request.url?.path {
            case "/api/config": return (200, cloudConfig())
            case "/api/messages/send": return (426, ["code": "e2ee_required", "error": "Для личных сообщений включён обязательный E2EE."])
            default: return (404, [:])
            }
        }
        defer { CloudURLProtocol.remove(host: host) }
        let client = makeClient(host: host)
        #expect(await client.usesCloudMessages(kind: "direct", roomId: 0))
        do {
            _ = try await client.sendCloudMessage(AloCloudSendRequest(peerId: 8, kind: "direct", body: "x", clientMessageId: "cloud-client-0000002"))
            Issue.record("The server refused the plain message")
        } catch let error as AloAPIError { #expect(error.status == 426) }
        _ = await client.usesCloudMessages(kind: "direct", roomId: 0)
        #expect(CloudURLProtocol.requests(host: host).filter { $0.path == "/api/config" }.count == 2)
    }

    @Test func editSendsPlainTextWithFormattingToThePersonalAndGroupRoutes() async throws {
        let host = "cloud-edit.invalid"
        CloudURLProtocol.install(host: host) { _, _ in (200, ["message": ["id": 5, "editedAt": "2026-10-25T10:05:00Z"]]) }
        defer { CloudURLProtocol.remove(host: host) }
        let client = makeClient(host: host)
        let direct = AloConversationDetail(peerId: 8, json: ["peer": ["id": 8, "name": "Анна"], "items": []])
        let result = try await client.sendCloudMessageEdit(conversation: direct, messageId: 5, body: "**новый** текст", operationId: "cloud-edit-operation-1")
        #expect(result.body == "**новый** текст" && result.editedAt == "2026-10-25T10:05:00Z")
        let group = AloConversationDetail(peerId: 100_077, json: ["peer": ["id": 100_077, "name": "Группа"], "room": ["id": 77, "title": "Группа"], "items": []])
        _ = try await client.sendCloudMessageEdit(conversation: group, messageId: 6, body: "ещё", operationId: "cloud-edit-operation-2")
        let calls = CloudURLProtocol.requests(host: host)
        #expect(calls.map(\.path) == ["/api/messages/5/edit", "/api/group-chats/77/messages/6/edit"])
        let json = CloudURLProtocol.json(calls[0].body)
        #expect(json["body"] as? String == "новый текст" && json["encrypted"] == nil && json["operationId"] as? String == "cloud-edit-operation-1")
        #expect((json["entities"] as? [[String: Any]])?.first?["length"] as? Int == 5)
    }

    @Test @MainActor func recordedVoiceUploadsAsAPlainFileAndKeepsWaveformDurationAndNewExtension() async throws {
        let host = "cloud-upload.invalid"
        let sample = await AloMessengerSampleMedia.make()
        let source = try #require(sample.audio)
        let original = try Data(contentsOf: source)
        let draft = try await Task.detached {
            try AloDraftAttachmentStore.makeRecordedVoice(sourceURL: source, waveform: [0.2, 0.6], durationSeconds: 3)
        }.value
        defer { AloDraftAttachmentStore.discard(draft) }
        let lock = NSLock()
        var uploaded = Data()
        CloudURLProtocol.install(host: host) { request, body in
            if request.httpMethod == "POST" {
                let json = CloudURLProtocol.json(body)
                #expect(json["purpose"] as? String == "message")
                #expect(json["size"] as? Int == original.count)
                return (201, ["upload": ["id": "cloud-voice-upload", "offset": 0, "chunkSize": 1_048_576]])
            }
            lock.withLock { uploaded.append(body) }
            return (200, ["complete": true, "file": ["url": "/uploads/messages/17-cloud.ogg", "type": "voice", "mime": "audio/ogg"]])
        }
        defer { CloudURLProtocol.remove(host: host) }
        let attachment = try await makeClient(host: host).uploadCloudAttachment(draft)
        #expect(lock.withLock { uploaded } == original, "The server gets the real file, not ciphertext")
        #expect(attachment.type == "voice" && attachment.url == "/uploads/messages/17-cloud.ogg")
        #expect(attachment.name.hasSuffix(".ogg"), "The name follows the stored file")
        #expect(attachment.mediaEncryption.isEmpty && attachment.durationSeconds == 3 && attachment.waveform.count == 2)
    }

    @Test @MainActor func circleStaysACircleAndAHeicPhotoGoesUpAsJPEG() async throws {
        let host = "cloud-kinds.invalid"
        let sample = await AloMessengerSampleMedia.make()
        let video = try #require(sample.video)
        let circle = try await Task.detached { try AloDraftAttachmentStore.makeRecordedCircle(sourceURL: video, durationSeconds: 1) }.value
        defer { AloDraftAttachmentStore.discard(circle) }
        // The bytes are a PNG labelled HEIC: ImageIO decodes by content, as it does for a real HEIC photo.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let photo = try await Task.detached {
            try AloDraftAttachmentStore.makePickedMedia(data: try #require(image.pngData()), mime: "image/heic", type: "image", name: "media-1.heic")
        }.value
        defer { AloDraftAttachmentStore.discard(photo) }
        let lock = NSLock()
        var creates = [[String: Any]]()
        var firstBytes = [Data]()
        CloudURLProtocol.install(host: host) { request, body in
            if request.httpMethod == "POST" {
                lock.withLock { creates.append(CloudURLProtocol.json(body)) }
                return (201, ["upload": ["id": "cloud-kinds-upload", "offset": 0, "chunkSize": 1_048_576]])
            }
            lock.withLock { firstBytes.append(body.prefix(2)) }
            let count = lock.withLock { firstBytes.count }
            return (200, ["complete": true, "file": ["url": "/uploads/messages/kinds-\(count).bin", "type": count == 1 ? "video" : "image"]])
        }
        defer { CloudURLProtocol.remove(host: host) }
        let client = makeClient(host: host)
        let sentCircle = try await client.uploadCloudAttachment(circle)
        #expect(sentCircle.type == "circle", "The server calls it a video; the message keeps «circle»")
        #expect(lock.withLock { creates[0]["mime"] as? String } == "video/mp4")
        let sentPhoto = try await client.uploadCloudAttachment(photo)
        #expect(lock.withLock { creates[1]["mime"] as? String } == "image/jpeg")
        #expect(lock.withLock { firstBytes[1] } == Data([0xff, 0xd8]))
        #expect(sentPhoto.name.hasSuffix(".jpg") && sentPhoto.type == "image")
    }

    @Test func aFileOverTheServerLimitFailsBeforeAnyByteIsSent() async throws {
        let host = "cloud-big.invalid"
        CloudURLProtocol.install(host: host) { _, _ in (200, [:]) }
        defer { CloudURLProtocol.remove(host: host) }
        let big = AloLocalAttachment(data: Data(count: 26 * 1_048_576), mime: "application/pdf", type: "file", name: "big.pdf")
        do {
            _ = try await makeClient(host: host).uploadCloudAttachment(big)
            Issue.record("A 26 MB document is over the 25 MB limit")
        } catch let error as AloAPIError {
            #expect(error.code == "CLOUD_FILE_TOO_LARGE" && error.message.contains("25"))
        }
        #expect(CloudURLProtocol.requests(host: host).isEmpty)
    }
}

@Suite(.serialized)
struct AloCloudOutboxTests {
    @MainActor private func model(host: String) -> AloAppModel {
        AloAppModel(api: makeClient(host: host))
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out")
    }

    @Test @MainActor func typedTextGoesOutPlainWithFormattingAndNoKeysAreRequested() async throws {
        let host = "cloud-outbox-text.invalid"
        let owner = 1_999_971_001, peer = 1_999_971_002
        CloudURLProtocol.install(host: host) { request, _ in
            switch request.url?.path {
            case "/api/config": return (200, cloudConfig())
            case "/api/messages/send": return (200, ["message": ["id": 4_001, "createdAt": "2026-10-25T10:00:00Z"]])
            default: return (404, [:])
            }
        }
        defer { CloudURLProtocol.remove(host: host); AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner) }
        let app = model(host: host)
        app.bootstrap = AloBootstrapData(["data": ["me": ["id": owner, "name": "Я"]]])
        app.activeConversation = AloConversationDetail(peerId: peer, json: ["peer": ["id": peer, "name": "Анна"], "items": []])
        app.messageText = "**Привет**, мир"
        app.sendMessage()
        try await wait { app.activeConversation?.items.first?.id == 4_001 }
        let sent = try #require(CloudURLProtocol.requests(host: host).first { $0.path == "/api/messages/send" })
        let json = CloudURLProtocol.json(sent.body)
        #expect(json["body"] as? String == "Привет, мир" && json["encrypted"] == nil && json["peerId"] as? Int == peer)
        #expect((json["entities"] as? [[String: Any]])?.first?["type"] as? String == "bold")
        #expect(!CloudURLProtocol.requests(host: host).contains { $0.path.hasPrefix("/api/e2ee") || $0.path.hasPrefix("/api/libsignal") })
        #expect(app.pendingChatMessageIds.isEmpty && app.failedChatMessageErrors.isEmpty)
    }

    @Test @MainActor func aFailedSendStaysQueuedAsPlainTextAndGoesOutOnRetry() async throws {
        let host = "cloud-outbox-retry.invalid"
        let owner = 1_999_971_011, peer = 1_999_971_012
        let lock = NSLock()
        var online = false
        CloudURLProtocol.install(host: host) { request, _ in
            switch request.url?.path {
            case "/api/config": return (200, cloudConfig())
            case "/api/messages/send":
                if lock.withLock({ online }) { return (200, ["message": ["id": 4_011, "createdAt": "2026-10-25T10:00:00Z"]]) }
                throw URLError(.notConnectedToInternet)
            default: return (404, [:])
            }
        }
        defer { CloudURLProtocol.remove(host: host); AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner) }
        AloSecureOutboxStore.shared.clear(ownerUserId: owner)
        let app = model(host: host)
        app.bootstrap = AloBootstrapData(["data": ["me": ["id": owner, "name": "Я"]]])
        let conversation = AloConversationDetail(peerId: peer, json: ["peer": ["id": peer, "name": "Анна"], "items": []])
        app.activeConversation = conversation
        app.messageText = "__Позже__"
        app.sendMessage()
        try await wait { app.pendingSendError(in: conversation) != nil }
        await AloSecureOutboxStore.shared.finishPendingWrites()
        let record = try #require(AloSecureOutboxStore.shared.load(ownerUserId: owner).first)
        #expect(record["type"] as? String == "sendText" && record["body"] as? String == "__Позже__")
        #expect(record["encryptedPayload"] == nil, "Nothing is encrypted in advance in a cloud chat")
        lock.withLock { online = true }
        app.retryPendingMessages(in: conversation)
        try await wait { app.activeConversation?.items.first?.id == 4_011 }
        let sends = CloudURLProtocol.requests(host: host).filter { $0.path == "/api/messages/send" }
        #expect(sends.count == 2)
        #expect(CloudURLProtocol.json(sends[0].body)["clientMessageId"] as? String == CloudURLProtocol.json(sends[1].body)["clientMessageId"] as? String,
                "The retry carries the same id, so the server cannot store it twice")
    }

    @Test @MainActor func mediaIsUploadedPlainThenSentAsAttachmentsWithTheCaption() async throws {
        let host = "cloud-outbox-media.invalid"
        let owner = 1_999_971_021, peer = 1_999_971_022
        let sample = await AloMessengerSampleMedia.make()
        let source = try #require(sample.audio)
        let draft = try await Task.detached {
            try AloDraftAttachmentStore.makeRecordedVoice(sourceURL: source, waveform: [0.3, 0.7], durationSeconds: 2)
        }.value
        defer { AloDraftAttachmentStore.discard(draft) }
        CloudURLProtocol.install(host: host) { request, body in
            switch (request.url?.path ?? "", request.httpMethod ?? "") {
            case ("/api/config", _): return (200, cloudConfig())
            case ("/api/uploads/resumable", "POST"):
                #expect(CloudURLProtocol.json(body)["purpose"] as? String == "message")
                return (201, ["upload": ["id": "cloud-media-upload", "offset": 0, "chunkSize": 1_048_576]])
            case (let path, "PUT") where path.hasPrefix("/api/uploads/resumable/"):
                return (200, ["complete": true, "file": ["url": "/uploads/messages/55-voice.m4a", "type": "voice"]])
            case ("/api/messages/send", _): return (200, ["message": ["id": 4_021, "createdAt": "2026-10-25T10:00:00Z"]])
            default: return (404, [:])
            }
        }
        defer { CloudURLProtocol.remove(host: host); AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner) }
        let app = model(host: host)
        app.bootstrap = AloBootstrapData(["data": ["me": ["id": owner, "name": "Я"]]])
        app.activeConversation = AloConversationDetail(peerId: peer, json: ["peer": ["id": peer, "name": "Анна"], "items": []])
        app.messageText = "Слушай"
        app.sendMessage(localAttachments: [draft], silent: true)
        try await wait { app.activeConversation?.items.first?.id == 4_021 }
        let sent = try #require(CloudURLProtocol.requests(host: host).first { $0.path == "/api/messages/send" })
        let json = CloudURLProtocol.json(sent.body)
        let attachment = try #require((json["attachments"] as? [[String: Any]])?.first)
        #expect(json["body"] as? String == "Слушай" && json["encrypted"] == nil && json["silent"] as? Bool == true)
        #expect(attachment["type"] as? String == "voice" && attachment["url"] as? String == "/uploads/messages/55-voice.m4a")
        #expect(attachment["waveform"] as? [Double] == [0.3, 0.7] && attachment["mediaEncryption"] == nil)
        #expect((attachment["metadata"] as? [String: Any])?["durationSeconds"] as? String == "2")
    }

    @Test @MainActor func contactCardAndEditAndAPollVoteUseThePlainRoutes() async throws {
        let host = "cloud-outbox-misc.invalid"
        let owner = 1_999_971_031, peer = 1_999_971_032
        CloudURLProtocol.install(host: host) { request, _ in
            switch request.url?.path {
            case "/api/config": return (200, cloudConfig())
            case "/api/messages/send": return (200, ["message": ["id": 4_031, "createdAt": "2026-10-25T10:00:00Z"]])
            case "/api/messages/4031/edit": return (200, ["message": ["id": 4_031, "editedAt": "2026-10-25T10:02:00Z"]])
            case "/api/polls/poll-misc-1/vote":
                return (200, ["poll": ["id": "poll-misc-1", "messageId": 9, "voteCounts": ["a": 1], "selectedOptionIds": ["a"], "totalVoters": 1, "isAnonymous": true]])
            default: return (404, [:])
            }
        }
        defer { CloudURLProtocol.remove(host: host); AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner) }
        let app = model(host: host)
        app.bootstrap = AloBootstrapData(["data": ["me": ["id": owner, "name": "Я"]]])
        let poll = AloPollDefinition(id: "poll-misc-1", question: "Чай?", options: [AloPollOption(id: "a", text: "Да"), AloPollOption(id: "b", text: "Нет")],
                                     allowsMultipleAnswers: false, isQuiz: false, correctOptionIds: [], isAnonymous: true, allowsRevoting: true)
        app.activeConversation = AloConversationDetail(peerId: peer, json: [
            "peer": ["id": peer, "name": "Анна"], "items": [["id": 9, "senderId": owner, "body": try #require(AloPollCodec.encodeCreate(poll)), "entities": []]],
            "polls": [["id": "poll-misc-1", "messageId": 9, "voteCounts": ["a": 0, "b": 0], "selectedOptionIds": [], "totalVoters": 0, "isAnonymous": true]]])
        // The anonymous vote is a PUT to the server and never a chat message.
        app.voteInPoll(poll, optionIds: ["a"])
        #expect(app.activeConversation?.canonicalPolls["poll-misc-1"]?.selectedOptionIds == ["a"], "The choice shows at once")
        try await wait { CloudURLProtocol.requests(host: host).contains { $0.path == "/api/polls/poll-misc-1/vote" } }
        try await wait { app.activeConversation?.canonicalPolls["poll-misc-1"]?.totalVoters == 1 }
        let vote = try #require(CloudURLProtocol.requests(host: host).first { $0.path == "/api/polls/poll-misc-1/vote" })
        #expect(vote.method == "PUT" && CloudURLProtocol.json(vote.body)["optionIds"] as? [String] == ["a"])
        #expect(!CloudURLProtocol.requests(host: host).contains { $0.path == "/api/messages/send" })
        // A contact card travels in `attachments`.
        app.shareContact(AloEntitySummary(["id": 4, "name": "Анна", "username": "anna"]))
        try await wait { CloudURLProtocol.requests(host: host).contains { $0.path == "/api/messages/send" } }
        let card = CloudURLProtocol.json(try #require(CloudURLProtocol.requests(host: host).first { $0.path == "/api/messages/send" }).body)
        #expect((card["attachments"] as? [[String: Any]])?.first?["type"] as? String == "contact" && card["encrypted"] == nil)
        try await wait { app.activeConversation?.items.contains { $0.id == 4_031 } == true }
        // An edit keeps the formatting beside the text.
        let sentMessage = try #require(app.activeConversation?.items.first { $0.id == 4_031 })
        app.editMessage(sentMessage, body: "**исправлено**")
        try await wait { CloudURLProtocol.requests(host: host).contains { $0.path == "/api/messages/4031/edit" } }
        let edit = CloudURLProtocol.json(try #require(CloudURLProtocol.requests(host: host).first { $0.path == "/api/messages/4031/edit" }).body)
        #expect(edit["body"] as? String == "исправлено" && edit["encrypted"] == nil)
        #expect((edit["entities"] as? [[String: Any]])?.first?["type"] as? String == "bold")
    }

    @Test @MainActor func forwardingResendsTheCopyThisDeviceHolds() async throws {
        let host = "cloud-outbox-forward.invalid"
        let owner = 1_999_971_041, peer = 1_999_971_042
        CloudURLProtocol.install(host: host) { request, _ in
            switch request.url?.path {
            case "/api/config": return (200, cloudConfig())
            case "/api/messages/send": return (200, ["message": ["id": 4_041, "createdAt": "2026-10-25T10:00:00Z"]])
            default: return (404, [:])
            }
        }
        defer { CloudURLProtocol.remove(host: host); AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner) }
        let app = model(host: host)
        app.bootstrap = AloBootstrapData(["data": ["me": ["id": owner, "name": "Я"]]])
        app.activeConversation = AloConversationDetail(peerId: peer, json: ["peer": ["id": peer, "name": "Анна"], "items": []])
        let source = AloChatMessage(["id": 31, "senderId": 3, "body": "Важный текст", "entities": [["type": "italic", "offset": 0, "length": 6]],
                                     "encryptionScheme": "alo-libsignal-v1", "encryptedPayload": ["scheme": "alo-libsignal-v1"],
                                     "attachments": [["type": "location", "url": "", "name": "Москва", "metadata": ["latitude": 55.75, "longitude": 37.61]]]])
        app.pendingForwardDraft = AloForwardMeta(userId: 3, messageId: 31, user: nil, content: AloForwardContent(source))
        app.sendMessage(forwardFrom: app.pendingForwardDraft)
        try await wait { app.activeConversation?.items.first?.id == 4_041 }
        let json = CloudURLProtocol.json(try #require(CloudURLProtocol.requests(host: host).first { $0.path == "/api/messages/send" }).body)
        #expect(json["body"] as? String == "Важный текст" && json["encrypted"] == nil)
        #expect((json["entities"] as? [[String: Any]])?.first?["type"] as? String == "italic")
        #expect((json["forwardFrom"] as? [String: Int]) == ["userId": 3, "messageId": 31])
        #expect((json["attachments"] as? [[String: Any]])?.first?["type"] as? String == "location")
    }
}
