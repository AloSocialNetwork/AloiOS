import Foundation
import XCTest
import Testing
import CryptoKit
import UIKit
import AVFoundation
@testable import AloiOS

/// All traffic is intercepted. These tests never send to a user's server/account.
private final class SendingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (Int, [String: Any]))?

    static func install(_ handler: ((URLRequest) throws -> (Int, [String: Any]))?) {
        lock.lock(); defer { lock.unlock() }
        storedHandler = handler
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.storedHandler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.cancelled) }
            let (status, json) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    static func body(of request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

@Suite(.serialized)
struct AloMediaSendDeliveryTests {
    @Test @MainActor func publicPhotoDraftUploadsPlainJPEGNotEmptyDataOrCiphertext() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("alo-public-photo-test-\(UUID().uuidString).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        }
        try #require(image.pngData()).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let draft = try await Task.detached { try await AloFeedMediaImport.prepare(source: source, video: false) }.value
        defer { AloDraftAttachmentStore.discard(draft) }
        #expect(draft.data.isEmpty && draft.encryptedSourceURL != nil)
        #expect(draft.mime == "image/jpeg")
        SendingURLProtocol.install { request in
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: SendingURLProtocol.body(of: request)) as? [String: Any]
                #expect(body?["purpose"] as? String == "post")
                #expect(body?["mime"] as? String == "image/jpeg")
                #expect((body?["size"] as? Int ?? 0) > 0)
                return (201, ["upload": ["id": "public-photo-test", "offset": 0, "chunkSize": 65_536]])
            }
            #expect(request.httpMethod == "PUT")
            let bytes = try SendingURLProtocol.body(of: request)
            #expect(bytes.prefix(2) == Data([0xff, 0xd8]), "Server must receive a real JPEG, not encrypted bytes")
            return (200, ["complete": true, "file": ["url": "/uploads/posts/test.jpg", "type": "image"]])
        }
        defer { SendingURLProtocol.install(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SendingURLProtocol.self]
        let client = AloAPIClient(baseURLs: [URL(string: "http://public-media-test.invalid/")!], configuration: configuration)
        let uploaded = try await client.uploadAttachment(draft, purpose: "post")
        #expect(uploaded.url == "/uploads/posts/test.jpg")
        #expect(uploaded.mediaEncryption.isEmpty)
        #expect(FileManager.default.fileExists(atPath: try #require(draft.encryptedSourceURL).path), "Retry retains the private draft")
    }

    @Test @MainActor func publicVideoPreparationIsFileBackedAndCompatible() async throws {
        let sample = await AloMessengerSampleMedia.make()
        let source = try #require(sample.video)
        let draft = try await Task.detached { try await AloFeedMediaImport.prepare(source: source, video: true) }.value
        defer { AloDraftAttachmentStore.discard(draft) }
        #expect(draft.mime == "video/mp4" && draft.data.isEmpty)
        let asset = AloSecureMediaStore.shared.makeAsset(url: try #require(draft.localPlaybackURL))
        #expect(try await asset.load(.isPlayable))
    }

    @Test(arguments: ["post", "story"]) @MainActor
    func publicPublicationFailureRetainsDraftAndExplicitRetrySucceeds(kind: String) async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let bytes = try #require(image.jpegData(compressionQuality: 0.8))
        let draft = try await Task.detached {
            try AloDraftAttachmentStore.makePickedMedia(data: bytes, mime: "image/jpeg", type: "image", name: "photo.jpg")
        }.value
        defer { AloDraftAttachmentStore.discard(draft) }
        let lock = NSLock()
        var reject = true
        SendingURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path == "/api/uploads/resumable", request.httpMethod == "POST" {
                return (201, ["upload": ["id": "public-retry-test", "offset": 0, "chunkSize": 65_536]])
            }
            if path.contains("/api/uploads/resumable/"), request.httpMethod == "PUT" {
                #expect(try SendingURLProtocol.body(of: request) == bytes)
                return (200, ["complete": true, "file": ["url": "/uploads/posts/retry.jpg", "type": "image"]])
            }
            if request.httpMethod == "POST", path == "/api/posts" || path == "/api/stories" {
                let body = try JSONSerialization.jsonObject(with: SendingURLProtocol.body(of: request)) as? [String: Any]
                let media = body?["media"] as? [[String: Any]]
                #expect(media?.first?["url"] as? String == "/uploads/posts/retry.jpg")
                if lock.withLock({ reject }) {
                    return (422, ["ok": false, "code": "PUBLICATION_TEST_FAILURE", "error": "Проверочная ошибка публикации"])
                }
                let item: [String: Any] = ["id": 987, "body": "Черновик с фото", "userId": 1_999_998_790,
                    "media": media ?? [], "createdAt": "2026-10-09T12:00:00Z"]
                return (200, [kind: item])
            }
            if path == "/api/stories", request.httpMethod == "GET" { return (200, ["stories": []]) }
            throw URLError(.unsupportedURL)
        }
        defer { SendingURLProtocol.install(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SendingURLProtocol.self]
        let client = AloAPIClient(baseURLs: [URL(string: "http://public-retry-test.invalid/")!], configuration: configuration)
        let model = AloAppModel(api: client)
        model.bootstrap = AloBootstrapData(["data": ["me": ["id": 1_999_998_790, "name": "Тест"]]])
        model.composeText = "Черновик с фото"
        func publish() {
            if kind == "post" { model.createPost(localAttachments: [draft]) }
            else { model.createStory(body: "Черновик с фото", localAttachments: [draft]) }
        }
        func awaitFinish() async throws {
            for _ in 0..<200 {
                if !model.isCreatingPost && !model.isCreatingStory { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        publish()
        try await awaitFinish()
        #expect(!model.isCreatingPost && !model.isCreatingStory && !model.isBusy)
        #expect((kind == "post" ? model.postPublishingError : model.storyPublishingError) == "Проверочная ошибка публикации")
        #expect(model.lastPublishedPostId == 0 && model.composeText == "Черновик с фото")
        #expect(FileManager.default.fileExists(atPath: try #require(draft.encryptedSourceURL).path))
        lock.withLock { reject = false }
        publish()
        try await awaitFinish()
        #expect((kind == "post" ? model.postPublishingError : model.storyPublishingError).isEmpty)
        if kind == "post" { #expect(model.lastPublishedPostId == 987 && model.composeText.isEmpty) }
    }

    @Test(arguments: ["image", "video", "circle"]) @MainActor
    func mediaIsAcknowledgedWithoutWaitingForHistoryRefresh(type: String) async throws {
        let owner = 1_999_998_783
        let peer = 1_999_998_784
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        }
        let bytes = try #require(image.jpegData(compressionQuality: 0.8))
        let draft: AloLocalAttachment
        if type == "video" || type == "circle" {
            let sample = await AloMessengerSampleMedia.make()
            let source = try #require(sample.video)
            draft = try await Task.detached {
                if type == "circle" {
                    return try AloDraftAttachmentStore.makeRecordedCircle(sourceURL: source, durationSeconds: 1)
                }
                return try AloDraftAttachmentStore.makePickedVideo(sourceURL: source, mime: "video/mp4", name: "video.mp4")
            }.value
        } else {
            draft = try await Task.detached {
                try AloDraftAttachmentStore.makePickedMedia(data: bytes, mime: "image/jpeg", type: "image", name: "photo.jpg")
            }.value
        }
        let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let jwk = ["kty": "EC", "crv": "P-256", "x": base64URL(key.subdata(in: 1..<33)), "y": base64URL(key.subdata(in: 33..<65))]
        let lock = NSLock()
        var sends = 0
        SendingURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/api/e2ee/keys/") {
                return (200, ["keys": [["deviceId": "test-media-recipient", "publicKeyJwk": jwk]]])
            }
            if path == "/api/messages/send" {
                lock.lock(); sends += 1; lock.unlock()
                return (200, ["message": ["id": 777, "createdAt": "2026-10-05T12:00:00Z"]])
            }
            if path == "/api/messages/\(peer)" { throw URLError(.timedOut) }
            if request.httpMethod == "POST", path.contains("uploads") {
                return (200, ["upload": ["id": "photo-test-upload", "offset": 0, "chunkSize": 65_536]])
            }
            if request.httpMethod == "PUT", path.contains("uploads") {
                return (200, ["complete": true, "file": ["url": "/opaque-test-photo.bin"]])
            }
            throw URLError(.unsupportedURL)
        }
        defer { SendingURLProtocol.install(nil); AloDraftAttachmentStore.discard(draft) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SendingURLProtocol.self]
        let client = AloAPIClient(baseURLs: [URL(string: "http://sending-regression.invalid/")!], configuration: configuration)
        let model = AloAppModel(api: client)
        model.bootstrap = AloBootstrapData(["data": ["me": ["id": owner, "name": "Тест"]]])
        model.activeConversation = AloConversationDetail(peerId: peer, json: ["peer": ["id": peer, "name": "Тест"], "items": []])
        model.messageText = "Фото без ожидания истории"
        var composerCleared = false
        model.sendMessage(localAttachments: [draft], onSent: { composerCleared = true })
        #expect(composerCleared && !model.isBusy && model.messageText.isEmpty)
        #expect(model.activeConversation?.items.count == 1)
        #expect(model.activeConversation?.items.first?.attachments.first?.url == draft.localPlaybackURL?.absoluteString)
        for _ in 0..<200 {
            if model.activeConversation?.items.first?.id == 777 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.activeConversation?.items.first?.id == 777)
        #expect(model.pendingChatMessageIds.isEmpty)
        #expect(model.failedChatMessageErrors.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.activeConversation?.items.count == 1, "Failed reconciliation must not erase delivery")
        #expect(lock.withLock { sends } == 1, "A failed history fetch must never resend delivered media")
        await AloSecureOutboxStore.shared.finishPendingWrites()
        let deliveredURL = try #require(URL(string: model.activeConversation?.items.first?.attachments.first?.url ?? ""))
        let cachedPayload = try await Task.detached {
            try AloSecureMediaStore.shared.payload(for: deliveredURL).data
        }.value
        #expect(!cachedPayload.isEmpty, "Upload cleanup must preserve playback when history refresh fails")
        if type == "image" { #expect(cachedPayload == bytes) }
        AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner)
        await AloSecureOutboxStore.shared.finishPendingWrites()
    }

    @Test @MainActor func failedDurableSaveKeepsDraftAndDoesNotStartUpload() async throws {
        let owner = 1_999_998_786
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SendingURLProtocol.self]
        let lock = NSLock()
        var requests = 0
        SendingURLProtocol.install { _ in
            lock.withLock { requests += 1 }
            throw URLError(.unsupportedURL)
        }
        defer { SendingURLProtocol.install(nil) }
        let client = AloAPIClient(baseURLs: [URL(string: "http://sending-regression.invalid/")!], configuration: configuration)
        let model = AloAppModel(api: client)
        model.bootstrap = AloBootstrapData(["data": ["me": ["id": owner, "name": "Тест"]]])
        model.activeConversation = AloConversationDetail(peerId: 42, json: ["peer": ["id": 42, "name": "Тест"], "items": []])
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("alo-missing-test-\(UUID())")
        let draft = AloLocalAttachment(data: Data(), mime: "video/mp4", type: "video", name: "video.mp4", encryptedSourceURL: missing)
        model.sendMessage(localAttachments: [draft])
        for _ in 0..<100 {
            if !model.failedChatMessageErrors.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.activeConversation?.items.count == 1)
        #expect(model.pendingChatMessageIds.count == 1)
        #expect(model.failedChatMessageErrors.values.first?.contains("сохранить") == true)
        #expect(!model.isBusy)
        #expect(lock.withLock { requests } == 0, "Never upload before a successful durable receipt")
        AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner)
        await AloSecureOutboxStore.shared.finishPendingWrites()
    }
}

