import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// Cloud chats (decision of 2026-10-25): ordinary chats are stored plain on the server and readable on every
// signed-in device. The wire contract is in `alo/docs/cloud-and-secret-chats.md`, "Этап 1". End-to-end
// encryption (libsignal) stays for old messages and for the server flags that require it.

/// What `GET /api/config` → `security` says about plain messages.
struct AloMessagingPolicy: Equatable {
    var plaintextDirectAllowed: Bool
    var plaintextGroupAllowed: Bool
    /// `security.secretChats`: the server can do secret chats (stage 2).
    var secretChatsEnabled = false

    /// The behaviour before cloud chats: everything goes through libsignal.
    static let encryptedOnly = AloMessagingPolicy(plaintextDirectAllowed: false, plaintextGroupAllowed: false)

    init(plaintextDirectAllowed: Bool, plaintextGroupAllowed: Bool, secretChatsEnabled: Bool = false) {
        self.plaintextDirectAllowed = plaintextDirectAllowed
        self.plaintextGroupAllowed = plaintextGroupAllowed
        self.secretChatsEnabled = secretChatsEnabled
    }

    /// `config` is the whole body of `GET /api/config`. A server that does not know the flags needs end-to-end messages.
    init(config: [String: Any]) {
        let security = config.object("security")
        plaintextDirectAllowed = security["plaintextDirectMessagesAllowed"] as? Bool ?? false
        plaintextGroupAllowed = security["plaintextGroupMessagesAllowed"] as? Bool ?? false
        secretChatsEnabled = security["secretChats"] as? Bool ?? false
    }

    /// Direct chats and «Избранное» follow the direct flag, groups and channels the group flag.
    func allowsCloud(kind: String, roomId: Int) -> Bool {
        kind == "group" && roomId > 0 ? plaintextGroupAllowed : plaintextDirectAllowed
    }

    /// Both kinds are cloud: no reason to talk about keys of other people's devices anywhere in the chats.
    var isCloudEverywhere: Bool { plaintextDirectAllowed && plaintextGroupAllowed }
}

/// The policy of one server, kept for a few minutes and on disk, so a send from the outbox needs no extra request.
final class AloMessagingPolicyCache: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey: String
    private let timeToLive: TimeInterval
    private let retryAfterFailure: TimeInterval
    private var policy: AloMessagingPolicy?
    private var loadedAt: Date?
    private var failedAt: Date?

    init(scope: String, defaults: UserDefaults = .standard, timeToLive: TimeInterval = 300, retryAfterFailure: TimeInterval = 10) {
        self.defaults = defaults
        self.storageKey = "alo.ios.messaging-policy.v1.\(scope)"
        self.timeToLive = timeToLive
        self.retryAfterFailure = retryAfterFailure
    }

    /// Loaded recently enough to be used without asking the server.
    func fresh(now: Date = Date()) -> AloMessagingPolicy? {
        lock.lock(); defer { lock.unlock() }
        guard let policy, let loadedAt, now.timeIntervalSince(loadedAt) < timeToLive else { return nil }
        return policy
    }

    /// The last known policy, however old: in memory, otherwise what an earlier launch saved.
    func stored() -> AloMessagingPolicy? {
        lock.lock(); defer { lock.unlock() }
        if let policy { return policy }
        guard let record = defaults.dictionary(forKey: storageKey) else { return nil }
        let restored = AloMessagingPolicy(
            plaintextDirectAllowed: record["direct"] as? Bool ?? false,
            plaintextGroupAllowed: record["group"] as? Bool ?? false,
            secretChatsEnabled: record["secret"] as? Bool ?? false
        )
        policy = restored
        return restored
    }

    func store(_ value: AloMessagingPolicy, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        policy = value
        loadedAt = now
        failedAt = nil
        defaults.set(["direct": value.plaintextDirectAllowed, "group": value.plaintextGroupAllowed,
                      "secret": value.secretChatsEnabled], forKey: storageKey)
    }

    func recordFailure(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        failedAt = now
    }

    func recentlyFailed(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let failedAt else { return false }
        return now.timeIntervalSince(failedAt) < retryAfterFailure
    }

    /// The server answered 426: the flags changed. The next send asks again.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        loadedAt = nil
        failedAt = nil
    }

    func forget() {
        lock.lock(); defer { lock.unlock() }
        policy = nil
        loadedAt = nil
        failedAt = nil
        defaults.removeObject(forKey: storageKey)
    }
}

