import Foundation

// Secret chats, the way Telegram does them (docs/cloud-and-secret-chats.md, stage 2). A secret chat belongs to two
// devices: this one and the device at the other end. Its messages are libsignal envelopes for that one device, its files
// are sealed before they are uploaded, and all of it is deleted from the server with the chat. The id of a secret chat
// lives in its own space: it is never a `peerId` or a group id.

struct AloSecretMessage: Identifiable, Equatable {
    let id: Int
    let secretChatId: Int
    let senderUserId: Int
    let senderDeviceId: String
    let body: String
    let entities: [AloMessageTextEntity]
    let attachments: [AloMessageAttachment]
    let clientMessageId: String
    let selfDestructSeconds: Int
    let createdAt: String
    let readAt: String
    let expiresAt: String
    /// The envelope's id: the key of this device's own copy of the text, deleted with the message.
    let contextId: String
    /// This device cannot open the envelope: `body` says so.
    let unreadable: Bool

    func replacingRead(readAt: String, expiresAt: String) -> AloSecretMessage {
        AloSecretMessage(id: id, secretChatId: secretChatId, senderUserId: senderUserId, senderDeviceId: senderDeviceId,
                         body: body, entities: entities, attachments: attachments, clientMessageId: clientMessageId,
                         selfDestructSeconds: selfDestructSeconds, createdAt: createdAt, readAt: readAt,
                         expiresAt: expiresAt, contextId: contextId, unreadable: unreadable)
    }
}

struct AloSecretChat: Identifiable, Equatable {
    let id: Int
    /// `pending` (nobody accepted yet) or `active`.
    let status: String
    /// `started` by this device, `accepted` by this device, `incoming` (a request nobody accepted yet).
    let role: String
    let peerUserId: Int
    let peerName: String
    let peerUsername: String
    let peerAvatarUrl: String
    let peerVerified: Bool
    let localDeviceId: String
    let remoteDeviceId: String
    var ttlSeconds: Int
    let createdAt: String
    let acceptedAt: String
    var unreadCount: Int
    var lastMessage: AloSecretMessage?

    var isIncomingRequest: Bool { status == "pending" && role == "incoming" }
    var isWaiting: Bool { status == "pending" && role == "started" }
    var isActive: Bool { status == "active" }

    /// What orders the chat in the list: its newest message, otherwise when it began.
    var lastActivityAt: String {
        if let last = lastMessage, !last.createdAt.isEmpty { return last.createdAt }
        return acceptedAt.isEmpty ? createdAt : acceptedAt
    }
}

/// A secret chat with its messages as the server holds them now.
struct AloSecretConversation {
    let chat: AloSecretChat?
    let messages: [AloSecretMessage]
    let hasMore: Bool
}

enum AloSecretTime {
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Milliseconds since 1970 of an ISO timestamp; 0 when it is empty or unreadable.
    static func millis(_ iso: String) -> Double {
        guard !iso.isEmpty else { return 0 }
        guard let date = fractional.date(from: iso) ?? plain.date(from: iso) else { return 0 }
        return date.timeIntervalSince1970 * 1000
    }

    static func iso(millis: Double) -> String {
        fractional.string(from: Date(timeIntervalSince1970: millis / 1000))
    }
}

enum AloSecretChatCodec {
    static let unreadableBeforeDevice = "Отправлено до подключения этого устройства"
    static let unreadableDamaged = "Не удалось расшифровать сообщение"

    /// What the timer menu offers (0 is off); the server takes 0, 1, 2, 3, 5, 10, 15, 30, 60, 300, 3600, 86400, 604800.
    static let timerChoices: [(seconds: Int, title: String)] = [
        (0, "Выключен"), (5, "5 секунд"), (30, "30 секунд"), (60, "1 минута"),
        (3600, "1 час"), (86400, "1 день"), (604800, "1 неделя")
    ]

    static func timerLabel(_ seconds: Int) -> String {
        timerChoices.first { $0.seconds == seconds }?.title ?? "\(seconds) с"
    }

    /// «5 с», «3 мин», «2 ч», «4 дн.»: how long a message that has been read still lives.
    static func countdownLabel(millisLeft: Double) -> String {
        let seconds = Int((max(0, millisLeft) + 999) / 1000)
        if seconds >= 86_400 { return "\((seconds + 86_399) / 86_400) дн." }
        if seconds >= 3_600 { return "\((seconds + 3_599) / 3_600) ч" }
        if seconds >= 60 { return "\((seconds + 59) / 60) мин" }
        return "\(seconds) с"
    }

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    // MARK: Requests

