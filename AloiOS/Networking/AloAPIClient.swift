import Foundation
import CryptoKit
import LibSignalClient
import Security

struct AloAPIError: Error, Identifiable {
    let id = UUID()
    let status: Int
    let code: String
    let message: String
    let payload: [String: Any]
}

struct AloMessageSendAcknowledgement {
    let messageId: Int
    let createdAt: String
}

struct AloChatStreamEvent {
    let id: Int
    let name: String
    let payload: [String: Any]
}

struct AloSafetyDevice: Identifiable {
    let id: String
    let label: String
    let fingerprint: String
}

struct AloSafetyVerification {
    let peerId: Int
    let decimalCode: String
    let qrPayload: String
    let digest: String
    let localFingerprint: String
    let peerDevices: [AloSafetyDevice]
    let isVerified: Bool
}

final class AloAPIClient {
    static let shared = AloAPIClient()

    var baseURL: URL { activeBaseURL }
    private(set) var latestE2EEWarning: String?

    private let baseURLs: [URL]
    private var activeBaseURL: URL
    private let sessionDelegate: AloCertificatePinningDelegate
    private let session: URLSession
    private var currentUserId = 0
    private var latestE2EERegistrationError: AloAPIError?
    private var isRegisteringLibSignal = false
    private var libSignalUserId = 0
    private var libSignalProtocolDeviceId: UInt32 = 0
    private var libSignalStore: AloLibSignalStore?
    private var libSignalEngine: AloLibSignalSessionEngine?
    private var didCleanDecodedMediaCache = false

    init(baseURLs: [URL] = AloEnvironment.baseURLs) {
        let normalizedBaseURLs = AloEnvironment.normalizedBaseURLs(baseURLs)
        self.baseURLs = normalizedBaseURLs
        self.activeBaseURL = normalizedBaseURLs[0]
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        let sessionDelegate = AloCertificatePinningDelegate(
            baseURLs: normalizedBaseURLs,
            configuredPins: AloEnvironment.certificatePins,
            requiresPins: AloEnvironment.requiresCertificatePins
        )
        self.sessionDelegate = sessionDelegate
        self.session = URLSession(
            configuration: configuration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
        cleanupDecodedMediaCacheIfNeeded()
    }

    func absoluteURL(_ path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("file://") ||
            path.hasPrefix("data:") || path.hasPrefix("\(AloSecureMediaStore.scheme)://") {
            return URL(string: path)
        }
        return URL(string: path, relativeTo: activeBaseURL)?.absoluteURL
    }

    func appURL(_ path: String) -> URL {
        absoluteURL(path) ?? activeBaseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func downloadData(from url: URL) async throws -> (data: Data, mimeType: String) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("AloiOS", forHTTPHeaderField: "X-Requested-With")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            throw AloAPIError(
                status: http?.statusCode ?? 0,
                code: "MEDIA_DOWNLOAD_FAILED",
                message: "Не удалось загрузить файл.",
                payload: [:]
            )
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    func login(email: String, password: String, captchaToken: String? = nil) async throws -> (challengeToken: String, message: String) {
        let json = try await request(
            "POST",
            "/api/auth/login",
            body: compactBody([
                "email": email,
                "password": password,
                "captchaToken": captchaToken
            ])
        )
        return (json.string("challengeToken"), json.string("message").ifBlank("Код отправлен на почту."))
    }

    func verifyLogin(
        email: String,
        code: String,
        challengeToken: String,
        verificationRequestId: String
    ) async throws {
        _ = try await request(
            "POST",
            "/api/auth/verify-login",
            body: [
                "email": email,
                "code": code,
                "challengeToken": challengeToken,
                "verificationRequestId": verificationRequestId
            ]
        )
    }

    func logout() async throws {
        _ = try await request("POST", "/api/auth/logout")
    }

    func registerPushToken(
        platform: String,
        token: String,
        deviceId: String,
        appVersion: String
    ) async throws {
        _ = try await request(
            "PUT",
            "/api/push/device-token",
            body: [
                "platform": platform,
                "token": token,
                "deviceId": deviceId,
                "appVersion": appVersion
            ]
        )
    }

    func unregisterPushToken(platform: String, token: String, deviceId: String) async throws {
        _ = try await request(
            "DELETE",
            "/api/push/device-token",
            body: [
                "platform": platform,
                "token": token,
                "deviceId": deviceId
            ]
        )
    }

    func registerVoIPPushToken(token: String, deviceId: String, appVersion: String) async throws {
        _ = try await request(
            "PUT",
            "/api/push/voip-token",
            body: [
                "token": token,
                "deviceId": deviceId,
                "appVersion": appVersion
            ]
        )
    }

    func unregisterVoIPPushToken(token: String, deviceId: String) async throws {
        _ = try await request(
            "DELETE",
            "/api/push/voip-token",
            body: [
                "token": token,
                "deviceId": deviceId
            ]
        )
    }

    func loadRTCConfiguration() async throws -> AloRTCConfiguration {
        let raw = try await request("GET", "/api/config")
        let servers = raw.object("rtc").array("iceServers").compactMap { item -> AloRTCIceServer? in
            var urls = (item["urls"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if urls.isEmpty {
                let single = item.string("urls").trimmingCharacters(in: .whitespacesAndNewlines)
                if !single.isEmpty { urls = [single] }
            }
            guard !urls.isEmpty else { return nil }
            return AloRTCIceServer(
                urls: urls,
                username: item.string("username"),
                credential: item.string("credential")
            )
        }
        return AloRTCConfiguration(iceServers: servers)
    }

    func startDirectCall(peerId: Int, type: String) async throws -> AloDirectCallSession {
        let raw = try await request(
            "POST",
            "/api/calls/start",
            body: [
                "peerId": peerId,
                "type": type == "video" ? "video" : "voice"
            ]
        ).object("call")
        let callId = raw.int("id")
        guard callId > 0 else {
            throw AloAPIError(
                status: 0,
                code: "CALL_SESSION_MISSING",
                message: "Сервер не вернул сессию звонка.",
                payload: raw
            )
        }
        return AloDirectCallSession(
            id: callId,
            type: raw.string("type").ifBlank("voice"),
            callerId: raw.int("callerId"),
            calleeId: raw.int("calleeId"),
            status: raw.string("status")
        )
    }

    func acceptDirectCall(callId: Int) async throws {
        _ = try await request("POST", "/api/calls/\(callId)/accept", body: [:])
    }

    func sendDirectCallSignal(
        callId: Int,
        kind: String,
        payload: [String: Any],
        peerId: Int
    ) async throws {
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let securedPayload: [String: Any]
        if [
            "security-commit",
            "security-response",
            "offer",
            "answer",
            "security-confirm",
            "reconnect-offer",
            "reconnect-answer",
            "ice",
            "media-state"
        ].contains(normalizedKind) {
            securedPayload = try await buildEncryptedDirectCallSignalPayload(
                peerId: peerId,
                payload: payload
            )
        } else {
            securedPayload = payload
        }
        _ = try await request(
            "POST",
            "/api/calls/\(callId)/signal",
            body: [
                "kind": normalizedKind,
                "payload": securedPayload
            ]
        )
    }

    func endDirectCall(callId: Int, reason: String = "") async throws {
        _ = try await request(
            "POST",
            "/api/calls/\(callId)/end",
            body: ["reason": reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        )
    }

    func pollDirectCallSignals(
        afterId: Int,
        activeCallId: Int? = nil
    ) async throws -> [AloDirectCallSignal] {
        var path = "/api/calls/poll?afterId=\(max(0, afterId))"
        if let activeCallId, activeCallId > 0 {
            path += "&activeCallId=\(activeCallId)"
        }
        let raw = try await request("GET", path)
        return raw.array("signals").map { item in
            let user = item.object("fromUser")
            return AloDirectCallSignal(
                id: item.int("id"),
                callId: item.int("callId"),
                fromUserId: item.int("fromUserId"),
                toUserId: item.int("toUserId"),
                kind: item.string("kind"),
                callType: item.string("callType").ifBlank("voice"),
                callStatus: item.string("callStatus"),
                callerId: item.int("callerId"),
                calleeId: item.int("calleeId"),
                fromUser: AloDirectCallPeer(
                    id: user.int("id").ifZero(item.int("fromUserId")),
                    name: user.string("name").ifBlank("Собеседник"),
                    username: user.string("username"),
                    avatarURL: user.string("avatarUrl").ifBlank(user.string("avatarEmoji")),
                    verified: user.bool("verified") || user.bool("isVerified")
                ),
                payload: decryptDirectCallSignalPayload(item.object("payload"))
            )
        }
    }

    func loadSafetyVerification(peerId: Int) async throws -> AloSafetyVerification {
        guard currentUserId > 0, peerId > 0, let store = libSignalStore else {
            throw AloAPIError(
                status: 0,
                code: "SAFETY_KEYS_UNAVAILABLE",
                message: "Ключи безопасности ещё не готовы. Повторите через несколько секунд.",
                payload: [:]
            )
        }

        let peerDevices = try await loadLibSignalUserDevices(userId: peerId, includePreKeys: false)
        guard !peerDevices.isEmpty else {
            throw AloAPIError(
                status: 0,
                code: "SAFETY_PEER_KEYS_UNAVAILABLE",
                message: "У собеседника пока нет зарегистрированных ключей безопасности.",
                payload: [:]
            )
        }
        try peerDevices.forEach(validateLibSignalIdentity)

        let ownDevices = try await loadLibSignalUserDevices(userId: currentUserId, includePreKeys: false)
        let localFingerprint = try store.identityFingerprint()
        var records = (ownDevices + peerDevices).map { device in
            "\(device.userId):\(device.deviceId):\(computedIdentityFingerprint(device.identityKey))"
        }
        let localRecordPrefix = "\(currentUserId):\(AloE2EECrypto.shared.deviceId):"
        if !records.contains(where: { $0.hasPrefix(localRecordPrefix) }) {
            records.append("\(localRecordPrefix)\(localFingerprint)")
        }
        records.sort()

        let lowUserId = min(currentUserId, peerId)
        let highUserId = max(currentUserId, peerId)
        let material = "alo-safety-v1|\(lowUserId)|\(highUserId)|\(records.joined(separator: "|"))"
        let hash = Array(SHA512.hash(data: Data(material.utf8)))
        let digest = hash.map { String(format: "%02x", $0) }.joined()
        let groups = (0..<12).map { group -> String in
            let start = group * 5
            let value = hash[start..<(start + 5)].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            return String(format: "%05llu", value % 100_000)
        }
        let verificationKey = safetyVerificationKey(peerId: peerId, digest: digest)
        let devices = peerDevices
            .sorted {
                if $0.deviceId == $1.deviceId {
                    return $0.protocolDeviceId < $1.protocolDeviceId
                }
                return $0.deviceId < $1.deviceId
            }
            .map {
                AloSafetyDevice(
                    id: "\($0.deviceId):\($0.protocolDeviceId)",
                    label: $0.deviceId,
                    fingerprint: computedIdentityFingerprint($0.identityKey)
                )
            }

        return AloSafetyVerification(
            peerId: peerId,
            decimalCode: groups.joined(separator: " "),
            qrPayload: "alo-safety-v1:\(lowUserId):\(highUserId):\(digest)",
            digest: digest,
            localFingerprint: localFingerprint,
            peerDevices: devices,
            isVerified: UserDefaults.standard.bool(forKey: verificationKey)
        )
    }

    func setSafetyVerification(peerId: Int, digest: String, verified: Bool) {
        UserDefaults.standard.set(
            verified,
            forKey: safetyVerificationKey(peerId: peerId, digest: digest)
        )
    }

    func chatMuteState(conversation: AloConversationDetail) async throws -> Bool {
        let targetId = conversation.kind == "group" ? conversation.roomId : conversation.peerId
        let response = try await request(
            "GET",
            "/api/chat/mute?kind=\(conversation.kind)&targetId=\(targetId)"
        )
        return response.bool("muted")
    }

    func setChatMuted(_ muted: Bool, conversation: AloConversationDetail) async throws -> Bool {
        let targetId = conversation.kind == "group" ? conversation.roomId : conversation.peerId
        let response = try await request(
            "PUT",
            "/api/chat/mute",
            body: [
                "kind": conversation.kind,
                "targetId": targetId,
                "muted": muted
            ]
        )
        return response.bool("muted")
    }

    private func computedIdentityFingerprint(_ identityKey: Data) -> String {
        let digest = SHA256.hash(data: identityKey).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: 60, by: 5).map { offset -> String in
            let start = digest.index(digest.startIndex, offsetBy: offset)
            let end = digest.index(start, offsetBy: 5)
            return String(digest[start..<end])
        }.joined(separator: "-")
    }

    private func safetyVerificationKey(peerId: Int, digest: String) -> String {
        "alo.ios.safety.verified.v1.\(currentUserId).\(peerId).\(digest)"
    }

    func clearCookies() {
        currentUserId = 0
        libSignalUserId = 0
        libSignalProtocolDeviceId = 0
        libSignalStore = nil
        libSignalEngine = nil
        HTTPCookieStorage.shared.cookies?.forEach { cookie in
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    func register(name: String, username: String, email: String, password: String, captchaToken: String? = nil) async throws -> String {
        let json = try await request(
            "POST",
            "/api/auth/register",
            body: compactBody([
                "name": name,
                "username": username,
                "email": email,
                "password": password,
                "skipAvatar": true,
                "captchaToken": captchaToken
            ])
        )
        return json.string("message").ifBlank("Код отправлен на почту.")
    }

    func verifyEmail(email: String, code: String) async throws {
        _ = try await request(
            "POST",
            "/api/auth/verify-email",
            body: [
                "email": email,
                "code": code
            ]
        )
    }

    func loadBootstrap(peerId: Int = 0) async throws -> AloBootstrapData {
        try await loadBootstrapSnapshot(peerId: peerId).data
    }

    func loadBootstrapSnapshot(peerId: Int = 0) async throws -> (data: AloBootstrapData, raw: [String: Any]) {
        let path = peerId > 0 ? "/api/app/bootstrap?peerId=\(peerId)" : "/api/app/bootstrap"
        var raw = try await request("GET", path)
        let currentUserId = raw.object("data").object("me").int("id")
        self.currentUserId = currentUserId
        await registerE2EEDeviceKeyIfPossible(currentUserId: currentUserId)
        await registerLibSignalDeviceIfPossible(currentUserId: currentUserId)
        raw = await decryptE2EEMessages(inBootstrap: raw)
        return (AloBootstrapData(raw), raw)
    }

    func createPost(body: String, media: [AloMessageAttachment] = [], captchaToken: String? = nil) async throws -> AloPost {
        let json = try await request(
            "POST",
            "/api/posts",
            body: compactBody([
                "body": body,
                "media": media.map { ["type": $0.type, "url": $0.url, "name": $0.name] },
                "captchaToken": captchaToken
            ])
        )
        return AloPost(json.object("post"))
    }

    func toggleLike(postId: Int) async throws -> AloPost {
        let json = try await request("POST", "/api/posts/\(postId)/like")
        return AloPost(json.object("post"))
    }

    func deletePost(postId: Int) async throws -> Int {
        let json = try await request("DELETE", "/api/posts/\(postId)")
        return json.int("deletedPostId").ifZero(postId)
    }

    func loadConversation(peerId: Int) async throws -> AloConversationDetail {
        let raw = try await request("GET", "/api/messages/\(peerId)")
        let decrypted = await decryptE2EEMessages(inConversation: raw)
        if currentUserId > 0,
           JSONSerialization.isValidJSONObject(decrypted),
           let data = try? JSONSerialization.data(withJSONObject: decrypted) {
            try? AloSecureOfflineCacheStore.shared.saveConversation(
                data,
                peerId: peerId,
                ownerUserId: currentUserId
            )
        }
        return AloConversationDetail(peerId: peerId, json: decrypted)
    }

    func loadConversationSummaries() async throws -> [AloConversationSummary] {
        let response = try await request("GET", "/api/chat/conversations")
        let wrapper: [String: Any] = [
            "data": [
                "messages": [
                    "conversations": response.array("conversations"),
                    "items": []
                ]
            ]
        ]
        let decrypted = await decryptE2EEMessages(inBootstrap: wrapper)
        return decrypted
            .object("data")
            .object("messages")
            .array("conversations")
            .map(AloConversationSummary.init)
    }

    func chatEventStream(afterCursor cursor: Int) -> AsyncThrowingStream<AloChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                do {
                    var components = URLComponents(
                        url: self.activeBaseURL.appendingPathComponent("api/chat/stream"),
                        resolvingAgainstBaseURL: false
                    )
                    if cursor > 0 {
                        components?.queryItems = [URLQueryItem(name: "cursor", value: String(cursor))]
                    }
                    guard let url = components?.url else {
                        throw AloAPIError(
                            status: 0,
                            code: "BAD_URL",
                            message: "Некорректный адрес realtime API.",
                            payload: [:]
                        )
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.timeoutInterval = 60 * 60
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("AloiOS", forHTTPHeaderField: "X-Requested-With")
                    if cursor > 0 {
                        request.setValue(String(cursor), forHTTPHeaderField: "Last-Event-ID")
                    }

                    let (bytes, response) = try await self.session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        throw AloAPIError(
                            status: status,
                            code: status == 401 ? "UNAUTHORIZED" : "CHAT_STREAM_FAILED",
                            message: status == 401 ? "Требуется авторизация." : "Realtime-соединение недоступно.",
                            payload: [:]
                        )
                    }

                    var eventId = 0
                    var eventName = "message"
                    var dataLines = [String]()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                let data = Data(dataLines.joined(separator: "\n").utf8)
                                let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                                continuation.yield(
                                    AloChatStreamEvent(id: eventId, name: eventName, payload: payload)
                                )
                            }
                            eventId = 0
                            eventName = "message"
                            dataLines.removeAll(keepingCapacity: true)
                            continue
                        }
                        if line.hasPrefix(":") { continue }
                        if line.hasPrefix("id:") {
                            eventId = Int(line.dropFirst(3).trimmingCharacters(in: .whitespaces)) ?? 0
                        } else if line.hasPrefix("event:") {
                            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                        }
                    }

                    if !Task.isCancelled {
                        throw URLError(.networkConnectionLost)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                streamTask.cancel()
            }
        }
    }

    func loadCachedConversation(peerId: Int, ownerUserId: Int) -> AloConversationDetail? {
        guard let data = AloSecureOfflineCacheStore.shared.loadConversation(
            peerId: peerId,
            ownerUserId: ownerUserId
        ),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return AloConversationDetail(peerId: peerId, json: raw)
    }

    func updateChatPresence(activePeerId: Int) async throws {
        _ = try await request(
            "POST",
            "/api/chat/presence",
            body: ["activePeerId": activePeerId]
        )
    }

    func sendTyping(conversation: AloConversationDetail) async throws {
        _ = try await request(
            "POST",
            "/api/chat/typing",
            body: [
                "kind": conversation.kind,
                "peerId": conversation.peerId,
                "roomId": conversation.roomId
            ]
        )
    }

    func uploadAttachment(_ attachment: AloLocalAttachment, purpose: String = "message") async throws -> AloMessageAttachment {
        let json = try await request(
            "POST",
            "/api/uploads",
            body: [
                "purpose": purpose,
                "dataUrl": attachment.dataUrl
            ]
        )
        let file = json.object("file")
        return AloMessageAttachment([
            "type": file.string("type").ifBlank(attachment.type),
            "url": file.string("url"),
            "name": attachment.name,
            "waveform": attachment.waveform
        ])
    }

    func uploadE2EEAttachment(_ attachment: AloLocalAttachment) async throws -> AloMessageAttachment {
        let sealed = try AloE2EECrypto.shared.encryptMedia(attachment.data)
        let binaryDataUrl = "data:application/octet-stream;base64,\(sealed.data.base64EncodedString())"
        let json = try await request(
            "POST",
            "/api/uploads",
            body: [
                "purpose": "message_e2ee",
                "dataUrl": binaryDataUrl
            ]
        )
        let file = json.object("file")
        return AloMessageAttachment([
            "type": attachment.type,
            "url": file.string("url"),
            "name": attachment.name,
            "waveform": attachment.waveform,
            "mediaEncryption": [
                "algorithm": AloE2EECrypto.mediaScheme,
                "key": sealed.key,
                "iv": sealed.iv,
                "mime": attachment.mime
            ]
        ])
    }

    func loadUserProfile(userId: Int) async throws -> AloUserProfile {
        AloUserProfile(try await request("GET", "/api/users/\(userId)/profile"))
    }

    func updateProfileCover(coverStyle: String) async throws -> AloCurrentUser {
        let json = try await request(
            "PATCH",
            "/api/profile/cover",
            body: ["coverStyle": coverStyle]
        )
        return AloCurrentUser(json.object("user"))
    }

    func updateProfileAvatar(avatarUrl: String) async throws -> AloCurrentUser {
        let json = try await request(
            "PATCH",
            "/api/profile",
            body: ["avatarEmoji": avatarUrl]
        )
        return AloCurrentUser(json.object("user"))
    }

    func updateGroupChatProfile(
        roomId: Int,
        title: String,
        avatarUrl: String? = nil
    ) async throws -> AloConversationDetail {
        var body: [String: Any] = ["title": title]
        if let avatarUrl {
            body["avatarUrl"] = avatarUrl
            body["avatarGallery"] = avatarUrl.isEmpty ? [] : [avatarUrl]
        }
        let json = try await request(
            "PATCH",
            "/api/group-chats/\(roomId)/profile",
            body: body
        )
        let room = json.object("room")
        let peerId = room.int("peerId")
        return try await loadConversation(peerId: peerId)
    }

    func leaveGroupChat(roomId: Int) async throws {
        _ = try await request("POST", "/api/group-chats/\(roomId)/leave")
    }

    func deleteGroupChat(roomId: Int) async throws {
        _ = try await request("DELETE", "/api/group-chats/\(roomId)")
    }

    func updatePrivacy(profileVisibility: String) async throws -> AloPrivacySettings {
        try await updatePrivacy(settings: AloPrivacySettings(
            allowFriendRequests: true,
            messageScope: "all",
            allowMessageForwards: true,
            callScope: "all",
            profileVisibility: profileVisibility,
            hideActivity: false
        ))
    }

    func updatePrivacy(settings: AloPrivacySettings) async throws -> AloPrivacySettings {
        let json = try await request(
            "PATCH",
            "/api/privacy/settings",
            body: settings.requestBody
        )
        return AloPrivacySettings(json.object("settings"))
    }

    func updateNotificationSettings(_ settings: AloNotificationSettings) async throws -> AloNotificationSettings {
        let json = try await request(
            "PATCH",
            "/api/notifications/settings",
            body: settings.requestBody
        )
        return AloNotificationSettings(json.object("settings"))
    }

    func loadSecuritySessions() async throws -> [AloSecuritySession] {
        let json = try await request("GET", "/api/security/sessions")
        return json.array("sessions").map(AloSecuritySession.init)
    }

    func changePassword(currentPassword: String, newPassword: String) async throws -> Int {
        let json = try await request(
            "POST",
            "/api/security/password/change",
            body: [
                "currentPassword": currentPassword,
                "newPassword": newPassword
            ]
        )
        return json.int("revokedSessions")
    }

    func revokeOtherSecuritySessions() async throws -> Int {
        let json = try await request("POST", "/api/security/sessions/revoke-others")
        return json.int("revoked")
    }

    func revokeSecuritySession(id: Int) async throws {
        _ = try await request("DELETE", "/api/security/sessions/\(id)")
    }

    func loadPostComments(postId: Int) async throws -> [AloPostComment] {
        let json = try await request("GET", "/api/posts/\(postId)/comments")
        return json.array("comments").map(AloPostComment.init)
    }

    func createComment(
        postId: Int,
        body: String,
        attachments: [AloMessageAttachment] = [],
        captchaToken: String? = nil
    ) async throws -> (comment: AloPostComment, post: AloPost?) {
        let json = try await request(
            "POST",
            "/api/posts/\(postId)/comments",
            body: compactBody([
                "body": body,
                "attachments": attachments.map { ["type": $0.type, "url": $0.url, "name": $0.name] },
                "captchaToken": captchaToken
            ])
        )
        return (AloPostComment(json.object("comment")), json.optionalObject("post").map(AloPost.init))
    }

    func updateComment(postId: Int, commentId: Int, body: String) async throws -> (comment: AloPostComment, post: AloPost?) {
        let json = try await request(
            "PATCH",
            "/api/posts/\(postId)/comments/\(commentId)",
            body: ["body": body]
        )
        return (AloPostComment(json.object("comment")), json.optionalObject("post").map(AloPost.init))
    }

    func deleteComment(postId: Int, commentId: Int) async throws -> AloPost? {
        let json = try await request("DELETE", "/api/posts/\(postId)/comments/\(commentId)")
        return json.optionalObject("post").map(AloPost.init)
    }

    func toggleCommentLike(postId: Int, commentId: Int) async throws -> AloPostComment {
        let json = try await request("POST", "/api/posts/\(postId)/comments/\(commentId)/like")
        return AloPostComment(json.object("comment"))
    }

    func sendMessage(
        peerId: Int,
        roomId: Int,
        kind: String,
        body: String,
        attachments: [AloMessageAttachment] = [],
        forwardFrom: AloForwardMeta? = nil,
        captchaToken: String? = nil,
        clientMessageId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws {
        let encryptedPayload = try await prepareEncryptedMessagePayload(
            peerId: peerId,
            roomId: roomId,
            kind: kind,
            body: body,
            attachments: attachments,
            forwardFrom: forwardFrom
        )
        _ = try await sendPreparedMessage(
            peerId: peerId,
            roomId: roomId,
            kind: kind,
            encryptedPayload: encryptedPayload,
            attachments: attachments,
            forwardFrom: forwardFrom,
            captchaToken: captchaToken,
            clientMessageId: clientMessageId
        )
    }

    func sendPreparedMessage(
        peerId: Int,
        roomId: Int,
        kind: String,
        encryptedPayload: [String: Any],
        attachments: [AloMessageAttachment] = [],
        forwardFrom: AloForwardMeta? = nil,
        captchaToken: String? = nil,
        clientMessageId: String
    ) async throws -> AloMessageSendAcknowledgement {
        var payload: [String: Any?] = [
            "encrypted": encryptedPayload,
            "attachments": attachments.map(e2eeServerAttachmentPayload),
            "clientMessageId": clientMessageId,
            "captchaToken": captchaToken
        ]
        if let forwardFrom {
            payload["forwardFrom"] = [
                "userId": forwardFrom.userId,
                "messageId": forwardFrom.messageId
            ]
        }
        let response: [String: Any]
        if kind == "group", roomId > 0 {
            response = try await request(
                "POST",
                "/api/group-chats/\(roomId)/messages/send",
                body: compactBody(payload)
            )
        } else {
            payload["peerId"] = peerId
            response = try await request("POST", "/api/messages/send", body: compactBody(payload))
        }
        AloE2EECrypto.shared.markRatchetSessionsConfirmed(encryptedPayload: encryptedPayload)
        let message = response.object("message")
        return AloMessageSendAcknowledgement(
            messageId: message.int("id"),
            createdAt: message.string("createdAt")
        )
    }

    func toggleMessageReaction(
        conversation: AloConversationDetail,
        messageId: Int,
        desiredEmoji: String
    ) async throws -> [AloMessageReaction] {
        let path = conversation.kind == "group" && conversation.roomId > 0
            ? "/api/group-chats/\(conversation.roomId)/messages/\(messageId)/reactions/toggle"
            : "/api/messages/\(messageId)/reactions/toggle"
        let json = try await request(
            "POST",
            path,
            body: ["desiredEmoji": desiredEmoji]
        )
        return json.array("reactions").map(AloMessageReaction.init)
    }

    func sendPreparedMessageEdit(
        conversation: AloConversationDetail,
        messageId: Int,
        body: String,
        encryptedPayload: [String: Any]
    ) async throws -> (body: String, editedAt: String) {
        let path = conversation.kind == "group" && conversation.roomId > 0
            ? "/api/group-chats/\(conversation.roomId)/messages/\(messageId)/edit"
            : "/api/messages/\(messageId)/edit"
        let json = try await request("POST", path, body: ["encrypted": encryptedPayload])
        AloE2EECrypto.shared.markRatchetSessionsConfirmed(encryptedPayload: encryptedPayload)
        let message = json.object("message")
        return (
            message.string("body").ifBlank(body),
            message.string("editedAt")
        )
    }

    func deleteMessages(messageIds: [Int], conversation: AloConversationDetail, mode: String = "me") async throws {
        let ids = Array(Set(messageIds)).filter { $0 > 0 }
        guard !ids.isEmpty else { return }
        if conversation.kind == "group", conversation.roomId > 0 {
            _ = try await request(
                "POST",
                "/api/group-chats/\(conversation.roomId)/messages/delete-batch",
                body: [
                    "messageIds": ids,
                    "mode": mode
                ]
            )
        } else {
            _ = try await request(
                "POST",
                "/api/messages/delete-batch",
                body: [
                    "messageIds": ids,
                    "mode": mode
                ]
            )
        }
    }

    func sendFriendRequest(userId: Int, captchaToken: String? = nil) async throws -> String {
        let json = try await request(
            "POST",
            "/api/friends/request",
            body: compactBody([
                "userId": userId,
                "captchaToken": captchaToken
            ])
        )
        return json.string("status").ifBlank("outgoing")
    }

    func toggleFollowUser(userId: Int) async throws -> Bool {
        let json = try await request("POST", "/api/users/\(userId)/follow", body: [:])
        return json.bool("following")
    }

    func respondFriendRequest(requestId: Int, accept: Bool) async throws -> String {
        let json = try await request("POST", "/api/friends/\(requestId)/\(accept ? "accept" : "decline")", body: [:])
        return json.string("status")
    }

    @discardableResult
    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let candidates = candidateURLs(for: path)
        guard !candidates.isEmpty else {
            throw AloAPIError(status: 0, code: "BAD_URL", message: "Некорректный адрес API.", payload: [:])
        }

        var lastConnectionError: Error?
        for candidate in candidates {
            do {
                var request = URLRequest(url: candidate.url)
                request.httpMethod = method
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("AloiOS", forHTTPHeaderField: "X-Requested-With")
                if let body {
                    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                }

                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                guard (200..<300).contains(status) else {
                    throw AloAPIError(
                        status: status,
                        code: json.string("code"),
                        message: json.string("error").ifBlank(json.string("message").ifBlank("Ошибка сервера.")),
                        payload: json
                    )
                }
                if let baseURL = candidate.baseURL {
                    activeBaseURL = baseURL
                }
                return json
            } catch let error as AloAPIError {
                throw error
            } catch {
                lastConnectionError = error
                if !canRetryOnAnotherBaseURL(method: method, error: error) {
                    break
                }
                continue
            }
        }

        throw AloAPIError(
            status: 0,
            code: "CONNECTION_FAILED",
            message: connectionErrorMessage(lastConnectionError),
            payload: [:]
        )
    }

    private func canRetryOnAnotherBaseURL(method: String, error: Error) -> Bool {
        if method == "GET" || method == "HEAD" { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed,
             .unsupportedURL, .badURL:
            return true
        default:
            // A timed-out or interrupted mutation may already have reached the server.
            return false
        }
    }

    private func candidateURLs(for path: String) -> [(baseURL: URL?, url: URL)] {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path).map { [(nil, $0)] } ?? []
        }
        let orderedBaseURLs = [activeBaseURL] + baseURLs.filter { $0 != activeBaseURL }
        return orderedBaseURLs.compactMap { baseURL in
            guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { return nil }
            return (baseURL, url)
        }
    }