/// What a message that is being forwarded carried, as this device sees it. A cloud forward resends it as a new
/// message, so an old encrypted message (which the server cannot read) can be forwarded too.
struct AloForwardContent: Equatable {
    /// The text with its formatting written back as markup (`**bold**`).
    let body: String
    let attachments: [AloMessageAttachment]

    init(body: String, attachments: [AloMessageAttachment]) {
        self.body = body
        self.attachments = attachments
    }

    init(_ message: AloChatMessage) {
        body = message.markupSource
        attachments = message.attachments
    }
}

/// One message to send to a cloud chat: `POST /api/messages/send` or `/api/group-chats/:roomId/messages/send`.
struct AloCloudSendRequest {
    var peerId = 0
    var roomId = 0
    var kind = "direct"
    /// The composer text with markup; it goes out as `body` plus `entities`.
    var body = ""
    var attachments: [AloMessageAttachment] = []
    var forwardFrom: AloForwardMeta?
    var replyToMessageId = 0
    var topicId = 0
    var selfDestructSeconds = 0
    var silent = false
    var scheduledAt = ""
    var sendWhenOnline = false
    var scheduledPoll: [String: Any]?
    var captchaToken: String?
    var clientMessageId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var mentionedUserIds: [Int] = []

    var isGroup: Bool { kind == "group" && roomId > 0 }

    var path: String {
        isGroup ? "/api/group-chats/\(roomId)/messages/send" : "/api/messages/send"
    }

    /// The JSON body. There is never an `encrypted` field in it.
    var jsonBody: [String: Any] {
        let markup = AloCloudMessage.trimmedMarkup(body)
        var json: [String: Any] = [
            "body": markup.body,
            "entities": markup.entities.map(\.payload),
            "attachments": attachments.map(AloCloudMessage.attachmentPayload),
            "replyToMessageId": max(0, replyToMessageId),
            "topicId": max(0, topicId),
            "selfDestructSeconds": max(0, selfDestructSeconds),
            "silent": silent,
            "sendWhenOnline": sendWhenOnline,
            "clientMessageId": clientMessageId
        ]
        if !scheduledAt.isEmpty {
            json["scheduledAt"] = scheduledAt
            if let scheduledPoll { json["scheduledPoll"] = scheduledPoll }
        }
        if let captchaToken { json["captchaToken"] = captchaToken }
        if let forwardFrom {
            json["forwardFrom"] = ["userId": forwardFrom.userId, "messageId": forwardFrom.messageId]
        }
        if isGroup {
            if !mentionedUserIds.isEmpty { json["mentionedUserIds"] = mentionedUserIds }
        } else {
            json["peerId"] = peerId
        }
        return json
    }
}

enum AloCloudMessage {
    /// The server keeps a plain file up to 30 MB (25 MB for documents and photos, 160 MB for audio: a voice message may run for 100 minutes).
    static let videoLimit: Int64 = 30 * 1_024 * 1_024
    static let documentLimit: Int64 = 25 * 1_024 * 1_024
    static let audioLimit: Int64 = 160 * 1_024 * 1_024

    /// The kinds the server accepts: `image video file voice circle` (uploaded files) and `location contact sticker` (cards).
    static func wireType(_ type: String) -> String {
        switch type.lowercased() {
        case "image", "video", "file", "voice", "circle", "location", "contact", "sticker":
            return type.lowercased()
        case "audio":
            return "voice"
        case "video_circle", "video-circle":
            return "circle"
        case "gif":
            // The server has no GIF card. The catalog GIF is an https picture, which a sticker card may carry, and
            // every app draws a sticker from its address.
            return "sticker"
        default:
            return "file"
        }
    }

