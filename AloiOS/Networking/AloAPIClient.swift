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
    let scheduled: Bool
    let scheduledMessageId: Int
    let scheduledAt: String
    let sendWhenOnline: Bool
}

/// Contract for server-persisted recurring messages.  The encrypted payload is
/// produced on-device; the API never receives a second plaintext copy.
enum AloRecurringScheduleRule: String, CaseIterable, Identifiable, Equatable {
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: return "Каждый день"
        case .weekly: return "Каждую неделю"
        case .monthly: return "Каждый месяц"
        }
    }

    var subtitle: String {
        switch self {
        case .daily: return "В одно и то же время"
        case .weekly: return "В выбранный день недели"
        case .monthly: return "В выбранный день месяца"
        }
    }

    var systemImage: String {
        switch self {
        case .daily: return "sun.max"
        case .weekly: return "calendar"
        case .monthly: return "calendar.badge.clock"
        }
    }
}

struct AloRecurringMessageSchedule: Equatable {
    let id: Int
    let startsAt: String
    let rule: AloRecurringScheduleRule?
    let occurrences: Int

    init(_ json: [String: Any]) {
        let record = json.object("schedule").isEmpty ? json : json.object("schedule")
        id = record.int("id")
        startsAt = record.string("startsAt").ifBlank(record.string("scheduledAt"))
        rule = AloRecurringScheduleRule(rawValue: record.string("rule"))
        occurrences = record.int("occurrences")
    }
}

struct AloMessageTranslation: Equatable {
    let text: String
    let sourceLanguage: String
    let targetLanguage: String

    init(_ json: [String: Any]) {
        let record = json.object("translation").isEmpty ? json : json.object("translation")
        text = record.string("text").ifBlank(record.string("translatedText"))
        sourceLanguage = record.string("sourceLanguage")
        targetLanguage = record.string("targetLanguage")
    }
}

struct AloVoiceTranscription: Equatable {
    let text: String
    let language: String
    let confidence: Double

    init(_ json: [String: Any]) {
        let record = json.object("transcription").isEmpty ? json : json.object("transcription")
        text = record.string("text").ifBlank(record.string("transcript"))
        language = record.string("language")
        if let value = record["confidence"] as? Double {
            confidence = value
        } else if let value = record["confidence"] as? NSNumber {
            confidence = value.doubleValue
        } else if let value = record["confidence"] as? String {
            confidence = Double(value) ?? 0
        } else {
            confidence = 0
        }
    }
}

struct AloLiveLocationSession: Equatable {
    let id: String
    let expiresAt: String

    init(_ json: [String: Any]) {
        let record = json.object("liveLocation").isEmpty ? json : json.object("liveLocation")
        id = record.string("id").ifBlank(record.string("sessionId"))
        expiresAt = record.string("expiresAt")
    }
}

struct AloResolvedAppLink {
    let kind: String
    let id: Int
    let handle: String
}

struct AloPostDiscussion {
    let roomId: Int
    let peerId: Int
    let topicId: Int
}

struct AloForumTopicLink {
    let roomId: Int
    let peerId: Int
    let topicId: Int
}

/// A durable cursor for a resumable encrypted upload. It contains no media
/// plaintext or media key, so it is safe to keep inside the encrypted outbox.
struct AloResumableUploadCheckpoint: Equatable {
    let uploadId: String
    let offset: Int64
    let total: Int64
    let checksum: String