    private func connectionErrorMessage(_ error: Error?) -> String {
        if let error {
            return "Не удалось подключиться к серверу Alo. \(error.localizedDescription)"
        }
        return "Не удалось подключиться к серверу Alo."
    }

    private func messageAttachmentPayload(_ attachment: AloMessageAttachment) -> [String: Any] {
        var payload: [String: Any] = [
            "type": attachment.type,
            "url": attachment.url,
            "name": attachment.name
        ]
        if !attachment.waveform.isEmpty {
            payload["waveform"] = attachment.waveform.map { Double($0) }
        }
        if !attachment.mediaEncryption.isEmpty {
            payload["mediaEncryption"] = attachment.mediaEncryption
        }
        return payload
    }

    private func e2eeServerAttachmentPayload(_ attachment: AloMessageAttachment) -> [String: Any] {
        [
            "type": "e2ee",
            "url": attachment.url,
            "name": attachment.name.ifBlank("encrypted.bin")
        ]
    }

    private func registerE2EEDeviceKeyIfPossible(currentUserId: Int) async {
        guard currentUserId > 0 else { return }
        do {
            let localKey = try AloE2EECrypto.shared.localPublicKeyPayload()
            let signingKey = try AloE2EECrypto.shared.localSigningPublicKeyPayload()
            let response = try await request(
                "PUT",
                "/api/e2ee/device-key",
                body: [
                    "deviceId": AloE2EECrypto.shared.deviceId,
                    "publicKeyJwk": localKey,
                    "signingPublicKeyJwk": signingKey,
                    "identitySignature": try AloE2EECrypto.shared.localIdentitySignature(),
                    "algorithm": AloE2EECrypto.scheme
                ]
            )
            latestE2EERegistrationError = nil
            latestE2EEWarning = response.bool("keyChanged")
                ? "Ключ шифрования этого устройства изменился. Проверьте безопасность активных диалогов."
                : nil
            do {
                try await publishE2EEOneTimePreKeysIfNeeded(
                    serverAvailable: response.int("preKeysAvailable"),
                    recommendedMinimum: response.int("preKeysRecommendedMinimum").ifZero(12)
                )
            } catch {
                // The signed identity key is already registered. A temporary
                // prekey replenishment failure must not block Saved Messages or
                // an existing ratchet session; the next bootstrap retries it.
            }
        } catch let error as AloAPIError {
            latestE2EERegistrationError = error
            if error.code == "E2EE_DEVICE_LIMIT_REACHED" ||
                error.code == "E2EE_IDENTITY_DOWNGRADE_BLOCKED" {
                latestE2EEWarning = error.message
            }
            // Bootstrap must still open offline/cached UI. Sending will surface transient setup errors.
        } catch {
            latestE2EERegistrationError = AloAPIError(
                status: -1,
                code: "E2EE_KEY_STORAGE_FAILED",
                message: "Не удалось получить доступ к защищённому хранилищу ключей устройства.",
                payload: [:]
            )
            // Bootstrap must still open offline/cached UI. Sending will surface transient setup errors.
        }
    }