    /// The attachment object of a cloud message: the one that used to travel inside the encrypted envelope, without `mediaEncryption`.
    static func attachmentPayload(_ attachment: AloMessageAttachment) -> [String: Any] {
        let type = wireType(attachment.type)
        var payload: [String: Any] = [
            "type": type,
            "url": remoteAddress(attachment.url),
            "name": String(attachment.name.prefix(120))
        ]
        let poster = remoteAddress(attachment.posterUrl)
        if !poster.isEmpty { payload["posterUrl"] = poster }
        if type == "voice", !attachment.waveform.isEmpty {
            payload["waveform"] = attachment.waveform.prefix(64).map { Double($0) }
        }
        let metadata = metadataPayload(attachment.metadata)
        if !metadata.isEmpty { payload["metadata"] = metadata }
        return payload
    }

    /// A downloaded copy is addressed by a private scheme; the message needs the address on the server.
    private static func remoteAddress(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        guard let url = URL(string: value), AloSecureMediaStore.shared.isSecureURL(url) else { return value }
        return AloSecureMediaStore.shared.remoteURL(for: url) ?? ""
    }

    private static let numericMetadataKeys: Set<String> = ["latitude", "longitude", "width", "height"]

    /// At most 16 flat fields with plain names; strings up to 256 characters.
    static func metadataPayload(_ metadata: [String: String]) -> [String: Any] {
        var result = [String: Any]()
        for key in metadata.keys.sorted() {
            guard result.count < 16, let value = metadata[key],
                  key.range(of: "^[A-Za-z][A-Za-z0-9_]{0,31}$", options: .regularExpression) != nil else { continue }
            if numericMetadataKeys.contains(key), let number = Double(value), number.isFinite {
                result[key] = number
            } else {
                result[key] = String(value.prefix(256))
            }
        }
        return result
    }

    /// The text the way the server stores it: without the markers, without spaces around it (the server trims
    /// the body, so the offsets must already be right for the trimmed text).
    static func trimmedMarkup(_ source: String) -> AloMessageMarkupResult {
        let parsed = AloMessageMarkup.parse(source)
        let utf16 = Array(parsed.body.utf16)
        func isSpace(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        var start = 0
        var end = utf16.count
        while start < end, isSpace(utf16[start]) { start += 1 }
        while end > start, isSpace(utf16[end - 1]) { end -= 1 }
        guard start > 0 || end < utf16.count else { return parsed }
        let body = String(decoding: utf16[start..<end], as: UTF16.self)
        let entities = parsed.entities.compactMap { entity -> AloMessageTextEntity? in
            let lower = max(entity.offset, start)
            let upper = min(entity.offset + entity.length, end)
            guard upper > lower else { return nil }
            return AloMessageTextEntity(type: entity.type, offset: lower - start, length: upper - lower, url: entity.url)
        }
        return AloMessageMarkupResult(body: body, entities: AloMessageMarkup.normalized(entities, utf16Length: body.utf16.count))
    }

    /// `POST …/edit` body: the new text and its formatting.
    static func editBody(markup source: String, operationId: String) -> [String: Any] {
        let markup = trimmedMarkup(source)
        return [
            "body": markup.body,
            "entities": markup.entities.map(\.payload),
            "operationId": operationId
        ]
    }

    /// An uploaded file keeps the extension the server gave it (a recording may come back as .ogg).
    static func name(_ name: String, matching address: String) -> String {
        let addressExtension = (address as NSString).pathExtension.lowercased()
        guard !addressExtension.isEmpty else { return name }
        let current = (name as NSString).pathExtension.lowercased()
        if current == addressExtension { return name }
        let stem = current.isEmpty ? name : (name as NSString).deletingPathExtension
        return "\(stem).\(addressExtension)"
    }
}

/// A plain file ready for `POST /api/uploads/resumable` with purpose "message".
struct AloCloudUploadFile {
    let url: URL
    let size: Int64
    let checksum: String
    let mime: String
    /// Name for the message, with the extension of the bytes that are really uploaded.
    let name: String
    private let temporaryURLs: [URL]

