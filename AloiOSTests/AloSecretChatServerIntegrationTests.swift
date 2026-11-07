import Foundation
import Testing
@testable import AloiOS

/// Secret chats between two accounts of this app through a real Alo server on a throwaway database
/// (`node ~/alo/tools/ios-test-server.js`). Skipped unless `ALO_SECRET_SERVER_URL`, `ALO_SECRET_USER_A`, `ALO_SECRET_TOKEN_A`,
/// `ALO_SECRET_USER_B`, `ALO_SECRET_TOKEN_B` are set; run with the `TEST_RUNNER_` prefix on each for `xcodebuild test`.
/// One client switches between the two people (cookies are shared): each has its own libsignal store ("user-<id>").
private let secretEnvironment = ProcessInfo.processInfo.environment

@Suite(.serialized, .enabled(if: secretEnvironment["ALO_SECRET_SERVER_URL"] != nil && secretEnvironment["ALO_SECRET_TOKEN_A"] != nil))
struct AloSecretChatServerIntegrationTests {
    private func cookie(_ token: String, url: URL) -> HTTPCookie {
        HTTPCookie(properties: [.domain: url.host ?? "127.0.0.1", .path: "/", .name: "alo_session", .value: token])!
    }

    @Test @MainActor func requestAcceptMessagesPhotoTimerAndDeleteThroughTheRealServer() async throws {
        let url = try #require(URL(string: secretEnvironment["ALO_SECRET_SERVER_URL"] ?? ""))
        let userA = try #require(Int(secretEnvironment["ALO_SECRET_USER_A"] ?? ""))
        let userB = try #require(Int(secretEnvironment["ALO_SECRET_USER_B"] ?? ""))
        let tokenA = try #require(secretEnvironment["ALO_SECRET_TOKEN_A"])
        let tokenB = try #require(secretEnvironment["ALO_SECRET_TOKEN_B"])
        let client = AloAPIClient(baseURLs: [url])
        client.messagingPolicyCache.forget()
        func signIn(_ token: String) async throws {
            client.replaceSessionCookies([cookie(token, url: url)])
            _ = try await client.loadBootstrap()
            _ = await client.messagingPolicy(refresh: true)
        }

        // 1. Both people have their libsignal device; the server can do secret chats.
        try await signIn(tokenB)
        #expect(await client.secretChatsAvailable())
        try await signIn(tokenA)
        #expect(await client.secretChatsAvailable())

        // 2. A asks; the chat waits for B. A second ask from the same device gives the same chat.
        let started = try await client.startSecretChat(peerUserId: userB)
        #expect(started.isWaiting)
        #expect(started.peerUserId == userB)
        let again = try await client.startSecretChat(peerUserId: userB)
        #expect(again.id == started.id)

        // 3. B sees the request and accepts it.
        try await signIn(tokenB)
        let incoming = try #require(try await client.loadSecretChats().first { $0.id == started.id })
        #expect(incoming.isIncomingRequest)
        #expect(AloSecretChatList.preview(incoming) == "Запрос секретного чата")
        let accepted = try await client.acceptSecretChat(id: started.id)
        #expect(accepted.isActive)
        #expect(!accepted.remoteDeviceId.isEmpty)

        // 4. B writes first (a new session from A's prekeys), with formatting.
        let fromB = try await client.sendSecretMessage(chat: accepted, text: "**Привет** из секретного чата", drafts: [],
                                                       selfDestructSeconds: 0)
        #expect(fromB.body == "Привет из секретного чата")
        #expect(fromB.entities.first?.type == "bold")

        // 5. A reads it; A answers with a photo and a 5 second timer.
        try await signIn(tokenA)
        let seenByA = try await client.loadSecretMessages(id: started.id)
        let received = try #require(seenByA.messages.first { $0.id == fromB.id })
        #expect(received.body == "Привет из секретного чата")
        #expect(received.entities.first?.type == "bold")
        #expect(!received.unreadable)
        let chatA = try #require(seenByA.chat)
        #expect(chatA.isActive)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        let photo = AloLocalAttachment(data: png, mime: "image/png", type: "image", name: "точка.png")
        let fromA = try await client.sendSecretMessage(chat: chatA, text: "Ответ с таймером", drafts: [photo],
                                                       selfDestructSeconds: 5)
        #expect(fromA.body == "Ответ с таймером")
        #expect(fromA.selfDestructSeconds == 5)
        #expect(fromA.attachments.count == 1)

        // 6. B opens it: the text, the photo's bytes, and the timer that starts only when B reads it.
        try await signIn(tokenB)
        let seenByB = try await client.loadSecretMessages(id: started.id)
        let answer = try #require(seenByB.messages.first { $0.id == fromA.id })
        #expect(answer.body == "Ответ с таймером")
        #expect(answer.selfDestructSeconds == 5)
        #expect(answer.expiresAt.isEmpty)
        let photoURL = try #require(answer.attachments.first.flatMap { URL(string: $0.url) })
        try await AloSecureMediaStore.shared.ensureAvailable(photoURL, intent: .userInitiated)
        #expect(try AloSecureMediaStore.shared.payload(for: photoURL).data == png)
        try await client.markSecretChatRead(id: started.id, upToMessageId: fromA.id)
        let afterRead = try await client.loadSecretMessages(id: started.id)
        let timed = try #require(afterRead.messages.first { $0.id == fromA.id })
        #expect(!timed.expiresAt.isEmpty)

        // 7. The chat timer is shared; deleting the chat removes it for both.
        try await client.setSecretChatTimer(id: started.id, seconds: 60)
        try await signIn(tokenA)
        #expect(try await client.loadSecretChats().first { $0.id == started.id }?.ttlSeconds == 60)
        try await client.deleteSecretChat(id: started.id)
        try await signIn(tokenB)
        #expect(try await client.loadSecretChats().contains { $0.id == started.id } == false)
        _ = userA
    }
}
