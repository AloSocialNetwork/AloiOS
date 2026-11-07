import Foundation
import Testing
@testable import AloiOS

/// The iPhone half of `~/alo/tools/ios-web-secret-check.js`: this app (person A) starts a secret chat with a person whose
/// only device is a real browser (the script drives it). The browser accepts, both write, each side reads the other.
/// Skipped unless `ALO_SECRET_WEB_PEER` (the browser person's id), `ALO_SECRET_SERVER_URL`, `ALO_SECRET_TOKEN_A` are set.
private let interopEnvironment = ProcessInfo.processInfo.environment

@Suite(.serialized, .enabled(if: interopEnvironment["ALO_SECRET_WEB_PEER"] != nil && interopEnvironment["ALO_SECRET_SERVER_URL"] != nil))
struct AloSecretChatWebInteropTests {
    @Test @MainActor func aSecretChatWithABrowserWorksBothWays() async throws {
        let url = try #require(URL(string: interopEnvironment["ALO_SECRET_SERVER_URL"] ?? ""))
        let peer = try #require(Int(interopEnvironment["ALO_SECRET_WEB_PEER"] ?? ""))
        let token = try #require(interopEnvironment["ALO_SECRET_TOKEN_A"])
        let client = AloAPIClient(baseURLs: [url])
        client.messagingPolicyCache.forget()
        client.replaceSessionCookies([HTTPCookie(properties: [.domain: url.host ?? "127.0.0.1", .path: "/",
                                                              .name: "alo_session", .value: token])!])
        _ = try await client.loadBootstrap()
        _ = await client.messagingPolicy(refresh: true)
        #expect(await client.secretChatsAvailable())

        func waitFor<T>(_ what: String, seconds: Double = 90, _ probe: () async throws -> T?) async throws -> T {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let value = try await probe() { return value }
                try await Task.sleep(nanoseconds: 700_000_000)
            }
            throw AloAPIError(status: -1, code: "TIMEOUT", message: "Не дождались: \(what)", payload: [:])
        }

        // 1. The iPhone asks; the browser accepts it (the script clicks «Принять»).
        let started = try await client.startSecretChat(peerUserId: peer)
        #expect(started.isWaiting)
        let active = try await waitFor("the browser accepts") {
            try await client.loadSecretChats().first { $0.id == started.id && $0.isActive }
        }
        #expect(active.remoteDeviceId.hasPrefix("web_"))

        // 2. The iPhone writes first, with formatting and a photo.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        let photo = AloLocalAttachment(data: png, mime: "image/png", type: "image", name: "iphone.png")
        _ = try await client.sendSecretMessage(chat: active, text: "Привет с **iPhone**", drafts: [photo], selfDestructSeconds: 0)

        // 3. The browser answers; the iPhone opens it.
        let answer = try await waitFor("the answer from the browser") {
            try await client.loadSecretMessages(id: started.id).messages.first { $0.senderUserId == peer && $0.body.contains("Ответ с сайта") }
        }
        #expect(!answer.unreadable)
        #expect(answer.body == "Ответ с сайта")
        try await client.markSecretChatRead(id: started.id, upToMessageId: answer.id)

        // 4. A last message tells the script the iPhone read the answer.
        _ = try await client.sendSecretMessage(chat: active, text: "iPhone прочитал ответ", drafts: [], selfDestructSeconds: 0)
    }
}
