import Foundation
import Testing
@testable import AloiOS

private final class ReliabilityURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let callback = Self.lock.withLock { Self.handler }
            guard let callback, let url = request.url else { throw URLError(.unsupportedURL) }
            let (status, body) = try callback(request)
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

@Suite(.serialized)
struct AloDurableStateTests {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for durable state")
    }
    private func api() -> AloAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReliabilityURLProtocol.self]
        return AloAPIClient(baseURLs: [URL(string: "http://durable-state.invalid")!], configuration: config)
    }
    private func session(owner: Int) -> AloBootstrapData { AloBootstrapData(["data": ["me": ["id": owner, "name": "Тест"]]]) }
    private func chat(_ peer: Int) -> AloConversationDetail {
        AloConversationDetail(peerId: peer, json: ["peer": ["id": peer, "name": "Тест"], "items": []])
    }

    @Test @MainActor func perChatDraftSurvivesRecreationWithReplyForwardAndAttachment() async throws {
        let owner = 1_999_997_901
        let store = AloSecureOutboxStore.shared
        store.clear(ownerUserId: owner)
        defer { store.scheduleClear(ownerUserId: owner) }
        let first = AloAppModel(api: api())
        first.bootstrap = session(owner: owner)
        first.activeConversation = chat(421)
        first.messageText = "Отдельный **черновик**"
        first.composerReply = AloChatMessage(["id": 12, "senderId": 421, "body": "Исходное сообщение", "sender": ["id": 421, "name": "Анна"]])
        first.pendingForwardDraft = AloForwardMeta(userId: 422, messageId: 13, user: nil)
        first.pendingForwardTitle = "Переслать сообщение"
        let attachment = AloLocalAttachment(data: Data([1, 2, 3]), mime: "image/png", type: "image", name: "fixture.png")
        first.composerAttachments = [attachment]
        first.composerSelfDestructSeconds = 10
        first.activeConversation = chat(422)
        #expect(first.messageText.isEmpty && first.composerReply == nil && first.composerAttachments.isEmpty)
        first.messageText = "Второй чат"
        // Wait for initial disk merge as well as queued writes, not a guessed delay.
        try await wait { store.load(ownerUserId: owner, collection: .drafts).count == 2 }
        await store.finishPendingWrites()
        let second = AloAppModel(api: api())
        second.bootstrap = session(owner: owner)
        second.activeConversation = chat(421)
        try await wait { second.messageText == "Отдельный **черновик**" }
        #expect(second.composerReply?.id == 12 && second.composerReply?.sender?.name == "Анна")
        #expect(second.pendingForwardDraft?.messageId == 13)
        #expect(second.composerAttachments.first?.id == attachment.id)
        #expect(second.composerAttachments.first?.data == attachment.data)
        #expect(second.composerSelfDestructSeconds == 10)
        second.activeConversation = chat(422)
        #expect(second.messageText == "Второй чат")
        second.bootstrap = session(owner: owner + 1)
        try await Task.sleep(for: .milliseconds(80))
        #expect(second.messageText.isEmpty && second.composerAttachments.isEmpty)
        store.scheduleClear(ownerUserId: owner + 1)
    }

    @Test @MainActor func editingDoesNotDestroyUnsentDraft() async throws {
        let owner = 1_999_997_902
        AloSecureOutboxStore.shared.clear(ownerUserId: owner)
        let model = AloAppModel(api: api())
        model.bootstrap = session(owner: owner); model.activeConversation = chat(42)
        model.messageText = "Неотправленный текст"
        model.beginComposerEdit(); model.messageText = "Правка старого сообщения"
        model.endComposerEdit()
        #expect(model.messageText == "Неотправленный текст")
        try await wait { !AloSecureOutboxStore.shared.load(ownerUserId: owner, collection: .drafts).isEmpty }
        await AloSecureOutboxStore.shared.finishPendingWrites()
        AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner)
    }

    @Test @MainActor func publicationRecoversAfterLostAcknowledgementWithSameOperationID() async throws {
        let owner = 1_999_997_903
        let store = AloSecureOutboxStore.shared
        store.clear(ownerUserId: owner)
        let lock = NSLock()
        var ids = [String](), fail = true
        ReliabilityURLProtocol.lock.withLock {
            ReliabilityURLProtocol.handler = { request in
                guard request.url?.path == "/api/posts" else { throw URLError(.unsupportedURL) }
                let body = try ReliabilityURLProtocol.body(request)
                let id = try #require(body["clientOperationId"] as? String)
                lock.withLock { ids.append(id) }
                if lock.withLock({ fail }) { throw URLError(.networkConnectionLost) }
                return (200, ["post": ["id": 7101, "body": "Не дублировать"]])
            }
        }
        defer {
            ReliabilityURLProtocol.lock.withLock { ReliabilityURLProtocol.handler = nil }
            store.scheduleClear(ownerUserId: owner)
        }
        let first = AloPublicationQueue(api: api())
        first.activate(owner: owner)
        let id = first.enqueue(AloPublicationJob(kind: .post, body: "Не дублировать", attachments: []))
        try await wait { first.jobs.first?.status == .failed }
        await store.finishPendingWrites()
        first.reset()
        lock.withLock { fail = false }
        let restored = AloPublicationQueue(api: api())
        var published = false
        restored.onPublished = { publishedOwner, job, post in
            #expect(publishedOwner == owner && job.id == id && post?.id == 7101); published = true
        }
        restored.activate(owner: owner)
        try await wait { published }
        #expect(Set(lock.withLock { ids }) == [id])
        #expect(restored.jobs.isEmpty)
        await store.finishPendingWrites()
        #expect(store.load(ownerUserId: owner, collection: .publications).isEmpty)
        #expect(store.load(ownerUserId: owner, collection: .publicationStaging).isEmpty)
    }

    @Test func coldLaunchPushIsBufferedAndStrictlyParsed() throws {
        let suite = "alo.push.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = String(repeating: "a", count: 64)
        let first = AloPushOpenStore(defaults: defaults)
        first.enqueue(requestID: "cold-launch", payload: ["alo": ["openToken": token]])
        first.enqueue(requestID: "cold-launch", payload: ["alo": ["openToken": token]])
        let recreated = AloPushOpenStore(defaults: defaults)
        let entry = try #require(recreated.first())
        #expect(entry.token == token)
        recreated.remove(entry)
        #expect(recreated.first() == nil)
        #expect(AloPushOpenStore.token(in: ["openToken": "../api/users"]) == nil)
        #expect(AloPushDestination(["kind": "post", "postId": -1]) == nil)
        #expect(AloPushDestination(["kind": "friendRequest", "notification": ["id": 2]]) == nil)
    }

    @Test func encryptedAttachmentSurvivesPickerCleanupWithoutOverwritingMessageOutbox() async throws {
        let owner = 1_999_997_905, store = AloSecureOutboxStore.shared
        store.clear(ownerUserId: owner)
        defer { store.scheduleClear(ownerUserId: owner) }
        let source = try await Task.detached {
            try AloDraftAttachmentStore.makePickedMedia(data: Data("owned encrypted draft fixture".utf8),
                mime: "audio/mp4", type: "audio", name: "voice.m4a")
        }.value
        defer { AloDraftAttachmentStore.discard(source) }
        var draft = AloChatDraft()
        draft.text = "С вложением"
        draft.attachments = [source.withDuration(4)]
        try await store.scheduleSave(records: [["type": "sentinel"]], attachments: [], ownerUserId: owner).value
        try await store.scheduleSave(records: [draft.record(key: "direct:0:42:0")],
            attachments: [.init(id: AloDurableAttachment.fileID(source, prefix: "draft"), attachment: source)],
            ownerUserId: owner, collection: .drafts).value
        AloDraftAttachmentStore.discard(source)
        let record = try #require(store.load(ownerUserId: owner, collection: .drafts).first)
        let restored = AloChatDraft(record: record, owner: owner)
        #expect(!restored.missingAttachments && restored.attachments.count == 1)
        #expect(restored.attachments.first?.id == source.id && restored.attachments.first?.durationSeconds == 4)
        #expect(store.load(ownerUserId: owner).first?.string("type") == "sentinel")
        let preview = AloDurableAttachment.preparingPreview(try #require(restored.attachments.first))
        #expect(preview.localPlaybackURL != nil)
        // Repeated snapshots use the durable copy after the source expired.
        try await store.scheduleSave(records: [draft.record(key: "direct:0:42:0")],
            attachments: [.init(id: AloDurableAttachment.fileID(source, prefix: "draft"), attachment: source)],
            ownerUserId: owner, collection: .drafts).value
        #expect(store.load(ownerUserId: owner + 1, collection: .drafts).isEmpty)
    }

    @Test @MainActor func pushWaitsForLoginAndKeepsItsTargetWhileOffline() async throws {
        let suite = "alo.push.routing.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AloPushOpenStore(defaults: defaults)
        let token = String(repeating: "b", count: 64)
        store.enqueue(requestID: "reply", payload: ["alo": ["openToken": token]])
        let lock = NSLock()
        var offline = true
        ReliabilityURLProtocol.lock.withLock {
            ReliabilityURLProtocol.handler = { request in
                if request.url?.path.contains("/notifications/open/") == true {
                    if lock.withLock({ offline }) { return (503, ["error": "Нет связи"]) }
                    return (200, ["destination": ["kind": "post", "postId": 42, "commentId": 7]])
                }
                if request.url?.path == "/api/posts/42" { return (200, ["post": ["id": 42, "body": "Пост"]]) }
                if request.url?.path == "/api/posts/42/comments" { return (200, ["comments": []]) }
                throw URLError(.unsupportedURL)
            }
        }
        defer { ReliabilityURLProtocol.lock.withLock { ReliabilityURLProtocol.handler = nil } }
        let model = AloAppModel(api: api())
        model.phase = .auth
        await model.processPendingPushOpens(store: store)
        #expect(store.first() != nil && model.commentsPost == nil)
        let owner = 1_999_997_906
        model.bootstrap = session(owner: owner)
        model.phase = .app
        await model.processPendingPushOpens(store: store)
        #expect(store.first() != nil && model.commentsPost == nil)
        lock.withLock { offline = false }
        await model.processPendingPushOpens(store: store)
        #expect(store.first() == nil && model.commentsPost?.id == 42 && model.focusedCommentId == 7)
        model.closeComments()
        await AloSecureOutboxStore.shared.finishPendingWrites()
        AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner)
    }

    @Test @MainActor func corruptPublicationSnapshotIsNotReplacedWithAnEmptyQueue() async throws {
        let owner = 1_999_997_907, store = AloSecureOutboxStore.shared
        store.clear(ownerUserId: owner)
        defer { store.scheduleClear(ownerUserId: owner) }
        try store.save(records: [], ownerUserId: owner, collection: .publications)
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let url = root.appendingPathComponent("AloSecureOutbox/user-\(owner)/publications-v1.bin")
        let corrupt = Data("owned synthetic corruption".utf8)
        try corrupt.write(to: url, options: .atomic)
        #expect(throws: (any Error).self) { try store.loadChecked(ownerUserId: owner, collection: .publications) }
        let queue = AloPublicationQueue(api: api())
        queue.activate(owner: owner)
        try await wait { !queue.restorationError.isEmpty }
        await store.finishPendingWrites()
        #expect(try Data(contentsOf: url) == corrupt)
        queue.reset()
    }

    @Test func newStagingSnapshotPreservesUnrecoveredJobsFromPreviousProcess() async throws {
        let owner = 1_999_997_908, store = AloSecureOutboxStore.shared
        store.clear(ownerUserId: owner)
        defer { store.scheduleClear(ownerUserId: owner) }
        let first = AloPublicationJob(kind: .post, body: "До закрытия приложения", attachments: [])
        let second = AloPublicationJob(kind: .story, body: "Пока загружается очередь", attachments: [])
        try await store.scheduleSave(records: [first.record()], attachments: [], ownerUserId: owner, collection: .publicationStaging).value
        try await store.scheduleSave(records: [second.record()], attachments: [], ownerUserId: owner, collection: .publicationStaging).value
        let ids = try store.loadChecked(ownerUserId: owner, collection: .publicationStaging).map { $0.string("id") }
        #expect(Set(ids) == [first.id, second.id])
    }
}
