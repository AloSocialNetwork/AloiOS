import XCTest
@testable import AloiOS

/// The client side of translation and voice transcription: the request is what the server expects (see
/// docs/chat-content-tools-setup.md), results are kept per account, and nothing leaves before consent.
private final class ContentToolsURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [(path: String, method: String, body: [String: Any])] = []
    nonisolated(unsafe) static var replies: [String: (status: Int, json: [String: Any])] = [:]

    static func reset() { lock.withLock { requests = []; replies = [:] } }
    static func reply(_ path: String, status: Int = 200, _ json: [String: Any]) { lock.withLock { replies[path] = (status, json) } }
    static var last: (path: String, method: String, body: [String: Any])? { lock.withLock { requests.last } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            stream.close()
            data = collected
        }
        let body = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let path = request.url?.path ?? ""
        let reply = Self.lock.withLock { () -> (status: Int, json: [String: Any]) in
            Self.requests.append((path, request.httpMethod ?? "", body))
            return Self.replies[path] ?? (404, ["ok": false])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FakeContentTransport: AloContentToolsTransport {
    var needsAudio = true
    var translated = [(id: Int, text: String, target: String)]()
    var transcribed = [(id: Int, bytes: Int, mime: String)]()
    var failure: Error?
    func capabilities() async throws -> AloContentToolsCapabilities { AloContentToolsCapabilities(translation: true, transcription: true) }
    func translate(conversation: AloConversationDetail, messageId: Int, text: String, target: String) async throws -> AloMessageTranslation {
        translated.append((messageId, text, target))
        if let failure { throw failure }
        return AloMessageTranslation(["text": "EN: \(text)", "sourceLanguage": "ru", "targetLanguage": target])
    }
    func transcribe(conversation: AloConversationDetail, messageId: Int, audio: Data, mimeType: String,
                    attachmentId: String) async throws -> AloVoiceTranscription {
        transcribed.append((messageId, audio.count, mimeType))
        if let failure { throw failure }
        return AloVoiceTranscription(["text": "привет, это проверка", "language": "ru"])
    }
}

final class AloContentToolsTests: XCTestCase {
    private func api() -> AloAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContentToolsURLProtocol.self]
        return AloAPIClient(baseURLs: [URL(string: "http://content-tools.invalid/")!], configuration: config)
    }

    private var direct: AloConversationDetail {
        AloConversationDetail(peerId: 42, json: ["peer": ["id": 42, "name": "Тест"], "items": []])
    }

    private func group(protected: Bool = false) -> AloConversationDetail {
        AloConversationDetail(peerId: 77, json: [
            "peer": ["id": 77, "name": "Семья"],
            "room": ["id": 77, "policy": ["kind": "group", "protectedContent": protected]],
            "items": []
        ])
    }

    private let languages = [AloContentLanguage(code: "ru", name: "Русский", english: "Russian"),
                             AloContentLanguage(code: "en", name: "English", english: "English")]

    override func setUp() {
        ContentToolsURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: AloContentToolsStore.consentKey)
        UserDefaults.standard.removeObject(forKey: AloContentToolsStore.languageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AloContentToolsStore.consentKey)
        UserDefaults.standard.removeObject(forKey: AloContentToolsStore.languageKey)
    }

    // MARK: Requests

    func testTheConfigSaysWhichToolsExistAndAnEmptyOneMeansOff() {
        let on = AloContentToolsCapabilities([
            "translation": true, "transcription": false, "maxAudioBytes": 1_048_576,
            "languages": [["code": "ru", "name": "Русский", "english": "Russian"], ["code": "", "name": "bad"]]
        ])
        XCTAssertTrue(on.translation)
        XCTAssertFalse(on.transcription)
        XCTAssertEqual(on.maxAudioBytes, 1_048_576)
        XCTAssertEqual(on.languages, [AloContentLanguage(code: "ru", name: "Русский", english: "Russian")])
        let off = AloContentToolsCapabilities([:])
        XCTAssertFalse(off.translation)
        XCTAssertFalse(off.transcription)
        XCTAssertGreaterThan(off.maxAudioBytes, 0)
    }

    func testCapabilitiesComeFromTheContentToolsOfTheConfig() async throws {
        ContentToolsURLProtocol.reply("/api/config", ["contentTools": ["translation": true, "transcription": true,
            "languages": [["code": "en", "name": "English", "english": "English"]]]])
        let result = try await api().loadContentTools()
        XCTAssertTrue(result.translation && result.transcription)
        XCTAssertEqual(result.languages.map(\.code), ["en"])
        XCTAssertEqual(ContentToolsURLProtocol.last?.method, "GET")
    }

    func testTranslationRequestCarriesConsentAndTheTextOfOneMessage() async throws {
        ContentToolsURLProtocol.reply("/api/messages/55/translate", ["ok": true, "translation": [
            "messageId": 55, "text": "Hello", "sourceLanguage": "ru", "targetLanguage": "en"]])
        let result = try await api().translateMessage(conversation: direct, messageId: 55, text: "Привет", targetLanguage: "en")
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(result.targetLanguage, "en")
        let sent = try XCTUnwrap(ContentToolsURLProtocol.last)
        XCTAssertEqual(sent.path, "/api/messages/55/translate")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.body["consent"] as? Bool, true)
        XCTAssertEqual(sent.body["text"] as? String, "Привет")
        XCTAssertEqual(sent.body["sourceLanguage"] as? String, "auto")
        XCTAssertEqual(sent.body["targetLanguage"] as? String, "en")
        XCTAssertEqual(sent.body["chatKind"] as? String, "direct")
    }

    func testAGroupMessageIsTranslatedThroughItsRoom() async throws {
        ContentToolsURLProtocol.reply("/api/group-chats/77/messages/9/translate", ["ok": true, "translation": ["text": "Hi"]])
        _ = try await api().translateMessage(conversation: group(), messageId: 9, text: "Привет", targetLanguage: "en")
        let sent = try XCTUnwrap(ContentToolsURLProtocol.last)
        XCTAssertEqual(sent.path, "/api/group-chats/77/messages/9/translate")
        XCTAssertEqual(sent.body["chatKind"] as? String, "group")
    }

    func testTranscriptionRequestCarriesTheDecryptedAudioAsBase64() async throws {
        ContentToolsURLProtocol.reply("/api/messages/55/transcribe", ["ok": true, "transcription": [
            "messageId": 55, "text": "привет", "language": "ru", "confidence": 0.9]])
        let audio = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x01, 0x02])
        let result = try await api().transcribeVoiceMessage(conversation: direct, messageId: 55, audio: audio,
                                                            mimeType: "audio/mp4", attachmentId: "voice-1")
        XCTAssertEqual(result.text, "привет")
        XCTAssertEqual(result.language, "ru")
        XCTAssertEqual(result.confidence, 0.9, accuracy: 0.001)
        let sent = try XCTUnwrap(ContentToolsURLProtocol.last)
        XCTAssertEqual(sent.path, "/api/messages/55/transcribe")
        XCTAssertEqual(sent.body["consent"] as? Bool, true)
        XCTAssertEqual(Data(base64Encoded: sent.body["audioBase64"] as? String ?? ""), audio)
        XCTAssertEqual(sent.body["mimeType"] as? String, "audio/mp4")
        XCTAssertEqual(sent.body["language"] as? String, "auto")
        XCTAssertEqual(sent.body["attachmentId"] as? String, "voice-1")
    }

    func testAGroupVoiceMessageIsTranscribedThroughItsRoom() async throws {
        ContentToolsURLProtocol.reply("/api/group-chats/77/messages/9/transcribe", ["ok": true, "transcription": ["text": "ok"]])
        _ = try await api().transcribeVoiceMessage(conversation: group(), messageId: 9, audio: Data([1]), mimeType: "audio/ogg")
        XCTAssertEqual(ContentToolsURLProtocol.last?.path, "/api/group-chats/77/messages/9/transcribe")
    }

    func testServerAnswersBecomeShortRussianLines() async {
        func message(_ status: Int, _ code: String, translating: Bool = true) async -> String {
            ContentToolsURLProtocol.reply("/api/messages/1/translate", status: status, ["ok": false, "code": code, "error": "server text"])
            do {
                _ = try await api().translateMessage(conversation: direct, messageId: 1, text: "a", targetLanguage: "en")
                return ""
            } catch {
                return AloContentToolsMessage.text(for: error, translating: translating)
            }
        }
        let unavailable = await message(503, "translation_unavailable")
        XCTAssertEqual(unavailable, "Перевод не подключён на сервере.")
        let limited = await message(429, "RATE_LIMITED")
        XCTAssertEqual(limited, "Слишком много запросов. Попробуйте позже.")
        let provider = await message(502, "message_translation_provider_failed")
        XCTAssertEqual(provider, "Сервис временно недоступен. Попробуйте позже.")
        XCTAssertEqual(AloContentToolsMessage.text(for: AloContentToolsError.audioTooLarge, translating: false), "Запись слишком длинная для расшифровки.")
        XCTAssertEqual(AloContentToolsMessage.text(for: AloContentToolsError.noAudio, translating: false), "В этом сообщении нет звука.")
    }

    func testAudioTypesAreOnesTheServerKnows() {
        XCTAssertEqual(AloContentAudio.mimeType("audio/x-m4a", name: "voice.m4a", isCircle: false), "audio/mp4")
        XCTAssertEqual(AloContentAudio.mimeType("audio/ogg; codecs=opus", name: "a", isCircle: false), "audio/ogg")
        XCTAssertEqual(AloContentAudio.mimeType("", name: "voice-1.m4a", isCircle: false), "audio/mp4")
        XCTAssertEqual(AloContentAudio.mimeType("", name: "clip.mov", isCircle: true), "video/quicktime")
        XCTAssertEqual(AloContentAudio.mimeType("video/mp4", name: "circle.mp4", isCircle: true), "video/mp4")
        XCTAssertEqual(AloContentAudio.mimeType("application/octet-stream", name: "unknown", isCircle: true), "video/mp4")
    }

    // MARK: The store

    @MainActor private func store(_ transport: FakeContentTransport, translation: Bool = true, transcription: Bool = true) -> AloContentToolsStore {
        let store = AloContentToolsStore(transport: transport)
        store.audioLoader = { _, _ in (Data("voice".utf8), "audio/mp4") }
        store.apply(capabilities: AloContentToolsCapabilities(translation: translation, transcription: transcription, languages: languages))
        store.accountChanged(0)
        return store
    }

    @MainActor private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the store")
    }

    private let message = AloChatMessage(["id": 55, "body": "Привет, как дела?", "senderId": 2])
    private let voice = AloMessageAttachment(["type": "voice", "url": "file:///v.m4a", "name": "voice-1.m4a"])

    @MainActor func testNothingIsSentUntilThePersonAgrees() async throws {
        let transport = FakeContentTransport()
        let store = store(transport)
        store.translate(message: message, conversation: direct, to: languages[1])
        XCTAssertNotNil(store.consentRequest, "the first request asks")
        XCTAssertEqual(store.consentRequest?.topic, .translation)
        XCTAssertTrue(transport.translated.isEmpty)
        store.declineConsent()
        XCTAssertNil(store.consentRequest)
        XCTAssertTrue(transport.translated.isEmpty)
        XCTAssertNil(store.shownTranslation(55))

        store.translate(message: message, conversation: direct, to: languages[1])
        store.confirmConsent()
        XCTAssertTrue(store.hasConsent)
        try await eventually { if case .ready? = store.shownTranslation(55)?.phase { return true } else { return false } }
        XCTAssertEqual(transport.translated.count, 1)
        XCTAssertEqual(transport.translated.first?.text, "Привет, как дела?")
        XCTAssertEqual(transport.translated.first?.target, "en")
        XCTAssertEqual(store.lastTargetLanguage, "en")

        // Consent is remembered: the next one goes straight out, and a cached language is not asked for again.
        store.hideTranslation(55)
        XCTAssertNil(store.shownTranslation(55))
        store.translate(message: message, conversation: direct, to: languages[1])
        XCTAssertEqual(transport.translated.count, 1, "the saved translation comes back without a request")
        if case .ready(let shown)? = store.shownTranslation(55)?.phase { XCTAssertEqual(shown.text, "EN: Привет, как дела?") } else { XCTFail("translation shown") }
        store.translate(message: message, conversation: direct, to: languages[0])
        XCTAssertNil(store.consentRequest)
        try await eventually { transport.translated.count == 2 }
    }

    @MainActor func testATranscriptOpensFoldsAndComesBack() async throws {
        let transport = FakeContentTransport()
        let store = store(transport)
        store.toggleTranscript(message: message, attachment: voice, conversation: direct)
        XCTAssertEqual(store.consentRequest?.topic, .transcription)
        store.confirmConsent()
        try await eventually { if case .ready? = store.transcriptPhase(55) { return true } else { return false } }
        XCTAssertTrue(store.isTranscriptExpanded(55))
        XCTAssertEqual(transport.transcribed.first?.mime, "audio/mp4")
        XCTAssertEqual(transport.transcribed.first?.bytes, 5)

        store.toggleTranscript(message: message, attachment: voice, conversation: direct)
        XCTAssertFalse(store.isTranscriptExpanded(55))
        store.toggleTranscript(message: message, attachment: voice, conversation: direct)
        XCTAssertTrue(store.isTranscriptExpanded(55))
        XCTAssertEqual(transport.transcribed.count, 1, "folding and unfolding asks the server nothing")
    }

    @MainActor func testAFailureShowsAShortLineAndALaterTapTriesAgain() async throws {
        let transport = FakeContentTransport()
        transport.failure = AloAPIError(status: 503, code: "transcription_unavailable", message: "x", payload: [:])
        let store = store(transport)
        store.setConsent(true)
        store.toggleTranscript(message: message, attachment: voice, conversation: direct)
        try await eventually { if case .failed? = store.transcriptPhase(55) { return true } else { return false } }
        guard case .failed(let line)? = store.transcriptPhase(55) else { return XCTFail("a failure") }
        XCTAssertEqual(line, "Расшифровка не подключена на сервере.")
        transport.failure = nil
        store.toggleTranscript(message: message, attachment: voice, conversation: direct)
        try await eventually { if case .ready? = store.transcriptPhase(55) { return true } else { return false } }
    }

    @MainActor func testToolsAreOffWhereTheServerOrTheChatDoesNotAllowThem() {
        let transport = FakeContentTransport()
        let on = store(transport)
        XCTAssertTrue(on.canTranslate(message, in: direct))
        XCTAssertTrue(on.canTranscribe(message, in: direct))
        XCTAssertFalse(on.canTranslate(message, in: group(protected: true)), "a chat that forbids copying keeps its text")
        XCTAssertFalse(on.canTranscribe(message, in: group(protected: true)))
        XCTAssertTrue(on.canTranslate(message, in: group()))
        XCTAssertFalse(on.canTranslate(AloChatMessage(["id": 55, "body": "  "]), in: direct), "no text, nothing to translate")
        XCTAssertFalse(on.canTranslate(AloChatMessage(["id": -3, "body": "Привет"]), in: direct), "a message not yet delivered")
        XCTAssertFalse(on.canTranscribe(AloChatMessage(["id": 55, "selfDestructSeconds": 10]), in: direct), "disappearing media stays untouched")
        let off = store(transport, translation: false, transcription: false)
        XCTAssertFalse(off.canTranslate(message, in: direct))
        XCTAssertFalse(off.canTranscribe(message, in: direct))
    }

    @MainActor func testResultsAreKeptPerAccountAndCanBeForgotten() async throws {
        let owner = 990_777
        let transport = FakeContentTransport()
        let first = store(transport)
        first.setConsent(true)
        first.accountChanged(owner)
        first.removeSavedResults()
        first.translate(message: message, conversation: direct, to: languages[1])
        first.toggleTranscript(message: message, attachment: voice, conversation: direct)
        try await eventually {
            if case .ready? = first.shownTranslation(55)?.phase, case .ready? = first.transcriptPhase(55) { return true }
            return false
        }
        first.toggleTranscript(message: message, attachment: voice, conversation: direct) // fold it
        try await Task.sleep(for: .milliseconds(900))

        let second = store(FakeContentTransport())
        second.accountChanged(owner)
        if case .ready(let translation)? = second.shownTranslation(55)?.phase {
            XCTAssertEqual(translation.text, "EN: Привет, как дела?")
        } else { XCTFail("the translation is back after a restart") }
        guard case .ready(let transcript)? = second.transcriptPhase(55) else { return XCTFail("the transcript is back") }
        XCTAssertEqual(transcript.text, "привет, это проверка")
        XCTAssertFalse(second.isTranscriptExpanded(55), "a folded transcript stays folded")

        let stranger = store(FakeContentTransport())
        stranger.accountChanged(owner + 1)
        XCTAssertNil(stranger.transcriptPhase(55), "another account sees none of it")

        second.removeSavedResults()
        let third = store(FakeContentTransport())
        third.accountChanged(owner)
        XCTAssertNil(third.transcriptPhase(55))
        XCTAssertNil(third.shownTranslation(55))
    }

    @MainActor func testThePickerOffersTheLastLanguageFirst() {
        let store = store(FakeContentTransport())
        XCTAssertEqual(store.orderedLanguages().map(\.code), ["ru", "en"])
        store.translate(message: message, conversation: direct, to: languages[1])
        store.declineConsent()
        XCTAssertEqual(store.orderedLanguages().map(\.code), ["en", "ru"])
        XCTAssertEqual(store.languageName("en"), "English")
    }
}