    private func publishE2EEOneTimePreKeysIfNeeded(serverAvailable: Int, recommendedMinimum: Int) async throws {
        let minimum = max(1, recommendedMinimum)
        guard serverAvailable < minimum else { return }
        let preKeys = try AloE2EECrypto.shared.prepareOneTimePreKeysForUpload(
            serverAvailable: serverAvailable,
            targetCount: max(24, minimum)
        )
        guard !preKeys.isEmpty else { return }
        _ = try await request(
            "PUT",
            "/api/e2ee/device-prekeys",
            body: [
                "deviceId": AloE2EECrypto.shared.deviceId,
                "keys": preKeys.map { preKey in
                    [
                        "keyId": preKey.keyId,
                        "publicKeyJwk": preKey.publicKeyJwk,
                        "signature": preKey.signature,
                        "signatureVersion": preKey.signatureVersion,
                        "algorithm": preKey.algorithm
                    ]
                }
            ]
        )
        AloE2EECrypto.shared.markOneTimePreKeysPublished(preKeys.map(\.keyId))
    }

    private func registerLibSignalDeviceIfPossible(currentUserId: Int) async {
        guard currentUserId > 0, !isRegisteringLibSignal else { return }
        isRegisteringLibSignal = true
        defer { isRegisteringLibSignal = false }
        do {
            let slot = try await request(
                "PUT",
                "/api/e2ee/libsignal/device-slot",
                body: ["deviceId": AloE2EECrypto.shared.deviceId]
            )
            let protocolDeviceId = UInt32(slot.int("protocolDeviceId"))
            guard (1...127).contains(protocolDeviceId) else {
                throw AloAPIError(
                    status: -1,
                    code: "LIBSIGNAL_DEVICE_SLOT_INVALID",
                    message: "Сервер вернул некорректный слот E2EE-устройства.",
                    payload: slot
                )
            }

            if libSignalEngine == nil ||
                libSignalUserId != currentUserId ||
                libSignalProtocolDeviceId != protocolDeviceId {
                let store = try AloLibSignalStore(namespace: "user-\(currentUserId)")
                libSignalStore = store
                libSignalEngine = AloLibSignalSessionEngine(
                    store: store,
                    localUserId: currentUserId,
                    localDeviceId: protocolDeviceId
                )
                libSignalUserId = currentUserId
                libSignalProtocolDeviceId = protocolDeviceId
            }

            let markerKey = "alo.ios.libsignal.v1.registered.\(currentUserId).\(protocolDeviceId)"
            let defaults = UserDefaults.standard
            let serverAvailable = max(0, slot.int("preKeysAvailable"))
            let recommended = min(80, max(1, slot.int("preKeysRecommendedMinimum").ifZero(20)))
            if slot.bool("registered"), defaults.bool(forKey: markerKey), serverAvailable >= recommended {
                return
            }

            let amount = min(80, max(1, max(24, recommended) - serverAvailable))
            guard let engine = libSignalEngine else { return }
            let bundle = try engine.generateDeviceBundle(preKeyCount: amount)
            let response = try await request(
                "PUT",
                "/api/e2ee/libsignal/device-bundle",
                body: [
                    "deviceId": AloE2EECrypto.shared.deviceId,
                    "bundle": [
                        "protocolDeviceId": Int(bundle.protocolDeviceId),
                        "registrationId": Int(bundle.registrationId),
                        "identityKey": bundle.identityKey.base64EncodedString(),
                        "signedPreKeyId": Int(bundle.signedPreKeyId),
                        "signedPreKey": bundle.signedPreKey.base64EncodedString(),
                        "signedPreKeySignature": bundle.signedPreKeySignature.base64EncodedString(),
                        "preKeys": bundle.preKeys.map { preKey in
                            [
                                "preKeyId": Int(preKey.preKeyId),
                                "preKey": preKey.preKey.base64EncodedString(),
                                "kyberPreKeyId": Int(preKey.kyberPreKeyId),
                                "kyberPreKey": preKey.kyberPreKey.base64EncodedString(),
                                "kyberPreKeySignature": preKey.kyberPreKeySignature.base64EncodedString()
                            ]
                        }
                    ]
                ]
            )
            defaults.set(true, forKey: markerKey)
            if response.bool("keyChanged") {
                latestE2EEWarning =
                    "Libsignal identity этого устройства изменилась. Проверьте safety number активных диалогов."
            }
        } catch let error as AloAPIError {
            if error.code == "E2EE_DEVICE_LIMIT_REACHED" ||
                error.code == "LIBSIGNAL_DEVICE_SLOT_MISMATCH" ||
                error.code == "LIBSIGNAL_PREKEY_ID_COLLISION" {
                latestE2EEWarning = error.message
            }
        } catch {
            // Bootstrap and the encrypted offline cache remain available while registration retries later.
        }
    }

    private func libSignalData(_ value: String) -> Data? {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }

    private func parseLibSignalDevice(
        userId: Int,
        json: [String: Any]
    ) -> AloLibSignalRemoteDevice? {
        let deviceId = json.string("deviceId")
        let protocolDeviceId = json.int("protocolDeviceId")
        let registrationId = json.int("registrationId")
        guard userId > 0,
              !deviceId.isEmpty,
              (1...127).contains(protocolDeviceId),
              (1...16_380).contains(registrationId),
              let identityKey = libSignalData(json.string("identityKey")), identityKey.count == 33,
              let signedPreKey = libSignalData(json.string("signedPreKey")), signedPreKey.count == 33,
              let signedSignature = libSignalData(json.string("signedPreKeySignature")),
              signedSignature.count == 64,
              json.int("signedPreKeyId") > 0 else {
            return nil
        }
        var preKeyBundle: AloLibSignalPreKeyBundle?
        if let oneTime = json.optionalObject("oneTimePreKey"), !oneTime.isEmpty,
           let preKey = libSignalData(oneTime.string("preKey")), preKey.count == 33,
           let kyberPreKey = libSignalData(oneTime.string("kyberPreKey")), !kyberPreKey.isEmpty,
           let kyberSignature = libSignalData(oneTime.string("kyberPreKeySignature")),
           kyberSignature.count == 64,
           oneTime.int("preKeyId") > 0,
           oneTime.int("kyberPreKeyId") > 0 {
            preKeyBundle = AloLibSignalPreKeyBundle(
                registrationId: UInt32(registrationId),
                deviceId: UInt32(protocolDeviceId),
                identityKey: identityKey,
                preKeyId: UInt32(oneTime.int("preKeyId")),
                preKey: preKey,
                signedPreKeyId: UInt32(json.int("signedPreKeyId")),
                signedPreKey: signedPreKey,
                signedPreKeySignature: signedSignature,
                kyberPreKeyId: UInt32(oneTime.int("kyberPreKeyId")),
                kyberPreKey: kyberPreKey,
                kyberPreKeySignature: kyberSignature
            )
        }
        return AloLibSignalRemoteDevice(
            userId: userId,
            deviceId: deviceId,
            protocolDeviceId: UInt32(protocolDeviceId),
            identityKey: identityKey,
            identityFingerprint: json.string("identityFingerprint").lowercased(),
            preKeyBundle: preKeyBundle
        )
    }

    private func validateLibSignalIdentity(_ device: AloLibSignalRemoteDevice) throws {
        let digest = SHA256.hash(data: device.identityKey).map { String(format: "%02x", $0) }.joined()
        let computed = stride(from: 0, to: 60, by: 5).map { offset -> String in
            let start = digest.index(digest.startIndex, offsetBy: offset)
            let end = digest.index(start, offsetBy: 5)
            return String(digest[start..<end])
        }.joined(separator: "-")
        if !device.identityFingerprint.isEmpty, device.identityFingerprint != computed {
            throw AloAPIError(
                status: -1,
                code: "LIBSIGNAL_IDENTITY_FINGERPRINT_INVALID",
                message: "Отпечаток libsignal identity не прошёл локальную проверку.",
                payload: [:]
            )
        }
        let storageKey = "alo.ios.libsignal.v1.trust.\(currentUserId).\(device.userId).\(device.deviceId)"
        let defaults = UserDefaults.standard
        if let previous = defaults.string(forKey: storageKey), !previous.isEmpty, previous != computed {
            throw AloAPIError(
                status: -1,
                code: "E2EE_KEY_CHANGED",
                message: "Ключ безопасности устройства собеседника изменился. Проверьте safety number.",
                payload: [:]
            )
        }
        defaults.set(computed, forKey: storageKey)
    }

    private func loadLibSignalUserDevices(
        userId: Int,
        includePreKeys: Bool,
        targets: [AloLibSignalRemoteDevice] = []
    ) async throws -> [AloLibSignalRemoteDevice] {
        let targetQuery = targets.prefix(128).map { "\($0.userId):\($0.deviceId)" }.joined(separator: ",")
        var path = "/api/e2ee/libsignal/bundles/\(userId)"
        path += "?requesterDeviceId=\(AloE2EECrypto.shared.deviceId)"
        path += "&includePreKeys=\(includePreKeys ? 1 : 0)"
        if !targetQuery.isEmpty { path += "&preKeyTargets=\(targetQuery)" }
        let response = try await request("GET", path)
        guard response.bool("migrationReady") else { return [] }
        return response.array("devices").compactMap { parseLibSignalDevice(userId: userId, json: $0) }
    }

    private func loadLibSignalDirectRecipients(peerId: Int) async throws -> [AloLibSignalRemoteDevice] {
        guard let engine = libSignalEngine, peerId > 0, currentUserId > 0 else { return [] }
        let peerBase = try await loadLibSignalUserDevices(userId: peerId, includePreKeys: false)
        guard !peerBase.isEmpty else { return [] }
        let selfBase = peerId == currentUserId
            ? []
            : try await loadLibSignalUserDevices(userId: currentUserId, includePreKeys: false)
        let base = (peerBase + selfBase).filter {
            !($0.userId == currentUserId &&
              $0.deviceId == AloE2EECrypto.shared.deviceId &&
              $0.protocolDeviceId == libSignalProtocolDeviceId)
        }
        let missing = base.filter {
            !engine.hasSession(remoteUserId: $0.userId, remoteDeviceId: $0.protocolDeviceId)
        }
        guard !missing.isEmpty else { return base }

        var refreshed = [AloLibSignalRemoteDevice]()
        for (userId, targets) in Dictionary(grouping: missing, by: \.userId) {
            refreshed += try await loadLibSignalUserDevices(
                userId: userId,
                includePreKeys: true,
                targets: targets
            )
        }
        let byAddress = Dictionary(uniqueKeysWithValues: refreshed.map { ("\($0.userId):\($0.deviceId)", $0) })
        return base.map { byAddress["\($0.userId):\($0.deviceId)"] ?? $0 }
    }

    private func loadLibSignalGroupRecipients(roomId: Int) async throws -> AloLibSignalGroupRecipients {
        guard let engine = libSignalEngine else {
            return AloLibSignalGroupRecipients(roomId: roomId, epoch: 0, complete: false, devices: [])
        }
        func parse(_ response: [String: Any]) -> AloLibSignalGroupRecipients {
            let members = response.array("members")
            var devices = [AloLibSignalRemoteDevice]()
            var complete = !members.isEmpty
            for member in members {
                let userId = member.int("userId")
                if !member.bool("migrationReady") { complete = false }
                let memberDevices = member.array("devices").compactMap {
                    parseLibSignalDevice(userId: userId, json: $0)
                }
                if memberDevices.isEmpty { complete = false }
                devices += memberDevices
            }
            return AloLibSignalGroupRecipients(
                roomId: response.int("roomId").ifZero(roomId),
                epoch: response.int("epoch"),
                complete: complete,
                devices: devices
            )
        }

        for _ in 0..<2 {
            let base = parse(try await request(
                "GET",
                "/api/e2ee/libsignal/group-bundles/\(roomId)?requesterDeviceId=\(AloE2EECrypto.shared.deviceId)&includePreKeys=0"
            ))
            if !base.complete || base.epoch <= 0 { return base }
            let activeDevices = base.devices.filter {
                !($0.userId == currentUserId &&
                  $0.deviceId == AloE2EECrypto.shared.deviceId &&
                  $0.protocolDeviceId == libSignalProtocolDeviceId)
            }
            let missing = activeDevices.filter {
                !engine.hasSession(remoteUserId: $0.userId, remoteDeviceId: $0.protocolDeviceId)
            }
            if missing.isEmpty {
                return AloLibSignalGroupRecipients(
                    roomId: base.roomId,
                    epoch: base.epoch,
                    complete: base.complete,
                    devices: activeDevices
                )
            }
            let targets = missing.prefix(128).map { "\($0.userId):\($0.deviceId)" }.joined(separator: ",")
            let refreshed = parse(try await request(
                "GET",
                "/api/e2ee/libsignal/group-bundles/\(roomId)?requesterDeviceId=\(AloE2EECrypto.shared.deviceId)&includePreKeys=1&preKeyTargets=\(targets)"
            ))
            if refreshed.epoch != base.epoch { continue }
            return AloLibSignalGroupRecipients(
                roomId: refreshed.roomId,
                epoch: refreshed.epoch,
                complete: refreshed.complete,
                devices: refreshed.devices.filter {
                    !($0.userId == currentUserId &&
                      $0.deviceId == AloE2EECrypto.shared.deviceId &&
                      $0.protocolDeviceId == libSignalProtocolDeviceId)
                }
            )
        }
        throw AloAPIError(
            status: -1,
            code: "LIBSIGNAL_GROUP_EPOCH_CHANGED",
            message: "Состав группы изменился во время подготовки сообщения. Повторите отправку.",
            payload: [:]
        )
    }