    static func listPath(deviceId: String) -> String { "/api/secret-chats?deviceId=\(encoded(deviceId))" }

    static func messagesPath(id: Int, deviceId: String, limit: Int = 100, beforeId: Int = 0) -> String {
        var path = "/api/secret-chats/\(id)/messages?deviceId=\(encoded(deviceId))&limit=\(min(200, max(1, limit)))"
        if beforeId > 0 { path += "&beforeId=\(beforeId)" }
        return path
    }

    static func deletePath(id: Int, deviceId: String) -> String { "/api/secret-chats/\(id)?deviceId=\(encoded(deviceId))" }
    static func acceptPath(id: Int) -> String { "/api/secret-chats/\(id)/accept" }
    static func readPath(id: Int) -> String { "/api/secret-chats/\(id)/read" }
    static func timerPath(id: Int) -> String { "/api/secret-chats/\(id)/timer" }
    static func sendPath(id: Int) -> String { "/api/secret-chats/\(id)/messages" }

    static func startBody(peerUserId: Int, deviceId: String) -> [String: Any] {
        ["peerUserId": peerUserId, "deviceId": deviceId]
    }

    static func acceptBody(deviceId: String) -> [String: Any] { ["deviceId": deviceId] }

    static func readBody(deviceId: String, upToMessageId: Int) -> [String: Any] {
        ["deviceId": deviceId, "upToMessageId": upToMessageId]
    }

    static func timerBody(deviceId: String, seconds: Int) -> [String: Any] {
        ["deviceId": deviceId, "seconds": seconds]
    }

    /// Files of a secret chat are opaque: the server sees `e2ee` and a name, never a type or a size.
    static func messageBody(
        deviceId: String,
        encrypted: [String: Any],
        attachments: [AloMessageAttachment],
        clientMessageId: String,
        selfDestructSeconds: Int
    ) -> [String: Any] {
        var body: [String: Any] = [
            "deviceId": deviceId,
            "encrypted": encrypted,
            "clientMessageId": clientMessageId,
            "selfDestructSeconds": max(0, selfDestructSeconds)
        ]
        if !attachments.isEmpty {
            body["attachments"] = attachments.map { attachment in
                ["type": "e2ee", "url": attachment.url, "name": String(attachment.name.ifBlank("encrypted.bin").prefix(120))]
            }
        }
        return body
    }

    /// What the envelope says about one uploaded file, the way a cloud chat says it: a recording is `voice` (the
    /// recorder's own type is `audio`) with its bars and length, a circle is `circle` with its length and its square
    /// size (`AloCircleVideoExport` renders 400×400), so every app draws a voice bubble and a round video, not a file.
    static func sealedAttachment(_ uploaded: AloMessageAttachment) -> AloMessageAttachment {
        let type = AloCloudMessage.wireType(uploaded.type.isEmpty ? "file" : uploaded.type)
        var metadata = uploaded.metadata
        if type == "circle", AloMediaDimensions(metadata) == nil {
            metadata["width"] = "400"
            metadata["height"] = "400"
        }
        return AloMessageAttachment(
            type: type, url: uploaded.url, name: uploaded.name, posterUrl: uploaded.posterUrl,
            waveform: type == "voice" ? uploaded.waveform : [], mediaEncryption: uploaded.mediaEncryption, metadata: metadata)
    }

    /// The server takes a secret message only as ONE envelope for the ONE device at the other end: no copy for the
    /// sender's other devices, none for the other devices of the person.
    static func isSingleRecipientEnvelope(
        _ envelope: [String: Any],
        peerUserId: Int,
        peerDeviceId: String,
        senderDeviceId: String
    ) -> Bool {
        guard let recipients = envelope["recipients"] as? [[String: Any]], recipients.count == 1,
              let recipient = recipients.first else { return false }
        let mode = envelope.string("mode")
        return envelope.string("purpose") == "message"
            && (mode.isEmpty || mode == "direct")
            && envelope.string("senderDeviceId") == senderDeviceId
            && recipient.int("userId") == peerUserId
            && recipient.string("deviceId") == peerDeviceId
    }

    // MARK: Reading