final class AloSendingRegressionTests: XCTestCase {
    override func tearDown() { SendingURLProtocol.install(nil); super.tearDown() }

    private func api() -> AloAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SendingURLProtocol.self]
        return AloAPIClient(baseURLs: [URL(string: "http://sending-regression.invalid/")!], configuration: configuration)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Operation did not settle within four seconds")
    }

    func testPreparedMessageAcknowledgesWithoutLoadingHistory() async throws {
        SendingURLProtocol.install { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/messages/send")
            let payload = try JSONSerialization.jsonObject(with: SendingURLProtocol.body(of: request)) as? [String: Any]
            XCTAssertEqual(payload?["clientMessageId"] as? String, "test-dedup-id")
            XCTAssertNil(payload?["body"], "Plaintext must not be added to the wire envelope")
            return (200, ["message": ["id": 77, "createdAt": "2026-09-25T21:00:00Z"]])
        }
        let ack = try await api().sendPreparedMessage(peerId: 42, roomId: 0, kind: "direct",
            encryptedPayload: ["version": "test"], clientMessageId: "test-dedup-id")
        XCTAssertEqual(ack.messageId, 77)
    }

    func testPermanentUploadErrorIsNotRetried() async throws {
        let lock = NSLock()
        var puts = 0
        SendingURLProtocol.install { request in
            if request.httpMethod == "POST" {
                return (200, ["upload": ["id": "test-upload", "offset": 0, "chunkSize": 65_536]])
            }
            XCTAssertEqual(request.httpMethod, "PUT", "A rejected file must not trigger status/retry requests")
            lock.lock(); puts += 1; lock.unlock()
            return (413, ["code": "BAD_UPLOAD_SIZE", "error": "Файл слишком большой"])
        }
        do {
            _ = try await api().uploadAttachment(AloLocalAttachment(data: Data([1, 2, 3]), mime: "image/jpeg", type: "image", name: "test.jpg"))
            XCTFail("Expected the server's rejection")
        } catch let error as AloAPIError {
            XCTAssertEqual(error.status, 413)
        }
        XCTAssertEqual(puts, 1)
    }

    func testEmptySuccessResponseCannotDiscardAnOutgoingMessageOrStory() async throws {
        SendingURLProtocol.install { _ in (200, [:]) }
        let client = api()
        do {
            _ = try await client.sendPreparedMessage(peerId: 42, roomId: 0, kind: "direct",
                encryptedPayload: ["version": "test"], clientMessageId: "test-dedup-id")
            XCTFail("An empty HTTP 200 is not delivery confirmation")
        } catch let error as AloAPIError { XCTAssertEqual(error.code, "MESSAGE_ACK_INVALID") }
        do {
            _ = try await client.createStory(body: "Тест")
            XCTFail("An empty HTTP 200 is not publication confirmation")
        } catch let error as AloAPIError { XCTAssertEqual(error.code, "STORY_ACK_INVALID") }
    }

    func testUploadRecoversLostAcknowledgementWithoutDuplicatingChunk() async throws {
        SendingURLProtocol.install { request in
            switch request.httpMethod {
            case "POST": return (200, ["upload": ["id": "test-upload", "offset": 0, "chunkSize": 65_536]])
            case "PUT": throw URLError(.networkConnectionLost)
            default:
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, ["upload": ["complete": true, "file": ["url": "/test-upload.jpg", "type": "image"]]])
            }
        }
        let result = try await api().uploadAttachment(AloLocalAttachment(data: Data([1, 2, 3]), mime: "image/jpeg", type: "image", name: "test.jpg"))
        XCTAssertEqual(result.url, "/test-upload.jpg")
    }

    @MainActor func testRecordedVoiceUsesFileUploadAndKeepsDuration() async throws {
        let sample = await AloMessengerSampleMedia.make()
        let source = try XCTUnwrap(sample.audio)
        let draft = try await Task.detached {
            try AloDraftAttachmentStore.makeRecordedVoice(sourceURL: source, waveform: [0.2, 0.6], durationSeconds: 3)
        }.value
        defer { AloDraftAttachmentStore.discard(draft) }
        XCTAssertTrue(draft.data.isEmpty)
        XCTAssertNotNil(draft.encryptedSourceURL)
        SendingURLProtocol.install { request in
            if request.httpMethod == "POST" {
                let payload = try JSONSerialization.jsonObject(with: SendingURLProtocol.body(of: request)) as? [String: Any]
                XCTAssertEqual(payload?["purpose"] as? String, "message_e2ee")
                XCTAssertGreaterThan(payload?["size"] as? Int ?? 0, 0)
                return (200, ["upload": ["id": "voice-upload", "offset": 0, "chunkSize": 65_536]])
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            let range = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Range"))
            let numbers = range.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            XCTAssertEqual(numbers.count, 3)
            guard numbers.count == 3 else { throw URLError(.badServerResponse) }
            if numbers[1] + 1 == numbers[2] {
                return (200, ["complete": true, "file": ["url": "/voice-opaque.bin"]])
            }
            return (200, ["upload": ["offset": numbers[1] + 1]])
        }
        let result = try await api().uploadE2EEAttachment(draft)
        XCTAssertEqual(result.url, "/voice-opaque.bin")
        XCTAssertEqual(result.durationSeconds, 3)
        XCTAssertFalse(result.mediaEncryption.isEmpty)
    }

    @MainActor func testStoryFailureStopsSpinnerAndKeepsUsefulError() async throws {
        SendingURLProtocol.install { _ in throw URLError(.timedOut) }
        let model = AloAppModel(api: api())
        model.createStory(body: "Не терять текст")
        XCTAssertTrue(model.isCreatingStory)
        try await waitUntil { !model.isCreatingStory }
        XCTAssertTrue(model.storyPublishingError.contains("сервер"))
        SendingURLProtocol.install { request in
            if request.httpMethod == "POST" { return (200, ["story": ["id": 9, "body": "Не терять текст"]]) }
            return (200, ["stories": []])
        }
        model.createStory(body: "Не терять текст")
        try await waitUntil { !model.isCreatingStory && !model.isStoriesLoading }
        XCTAssertEqual(model.storyPublishingError, "")
    }

    @MainActor func testFailedSendRetainsMessageAndAllowsExplicitRetry() async throws {
        SendingURLProtocol.install { _ in (403, ["code": "TEST_REJECTED", "error": "Доставка запрещена тестовым сервером"]) }
        let model = AloAppModel(api: api())
        model.bootstrap = AloBootstrapData(["data": ["me": ["id": 1_999_998_771, "name": "Тест"]]])
        let conversation = AloConversationDetail(peerId: 42, json: ["peer": ["id": 42, "name": "Собеседник"], "items": []])
        model.activeConversation = conversation
        model.messageText = "Сохранённый текст"
        model.sendMessage()
        try await waitUntil { model.pendingSendError(in: conversation) != nil }
        XCTAssertEqual(model.activeConversation?.items.first?.body, "Сохранённый текст")
        XCTAssertEqual(model.pendingChatMessageIds.count, 1)
        let id = try XCTUnwrap(model.activeConversation?.items.first?.id)
        model.retryPendingMessages(in: conversation)
        try await waitUntil { model.failedChatMessageErrors[id] != nil }
        XCTAssertEqual(model.activeConversation?.items.count, 1, "Retry must not insert a duplicate")
        XCTAssertFalse(model.isBusy)
    }

    @MainActor func testVoiceTitleUsesSenderNotOpaqueAttachmentFilename() {
        let model = AloAppModel(api: api())
        model.bootstrap = AloBootstrapData(["data": ["me": ["id": 1, "name": "Михаил"]]])
        let incoming = AloChatMessage(["id": 7, "senderId": 2, "sender": ["id": 2, "name": "Александр"],
            "attachments": [["type": "audio", "name": "d9287a71-blob.m4a"]]])
        XCTAssertEqual(model.voicePlaybackTitle(for: incoming), "Александр")
        XCTAssertEqual(model.voicePlaybackTitle(for: AloChatMessage(["senderId": 1])), "Михаил")
        XCTAssertEqual(model.voicePlaybackTitle(for: AloChatMessage(["senderId": 2])), "Голосовое сообщение")
        XCTAssertEqual(model.voicePlaybackTitle(for: AloChatMessage(["senderId": 2, "senderIsAnonymous": true])), "Анонимный участник")
    }

    @MainActor func testClosedQuizRemainsCardAndTechnicalEventsNeverBecomeText() throws {
        let quiz = AloPollDefinition(id: "quiz_regression", question: "Выберите ответ",
            options: [AloPollOption(id: "a", text: "Первый"), AloPollOption(id: "b", text: "Второй")],
            allowsMultipleAnswers: false, isQuiz: true, correctOptionIds: ["b"], isAnonymous: false, allowsRevoting: false)
        let prepared = try XCTUnwrap(AloPollQuizCommitment.prepare(quiz))
        let create = try XCTUnwrap(AloPollCodec.encodeCreate(prepared.definition))
        let reveal = try XCTUnwrap(AloPollCodec.encodeReveal(pollId: quiz.id, correctOptionIds: ["b"], salt: prepared.salt))
        let messages = [AloChatMessage(["id": 1, "senderId": 1, "body": create]),
                        AloChatMessage(["id": 2, "senderId": 1, "body": reveal])]
        XCTAssertEqual(AloPollProjection.visibleMessages(messages).map(\.id), [1])
        let projected = AloPollProjection.states(messages: messages, currentUserId: 1)
        let closed = AloPollProjection.applyingCanonical([quiz.id: AloCanonicalPollState([
            "id": quiz.id, "messageId": 1, "isClosed": true
        ])], to: projected)
        let closedState = try XCTUnwrap(closed[quiz.id])
        XCTAssertTrue(closedState.isClosed)
        XCTAssertEqual(closedState.correctOptionIds, ["b"])
        XCTAssertEqual(AloPollCodec.previewText(for: reveal), "Опрос завершён")
        XCTAssertEqual(AloRichMessageText.attributedBody(reveal, entities: []).string, "Опрос завершён")
        XCTAssertEqual(AloRichMessageText.attributedBody("alo.poll.v1:broken", entities: []).string, "Опрос недоступен")
        XCTAssertNil(AloPollCodec.previewText(for: "Обычное сообщение"))
    }

    func testRetryPolicyRejectsCancellationAndPermanentErrors() {
        XCTAssertFalse(AloAPIClient.shouldRetryUpload(CancellationError()))
        XCTAssertFalse(AloAPIClient.shouldRetryUpload(URLError(.cancelled)))
        XCTAssertFalse(AloAPIClient.shouldRetryUpload(AloAPIError(status: 422, code: "UPLOAD_CHECKSUM_MISMATCH", message: "", payload: [:])))
        XCTAssertTrue(AloAPIClient.shouldRetryUpload(URLError(.timedOut)))
        XCTAssertTrue(AloAPIClient.shouldRetryUpload(AloAPIError(status: 409, code: "UPLOAD_OFFSET_MISMATCH", message: "", payload: [:])))
    }
}