    private func prepareLibSignalGroupMessagePayload(
        peerId: Int,
        roomId: Int,
        kind: String,
        body: String,
        attachments: [AloMessageAttachment],
        forwardFrom: AloForwardMeta?
    ) async throws -> [String: Any]? {
        guard let engine = libSignalEngine, let store = libSignalStore else { return nil }
        guard kind == "group" || roomId > 0 || peerId >= 1_000_000_000 else { return nil }
        let resolvedRoomId = roomId > 0 ? roomId : peerId - 1_000_000_000
        guard resolvedRoomId > 0 else { return nil }
        let markerKey = "alo.ios.libsignal.v1.required.group.\(currentUserId).\(resolvedRoomId)"
        let state: AloLibSignalGroupRecipients
        do {
            state = try await loadLibSignalGroupRecipients(roomId: resolvedRoomId)
        } catch {
            if UserDefaults.standard.bool(forKey: markerKey) { throw error }
            return nil
        }
        guard state.complete, state.epoch > 0, !state.devices.isEmpty, state.devices.count <= 128 else {
            if UserDefaults.standard.bool(forKey: markerKey) {
                throw AloAPIError(
                    status: -1,
                    code: "LIBSIGNAL_GROUP_KEYS_MISSING",
                    message: "Не все участники группы зарегистрировали libsignal-устройства.",
                    payload: [:]
                )
            }
            return nil
        }
        for recipient in state.devices { try validateLibSignalIdentity(recipient) }
        for recipient in state.devices where !engine.hasSession(
            remoteUserId: recipient.userId,
            remoteDeviceId: recipient.protocolDeviceId
        ) {
            guard let bundle = recipient.preKeyBundle else {
                throw AloAPIError(
                    status: -1,
                    code: "LIBSIGNAL_PREKEYS_MISSING",
                    message: "На одном из устройств группы закончились PQXDH-ключи.",
                    payload: [:]
                )
            }
            try engine.processRemotePreKeyBundle(remoteUserId: recipient.userId, bundle: bundle)
        }

        let distributionStorageKey =
            "alo.ios.libsignal.v1.sender-key.\(currentUserId).\(libSignalProtocolDeviceId).\(resolvedRoomId).\(state.epoch)"
        let defaults = UserDefaults.standard
        let distributionId: UUID
        if let raw = defaults.string(forKey: distributionStorageKey), let existing = UUID(uuidString: raw) {
            distributionId = existing
        } else {
            distributionId = UUID()
            defaults.set(distributionId.uuidString.lowercased(), forKey: distributionStorageKey)
        }
        let distribution = try engine.createSenderKeyDistribution(distributionId: distributionId)
        let contextId = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        var content: [String: Any] = [
            "v": 3,
            "body": body,
            "attachments": attachments.map(messageAttachmentPayload),
            "sentAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let forwardFrom {
            content["forwardFrom"] = ["userId": forwardFrom.userId, "messageId": forwardFrom.messageId]
        }
        let plaintext = try JSONSerialization.data(withJSONObject: content)
        var distributionEnvelopes = [[String: Any]]()
        for recipient in state.devices {
            let ciphertext = try engine.encrypt(
                remoteUserId: recipient.userId,
                remoteDeviceId: recipient.protocolDeviceId,
                plaintext: distribution
            )
            var envelope: [String: Any] = [
                "userId": recipient.userId,
                "deviceId": recipient.deviceId,
                "protocolDeviceId": Int(recipient.protocolDeviceId),
                "ciphertextType": Int(ciphertext.type),
                "ciphertext": ciphertext.bytes.base64EncodedString()
            ]
            if ciphertext.type == CiphertextMessage.MessageType.preKey.rawValue,
               let bundle = recipient.preKeyBundle {
                envelope["preKeyId"] = Int(bundle.preKeyId)
                envelope["kyberPreKeyId"] = Int(bundle.kyberPreKeyId)
            }
            distributionEnvelopes.append(envelope)
        }
        let groupCiphertext = try engine.groupEncrypt(distributionId: distributionId, plaintext: plaintext)
        try store.storeMessagePlaintext(contextId: contextId, plaintext: plaintext)
        defaults.set(true, forKey: markerKey)
        return [
            "scheme": "alo-libsignal-v1",
            "protocolVersion": 1,
            "mode": "sender-key",
            "purpose": "message",
            "contextId": contextId,
            "senderUserId": currentUserId,
            "senderDeviceId": AloE2EECrypto.shared.deviceId,
            "senderProtocolDeviceId": Int(libSignalProtocolDeviceId),
            "group": [
                "roomId": resolvedRoomId,
                "epoch": state.epoch,
                "distributionId": distributionId.uuidString.lowercased(),
                "ciphertext": groupCiphertext.base64EncodedString()
            ],
            "recipients": distributionEnvelopes
        ]
    }

    private func prepareLibSignalDirectMessagePayload(
        peerId: Int,
        roomId: Int,
        kind: String,
        body: String,
        attachments: [AloMessageAttachment],
        forwardFrom: AloForwardMeta?
    ) async throws -> [String: Any]? {
        guard let engine = libSignalEngine, let store = libSignalStore else { return nil }
        guard kind != "group", roomId <= 0, peerId < 1_000_000_000 else { return nil }
        // A Signal session cannot target the same local device. Saved Messages use
        // the signed multi-device E2EE envelope, which includes this device too.
        guard peerId != currentUserId else { return nil }
        let markerKey = "alo.ios.libsignal.v1.required.direct.\(currentUserId).\(peerId)"
        let recipients: [AloLibSignalRemoteDevice]
        do {
            recipients = try await loadLibSignalDirectRecipients(peerId: peerId)
        } catch {
            if UserDefaults.standard.bool(forKey: markerKey) { throw error }
            return nil
        }
        guard recipients.contains(where: { $0.userId == peerId }) else {
            if UserDefaults.standard.bool(forKey: markerKey) {
                throw AloAPIError(
                    status: -1,
                    code: "LIBSIGNAL_KEYS_MISSING",
                    message: "У собеседника пропали ранее подтверждённые libsignal-ключи.",
                    payload: [:]
                )
            }
            return nil
        }
        for recipient in recipients { try validateLibSignalIdentity(recipient) }

        let contextId = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        var content: [String: Any] = [
            "v": 3,
            "body": body,
            "attachments": attachments.map(messageAttachmentPayload),
            "sentAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let forwardFrom {
            content["forwardFrom"] = ["userId": forwardFrom.userId, "messageId": forwardFrom.messageId]
        }
        let plaintext = try JSONSerialization.data(withJSONObject: content)
        var envelopes = [[String: Any]]()
        for recipient in recipients {
            let hadSession = engine.hasSession(
                remoteUserId: recipient.userId,
                remoteDeviceId: recipient.protocolDeviceId
            )
            if !hadSession {
                guard let bundle = recipient.preKeyBundle else {
                    throw AloAPIError(
                        status: -1,
                        code: "LIBSIGNAL_PREKEYS_MISSING",
                        message: "На устройстве получателя закончились одноразовые PQXDH-ключи.",
                        payload: [:]
                    )
                }
                try validateLibSignalIdentity(recipient)
                try engine.processRemotePreKeyBundle(remoteUserId: recipient.userId, bundle: bundle)
            }
            let ciphertext = try engine.encrypt(
                remoteUserId: recipient.userId,
                remoteDeviceId: recipient.protocolDeviceId,
                plaintext: plaintext
            )
            var envelope: [String: Any] = [
                "userId": recipient.userId,
                "deviceId": recipient.deviceId,
                "protocolDeviceId": Int(recipient.protocolDeviceId),
                "ciphertextType": Int(ciphertext.type),
                "ciphertext": ciphertext.bytes.base64EncodedString()
            ]
            if ciphertext.type == CiphertextMessage.MessageType.preKey.rawValue,
               let bundle = recipient.preKeyBundle {
                envelope["preKeyId"] = Int(bundle.preKeyId)
                envelope["kyberPreKeyId"] = Int(bundle.kyberPreKeyId)
            }
            envelopes.append(envelope)
        }
        try store.storeMessagePlaintext(contextId: contextId, plaintext: plaintext)
        UserDefaults.standard.set(true, forKey: markerKey)
        return [
            "scheme": "alo-libsignal-v1",
            "protocolVersion": 1,
            "purpose": "message",
            "contextId": contextId,
            "senderUserId": currentUserId,
            "senderDeviceId": AloE2EECrypto.shared.deviceId,
            "senderProtocolDeviceId": Int(libSignalProtocolDeviceId),
            "recipients": envelopes
        ]
    }

