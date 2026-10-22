import CryptoKit
import Foundation
import Testing
@testable import AloiOS

/// Responses are released explicitly, so navigation happens during the request,
/// not during an arbitrary sleep. All traffic remains inside this protocol.
private final class CompletionURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((CompletionURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        handler(self)
    }
    override func stopLoading() {}
    func respond(_ json: [String: Any], status: Int = 200) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]),
              let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class CompletionRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CompletionURLProtocol?
    var received: Bool { lock.withLock { pending != nil } }
    func hold(_ request: CompletionURLProtocol) { lock.withLock { pending = request } }
    func release(_ json: [String: Any]) {
        let request = lock.withLock { let value = pending; pending = nil; return value }
        request?.respond(json)
    }
}

@Suite(.serialized)
struct AloAsyncCompletionRegressionTests {
    private func api() -> AloAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompletionURLProtocol.self]
        return AloAPIClient(baseURLs: [URL(string: "http://async-completion.invalid/")!], configuration: config)
    }
    private func session(_ owner: Int) -> AloBootstrapData {
        AloBootstrapData(["data": ["me": ["id": owner, "name": "Тест"]]])
    }
    private func chat(_ peer: Int) -> AloConversationDetail {
        AloConversationDetail(peerId: peer, json: ["peer": ["id": peer, "name": "Тест"], "items": []])
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Timed out waiting for the controlled request")
    }
    private func recipientKey() -> [String: String] {
        let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        func encoded(_ bytes: Data) -> String {
            bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return ["kty": "EC", "crv": "P-256", "x": encoded(key.subdata(in: 1..<33)), "y": encoded(key.subdata(in: 33..<65))]
    }

    @Test(arguments: ["otherChat", "editedDraft", "otherAccount", "unchanged"])
    @MainActor func disappearingMediaCompletionOnlyConsumesItsOriginalDraft(change: String) async throws {
        let fixture = ["otherChat", "editedDraft", "otherAccount", "unchanged"].firstIndex(of: change) ?? 0
        let owner = 1_999_996_801 + fixture * 10, peer = 990_801 + fixture
        let store = AloSecureOutboxStore.shared
        store.clear(ownerUserId: owner); store.clear(ownerUserId: owner + 1)
        let gate = CompletionRequestGate(), key = recipientKey()
        CompletionURLProtocol.lock.withLock {
            CompletionURLProtocol.handler = { request in
                let path = request.request.url?.path ?? ""
                if path == "/api/messages/send" { gate.hold(request); return }
                if path.hasPrefix("/api/e2ee/keys/") {
                    request.respond(["keys": [["deviceId": "async-fixture-recipient", "publicKeyJwk": key]]]); return
                }
                if request.request.httpMethod == "POST", path.contains("uploads") {
                    request.respond(["upload": ["id": "async-fixture-upload", "offset": 0, "chunkSize": 65_536]]); return
                }
                if request.request.httpMethod == "PUT", path.contains("uploads") {
                    request.respond(["complete": true, "file": ["url": "/async-fixture-opaque.bin"]]); return
                }
                // Reconciliation may fail after ACK without undoing delivery.
                request.respond(["error": "History unavailable"], status: 503)
            }
        }
        let model = AloAppModel(api: api())
        defer {
            CompletionURLProtocol.lock.withLock { CompletionURLProtocol.handler = nil }
            model.publications.reset()
            store.scheduleClear(ownerUserId: owner); store.scheduleClear(ownerUserId: owner + 1)
        }
        model.bootstrap = session(owner); model.activeConversation = chat(peer)
        model.messageText = "Подпись исчезающего фото"
        let attachment = AloLocalAttachment(data: Data([1, 2, 3]), mime: "image/jpeg", type: "image", name: "fixture.jpg")
        model.composerAttachments = [attachment]
        model.composerSelfDestructSeconds = 10
        var completed = false
        let task = try #require(model.sendMessage(localAttachments: [attachment], selfDestructSeconds: 10) {
            completed = true
        })
        try await wait { gate.received }
        if change == "otherChat" { model.activeConversation = chat(peer + 1) }
        if change == "otherAccount" {
            model.bootstrap = session(owner + 1)
            model.activeConversation = chat(peer + 1)
            model.isBusy = false // The new account's own bootstrap has completed.
        }
        if change != "unchanged" {
            model.messageText = "Новый черновик"
            model.composerReply = AloChatMessage(["id": 81, "body": "Ответить сюда"])
            model.composerAttachments = [AloLocalAttachment(data: Data([4]), mime: "image/png", type: "image", name: "new.png")]
            model.composerSelfDestructSeconds = 20
        }
        gate.release(["message": ["id": 771, "createdAt": "2026-10-20T12:00:00Z"]])
        await task.value
        if change == "unchanged" {
            #expect(completed && model.messageText.isEmpty && model.composerAttachments.isEmpty)
            #expect(model.composerSelfDestructSeconds == 0)
        } else {
            #expect(!completed)
            #expect(model.messageText == "Новый черновик" && model.composerReply?.id == 81)
            #expect(model.composerAttachments.first?.name == "new.png" && model.composerSelfDestructSeconds == 20)
        }
        #expect(model.activeConversation?.peerId == (change == "otherChat" || change == "otherAccount" ? peer + 1 : peer))
        #expect(!model.isBusy && model.errorMessage.isEmpty)
        if change == "otherChat" {
            model.activeConversation = chat(peer)
            #expect(model.messageText.isEmpty && model.composerAttachments.isEmpty, "The sent chat must not restore the consumed draft")
        }
    }

    @Test(arguments: [AloPublicationJob.Kind.post, .story])
    @MainActor func oldPublicationCallbackCannotMutateTheNewAccount(kind: AloPublicationJob.Kind) throws {
        let owner = kind == .post ? 1_999_996_803 : 1_999_996_813
        let model = AloAppModel(api: api())
        model.bootstrap = session(owner)
        let completion = try #require(model.publications.onPublished)
        model.bootstrap = session(owner + 1)
        model.composeText = "Пост другого аккаунта"
        defer {
            model.publications.reset()
            AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner)
            AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner + 1)
        }
        completion(owner, AloPublicationJob(kind: kind, body: "Старый пост", attachments: []),
            kind == .post ? AloPost(["id": 991, "body": "Старый пост"]) : nil)
        #expect(model.bootstrap?.me.id == owner + 1)
        #expect(model.bootstrap?.feedPopular.isEmpty == true && model.bootstrap?.feedSubscriptions.isEmpty == true)
        #expect(model.composeText == "Пост другого аккаунта" && model.lastPublishedPostId == 0)
    }

    @Test(arguments: [AloPublicationJob.Kind.post, .story])
    @MainActor func switchingAccountDuringPublicationAcknowledgementSuppressesTheCallback(kind: AloPublicationJob.Kind) async throws {
        let owner = kind == .post ? 1_999_996_843 : 1_999_996_853
        let store = AloSecureOutboxStore.shared
        store.clear(ownerUserId: owner); store.clear(ownerUserId: owner + 1)
        CompletionURLProtocol.lock.withLock {
            CompletionURLProtocol.handler = { request in
                if request.request.url?.path == "/api/posts" {
                    request.respond(["post": ["id": 992, "body": "Ответ старого аккаунта"]])
                } else if request.request.url?.path == "/api/stories" {
                    request.respond(["story": ["id": 993, "body": "Старая история"]])
                } else { request.respond(["ok": true]) }
            }
        }
        let model = AloAppModel(api: api())
        model.bootstrap = session(owner)
        let queue = model.publications
        let change = queue.onChange, publish = queue.onPublished
        let nextAccount = session(owner + 1)
        var publishing = false, switched = false, callbacks = 0
        queue.onChange = { jobs in
            change?(jobs)
            if jobs.contains(where: { $0.status == .publishing }) { publishing = true }
            // Removal starts persisting the ACK. Switch before the worker
            // resumes from that persistence, the previously unguarded boundary.
            if publishing && jobs.isEmpty && !switched {
                switched = true
                model.bootstrap = nextAccount
                model.composeText = "Черновик нового аккаунта"
            }
        }
        queue.onPublished = { publishedOwner, job, post in
            callbacks += 1
            publish?(publishedOwner, job, post)
        }
        defer {
            queue.onChange = change
            queue.onPublished = publish
            queue.reset()
            CompletionURLProtocol.lock.withLock { CompletionURLProtocol.handler = nil }
            store.scheduleClear(ownerUserId: owner); store.scheduleClear(ownerUserId: owner + 1)
        }
        if kind == .post {
            model.composeText = "Публикация старого аккаунта"
            model.createPost()
        } else { model.createStory(body: "История старого аккаунта") }
        try await wait { switched }
        await store.finishPendingWrites()
        #expect(callbacks == 0)
        #expect(model.bootstrap?.me.id == owner + 1 && model.bootstrap?.feedPopular.isEmpty == true)
        #expect(model.composeText == "Черновик нового аккаунта")
    }

    @Test @MainActor func channelOpenedFromPublicLinkLoadsAuthoritativeOwnerRole() async throws {
        let owner = 1_999_996_805, room = 82, peer = 1_000_000_082
        let handle = "async_owner_channel"
        CompletionURLProtocol.lock.withLock {
            CompletionURLProtocol.handler = { request in
                switch request.request.url?.path ?? "" {
                case "/api/group-public/\(handle)/join":
                    request.respond(["joined": true, "roomId": room, "peerId": peer])
                case "/api/app/bootstrap":
                    request.respond(["data": ["me": ["id": owner, "name": "Тест"], "messages": [
                        "activePeerId": peer, "items": [], "conversations": [[
                            "peerId": peer, "kind": "group", "roomId": room,
                            "peer": ["id": peer, "name": "Мой канал", "entityType": "channel"]
                        ]]
                    ]]])
                case "/api/messages/\(peer)", "/api/group-chats/\(room)/messages":
                    request.respond(["room": ["id": room, "title": "Мой канал", "memberRole": "owner",
                        "canManage": true, "policy": ["kind": "channel", "username": handle]], "items": []])
                default: request.respond(["ok": true])
                }
            }
        }
        let model = AloAppModel(api: api())
        model.bootstrap = session(owner); model.phase = .app
        defer {
            CompletionURLProtocol.lock.withLock { CompletionURLProtocol.handler = nil }
            model.publications.reset()
            model.closeConversation()
            AloSecureOutboxStore.shared.scheduleClear(ownerUserId: owner)
        }
        model.handleDeepLink(try #require(URL(string: "https://\(AloServerConfiguration.appLinkHost)/c/\(handle)")))
        try await wait { model.activeConversation?.groupMemberRole == "owner" }
        #expect(model.activeConversation?.peerId == peer && model.activeConversation?.canManageGroup == true)
        #expect(model.activeConversation?.groupPolicy?.kind == "channel")
    }
}