    /// `opened` is the message after its envelope was opened (then `body`, `entities`, `attachments` are plain);
    /// `original` is the JSON the server sent.
    static func parseMessage(_ opened: [String: Any], original: [String: Any]? = nil) -> AloSecretMessage {
        let server = original ?? opened
        let body = (opened["body"] as? String) ?? ""
        let entities = AloMessageMarkup.normalized(
            opened.array("entities").compactMap(AloMessageTextEntity.init),
            utf16Length: body.utf16.count
        )
        // The opaque files the server holds are not what is shown: the opened envelope lists the real ones.
        let attachments = opened.array("attachments")
            .filter { $0.string("type").lowercased() != "e2ee" }
            .map(AloMessageAttachment.init)
        return AloSecretMessage(
            id: server.int("id"),
            secretChatId: server.int("secretChatId"),
            senderUserId: server.int("senderUserId"),
            senderDeviceId: server.string("senderDeviceId"),
            body: body,
            entities: entities,
            attachments: attachments,
            clientMessageId: server.string("clientMessageId"),
            selfDestructSeconds: max(0, server.int("selfDestructSeconds")),
            createdAt: server.string("createdAt"),
            readAt: server.string("readAt"),
            expiresAt: server.string("expiresAt"),
            contextId: server.object("encryptedPayload").string("contextId"),
            unreadable: body == unreadableBeforeDevice || body == unreadableDamaged
        )
    }

    static func parseChat(_ json: [String: Any], lastMessage: AloSecretMessage? = nil) -> AloSecretChat? {
        let id = json.int("id")
        guard id > 0 else { return nil }
        let peer = json.object("peerUser")
        return AloSecretChat(
            id: id,
            status: json.string("status").ifBlank("pending"),
            role: json.string("role").ifBlank("incoming"),
            peerUserId: json.int("peerUserId").ifZero(peer.int("id")),
            peerName: peer.string("name").ifBlank("Собеседник"),
            peerUsername: peer.string("username"),
            peerAvatarUrl: peer.string("avatarEmoji").ifBlank(peer.string("avatarUrl")),
            peerVerified: peer.bool("verified") || peer.bool("isVerified"),
            localDeviceId: json.string("localDeviceId"),
            remoteDeviceId: json.string("remoteDeviceId"),
            ttlSeconds: max(0, json.int("ttlSeconds")),
            createdAt: json.string("createdAt"),
            acceptedAt: json.string("acceptedAt"),
            unreadCount: max(0, json.int("unreadCount")),
            lastMessage: lastMessage
        )
    }
}

/// The chats of this device, merged into the chat list and shown there.
enum AloSecretChatList {
    /// The line under the name in the chat list.
    static func preview(_ chat: AloSecretChat, now: Double = Date().timeIntervalSince1970 * 1000) -> String {
        if chat.isIncomingRequest { return "Запрос секретного чата" }
        if chat.isWaiting { return "Ждём, пока \(chat.peerName) зайдёт в сеть…" }
        let last = chat.lastMessage.flatMap { AloSecretTimers.isExpired($0, nowMillis: now) ? nil : $0 }
        return messagePreview(last) ?? "Секретный чат"
    }