    private func prepareLibSignalDirectCallPayload(
        peerId: Int,
        payload: [String: Any]
    ) async throws -> [String: Any]? {
        guard let engine = libSignalEngine, let store = libSignalStore else { return nil }
        guard peerId > 0, peerId != currentUserId else { return nil }
        let recipients = try await loadLibSignalDirectRecipients(peerId: peerId)
        guard recipients.contains(where: { $0.userId == peerId }) else { return nil }
        for recipient in recipients { try validateLibSignalIdentity(recipient) }

        let contextId = "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let content: [String: Any] = [
            "v": 3,
            "type": "directCallSignal",
            "payload": payload,
            "sentAt": ISO8601DateFormatter().string(from: Date())
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: content)
        var envelopes = [[String: Any]]()
        for recipient in recipients {
            if !engine.hasSession(
                remoteUserId: recipient.userId,
                remoteDeviceId: recipient.protocolDeviceId
            ) {
                guard let bundle = recipient.preKeyBundle else {
                    throw AloAPIError(
                        status: -1,
                        code: "LIBSIGNAL_PREKEYS_MISSING",
                        message: "На устройстве собеседника закончились одноразовые ключи звонка.",
                        payload: [:]
                    )
                }
                try engine.processRemotePreKeyBundle(remoteUserId: recipient.userId, bundle: bundle)
            }
            let ciphertext = try engine.encrypt(
                remoteUserId: recipient.userId,
                remoteDeviceId: recipient.protocolDeviceId,
                plaintext: plaintext
            )
            var envelope: [String: Any] = [
                "userId": recipient.userId,
                "deviceId": recipient.deviceId,
                "protocolDeviceId": Int(recipient.protocolDeviceId),
                "ciphertextType": Int(ciphertext.type),
                "ciphertext": ciphertext.bytes.base64EncodedString()
            ]
            if ciphertext.type == CiphertextMessage.MessageType.preKey.rawValue,
               let bundle = recipient.preKeyBundle {
                envelope["preKeyId"] = Int(bundle.preKeyId)
                envelope["kyberPreKeyId"] = Int(bundle.kyberPreKeyId)
            }
            envelopes.append(envelope)
        }
        try store.storeMessagePlaintext(contextId: contextId, plaintext: plaintext)
        return [
            "scheme": "alo-libsignal-v1",
            "protocolVersion": 1,
            "purpose": "call",
            "contextId": contextId,
            "senderUserId": currentUserId,
            "senderDeviceId": AloE2EECrypto.shared.deviceId,
            "senderProtocolDeviceId": Int(libSignalProtocolDeviceId),
            "recipients": envelopes
        ]
    }

    private func buildEncryptedDirectCallSignalPayload(
        peerId: Int,
        payload: [String: Any]
    ) async throws -> [String: Any] {
        if currentUserId > 0 {
            await registerE2EEDeviceKeyIfPossible(currentUserId: currentUserId)
            if let latestE2EERegistrationError { throw latestE2EERegistrationError }
            await registerLibSignalDeviceIfPossible(currentUserId: currentUserId)
        }
        if let encrypted = try await prepareLibSignalDirectCallPayload(
            peerId: peerId,
            payload: payload
        ) {
            return [
                "format": "alo-direct-call-signal-e2ee-v1",
                "encrypted": encrypted
            ]
        }

        let recipientKeys = try await loadE2EERecipientKeys(
            peerId: peerId,
            roomId: 0,
            kind: "direct"
        )
        let verifiableRecipientKeys = recipientKeys.filter {
            $0.signingPublicKeyJwk != nil && !$0.identityFingerprint.isEmpty
        }
        let recipientUserIds = Set(verifiableRecipientKeys.map(\.userId))
        guard recipientUserIds.contains(peerId),
              currentUserId <= 0 || recipientUserIds.contains(currentUserId) else {
            throw AloAPIError(
                status: -1,
                code: "E2EE_KEYS_MISSING",
                message: "Собеседник ещё регистрирует ключи защищённого звонка.",
                payload: [:]
            )
        }
        try AloE2EETrustStore.shared.validate(
            verifiableRecipientKeys,
            currentUserId: currentUserId
        )
        let contextId = "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let plaintext = try JSONSerialization.data(withJSONObject: [
            "v": 2,
            "type": "directCallSignal",
            "payload": payload,
            "sentAt": ISO8601DateFormatter().string(from: Date())
        ])
        let recipients = try verifiableRecipientKeys.map { key in
            try AloE2EECrypto.shared.encrypt(
                plaintext,
                for: key,
                senderUserId: currentUserId,
                purpose: "call",
                contextId: contextId,
                useV2: true,
                allowRatchetBootstrap: true
            )
        }
        return [
            "format": "alo-direct-call-signal-e2ee-v1",
            "encrypted": [
                "scheme": AloE2EECrypto.messageSchemeV2,
                "recipients": recipients
            ]
        ]
    }

    private func decryptDirectCallSignalPayload(_ payload: [String: Any]) -> [String: Any] {
        guard let encrypted = payload.optionalObject("encrypted") else { return payload }
        do {
            let plaintext: Data
            if encrypted.string("scheme") == "alo-libsignal-v1" {
                plaintext = try decryptLibSignalPayload(encrypted)
            } else {
                try AloE2EETrustStore.shared.validateEmbeddedSender(
                    encrypted,
                    currentUserId: currentUserId
                )
                plaintext = try AloE2EECrypto.shared.decrypt(encryptedPayload: encrypted)
            }
            guard let decoded = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
                return [:]
            }
            return decoded.optionalObject("payload") ?? decoded
        } catch {
            latestE2EEWarning = "Не удалось проверить защищённый сигнал звонка."
            return [:]
        }
    }

    private func decryptLibSignalPayload(_ encryptedPayload: [String: Any]) throws -> Data {
        guard let engine = libSignalEngine, let store = libSignalStore else {
            throw AloE2EECryptoError.invalidPayload
        }
        let contextId = encryptedPayload.string("contextId")
        if let cached = try store.loadMessagePlaintext(contextId: contextId) { return cached }
        let senderUserId = encryptedPayload.int("senderUserId")
        let senderProtocolDeviceId = encryptedPayload.int("senderProtocolDeviceId")
        guard senderUserId > 0, (1...127).contains(senderProtocolDeviceId) else {
            throw AloE2EECryptoError.invalidPayload
        }
        guard let envelope = encryptedPayload.array("recipients").first(where: {
            $0.int("userId") == currentUserId &&
                $0.string("deviceId") == AloE2EECrypto.shared.deviceId &&
                $0.int("protocolDeviceId") == Int(libSignalProtocolDeviceId)
        }),
              let ciphertext = libSignalData(envelope.string("ciphertext")) else {
            throw AloE2EECryptoError.missingRecipient
        }
        let plaintext: Data
        if encryptedPayload.string("mode") == "sender-key" {
            let distributionContextId = "dist_\(contextId)"
            let distribution: Data
            if let cached = try store.loadMessagePlaintext(contextId: distributionContextId) {
                distribution = cached
            } else {
                distribution = try engine.decrypt(
                    remoteUserId: senderUserId,
                    remoteDeviceId: UInt32(senderProtocolDeviceId),
                    ciphertextType: UInt8(envelope.int("ciphertextType")),
                    ciphertext: ciphertext
                )
                try store.storeMessagePlaintext(contextId: distributionContextId, plaintext: distribution)
            }
            try engine.processSenderKeyDistribution(
                remoteUserId: senderUserId,
                remoteDeviceId: UInt32(senderProtocolDeviceId),
                serialized: distribution
            )
            let group = encryptedPayload.object("group")
            guard UUID(uuidString: group.string("distributionId")) != nil,
                  let groupCiphertext = libSignalData(group.string("ciphertext")) else {
                throw AloE2EECryptoError.invalidPayload
            }
            plaintext = try engine.groupDecrypt(
                remoteUserId: senderUserId,
                remoteDeviceId: UInt32(senderProtocolDeviceId),
                ciphertext: groupCiphertext
            )
        } else {
            plaintext = try engine.decrypt(
                remoteUserId: senderUserId,
                remoteDeviceId: UInt32(senderProtocolDeviceId),
                ciphertextType: UInt8(envelope.int("ciphertextType")),
                ciphertext: ciphertext
            )
        }
        try store.storeMessagePlaintext(contextId: contextId, plaintext: plaintext)
        return plaintext
    }

    func prepareEncryptedMessagePayload(
        peerId: Int,
        roomId: Int,
        kind: String,
        body: String,
        attachments: [AloMessageAttachment],
        forwardFrom: AloForwardMeta?
    ) async throws -> [String: Any] {
        if currentUserId > 0 {
            await registerE2EEDeviceKeyIfPossible(currentUserId: currentUserId)
            if let latestE2EERegistrationError { throw latestE2EERegistrationError }
            await registerLibSignalDeviceIfPossible(currentUserId: currentUserId)
        }
        if let libSignal = try await prepareLibSignalGroupMessagePayload(
            peerId: peerId,
            roomId: roomId,
            kind: kind,
            body: body,
            attachments: attachments,
            forwardFrom: forwardFrom
        ) {
            return libSignal
        }
        if let libSignal = try await prepareLibSignalDirectMessagePayload(
            peerId: peerId,
            roomId: roomId,
            kind: kind,
            body: body,
            attachments: attachments,
            forwardFrom: forwardFrom
        ) {
            return libSignal
        }
        let recipientKeys = try await loadE2EERecipientKeys(peerId: peerId, roomId: roomId, kind: kind)
        guard !recipientKeys.isEmpty else {
            throw AloAPIError(
                status: -1,
                code: "E2EE_KEYS_MISSING",
                message: "Не удалось получить ключи шифрования для этого чата.",
                payload: [:]
            )
        }
        do {
            try AloE2EETrustStore.shared.validate(recipientKeys, currentUserId: currentUserId)
        } catch let error as AloAPIError {
            latestE2EEWarning = error.message
            throw error
        }

        var useV2 = recipientKeys.allSatisfy {
            $0.signingPublicKeyJwk != nil && !$0.identityFingerprint.isEmpty
        }
        let isSavedMessages = kind != "group" && roomId <= 0 && peerId == currentUserId
        let contextId = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        var content: [String: Any?] = [
            "v": useV2 ? 2 : 1,
            "body": body,
            "attachments": attachments.map(messageAttachmentPayload),
            "sentAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let forwardFrom {
            content["forwardFrom"] = [
                "userId": forwardFrom.userId,
                "messageId": forwardFrom.messageId
            ]
        }
        let plaintext = try JSONSerialization.data(withJSONObject: compactBody(content))
        let recipients: [[String: Any]]
        do {
            recipients = try recipientKeys.map { key in
                try AloE2EECrypto.shared.encrypt(
                    plaintext,
                    for: key,
                    senderUserId: currentUserId,
                    purpose: "message",
                    contextId: contextId,
                    useV2: useV2,
                    allowRatchetBootstrap: !isSavedMessages
                )
            }
        } catch AloE2EECryptoError.missingRecipient where isSavedMessages && useV2 {
            useV2 = false
            recipients = try encryptSavedMessagesStaticEnvelope(plaintext, recipientKeys: recipientKeys, contextId: contextId)
        } catch AloE2EECryptoError.keyStorageFailed where isSavedMessages && useV2 {
            useV2 = false
            recipients = try encryptSavedMessagesStaticEnvelope(plaintext, recipientKeys: recipientKeys, contextId: contextId)
        } catch AloE2EECryptoError.invalidKey where isSavedMessages && useV2 {
            useV2 = false
            recipients = try encryptSavedMessagesStaticEnvelope(plaintext, recipientKeys: recipientKeys, contextId: contextId)
        }
        return [
            "scheme": useV2 ? AloE2EECrypto.messageSchemeV2 : AloE2EECrypto.scheme,
            "recipients": recipients
        ]
    }

    private func encryptSavedMessagesStaticEnvelope(
        _ plaintext: Data,
        recipientKeys: [AloE2EERecipientKey],
        contextId: String
    ) throws -> [[String: Any]] {
        try recipientKeys.map { key in
            try AloE2EECrypto.shared.encrypt(
                plaintext,
                for: key,
                senderUserId: currentUserId,
                purpose: "message",
                contextId: contextId,
                useV2: false,
                allowRatchetBootstrap: false
            )
        }
    }

    private func loadE2EERecipientKeys(peerId: Int, roomId: Int, kind: String) async throws -> [AloE2EERecipientKey] {
        func parseGroupKeys(_ raw: [String: Any]) -> [AloE2EERecipientKey] {
            raw.array("members").flatMap { member -> [AloE2EERecipientKey] in
                let userId = member.int("userId")
                return member.array("keys").compactMap { AloE2EERecipientKey(userId: userId, json: $0) }
            }
        }

        func parseUserKeys(userId: Int, raw: [String: Any]) -> [AloE2EERecipientKey] {
            raw.array("keys").compactMap { AloE2EERecipientKey(userId: userId, json: $0) }
        }

        func missingTargets(_ keys: [AloE2EERecipientKey]) -> [AloE2EERecipientKey] {
            keys.filter {
                !AloE2EECrypto.shared.hasConfirmedRatchetSession(
                    userId: $0.userId,
                    deviceId: $0.deviceId,
                    useV2: $0.signingPublicKeyJwk != nil && !$0.identityFingerprint.isEmpty
                )
            }
        }

        func targetQuery(_ keys: [AloE2EERecipientKey]) -> String {
            keys.prefix(64).map { "\($0.userId):\($0.deviceId)" }.joined(separator: ",")
        }

        let requesterDeviceId = AloE2EECrypto.shared.deviceId

        if kind == "group", roomId > 0 {
            let baseKeys = parseGroupKeys(try await request("GET", "/api/e2ee/group-keys/\(roomId)"))
            let missing = missingTargets(baseKeys)
            if missing.isEmpty { return baseKeys }
            let raw = try await request(
                "GET",
                "/api/e2ee/group-keys/\(roomId)?includePreKeys=1&requesterDeviceId=\(requesterDeviceId)&preKeyTargets=\(targetQuery(missing))"
            )
            return parseGroupKeys(raw)
        }

        func loadUserKeys(_ userId: Int) async throws -> [AloE2EERecipientKey] {
            let baseKeys = parseUserKeys(
                userId: userId,
                raw: try await request("GET", "/api/e2ee/keys/\(userId)")
            )
            let missing = missingTargets(baseKeys)
            if missing.isEmpty { return baseKeys }
            return parseUserKeys(
                userId: userId,
                raw: try await request(
                    "GET",
                    "/api/e2ee/keys/\(userId)?includePreKeys=1&requesterDeviceId=\(requesterDeviceId)&preKeyTargets=\(targetQuery(missing))"
                )
            )
        }

        var collected = [AloE2EERecipientKey]()
        collected += try await loadUserKeys(peerId)
        if peerId == currentUserId {
            let signedKeys = collected.filter {
                $0.signingPublicKeyJwk != nil && !$0.identityFingerprint.isEmpty
            }
            if !signedKeys.isEmpty {
                collected = signedKeys
            }
        }
        if currentUserId > 0, currentUserId != peerId {
            collected += try await loadUserKeys(currentUserId)
        }
        let users = Set(collected.map(\.userId))
        guard users.contains(peerId), currentUserId <= 0 || users.contains(currentUserId) else {
            throw AloAPIError(
                status: -1,
                code: "E2EE_KEYS_MISSING",
                message: "У одного из участников чата ещё нет ключа шифрования. Откройте Alo на обоих устройствах и попробуйте снова.",
                payload: [:]
            )
        }
        return collected
    }

    private func decryptE2EEMessages(inBootstrap raw: [String: Any]) async -> [String: Any] {
        var next = raw
        guard var data = next["data"] as? [String: Any] else { return raw }
        if var messages = data["messages"] as? [String: Any] {
            if let items = messages["items"] as? [[String: Any]] {
                var decryptedItems = [[String: Any]]()
                for item in items {
                    decryptedItems.append(await decryptE2EEMessageJSON(item))
                }
                messages["items"] = decryptedItems
            }
            if let conversations = messages["conversations"] as? [[String: Any]] {
                var decryptedConversations = [[String: Any]]()
                for rawConversation in conversations {
                    var conversation = rawConversation
                    if let lastMessage = rawConversation["lastMessage"] as? [String: Any] {
                        let decryptedLastMessage = await decryptE2EEMessageJSON(lastMessage)
                        conversation["lastMessage"] = decryptedLastMessage
                        let preview = conversationPreview(decryptedLastMessage)
                        if !preview.isEmpty {
                            conversation["lastBody"] = preview
                        }
                    }
                    decryptedConversations.append(conversation)
                }
                messages["conversations"] = decryptedConversations
            }
            data["messages"] = messages
        }
        next["data"] = data
        return next
    }

    private func conversationPreview(_ message: [String: Any]) -> String {
        let body = message.string("body").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body }
        let firstAttachment = message.array("attachments").first
        let type = message.string("attachmentType")
            .ifBlank(firstAttachment?.string("type") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if type == "voice" || type.hasPrefix("audio") { return "Голосовое сообщение" }
        if type == "circle" || type == "video_circle" || type == "video-circle" { return "Видеосообщение" }
        if type == "call" { return "Звонок" }
        if type == "image" || type.hasPrefix("image/") { return "Фото" }
        if type == "video" || type.hasPrefix("video/") { return "Видео" }
        if !type.isEmpty || firstAttachment != nil { return "Вложение" }
        return ""
    }

    private func decryptE2EEMessages(inConversation raw: [String: Any]) async -> [String: Any] {
        var next = raw
        if let items = next["items"] as? [[String: Any]] {
            var decryptedItems = [[String: Any]]()
            for item in items {
                decryptedItems.append(await decryptE2EEMessageJSON(item))
            }
            next["items"] = decryptedItems
        }
        return next
    }

    private func decryptE2EEMessageJSON(_ raw: [String: Any]) async -> [String: Any] {
        guard let encrypted = raw.optionalObject("encryptedPayload") else { return raw }
        let decrypted: Data
        let object: [String: Any]
        do {
            if encrypted.string("scheme") == "alo-libsignal-v1" {
                decrypted = try decryptLibSignalPayload(encrypted)
            } else {
                try AloE2EETrustStore.shared.validateEmbeddedSender(
                    encrypted,
                    currentUserId: currentUserId
                )
                decrypted = try AloE2EECrypto.shared.decrypt(encryptedPayload: encrypted)
            }
            guard let decoded = try JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else {
                throw AloE2EECryptoError.invalidPayload
            }
            object = decoded
        } catch {
            let scheme = raw.string("encryptionScheme")
            if (scheme == AloE2EECrypto.scheme ||
                scheme == AloE2EECrypto.messageSchemeV2 ||
                scheme == "alo-libsignal-v1"),
               raw.string("body").isEmpty {
                var fallback = raw
                fallback["body"] = "Не удалось расшифровать сообщение"
                return fallback
            }
            return raw
        }

        var next = raw
        if let body = object["body"] as? String {
            next["body"] = body
        }
        if let attachments = object["attachments"] as? [[String: Any]] {
            let resolvedAttachments = await resolveDecryptedMediaAttachments(attachments)
            next["attachments"] = resolvedAttachments
            if let first = resolvedAttachments.first {
                next["attachmentUrl"] = first.string("url")
                next["attachmentType"] = first.string("type")
                next["attachmentName"] = first.string("name")
            }
        }
        if let forwardFrom = object["forwardFrom"] as? [String: Any], raw["forwardFrom"] == nil {
            next["forwardFrom"] = forwardFrom
        }
        return next
    }

    private func resolveDecryptedMediaAttachments(_ attachments: [[String: Any]]) async -> [[String: Any]] {
        var resolved = [[String: Any]]()
        for attachment in attachments {
            resolved.append(await resolveDecryptedMediaAttachment(attachment))
        }
        return resolved
    }

    private func resolveDecryptedMediaAttachment(_ attachment: [String: Any]) async -> [String: Any] {
        let encryption = attachment.object("mediaEncryption").isEmpty ? attachment.object("e2ee") : attachment.object("mediaEncryption")
        guard encryption.string("algorithm") == AloE2EECrypto.mediaScheme else { return attachment }
        let remoteUrl = attachment.string("url")
        guard !remoteUrl.isEmpty else { return attachment }

        cleanupDecodedMediaCacheIfNeeded()
        let encryptedCacheURL = encryptedMediaCacheURL(
            remoteUrl: remoteUrl,
            encryption: encryption
        )
        do {
            if !FileManager.default.fileExists(atPath: encryptedCacheURL.path) {
                let encryptedBytes = try await downloadRawData(remoteUrl)
                try writeProtectedCacheData(encryptedBytes, to: encryptedCacheURL)
            }
            let secureURL = try AloSecureMediaStore.shared.register(
                encryptedURL: encryptedCacheURL,
                encryption: encryption,
                type: attachment.string("type"),
                name: attachment.string("name")
            )
            var next = attachment
            next["url"] = secureURL.absoluteString
            if attachment.string("type") == "image" {
                next["posterUrl"] = secureURL.absoluteString
            }
            return next
        } catch {
            return attachment
        }
    }

    private func encryptedMediaCacheURL(
        remoteUrl: String,
        encryption: [String: Any]
    ) -> URL {
        e2eeMediaCacheRoot()
            .appendingPathComponent("encrypted", isDirectory: true)
            .appendingPathComponent("\(mediaCacheDigest(remoteUrl: remoteUrl, encryption: encryption)).bin")
    }

    private func mediaCacheDigest(remoteUrl: String, encryption: [String: Any]) -> String {
        let digestInput = Data("\(remoteUrl)|\(encryption.string("key"))|\(encryption.string("iv"))".utf8)
        return SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
    }

    private func e2eeMediaCacheRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("AloE2EEMedia", isDirectory: true)
    }

    private func writeProtectedCacheData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markProtectedAndUnbacked(url.deletingLastPathComponent(), isDirectory: true)
        try data.write(to: url, options: [.atomic])
        try markProtectedAndUnbacked(url, isDirectory: false)
    }

    private func markProtectedAndUnbacked(_ url: URL, isDirectory: Bool) throws {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
    }

    private func cleanupDecodedMediaCacheIfNeeded() {
        guard !didCleanDecodedMediaCache else { return }
        didCleanDecodedMediaCache = true

        let root = e2eeMediaCacheRoot()
        let decoded = root.appendingPathComponent("decoded", isDirectory: true)
        try? FileManager.default.removeItem(at: decoded)

        if let legacyURLs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for url in legacyURLs {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory != true else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func downloadRawData(_ path: String) async throws -> Data {
        if path.hasPrefix("file://"), let url = URL(string: path) {
            return try Data(contentsOf: url)
        }
        let candidates = candidateURLs(for: path)
        guard !candidates.isEmpty else {
            throw AloAPIError(status: 0, code: "BAD_URL", message: "Некорректный адрес вложения.", payload: [:])
        }
        var lastError: Error?
        for candidate in candidates {
            do {
                var request = URLRequest(url: candidate.url)
                request.httpMethod = "GET"
                request.timeoutInterval = 5
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    throw AloAPIError(status: status, code: "DOWNLOAD_FAILED", message: "Не удалось загрузить вложение.", payload: [:])
                }
                if let baseURL = candidate.baseURL {
                    activeBaseURL = baseURL
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AloAPIError(status: 0, code: "DOWNLOAD_FAILED", message: "Не удалось загрузить вложение.", payload: [:])
    }

    private func compactBody(_ body: [String: Any?]) -> [String: Any] {
        body.reduce(into: [String: Any]()) { result, pair in
            if let value = pair.value {
                if let string = value as? String, string.isEmpty { return }
                result[pair.key] = value
            }
        }
    }
}

enum AloEnvironment {
    private static let configuredBaseURLs: [URL] = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "AloAPIBaseURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw
            .split(separator: ",")
            .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }()

    static let certificatePins: [String] = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "AloCertificatePins") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }()

    #if DEBUG
    static let requiresCertificatePins = false
    #else
    static let requiresCertificatePins = true
    #endif

    static func normalizedBaseURLs(_ configured: [URL]) -> [URL] {
        #if DEBUG
        return configured.isEmpty ? [URL(string: "http://127.0.0.1:3000/")!] : configured
        #else
        let secure = configured.filter { $0.scheme?.lowercased() == "https" }
        precondition(!secure.isEmpty, "ALO_API_BASE_URL must contain an HTTPS URL in Release builds.")
        precondition(!certificatePins.isEmpty, "ALO_CERTIFICATE_PINS must contain at least one SHA-256 certificate pin.")
        return secure
        #endif
    }

    #if DEBUG
    static let baseURLs = configuredBaseURLs + [
        URL(string: "http://127.0.0.1:3000/")!,
        URL(string: "http://192.168.0.19:3000/")!,
        URL(string: "http://198.18.0.1:3000/")!
    ]
    #else
    static let baseURLs = configuredBaseURLs
    #endif
}

private struct AloLibSignalRemoteDevice {
    let userId: Int
    let deviceId: String
    let protocolDeviceId: UInt32
    let identityKey: Data
    let identityFingerprint: String
    let preKeyBundle: AloLibSignalPreKeyBundle?
}

private struct AloLibSignalGroupRecipients {
    let roomId: Int
    let epoch: Int
    let complete: Bool
    let devices: [AloLibSignalRemoteDevice]
}

private struct AloE2EERecipientKey {
    let userId: Int
    let deviceId: String
    let publicKeyJwk: [String: Any]
    let fingerprint: String
    let signingPublicKeyJwk: [String: Any]?
    let identityFingerprint: String
    let oneTimePreKey: AloE2EEOneTimePreKey?

    init?(userId: Int, json: [String: Any]) {
        let deviceId = json.string("deviceId")
        let publicKeyJwk = json.object("publicKeyJwk")
        guard userId > 0, !deviceId.isEmpty, !publicKeyJwk.isEmpty else { return nil }
        self.userId = userId
        self.deviceId = deviceId
        self.publicKeyJwk = publicKeyJwk
        self.fingerprint = json.string("fingerprint").trimmingCharacters(in: .whitespacesAndNewlines)
        let signingKey = json.object("signingPublicKeyJwk")
        self.signingPublicKeyJwk = signingKey.isEmpty ? nil : signingKey
        self.identityFingerprint = json.string("identityFingerprint").trimmingCharacters(in: .whitespacesAndNewlines)
        if let preKeyRaw = json["oneTimePreKey"] as? [String: Any] {
            self.oneTimePreKey = AloE2EEOneTimePreKey(json: preKeyRaw)
        } else {
            self.oneTimePreKey = nil
        }
    }
}