    fileprivate init(url: URL, size: Int64, checksum: String, mime: String, name: String, temporaryURLs: [URL]) {
        self.url = url
        self.size = size
        self.checksum = checksum
        self.mime = mime
        self.name = name
        self.temporaryURLs = temporaryURLs
    }

    func cleanup() {
        temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

enum AloCloudUploadPreparation {
    /// Title, performer and length of a song from its tags (ID3, iTunes), for the track bubble and the player.
    static func songMetadata(_ url: URL, mime: String) async -> [String: String] {
        let asset = AVURLAsset(url: url)
        var result = ["mime": mime]
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
            result["durationSeconds"] = String(Int(duration.seconds.rounded()))
        }
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey, let value = try? await item.load(.stringValue),
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if key == .commonKeyTitle { result["title"] = value }
                if key == .commonKeyArtist { result["performer"] = value }
            }
        }
        return result
    }

    private static let directlyAccepted: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif", "image/avif"]

    /// Decrypts the private draft to a short-lived file, turns HEIC photos into JPEG (other apps cannot show
    /// HEIC), shrinks a video that is over the server's limit and checks the size limits before any byte is sent.
    static func prepare(_ attachment: AloLocalAttachment) async throws -> AloCloudUploadFile {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("alo-cloud-upload-\(UUID().uuidString)")
        var temporary = [source]
        do {
            try await Task.detached(priority: .utility) {
                if let encryptedSource = attachment.encryptedSourceURL {
                    guard let metadata = AloChunkedMediaCrypto.Metadata(attachment.mediaEncryption) else {
                        throw AloAPIError(status: 400, code: "DRAFT_MEDIA_INVALID", message: "Черновик вложения повреждён.", payload: [:])
                    }
                    try AloChunkedMediaCrypto.decrypt(encryptedURL: encryptedSource, metadata: metadata, destinationURL: source)
                } else {
                    try attachment.data.write(to: source, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            }.value

            let type = attachment.type.lowercased()
            var mime = attachment.mime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var name = attachment.name
            var file = source
            if type == "image", !directlyAccepted.contains(mime) {
                let converted = FileManager.default.temporaryDirectory.appendingPathComponent("alo-cloud-upload-\(UUID().uuidString).jpg")
                temporary.append(converted)
                try await Task.detached(priority: .utility) { try convertToJPEG(source: source, destination: converted) }.value
                file = converted
                mime = "image/jpeg"
                name = AloCloudMessage.name(name, matching: "x.jpg")
            }
            if type == "circle" || type == "video_circle" { mime = "video/mp4" }
            var size = try fileSize(file)
            let isVideo = type == "video" || type == "circle" || mime.hasPrefix("video/")
            if isVideo, size > AloCloudMessage.videoLimit {
                let shrunk = try await shrinkVideo(source: file)
                temporary.append(shrunk)
                file = shrunk
                mime = "video/mp4"
                name = AloCloudMessage.name(name, matching: "x.mp4")
                size = try fileSize(file)
            }
            // A song sent as a file keeps the file limit; recordings have the voice one.
            let limit: Int64 = isVideo ? AloCloudMessage.videoLimit
                : (type == "audio" || type == "voice" || (mime.hasPrefix("audio/") && type != "file")) ? AloCloudMessage.audioLimit
                : AloCloudMessage.documentLimit
            guard size > 0, size <= limit else {
                throw AloAPIError(
                    status: 413,
                    code: "CLOUD_FILE_TOO_LARGE",
                    message: size <= 0
                        ? "Файл пуст."
                        : "В обычном чате файл может быть до \(limit / 1_048_576) МБ. Сократите его или отправьте ссылкой.",
                    payload: [:]
                )
            }
            let checksum = try await Task.detached(priority: .utility) { try AloAPIClient.sha256(of: file) }.value
            return AloCloudUploadFile(url: file, size: size, checksum: checksum,
                                      mime: mime.ifBlank("application/octet-stream"), name: name, temporaryURLs: temporary)
        } catch {
            temporary.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private static func convertToJPEG(source: URL, destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4_096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let target = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AloAPIError(status: 400, code: "IMAGE_UNREADABLE", message: "Не удалось подготовить фото к отправке.", payload: [:])
        }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(target) else {
            throw AloAPIError(status: 400, code: "IMAGE_UNREADABLE", message: "Не удалось подготовить фото к отправке.", payload: [:])
        }
    }

    /// 720p, then 540p: the first that fits the server's limit.
    private static func shrinkVideo(source: URL) async throws -> URL {
        for preset in [AVAssetExportPreset1280x720, AVAssetExportPreset960x540] {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("alo-cloud-video-\(UUID().uuidString).mp4")
            guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: preset) else { continue }
            exporter.shouldOptimizeForNetworkUse = true
            do {
                try await exporter.export(to: output, as: .mp4)
            } catch {
                try? FileManager.default.removeItem(at: output)
                continue
            }
            if let size = try? fileSize(output), size > 0, size <= AloCloudMessage.videoLimit { return output }
            try? FileManager.default.removeItem(at: output)
        }
        throw AloAPIError(
            status: 413,
            code: "CLOUD_FILE_TOO_LARGE",
            message: "В обычном чате видео может быть до \(AloCloudMessage.videoLimit / 1_048_576) МБ. Выберите более короткое видео.",
            payload: [:]
        )
    }
}

extension AloAPIClient {
    // MARK: Policy

    /// The flags of `GET /api/config`. Never throws: when the server cannot be asked, the last known policy is
    /// used, and without one the old behaviour (end-to-end) stays.
    func messagingPolicy(refresh: Bool = false) async -> AloMessagingPolicy {
        if !refresh {
            if let fresh = messagingPolicyCache.fresh() { return fresh }
            if messagingPolicyCache.recentlyFailed() { return messagingPolicyCache.stored() ?? .encryptedOnly }
        }
        do {
            let config = try await request("GET", "/api/config", timeout: 10)
            let policy = AloMessagingPolicy(config: config)
            messagingPolicyCache.store(policy)
            return policy
        } catch {
            messagingPolicyCache.recordFailure()
            return messagingPolicyCache.stored() ?? .encryptedOnly
        }
    }

    /// The policy as far as it is known without any request.
    var knownMessagingPolicy: AloMessagingPolicy { messagingPolicyCache.stored() ?? .encryptedOnly }

    func usesCloudMessages(kind: String, roomId: Int) async -> Bool {
        await messagingPolicy().allowsCloud(kind: kind, roomId: roomId)
    }

    // MARK: Send

    func sendCloudMessage(_ message: AloCloudSendRequest) async throws -> AloMessageSendAcknowledgement {
        do {
            let response = try await request("POST", message.path, body: message.jsonBody)
            return try Self.sendAcknowledgement(from: response)
        } catch let error as AloAPIError where error.status == 426 {
            // The operator turned end-to-end messages on again: ask for the flags next time.
            messagingPolicyCache.invalidate()
            throw error
        }
    }

    /// `body` is the new text with markup; the server answers with the plain text, so the caller keeps its own.
    func sendCloudMessageEdit(
        conversation: AloConversationDetail,
        messageId: Int,
        body: String,
        operationId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws -> (body: String, editedAt: String) {
        let path = conversation.kind == "group" && conversation.roomId > 0
            ? "/api/group-chats/\(conversation.roomId)/messages/\(messageId)/edit"
            : "/api/messages/\(messageId)/edit"
        do {
            let json = try await request("POST", path, body: AloCloudMessage.editBody(markup: body, operationId: operationId))
            return (body, json.object("message").string("editedAt"))
        } catch let error as AloAPIError where error.status == 426 {
            messagingPolicyCache.invalidate()
            throw error
        }
    }

    static func sendAcknowledgement(from response: [String: Any]) throws -> AloMessageSendAcknowledgement {
        let message = response.object("message")
        guard message.int("id") > 0 || (response.bool("scheduled") && response.object("scheduledMessage").int("id") > 0) else {
            throw AloAPIError(status: 502, code: "MESSAGE_ACK_INVALID",
                message: "Сервер не подтвердил отправку. Сообщение сохранено, можно повторить попытку.", payload: [:])
        }
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

    // MARK: Upload

    /// A plain upload: the file goes to the server as it is, purpose "message".
    func uploadCloudAttachment(
        _ attachment: AloLocalAttachment,
        resumeCheckpoint: AloResumableUploadCheckpoint? = nil,
        onCheckpoint: ((AloResumableUploadCheckpoint) -> Void)? = nil
    ) async throws -> AloMessageAttachment {
        let file = try await AloCloudUploadPreparation.prepare(attachment)
        defer { file.cleanup() }
        // A song picked as a file (not a recording) stays as it is: without `keepOriginal` the server turns any audio
        // into a voice message. Its title, performer and length go with it, as the website sends them.
        let isSong = attachment.type.lowercased() == "file" && (file.mime.hasPrefix("audio/")
            || AloMusicCatalog.isMusic(AloMessageAttachment(type: "file", url: "", name: file.name)))
        let songMetadata = isSong ? await AloCloudUploadPreparation.songMetadata(file.url, mime: file.mime) : [:]
        let json = try await uploadResumable(
            fileURL: file.url,
            size: file.size,
            checksum: file.checksum,
            purpose: "message",
            mime: file.mime,
            resumeCheckpoint: resumeCheckpoint,
            onCheckpoint: onCheckpoint,
            keepOriginal: isSong
        )
        let uploaded = json.object("file")
        let address = uploaded.string("url")
        let serverType = uploaded.string("type").lowercased()
        let localType = attachment.type.lowercased()
        let type: String
        switch localType {
        case "circle", "video_circle", "video-circle": type = "circle"
        case "audio", "voice": type = "voice"
        default: type = ["image", "video", "file", "voice"].contains(serverType) ? serverType : AloCloudMessage.wireType(localType)
        }
        return AloMessageAttachment(
            type: type,
            url: address,
            // A recording the server turned into .ogg keeps playing: the file type comes from the name.
            name: type == "voice" || type == "circle" ? AloCloudMessage.name(file.name, matching: address) : file.name,
            waveform: attachment.waveform,
            metadata: attachment.durationMetadata.merging(songMetadata) { _, song in song }
        )
    }

    /// The upload the chat needs: plain for a cloud chat, chunk-encrypted for an end-to-end one.
    func uploadMessageAttachment(
        _ attachment: AloLocalAttachment,
        cloud: Bool,
        resumeCheckpoint: AloResumableUploadCheckpoint? = nil,
        onCheckpoint: ((AloResumableUploadCheckpoint) -> Void)? = nil
    ) async throws -> AloMessageAttachment {
        if cloud {
            return try await uploadCloudAttachment(attachment, resumeCheckpoint: resumeCheckpoint, onCheckpoint: onCheckpoint)
        }
        return try await uploadE2EEAttachment(attachment, resumeCheckpoint: resumeCheckpoint, onCheckpoint: onCheckpoint)
    }

    /// A forwarded attachment that arrived encrypted: this device holds the decrypted copy, the server only the
    /// ciphertext. It goes up again as a plain file, which a cloud message can carry.
    func reuploadDecryptedAttachment(_ attachment: AloMessageAttachment) async throws -> AloMessageAttachment {
        guard let url = URL(string: attachment.url), AloSecureMediaStore.shared.isSecureURL(url) else {
            throw AloAPIError(status: 400, code: "FORWARD_MEDIA_UNAVAILABLE",
                message: "Это вложение нельзя переслать: на устройстве нет его копии.", payload: [:])
        }
        try await AloSecureMediaStore.shared.ensureAvailable(url, intent: .userInitiated)
        let payload = try await Task.detached(priority: .utility) { try AloSecureMediaStore.shared.payload(for: url) }.value
        let local = AloLocalAttachment(
            data: payload.data,
            mime: payload.mime,
            type: attachment.type,
            name: attachment.name.ifBlank(payload.name),
            waveform: attachment.waveform,
            durationSeconds: attachment.durationSeconds,
            mediaDimensions: attachment.mediaDimensions
        )
        return try await uploadCloudAttachment(local)
    }
}