    var isValid: Bool {
        uploadId.range(of: "^[a-z0-9_-]{16,160}$", options: .regularExpression) != nil &&
            offset >= 0 && total > 0 && offset <= total &&
            checksum.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
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
    private let streamingSession: URLSession
    private var currentUserId = 0
    private var latestE2EERegistrationError: AloAPIError?
    private var isRegisteringLibSignal = false
    private var libSignalUserId = 0
    private var libSignalProtocolDeviceId: UInt32 = 0
    private var libSignalStore: AloLibSignalStore?
    private var libSignalEngine: AloLibSignalSessionEngine?
    private var didCleanDecodedMediaCache = false

    init(baseURLs: [URL] = AloServerConfiguration.baseURLs, configuration: URLSessionConfiguration = .default) {
        let normalizedBaseURLs = AloServerConfiguration.normalizedBaseURLs(baseURLs)
        self.baseURLs = normalizedBaseURLs
        self.activeBaseURL = normalizedBaseURLs[0]
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        let sessionDelegate = AloCertificatePinningDelegate(
            baseURLs: normalizedBaseURLs,
            configuredPins: AloServerConfiguration.certificatePins,
            requiresPins: AloServerConfiguration.requiresCertificatePins
        )
        self.sessionDelegate = sessionDelegate
        self.session = URLSession(
            configuration: configuration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
        // SSE responses never finish during normal operation. Give them their
        // own connection pool and resource lifetime; they must not compete
        // with message POSTs or restart every 30 seconds with the API timeout.
        let streamingConfiguration = configuration.copy() as! URLSessionConfiguration
        streamingConfiguration.timeoutIntervalForRequest = 45
        streamingConfiguration.timeoutIntervalForResource = 60 * 60
        streamingConfiguration.httpMaximumConnectionsPerHost = 4
        self.streamingSession = URLSession(
            configuration: streamingConfiguration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
        cleanupDecodedMediaCacheIfNeeded()
    }

    deinit {
        session.invalidateAndCancel()
        streamingSession.invalidateAndCancel()
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

    func downloadData(
        from url: URL,
        ignoringLocalCache: Bool = false
    ) async throws -> (data: Data, mimeType: String) {
        var request = URLRequest(
            url: url,
            cachePolicy: ignoringLocalCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        )
        request.timeoutInterval = 60
        request.setValue("AloiOS", forHTTPHeaderField: "X-Requested-With")
        if ignoringLocalCache {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
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

    func heartbeatDirectCall(callId: Int) async throws {
        guard callId > 0 else { return }
        _ = try await request(
            "POST",
            "/api/calls/\(callId)/heartbeat",
            body: [:]
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

    func loadActiveGroupCall(roomId: Int) async throws -> AloGroupCallSession? {
        let response = try await request(
            "GET",
            "/api/group-calls/active?roomId=\(roomId)"
        )
        let raw = response.object("call")
        guard raw.int("id") > 0 else { return nil }
        return parseGroupCallSession(
            raw,
            participants: response.array("participants")
        )
    }

    func startGroupCall(roomId: Int) async throws -> AloGroupCallSession {
        let response = try await request(
            "POST",
            "/api/group-calls/start",
            body: [
                "roomId": roomId,
                "type": "video"
            ]
        )
        let raw = response.object("call")
        guard raw.int("id") > 0 else {
            throw AloAPIError(
                status: 0,
                code: "GROUP_CALL_SESSION_MISSING",
                message: "Сервер не вернул комнату видеочата.",
                payload: response
            )
        }
        return parseGroupCallSession(
            raw,
            participants: response.array("participants")
        )
    }

    func loadGroupCallSFUJoin(callId: Int) async throws -> AloGroupCallSFUJoin {
        let response = try await request(
            "POST",
            "/api/group-calls/\(callId)/join-token",
            body: [:]
        )
        let serverURL = response.string("serverUrl")
        let token = response.string("token")
        guard !serverURL.isEmpty, !token.isEmpty else {
            throw AloAPIError(
                status: 0,
                code: "GROUP_CALL_SFU_CREDENTIALS_MISSING",
                message: "Сервер не вернул параметры медиакомнаты.",
                payload: response
            )
        }
        return AloGroupCallSFUJoin(
            serverURL: serverURL,
            roomName: response.string("roomName"),
            identity: response.string("identity"),
            token: token,
            expiresAt: ISO8601DateFormatter().date(from: response.string("expiresAt"))
        )
    }

    func sendGroupCallSignal(
        callId: Int,
        kind: String,
        payload: [String: Any],
        toUserId: Int
    ) async throws {
        guard toUserId > 0 else { return }
        let normalizedKind = kind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let securedPayload = try await buildEncryptedDirectCallSignalPayload(
            peerId: toUserId,
            payload: payload
        )
        _ = try await request(
            "POST",
            "/api/group-calls/\(callId)/signal",
            body: [
                "kind": normalizedKind,
                "payload": securedPayload,
                "toUserId": toUserId
            ]
        )
    }

    func leaveGroupCall(callId: Int) async throws {
        _ = try await request(
            "POST",
            "/api/group-calls/\(callId)/leave",
            body: [:]
        )
    }

    func heartbeatGroupCall(callId: Int) async throws {
        guard callId > 0 else { return }
        _ = try await request(
            "POST",
            "/api/group-calls/\(callId)/heartbeat",
            body: [:]
        )
    }

    // MARK: Video-chat controls

    func loadGroupCallControls(callId: Int) async throws -> AloGroupCallControls {
        let json = try await request("GET", "/api/group-calls/\(callId)/state")
        return AloGroupCallControls(json.object("state"))
    }

    func setGroupCallHand(callId: Int, raised: Bool) async throws {
        _ = try await request("POST", "/api/group-calls/\(callId)/hand", body: ["raised": raised])
    }

    func muteGroupCallParticipant(callId: Int, userId: Int, muted: Bool) async throws {
        _ = try await request("POST", "/api/group-calls/\(callId)/mute", body: ["userId": userId, "muted": muted])
    }

    /// Mutes (or lets speak) everyone but admins; returns whom it changed.
    func muteGroupCallEveryone(callId: Int, muted: Bool) async throws -> Set<Int> {
        let json = try await request("POST", "/api/group-calls/\(callId)/mute", body: ["all": true, "muted": muted])
        return Set((json["userIds"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
    }

    func setGroupCallRecording(callId: Int, active: Bool, title: String) async throws {
        _ = try await request("POST", "/api/group-calls/\(callId)/recording", body: ["active": active, "title": title])
    }

    func pollGroupCallSignals(afterId: Int) async throws -> [AloGroupCallSignal] {
        let response = try await request(
            "GET",
            "/api/group-calls/poll?afterId=\(max(0, afterId))"
        )
        return response.array("signals").map { item in
            AloGroupCallSignal(
                id: item.int("id"),
                callId: item.int("callId"),
                roomId: item.int("roomId"),
                fromUserId: item.int("fromUserId"),
                toUserId: item.int("toUserId"),
                kind: item.string("kind"),
                payload: decryptDirectCallSignalPayload(item.object("payload"))
            )
        }
    }

    func callEventStream() -> AsyncThrowingStream<AloChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                do {
                    let url = self.activeBaseURL.appendingPathComponent("api/calls/stream")
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.timeoutInterval = 45
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("AloiOS", forHTTPHeaderField: "X-Requested-With")

                    let (bytes, response) = try await self.streamingSession.bytes(for: request)
                    defer { bytes.task.cancel() }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        throw AloAPIError(
                            status: status,
                            code: status == 401 ? "UNAUTHORIZED" : "CALL_STREAM_FAILED",
                            message: status == 401
                                ? "Требуется авторизация."
                                : "Realtime-соединение звонков недоступно.",
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
                                let payload = (try? JSONSerialization.jsonObject(with: data))
                                    as? [String: Any] ?? [:]
                                continuation.yield(
                                    AloChatStreamEvent(
                                        id: eventId,
                                        name: eventName,
                                        payload: payload
                                    )
                                )
                            }
                            eventId = 0
                            eventName = "message"
                            dataLines.removeAll(keepingCapacity: true)
                            continue
                        }
                        if line.hasPrefix(":") { continue }
                        if line.hasPrefix("id:") {
                            eventId = Int(
                                line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                            ) ?? 0
                        } else if line.hasPrefix("event:") {
                            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(
                                line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            )
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

    private func parseGroupCallSession(
        _ raw: [String: Any],
        participants: [[String: Any]]
    ) -> AloGroupCallSession {
        AloGroupCallSession(
            id: raw.int("id"),
            roomId: raw.int("roomId"),
            type: raw.string("type").ifBlank("video"),
            status: raw.string("status").ifBlank("active"),
            roomTitle: raw.string("roomTitle").ifBlank("Видеочат"),
            participants: participants.compactMap { user in
                let id = user.int("id")
                guard id > 0 else { return nil }
                return AloDirectCallPeer(
                    id: id,
                    name: user.string("name").ifBlank("Участник"),
                    username: user.string("username"),
                    avatarURL: user.string("avatarUrl").ifBlank(user.string("avatarEmoji")),
                    verified: user.bool("verified") || user.bool("isVerified")
                )
            }
        )
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

    func directChatAutoDeleteSeconds(peerId: Int) async throws -> Int {
        let response = try await request("GET", "/api/direct-chats/\(peerId)/settings")
        return max(0, response.int("autoDeleteSeconds"))
    }

    func setDirectChatAutoDeleteSeconds(peerId: Int, seconds: Int) async throws -> Int {
        let response = try await request(
            "PATCH",
            "/api/direct-chats/\(peerId)/settings",
            body: ["autoDeleteSeconds": max(0, seconds)]
        )
        return max(0, response.int("autoDeleteSeconds"))
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
        clearSessionCookies()
    }

    /// Returns only cookies scoped to an Alo API host. Cookie values never enter
    /// UserDefaults; callers that persist a session must use Keychain.
    func sessionCookies() -> [HTTPCookie] {
        (HTTPCookieStorage.shared.cookies ?? []).filter(isAloCookie)
    }

    /// Atomically drops the current in-memory identity and replaces the Alo
    /// server cookies. Used for local account switching, not for remote logout.
    func replaceSessionCookies(_ cookies: [HTTPCookie]) {
        clearSessionCookies()
        for cookie in cookies where isAloCookie(cookie) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    private func clearSessionCookies() {
        currentUserId = 0
        libSignalUserId = 0
        libSignalProtocolDeviceId = 0
        libSignalStore = nil
        libSignalEngine = nil
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where isAloCookie(cookie) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    private func isAloCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !domain.isEmpty else { return false }
        return baseURLs.contains { baseURL in
            guard let host = baseURL.host?.lowercased() else { return false }
            return host == domain || host.hasSuffix(".\(domain)") || domain.hasSuffix(".\(host)")
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

    func loadChannelProfile(channelId: Int) async throws -> AloChannelProfile {
        let json = try await request("GET", "/api/channels/\(channelId)/profile")
        return AloChannelProfile(json)
    }

    func updateChannelSettings(
        channelId: Int,
        commentsEnabled: Bool,
        signMessages: Bool,
        showAuthorProfiles: Bool
    ) async throws -> AloChannelProfile {
        let json = try await request(
            "PATCH",
            "/api/channels/\(channelId)",
            body: [
                "commentsEnabled": commentsEnabled,
                "signMessages": signMessages,
                "showAuthorProfiles": showAuthorProfiles
            ]
        )
        return AloChannelProfile(json)
    }

    func loadChannelAdminLog(
        channelId: Int,
        action: String? = nil,
        actorUserId: Int? = nil,
        beforeId: Int? = nil,
        limit: Int = 100
    ) async throws -> [AloChannelAdminEvent] {
        var query = ["limit=\(min(200, max(1, limit)))"]
        if let action, !action.isEmpty {
            query.append("action=\(action.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? action)")
        }
        if let actorUserId, actorUserId > 0 {
            query.append("actorUserId=\(actorUserId)")
        }
        if let beforeId, beforeId > 0 {
            query.append("beforeId=\(beforeId)")
        }
        let json = try await request(
            "GET",
            "/api/channels/\(channelId)/admin-log?\(query.joined(separator: "&"))"
        )
        return json.array("events").map(AloChannelAdminEvent.init)
    }

    func loadGroupAdminLog(
        roomId: Int,
        beforeId: Int? = nil,
        action: String? = nil,
        actorUserId: Int? = nil,
        limit: Int = 100
    ) async throws -> AloGroupAdminLogPage {
        var query = ["limit=\(min(200, max(1, limit)))"]
        if let beforeId, beforeId > 0 {
            query.append("beforeId=\(beforeId)")
        }
        if let action, !action.isEmpty {
            query.append("action=\(action.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? action)")
        }
        if let actorUserId, actorUserId > 0 {
            query.append("actorUserId=\(actorUserId)")
        }
        let json = try await request(
            "GET",
            "/api/group-chats/\(roomId)/admin-log?\(query.joined(separator: "&"))"
        )
        return AloGroupAdminLogPage(json)
    }

    func loadBootstrapSnapshot(peerId: Int = 0, timeout: TimeInterval = 15) async throws -> (data: AloBootstrapData, raw: [String: Any]) {
        let path = peerId > 0 ? "/api/app/bootstrap?peerId=\(peerId)" : "/api/app/bootstrap"
        var raw = try await request("GET", path, timeout: timeout)
        let currentUserId = raw.object("data").object("me").int("id")
        self.currentUserId = currentUserId
        await registerE2EEDeviceKeyIfPossible(currentUserId: currentUserId)
        await registerLibSignalDeviceIfPossible(currentUserId: currentUserId)
        raw = await decryptE2EEMessages(inBootstrap: raw)
        return (AloBootstrapData(raw), raw)
    }

    /// `draftMedia` is media a saved draft already uploaded; publishing with `draftId` uses the draft up.
    func createPost(body: String, media: [AloMessageAttachment] = [], draftMedia: [AloMediaItem] = [],
                    draftId: Int? = nil, captchaToken: String? = nil) async throws -> AloPost {
        let json = try await request(
            "POST",
            "/api/posts",
            body: compactBody([
                "body": body,
                "media": draftMedia.map(\.payload) + media.map { ["type": $0.type, "url": $0.url, "name": $0.name] },
                "draftId": draftId,
                "captchaToken": captchaToken
            ])
        )
        let post = AloPost(json.object("post"))
        guard post.id > 0 else {
            throw AloAPIError(
                status: 502,
                code: "POST_ACK_INVALID",
                message: "Сервер не подтвердил публикацию. Черновик сохранён — попробуйте ещё раз.",
                payload: json
            )
        }
        return post
    }

    func loadStories() async throws -> [AloStoryGroup] {
        let json = try await request("GET", "/api/stories")
        return json.array("stories").map(AloStoryGroup.init)
    }

    func createStory(
        body: String,
        media: [AloMessageAttachment] = [],
        lifetimeHours: Int = 24,
        audience: AloStoryAudience = .everyone,
        audienceUserIds: [Int] = []
    ) async throws -> AloStory {
        let json = try await request(
            "POST",
            "/api/stories",
            body: [
                "audience": audience.rawValue,
                "audienceUserIds": audienceUserIds,
                "body": body,
                "media": media.map {
                    [
                        "type": $0.type,
                        "url": $0.url,
                        "poster": $0.posterUrl,
                        "caption": $0.name
                    ]
                },
                "lifetimeHours": max(1, min(48, lifetimeHours))
            ]
        )
        let story = AloStory(json.object("story"))
        guard story.id > 0 else {
            throw AloAPIError(status: 502, code: "STORY_ACK_INVALID",
                message: "Сервер не подтвердил публикацию истории. Черновик сохранён в редакторе.", payload: [:])
        }
        return story
    }

    func markStoryViewed(storyId: Int) async throws {
        _ = try await request("POST", "/api/stories/\(storyId)/view", body: [:])
    }

    func deleteStory(storyId: Int) async throws {
        _ = try await request("DELETE", "/api/stories/\(storyId)")
    }

    /// The story's share code (one per story); the app builds the link from it.
    func createStoryLink(storyId: Int) async throws -> String {
        let json = try await request("POST", "/api/stories/\(storyId)/link", body: [:])
        let code = json.string("code")
        guard AloDeepLinkTarget.isStoryCode(code) else {
            throw AloAPIError(status: 0, code: "BAD_RESPONSE", message: "Не удалось создать ссылку.", payload: json)
        }
        return code
    }

    /// 410 means the story expired or was deleted; the author still comes back.
    func resolveStoryLink(code: String) async throws -> AloStoryLinkResult {
        guard AloDeepLinkTarget.isStoryCode(code) else { return .expired(author: nil) }
        do {
            let json = try await request("GET", "/api/stories/link/\(code)")
            let story = json.object("story")
            return .live(AloStoryGroup([
                "user": json.object("user"),
                "stories": [story],
                "hasUnseen": !story.bool("viewerHasSeen")
            ]))
        } catch let error as AloAPIError where error.status == 410 {
            return .expired(author: (error.payload["user"] as? [String: Any]).map(AloEntitySummary.init))
        }
    }

    func loadFriends() async throws -> [AloEntitySummary] {
        try await request("GET", "/api/friends").array("friends").map(AloEntitySummary.init)
    }

    func loadStorySettings() async throws -> AloStorySettings {
        AloStorySettings(try await request("GET", "/api/stories/settings"))
    }

    func updateCloseFriends(_ userIds: [Int]) async throws -> [AloEntitySummary] {
        try await request("PUT", "/api/stories/close-friends", body: ["userIds": userIds]).array("people").map(AloEntitySummary.init)
    }

    func updateStoryHiddenFrom(_ userIds: [Int]) async throws -> [AloEntitySummary] {
        try await request("PUT", "/api/stories/hidden-from", body: ["userIds": userIds]).array("people").map(AloEntitySummary.init)
    }

    /// Your own stories, expired ones too, newest first; `before` pages back.
    func loadStoryArchive(before: String = "") async throws -> (stories: [AloStory], nextBefore: String) {
        let query = before.isEmpty ? "" : "?before=\(before.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        let json = try await request("GET", "/api/stories/archive\(query)")
        return (json.array("stories").map(AloStory.init), json.string("nextBefore"))
    }

    func loadHighlights(userId: Int) async throws -> [AloStoryHighlight] {
        try await request("GET", "/api/users/\(userId)/highlights").array("highlights").map(AloStoryHighlight.init)
    }

    func createHighlight(title: String, storyIds: [Int]) async throws -> AloStoryHighlight {
        AloStoryHighlight(try await request("POST", "/api/stories/highlights",
                                            body: ["title": title, "storyIds": storyIds]).object("highlight"))
    }

    /// Nil when the change emptied the highlight and the server removed it.
    func updateHighlight(id: Int, title: String? = nil, addStoryIds: [Int] = [], removeStoryIds: [Int] = [],
                         coverStoryId: Int? = nil) async throws -> AloStoryHighlight? {
        var body: [String: Any] = ["addStoryIds": addStoryIds, "removeStoryIds": removeStoryIds]
        if let title { body["title"] = title }
        if let coverStoryId { body["coverStoryId"] = coverStoryId }
        let json = try await request("PATCH", "/api/stories/highlights/\(id)", body: body)
        let highlight = json.object("highlight")
        return highlight.isEmpty ? nil : AloStoryHighlight(highlight)
    }

    func deleteHighlight(id: Int) async throws {
        _ = try await request("DELETE", "/api/stories/highlights/\(id)")
    }

    /// Who has seen a story, newest first; only its author may ask.
    func loadStoryViewers(storyId: Int) async throws -> [AloStoryViewerEntry] {
        let json = try await request("GET", "/api/stories/\(storyId)/viewers")
        return json.array("viewers").map(AloStoryViewerEntry.init)
    }

    func loadBusinessProfile() async throws -> AloBusinessProfileData {
        AloBusinessProfileData(try await request("GET", "/api/business/profile"))
    }

    func updateBusinessProfile(
        enabled: Bool,
        businessName: String,
        category: String,
        hours: [String: String],
        greetingMessage: String,
        autoReplyEnabled: Bool,
        autoReplyMessage: String
    ) async throws -> AloBusinessProfile {
        let json = try await request(
            "PUT",
            "/api/business/profile",
            body: [
                "enabled": enabled,
                "businessName": businessName,
                "category": category,
                "hours": hours,
                "greetingMessage": greetingMessage,
                "autoReplyEnabled": autoReplyEnabled,
                "autoReplyMessage": autoReplyMessage
            ]
        )
        return AloBusinessProfile(json.object("profile"))
    }

    func createBusinessQuickReply(shortcut: String, title: String, body: String) async throws -> AloBusinessQuickReply {
        let json = try await request(
            "POST",
            "/api/business/quick-replies",
            body: ["shortcut": shortcut, "title": title, "body": body]
        )
        return AloBusinessQuickReply(json.object("quickReply"))
    }

    func deleteBusinessQuickReply(id: Int) async throws {
        _ = try await request("DELETE", "/api/business/quick-replies/\(id)")
    }

    func saveBusinessChatLabel(
        chatKind: String,
        peerId: Int,
        roomId: Int,
        label: String,
        color: String
    ) async throws -> AloBusinessChatLabel {
        let json = try await request(
            "PUT",
            "/api/business/chat-labels",
            body: [
                "chatKind": chatKind,
                "peerId": peerId,
                "roomId": roomId,
                "label": label,
                "color": color
            ]
        )
        return AloBusinessChatLabel(json.object("chatLabel"))
    }

    func deleteBusinessChatLabel(id: Int) async throws {
        _ = try await request("DELETE", "/api/business/chat-labels/\(id)")
    }

    func loadPost(postId: Int) async throws -> AloPost {
        let json = try await request("GET", "/api/posts/\(postId)")
        return AloPost(json.object("post"))
    }

    func resolveAppLink(handle: String) async throws -> AloResolvedAppLink {
        let normalized = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .lowercased()
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
        let json = try await request("GET", "/api/links/resolve/\(encoded)")
        let target = json.object("target")
        return AloResolvedAppLink(
            kind: target.string("kind"),
            id: target.int("id"),
            handle: target.string("handle").ifBlank(normalized)
        )
    }

    func resolveForumTopicLink(roomId: Int, topicId: Int) async throws -> AloForumTopicLink {
        guard roomId > 0, topicId > 0 else {
            throw AloAPIError(
                status: 0,
                code: "INVALID_LINK",
                message: "Некорректная ссылка на тему.",
                payload: [:]
            )
        }
        let json = try await request("GET", "/api/links/topics/\(roomId)/\(topicId)")
        let target = json.object("target")
        let result = AloForumTopicLink(
            roomId: target.int("roomId"),
            peerId: target.int("peerId"),
            topicId: target.int("topicId")
        )
        guard result.roomId == roomId,
              result.peerId > 0,
              result.topicId == topicId else {
            throw AloAPIError(
                status: 0,
                code: "INVALID_RESPONSE",
                message: "Сервер не вернул доступную тему.",
                payload: json
            )
        }
        return result
    }

    func openPostDiscussion(postId: Int) async throws -> AloPostDiscussion {
        let json = try await request("POST", "/api/posts/\(postId)/discussion")
        let discussion = json.object("discussion")
        let result = AloPostDiscussion(
            roomId: discussion.int("roomId"),
            peerId: discussion.int("peerId"),
            topicId: discussion.int("topicId")
        )
        guard result.roomId > 0, result.peerId > 0, result.topicId > 0 else {
            throw AloAPIError(
                status: 0,
                code: "INVALID_RESPONSE",
                message: "Сервер не вернул связанную тему обсуждения.",
                payload: json
            )
        }
        return result
    }

    func toggleLike(postId: Int) async throws -> AloPost {
        let json = try await request("POST", "/api/posts/\(postId)/like")
        return AloPost(json.object("post"))
    }

    func toggleRepost(postId: Int, captchaToken: String? = nil) async throws -> AloPost {
        let json = try await request(
            "POST",
            "/api/posts/\(postId)/repost",
            body: compactBody(["captchaToken": captchaToken])
        )
        return AloPost(json.object("post"))
    }

    func deletePost(postId: Int) async throws -> Int {
        let json = try await request("DELETE", "/api/posts/\(postId)")
        return json.int("deletedPostId").ifZero(postId)
    }

    func loadConversation(peerId: Int) async throws -> AloConversationDetail {
        let raw = try await request("GET", "/api/messages/\(peerId)")
        let decryptedMessages = await decryptE2EEMessages(inConversation: raw)
        let decryptedTopics = await decryptForumTopicStates(inConversation: decryptedMessages)
        let decrypted = await attachCanonicalPollStates(to: decryptedTopics)
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

    func registerPoll(
        _ definition: AloPollDefinition,
        messageId: Int,
        conversation: AloConversationDetail
    ) async throws -> AloCanonicalPollState {
        var payload = pollRegistrationPayload(definition)
        payload["chatKind"] = conversation.kind == "group" ? "group" : "direct"
        payload["roomId"] = max(0, conversation.roomId)
        payload["messageId"] = messageId
        let json = try await request(
            "POST",
            "/api/polls",
            body: payload
        )
        return AloCanonicalPollState(json.object("poll"))
    }

    func votePoll(pollId: String, optionIds: Set<String>) async throws -> AloCanonicalPollState {
        let json = try await request(
            "PUT",
            "/api/polls/\(pollId)/vote",
            body: ["optionIds": Array(optionIds).sorted()]
        )
        return AloCanonicalPollState(json.object("poll"))
    }

    func closePoll(pollId: String) async throws -> AloCanonicalPollState {
        let json = try await request(
            "POST",
            "/api/polls/\(pollId)/close",
            body: [:]
        )
        return AloCanonicalPollState(json.object("poll"))
    }

    private func attachCanonicalPollStates(to conversation: [String: Any]) async -> [String: Any] {
        let pollIds = Array(Set(conversation.array("items").compactMap { item -> String? in
            guard case let .create(definition)? = AloPollCodec.decode(item.string("body")) else { return nil }
            return definition.id
        })).sorted()
        guard !pollIds.isEmpty,
              let response = try? await request(
                "GET",
                "/api/polls?ids=\(pollIds.joined(separator: ","))"
              ) else { return conversation }
        var enriched = conversation
        enriched["polls"] = response.array("polls")
        return enriched
    }

    func backfillConversationSearchHistory(peerId: Int) async throws {
        let ownerUserId = currentUserId
        guard peerId > 0, ownerUserId > 0 else { return }
        let store = AloSecureOfflineCacheStore.shared
        guard !store.isSearchHistoryComplete(peerId: peerId, ownerUserId: ownerUserId) else {
            return
        }

        var beforeId = store.oldestSearchMessageId(peerId: peerId, ownerUserId: ownerUserId)
        if beforeId <= 0 {
            // A conversation that has never been opened has no encrypted
            // index yet. Seed it once, then walk older pages below. This keeps
            // the eventual global search entirely device-local.
            let seed = try await loadConversation(peerId: peerId)
            guard !seed.items.isEmpty else {
                store.markSearchHistoryComplete(peerId: peerId, ownerUserId: ownerUserId)
                return
            }
            beforeId = store.oldestSearchMessageId(peerId: peerId, ownerUserId: ownerUserId)
            guard beforeId > 0 else { return }
        }

        while !Task.isCancelled {
            let raw = try await request(
                "GET",
                "/api/messages/\(peerId)/history?beforeId=\(beforeId)&limit=200"
            )
            let decrypted = await decryptE2EEMessages(inConversation: raw)
            let page = decrypted.object("page")
            let hasMore = page.bool("hasMore")
            let nextBeforeId = page.int("nextBeforeId")
            guard JSONSerialization.isValidJSONObject(decrypted),
                  let data = try? JSONSerialization.data(withJSONObject: decrypted) else {
                return
            }
            store.mergeSearchHistory(
                data,
                peerId: peerId,
                ownerUserId: ownerUserId,
                complete: !hasMore
            )
            guard hasMore, nextBeforeId > 0, nextBeforeId < beforeId else { return }
            beforeId = nextBeforeId
        }
    }

    func toggleMessagePin(
        conversation: AloConversationDetail,
        messageId: Int,
        pinned: Bool? = nil,
        operationId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws {
        let path = conversation.kind == "group" && conversation.roomId > 0
            ? "/api/group-chats/\(conversation.roomId)/messages/\(messageId)/pin"
            : "/api/messages/\(messageId)/pin"
        var body: [String: Any] = conversation.kind == "group" ? [:] : ["scope": "both"]
        if let pinned {
            body["pinned"] = pinned
        }
        body["operationId"] = operationId
        _ = try await request("POST", path, body: body)
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

    func updatesEventStream(afterCursor cursor: Int) -> AsyncThrowingStream<AloChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                do {
                    var components = URLComponents(
                        url: self.activeBaseURL.appendingPathComponent("api/updates/stream"),
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
                    request.timeoutInterval = 45
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("AloiOS", forHTTPHeaderField: "X-Requested-With")
                    if cursor > 0 {
                        request.setValue(String(cursor), forHTTPHeaderField: "Last-Event-ID")
                    }

                    let (bytes, response) = try await self.streamingSession.bytes(for: request)
                    defer { bytes.task.cancel() }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        throw AloAPIError(
                            status: status,
                            code: status == 401 ? "UNAUTHORIZED" : "UPDATES_STREAM_FAILED",
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

    func acknowledgeUpdates(cursor: Int, deviceId: String) async throws {
        _ = try await request(
            "PUT",
            "/api/updates/cursor",
            body: [
                "cursor": max(0, cursor),
                "deviceId": deviceId
            ]
        )
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

    /// `action` is "typing", "voice" (recording a voice message) or "circle" (recording a video message).
    func sendTyping(conversation: AloConversationDetail, action: String = "typing") async throws {
        _ = try await request(
            "POST",
            "/api/chat/typing",
            body: [
                "kind": conversation.kind,
                "peerId": conversation.peerId,
                "roomId": conversation.roomId,
                "action": action
            ]
        )
    }

    func uploadAttachment(_ attachment: AloLocalAttachment, purpose: String = "message") async throws -> AloMessageAttachment {
        let json: [String: Any]
        if let encryptedSource = attachment.encryptedSourceURL {
            // Public posts/stories are not E2EE messages. Read the protected
            // draft to a short-lived file on a worker, not an empty Data value
            // and not a whole plaintext movie in main-thread memory.
            let source = try await Task.detached(priority: .utility) {
                guard let metadata = AloChunkedMediaCrypto.Metadata(attachment.mediaEncryption),
                      metadata.plaintextSize <= (attachment.type == "image" ? 12 : 30) * 1_024 * 1_024 else {
                    throw AloAPIError(status: 400, code: "PUBLIC_MEDIA_TOO_LARGE",
                        message: "Для постов и историй: фото до 12 МБ, видео до 30 МБ.", payload: [:])
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("alo-public-upload-\(UUID().uuidString)")
                do {
                    try AloChunkedMediaCrypto.decrypt(encryptedURL: encryptedSource, metadata: metadata, destinationURL: url)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
                    return (url, metadata.plaintextSize, try Self.sha256(of: url))
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
            }.value
            defer { try? FileManager.default.removeItem(at: source.0) }
            json = try await uploadResumable(fileURL: source.0, size: source.1,
                checksum: source.2, purpose: purpose, mime: attachment.mime)
        } else {
            json = try await uploadResumable(data: attachment.data, purpose: purpose, mime: attachment.mime)
        }
        let file = json.object("file")
        return AloMessageAttachment([
            "type": file.string("type").ifBlank(attachment.type),
            "url": file.string("url"),
            "name": attachment.name,
            "waveform": attachment.waveform,
            "metadata": attachment.durationMetadata
        ])
    }

    func uploadE2EEAttachment(
        _ attachment: AloLocalAttachment,
        resumeCheckpoint: AloResumableUploadCheckpoint? = nil,
        onCheckpoint: ((AloResumableUploadCheckpoint) -> Void)? = nil
    ) async throws -> AloMessageAttachment {
        if let encryptedSourceURL = attachment.encryptedSourceURL,
           let metadata = AloChunkedMediaCrypto.Metadata(
            attachment.mediaEncryption.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = pair.value
            }
           ) {
            let expectedSize = AloChunkedMediaCrypto.expectedCiphertextSize(
                plaintextSize: metadata.plaintextSize,
                chunkSize: metadata.chunkSize
            )
            let actualSize = try encryptedSourceURL.resourceValues(forKeys: [.fileSizeKey])
                .fileSize
                .map(Int64.init) ?? -1
            guard actualSize == expectedSize else {
                throw AloAPIError(
                    status: 400,
                    code: "DRAFT_MEDIA_INVALID",
                    message: "Черновик вложения повреждён.",
                    payload: [:]
                )
            }
            let checksum: String
            if attachment.encryptedChecksum.isEmpty {
                checksum = try await Task.detached(priority: .utility) {
                    try Self.sha256(of: encryptedSourceURL)
                }.value
            } else {
                checksum = attachment.encryptedChecksum
            }
            let json = try await uploadResumable(
                fileURL: encryptedSourceURL,
                size: actualSize,
                checksum: checksum,
                purpose: "message_e2ee",
                mime: "application/octet-stream",
                resumeCheckpoint: resumeCheckpoint,
                onCheckpoint: onCheckpoint
            )
            let file = json.object("file")
            return AloMessageAttachment([
                "type": attachment.type,
                "url": file.string("url"),
                "name": attachment.name,
                "waveform": attachment.waveform,
                "mediaEncryption": metadata.dictionary,
                "metadata": attachment.durationMetadata
            ])
        }
        let sealed = try AloE2EECrypto.shared.encryptMedia(attachment.data)
        let json = try await uploadResumable(
            data: sealed.data,
            purpose: "message_e2ee",
            mime: "application/octet-stream"
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
            ],
            "metadata": attachment.durationMetadata
        ])
    }

    /// Encrypts a file incrementally before the resumable upload. The staging file
    /// contains only ciphertext and is removed as soon as the server acknowledges it.
    func uploadE2EEAttachment(
        sourceURL: URL,
        mime: String,
        type: String,
        name: String,
        waveform: [CGFloat] = []
    ) async throws -> AloMessageAttachment {
        let stagingDirectory = e2eeMediaCacheRoot()
            .appendingPathComponent("outgoing", isDirectory: true)
        let stagingURL = stagingDirectory.appendingPathComponent("\(UUID().uuidString).bin")
        let sealed = try await Task.detached(priority: .utility) {
            try AloChunkedMediaCrypto.encrypt(
                sourceURL: sourceURL,
                destinationURL: stagingURL,
                mime: mime
            )
        }.value
        defer { try? FileManager.default.removeItem(at: sealed.encryptedURL) }

        let json = try await uploadResumable(
            fileURL: sealed.encryptedURL,
            size: sealed.encryptedSize,
            checksum: sealed.sha256,
            purpose: "message_e2ee",
            mime: "application/octet-stream"
        )
        let file = json.object("file")
        return AloMessageAttachment([
            "type": type,
            "url": file.string("url"),
            "name": name,
            "waveform": waveform,
            "mediaEncryption": sealed.metadata.dictionary
        ])
    }

    private func uploadResumable(
        data: Data,
        purpose: String,
        mime: String
    ) async throws -> [String: Any] {
        guard !data.isEmpty else {
            throw AloAPIError(
                status: 400,
                code: "BAD_UPLOAD_SIZE",
                message: "Файл пуст.",
                payload: [:]
            )
        }
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let created = try await request(
            "POST",
            "/api/uploads/resumable",
            body: [
                "purpose": purpose,
                "mime": mime.ifBlank("application/octet-stream"),
                "size": data.count,
                "sha256": checksum
            ]
        )
        let upload = created.object("upload")
        let uploadId = upload.string("id")
        guard !uploadId.isEmpty else {
            throw AloAPIError(
                status: 500,
                code: "UPLOAD_SESSION_INVALID",
                message: "Сервер не создал сессию загрузки.",
                payload: created
            )
        }
        let chunkSize = min(5 * 1024 * 1024, max(64 * 1024, upload.int("chunkSize")))
        var offset = max(0, upload.int("offset"))
        var retryCount = 0

        while offset < data.count {
            try Task.checkCancellation()
            let endExclusive = min(data.count, offset + chunkSize)
            let chunk = data.subdata(in: offset..<endExclusive)
            do {
                let response = try await uploadResumableChunk(
                    uploadId: uploadId,
                    chunk: chunk,
                    start: Int64(offset),
                    total: Int64(data.count)
                )
                if response.bool("complete") {
                    guard !response.object("file").string("url").isEmpty else {
                        throw AloAPIError(
                            status: 500,
                            code: "UPLOAD_FILE_MISSING",
                            message: "Сервер не вернул загруженный файл.",
                            payload: response
                        )
                    }
                    return response
                }
                let acknowledged = response.object("upload").int("offset")
                guard acknowledged > offset, acknowledged <= data.count else {
                    throw AloAPIError(
                        status: 409,
                        code: "UPLOAD_OFFSET_INVALID",
                        message: "Сервер подтвердил некорректное смещение загрузки.",
                        payload: response
                    )
                }
                offset = acknowledged
                retryCount = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                retryCount += 1
                guard Self.shouldRetryUpload(error), retryCount <= 2 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(250 * (1 << (retryCount - 1))) * 1_000_000)
                let status = try await request("GET", "/api/uploads/resumable/\(uploadId)")
                let remoteUpload = status.object("upload")
                if remoteUpload.bool("complete"), !remoteUpload.object("file").string("url").isEmpty {
                    return [
                        "ok": true,
                        "complete": true,
                        "file": remoteUpload.object("file")
                    ]
                }
                let acknowledged = remoteUpload.int("offset")
                guard acknowledged >= 0, acknowledged <= data.count else { throw error }
                offset = acknowledged
            }
        }
        throw AloAPIError(
            status: 500,
            code: "UPLOAD_INCOMPLETE",
            message: "Загрузка не была завершена.",
            payload: [:]
        )
    }

    private func uploadResumable(
        fileURL: URL,
        size: Int64,
        checksum: String,
        purpose: String,
        mime: String,
        resumeCheckpoint: AloResumableUploadCheckpoint? = nil,
        onCheckpoint: ((AloResumableUploadCheckpoint) -> Void)? = nil
    ) async throws -> [String: Any] {
        guard size > 0,
              size <= AloChunkedMediaCrypto.expectedCiphertextSize(
                plaintextSize: AloChunkedMediaCrypto.maximumPlaintextSize,
                chunkSize: AloChunkedMediaCrypto.defaultChunkSize
              ) else {
            throw AloAPIError(
                status: 400,
                code: "BAD_UPLOAD_SIZE",
                message: "Размер файла превышает лимит 2 ГБ.",
                payload: [:]
            )
        }
        var uploadId = ""
        var chunkSize = 512 * 1024
        var offset: Int64 = 0

        if let resumeCheckpoint,
           resumeCheckpoint.isValid,
           resumeCheckpoint.total == size,
           resumeCheckpoint.checksum == checksum.lowercased() {
            do {
                let status = try await request("GET", "/api/uploads/resumable/\(resumeCheckpoint.uploadId)")
                let upload = status.object("upload")
                guard Int64(max(0, upload.int("size"))) == size else {
                    throw AloAPIError(
                        status: 409,
                        code: "UPLOAD_SESSION_MISMATCH",
                        message: "Серверная сессия загрузки не соответствует файлу.",
                        payload: status
                    )
                }
                if upload.bool("complete"), !upload.object("file").string("url").isEmpty {
                    return [
                        "ok": true,
                        "complete": true,
                        "file": upload.object("file")
                    ]
                }
                uploadId = resumeCheckpoint.uploadId
                chunkSize = min(5 * 1024 * 1024, max(64 * 1024, upload.int("chunkSize")))
                offset = Int64(max(0, upload.int("offset")))
                guard offset <= size else {
                    throw AloAPIError(
                        status: 409,
                        code: "UPLOAD_OFFSET_INVALID",
                        message: "Сервер подтвердил некорректное смещение загрузки.",
                        payload: status
                    )
                }
            } catch let error as AloAPIError where error.status == 404 || error.status == 410 {
                // The server expired the temporary upload. Start a new opaque
                // session while retaining the durable ciphertext source file.
            }
        }

        if uploadId.isEmpty {
            let created = try await request(
                "POST",
                "/api/uploads/resumable",
                body: [
                    "purpose": purpose,
                    "mime": mime.ifBlank("application/octet-stream"),
                    "size": size,
                    "sha256": checksum
                ]
            )
            let upload = created.object("upload")
            uploadId = upload.string("id")
            guard !uploadId.isEmpty else {
                throw AloAPIError(
                    status: 500,
                    code: "UPLOAD_SESSION_INVALID",
                    message: "Сервер не создал сессию загрузки.",
                    payload: created
                )
            }
            chunkSize = min(5 * 1024 * 1024, max(64 * 1024, upload.int("chunkSize")))
            offset = Int64(max(0, upload.int("offset")))
        }

        func persistCheckpoint(_ acknowledgedOffset: Int64) {
            onCheckpoint?(AloResumableUploadCheckpoint(
                uploadId: uploadId,
                offset: acknowledgedOffset,
                total: size,
                checksum: checksum.lowercased()
            ))
        }

        persistCheckpoint(offset)
        var retryCount = 0
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { try? file.close() }

        while offset < size {
            try Task.checkCancellation()
            let expectedChunkSize = Int(min(Int64(chunkSize), size - offset))
            try file.seek(toOffset: UInt64(offset))
            guard let chunk = try file.read(upToCount: expectedChunkSize), chunk.count == expectedChunkSize else {
                throw AloAPIError(
                    status: 500,
                    code: "UPLOAD_SOURCE_TRUNCATED",
                    message: "Исходный файл изменился во время загрузки.",
                    payload: [:]
                )
            }
            do {
                let response = try await uploadResumableChunk(
                    uploadId: uploadId,
                    chunk: chunk,
                    start: offset,
                    total: size
                )
                if response.bool("complete") {
                    guard !response.object("file").string("url").isEmpty else {
                        throw AloAPIError(
                            status: 500,
                            code: "UPLOAD_FILE_MISSING",
                            message: "Сервер не вернул загруженный файл.",
                            payload: response
                        )
                    }
                    return response
                }
                let acknowledged = Int64(max(0, response.object("upload").int("offset")))
                guard acknowledged > offset, acknowledged <= size else {
                    throw AloAPIError(
                        status: 409,
                        code: "UPLOAD_OFFSET_INVALID",
                        message: "Сервер подтвердил некорректное смещение загрузки.",
                        payload: response
                    )
                }
                offset = acknowledged
                persistCheckpoint(offset)
                retryCount = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                retryCount += 1
                guard Self.shouldRetryUpload(error), retryCount <= 2 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(250 * (1 << (retryCount - 1))) * 1_000_000)
                let status = try await request("GET", "/api/uploads/resumable/\(uploadId)")
                let remoteUpload = status.object("upload")
                if remoteUpload.bool("complete"), !remoteUpload.object("file").string("url").isEmpty {
                    return [
                        "ok": true,
                        "complete": true,
                        "file": remoteUpload.object("file")
                    ]
                }
                let acknowledged = Int64(max(0, remoteUpload.int("offset")))
                guard acknowledged <= size else { throw error }
                offset = acknowledged
                persistCheckpoint(offset)
            }
        }
        throw AloAPIError(
            status: 500,
            code: "UPLOAD_INCOMPLETE",
            message: "Загрузка не была завершена.",
            payload: [:]
        )
    }

    static func shouldRetryUpload(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed].contains(error.code)
        }
        guard let error = error as? AloAPIError else { return false }
        return error.code == "CONNECTION_FAILED" || error.status == 408 || error.status == 429 ||
            error.code == "UPLOAD_OFFSET_MISMATCH" ||
            ([500, 502, 503, 504].contains(error.status) && !error.code.hasPrefix("UPLOAD_"))
    }

    private func uploadResumableChunk(
        uploadId: String,
        chunk: Data,
        start: Int64,
        total: Int64
    ) async throws -> [String: Any] {
        let path = "/api/uploads/resumable/\(uploadId)"
        guard let url = URL(string: path, relativeTo: activeBaseURL)?.absoluteURL else {
            throw AloAPIError(status: 0, code: "BAD_URL", message: "Некорректный адрес загрузки.", payload: [:])
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("AloiOS", forHTTPHeaderField: "X-Requested-With")
        urlRequest.setValue(
            "bytes \(start)-\(start + Int64(chunk.count) - 1)/\(total)",
            forHTTPHeaderField: "Content-Range"
        )
        let (responseData, response) = try await session.upload(for: urlRequest, from: chunk)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            throw AloAPIError(
                status: status,
                code: json.string("code"),
                message: json.string("error").ifBlank("Не удалось продолжить загрузку."),
                payload: json
            )
        }
        return json
    }

    private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func loadUserProfile(userId: Int) async throws -> AloUserProfile {
        AloUserProfile(try await request("GET", "/api/users/\(userId)/profile"))
    }

    func loadBlockedUserIds() async throws -> Set<Int> {
        AloBlockedUserList.userIds(from: try await request("GET", "/api/users/blocks"))
    }

    func blockUser(userId: Int) async throws {
        _ = try await request("POST", "/api/users/\(userId)/block", body: [:])
    }

    func unblockUser(userId: Int) async throws {
        _ = try await request("DELETE", "/api/users/\(userId)/block")
    }

    /// `coverImageUrl`: nil keeps the photo, "" removes it, a path sets a freshly uploaded one.
    func updateProfileCover(coverStyle: String, coverImageUrl: String? = nil) async throws -> AloCurrentUser {
        var body: [String: Any] = ["coverStyle": coverStyle]
        if let coverImageUrl { body["coverImageUrl"] = coverImageUrl }
        let json = try await request(
            "PATCH",
            "/api/profile/cover",
            body: body
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

    /// People search on the server (signed in, rate limited, public fields only).
    func searchUsers(query: String, limit: Int = 20) async throws -> [AloEntitySummary] {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        let json = try await request("GET", "/api/users/search?\(components.percentEncodedQuery ?? "")")
        return json.array("users").map(AloEntitySummary.init)
    }

    func createGroupChat(
        title: String,
        description: String,
        kind: String,
        joinPolicy: String,
        username: String,
        memberIds: [Int] = []
    ) async throws -> (roomId: Int, peerId: Int) {
        let json = try await request(
            "POST",
            "/api/group-chats",
            body: [
                "memberIds": memberIds,
                "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                "description": description.trimmingCharacters(in: .whitespacesAndNewlines),
                "kind": kind == "channel" ? "channel" : "group",
                "joinPolicy": ["invite", "request", "public"].contains(joinPolicy)
                    ? joinPolicy
                    : "invite",
                "username": username
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^@+", with: "", options: .regularExpression)
                    .lowercased()
            ]
        )
        let room = json.object("room")
        let roomId = room.int("id")
        let peerId = room.int("peerId")
        guard roomId > 0, peerId > 0 else {
            throw AloAPIError(
                status: 0,
                code: "INVALID_RESPONSE",
                message: "Сервер не вернул созданное сообщество.",
                payload: json
            )
        }
        return (roomId, peerId)
    }

    func loadGroupManagement(roomId: Int) async throws -> AloGroupManagementSnapshot {
        let profile = try await request("GET", "/api/group-chats/\(roomId)/profile")
        let room = profile.object("room")
        let requestsResponse = try? await request(
            "GET",
            "/api/group-chats/\(roomId)/join-requests"
        )
        let invitesResponse = try? await request(
            "GET",
            "/api/group-chats/\(roomId)/invite-links"
        )
        let eventsPage = try? await loadGroupAdminLog(roomId: roomId)
        let topicsResponse = try? await request(
            "GET",
            "/api/group-chats/\(roomId)/topics"
        )
        let bansResponse = try? await request(
            "GET",
            "/api/group-chats/\(roomId)/bans"
        )
        return AloGroupManagementSnapshot(
            policy: AloGroupPolicy(room.object("policy")),
            members: room.array("members").map(AloGroupMember.init),
            requests: requestsResponse?.array("requests").map(AloGroupJoinRequest.init) ?? [],
            invites: invitesResponse?.array("invites").map(AloGroupInviteLink.init) ?? [],
            events: eventsPage?.events ?? [],
            topics: topicsResponse?.array("topics").map(AloForumTopic.init) ?? [],
            bans: bansResponse?.array("bans").map(AloGroupBan.init) ?? [],
            nextAdminLogBeforeId: eventsPage?.nextBeforeId
        )
    }

    func createGroupInviteLink(
        roomId: Int,
        label: String,
        requiresApproval: Bool,
        usageLimit: Int,
        expiresAt: String = ""
    ) async throws -> (invite: AloGroupInviteLink, token: String) {
        let response = try await request(
            "POST",
            "/api/group-chats/\(roomId)/invite-links",
            body: [
                "label": label.trimmingCharacters(in: .whitespacesAndNewlines),
                "requiresApproval": requiresApproval,
                "usageLimit": max(0, usageLimit),
                "expiresAt": expiresAt.isEmpty ? NSNull() : expiresAt
            ]
        )
        let json = response.object("invite")
        return (AloGroupInviteLink(json), json.string("token"))
    }

    func updateGroupInviteLink(
        roomId: Int,
        inviteId: Int,
        label: String,
        requiresApproval: Bool,
        usageLimit: Int,
        expiresAt: String
    ) async throws -> AloGroupInviteLink {
        let response = try await request(
            "PATCH",
            "/api/group-chats/\(roomId)/invite-links/\(inviteId)",
            body: [
                "label": label.trimmingCharacters(in: .whitespacesAndNewlines),
                "requiresApproval": requiresApproval,
                "usageLimit": max(0, usageLimit),
                "expiresAt": expiresAt.isEmpty ? NSNull() : expiresAt
            ]
        )
        return AloGroupInviteLink(response.object("invite"))
    }

    func loadGroupInviteStats(roomId: Int, inviteId: Int) async throws -> AloGroupInviteStats {
        let response = try await request(
            "GET",
            "/api/group-chats/\(roomId)/invite-links/\(inviteId)/stats"
        )
        return AloGroupInviteStats(response)
    }

    func revokeGroupInviteLink(roomId: Int, inviteId: Int) async throws {
        _ = try await request(
            "DELETE",
            "/api/group-chats/\(roomId)/invite-links/\(inviteId)"
        )
    }

    func joinGroupInvite(token: String) async throws -> (peerId: Int, pendingApproval: Bool) {
        let raw = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (URL(string: raw)?.lastPathComponent ?? "").ifBlank(
            raw.split(separator: "/").last.map(String.init) ?? raw
        )
        let response = try await request(
            "POST",
            "/api/group-invites/\(normalized)/join",
            body: [:]
        )
        return (
            peerId: response.int("peerId"),
            pendingApproval: response.bool("pendingApproval")
        )
    }

    func joinPublicGroup(username: String) async throws -> (peerId: Int, pendingApproval: Bool) {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .lowercased()
        let response = try await request(
            "POST",
            "/api/group-public/\(normalized)/join",
            body: [:]
        )
        return (
            peerId: response.int("peerId"),
            pendingApproval: response.bool("pendingApproval")
        )
    }

    func updateGroupSettings(roomId: Int, policy: AloGroupPolicy) async throws -> AloGroupPolicy {
        let response = try await request(
            "PATCH",
            "/api/group-chats/\(roomId)/settings",
            body: policy.requestBody
        )
        return AloGroupPolicy(response.object("policy"))
    }

    func updateGroupMemberAccess(
        roomId: Int,
        userId: Int,
        role: String,
        adminTitle: String,
        isAnonymous: Bool,
        adminRights: [String: Bool],
        restrictions: [String: Bool],
        changeRole: Bool
    ) async throws -> [AloGroupMember] {
        if changeRole {
            _ = try await request(
                "PATCH",
                "/api/group-chats/\(roomId)/members/\(userId)/role",
                body: [
                    "role": role,
                    "adminTitle": adminTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    "isAnonymous": isAnonymous,
                    "adminRights": adminRights
                ]
            )
        }
        let response = try await request(
            "PATCH",
            "/api/group-chats/\(roomId)/members/\(userId)/permissions",
            body: [
                "adminRights": adminRights,
                "isAnonymous": isAnonymous,
                "restrictions": restrictions,
                "restrictedUntil": NSNull()
            ]
        )
        return response.array("members").map(AloGroupMember.init)
    }

    func transferGroupOwnership(
        roomId: Int,
        userId: Int,
        currentPassword: String
    ) async throws -> [AloGroupMember] {
        let response = try await request(
            "POST",
            "/api/group-chats/\(roomId)/transfer-ownership",
            body: [
                "userId": userId,
                "currentPassword": currentPassword
            ]
        )
        return response.array("members").map(AloGroupMember.init)
    }

    func banGroupMember(
        roomId: Int,
        userId: Int,
        reason: String,
        expiresAt: String = ""
    ) async throws -> [AloGroupMember] {
        var body: [String: Any] = [
            "reason": reason.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        body["expiresAt"] = expiresAt.isEmpty ? NSNull() : expiresAt
        let response = try await request(
            "POST",
            "/api/group-chats/\(roomId)/bans/\(userId)",
            body: body
        )
        return response.array("members").map(AloGroupMember.init)
    }

    func unbanGroupMember(roomId: Int, userId: Int) async throws {
        _ = try await request(
            "DELETE",
            "/api/group-chats/\(roomId)/bans/\(userId)"
        )
    }

    func removeGroupMember(roomId: Int, userId: Int) async throws -> [AloGroupMember] {
        let response = try await request(
            "DELETE",
            "/api/group-chats/\(roomId)/members/\(userId)"
        )
        return response.array("members").map(AloGroupMember.init)
    }

    func reviewGroupJoinRequest(
        roomId: Int,
        userId: Int,
        approve: Bool
    ) async throws {
        _ = try await request(
            "POST",
            "/api/group-chats/\(roomId)/join-requests/\(userId)/\(approve ? "approve" : "reject")",
            body: [:]
        )
    }

    func createGroupTopic(
        roomId: Int,
        title: String,
        iconEmoji: String
    ) async throws -> AloForumTopic {
        let response = try await request(
            "POST",
            "/api/group-chats/\(roomId)/topics",
            body: [
                "title": title,
                "iconEmoji": iconEmoji
            ]
        )
        return AloForumTopic(response.object("topic"))
    }

    func updateGroupTopic(
        roomId: Int,
        topicId: Int,
        title: String,
        iconEmoji: String,
        isClosed: Bool,
        isHidden: Bool? = nil
    ) async throws -> AloForumTopic {
        var body: [String: Any] = [
            "title": title,
            "iconEmoji": iconEmoji,
            "isClosed": isClosed
        ]
        if let isHidden { body["isHidden"] = isHidden }
        let response = try await request(
            "PATCH",
            "/api/group-chats/\(roomId)/topics/\(topicId)",
            body: body
        )
        return AloForumTopic(response.object("topic"))
    }

    func deleteGroupTopic(roomId: Int, topicId: Int) async throws {
        _ = try await request(
            "DELETE",
            "/api/group-chats/\(roomId)/topics/\(topicId)"
        )
    }

    func mergeGroupTopic(
        roomId: Int,
        sourceTopicId: Int,
        targetTopicId: Int
    ) async throws -> AloForumTopic {
        let response = try await request(
            "POST",
            "/api/group-chats/\(roomId)/topics/\(sourceTopicId)/merge",
            body: ["targetTopicId": targetTopicId]
        )
        return AloForumTopic(response.object("targetTopic"))
    }

    func updateGroupTopicState(
        roomId: Int,
        topicId: Int,
        readThroughMessageId: Int? = nil,
        muted: Bool? = nil,
        draftText: String? = nil,
        updateDraft: Bool = false,
        baseDraftRevision: Int = 0,
        operationId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws -> AloForumTopicState {
        var body = [String: Any]()
        if let readThroughMessageId {
            body["readThroughMessageId"] = max(0, readThroughMessageId)
        }
        if let muted {
            body["muted"] = muted
        }
        if updateDraft {
            body["baseDraftRevision"] = max(0, baseDraftRevision)
            let normalized = String(String(draftText ?? "").prefix(4_000))
            body["encryptedDraft"] = normalized.isEmpty
                ? NSNull()
                : try await prepareEncryptedTopicDraft(normalized)
        }
        body["operationId"] = operationId
        let response = try await request(
            "PUT",
            "/api/group-chats/\(roomId)/topics/\(topicId)/state",
            body: body
        )
        return await decodeForumTopicState(response.object("state"))
    }

    func loadGroupTopicStates(roomId: Int) async throws -> [AloForumTopicState] {
        let response = try await request(
            "GET",
            "/api/group-chats/\(roomId)/topics/state"
        )
        var states = [AloForumTopicState]()
        for raw in response.array("states") {
            states.append(await decodeForumTopicState(raw))
        }
        return states
    }

    func leaveGroupChat(roomId: Int) async throws {
        _ = try await request("POST", "/api/group-chats/\(roomId)/leave")
    }

    func deleteGroupChat(roomId: Int) async throws {
        _ = try await request("DELETE", "/api/group-chats/\(roomId)")
    }

    // MARK: - Sticker and GIF catalog

    /// Returns the server catalog (and performs a catalog search when `query`
    /// is present). It intentionally has no local content fallback.
    func loadStickerPacks(query: String = "", limit: Int = 50) async throws -> [AloStickerPack] {
        let normalizedQuery = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let json = try await request(
            "GET",
            queryPath(
                "/api/stickers/packs",
                items: [
                    ("q", normalizedQuery),
                    ("limit", String(min(100, max(1, limit))))
                ]
            )
        )
        return json.array("packs").map(AloStickerPack.init).filter { !$0.id.isEmpty }
    }

    func loadInstalledStickerPacks() async throws -> [AloStickerPack] {
        let json = try await request("GET", "/api/stickers/installed")
        return json.array("packs").map(AloStickerPack.init).filter { !$0.id.isEmpty }
    }

    func loadStickerPack(id: String) async throws -> AloStickerPack {
        let packID = try validatedStickerPackID(id)
        return AloStickerPack(try await request("GET", "/api/stickers/packs/\(packID)"))
    }

    /// Searches stickers within the user's installed packs. The server indexes
    /// emoji and textual alt labels, so the UI can use one normal search field.
    func searchStickers(query: String, limit: Int = 48) async throws -> [AloStickerItem] {
        let normalizedQuery = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !normalizedQuery.isEmpty else { return [] }
        let json = try await request(
            "GET",
            queryPath(
                "/api/stickers/emoji/search",
                items: [
                    ("emoji", normalizedQuery),
                    ("limit", String(min(100, max(1, limit))))
                ]
            )
        )
        return json.array("stickers").map(AloStickerItem.init).filter(\.isUsable)
    }

    @discardableResult
    func installStickerPack(id: String) async throws -> AloStickerPack {
        let packID = try validatedStickerPackID(id)
        return AloStickerPack(
            try await request("POST", "/api/stickers/packs/\(packID)/install", body: [:])
        )
    }

    @discardableResult
    func removeStickerPack(id: String) async throws -> Bool {
        let packID = try validatedStickerPackID(id)
        let json = try await request("DELETE", "/api/stickers/packs/\(packID)/install")
        return json.bool("removed")
    }

    func loadTrendingGIFs(limit: Int = 24, offset: String = "") async throws -> AloGIFResultPage {
        let json = try await request(
            "GET",
            queryPath(
                "/api/gifs/trending",
                items: [
                    ("limit", String(min(50, max(1, limit)))),
                    ("offset", String(offset.prefix(256)))
                ]
            )
        )
        return AloGIFResultPage(json)
    }

    func searchGIFs(query: String, limit: Int = 24, offset: String = "") async throws -> AloGIFResultPage {
        let normalizedQuery = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard !normalizedQuery.isEmpty else {
            throw AloAPIError(
                status: 400,
                code: "GIF_QUERY_REQUIRED",
                message: "Введите запрос для поиска GIF.",
                payload: [:]
            )
        }
        let json = try await request(
            "GET",
            queryPath(
                "/api/gifs/search",
                items: [
                    ("q", normalizedQuery),
                    ("limit", String(min(50, max(1, limit)))),
                    ("offset", String(offset.prefix(256)))
                ]
            )
        )
        return AloGIFResultPage(json)
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

    func markNotificationsRead(ids: [Int] = [], all: Bool = false) async throws {
        _ = try await request(
            "PUT",
            "/api/notifications/read",
            body: [
                "all": all,
                "notificationIds": ids.filter { $0 > 0 }
            ]
        )
    }

    func deleteNotification(id: Int) async throws {
        _ = try await request("DELETE", "/api/notifications/\(id)")
    }

    func loadSecuritySessions() async throws -> [AloSecuritySession] {
        let json = try await request("GET", "/api/security/sessions")
        return json.array("sessions").map(AloSecuritySession.init)
    }

    func loadSecurityEvents(limit: Int = 12) async throws -> [AloSecurityEvent] {
        let safeLimit = min(50, max(1, limit))
        let json = try await request("GET", "/api/security/events?limit=\(safeLimit)")
        return json.array("events").map(AloSecurityEvent.init)
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

    // MARK: - Account security (server-contract ready)

    func loadPasskeyStatus() async throws -> AloPasskeyStatus {
        AloPasskeyStatus(try await request("GET", "/api/security/passkeys"))
    }

    func requestPasskeyRegistrationOptions() async throws -> AloPasskeyRegistrationOptions {
        let json = try await request(
            "POST",
            "/api/security/passkeys/registration/options",
            body: ["deviceId": AloDeviceIdentity.shared.identifier]
        )
        return AloPasskeyRegistrationOptions(json)
    }

    func verifyPasskeyRegistration(
        credentialID: Data,
        clientDataJSON: Data,
        attestationObject: Data
    ) async throws -> AloPasskeyStatus {
        let json = try await request(
            "POST",
            "/api/security/passkeys/registration/verify",
            body: [
                "credentialId": credentialID.aloBase64URL,
                "clientDataJSON": clientDataJSON.aloBase64URL,
                "attestationObject": attestationObject.aloBase64URL,
                "deviceId": AloDeviceIdentity.shared.identifier
            ]
        )
        return AloPasskeyStatus(json)
    }

    func requestPasskeyAssertionOptions(email: String?) async throws -> AloPasskeyAssertionOptions {
        let json = try await request(
            "POST",
            "/api/auth/passkeys/authentication/options",
            body: compactBody([
                "email": email?.trimmingCharacters(in: .whitespacesAndNewlines),
                "deviceId": AloDeviceIdentity.shared.identifier
            ])
        )
        return AloPasskeyAssertionOptions(json)
    }

    func verifyPasskeyAssertion(
        credentialID: Data,
        clientDataJSON: Data,
        authenticatorData: Data,
        signature: Data,
        userID: Data?
    ) async throws {
        _ = try await request(
            "POST",
            "/api/auth/passkeys/authentication/verify",
            body: compactBody([
                "credentialId": credentialID.aloBase64URL,
                "clientDataJSON": clientDataJSON.aloBase64URL,
                "authenticatorData": authenticatorData.aloBase64URL,
                "signature": signature.aloBase64URL,
                "userId": userID?.aloBase64URL,
                "deviceId": AloDeviceIdentity.shared.identifier
            ])
        )
    }

    func startQRCodeLogin() async throws -> AloQRCodeLoginRequest {
        let json = try await request(
            "POST",
            "/api/auth/qr-login/start",
            body: ["deviceId": AloDeviceIdentity.shared.identifier]
        )
        return AloQRCodeLoginRequest(json)
    }

    func loadQRCodeLoginStatus(requestID: String, secret: String) async throws -> AloQRCodeLoginStatus {
        let requestID = requestID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestID
        let secret = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? secret
        return AloQRCodeLoginStatus(
            try await request("GET", "/api/auth/qr-login/\(requestID)?secret=\(secret)")
        )
    }

    func approveQRCodeLogin(requestID: String, secret: String) async throws {
        let requestID = requestID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestID
        _ = try await request(
            "POST",
            "/api/auth/qr-login/\(requestID)/approve",
            body: ["secret": secret]
        )
    }

    func loadCallHistory(beforeId: Int = 0) async throws -> (items: [AloCallHistoryItem], hasMore: Bool) {
        let json = try await request("GET", beforeId > 0 ? "/api/calls/history?beforeId=\(beforeId)" : "/api/calls/history")
        return (json.array("items").map(AloCallHistoryItem.init), json.bool("hasMore"))
    }

    /// Deletes a one-to-one chat for this account only (the other person keeps their copy).
    func deleteDirectChatForMe(peerId: Int) async throws {
        _ = try await request("POST", "/api/messages/\(peerId)/clear-history", body: [:])
    }

    // MARK: Device link (a signed-in device shows the QR, a new device scans it)

    func startDeviceLink() async throws -> AloQRCodeLoginRequest {
        AloQRCodeLoginRequest(try await request("POST", "/api/auth/device-link/start", body: [:]))
    }

    func claimDeviceLink(requestID: String, secret: String) async throws {
        let requestID = requestID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestID
        _ = try await request("POST", "/api/auth/device-link/\(requestID)/claim", body: ["secret": secret])
    }

    func approveDeviceLink(requestID: String, secret: String) async throws {
        let requestID = requestID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestID
        _ = try await request("POST", "/api/auth/device-link/\(requestID)/approve", body: ["secret": secret])
    }

    func denyDeviceLink(requestID: String, secret: String) async throws {
        let requestID = requestID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestID
        _ = try await request("POST", "/api/auth/device-link/\(requestID)/deny", body: ["secret": secret])
    }

    func completeQRCodeLogin(requestID: String, secret: String) async throws {
        let requestID = requestID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestID
        _ = try await request(
            "POST",
            "/api/auth/qr-login/\(requestID)/complete",
            body: ["secret": secret, "deviceId": AloDeviceIdentity.shared.identifier]
        )
    }

    /// Downloads the export attachment immediately. We intentionally do not
    /// model this as a status-only request: the server returns the sensitive
    /// JSON document in this response.
    func exportAccountData(currentPassword: String) async throws -> AloDataExportFile {
        let password = currentPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else {
            throw AloAPIError(
                status: 400,
                code: "CURRENT_PASSWORD_REQUIRED",
                message: "Подтвердите текущий пароль, чтобы скачать архив данных.",
                payload: [:]
            )
        }
        return try await requestAccountExport(currentPassword: password)
    }

    func deleteAccount(currentPassword: String, confirmation: String) async throws {
        _ = try await request(
            "POST",
            "/api/account/delete",
            body: [
                "currentPassword": currentPassword,
                "confirmation": confirmation
            ]
        )
    }

    func loadPostComments(postId: Int) async throws -> [AloPostComment] {
        let json = try await request("GET", "/api/posts/\(postId)/comments")
        return json.array("comments").map(AloPostComment.init)
    }

    func createComment(
        postId: Int,
        body: String,
        attachments: [AloMessageAttachment] = [],
        replyToCommentId: Int? = nil,
        captchaToken: String? = nil
    ) async throws -> (comment: AloPostComment, post: AloPost?) {
        let json = try await request(
            "POST",
            "/api/posts/\(postId)/comments",
            body: compactBody([
                "body": body,
                "attachments": attachments.map { ["type": $0.type, "url": $0.url, "name": $0.name] },
                "parentId": replyToCommentId,
                "captchaToken": captchaToken
            ])
        )
        return (AloPostComment(json.object("comment")), json.optionalObject("post").map(AloPost.init))
    }

    // MARK: Feed curation, reports, drafts, creator statistics

    func hideFeedPost(postId: Int, reason: AloFeedHideReason) async throws {
        _ = try await request("POST", "/api/feed/posts/\(postId)/hide", body: ["reason": reason.rawValue])
    }

    func unhideFeedPost(postId: Int) async throws -> AloPost? {
        let json = try await request("DELETE", "/api/feed/posts/\(postId)/hide")
        return json.optionalObject("post").map(AloPost.init)
    }

    func report(_ target: AloReportTarget, reason: AloReportReason, details: String) async throws {
        _ = try await request("POST", "/api/reports", body: [
            "targetType": target.type,
            "targetId": target.targetId,
            "reason": reason.title,
            "details": details
        ])
    }

    func loadPostDrafts() async throws -> [AloPostDraft] {
        let json = try await request("GET", "/api/post-drafts")
        return json.array("drafts").map(AloPostDraft.init)
    }

    /// Creates a draft, or replaces the text and media of `draftId`.
    func savePostDraft(draftId: Int?, body: String, media: [[String: Any]]) async throws -> AloPostDraft {
        let payload: [String: Any] = ["body": body, "media": media]
        let json = if let draftId {
            try await request("PATCH", "/api/post-drafts/\(draftId)", body: payload)
        } else {
            try await request("POST", "/api/post-drafts", body: payload)
        }
        return AloPostDraft(json.object("draft"))
    }

    func deletePostDraft(draftId: Int) async throws {
        _ = try await request("DELETE", "/api/post-drafts/\(draftId)")
    }

    func loadCreatorStats(days: Int) async throws -> AloCreatorStats {
        let json = try await request("GET", "/api/creator/stats?days=\(days)")
        return AloCreatorStats(json.object("stats"))
    }

    func mentionSuggestions(query: String) async throws -> [AloEntitySummary] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let json = try await request("GET", "/api/mentions/suggest?q=\(encoded)")
        return json.array("people").map(AloEntitySummary.init)
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
        replyToMessageId: Int = 0,
        topicId: Int = 0,
        selfDestructSeconds: Int = 0,
        silent: Bool = false,
        scheduledAt: String = "",
        sendWhenOnline: Bool = false,
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
            replyToMessageId: replyToMessageId,
            topicId: topicId,
            selfDestructSeconds: selfDestructSeconds,
            silent: silent,
            scheduledAt: scheduledAt,
            sendWhenOnline: sendWhenOnline,
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
        replyToMessageId: Int = 0,
        topicId: Int = 0,
        selfDestructSeconds: Int = 0,
        silent: Bool = false,
        scheduledAt: String = "",
        sendWhenOnline: Bool = false,
        scheduledPoll: AloPollDefinition? = nil,
        captchaToken: String? = nil,
        clientMessageId: String
    ) async throws -> AloMessageSendAcknowledgement {
        var payload: [String: Any?] = [
            "encrypted": encryptedPayload,
            "attachments": attachments
                .filter { !$0.isVirtualCard }
                .map(e2eeServerAttachmentPayload),
            "replyToMessageId": max(0, replyToMessageId),
            "topicId": max(0, topicId),
            "selfDestructSeconds": max(0, selfDestructSeconds),
            "silent": silent,
            "scheduledAt": scheduledAt.isEmpty ? nil : scheduledAt,
            "sendWhenOnline": sendWhenOnline,
            "clientMessageId": clientMessageId,
            "captchaToken": captchaToken
        ]
        if let forwardFrom {
            payload["forwardFrom"] = [
                "userId": forwardFrom.userId,
                "messageId": forwardFrom.messageId
            ]
        }
        if !scheduledAt.isEmpty, let scheduledPoll {
            payload["scheduledPoll"] = pollRegistrationPayload(scheduledPoll)
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
        let message = response.object("message")
        guard message.int("id") > 0 || (response.bool("scheduled") && response.object("scheduledMessage").int("id") > 0) else {
            throw AloAPIError(status: 502, code: "MESSAGE_ACK_INVALID",
                message: "Сервер не подтвердил отправку. Сообщение сохранено, можно повторить попытку.", payload: [:])
        }
        AloE2EECrypto.shared.markRatchetSessionsConfirmed(encryptedPayload: encryptedPayload)
        return AloMessageSendAcknowledgement(
            messageId: message.int("id"),
            createdAt: message.string("createdAt"),
            scheduled: response.bool("scheduled"),
            scheduledMessageId: response.object("scheduledMessage").int("id"),
            scheduledAt: message.string("scheduledAt")
                .ifBlank(response.object("scheduledMessage").string("scheduledAt")),
            sendWhenOnline: message.bool("sendWhenOnline")
                || response.object("scheduledMessage").bool("sendWhenOnline")
                || response.bool("sendWhenOnline")
        )
    }

    private func pollRegistrationPayload(_ definition: AloPollDefinition) -> [String: Any] {
        var payload: [String: Any] = [
            "pollId": definition.id,
            "optionIds": definition.options.map(\.id),
            "allowsMultipleAnswers": definition.allowsMultipleAnswers,
            "isQuiz": definition.isQuiz,
            "isAnonymous": definition.isAnonymous,
            "allowsRevoting": definition.allowsRevoting,
            "quizAnswerCommitment": definition.quizAnswerCommitment
        ]
        if !definition.closesAt.isEmpty {
            payload["closesAt"] = definition.closesAt
        }
        return payload
    }

    func updateScheduledMessage(
        scheduledMessageId: Int,
        scheduledAt: String,
        silent: Bool? = nil,
        operationId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws {
        var body: [String: Any] = [
            "scheduledAt": scheduledAt,
            "operationId": operationId
        ]
        if let silent {
            body["silent"] = silent
        }
        _ = try await request(
            "PATCH",
            "/api/messages/scheduled/\(scheduledMessageId)",
            body: body
        )
    }

    func cancelScheduledMessage(
        scheduledMessageId: Int,
        operationId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws {
        _ = try await request(
            "DELETE",
            "/api/messages/scheduled/\(scheduledMessageId)",
            body: ["operationId": operationId]
        )
    }

    /// Future API contract.  The server is expected to persist this schedule
    /// and deliver the already E2EE-encrypted payload even when the sender's
    /// device is offline.
    func createRecurringMessageSchedule(
        peerId: Int,
        roomId: Int,
        kind: String,
        encryptedPayload: [String: Any],
        topicId: Int,
        startsAt: String,
        rule: AloRecurringScheduleRule,
        occurrences: Int,
        silent: Bool
    ) async throws -> AloRecurringMessageSchedule {
        let body: [String: Any] = [
            "peerId": max(0, peerId),
            "roomId": max(0, roomId),
            "kind": kind,
            "encrypted": encryptedPayload,
            "topicId": max(0, topicId),
            "startsAt": startsAt,
            "rule": rule.rawValue,
            "occurrences": max(1, min(52, occurrences)),
            "silent": silent
        ]
        let json = try await request("POST", "/api/messages/recurring", body: body)
        return AloRecurringMessageSchedule(json)
    }

    /// Future API contract. The user explicitly chooses this action from the
    /// message menu before plaintext is sent for translation.
    func translateMessage(
        messageId: Int,
        text: String,
        targetLanguage: String,
        sourceLanguage: String = "auto"
    ) async throws -> AloMessageTranslation {
        let json = try await request(
            "POST",
            "/api/messages/\(messageId)/translate",
            body: [
                "text": text,
                "sourceLanguage": sourceLanguage,
                "targetLanguage": targetLanguage,
                "consent": true
            ]
        )
        return AloMessageTranslation(json)
    }

    /// Future API contract for a consented transcription. Voice media stays
    /// E2EE until a compatible service is available to process this request.
    func transcribeVoiceMessage(
        messageId: Int,
        attachmentId: String,
        language: String
    ) async throws -> AloVoiceTranscription {
        let json = try await request(
            "POST",
            "/api/messages/\(messageId)/transcribe",
            body: [
                "attachmentId": attachmentId,
                "language": language,
                "consent": true
            ]
        )
        return AloVoiceTranscription(json)
    }

    /// Future API contract for a short-lived, E2EE live-location session.
    /// Unlike a static pin, this route must remain available while updates are
    /// flowing, so the iOS client never pretends a one-time point is live.
    func startLiveLocation(
        peerId: Int,
        roomId: Int,
        kind: String,
        topicId: Int,
        encryptedPayload: [String: Any],
        expiresAt: String
    ) async throws -> AloLiveLocationSession {
        let json = try await request(
            "POST",
            "/api/messages/live-location",
            body: [
                "peerId": max(0, peerId),
                "roomId": max(0, roomId),
                "kind": kind,
                "topicId": max(0, topicId),
                "encrypted": encryptedPayload,
                "expiresAt": expiresAt
            ]
        )
        return AloLiveLocationSession(json)
    }

    func updateLiveLocation(
        sessionId: String,
        encryptedPayload: [String: Any]
    ) async throws {
        _ = try await request(
            "PATCH",
            "/api/messages/live-location/\(sessionId)",
            body: ["encrypted": encryptedPayload]
        )
    }

    func stopLiveLocation(sessionId: String) async throws {
        _ = try await request("DELETE", "/api/messages/live-location/\(sessionId)")
    }

    func markMessageMediaOpened(
        conversation: AloConversationDetail,
        messageId: Int
    ) async throws -> AloMessageExpiryState {
        let path = conversation.kind == "group" && conversation.roomId > 0
            ? "/api/group-chats/\(conversation.roomId)/messages/\(messageId)/open"
            : "/api/messages/\(messageId)/open"
        let json = try await request("POST", path, body: [:])
        return AloMessageExpiryState(json.object("expiry"))
    }

    func prepareMessageMediaOpened(
        conversation: AloConversationDetail,
        message: AloChatMessage
    ) async throws -> (message: AloChatMessage, expiry: AloMessageExpiryState) {
        let expiry = try await markMessageMediaOpened(
            conversation: conversation,
            messageId: message.id
        )
        let sourceAttachments: [AloMessageAttachment]
        if !message.attachments.isEmpty {
            sourceAttachments = message.attachments
        } else if !message.attachmentUrl.isEmpty {
            sourceAttachments = [
                AloMessageAttachment([
                    "url": message.attachmentUrl,
                    "type": message.attachmentType,
                    "name": message.attachmentName
                ])
            ]
        } else {
            sourceAttachments = []
        }
        let rawAttachments = sourceAttachments.map(messageAttachmentJSON)
        let resolved = await resolveDecryptedMediaAttachments(
            rawAttachments,
            expiresAt: expiry.expiresAt
        )
            .map(AloMessageAttachment.init)
        return (
            message.replacingMedia(
                attachments: resolved,
                startedAt: expiry.selfDestructStartedAt,
                expiresAt: expiry.expiresAt
            ),
            expiry
        )
    }

    func toggleMessageReaction(
        conversation: AloConversationDetail,
        messageId: Int,
        desiredEmoji: String,
        operationId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws -> [AloMessageReaction] {
        let path = conversation.kind == "group" && conversation.roomId > 0
            ? "/api/group-chats/\(conversation.roomId)/messages/\(messageId)/reactions/toggle"
            : "/api/messages/\(messageId)/reactions/toggle"
        let json = try await request(
            "POST",
            path,
            body: [
                "desiredEmoji": desiredEmoji,
                "operationId": operationId
            ]
        )
        return json.array("reactions").map(AloMessageReaction.init)
    }

    func sendPreparedMessageEdit(
        conversation: AloConversationDetail,
        messageId: Int,
        body: String,
        encryptedPayload: [String: Any],
        operationId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws -> (body: String, editedAt: String) {
        let path = conversation.kind == "group" && conversation.roomId > 0
            ? "/api/group-chats/\(conversation.roomId)/messages/\(messageId)/edit"
            : "/api/messages/\(messageId)/edit"
        let json = try await request(
            "POST",
            path,
            body: [
                "encrypted": encryptedPayload,
                "operationId": operationId
            ]
        )
        AloE2EECrypto.shared.markRatchetSessionsConfirmed(encryptedPayload: encryptedPayload)
        let message = json.object("message")
        return (
            message.string("body").ifBlank(body),
            message.string("editedAt")
        )
    }

    func deleteMessages(
        messageIds: [Int],
        conversation: AloConversationDetail,
        mode: String = "me",
        operationId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws {
        let ids = Array(Set(messageIds)).filter { $0 > 0 }
        guard !ids.isEmpty else { return }
        if conversation.kind == "group", conversation.roomId > 0 {
            _ = try await request(
                "POST",
                "/api/group-chats/\(conversation.roomId)/messages/delete-batch",
                body: [
                    "messageIds": ids,
                    "mode": mode,
                    "operationId": operationId
                ]
            )
        } else {
            _ = try await request(
                "POST",
                "/api/messages/delete-batch",
                body: [
                    "messageIds": ids,
                    "mode": mode,
                    "operationId": operationId
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
    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 15) async throws -> [String: Any] {
        let candidates = candidateURLs(for: path)
        guard !candidates.isEmpty else {
            throw AloAPIError(status: 0, code: "BAD_URL", message: "Некорректный адрес API.", payload: [:])
        }

        var lastConnectionError: Error?
        for candidate in candidates {
            do {
                var request = URLRequest(url: candidate.url)
                request.httpMethod = method
                request.timeoutInterval = timeout
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("AloiOS", forHTTPHeaderField: "X-Requested-With")
                request.setValue(AloDeviceIdentity.shared.identifier, forHTTPHeaderField: "X-Alo-Device-ID")
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
                try Task.checkCancellation()
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

    private func requestAccountExport(currentPassword: String) async throws -> AloDataExportFile {
        let candidates = candidateURLs(for: "/api/account/export")
        guard !candidates.isEmpty else {
            throw AloAPIError(status: 0, code: "BAD_URL", message: "Некорректный адрес API.", payload: [:])
        }

        var lastConnectionError: Error?
        for candidate in candidates {
            do {
                var request = URLRequest(url: candidate.url)
                request.httpMethod = "POST"
                request.timeoutInterval = 60
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.setValue("AloiOS", forHTTPHeaderField: "X-Requested-With")
                request.setValue(AloDeviceIdentity.shared.identifier, forHTTPHeaderField: "X-Alo-Device-ID")
                request.httpBody = try JSONSerialization.data(
                    withJSONObject: ["currentPassword": currentPassword]
                )

                let (temporaryURL, response) = try await session.download(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AloAPIError(
                        status: 0,
                        code: "EXPORT_RESPONSE_INVALID",
                        message: "Сервер вернул некорректный ответ экспорта.",
                        payload: [:]
                    )
                }
                guard (200..<300).contains(http.statusCode) else {
                    let data = try Data(contentsOf: temporaryURL)
                    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                    throw AloAPIError(
                        status: http.statusCode,
                        code: json.string("code"),
                        message: json.string("error").ifBlank(json.string("message").ifBlank("Не удалось экспортировать данные.")),
                        payload: json
                    )
                }

                let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
                let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard byteCount > 0 else {
                    throw AloAPIError(
                        status: http.statusCode,
                        code: "EXPORT_EMPTY",
                        message: "Сервер вернул пустой архив данных.",
                        payload: [:]
                    )
                }
                guard byteCount <= 512 * 1_024 * 1_024 else {
                    throw AloAPIError(
                        status: http.statusCode,
                        code: "EXPORT_TOO_LARGE",
                        message: "Архив слишком большой для сохранения на этом устройстве.",
                        payload: [:]
                    )
                }

                let contentDisposition = http.value(forHTTPHeaderField: "Content-Disposition") ?? ""
                let fileName = sanitizedAccountExportFileName(
                    fileNameFromContentDisposition(contentDisposition)
                        .ifBlank("alo-data-export.json")
                )
                let destination = try accountExportURL(fileName: fileName)
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.moveItem(at: temporaryURL, to: destination)
                } catch {
                    try FileManager.default.copyItem(at: temporaryURL, to: destination)
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
                try markProtectedAndUnbacked(destination, isDirectory: false)
                if let baseURL = candidate.baseURL {
                    activeBaseURL = baseURL
                }
                let rawMIMEType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                let firstMIMEType = rawMIMEType.components(separatedBy: ";").first ?? ""
                let mimeType = firstMIMEType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "application/json"
                    : firstMIMEType
                return AloDataExportFile(
                    fileURL: destination,
                    fileName: fileName,
                    mimeType: mimeType
                )
            } catch let error as AloAPIError {
                throw error
            } catch {
                lastConnectionError = error
                if !canRetryOnAnotherBaseURL(method: "POST", error: error) {
                    break
                }
            }
        }

        throw AloAPIError(
            status: 0,
            code: "CONNECTION_FAILED",
            message: connectionErrorMessage(lastConnectionError),
            payload: [:]
        )
    }

    private func accountExportURL(fileName: String) throws -> URL {
        let root = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("AloAccountExports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try markProtectedAndUnbacked(root, isDirectory: true)
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? [] {
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if (date ?? .distantPast) < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return root.appendingPathComponent("\(UUID().uuidString.lowercased())-\(fileName)")
    }

    private func fileNameFromContentDisposition(_ value: String) -> String {
        let parts = value.split(separator: ";", omittingEmptySubsequences: true).map(String.init)
        if let encoded = parts.first(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("filename*=") }) {
            let raw = encoded.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
            let encodedName = raw.split(separator: "'", maxSplits: 2).last.map(String.init) ?? raw
            return encodedName.removingPercentEncoding ?? encodedName
        }
        if let plain = parts.first(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("filename=") }) {
            let raw = plain.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\\\"")).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func sanitizedAccountExportFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let name = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let normalized = String(name).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        let base = normalized.isEmpty ? "alo-data-export" : String(normalized.prefix(120))
        return base.lowercased().hasSuffix(".json") ? base : "\(base).json"
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
        if !attachment.metadata.isEmpty {
            payload["metadata"] = attachment.metadata
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
        let markup = AloMessageMarkup.parse(body)
        var content: [String: Any] = [
            "v": 3,
            "body": markup.body,
            "entities": markup.entities.map(\.payload),
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
        let markup = AloMessageMarkup.parse(body)
        var content: [String: Any] = [
            "v": 3,
            "body": markup.body,
            "entities": markup.entities.map(\.payload),
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

    private func prepareEncryptedTopicDraft(_ body: String) async throws -> [String: Any] {
        guard currentUserId > 0 else {
            throw AloAPIError(
                status: -1,
                code: "E2EE_UNAVAILABLE",
                message: "Шифрование черновика недоступно до авторизации.",
                payload: [:]
            )
        }
        await registerE2EEDeviceKeyIfPossible(currentUserId: currentUserId)
        if let latestE2EERegistrationError { throw latestE2EERegistrationError }
        let recipientKeys = try await loadE2EERecipientKeys(
            peerId: currentUserId,
            roomId: 0,
            kind: "direct"
        ).filter {
            $0.signingPublicKeyJwk != nil && !$0.identityFingerprint.isEmpty
        }
        guard !recipientKeys.isEmpty else {
            throw AloAPIError(
                status: -1,
                code: "E2EE_KEYS_MISSING",
                message: "Нет ключей собственных устройств для синхронизации черновика.",
                payload: [:]
            )
        }
        try AloE2EETrustStore.shared.validate(
            recipientKeys,
            currentUserId: currentUserId
        )
        let content: [String: Any] = [
            "v": 1,
            "body": body,
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: content)
        let contextId = "draft_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let recipients = try recipientKeys.map { key in
            try AloE2EECrypto.shared.encrypt(
                plaintext,
                for: key,
                senderUserId: currentUserId,
                purpose: "draft",
                contextId: contextId,
                useV2: true,
                allowRatchetBootstrap: false
            )
        }
        return [
            "scheme": AloE2EECrypto.messageSchemeV2,
            "recipients": recipients
        ]
    }

    func decodeForumTopicState(_ raw: [String: Any]) async -> AloForumTopicState {
        var decoded = raw
        if let encryptedDraft = raw.optionalObject("encryptedDraft") {
            do {
                try AloE2EETrustStore.shared.validateEmbeddedSender(
                    encryptedDraft,
                    currentUserId: currentUserId
                )
                let plaintext = try AloE2EECrypto.shared.decrypt(
                    encryptedPayload: encryptedDraft
                )
                if let content = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] {
                    decoded["draftText"] = content.string("body")
                }
            } catch {
                decoded["draftText"] = ""
            }
        }
        return AloForumTopicState(decoded)
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
        let markup = AloMessageMarkup.parse(body)
        var content: [String: Any?] = [
            "v": useV2 ? 2 : 1,
            "body": markup.body,
            "entities": markup.entities.map(\.payload),
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
        if let preview = AloPollCodec.previewText(for: body) { return preview }
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

    private func decryptForumTopicStates(inConversation raw: [String: Any]) async -> [String: Any] {
        var next = raw
        var room = next.object("room")
        guard !room.isEmpty else { return next }
        var decodedStates = [[String: Any]]()
        for state in room.array("topicStates") {
            let decoded = await decodeForumTopicState(state)
            decodedStates.append([
                "topicId": decoded.topicId,
                "cursor": decoded.cursor,
                "lastReadMessageId": decoded.lastReadMessageId,
                "unreadCount": decoded.unreadCount,
                "muted": decoded.muted,
                "draftRevision": decoded.draftRevision,
                "stateVersion": decoded.stateVersion,
                "draftUpdatedAt": decoded.draftUpdatedAt,
                "updatedAt": decoded.updatedAt,
                "draftText": decoded.draftText
            ])
        }
        room["topicStates"] = decodedStates
        next["room"] = room
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
        if let entities = object["entities"] as? [[String: Any]] {
            next["entities"] = entities
        }
        if let attachments = object["attachments"] as? [[String: Any]] {
            let shouldDeferDisappearingMedia =
                raw.int("selfDestructSeconds") > 0 &&
                raw.string("selfDestructStartedAt").isEmpty &&
                raw.string("expiresAt").isEmpty
            let resolvedAttachments = shouldDeferDisappearingMedia
                ? attachments
                : await resolveDecryptedMediaAttachments(
                    attachments,
                    expiresAt: raw.string("expiresAt")
                )
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

    private func messageAttachmentJSON(_ attachment: AloMessageAttachment) -> [String: Any] {
        var json: [String: Any] = [
            "url": attachment.url,
            "type": attachment.type,
            "name": attachment.name,
            "posterUrl": attachment.posterUrl
        ]
        if !attachment.waveform.isEmpty {
            json["waveform"] = attachment.waveform.map(Double.init)
        }
        if !attachment.mediaEncryption.isEmpty {
            json["mediaEncryption"] = attachment.mediaEncryption
        }
        if !attachment.metadata.isEmpty {
            json["metadata"] = attachment.metadata
        }
        return json
    }

    private func resolveDecryptedMediaAttachments(
        _ attachments: [[String: Any]],
        expiresAt: String = ""
    ) async -> [[String: Any]] {
        var resolved = [[String: Any]]()
        for attachment in attachments {
            resolved.append(
                await resolveDecryptedMediaAttachment(
                    attachment,
                    expiresAt: expiresAt
                )
            )
        }
        return resolved
    }

    private func resolveDecryptedMediaAttachment(
        _ attachment: [String: Any],
        expiresAt: String = ""
    ) async -> [String: Any] {
        let encryption = attachment.object("mediaEncryption").isEmpty ? attachment.object("e2ee") : attachment.object("mediaEncryption")
        let algorithm = encryption.string("algorithm")
        let chunkedMetadata = AloChunkedMediaCrypto.Metadata(encryption)
        guard algorithm == AloE2EECrypto.mediaScheme || chunkedMetadata != nil else { return attachment }
        let remoteUrl = attachment.string("url")
        guard !remoteUrl.isEmpty else { return attachment }

        cleanupDecodedMediaCacheIfNeeded()
        let encryptedCacheURL = encryptedMediaCacheURL(
            remoteUrl: remoteUrl,
            encryption: encryption
        )
        do {
            if !FileManager.default.fileExists(atPath: encryptedCacheURL.path) {
                let expectedSize = chunkedMetadata.map {
                    AloChunkedMediaCrypto.expectedCiphertextSize(
                        plaintextSize: $0.plaintextSize,
                        chunkSize: $0.chunkSize
                    )
                }
                let temporary = encryptedCacheURL.deletingLastPathComponent().appendingPathComponent(
                    ".\(encryptedCacheURL.lastPathComponent).download-\(UUID().uuidString).part"
                )
                defer { try? FileManager.default.removeItem(at: temporary) }
                try await downloadRawFile(
                    remoteUrl,
                    to: temporary,
                    expectedSize: expectedSize
                )
                try moveProtectedCacheFile(from: temporary, to: encryptedCacheURL)
            }
            let secureURL = try AloSecureMediaStore.shared.register(
                encryptedURL: encryptedCacheURL,
                encryption: encryption,
                type: attachment.string("type"),
                name: attachment.string("name"),
                expiresAt: expiresAt
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
        let digestInput = Data(
            "\(remoteUrl)|\(encryption.string("algorithm"))|\(encryption.string("key"))|\(encryption.string("iv"))|\(encryption.string("noncePrefix"))|\(encryption.string("chunkSize"))|\(encryption.string("plaintextSize"))".utf8
        )
        return SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
    }

    private func e2eeMediaCacheRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("AloE2EEMedia", isDirectory: true)
    }

    private func moveProtectedCacheFile(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markProtectedAndUnbacked(destination.deletingLastPathComponent(), isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
            try? FileManager.default.removeItem(at: source)
        }
        try markProtectedAndUnbacked(destination, isDirectory: false)
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

    private func downloadRawFile(
        _ path: String,
        to destination: URL,
        expectedSize: Int64?
    ) async throws {
        if path.hasPrefix("file://"), let url = URL(string: path) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? -1
            guard expectedSize == nil || size == expectedSize else {
                throw AloAPIError(status: 0, code: "DOWNLOAD_SIZE_INVALID", message: "Размер вложения не совпадает с зашифрованными метаданными.", payload: [:])
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            return
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
                request.timeoutInterval = 60
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                let (temporaryURL, response) = try await session.download(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    throw AloAPIError(status: status, code: "DOWNLOAD_FAILED", message: "Не удалось загрузить вложение.", payload: [:])
                }
                let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? -1
                guard expectedSize == nil || size == expectedSize else {
                    throw AloAPIError(status: status, code: "DOWNLOAD_SIZE_INVALID", message: "Размер вложения не совпадает с зашифрованными метаданными.", payload: [:])
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.moveItem(at: temporaryURL, to: destination)
                } catch {
                    try FileManager.default.copyItem(at: temporaryURL, to: destination)
                }
                if let baseURL = candidate.baseURL {
                    activeBaseURL = baseURL
                }
                return
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

    private func queryPath(_ path: String, items: [(String, String)]) -> String {
        let presentItems = items.filter { !$0.1.isEmpty }
        guard !presentItems.isEmpty else { return path }
        var components = URLComponents()
        components.queryItems = presentItems.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return path }
        return "\(path)?\(query)"
    }

    private func validatedStickerPackID(_ id: String) throws -> String {
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw AloAPIError(
                status: 400,
                code: "INVALID_STICKER_PACK",
                message: "Некорректный набор стикеров.",
                payload: [:]
            )
        }
        return value
    }
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
              purpose == "message" || purpose == "call" || purpose == "draft",
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
              ["message", "call", "draft"].contains(envelope.string("purpose")),
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
    var aloBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

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