private struct AloE2EEOneTimePreKey {
    let keyId: String
    let publicKeyJwk: [String: Any]
    let signature: String
    let signatureVersion: Int
    let algorithm: String

    init(
        keyId: String,
        publicKeyJwk: [String: Any],
        signature: String,
        signatureVersion: Int,
        algorithm: String
    ) {
        self.keyId = keyId
        self.publicKeyJwk = publicKeyJwk
        self.signature = signature
        self.signatureVersion = signatureVersion
        self.algorithm = algorithm
    }

    init?(json: [String: Any]) {
        let keyId = json.string("keyId")
        let publicKeyJwk = json.object("publicKeyJwk")
        let signature = json.string("signature")
        guard !keyId.isEmpty, !publicKeyJwk.isEmpty, !signature.isEmpty else { return nil }
        self.keyId = keyId
        self.publicKeyJwk = publicKeyJwk
        self.signature = signature
        self.signatureVersion = json.int("signatureVersion") == 2 ? 2 : 1
        self.algorithm = json.string("algorithm").ifBlank(AloE2EECrypto.scheme)
    }
}

private final class AloE2EETrustStore {
    static let shared = AloE2EETrustStore()

    private let storageKey = "alo.ios.e2ee.trusted-fingerprints.v1"
    private let defaults = UserDefaults.standard

    func validate(_ keys: [AloE2EERecipientKey], currentUserId: Int) throws {
        var trusted = load()
        var didUpdate = false

        for key in keys where key.userId != currentUserId {
            let fingerprint = key.identityFingerprint.ifBlank(key.fingerprint)
            guard !fingerprint.isEmpty else { continue }
            let id = storageId(for: key)
            if let known = trusted[id] {
                if known != fingerprint {
                    throw AloAPIError(
                        status: -1,
                        code: "E2EE_KEY_CHANGED",
                        message: "Ключ шифрования собеседника изменился. Сверьте код безопасности перед отправкой.",
                        payload: [
                            "userId": key.userId,
                            "deviceId": key.deviceId,
                            "oldFingerprint": known,
                            "newFingerprint": fingerprint
                        ]
                    )
                }
            } else {
                trusted[id] = fingerprint
                didUpdate = true
            }
        }

        if didUpdate {
            save(trusted)
        }
    }

    func validateEmbeddedSender(_ encryptedPayload: [String: Any], currentUserId: Int) throws {
        guard encryptedPayload.string("scheme") == AloE2EECrypto.messageSchemeV2,
              let envelope = encryptedPayload.array("recipients").first else { return }
        let senderUserId = envelope.int("senderUserId")
        let senderDeviceId = envelope.string("senderDeviceId")
        let senderFingerprint = envelope.string("senderIdentityFingerprint")
        let agreementKey = envelope.object("senderAgreementPublicKeyJwk")
        let signingKey = envelope.object("senderSigningPublicKeyJwk")
        guard senderUserId > 0,
              !senderDeviceId.isEmpty,
              !senderFingerprint.isEmpty,
              !agreementKey.isEmpty,
              !signingKey.isEmpty else {
            throw AloAPIError(
                status: -1,
                code: "E2EE_SENDER_IDENTITY_INVALID",
                message: "Identity отправителя в зашифрованном сообщении повреждена.",
                payload: [:]
            )
        }
        for candidate in encryptedPayload.array("recipients") {
            guard candidate.int("senderUserId") == senderUserId,
                  candidate.string("senderDeviceId") == senderDeviceId,
                  candidate.string("senderIdentityFingerprint") == senderFingerprint,
                  samePublicKey(candidate.object("senderAgreementPublicKeyJwk"), agreementKey),
                  samePublicKey(candidate.object("senderSigningPublicKeyJwk"), signingKey) else {
                throw AloAPIError(
                    status: -1,
                    code: "E2EE_SENDER_IDENTITY_MISMATCH",
                    message: "Конверты сообщения содержат разные identity отправителя.",
                    payload: [:]
                )
            }
        }
        let json: [String: Any] = [
            "deviceId": senderDeviceId,
            "publicKeyJwk": agreementKey,
            "signingPublicKeyJwk": signingKey,
            "identityFingerprint": senderFingerprint,
            "fingerprint": ""
        ]
        guard let key = AloE2EERecipientKey(userId: senderUserId, json: json) else { return }
        try validate([key], currentUserId: currentUserId)
    }

    private func samePublicKey(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        lhs.string("kty") == rhs.string("kty") &&
            lhs.string("crv") == rhs.string("crv") &&
            lhs.string("x") == rhs.string("x") &&
            lhs.string("y") == rhs.string("y")
    }

    private func storageId(for key: AloE2EERecipientKey) -> String {
        "\(key.identityFingerprint.isEmpty ? "v1" : "v2"):\(key.userId):\(key.deviceId)"
    }

    private func load() -> [String: String] {
        guard let data = defaults.data(forKey: storageKey),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func save(_ trusted: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: trusted, options: []) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private struct AloE2EEMediaBox {
    let data: Data
    let key: String
    let iv: String
}

private final class AloE2EECrypto {
    static let shared = AloE2EECrypto()
    static let scheme = "ecdh-p256-aes-gcm-v1"
    static let messageSchemeV2 = "alo-e2ee-p256-aes-gcm-v2"
    static let mediaScheme = "aes-256-gcm-v1"
    static let ratchetScheme = "alo-chain-ratchet-v1"

    private let deviceIdKey = "alo.ios.e2ee.device-id.v1"
    private let privateKeyKey = "alo.ios.e2ee.private-key.v1"
    private let signingPrivateKeyKey = "alo.ios.e2ee.signing-private-key.v2"
    private let oneTimePreKeysKey = "alo.ios.e2ee.one-time-prekeys.v1"
    private let ratchetSessionsKey = "alo.ios.e2ee.ratchet-sessions.v1"
    private let ratchetHistoryKeysKey = "alo.ios.e2ee.ratchet-history-keys.v1"
    private let plaintextCacheKey = "alo.ios.e2ee.plaintext-cache.v2"
    private let ratchetHistoryWrapKeyAccount = "ratchet-history-wrap-key.v1"
    private let keychainService = "alo.ios.e2ee"
    private let ratchetLock = NSLock()
    private let maxRatchetSkip = 64
    private let ratchetRotationMessages = 64
    private let maxRatchetHistoryKeys = 4000
    private let maxPlaintextCacheItems = 600
    private let salt = Data("alo-e2ee-v1".utf8)
    private let info = Data("alo-message-envelope-v1".utf8)
    private let saltV2 = Data("alo-e2ee-v2".utf8)
    private let infoV2 = Data("alo-message-envelope-v2".utf8)

    var deviceId: String {
        if let stored = UserDefaults.standard.string(forKey: deviceIdKey), isValidDeviceId(stored) {
            return stored
        }
        let next = "ios_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        UserDefaults.standard.set(next, forKey: deviceIdKey)
        return next
    }

    func localPublicKeyPayload() throws -> [String: Any] {
        try publicKeyJwk(for: localPrivateKey().publicKey)
    }

    func localSigningPublicKeyPayload() throws -> [String: Any] {
        try publicKeyJwk(x963Representation: localSigningPrivateKey().publicKey.x963Representation)
    }

    func localIdentitySignature() throws -> String {
        let signature = try localSigningPrivateKey().signature(
            for: identitySigningPayload(
                signedDeviceId: deviceId,
                agreementPublicKeyJwk: localPublicKeyPayload(),
                signingPublicKeyJwk: localSigningPublicKeyPayload()
            )
        )
        return base64URL(signature.derRepresentation)
    }

    func localIdentityFingerprint() throws -> String {
        identityFingerprint(
            agreementPublicKeyJwk: try localPublicKeyPayload(),
            signingPublicKeyJwk: try localSigningPublicKeyPayload()
        )
    }

    func prepareOneTimePreKeysForUpload(
        serverAvailable: Int,
        targetCount: Int = 24,
        maxUpload: Int = 48
    ) throws -> [AloE2EEOneTimePreKey] {
        var store = loadOneTimePreKeyStore()
        let pendingCount = store.values.filter { !($0["published"] as? Bool ?? false) }.count
        let needed = min(maxUpload, max(0, targetCount - max(0, serverAvailable) - pendingCount))
        for _ in 0..<needed {
            let key = P256.KeyAgreement.PrivateKey()
            let keyId = "otpk_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
            let publicKeyJwk = try publicKeyJwk(for: key.publicKey)
            let signature = try signOneTimePreKey(keyId: keyId, algorithm: Self.scheme, publicKeyJwk: publicKeyJwk)
            try storeKeychainData(key.rawRepresentation, account: oneTimePreKeyAccount(keyId))
            store[keyId] = [
                "keyId": keyId,
                "publicKeyJwk": publicKeyJwk,
                "signature": signature,
                "signatureVersion": 2,
                "algorithm": Self.scheme,
                "createdAt": Date().timeIntervalSince1970,
                "published": false
            ]
        }
        trimOneTimePreKeyStore(&store)
        saveOneTimePreKeyStore(store)
        return pendingOneTimePreKeys(in: store).prefix(maxUpload).map { $0 }
    }

    func markOneTimePreKeysPublished(_ keyIds: [String]) {
        guard !keyIds.isEmpty else { return }
        var store = loadOneTimePreKeyStore()
        var didChange = false
        for keyId in Set(keyIds) {
            guard var item = store[keyId] else { continue }
            item["published"] = true
            store[keyId] = item
            didChange = true
        }
        if didChange {
            saveOneTimePreKeyStore(store)
        }
    }

    func encryptMedia(_ data: Data) throws -> AloE2EEMediaBox {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)
        var ciphertext = Data(sealed.ciphertext)
        ciphertext.append(sealed.tag)
        let keyData = key.withUnsafeBytes { Data($0) }
        return AloE2EEMediaBox(
            data: ciphertext,
            key: base64URL(keyData),
            iv: base64URL(Data(nonce))
        )
    }

    func decryptMedia(_ data: Data, encryption: [String: Any]) throws -> Data {
        guard encryption.string("algorithm") == Self.mediaScheme,
              let keyData = Data(base64URLEncoded: encryption.string("key")),
              let iv = Data(base64URLEncoded: encryption.string("iv")),
              data.count > 16 else {
            throw AloE2EECryptoError.invalidPayload
        }
        let ciphertext = data.dropLast(16)
        let tag = data.suffix(16)
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
        return try AES.GCM.open(sealed, using: SymmetricKey(data: keyData))
    }

    func encrypt(
        _ plaintext: Data,
        for recipient: AloE2EERecipientKey,
        senderUserId: Int = 0,
        purpose: String = "message",
        contextId: String = "",
        useV2: Bool = false,
        allowRatchetBootstrap: Bool = true
    ) throws -> [String: Any] {
        ratchetLock.lock()
        defer { ratchetLock.unlock() }
        if useV2 {
            return try encryptV2(
                plaintext,
                recipient: recipient,
                senderUserId: senderUserId,
                purpose: purpose,
                contextId: contextId,
                allowRatchetBootstrap: allowRatchetBootstrap
            )
        }
        let ratchetStorageId = sendRatchetStorageId(
            userId: recipient.userId,
            deviceId: recipient.deviceId
        )
        if allowRatchetBootstrap,
           let session = loadRatchetSession(storageKey: ratchetStorageId),
           session.bool("confirmed") {
            return try encryptWithRatchetSession(plaintext, recipient: recipient, session: session)
        }

        let oneTimePreKey = try (allowRatchetBootstrap ? recipient.oneTimePreKey : nil).map { preKey in
            guard try verifyOneTimePreKey(recipient: recipient, preKey: preKey) else {
                throw AloE2EECryptoError.invalidKey
            }
            return preKey
        }
        let remotePublicKey = try publicKey(from: oneTimePreKey?.publicKeyJwk ?? recipient.publicKeyJwk)
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        var ciphertext = Data(sealed.ciphertext)
        ciphertext.append(sealed.tag)
        var envelope: [String: Any] = [
            "userId": recipient.userId,
            "deviceId": recipient.deviceId,
            "iv": base64URL(Data(nonce)),
            "ciphertext": base64URL(ciphertext),
            "ephemeralPublicKeyJwk": try publicKeyJwk(for: ephemeralKey.publicKey),
            "algorithm": Self.scheme
        ]
        if let oneTimePreKey {
            let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
            let sessionId = ratchetSessionId(sharedSecret: sharedSecretData)
            try storeRatchetSession(
                storageKey: ratchetStorageId,
                sessionId: sessionId,
                chainKey: ratchetChainKey(sharedSecret: sharedSecretData, sessionId: sessionId),
                nextMessageNumber: 0,
                peerUserId: recipient.userId,
                peerDeviceId: recipient.deviceId,
                confirmed: false
            )
            envelope["ratchet"] = Self.ratchetScheme
            envelope["ratchetMode"] = "init"
            envelope["ratchetSessionId"] = sessionId
            envelope["ratchetMessageNumber"] = 0
            envelope["ratchetPublicKeyJwk"] = try publicKeyJwk(for: ephemeralKey.publicKey)
            envelope["preKeyId"] = oneTimePreKey.keyId
            envelope["preKeyAlgorithm"] = oneTimePreKey.algorithm
        }
        return envelope
    }

    private func encryptV2(
        _ plaintext: Data,
        recipient: AloE2EERecipientKey,
        senderUserId: Int,
        purpose: String,
        contextId: String,
        allowRatchetBootstrap: Bool
    ) throws -> [String: Any] {
        guard senderUserId > 0,
              purpose == "message" || purpose == "call",
              contextId.range(of: #"^[a-zA-Z0-9_-]{12,160}$"#, options: .regularExpression) != nil,
              recipient.signingPublicKeyJwk != nil,
              !recipient.identityFingerprint.isEmpty else {
            throw AloE2EECryptoError.invalidPayload
        }

        let ratchetStorageId = sendRatchetStorageId(
            userId: recipient.userId,
            deviceId: recipient.deviceId,
            protocolVersion: 2
        )
        if allowRatchetBootstrap,
           let session = loadRatchetSession(storageKey: ratchetStorageId),
           session.bool("confirmed"),
           session.int("nextMessageNumber") < ratchetRotationMessages || recipient.oneTimePreKey == nil {
            return try encryptWithRatchetSessionV2(
                plaintext,
                recipient: recipient,
                session: session,
                senderUserId: senderUserId,
                purpose: purpose,
                contextId: contextId
            )
        }

        if !allowRatchetBootstrap {
            return try encryptStaticV2(
                plaintext,
                recipient: recipient,
                senderUserId: senderUserId,
                purpose: purpose,
                contextId: contextId
            )
        }

        guard let oneTimePreKey = try recipient.oneTimePreKey.map({ preKey in
            guard try verifyOneTimePreKey(recipient: recipient, preKey: preKey) else {
                throw AloE2EECryptoError.invalidKey
            }
            return preKey
        }) else {
            throw AloE2EECryptoError.missingRecipient
        }
        let remotePublicKey = try publicKey(from: oneTimePreKey.publicKeyJwk)
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let ephemeralPublicKeyJwk = try publicKeyJwk(for: ephemeralKey.publicKey)
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltV2,
            sharedInfo: infoV2,
            outputByteCount: 32
        )
        var envelope = try baseV2Envelope(
            recipient: recipient,
            senderUserId: senderUserId,
            purpose: purpose,
            contextId: contextId
        )
        envelope["ephemeralPublicKeyJwk"] = ephemeralPublicKeyJwk

        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        let sessionId = ratchetSessionId(sharedSecret: sharedSecretData)
        try storeRatchetSession(
            storageKey: ratchetStorageId,
            sessionId: sessionId,
            chainKey: ratchetChainKey(sharedSecret: sharedSecretData, sessionId: sessionId),
            nextMessageNumber: 0,
            peerUserId: recipient.userId,
            peerDeviceId: recipient.deviceId,
            confirmed: false
        )
        envelope["ratchet"] = Self.ratchetScheme
        envelope["ratchetMode"] = "init"
        envelope["ratchetSessionId"] = sessionId
        envelope["ratchetMessageNumber"] = 0
        envelope["ratchetPublicKeyJwk"] = ephemeralPublicKeyJwk
        envelope["preKeyId"] = oneTimePreKey.keyId
        envelope["preKeyAlgorithm"] = oneTimePreKey.algorithm

        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: envelopeAssociatedDataV2(envelope)
        )
        var ciphertext = Data(sealed.ciphertext)
        ciphertext.append(sealed.tag)
        envelope["iv"] = base64URL(Data(nonce))
        envelope["ciphertext"] = base64URL(ciphertext)
        envelope["signature"] = try signEnvelopeV2(envelope)
        return envelope
    }