    static func messagePreview(_ message: AloSecretMessage?) -> String? {
        guard let message else { return nil }
        if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return message.body }
        guard let first = message.attachments.first else { return nil }
        if first.isCircleAttachment { return "Видеосообщение" }
        if first.isVoiceAttachment { return "Голосовое сообщение" }
        switch first.type.lowercased() {
        case "image": return "Фото"
        case "video": return "Видео"
        default: return "Файл"
        }
    }

    /// A secret chat as a row of the ordinary list. Its `peerId` is negative so it can never be mistaken for a person
    /// or a group, and its `roomId` is the secret chat's own id (the chat list keys rows by kind and room).
    static func summary(_ chat: AloSecretChat, now: Double = Date().timeIntervalSince1970 * 1000) -> AloConversationSummary {
        AloConversationSummary(
            peerId: -chat.id,
            kind: "secret",
            roomId: chat.id,
            memberCount: 0,
            lastAt: chat.lastActivityAt,
            lastBody: preview(chat, now: now),
            peer: AloConversationPeer(
                id: chat.peerUserId, name: chat.peerName, username: chat.peerUsername, avatarUrl: chat.peerAvatarUrl,
                verified: chat.peerVerified, online: false, lastSeenAt: "", isTyping: false, entityType: "secret"
            ),
            lastMessageId: chat.lastMessage?.id ?? 0,
            lastSenderId: chat.lastMessage?.senderUserId ?? 0,
            unreadCount: chat.isIncomingRequest ? max(1, chat.unreadCount) : chat.unreadCount,
            hasServerUnreadCount: true
        )
    }

    /// The list the person sees: the conversations as the list arranged them (pinned first) with the secret chats among
    /// the rest by last activity. Secret chats are never pinned or archived.
    static func merge(
        arranged: [AloConversationSummary],
        isPinned: (AloConversationSummary) -> Bool,
        secrets: [AloSecretChat],
        now: Double = Date().timeIntervalSince1970 * 1000
    ) -> [AloConversationSummary] {
        guard !secrets.isEmpty else { return arranged }
        let pinned = Array(arranged.prefix { isPinned($0) })
        let rest = Array(arranged.dropFirst(pinned.count))
        let ordered = secrets.sorted { AloSecretTime.millis($0.lastActivityAt) > AloSecretTime.millis($1.lastActivityAt) }
        var result = pinned
        var chatIndex = 0, secretIndex = 0
        while chatIndex < rest.count || secretIndex < ordered.count {
            let nextChat = chatIndex < rest.count ? rest[chatIndex] : nil
            let nextSecret = secretIndex < ordered.count ? ordered[secretIndex] : nil
            if let nextSecret,
               (nextChat == nil || AloSecretTime.millis(nextSecret.lastActivityAt) > AloSecretTime.millis(nextChat?.lastAt ?? "")) {
                result.append(summary(nextSecret, now: now))
                secretIndex += 1
            } else if let nextChat {
                result.append(nextChat)
                chatIndex += 1
            }
        }
        return result
    }

    /// The list from the server replaces ours, newest activity first.
    static func replacing(_ fresh: [AloSecretChat]) -> [AloSecretChat] {
        fresh.sorted { AloSecretTime.millis($0.lastActivityAt) > AloSecretTime.millis($1.lastActivityAt) }
    }

    static func removing(_ current: [AloSecretChat], id: Int) -> [AloSecretChat] { current.filter { $0.id != id } }

    /// The chat as the server shows it now, merged into ours (a message list answers with the chat too).
    static func upserting(_ current: [AloSecretChat], _ chat: AloSecretChat) -> [AloSecretChat] {
        replacing([chat] + current.filter { $0.id != chat.id })
    }
}

/// Timers of a secret chat: they start when the message is read, and the message disappears on both sides.
enum AloSecretTimers {
    static func expiresAtAfterRead(nowMillis: Double, seconds: Int) -> String {
        seconds > 0 ? AloSecretTime.iso(millis: nowMillis + Double(seconds) * 1000) : ""
    }

    struct ReadResult {
        let messages: [AloSecretMessage]
        /// What to tell the server: 0 when nothing was unread.
        let upToMessageId: Int
    }

    /// Opening a chat reads what the other person sent: those messages get their read mark and, with a timer, their end.
    static func applyRead(_ messages: [AloSecretMessage], myUserId: Int, nowMillis: Double) -> ReadResult {
        let unread = messages.filter { $0.senderUserId != myUserId && $0.readAt.isEmpty }
        guard !unread.isEmpty else { return ReadResult(messages: messages, upToMessageId: 0) }
        let readAt = AloSecretTime.iso(millis: nowMillis)
        let ids = Set(unread.map(\.id))
        return ReadResult(
            messages: messages.map { message in
                guard ids.contains(message.id) else { return message }
                return message.replacingRead(
                    readAt: readAt,
                    expiresAt: message.expiresAt.isEmpty
                        ? expiresAtAfterRead(nowMillis: nowMillis, seconds: message.selfDestructSeconds)
                        : message.expiresAt
                )
            },
            upToMessageId: unread.map(\.id).max() ?? 0
        )
    }

    static func isExpired(_ message: AloSecretMessage, nowMillis: Double) -> Bool {
        !message.expiresAt.isEmpty && AloSecretTime.millis(message.expiresAt) <= nowMillis
    }

    static func visible(_ messages: [AloSecretMessage], nowMillis: Double) -> [AloSecretMessage] {
        messages.filter { !isExpired($0, nowMillis: nowMillis) }
    }

    /// The chat's own timer goes into each new message (the server holds a default for the chat too).
    static func secondsForNewMessage(_ chat: AloSecretChat) -> Int { max(0, chat.ttlSeconds) }
}