    private func encryptStaticV2(
        _ plaintext: Data,
        recipient: AloE2EERecipientKey,
        senderUserId: Int,
        purpose: String,
        contextId: String
    ) throws -> [String: Any] {
        let remotePublicKey = try publicKey(from: recipient.publicKeyJwk)
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltV2,
            sharedInfo: infoV2,
            outputByteCount: 32
        )
        var envelope = try baseV2Envelope(
            recipient: recipient,
            senderUserId: senderUserId,
            purpose: purpose,
            contextId: contextId
        )
        envelope["ephemeralPublicKeyJwk"] = try publicKeyJwk(for: ephemeralKey.publicKey)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: envelopeAssociatedDataV2(envelope)
        )
        var ciphertext = Data(sealed.ciphertext)
        ciphertext.append(sealed.tag)
        envelope["iv"] = base64URL(Data(nonce))
        envelope["ciphertext"] = base64URL(ciphertext)
        envelope["signature"] = try signEnvelopeV2(envelope)
        return envelope
    }

    private func baseV2Envelope(
        recipient: AloE2EERecipientKey,
        senderUserId: Int,
        purpose: String,
        contextId: String
    ) throws -> [String: Any] {
        [
            "userId": recipient.userId,
            "deviceId": recipient.deviceId,
            "algorithm": Self.scheme,
            "protocolVersion": 2,
            "purpose": purpose,
            "contextId": contextId,
            "senderUserId": senderUserId,
            "senderDeviceId": deviceId,
            "senderAgreementPublicKeyJwk": try localPublicKeyPayload(),
            "senderSigningPublicKeyJwk": try localSigningPublicKeyPayload(),
            "senderIdentityFingerprint": try localIdentityFingerprint()
        ]
    }

    func decrypt(encryptedPayload: [String: Any]) throws -> Data {
        ratchetLock.lock()
        defer { ratchetLock.unlock() }
        let messageScheme = encryptedPayload.string("scheme")
        guard messageScheme == Self.scheme || messageScheme == Self.messageSchemeV2 else {
            throw AloE2EECryptoError.invalidPayload
        }
        guard let recipient = encryptedPayload.array("recipients").first(where: { $0.string("deviceId") == deviceId }) else {
            throw AloE2EECryptoError.missingRecipient
        }
        if messageScheme == Self.messageSchemeV2 {
            try verifyEnvelopeV2(recipient)
        }
        if let cached = (try? loadCachedPlaintext(messageScheme: messageScheme, envelope: recipient)) ?? nil {
            return cached
        }
        if recipient.string("ratchet") == Self.ratchetScheme,
           recipient.string("ratchetMode") == "chain" {
            let opened = try decryptWithRatchetSession(recipient)
            if (try? storeCachedPlaintext(messageScheme: messageScheme, envelope: recipient, plaintext: opened)) == true {
                retireConsumedEnvelopeKeys(recipient)
            }
            return opened
        }

        let preKeyId = recipient.string("preKeyId").trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKey = preKeyId.isEmpty
            ? try localPrivateKey()
            : try localOneTimePreKeyPrivateKey(keyId: preKeyId)
        let ephemeralPublicKey = try publicKey(from: recipient.object("ephemeralPublicKeyJwk"))
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: messageScheme == Self.messageSchemeV2 ? saltV2 : salt,
            sharedInfo: messageScheme == Self.messageSchemeV2 ? infoV2 : info,
            outputByteCount: 32
        )
        guard let iv = Data(base64URLEncoded: recipient.string("iv")),
              let ciphertextAndTag = Data(base64URLEncoded: recipient.string("ciphertext")),
              ciphertextAndTag.count > 16 else {
            throw AloE2EECryptoError.invalidPayload
        }
        let ciphertext = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
        let opened: Data
        if messageScheme == Self.messageSchemeV2 {
            opened = try AES.GCM.open(
                sealed,
                using: key,
                authenticating: envelopeAssociatedDataV2(recipient)
            )
        } else {
            opened = try AES.GCM.open(sealed, using: key)
        }
        if recipient.string("ratchet") == Self.ratchetScheme,
           recipient.string("ratchetMode") == "init" {
            let sessionId = recipient.string("ratchetSessionId").trimmingCharacters(in: .whitespacesAndNewlines)
            if !sessionId.isEmpty {
                let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
                try storeRatchetSession(
                    storageKey: receiveRatchetStorageId(sessionId: sessionId),
                    sessionId: sessionId,
                    chainKey: ratchetChainKey(sharedSecret: sharedSecretData, sessionId: sessionId),
                    nextMessageNumber: 0,
                    peerUserId: messageScheme == Self.messageSchemeV2
                        ? recipient.int("senderUserId")
                        : recipient.int("userId"),
                    peerDeviceId: messageScheme == Self.messageSchemeV2
                        ? recipient.string("senderDeviceId")
                        : recipient.string("deviceId")
                )
            }
        }
        if (try? storeCachedPlaintext(messageScheme: messageScheme, envelope: recipient, plaintext: opened)) == true {
            retireConsumedEnvelopeKeys(recipient)
        }
        return opened
    }

    func markRatchetSessionsConfirmed(encryptedPayload: [String: Any]) {
        ratchetLock.lock()
        defer { ratchetLock.unlock() }
        var store = loadRatchetStore()
        var didChange = false
        for envelope in encryptedPayload.array("recipients")
        where envelope.string("ratchet") == Self.ratchetScheme && envelope.string("ratchetMode") == "init" {
            let userId = envelope.int("userId")
            let deviceId = envelope.string("deviceId").trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionId = envelope.string("ratchetSessionId").trimmingCharacters(in: .whitespacesAndNewlines)
            guard userId > 0, !deviceId.isEmpty, !sessionId.isEmpty else { continue }
            let protocolVersion = envelope.int("protocolVersion") == 2 ? 2 : 1
            let storageKey = sendRatchetStorageId(
                userId: userId,
                deviceId: deviceId,
                protocolVersion: protocolVersion
            )
            guard var session = store[storageKey], session.string("sessionId") == sessionId else { continue }
            session["confirmed"] = true
            session["updatedAt"] = Date().timeIntervalSince1970
            store[storageKey] = session
            didChange = true
        }
        guard didChange,
              let data = try? JSONSerialization.data(withJSONObject: store, options: []) else { return }
        UserDefaults.standard.set(data, forKey: ratchetSessionsKey)
    }

    func hasConfirmedRatchetSession(userId: Int, deviceId: String, useV2: Bool = false) -> Bool {
        ratchetLock.lock()
        defer { ratchetLock.unlock() }
        guard let session = loadRatchetSession(
            storageKey: sendRatchetStorageId(
                userId: userId,
                deviceId: deviceId,
                protocolVersion: useV2 ? 2 : 1
            )
        ) else { return false }
        return session.bool("confirmed") &&
            (!useV2 || session.int("nextMessageNumber") < ratchetRotationMessages)
    }

    private func encryptWithRatchetSession(
        _ plaintext: Data,
        recipient: AloE2EERecipientKey,
        session: [String: Any]
    ) throws -> [String: Any] {
        let sessionId = session.string("sessionId").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { throw AloE2EECryptoError.invalidPayload }
        let messageNumber = max(0, session.int("nextMessageNumber"))
        let chainKey = try ratchetChainKeyFromSession(
            storageKey: sendRatchetStorageId(userId: recipient.userId, deviceId: recipient.deviceId)
        )
        let messageKey = ratchetMessageKey(chainKey: chainKey)
        let nextChainKey = ratchetNextChainKey(chainKey: chainKey)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: messageKey), nonce: nonce)
        var ciphertext = Data(sealed.ciphertext)
        ciphertext.append(sealed.tag)

        try storeRatchetSession(
            storageKey: sendRatchetStorageId(userId: recipient.userId, deviceId: recipient.deviceId),
            sessionId: sessionId,
            chainKey: nextChainKey,
            nextMessageNumber: messageNumber + 1,
            peerUserId: recipient.userId,
            peerDeviceId: recipient.deviceId
        )
        return [
            "userId": recipient.userId,
            "deviceId": recipient.deviceId,
            "iv": base64URL(Data(nonce)),
            "ciphertext": base64URL(ciphertext),
            "algorithm": Self.scheme,
            "ratchet": Self.ratchetScheme,
            "ratchetMode": "chain",
            "ratchetSessionId": sessionId,
            "ratchetMessageNumber": messageNumber
        ]
    }

    private func encryptWithRatchetSessionV2(
        _ plaintext: Data,
        recipient: AloE2EERecipientKey,
        session: [String: Any],
        senderUserId: Int,
        purpose: String,
        contextId: String
    ) throws -> [String: Any] {
        let sessionId = session.string("sessionId").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { throw AloE2EECryptoError.invalidPayload }
        let messageNumber = max(0, session.int("nextMessageNumber"))
        let storageKey = sendRatchetStorageId(
            userId: recipient.userId,
            deviceId: recipient.deviceId,
            protocolVersion: 2
        )
        let chainKey = try ratchetChainKeyFromSession(storageKey: storageKey)
        let messageKey = ratchetMessageKey(chainKey: chainKey)
        let nextChainKey = ratchetNextChainKey(chainKey: chainKey)
        var envelope = try baseV2Envelope(
            recipient: recipient,
            senderUserId: senderUserId,
            purpose: purpose,
            contextId: contextId
        )
        envelope["ratchet"] = Self.ratchetScheme
        envelope["ratchetMode"] = "chain"
        envelope["ratchetSessionId"] = sessionId
        envelope["ratchetMessageNumber"] = messageNumber

        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: messageKey),
            nonce: nonce,
            authenticating: envelopeAssociatedDataV2(envelope)
        )
        var ciphertext = Data(sealed.ciphertext)
        ciphertext.append(sealed.tag)
        envelope["iv"] = base64URL(Data(nonce))
        envelope["ciphertext"] = base64URL(ciphertext)
        envelope["signature"] = try signEnvelopeV2(envelope)

        try storeRatchetSession(
            storageKey: storageKey,
            sessionId: sessionId,
            chainKey: nextChainKey,
            nextMessageNumber: messageNumber + 1,
            peerUserId: recipient.userId,
            peerDeviceId: recipient.deviceId
        )
        return envelope
    }

    private func decryptWithRatchetSession(_ envelope: [String: Any]) throws -> Data {
        let sessionId = envelope.string("ratchetSessionId").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty,
              let rawMessageNumber = envelope["ratchetMessageNumber"] as? NSNumber else {
            throw AloE2EECryptoError.invalidPayload
        }
        let storageKey = receiveRatchetStorageId(sessionId: sessionId)
        guard let session = loadRatchetSession(storageKey: storageKey) else {
            throw AloE2EECryptoError.missingRecipient
        }
        let targetMessageNumber = rawMessageNumber.intValue
        let currentMessageNumber = max(0, session.int("nextMessageNumber"))
        if targetMessageNumber < currentMessageNumber {
            guard let retainedKey = try loadRatchetHistoryMessageKey(
                sessionId: sessionId,
                messageNumber: targetMessageNumber
            ) else {
                throw AloE2EECryptoError.missingRecipient
            }
            return try decryptRatchetEnvelope(envelope, messageKey: retainedKey)
        }
        guard targetMessageNumber - currentMessageNumber <= maxRatchetSkip else {
            throw AloE2EECryptoError.invalidPayload
        }

        var chainKey = try ratchetChainKeyFromSession(storageKey: storageKey)
        var nextNumber = currentMessageNumber
        while nextNumber < targetMessageNumber {
            try storeRatchetHistoryMessageKey(
                sessionId: sessionId,
                messageNumber: nextNumber,
                messageKey: ratchetMessageKey(chainKey: chainKey)
            )
            chainKey = ratchetNextChainKey(chainKey: chainKey)
            nextNumber += 1
        }
        let messageKey = ratchetMessageKey(chainKey: chainKey)
        let nextChainKey = ratchetNextChainKey(chainKey: chainKey)
        let opened = try decryptRatchetEnvelope(envelope, messageKey: messageKey)
        try storeRatchetSession(
            storageKey: storageKey,
            sessionId: sessionId,
            chainKey: nextChainKey,
            nextMessageNumber: targetMessageNumber + 1,
            peerUserId: session.int("peerUserId"),
            peerDeviceId: session.string("peerDeviceId")
        )
        return opened
    }

    private func decryptRatchetEnvelope(_ envelope: [String: Any], messageKey: Data) throws -> Data {
        guard let iv = Data(base64URLEncoded: envelope.string("iv")),
              let ciphertextAndTag = Data(base64URLEncoded: envelope.string("ciphertext")),
              ciphertextAndTag.count > 16 else {
            throw AloE2EECryptoError.invalidPayload
        }
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: Data(ciphertextAndTag.dropLast(16)),
            tag: Data(ciphertextAndTag.suffix(16))
        )
        if envelope.int("protocolVersion") == 2 {
            return try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: messageKey),
                authenticating: envelopeAssociatedDataV2(envelope)
            )
        }
        return try AES.GCM.open(sealed, using: SymmetricKey(data: messageKey))
    }

    private func loadRatchetSession(storageKey: String) -> [String: Any]? {
        loadRatchetStore()[storageKey]
    }

    private func storeRatchetSession(
        storageKey: String,
        sessionId: String,
        chainKey: Data,
        nextMessageNumber: Int,
        peerUserId: Int,
        peerDeviceId: String,
        confirmed: Bool = true
    ) throws {
        guard !storageKey.isEmpty, !sessionId.isEmpty else {
            throw AloE2EECryptoError.invalidPayload
        }
        try storeKeychainData(chainKey, account: ratchetChainKeyAccount(storageKey: storageKey))
        var store = loadRatchetStore()
        store[storageKey] = [
            "sessionId": sessionId,
            "peerUserId": peerUserId,
            "peerDeviceId": peerDeviceId,
            "confirmed": confirmed,
            "nextMessageNumber": max(0, nextMessageNumber),
            "updatedAt": Date().timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: store, options: []) else {
            throw AloE2EECryptoError.keyStorageFailed
        }
        UserDefaults.standard.set(data, forKey: ratchetSessionsKey)
    }

    private func loadRatchetStore() -> [String: [String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: ratchetSessionsKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result = [String: [String: Any]]()
        for (key, value) in raw {
            if let session = value as? [String: Any] {
                result[key] = session
            }
        }
        return result
    }

    private func loadRatchetHistoryMessageKey(sessionId: String, messageNumber: Int) throws -> Data? {
        let storageId = ratchetHistoryStorageId(sessionId: sessionId, messageNumber: messageNumber)
        guard let item = loadRatchetHistoryStore()[storageId],
              let boxData = Data(base64URLEncoded: item.string("box")) else {
            return nil
        }
        let sealed = try AES.GCM.SealedBox(combined: boxData)
        return try AES.GCM.open(sealed, using: try ratchetHistoryWrappingKey())
    }

    private func storeRatchetHistoryMessageKey(
        sessionId: String,
        messageNumber: Int,
        messageKey: Data
    ) throws {
        guard !sessionId.isEmpty, messageNumber >= 0, messageKey.count == 32 else { return }
        let sealed = try AES.GCM.seal(messageKey, using: try ratchetHistoryWrappingKey())
        guard let combined = sealed.combined else { throw AloE2EECryptoError.keyStorageFailed }
        var store = loadRatchetHistoryStore()
        store[ratchetHistoryStorageId(sessionId: sessionId, messageNumber: messageNumber)] = [
            "box": base64URL(combined),
            "createdAt": Date().timeIntervalSince1970
        ]
        if store.count > maxRatchetHistoryKeys {
            let removeCount = store.count - maxRatchetHistoryKeys
            let oldest = store.sorted { lhs, rhs in
                let left = lhs.value["createdAt"] as? TimeInterval ?? 0
                let right = rhs.value["createdAt"] as? TimeInterval ?? 0
                return left < right
            }.prefix(removeCount)
            for (key, _) in oldest {
                store.removeValue(forKey: key)
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: store, options: []) else {
            throw AloE2EECryptoError.keyStorageFailed
        }
        UserDefaults.standard.set(data, forKey: ratchetHistoryKeysKey)
    }

    private func loadRatchetHistoryStore() -> [String: [String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: ratchetHistoryKeysKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result = [String: [String: Any]]()
        for (key, value) in raw {
            if let item = value as? [String: Any] {
                result[key] = item
            }
        }
        return result
    }

    private func removeRatchetHistoryMessageKey(sessionId: String, messageNumber: Int) {
        guard !sessionId.isEmpty, messageNumber >= 0 else { return }
        var store = loadRatchetHistoryStore()
        store.removeValue(forKey: ratchetHistoryStorageId(sessionId: sessionId, messageNumber: messageNumber))
        guard let data = try? JSONSerialization.data(withJSONObject: store, options: []) else { return }
        UserDefaults.standard.set(data, forKey: ratchetHistoryKeysKey)
    }

    private func loadCachedPlaintext(
        messageScheme: String,
        envelope: [String: Any]
    ) throws -> Data? {
        let storageId = plaintextCacheId(messageScheme: messageScheme, envelope: envelope)
        guard let item = loadPlaintextCacheStore()[storageId],
              let combined = Data(base64URLEncoded: item.string("box")) else {
            return nil
        }
        let sealed = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealed, using: ratchetHistoryWrappingKey())
    }

    @discardableResult
    private func storeCachedPlaintext(
        messageScheme: String,
        envelope: [String: Any],
        plaintext: Data
    ) throws -> Bool {
        let sealed = try AES.GCM.seal(plaintext, using: ratchetHistoryWrappingKey())
        guard let combined = sealed.combined else { return false }
        var store = loadPlaintextCacheStore()
        store[plaintextCacheId(messageScheme: messageScheme, envelope: envelope)] = [
            "box": base64URL(combined),
            "createdAt": Date().timeIntervalSince1970
        ]
        if store.count > maxPlaintextCacheItems {
            let removeCount = store.count - maxPlaintextCacheItems
            for (key, _) in store.sorted(by: {
                ($0.value["createdAt"] as? TimeInterval ?? 0) < ($1.value["createdAt"] as? TimeInterval ?? 0)
            }).prefix(removeCount) {
                store.removeValue(forKey: key)
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: store, options: []) else { return false }
        UserDefaults.standard.set(data, forKey: plaintextCacheKey)
        return true
    }

    private func loadPlaintextCacheStore() -> [String: [String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: plaintextCacheKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return raw.reduce(into: [String: [String: Any]]()) { result, entry in
            if let item = entry.value as? [String: Any] {
                result[entry.key] = item
            }
        }
    }

    private func plaintextCacheId(messageScheme: String, envelope: [String: Any]) -> String {
        let source = [
            messageScheme,
            envelope.string("deviceId"),
            envelope.string("iv"),
            envelope.string("ciphertext"),
            envelope.string("signature")
        ].joined(separator: "|")
        return base64URL(Data(SHA256.hash(data: Data(source.utf8))))
    }

    private func retireConsumedEnvelopeKeys(_ envelope: [String: Any]) {
        let preKeyId = envelope.string("preKeyId").trimmingCharacters(in: .whitespacesAndNewlines)
        if !preKeyId.isEmpty {
            markOneTimePreKeyConsumed(keyId: preKeyId)
        }
        if envelope.string("ratchet") == Self.ratchetScheme,
           envelope.string("ratchetMode") == "chain" {
            removeRatchetHistoryMessageKey(
                sessionId: envelope.string("ratchetSessionId"),
                messageNumber: envelope.int("ratchetMessageNumber")
            )
        }
    }

    private func ratchetHistoryWrappingKey() throws -> SymmetricKey {
        if let raw = readKeychainData(account: ratchetHistoryWrapKeyAccount), raw.count == 32 {
            return SymmetricKey(data: raw)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try storeKeychainData(raw, account: ratchetHistoryWrapKeyAccount)
        return key
    }

    private func ratchetHistoryStorageId(sessionId: String, messageNumber: Int) -> String {
        "\(sessionId):\(messageNumber)"
    }

    private func ratchetChainKeyFromSession(storageKey: String) throws -> Data {
        guard let key = readKeychainData(account: ratchetChainKeyAccount(storageKey: storageKey)),
              key.count == 32 else {
            throw AloE2EECryptoError.missingRecipient
        }
        return key
    }

    private func sendRatchetStorageId(
        userId: Int,
        deviceId: String,
        protocolVersion: Int = 1
    ) -> String {
        "send:v\(protocolVersion == 2 ? 2 : 1):\(userId):\(deviceId)"
    }

    private func receiveRatchetStorageId(sessionId: String) -> String {
        "recv:\(sessionId)"
    }

    private func ratchetChainKeyAccount(storageKey: String) -> String {
        let digest = SHA256.hash(data: Data(storageKey.utf8))
        return "ratchet-chain.\(base64URL(Data(digest)))"
    }

    private func ratchetSessionId(sharedSecret: Data) -> String {
        base64URL(hmacSHA256(key: sharedSecret, data: Data("session".utf8)))
    }

    private func ratchetChainKey(sharedSecret: Data, sessionId: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: salt,
            info: Data("\(Self.ratchetScheme)|\(sessionId)".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private func ratchetMessageKey(chainKey: Data) -> Data {
        hmacSHA256(key: chainKey, data: Data("message-key".utf8))
    }

    private func ratchetNextChainKey(chainKey: Data) -> Data {
        hmacSHA256(key: chainKey, data: Data("chain-key".utf8))
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private func signOneTimePreKey(
        keyId: String,
        algorithm: String,
        publicKeyJwk: [String: Any]
    ) throws -> String {
        let signature = try localSigningPrivateKey().signature(
            for: oneTimePreKeySigningPayload(
                signedDeviceId: deviceId,
                keyId: keyId,
                algorithm: algorithm,
                publicKeyJwk: publicKeyJwk
            )
        )
        return base64URL(signature.derRepresentation)
    }

    private func verifyOneTimePreKey(
        recipient: AloE2EERecipientKey,
        preKey: AloE2EEOneTimePreKey
    ) throws -> Bool {
        let signerJwk: [String: Any]
        if preKey.signatureVersion == 2 {
            guard let signingPublicKeyJwk = recipient.signingPublicKeyJwk else { return false }
            signerJwk = signingPublicKeyJwk
        } else {
            signerJwk = recipient.publicKeyJwk
        }
        let agreementPublicKey = try publicKey(from: signerJwk)
        let signingPublicKey = try P256.Signing.PublicKey(x963Representation: agreementPublicKey.x963Representation)
        guard let signatureData = Data(base64URLEncoded: preKey.signature) else { return false }
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        return signingPublicKey.isValidSignature(
            signature,
            for: oneTimePreKeySigningPayload(
                signedDeviceId: recipient.deviceId,
                keyId: preKey.keyId,
                algorithm: preKey.algorithm,
                publicKeyJwk: preKey.publicKeyJwk
            )
        )
    }

    private func oneTimePreKeySigningPayload(
        signedDeviceId: String,
        keyId: String,
        algorithm: String,
        publicKeyJwk: [String: Any]
    ) -> Data {
        Data(
            "alo-e2ee-prekey-v1|\(signedDeviceId)|\(keyId)|\(algorithm)|\(publicKeyJwk.string("x"))|\(publicKeyJwk.string("y"))".utf8
        )
    }

    private func identitySigningPayload(
        signedDeviceId: String,
        agreementPublicKeyJwk: [String: Any],
        signingPublicKeyJwk: [String: Any]
    ) -> Data {
        Data(
            "alo-e2ee-identity-v2|\(signedDeviceId)|\(agreementPublicKeyJwk.string("x"))|\(agreementPublicKeyJwk.string("y"))|\(signingPublicKeyJwk.string("x"))|\(signingPublicKeyJwk.string("y"))".utf8
        )
    }

    private func identityFingerprint(
        agreementPublicKeyJwk: [String: Any],
        signingPublicKeyJwk: [String: Any]
    ) -> String {
        let digest = SHA256.hash(
            data: identitySigningPayload(
                signedDeviceId: "",
                agreementPublicKeyJwk: agreementPublicKeyJwk,
                signingPublicKeyJwk: signingPublicKeyJwk
            )
        )
        let hex = digest.prefix(20)
            .map { String(format: "%02x", $0) }
            .joined()
        return stride(from: 0, to: hex.count, by: 5).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(5, hex.distance(from: start, to: hex.endIndex)))
            return String(hex[start..<end])
        }.joined(separator: "-")
    }

    private func envelopeAssociatedDataV2(_ envelope: [String: Any]) -> Data {
        let ephemeral = envelope.object("ephemeralPublicKeyJwk")
        let ratchetPublic = envelope.object("ratchetPublicKeyJwk")
        let senderAgreement = envelope.object("senderAgreementPublicKeyJwk")
        let senderSigning = envelope.object("senderSigningPublicKeyJwk")
        let fields = [
            "alo-e2ee-envelope-v2",
            Self.messageSchemeV2,
            envelope.string("purpose"),
            envelope.string("contextId"),
            String(envelope.int("senderUserId")),
            envelope.string("senderDeviceId"),
            String(envelope.int("userId")),
            envelope.string("deviceId"),
            envelope.string("algorithm"),
            envelope.string("ratchet"),
            envelope.string("ratchetMode"),
            envelope.string("ratchetSessionId"),
            envelope["ratchetMessageNumber"] == nil ? "-1" : String(envelope.int("ratchetMessageNumber")),
            envelope.string("preKeyId"),
            envelope.string("preKeyAlgorithm"),
            ephemeral.string("x"),
            ephemeral.string("y"),
            ratchetPublic.string("x"),
            ratchetPublic.string("y"),
            senderAgreement.string("x"),
            senderAgreement.string("y"),
            senderSigning.string("x"),
            senderSigning.string("y"),
            envelope.string("senderIdentityFingerprint")
        ]
        return Data(
            fields.map { base64URL(Data($0.utf8)) }
                .joined(separator: "|")
                .utf8
        )
    }

    private func envelopeSignaturePayloadV2(_ envelope: [String: Any]) -> Data {
        var payload = envelopeAssociatedDataV2(envelope)
        payload.append(Data(".\(envelope.string("iv")).\(envelope.string("ciphertext"))".utf8))
        return payload
    }

    private func signEnvelopeV2(_ envelope: [String: Any]) throws -> String {
        let signature = try localSigningPrivateKey().signature(for: envelopeSignaturePayloadV2(envelope))
        return base64URL(signature.derRepresentation)
    }

    private func verifyEnvelopeV2(_ envelope: [String: Any]) throws {
        let agreementPublicKeyJwk = envelope.object("senderAgreementPublicKeyJwk")
        let signingPublicKeyJwk = envelope.object("senderSigningPublicKeyJwk")
        guard envelope.int("protocolVersion") == 2,
              envelope.int("senderUserId") > 0,
              !envelope.string("senderDeviceId").isEmpty,
              envelope.string("purpose") == "message" || envelope.string("purpose") == "call",
              !agreementPublicKeyJwk.isEmpty,
              !signingPublicKeyJwk.isEmpty,
              identityFingerprint(
                agreementPublicKeyJwk: agreementPublicKeyJwk,
                signingPublicKeyJwk: signingPublicKeyJwk
              ) == envelope.string("senderIdentityFingerprint"),
              let signatureData = Data(base64URLEncoded: envelope.string("signature")) else {
            throw AloE2EECryptoError.invalidPayload
        }
        let signingAgreementKey = try publicKey(from: signingPublicKeyJwk)
        let signingPublicKey = try P256.Signing.PublicKey(
            x963Representation: signingAgreementKey.x963Representation
        )
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        guard signingPublicKey.isValidSignature(
            signature,
            for: envelopeSignaturePayloadV2(envelope)
        ) else {
            throw AloE2EECryptoError.invalidPayload
        }
    }

    private func localPrivateKey() throws -> P256.KeyAgreement.PrivateKey {
        if let raw = readKeychainData(account: privateKeyKey),
           let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return key
        }
        if let legacyRaw = UserDefaults.standard.data(forKey: privateKeyKey),
           let legacyKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: legacyRaw) {
            try storeKeychainData(legacyRaw, account: privateKeyKey)
            UserDefaults.standard.removeObject(forKey: privateKeyKey)
            return legacyKey
        }
        let key = P256.KeyAgreement.PrivateKey()
        try storeKeychainData(key.rawRepresentation, account: privateKeyKey)
        return key
    }

    private func localSigningPrivateKey() throws -> P256.Signing.PrivateKey {
        if let raw = readKeychainData(account: signingPrivateKeyKey),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        try storeKeychainData(key.rawRepresentation, account: signingPrivateKeyKey)
        return key
    }

    private func readKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func deleteKeychainData(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func storeKeychainData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw AloE2EECryptoError.keyStorageFailed
        }
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw AloE2EECryptoError.keyStorageFailed
        }
    }

    private func oneTimePreKeyAccount(_ keyId: String) -> String {
        "one-time-prekey.\(keyId)"
    }

    private func localOneTimePreKeyPrivateKey(keyId: String) throws -> P256.KeyAgreement.PrivateKey {
        guard let raw = readKeychainData(account: oneTimePreKeyAccount(keyId)),
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            throw AloE2EECryptoError.missingRecipient
        }
        return key
    }

    private func markOneTimePreKeyConsumed(keyId: String) {
        var store = loadOneTimePreKeyStore()
        guard var item = store[keyId] else { return }
        item["consumedAt"] = Date().timeIntervalSince1970
        store[keyId] = item
        saveOneTimePreKeyStore(store)
        deleteKeychainData(account: oneTimePreKeyAccount(keyId))
    }

    private func loadOneTimePreKeyStore() -> [String: [String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: oneTimePreKeysKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result = [String: [String: Any]]()
        for (key, value) in raw {
            guard let item = value as? [String: Any] else { continue }
            result[key] = item
        }
        return result
    }

    private func saveOneTimePreKeyStore(_ store: [String: [String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: store, options: []) else { return }
        UserDefaults.standard.set(data, forKey: oneTimePreKeysKey)
    }

    private func pendingOneTimePreKeys(in store: [String: [String: Any]]) -> [AloE2EEOneTimePreKey] {
        store.values.compactMap { item in
            guard (item["published"] as? Bool ?? false) == false,
                  let keyId = item["keyId"] as? String,
                  !keyId.isEmpty,
                  let publicKeyJwk = item["publicKeyJwk"] as? [String: Any],
                  let signature = item["signature"] as? String,
                  !signature.isEmpty else {
                return nil
            }
            let algorithm = (item["algorithm"] as? String)?.ifBlank(Self.scheme) ?? Self.scheme
            return AloE2EEOneTimePreKey(
                keyId: keyId,
                publicKeyJwk: publicKeyJwk,
                signature: signature,
                signatureVersion: item["signatureVersion"] as? Int == 2 ? 2 : 1,
                algorithm: algorithm
            )
        }
    }

    private func trimOneTimePreKeyStore(_ store: inout [String: [String: Any]], maxPending: Int = 120) {
        let pending = store
            .filter { ($0.value["published"] as? Bool ?? false) == false }
            .sorted { lhs, rhs in
                let left = lhs.value["createdAt"] as? TimeInterval ?? 0
                let right = rhs.value["createdAt"] as? TimeInterval ?? 0
                return left < right
            }
        guard pending.count > maxPending else { return }
        for (key, _) in pending.prefix(pending.count - maxPending) {
            store.removeValue(forKey: key)
        }
    }

    private func publicKeyJwk(for publicKey: P256.KeyAgreement.PublicKey) throws -> [String: Any] {
        try publicKeyJwk(x963Representation: publicKey.x963Representation)
    }

    private func publicKeyJwk(x963Representation x963: Data) throws -> [String: Any] {
        guard x963.count == 65, x963.first == 0x04 else {
            throw AloE2EECryptoError.invalidKey
        }
        let x = x963.dropFirst().prefix(32)
        let y = x963.dropFirst(33).prefix(32)
        return [
            "kty": "EC",
            "crv": "P-256",
            "x": base64URL(Data(x)),
            "y": base64URL(Data(y)),
            "ext": true
        ]
    }

    private func publicKey(from jwk: [String: Any]) throws -> P256.KeyAgreement.PublicKey {
        guard let x = Data(base64URLEncoded: jwk.string("x")),
              let y = Data(base64URLEncoded: jwk.string("y")),
              x.count == 32,
              y.count == 32 else {
            throw AloE2EECryptoError.invalidKey
        }
        var x963 = Data([0x04])
        x963.append(x)
        x963.append(y)
        return try P256.KeyAgreement.PublicKey(x963Representation: x963)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func isValidDeviceId(_ value: String) -> Bool {
        value.range(of: #"^[a-zA-Z0-9_-]{12,128}$"#, options: .regularExpression) != nil
    }
}

private enum AloE2EECryptoError: Error {
    case invalidKey
    case invalidPayload
    case keyStorageFailed
    case missingRecipient
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = normalized.count % 4
        if padding > 0 {
            normalized += String(repeating: "=", count: 4 - padding)
        }
        self.init(base64Encoded: normalized)
    }
}
