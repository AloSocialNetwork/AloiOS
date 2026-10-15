import CryptoKit
import Foundation

enum AloAppTab: String, CaseIterable, Identifiable {
    case feed
    case search
    case messages
    case alerts
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feed: return "Лента"
        case .search: return "Поиск"
        case .messages: return "Чаты"
        case .alerts: return "Уведы"
        case .profile: return "Профиль"
        }
    }

    var systemImage: String {
        switch self {
        case .feed: return "house.fill"
        case .search: return "magnifyingglass"
        case .messages: return "message"
        case .alerts: return "bell"
        case .profile: return "person"
        }
    }
}

enum AloFeedMode: String, CaseIterable {
    case popular
    case subscriptions
}

struct AloEntitySummary: Identifiable, Equatable {
    let id: Int
    let name: String
    let username: String
    let avatarUrl: String
    let verified: Bool
    let isChannel: Bool
    let relation: AloProfileRelation?

    init(_ json: [String: Any]) {
        id = json.int("id")
        name = json.string("name").ifBlank("Без имени")
        username = json.string("username")
        avatarUrl = json.string("avatarUrl").ifBlank(json.string("avatarEmoji"))
        verified = json.bool("verified") || json.bool("isVerified")
        isChannel = json.bool("isChannel") || json.string("entityType") == "channel"
        relation = json.optionalObject("relation").map(AloProfileRelation.init)
    }

    init(
        id: Int,
        name: String,
        username: String,
        avatarUrl: String,
        verified: Bool,
        isChannel: Bool,
        relation: AloProfileRelation? = nil
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.avatarUrl = avatarUrl
        self.verified = verified
        self.isChannel = isChannel
        self.relation = relation
    }
}

struct AloCurrentUser: Identifiable, Equatable {
    let id: Int
    let name: String
    let username: String
    let email: String
    let bio: String
    let avatarUrl: String
    let verified: Bool
    let online: Bool
    let registeredLabel: String
    let coverStyle: String
    let coverImageUrl: String
    /// What this account may do in the moderation panel: "reports", "moderation", "stats"…
    let adminCan: Set<String>

    init(_ json: [String: Any]) {
        id = json.int("id")
        adminCan = Set(json.object("adminScope").boolMap("can").filter(\.value).map(\.key))
        name = json.string("name").ifBlank("Alo")
        username = json.string("username")
        email = json.string("email")
        bio = json.string("bio")
        avatarUrl = json.string("avatarUrl").ifBlank(json.string("avatarEmoji"))
        verified = json.bool("verified") || json.bool("isVerified")
        online = json.bool("online") || json.bool("isOnline")
        registeredLabel = json.string("registeredLabel")
        coverStyle = json.string("coverStyle").ifBlank("violet")
        coverImageUrl = json.string("coverImageUrl")
    }

    /// The same person with another banner.
    func withCover(style: String, imageURL: String) -> AloCurrentUser {
        AloCurrentUser([
            "id": id, "name": name, "username": username, "email": email, "bio": bio, "avatarUrl": avatarUrl,
            "verified": verified, "online": online, "registeredLabel": registeredLabel,
            "coverStyle": style, "coverImageUrl": imageURL,
            "adminScope": ["can": Dictionary(uniqueKeysWithValues: adminCan.map { ($0, true) })]
        ])
    }
}

struct AloMediaItem: Identifiable, Equatable {
    let id = UUID()
    let type: String
    let url: String
    let posterUrl: String
    let caption: String
    /// Optional: older servers do not send it, in which case the post uses a default tall ratio.
    let dimensions: AloMediaDimensions?

    init(type: String, url: String, posterUrl: String = "", caption: String = "", dimensions: AloMediaDimensions? = nil) {
        self.type = type
        self.url = url
        self.posterUrl = posterUrl
        self.caption = caption
        self.dimensions = dimensions
    }

    init(_ json: [String: Any]) {
        type = json.string("type")
        url = json.string("url")
        posterUrl = json.string("posterUrl")
        caption = json.string("caption").ifBlank(json.string("alt"))
        let width = (json["width"] as? Double) ?? Double(json.int("width"))
        let height = (json["height"] as? Double) ?? Double(json.int("height"))
        dimensions = AloMediaDimensions(width: width, height: height)
    }
}

struct AloStory: Identifiable, Equatable {
    let id: Int
    let userId: Int
    let body: String
    let media: [AloMediaItem]
    let createdAt: String
    let expiresAt: String
    let viewerHasSeen: Bool
    let viewCount: Int
    /// Who may see it: everyone, friends, close_friends or selected.
    let audience: AloStoryAudience

    /// The story as the server sends it, to rebuild or regroup it locally.
    var dictionary: [String: Any] {
        [
            "id": id, "userId": userId, "body": body, "createdAt": createdAt, "expiresAt": expiresAt,
            "viewerHasSeen": viewerHasSeen, "viewCount": viewCount, "audience": audience.rawValue,
            "media": media.map { ["type": $0.type, "url": $0.url, "posterUrl": $0.posterUrl, "caption": $0.caption] }
        ]
    }

    var isExpired: Bool {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt) else { return false }
        return date <= Date()
    }

    init(_ json: [String: Any]) {
        id = json.int("id")
        userId = json.int("userId")
        body = json.string("body")
        media = json.array("media").map(AloMediaItem.init)
        createdAt = json.string("createdAt")
        expiresAt = json.string("expiresAt")
        viewerHasSeen = json.bool("viewerHasSeen")
        viewCount = json.int("viewCount")
        audience = AloStoryAudience(rawValue: json.string("audience")) ?? .everyone
    }
}

/// Telegram's story audiences.
enum AloStoryAudience: String, CaseIterable, Identifiable {
    case everyone
    case friends
    case closeFriends = "close_friends"
    case selected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyone: return "Все"
        case .friends: return "Друзья"
        case .closeFriends: return "Близкие друзья"
        case .selected: return "Выбранные"
        }
    }

    var symbol: String {
        switch self {
        case .everyone: return "globe"
        case .friends: return "person.2.fill"
        case .closeFriends: return "star.fill"
        case .selected: return "person.crop.circle.badge.checkmark"
        }
    }
}

/// "Актуальное": a named set of someone's stories kept on their profile after they expire.
struct AloStoryHighlight: Identifiable, Equatable {
    let id: Int
    let title: String
    let coverStoryId: Int
    let stories: [AloStory]

    var cover: AloStory? { stories.first(where: { $0.id == coverStoryId }) ?? stories.first }

    init(_ json: [String: Any]) {
        id = json.int("id")
        title = json.string("title")
        coverStoryId = json.int("coverStoryId")
        stories = json.array("stories").map(AloStory.init)
    }
}

/// Your close friends and the people your stories are hidden from.
struct AloStorySettings: Equatable {
    var closeFriends: [AloEntitySummary]
    var hiddenFrom: [AloEntitySummary]

    init(closeFriends: [AloEntitySummary] = [], hiddenFrom: [AloEntitySummary] = []) {
        self.closeFriends = closeFriends
        self.hiddenFrom = hiddenFrom
    }

    init(_ json: [String: Any]) {
        closeFriends = json.array("closeFriends").map(AloEntitySummary.init)
        hiddenFrom = json.array("hiddenFrom").map(AloEntitySummary.init)
    }
}

struct AloStoryGroup: Identifiable, Equatable {
    let user: AloEntitySummary
    let stories: [AloStory]
    let hasUnseen: Bool

    var id: Int { user.id }

    init(_ json: [String: Any]) {
        user = AloEntitySummary(json.object("user"))
        stories = json.array("stories").map(AloStory.init)
        hasUnseen = json.bool("hasUnseen")
    }
}

/// Someone who opened your story, for the viewers list.
struct AloStoryViewerEntry: Identifiable, Equatable {
    let user: AloEntitySummary
    let viewedAt: String

    var id: Int { user.id }

    init(_ json: [String: Any]) {
        user = AloEntitySummary(json.object("user"))
        viewedAt = json.string("viewedAt")
    }
}

/// What a story link turned out to be: the story, or a note that it has gone.
enum AloStoryLinkResult {
    case live(AloStoryGroup)
    case expired(author: AloEntitySummary?)
}

/// Shown when a story link is opened after the story expired or was deleted.
struct AloExpiredStoryNotice: Identifiable {
    let id = UUID()
    let author: AloEntitySummary?
}

struct AloBusinessProfile: Equatable {
    let userId: Int
    let enabled: Bool
    let businessName: String
    let category: String
    let hours: [String: String]
    let greetingMessage: String
    let autoReplyEnabled: Bool
    let autoReplyMessage: String
    let updatedAt: String

    init(_ json: [String: Any]) {
        userId = json.int("userId")
        enabled = json.bool("enabled")
        businessName = json.string("businessName")
        category = json.string("category")
        hours = json.object("hours").reduce(into: [String: String]()) { result, item in
            result[item.key] = String(describing: item.value)
        }
        greetingMessage = json.string("greetingMessage")
        autoReplyEnabled = json.bool("autoReplyEnabled")
        autoReplyMessage = json.string("autoReplyMessage")
        updatedAt = json.string("updatedAt")
    }
}

struct AloBusinessQuickReply: Identifiable, Equatable {
    let id: Int
    let shortcut: String
    let title: String
    let body: String
    let sortOrder: Int

    init(_ json: [String: Any]) {
        id = json.int("id")
        shortcut = json.string("shortcut")
        title = json.string("title")
        body = json.string("body")
        sortOrder = json.int("sortOrder")
    }
}

struct AloBusinessChatLabel: Identifiable, Equatable {
    let id: Int
    let chatKind: String
    let peerId: Int
    let roomId: Int
    let label: String
    let color: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        chatKind = json.string("chatKind")
        peerId = json.int("peerId")
        roomId = json.int("roomId")
        label = json.string("label")
        color = json.string("color")
    }
}

struct AloBusinessProfileData: Equatable {
    let profile: AloBusinessProfile
    let quickReplies: [AloBusinessQuickReply]
    let chatLabels: [AloBusinessChatLabel]

    init(
        profile: AloBusinessProfile,
        quickReplies: [AloBusinessQuickReply],
        chatLabels: [AloBusinessChatLabel]
    ) {
        self.profile = profile
        self.quickReplies = quickReplies
        self.chatLabels = chatLabels
    }

    init(_ json: [String: Any]) {
        profile = AloBusinessProfile(json.object("profile"))
        quickReplies = json.array("quickReplies").map(AloBusinessQuickReply.init)
        chatLabels = json.array("chatLabels").map(AloBusinessChatLabel.init)
    }
}

struct AloPostComment: Identifiable, Equatable {
    let id: Int
    let body: String
    let media: [AloMediaItem]
    let createdAt: String
    let editedAt: String
    let likeCount: Int
    let viewerLiked: Bool
    let author: AloEntitySummary
    /// The root comment of the thread this reply belongs to; nil for a root comment.
    let parentId: Int?
    /// Whom a reply answers (the root's author or another reply's).
    let replyTo: AloEntitySummary?

    init(_ json: [String: Any]) {
        id = json.int("id")
        body = json.string("body")
        media = json.array("media").map(AloMediaItem.init)
        createdAt = json.string("createdAt")
        editedAt = json.string("editedAt")
        likeCount = json.int("likeCount")
        viewerLiked = json.bool("viewerLiked")
        author = AloEntitySummary(json.object("author"))
        let parent = json.int("parentId")
        parentId = parent > 0 ? parent : nil
        replyTo = json.optionalObject("replyTo").map(AloEntitySummary.init)
    }

    func withLike(count: Int, liked: Bool) -> AloPostComment {
        AloPostComment(copying: self, count: count, liked: liked)
    }
    private init(copying comment: AloPostComment, count: Int, liked: Bool) {
        id = comment.id; body = comment.body; media = comment.media
        createdAt = comment.createdAt; editedAt = comment.editedAt; author = comment.author
        parentId = comment.parentId; replyTo = comment.replyTo
        likeCount = max(0, count); viewerLiked = liked
    }
}

struct AloMessageAttachment: Identifiable, Equatable {
    let id: String
    let type: String
    let url: String
    let name: String
    let posterUrl: String
    let waveform: [CGFloat]
    let mediaEncryption: [String: String]
    /// Structured attachment data is encrypted with the message and never
    /// included in the server-visible attachment envelope.
    let metadata: [String: String]

    init(_ json: [String: Any]) {
        type = json.string("type")
        url = json.string("url")
        name = json.string("name")
        posterUrl = json.string("posterUrl")
        waveform = Self.normalizedWaveform(json["waveform"])
        let encryption = json.object("mediaEncryption").isEmpty ? json.object("e2ee") : json.object("mediaEncryption")
        mediaEncryption = encryption.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = String(describing: pair.value)
        }
        metadata = json.object("metadata").reduce(into: [String: String]()) { result, pair in
            result[pair.key] = String(describing: pair.value)
        }
        id = (metadata["id"] ?? "").ifBlank(url.ifBlank(name.ifBlank(UUID().uuidString)))
    }

    init(local attachment: AloLocalAttachment, includeInlineData: Bool = true) {
        type = attachment.type
        url = attachment.localPlaybackURL?.absoluteString ?? (!includeInlineData || attachment.data.isEmpty ? "" : attachment.dataUrl)
        name = attachment.name
        posterUrl = attachment.type == "image" ? url : ""
        waveform = attachment.waveform
        mediaEncryption = attachment.mediaEncryption
        metadata = attachment.durationMetadata
        id = attachment.id.uuidString
    }

    init(
        type: String,
        url: String = "",
        name: String = "",
        posterUrl: String = "",
        waveform: [CGFloat] = [],
        mediaEncryption: [String: String] = [:],
        metadata: [String: String] = [:]
    ) {
        self.type = type
        self.url = url
        self.name = name
        self.posterUrl = posterUrl
        self.waveform = Self.clippedWaveform(waveform)
        self.mediaEncryption = mediaEncryption
        self.metadata = metadata
        id = (metadata["id"] ?? "").ifBlank(url.ifBlank(name.ifBlank(UUID().uuidString)))
    }

    var isVirtualCard: Bool {
        type == "contact" || type == "location"
    }

    var durationSeconds: Double? {
        guard let value = metadata["durationSeconds"].flatMap(Double.init),
              value.isFinite, value > 0 else { return nil }
        return value
    }

    var mediaDimensions: AloMediaDimensions? { AloMediaDimensions(metadata) }

    var isContactCard: Bool { type == "contact" }
    var isLocationCard: Bool { type == "location" }

    static func contact(_ entity: AloEntitySummary) -> AloMessageAttachment {
        AloMessageAttachment(
            type: "contact",
            name: entity.name,
            metadata: [
                "id": "contact-\(entity.id)",
                "userId": String(entity.id),
                "displayName": entity.name,
                "username": entity.username,
                "avatarUrl": entity.avatarUrl,
                "verified": entity.verified ? "1" : "0"
            ]
        )
    }

    static func location(latitude: Double, longitude: Double) -> AloMessageAttachment {
        let roundedLatitude = String(format: "%.5f", latitude)
        let roundedLongitude = String(format: "%.5f", longitude)
        return AloMessageAttachment(
            type: "location",
            name: "Текущее местоположение",
            metadata: [
                "id": "location-\(roundedLatitude)-\(roundedLongitude)",
                "latitude": roundedLatitude,
                "longitude": roundedLongitude,
                "title": "Текущее местоположение"
            ]
        )
    }

    static func liveLocation(
        latitude: Double,
        longitude: Double,
        expiresAt: String
    ) -> AloMessageAttachment {
        let roundedLatitude = String(format: "%.5f", latitude)
        let roundedLongitude = String(format: "%.5f", longitude)
        return AloMessageAttachment(
            type: "location",
            name: "Живая геопозиция",
            metadata: [
                "id": "live-location-\(roundedLatitude)-\(roundedLongitude)-\(expiresAt)",
                "latitude": roundedLatitude,
                "longitude": roundedLongitude,
                "title": "Живая геопозиция",
                "live": "1",
                "expiresAt": expiresAt
            ]
        )
    }

    private static func normalizedWaveform(_ value: Any?) -> [CGFloat] {
        if let values = value as? [CGFloat] {
            return clippedWaveform(values)
        }
        if let values = value as? [Double] {
            return clippedWaveform(values.map { CGFloat($0) })
        }
        if let values = value as? [Float] {
            return clippedWaveform(values.map { CGFloat($0) })
        }
        if let values = value as? [Int] {
            return clippedWaveform(values.map { CGFloat($0) })
        }
        guard let rawValues = value as? [Any] else { return [] }
        return rawValues.prefix(64).compactMap { item in
            let number: Double?
            if let value = item as? Double {
                number = value
            } else if let value = item as? Float {
                number = Double(value)
            } else if let value = item as? Int {
                number = Double(value)
            } else if let value = item as? NSNumber {
                number = value.doubleValue
            } else if let value = item as? String {
                number = Double(value)
            } else {
                number = nil
            }
            guard let number, number.isFinite else { return nil }
            return CGFloat(max(0.08, min(1, number)))
        }
    }

    private static func clippedWaveform(_ values: [CGFloat]) -> [CGFloat] {
        values.prefix(64).map { max(0.08, min(1, $0)) }
    }
}

/// A server-hosted sticker is referenced by its opaque catalog id and its
/// media URL.  The picker never fabricates a local sticker fallback: if the
/// catalog is unavailable, the UI shows that state instead of sending emoji
/// under the guise of a sticker.
struct AloStickerItem: Identifiable, Equatable {
    let id: String
    let packID: String
    let emoji: String
    let assetURL: String
    let thumbnailURL: String
    let width: Int
    let height: Int
    let alt: String
    let sortOrder: Int

    init(_ json: [String: Any]) {
        let value = json.object("sticker").isEmpty ? json : json.object("sticker")
        id = value.string("id")
        packID = value.string("packId")
        emoji = value.string("emoji")
        assetURL = value.string("assetUrl")
        thumbnailURL = value.string("thumbnailUrl")
        width = max(0, value.int("width"))
        height = max(0, value.int("height"))
        alt = value.string("alt")
        sortOrder = value.int("sortOrder")
    }

    var isUsable: Bool {
        !id.isEmpty && !assetURL.isEmpty
    }

    /// The attachment itself travels in the encrypted message payload. The
    /// URL points to media that the authenticated recipient can load, while
    /// catalog metadata stays available to clients for a stable presentation.
    var messageAttachment: AloMessageAttachment {
        AloMessageAttachment(
            type: "sticker",
            url: assetURL,
            name: alt.ifBlank(emoji.ifBlank("Стикер")),
            posterUrl: thumbnailURL.ifBlank(assetURL),
            metadata: [
                "id": "sticker-\(id)",
                "stickerId": id,
                "packId": packID,
                "emoji": emoji,
                "alt": alt,
                "width": width > 0 ? String(width) : "",
                "height": height > 0 ? String(height) : ""
            ].filter { !$0.value.isEmpty }
        )
    }
}

struct AloStickerPack: Identifiable, Equatable {
    let id: String
    let title: String
    let shortName: String
    let description: String
    let coverURL: String
    let official: Bool
    let installed: Bool
    let itemCount: Int
    let items: [AloStickerItem]

    init(_ json: [String: Any]) {
        let value = json.object("pack").isEmpty ? json : json.object("pack")
        id = value.string("id")
        title = value.string("title")
        shortName = value.string("shortName")
        description = value.string("description")
        coverURL = value.string("coverUrl")
        official = value.bool("official")
        installed = value.bool("installed")
        itemCount = max(0, value.int("itemCount"))
        items = value.array("items").map(AloStickerItem.init).filter(\.isUsable)
    }

    func replacingInstalled(_ installed: Bool) -> AloStickerPack {
        AloStickerPack(
            id: id,
            title: title,
            shortName: shortName,
            description: description,
            coverURL: coverURL,
            official: official,
            installed: installed,
            itemCount: itemCount,
            items: items
        )
    }

    private init(
        id: String,
        title: String,
        shortName: String,
        description: String,
        coverURL: String,
        official: Bool,
        installed: Bool,
        itemCount: Int,
        items: [AloStickerItem]
    ) {
        self.id = id
        self.title = title
        self.shortName = shortName
        self.description = description
        self.coverURL = coverURL
        self.official = official
        self.installed = installed
        self.itemCount = itemCount
        self.items = items
    }
}

struct AloGIFItem: Identifiable, Equatable {
    let id: String
    let title: String
    let url: String
    let previewURL: String
    let width: Int
    let height: Int
    let durationSeconds: Double

    init(_ json: [String: Any]) {
        let value = json.object("gif").isEmpty ? json : json.object("gif")
        id = value.string("id")
        title = value.string("title")
        url = value.string("url")
        previewURL = value.string("previewUrl")
        width = max(0, value.int("width"))
        height = max(0, value.int("height"))
        if let number = value["durationSeconds"] as? NSNumber {
            durationSeconds = max(0, number.doubleValue)
        } else if let string = value["durationSeconds"] as? String {
            durationSeconds = max(0, Double(string) ?? 0)
        } else {
            durationSeconds = 0
        }
    }

    var isUsable: Bool {
        !id.isEmpty && !url.isEmpty
    }

    var messageAttachment: AloMessageAttachment {
        AloMessageAttachment(
            type: "gif",
            url: url,
            name: title.ifBlank("GIF"),
            posterUrl: previewURL.ifBlank(url),
            metadata: [
                "id": "gif-\(id)",
                "gifId": id,
                "title": title,
                "width": width > 0 ? String(width) : "",
                "height": height > 0 ? String(height) : "",
                "durationSeconds": durationSeconds > 0 ? String(durationSeconds) : ""
            ].filter { !$0.value.isEmpty }
        )
    }
}

struct AloGIFResultPage: Equatable {
    let items: [AloGIFItem]
    /// An opaque cursor owned by the configured GIF provider. It is only sent
    /// back to the same server route and is never stored as a draft.
    let nextOffset: String

    init(_ json: [String: Any]) {
        items = json.array("gifs").map(AloGIFItem.init).filter(\.isUsable)
        nextOffset = json.string("nextOffset")
    }
}

struct AloLocalAttachment: Identifiable, Equatable {
    let id: UUID
    let data: Data
    let mime: String
    let type: String
    let name: String
    let waveform: [CGFloat]
    /// Present only for a chunk-encrypted draft file. The file never contains
    /// plaintext and can safely survive a resumable/offline upload.
    let encryptedSourceURL: URL?
    let mediaEncryption: [String: String]
    let encryptedChecksum: String
    /// A private resource-loader URL, never an inline base64 copy of a video.
    let localPlaybackURL: URL?
    let durationSeconds: Double?
    let mediaDimensions: AloMediaDimensions?

    init(
        data: Data,
        mime: String,
        type: String,
        name: String,
        waveform: [CGFloat] = [],
        encryptedSourceURL: URL? = nil,
        mediaEncryption: [String: String] = [:],
        encryptedChecksum: String = "",
        localPlaybackURL: URL? = nil,
        durationSeconds: Double? = nil,
        mediaDimensions: AloMediaDimensions? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.data = data
        self.mime = mime
        self.type = type
        self.name = name
        self.waveform = waveform.prefix(64).map { max(0.08, min(1, $0)) }
        self.encryptedSourceURL = encryptedSourceURL
        self.mediaEncryption = mediaEncryption
        self.encryptedChecksum = encryptedChecksum
        self.localPlaybackURL = localPlaybackURL
        self.durationSeconds = durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.mediaDimensions = mediaDimensions
    }

    var durationMetadata: [String: String] {
        var metadata = mediaDimensions?.metadata ?? [:]
        if let durationSeconds { metadata["durationSeconds"] = String(durationSeconds) }
        return metadata
    }

    func withDuration(_ seconds: Double) -> AloLocalAttachment {
        AloLocalAttachment(data: data, mime: mime, type: type, name: name, waveform: waveform,
            encryptedSourceURL: encryptedSourceURL, mediaEncryption: mediaEncryption,
            encryptedChecksum: encryptedChecksum, localPlaybackURL: localPlaybackURL,
            durationSeconds: seconds, mediaDimensions: mediaDimensions, id: id)
    }

    func withMediaDimensions(_ dimensions: AloMediaDimensions?) -> AloLocalAttachment {
        AloLocalAttachment(data: data, mime: mime, type: type, name: name, waveform: waveform,
            encryptedSourceURL: encryptedSourceURL, mediaEncryption: mediaEncryption,
            encryptedChecksum: encryptedChecksum, localPlaybackURL: localPlaybackURL,
            durationSeconds: durationSeconds, mediaDimensions: dimensions, id: id)
    }

    var dataUrl: String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    func replacingWaveform(_ waveform: [CGFloat]) -> AloLocalAttachment {
        AloLocalAttachment(
            data: data,
            mime: mime,
            type: type,
            name: name,
            waveform: waveform.isEmpty ? self.waveform : waveform,
            encryptedSourceURL: encryptedSourceURL,
            mediaEncryption: mediaEncryption,
            encryptedChecksum: encryptedChecksum,
            localPlaybackURL: localPlaybackURL,
            durationSeconds: durationSeconds,
            mediaDimensions: mediaDimensions,
            id: id
        )
    }
}

struct AloMessageTextEntity: Identifiable, Equatable {
    let type: String
    let offset: Int
    let length: Int
    let url: String

    var id: String { "\(type):\(offset):\(length):\(url)" }

    init(type: String, offset: Int, length: Int, url: String = "") {
        self.type = type
        self.offset = max(0, offset)
        self.length = max(0, length)
        self.url = url
    }

    init?(_ json: [String: Any]) {
        let type = json.string("type").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let offset = json.int("offset")
        let length = json.int("length")
        guard Self.allowedTypes.contains(type), offset >= 0, length > 0 else { return nil }
        self.init(type: type, offset: offset, length: length, url: json.string("url"))
    }

    var payload: [String: Any] {
        var value: [String: Any] = [
            "type": type,
            "offset": offset,
            "length": length
        ]
        if !url.isEmpty {
            value["url"] = url
        }
        return value
    }

    private static let allowedTypes: Set<String> = [
        "bold", "italic", "underline", "strikethrough", "spoiler", "code", "link", "mention", "blockquote", "pre"
    ]
}

struct AloMessageMarkupResult {
    let body: String
    let entities: [AloMessageTextEntity]
}

struct AloPollOption: Equatable, Identifiable {
    let id: String
    let text: String
}

struct AloPollDefinition: Equatable {
    let id: String
    let question: String
    let options: [AloPollOption]
    let allowsMultipleAnswers: Bool
    let isQuiz: Bool
    let correctOptionIds: Set<String>
    /// SHA-256 commitment to the correct quiz answer. The answer and salt are
    /// kept only in the encrypted local store of the quiz author until reveal.
    let quizAnswerCommitment: String
    /// Optional text shown after a participant answers a quiz or after it closes.
    /// It stays inside the encrypted poll definition; correct answers do not.
    let explanation: String
    let isAnonymous: Bool
    let allowsRevoting: Bool
    /// Canonical close deadline. Poll text remains inside the E2EE payload;
    /// this deadline is also sent as technical metadata so the server can enforce it.
    let closesAt: String

    init(
        id: String,
        question: String,
        options: [AloPollOption],
        allowsMultipleAnswers: Bool,
        isQuiz: Bool,
        correctOptionIds: Set<String>,
        quizAnswerCommitment: String = "",
        explanation: String = "",
        isAnonymous: Bool,
        allowsRevoting: Bool,
        closesAt: String = ""
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.allowsMultipleAnswers = allowsMultipleAnswers
        self.isQuiz = isQuiz
        self.correctOptionIds = correctOptionIds
        self.quizAnswerCommitment = quizAnswerCommitment
        self.explanation = explanation
        self.isAnonymous = isAnonymous
        self.allowsRevoting = allowsRevoting
        self.closesAt = closesAt
    }
}

enum AloPollEvent: Equatable {
    case create(AloPollDefinition)
    case vote(pollId: String, optionIds: Set<String>)
    case reveal(pollId: String, correctOptionIds: Set<String>, salt: String)
}

struct AloPollViewState: Equatable {
    let definition: AloPollDefinition
    let voteCounts: [String: Int]
    let selectedOptionIds: Set<String>
    let totalVoters: Int
    let isClosed: Bool
    let allowsRevoting: Bool
    let correctOptionIds: Set<String>
    let publicVoters: [AloPollPublicVoter]
    let closesAt: String
}

struct AloPollPublicVoter: Equatable {
    let userId: Int
    let name: String
    let username: String
    let avatarUrl: String
    let optionIds: Set<String>

    init(_ json: [String: Any]) {
        userId = json.int("userId")
        name = json.string("name").ifBlank("Пользователь")
        username = json.string("username")
        avatarUrl = json.string("avatarUrl")
        optionIds = Set((json["optionIds"] as? [String]) ?? [])
    }
}

struct AloCanonicalPollState: Equatable {
    let id: String
    let messageId: Int
    let voteCounts: [String: Int]
    let selectedOptionIds: Set<String>
    let totalVoters: Int
    let isClosed: Bool
    let allowsRevoting: Bool
    let correctOptionIds: Set<String>
    let publicVoters: [AloPollPublicVoter]
    let closesAt: String
    let closedAt: String

    init(_ json: [String: Any]) {
        id = json.string("id")
        messageId = json.int("messageId")
        voteCounts = json.object("voteCounts").reduce(into: [:]) { result, item in
            result[item.key] = (item.value as? NSNumber)?.intValue ?? 0
        }
        selectedOptionIds = Set((json["selectedOptionIds"] as? [String]) ?? [])
        totalVoters = max(0, json.int("totalVoters"))
        isClosed = json.bool("isClosed")
        allowsRevoting = json.bool("allowsRevoting")
        correctOptionIds = Set((json["correctOptionIds"] as? [String]) ?? [])
        publicVoters = json.array("publicVoters").map(AloPollPublicVoter.init)
        closesAt = json.string("closesAt")
        closedAt = json.string("closedAt")
    }
}

enum AloPollCodec {
    private static let prefix = "alo.poll.v1:"

    static func encodeCreate(_ definition: AloPollDefinition) -> String? {
        guard isValid(definition),
              (!definition.isQuiz || AloPollQuizCommitment.isValidCommitment(definition.quizAnswerCommitment)) else { return nil }
        var payload: [String: Any] = [
            "type": "create",
            "pollId": definition.id,
            "question": definition.question,
            "options": definition.options.map { ["id": $0.id, "text": $0.text] },
            "multiple": definition.allowsMultipleAnswers,
            "quiz": definition.isQuiz,
            "anonymous": definition.isAnonymous,
            "revoting": definition.allowsRevoting
        ]
        if !definition.closesAt.isEmpty {
            payload["closesAt"] = definition.closesAt
        }
        if !definition.explanation.isEmpty {
            payload["explanation"] = definition.explanation
        }
        if definition.isQuiz {
            payload["quizAnswerCommitment"] = definition.quizAnswerCommitment
        }
        return encode(payload)
    }

    static func encodeVote(pollId: String, optionIds: Set<String>) -> String? {
        guard isValidIdentifier(pollId), optionIds.count <= 10,
              optionIds.allSatisfy(isValidIdentifier) else { return nil }
        return encode([
            "type": "vote",
            "pollId": pollId,
            "optionIds": Array(optionIds).sorted()
        ])
    }

    static func encodeReveal(
        pollId: String,
        correctOptionIds: Set<String>,
        salt: String
    ) -> String? {
        guard isValidIdentifier(pollId), correctOptionIds.count == 1,
              correctOptionIds.allSatisfy(isValidIdentifier),
              AloPollQuizCommitment.isValidSalt(salt) else { return nil }
        return encode([
            "type": "reveal",
            "pollId": pollId,
            "correctOptionIds": Array(correctOptionIds).sorted(),
            "salt": salt
        ])
    }

    static func decode(_ body: String) -> AloPollEvent? {
        guard body.hasPrefix(prefix) else { return nil }
        let hex = String(body.dropFirst(prefix.count))
        guard let data = decodeHex(hex),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let pollId = object["pollId"] as? String,
              isValidIdentifier(pollId) else { return nil }
        if type == "vote" {
            guard let values = object["optionIds"] as? [String] else { return nil }
            let optionIds = Set(values)
            guard optionIds.count <= 10,
                  optionIds.allSatisfy(isValidIdentifier) else { return nil }
            return .vote(pollId: pollId, optionIds: optionIds)
        }
        if type == "reveal" {
            guard let values = object["correctOptionIds"] as? [String],
                  let salt = object["salt"] as? String else { return nil }
            let correctOptionIds = Set(values)
            guard correctOptionIds.count == 1,
                  correctOptionIds.allSatisfy(isValidIdentifier),
                  AloPollQuizCommitment.isValidSalt(salt) else { return nil }
            return .reveal(pollId: pollId, correctOptionIds: correctOptionIds, salt: salt)
        }
        guard type == "create",
              let question = object["question"] as? String,
              let rawOptions = object["options"] as? [[String: Any]] else { return nil }
        let options = rawOptions.compactMap { value -> AloPollOption? in
            guard let id = value["id"] as? String,
                  let text = value["text"] as? String,
                  isValidIdentifier(id) else { return nil }
            return AloPollOption(id: id, text: text)
        }
        let definition = AloPollDefinition(
            id: pollId,
            question: question,
            options: options,
            allowsMultipleAnswers: object["multiple"] as? Bool ?? false,
            isQuiz: object["quiz"] as? Bool ?? false,
            correctOptionIds: Set(object["correctOptionIds"] as? [String] ?? []),
            quizAnswerCommitment: object["quizAnswerCommitment"] as? String ?? "",
            explanation: object["explanation"] as? String ?? "",
            isAnonymous: object["anonymous"] as? Bool ?? true,
            allowsRevoting: object["revoting"] as? Bool ?? !(object["quiz"] as? Bool ?? false),
            closesAt: object["closesAt"] as? String ?? ""
        )
        return isValid(definition) ? .create(definition) : nil
    }

    static func previewText(for body: String) -> String? {
        switch decode(body) {
        case let .create(definition):
            return "Опрос: \(definition.question)"
        case .vote:
            return "Опрос"
        case .reveal:
            return "Опрос завершён"
        case nil:
            return body.hasPrefix(prefix) ? "Опрос недоступен" : nil
        }
    }

    private static func encode(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return prefix + data.map { String(format: "%02x", $0) }.joined()
    }

    private static func isValid(_ definition: AloPollDefinition) -> Bool {
        let question = definition.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let explanation = definition.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        let optionIds = Set(definition.options.map(\.id))
        return isValidIdentifier(definition.id) && (1...300).contains(question.count) &&
            explanation.count <= 500 && (definition.isQuiz || explanation.isEmpty) &&
            (2...10).contains(definition.options.count) && optionIds.count == definition.options.count &&
            definition.options.allSatisfy {
                isValidIdentifier($0.id) &&
                    (1...100).contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines).count)
            } && definition.correctOptionIds.isSubset(of: optionIds)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }

    private static func decodeHex(_ value: String) -> Data? {
        guard !value.isEmpty, value.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

enum AloPollQuizCommitment {
    static func prepare(_ definition: AloPollDefinition) -> (definition: AloPollDefinition, salt: String)? {
        guard definition.isQuiz, definition.correctOptionIds.count == 1,
              definition.correctOptionIds.isSubset(of: Set(definition.options.map(\.id))) else { return nil }
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<24).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            .base64EncodedString()
        let commitment = makeCommitment(
            pollId: definition.id,
            correctOptionIds: definition.correctOptionIds,
            salt: salt
        )
        return (
            AloPollDefinition(
                id: definition.id,
                question: definition.question,
                options: definition.options,
                allowsMultipleAnswers: definition.allowsMultipleAnswers,
                isQuiz: true,
                correctOptionIds: definition.correctOptionIds,
                quizAnswerCommitment: commitment,
                explanation: definition.explanation,
                isAnonymous: definition.isAnonymous,
                allowsRevoting: definition.allowsRevoting,
                closesAt: definition.closesAt
            ),
            salt
        )
    }

    static func verifies(
        pollId: String,
        correctOptionIds: Set<String>,
        salt: String,
        commitment: String
    ) -> Bool {
        guard isValidSalt(salt), isValidCommitment(commitment) else { return false }
        return makeCommitment(
            pollId: pollId,
            correctOptionIds: correctOptionIds,
            salt: salt
        ) == commitment.lowercased()
    }

    static func isValidCommitment(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    static func isValidSalt(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value), (16...64).contains(data.count) else { return false }
        return data.base64EncodedString() == value
    }

    private static func makeCommitment(
        pollId: String,
        correctOptionIds: Set<String>,
        salt: String
    ) -> String {
        let source = "alo.poll.quiz.v1|\(pollId)|\(correctOptionIds.sorted().joined(separator: ","))|\(salt)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// System events use the normal encrypted-message route. They are a report
/// from the client, not proof that a screenshot was taken: iOS only reports a
/// screenshot after the operating system has already created it.
enum AloChatSystemEvent: Equatable {
    case protectedMediaScreenshot
}

enum AloChatSystemEventCodec {
    private static let prefix = "alo.system.v1:"
    private static let protectedMediaScreenshotToken = "protected_media_screenshot"

    static func encode(_ event: AloChatSystemEvent) -> String {
        switch event {
        case .protectedMediaScreenshot:
            return prefix + protectedMediaScreenshotToken
        }
    }

    static func decode(_ body: String) -> AloChatSystemEvent? {
        guard body.hasPrefix(prefix) else { return nil }
        switch String(body.dropFirst(prefix.count)) {
        case protectedMediaScreenshotToken:
            return .protectedMediaScreenshot
        default:
            return nil
        }
    }

    static func previewText(for body: String, isMine: Bool = false) -> String? {
        guard let event = decode(body) else { return nil }
        switch event {
        case .protectedMediaScreenshot:
            return isMine
                ? "Вы сделали снимок исчезающего медиа"
                : "Сделан снимок исчезающего медиа"
        }
    }
}

enum AloPollProjection {
    static func states(messages: [AloChatMessage], currentUserId: Int) -> [String: AloPollViewState] {
        var definitions = [String: (definition: AloPollDefinition, creatorId: Int)]()
        var latestVotes = [String: [Int: Set<String>]]()
        var verifiedReveals = [String: Set<String>]()
        for message in messages {
            switch AloPollCodec.decode(message.body) {
            case let .create(definition):
                definitions[definition.id] = (definition, message.senderId)
            case let .vote(pollId, optionIds):
                latestVotes[pollId, default: [:]][message.senderId] = optionIds
            case let .reveal(pollId, correctOptionIds, salt):
                guard let created = definitions[pollId],
                      message.senderId == created.creatorId,
                      correctOptionIds.isSubset(of: Set(created.definition.options.map(\.id))),
                      AloPollQuizCommitment.verifies(
                        pollId: pollId,
                        correctOptionIds: correctOptionIds,
                        salt: salt,
                        commitment: created.definition.quizAnswerCommitment
                      ) else { continue }
                verifiedReveals[pollId] = correctOptionIds
            case nil:
                continue
            }
        }
        return definitions.mapValues { created in
            let definition = created.definition
            let validIds = Set(definition.options.map(\.id))
            let votes = latestVotes[definition.id, default: [:]].mapValues { ids in
                let filtered = ids.intersection(validIds)
                return definition.allowsMultipleAnswers ? filtered : Set(filtered.prefix(1))
            }
            var counts = Dictionary(uniqueKeysWithValues: definition.options.map { ($0.id, 0) })
            votes.values.forEach { ids in ids.forEach { counts[$0, default: 0] += 1 } }
            return AloPollViewState(
                definition: definition,
                voteCounts: counts,
                selectedOptionIds: votes[currentUserId] ?? [],
                totalVoters: votes.values.filter { !$0.isEmpty }.count,
                isClosed: false,
                allowsRevoting: true,
                correctOptionIds: verifiedReveals[definition.id] ?? definition.correctOptionIds,
                publicVoters: [],
                closesAt: definition.closesAt
            )
        }
    }

    static func applyingCanonical(
        _ canonical: [String: AloCanonicalPollState],
        to projected: [String: AloPollViewState]
    ) -> [String: AloPollViewState] {
        projected.mapValues { state in
            guard let server = canonical[state.definition.id] else { return state }
            if state.definition.isAnonymous {
                // Vote counts and the selected options are reconstructed only
                // from authenticated E2EE vote messages.  The server still
                // supplies lifecycle state after a poll is closed, but it never
                // becomes the source of an anonymous person's choice.
                return AloPollViewState(
                    definition: state.definition,
                    voteCounts: state.voteCounts,
                    selectedOptionIds: state.selectedOptionIds,
                    totalVoters: state.totalVoters,
                    isClosed: server.isClosed,
                    allowsRevoting: server.allowsRevoting,
                    correctOptionIds: server.isClosed ? state.correctOptionIds : [],
                    publicVoters: [],
                    closesAt: server.closesAt.isEmpty ? state.closesAt : server.closesAt
                )
            }
            return AloPollViewState(
                definition: state.definition,
                voteCounts: server.voteCounts,
                selectedOptionIds: server.selectedOptionIds,
                totalVoters: server.totalVoters,
                isClosed: server.isClosed,
                allowsRevoting: server.allowsRevoting,
                correctOptionIds: server.isClosed ? state.correctOptionIds : [],
                publicVoters: server.publicVoters,
                closesAt: server.closesAt
            )
        }
    }

    static func visibleMessages(_ messages: [AloChatMessage]) -> [AloChatMessage] {
        messages.filter {
            switch AloPollCodec.decode($0.body) {
            case .vote?, .reveal?:
                return false
            case .create?, nil:
                return true
            }
        }
    }
}

enum AloMessageMarkup {
    private struct Marker {
        let token: String
        let type: String
    }

    private static let markers = [
        Marker(token: "**", type: "bold"),
        Marker(token: "__", type: "italic"),
        Marker(token: "++", type: "underline"),
        Marker(token: "~~", type: "strikethrough"),
        Marker(token: "||", type: "spoiler"),
        Marker(token: "`", type: "code")
    ]

    /// Lines starting with "> " are a quote, and text between ``` fences (an optional language after
    /// the opening one) is a code block, as in Telegram; inline markers work everywhere but in code.
    static func parse(_ source: String) -> AloMessageMarkupResult {
        guard source.contains("```") || source.contains(">") else { return parseInline(source) }
        enum Kind { case plain, quote, code }
        var segments = [(kind: Kind, text: String, language: String)]()
        let lines = source.components(separatedBy: "\n")
        var plain = [String]()
        func flushPlain() {
            if !plain.isEmpty { segments.append((.plain, plain.joined(separator: "\n"), "")) }
            plain = []
        }
        func isQuoteLine(_ line: String) -> Bool { line == ">" || line.hasPrefix("> ") }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```"),
               let close = lines[(index + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```" }) {
                flushPlain()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                segments.append((.code, lines[(index + 1)..<close].joined(separator: "\n"), String(language.prefix(24))))
                index = close + 1
                continue
            }
            if isQuoteLine(line) {
                flushPlain()
                var quoted = [String]()
                while index < lines.count, isQuoteLine(lines[index]) {
                    quoted.append(String(lines[index].dropFirst(lines[index] == ">" ? 1 : 2)))
                    index += 1
                }
                segments.append((.quote, quoted.joined(separator: "\n"), ""))
                continue
            }
            // An unclosed fence is just text: its backticks are not inline code markers.
            plain.append(line.hasPrefix("```") ? "\\`\\`\\`" + line.dropFirst(3) : line)
            index += 1
        }
        flushPlain()
        guard segments.contains(where: { $0.kind != .plain }) else {
            return parseInline(segments.map(\.text).joined(separator: "\n"))
        }

        var body = ""
        var entities = [AloMessageTextEntity]()
        for (position, segment) in segments.enumerated() {
            if position > 0 { body += "\n" }
            let offset = body.utf16.count
            switch segment.kind {
            case .code:
                body += segment.text
                if !segment.text.isEmpty {
                    entities.append(AloMessageTextEntity(type: "pre", offset: offset, length: segment.text.utf16.count,
                                                         url: segment.language))
                }
            case .plain, .quote:
                let inline = parseInline(segment.text)
                body += inline.body
                entities += inline.entities.map {
                    AloMessageTextEntity(type: $0.type, offset: $0.offset + offset, length: $0.length, url: $0.url)
                }
                if segment.kind == .quote, !inline.body.isEmpty {
                    entities.append(AloMessageTextEntity(type: "blockquote", offset: offset, length: inline.body.utf16.count))
                }
            }
        }
        return AloMessageMarkupResult(body: body, entities: normalized(entities, utf16Length: body.utf16.count))
    }

    private static func parseInline(_ source: String) -> AloMessageMarkupResult {
        guard !source.isEmpty else { return AloMessageMarkupResult(body: "", entities: []) }
        var output = ""
        var entities = [AloMessageTextEntity]()
        var opened = [String: Int]()
        var index = source.startIndex

        while index < source.endIndex {
            if source[index] == "\\" {
                let escaped = source.index(after: index)
                if escaped < source.endIndex {
                    output.append(source[escaped])
                    index = source.index(after: escaped)
                    continue
                }
            }

            if let marker = markers.first(where: { source[index...].hasPrefix($0.token) }) {
                let afterMarker = source.index(index, offsetBy: marker.token.count)
                if let start = opened.removeValue(forKey: marker.token) {
                    let length = output.utf16.count - start
                    if length > 0 {
                        entities.append(
                            AloMessageTextEntity(type: marker.type, offset: start, length: length)
                        )
                    }
                    index = afterMarker
                    continue
                }
                if afterMarker < source.endIndex,
                   source[afterMarker...].range(of: marker.token) != nil {
                    opened[marker.token] = output.utf16.count
                    index = afterMarker
                    continue
                }
            }

            output.append(source[index])
            index = source.index(after: index)
        }

        entities.append(contentsOf: detectedLinks(in: output))
        return AloMessageMarkupResult(
            body: output,
            entities: normalized(entities, utf16Length: output.utf16.count)
        )
    }

    static func source(body: String, entities: [AloMessageTextEntity]) -> String {
        guard !body.isEmpty, !entities.isEmpty else { return body }
        let markersByType = Dictionary(uniqueKeysWithValues: markers.map { ($0.type, $0.token) })
        var insertions = [Int: [(closing: Bool, token: String)]]()
        let utf16 = Array(body.utf16)
        for entity in normalized(entities, utf16Length: body.utf16.count) {
            switch entity.type {
            case "pre":
                // Opening fence first at its offset, closing fence last at its end.
                insertions[entity.offset, default: []].insert((false, "```\(entity.url)\n"), at: 0)
                insertions[entity.offset + entity.length, default: []].append((true, "\n```"))
            case "blockquote":
                insertions[entity.offset, default: []].insert((false, "> "), at: 0)
                for position in entity.offset..<(entity.offset + entity.length) where utf16[position] == 10 {
                    insertions[position + 1, default: []].insert((false, "> "), at: 0)
                }
            default:
                guard let token = markersByType[entity.type] else { continue }
                insertions[entity.offset, default: []].append((false, token))
                insertions[entity.offset + entity.length, default: []].append((true, token))
            }
        }
        let result = NSMutableString(string: body)
        for position in insertions.keys.sorted(by: >) {
            guard let values = insertions[position] else { continue }
            let closing = values.filter(\.closing).reversed().map(\.token).joined()
            let opening = values.filter { !$0.closing }.map(\.token).joined()
            result.insert(closing + opening, at: position)
        }
        return String(result)
    }

    static func normalized(
        _ entities: [AloMessageTextEntity],
        utf16Length: Int
    ) -> [AloMessageTextEntity] {
        entities
            .filter { $0.offset >= 0 && $0.length > 0 && $0.offset + $0.length <= utf16Length }
            .prefix(128)
            .sorted {
                if $0.offset == $1.offset { return $0.length > $1.length }
                return $0.offset < $1.offset
            }
    }

    private static func detectedLinks(in body: String) -> [AloMessageTextEntity] {
        guard let urlExpression = try? NSRegularExpression(
            pattern: #"(?:https?://|alo://)[^\s<>()]+"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(location: 0, length: body.utf16.count)
        var links = urlExpression.matches(in: body, range: range).compactMap { match -> AloMessageTextEntity? in
            guard match.range.length > 0 else { return nil }
            let rawURL = (body as NSString).substring(with: match.range)
            let url = rawURL.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            return AloMessageTextEntity(
                type: "link",
                offset: match.range.location,
                length: (url as NSString).length,
                url: url
            )
        }
        guard let handleExpression = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])@[A-Za-z0-9_]{3,32}\b"#
        ) else { return links }
        for match in handleExpression.matches(in: body, range: range) {
            guard match.range.length > 1,
                  !links.contains(where: { NSIntersectionRange($0.nsRange, match.range).length > 0 }) else {
                continue
            }
            let handle = (body as NSString).substring(with: match.range)
                .dropFirst()
                .lowercased()
            guard let url = AloDeepLinkTarget.handleURL(handle) else { continue }
            links.append(
                AloMessageTextEntity(
                    type: "mention",
                    offset: match.range.location,
                    length: match.range.length,
                    url: url.absoluteString
                )
            )
        }
        return links
    }
}

private extension AloMessageTextEntity {
    var nsRange: NSRange { NSRange(location: offset, length: length) }
}

struct AloForwardMeta: Equatable {
    let userId: Int
    let messageId: Int
    let user: AloEntitySummary?

    init?(_ json: [String: Any]) {
        userId = json.int("userId")
        messageId = json.int("messageId")
        user = json.optionalObject("user").map(AloEntitySummary.init)
        if userId <= 0 || messageId <= 0 { return nil }
    }

    init(userId: Int, messageId: Int, user: AloEntitySummary?) {
        self.userId = userId
        self.messageId = messageId
        self.user = user
    }
}

struct AloMessageReaction: Identifiable, Equatable {
    let emoji: String
    let count: Int
    let reactedByMe: Bool

    var id: String { emoji }

    init(_ json: [String: Any]) {
        emoji = json.string("emoji")
        count = max(0, json.int("count"))
        reactedByMe = json.bool("reactedByMe")
    }

    init(emoji: String, count: Int, reactedByMe: Bool) {
        self.emoji = emoji
        self.count = max(0, count)
        self.reactedByMe = reactedByMe
    }
}

struct AloPost: Identifiable, Equatable {
    let id: Int
    let creatorId: Int
    let body: String
    let media: [AloMediaItem]
    let authorSignature: String
    let commentsEnabled: Bool
    let discussionRoomId: Int?
    let discussionTopicId: Int?
    let messengerRoomId: Int?
    let likeCount: Int
    let commentCount: Int
    let repostCount: Int
    let viewCount: Int
    let viewerLiked: Bool
    let viewerReposted: Bool
    let createdAt: String
    let author: AloEntitySummary
    /// Why the feed shows it; only feed listings carry it.
    let feedReason: AloFeedReason?

    init(_ json: [String: Any]) {
        id = json.int("id")
        feedReason = AloFeedReason(rawValue: json.string("feedReason"))
        creatorId = json.int("creatorId").ifZero(json.int("creator_id"))
        body = json.string("body")
        media = json.array("media").map(AloMediaItem.init)
        authorSignature = json.string("authorSignature")
        commentsEnabled = json["commentsEnabled"] == nil
            ? true
            : json.bool("commentsEnabled")
        let rawDiscussionRoomId = json.int("discussionRoomId")
        discussionRoomId = rawDiscussionRoomId > 0 ? rawDiscussionRoomId : nil
        let rawDiscussionTopicId = json.int("discussionTopicId")
        discussionTopicId = rawDiscussionTopicId > 0 ? rawDiscussionTopicId : nil
        let rawMessengerRoomId = json.int("messengerRoomId")
        messengerRoomId = rawMessengerRoomId > 0 ? rawMessengerRoomId : nil
        likeCount = json.int("likeCount")
        commentCount = json.int("commentCount")
        repostCount = json.int("repostCount")
        viewCount = json.int("viewCount")
        viewerLiked = json.bool("viewerLiked")
        viewerReposted = json.bool("viewerReposted")
        createdAt = json.string("createdAt").ifBlank(json.string("created_at"))
        author = AloEntitySummary(json.object("author"))
    }

    /// Patch only engagement: concurrent like/repost responses must not undo
    /// one another, replace media, or change the identity of a timeline row.
    func withEngagement(likeCount: Int? = nil, viewerLiked: Bool? = nil,
                        repostCount: Int? = nil, viewerReposted: Bool? = nil,
                        commentCount: Int? = nil) -> AloPost {
        AloPost(copying: self, likeCount: likeCount ?? self.likeCount,
                viewerLiked: viewerLiked ?? self.viewerLiked,
                repostCount: repostCount ?? self.repostCount,
                viewerReposted: viewerReposted ?? self.viewerReposted,
                commentCount: commentCount ?? self.commentCount)
    }

    private init(copying post: AloPost, likeCount: Int, viewerLiked: Bool,
                 repostCount: Int, viewerReposted: Bool, commentCount: Int) {
        id = post.id; creatorId = post.creatorId; body = post.body; media = post.media
        authorSignature = post.authorSignature; commentsEnabled = post.commentsEnabled
        discussionRoomId = post.discussionRoomId; discussionTopicId = post.discussionTopicId
        messengerRoomId = post.messengerRoomId; viewCount = post.viewCount
        createdAt = post.createdAt; author = post.author; feedReason = post.feedReason
        self.likeCount = max(0, likeCount); self.viewerLiked = viewerLiked
        self.repostCount = max(0, repostCount); self.viewerReposted = viewerReposted
        self.commentCount = max(0, commentCount)
    }
}

struct AloNotificationItem: Identifiable {
    let id: Int
    let type: String
    let text: String
    let createdAt: String
    let isRead: Bool
    let actor: AloEntitySummary?
    let actionableFriendRequestId: Int
    let entityType: String
    let entityId: Int

    init(_ json: [String: Any]) {
        id = json.int("id")
        type = json.string("type")
        text = json.string("text")
        createdAt = json.string("createdAt")
        isRead = json.bool("isRead")
        actor = json.optionalObject("actor").map(AloEntitySummary.init)
        entityType = json.string("entityType")
        entityId = json.int("entityId")
        actionableFriendRequestId = json.bool("friendRequestActionable") ? entityId : 0
    }

    private init(
        id: Int,
        type: String,
        text: String,
        createdAt: String,
        isRead: Bool,
        actor: AloEntitySummary?,
        actionableFriendRequestId: Int,
        entityType: String,
        entityId: Int
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.createdAt = createdAt
        self.isRead = isRead
        self.actor = actor
        self.actionableFriendRequestId = actionableFriendRequestId
        self.entityType = entityType
        self.entityId = entityId
    }

    func withRead(_ isRead: Bool) -> AloNotificationItem {
        AloNotificationItem(
            id: id,
            type: type,
            text: text,
            createdAt: createdAt,
            isRead: isRead,
            actor: actor,
            actionableFriendRequestId: actionableFriendRequestId,
            entityType: entityType,
            entityId: entityId
        )
    }
}

struct AloConversationPeer: Identifiable, Equatable {
    let id: Int
    let name: String
    let username: String
    let avatarUrl: String
    let verified: Bool
    let online: Bool
    let lastSeenAt: String
    let isTyping: Bool
    let entityType: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        name = json.string("name").ifBlank("Чат")
        username = json.string("username")
        avatarUrl = json.string("avatarUrl").ifBlank(json.string("avatarEmoji"))
        verified = json.bool("verified") || json.bool("isVerified")
        online = json.bool("online") || json.bool("isOnline")
        lastSeenAt = json.string("lastSeenAt")
        isTyping = json.bool("typing") || json.bool("isTyping")
        entityType = json.string("entityType")
    }

    init(
        id: Int,
        name: String,
        username: String,
        avatarUrl: String,
        verified: Bool,
        online: Bool,
        lastSeenAt: String,
        isTyping: Bool,
        entityType: String
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.avatarUrl = avatarUrl
        self.verified = verified
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.isTyping = isTyping
        self.entityType = entityType
    }
}

struct AloGroupMember: Identifiable, Equatable {
    let id: Int
    let name: String
    let username: String
    let avatarUrl: String
    let verified: Bool
    let role: String
    let adminTitle: String
    let isAnonymous: Bool
    let adminRights: [String: Bool]
    let restrictions: [String: Bool]
    let restrictedUntil: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        name = json.string("name").ifBlank("Участник")
        username = json.string("username")
        avatarUrl = json.string("avatarUrl").ifBlank(json.string("avatarEmoji"))
        verified = json.bool("verified") || json.bool("isVerified")
        role = json.string("role").ifBlank("member")
        adminTitle = json.string("adminTitle")
        isAnonymous = json.bool("isAnonymous")
        adminRights = json.boolMap("adminRights")
        restrictions = json.boolMap("restrictions")
        restrictedUntil = json.string("restrictedUntil")
    }

    var roleLabel: String {
        switch role {
        case "owner":
            return "Владелец"
        case "admin":
            return adminTitle.ifBlank("Администратор")
        default:
            return ""
        }
    }
}

struct AloGroupBan: Identifiable, Equatable {
    let user: AloEntitySummary
    let reason: String
    let createdAt: String
    let expiresAt: String
    let bannedBy: AloEntitySummary

    var id: Int { user.id }

    init(_ json: [String: Any]) {
        user = AloEntitySummary(json.object("user"))
        reason = json.string("reason")
        createdAt = json.string("createdAt")
        expiresAt = json.string("expiresAt")
        bannedBy = AloEntitySummary(json.object("bannedBy"))
    }
}

struct AloGroupPolicy: Equatable {
    var kind: String
    var username: String
    var joinPolicy: String
    var isForum: Bool
    var historyVisible: Bool
    var slowModeSeconds: Int
    var autoDeleteSeconds: Int
    /// "Запретить копирование": no forwarding, copying or saving of this chat's messages.
    var protectedContent = false
    var defaultPermissions: [String: Bool]
    var memberAdminRights: [String: Bool]
    var memberRestrictions: [String: Bool]
    var memberRestrictedUntil: String

    var isChannel: Bool {
        kind == "channel"
    }

    var isForumGroup: Bool {
        !isChannel && isForum
    }

    init(_ json: [String: Any]) {
        let resolvedKind = json.string("kind")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "channel" ? "channel" : "group"
        kind = resolvedKind
        username = json.string("username")
        joinPolicy = json.string("joinPolicy").ifBlank("invite")
        isForum = resolvedKind == "group" && json.bool("isForum")
        historyVisible = (resolvedKind == "channel" || json["historyVisible"] == nil)
            ? true
            : json.bool("historyVisible")
        slowModeSeconds = resolvedKind == "channel" ? 0 : max(0, json.int("slowModeSeconds"))
        autoDeleteSeconds = max(0, json.int("autoDeleteSeconds"))
        protectedContent = json.bool("protectedContent")
        defaultPermissions = json.boolMap("defaultPermissions")
        memberAdminRights = json.boolMap("memberAdminRights")
        memberRestrictions = json.boolMap("memberRestrictions")
        memberRestrictedUntil = json.string("memberRestrictedUntil")
    }

    var requestBody: [String: Any] {
        let isChannel = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "channel"
        return [
            "username": username,
            "joinPolicy": joinPolicy,
            "isForum": isChannel ? false : isForum,
            "historyVisible": isChannel ? true : historyVisible,
            "slowModeSeconds": isChannel ? 0 : slowModeSeconds,
            "autoDeleteSeconds": autoDeleteSeconds,
            "protectedContent": protectedContent,
            "defaultPermissions": defaultPermissions
        ]
    }
}

struct AloGroupJoinRequest: Identifiable, Equatable {
    let user: AloEntitySummary
    let createdAt: String

    var id: Int { user.id }

    init(_ json: [String: Any]) {
        user = AloEntitySummary(json.object("user"))
        createdAt = json.string("createdAt")
    }
}

struct AloGroupInviteLink: Identifiable, Equatable {
    let id: Int
    let label: String
    let requiresApproval: Bool
    let usageLimit: Int
    let usageCount: Int
    let joinedCount: Int
    let pendingCount: Int
    let expiresAt: String
    let revokedAt: String
    let createdAt: String
    let creator: AloEntitySummary?

    init(_ json: [String: Any]) {
        id = json.int("id")
        label = json.string("label")
        requiresApproval = json.bool("requiresApproval")
        usageLimit = max(0, json.int("usageLimit"))
        usageCount = max(0, json.int("usageCount"))
        joinedCount = max(0, json.int("joinedCount"))
        pendingCount = max(0, json.int("pendingCount"))
        expiresAt = json.string("expiresAt")
        revokedAt = json.string("revokedAt")
        createdAt = json.string("createdAt")
        creator = json.optionalObject("creator").map(AloEntitySummary.init)
    }

    var isActive: Bool {
        guard revokedAt.isEmpty else { return false }
        guard !expiresAt.isEmpty else { return true }
        return (ISO8601DateFormatter().date(from: expiresAt) ?? .distantPast) > Date()
    }
}

struct AloGroupInviteParticipant: Identifiable, Equatable {
    let user: AloEntitySummary
    let createdAt: String

    var id: Int { user.id }

    init(_ json: [String: Any]) {
        user = AloEntitySummary(json.object("user"))
        createdAt = json.string("createdAt")
    }
}

struct AloGroupInviteStats: Equatable {
    let invite: AloGroupInviteLink
    let joined: [AloGroupInviteParticipant]
    let pending: [AloGroupInviteParticipant]

    init(_ json: [String: Any]) {
        invite = AloGroupInviteLink(json.object("invite"))
        joined = json.array("joined").map(AloGroupInviteParticipant.init)
        pending = json.array("pending").map(AloGroupInviteParticipant.init)
    }
}

struct AloForumTopic: Identifiable, Equatable {
    let id: Int
    let roomId: Int
    let title: String
    let iconEmoji: String
    let isGeneral: Bool
    let isClosed: Bool
    let isHidden: Bool
    let createdAt: String
    let updatedAt: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        roomId = json.int("roomId")
        title = json.string("title").ifBlank("Тема")
        iconEmoji = json.string("iconEmoji").ifBlank("💬")
        isGeneral = json.bool("isGeneral")
        isClosed = json.bool("isClosed")
        isHidden = json.bool("isHidden")
        createdAt = json.string("createdAt")
        updatedAt = json.string("updatedAt")
    }
}

struct AloForumTopicState: Identifiable, Equatable {
    let topicId: Int
    let cursor: Int
    let lastReadMessageId: Int
    let unreadCount: Int
    let muted: Bool
    let draftRevision: Int
    let stateVersion: Int
    let draftUpdatedAt: String
    let updatedAt: String
    let draftText: String

    var id: Int { topicId }

    init(_ json: [String: Any]) {
        topicId = json.int("topicId")
        cursor = max(0, json.int("cursor"))
        lastReadMessageId = max(0, json.int("lastReadMessageId"))
        unreadCount = max(0, json.int("unreadCount"))
        muted = json.bool("muted")
        draftRevision = max(0, json.int("draftRevision"))
        stateVersion = max(0, json.int("stateVersion"))
        draftUpdatedAt = json.string("draftUpdatedAt")
        updatedAt = json.string("updatedAt")
        draftText = json.string("draftText")
    }
}

struct AloGroupAdminEvent: Identifiable, Equatable {
    let id: Int
    let action: String
    let details: [String: AnyHashable]
    let createdAt: String
    let actor: AloEntitySummary
    let target: AloEntitySummary?

    init(_ json: [String: Any]) {
        id = json.int("id")
        action = json.string("action")
        details = json.object("details").reduce(into: [:]) { result, item in
            if let value = item.value as? AnyHashable {
                result[item.key] = value
            }
        }
        createdAt = json.string("createdAt")
        actor = AloEntitySummary(json.object("actor"))
        target = json.optionalObject("target").map(AloEntitySummary.init)
    }

    static func == (lhs: AloGroupAdminEvent, rhs: AloGroupAdminEvent) -> Bool {
        lhs.id == rhs.id &&
        lhs.action == rhs.action &&
        lhs.createdAt == rhs.createdAt &&
        lhs.actor == rhs.actor &&
        lhs.target == rhs.target
    }
}

struct AloGroupAdminLogPage {
    let events: [AloGroupAdminEvent]
    let nextBeforeId: Int?

    init(_ json: [String: Any]) {
        events = json.array("events").map(AloGroupAdminEvent.init)
        let cursor = json.int("nextBeforeId")
        nextBeforeId = cursor > 0 ? cursor : nil
    }
}

struct AloGroupManagementSnapshot {
    let policy: AloGroupPolicy
    let members: [AloGroupMember]
    let requests: [AloGroupJoinRequest]
    let invites: [AloGroupInviteLink]
    let events: [AloGroupAdminEvent]
    let topics: [AloForumTopic]
    let bans: [AloGroupBan]
    let nextAdminLogBeforeId: Int?

    init(
        policy: AloGroupPolicy,
        members: [AloGroupMember],
        requests: [AloGroupJoinRequest],
        invites: [AloGroupInviteLink],
        events: [AloGroupAdminEvent],
        topics: [AloForumTopic],
        bans: [AloGroupBan],
        nextAdminLogBeforeId: Int? = nil
    ) {
        self.policy = policy
        self.members = members
        self.requests = requests
        self.invites = invites
        self.events = events
        self.topics = topics
        self.bans = bans
        self.nextAdminLogBeforeId = nextAdminLogBeforeId
    }
}

struct AloGroupManagementDelta: Equatable {
    let revision: Int
    let policy: AloGroupPolicy?
    let membersUpserted: [AloGroupMember]
    let memberIdsRemoved: [Int]
    let requestsUpserted: [AloGroupJoinRequest]
    let requestUserIdsRemoved: [Int]
    let bansUpserted: [AloGroupBan]
    let banUserIdsRemoved: [Int]
    let invitesUpserted: [AloGroupInviteLink]
    let topicsUpserted: [AloForumTopic]
    let topicIdsRemoved: [Int]
    let adminEvent: AloGroupAdminEvent?

    init?(_ json: [String: Any], revision: Int) {
        guard json.int("version") == 1 else { return nil }
        self.revision = revision
        policy = json.optionalObject("policy").map(AloGroupPolicy.init)

        let memberChanges = json.array("members")
        membersUpserted = memberChanges.compactMap { change in
            guard change.string("operation") == "upsert" else { return nil }
            let value = change.object("value")
            return value.int("id") > 0 ? AloGroupMember(value) : nil
        }
        memberIdsRemoved = memberChanges.compactMap { change in
            guard change.string("operation") == "remove" else { return nil }
            let userId = change.int("userId")
            return userId > 0 ? userId : nil
        }

        let requestChanges = json.array("requests")
        requestsUpserted = requestChanges.compactMap { change in
            guard change.string("operation") == "upsert" else { return nil }
            let value = change.object("value")
            return value.object("user").int("id") > 0 ? AloGroupJoinRequest(value) : nil
        }
        requestUserIdsRemoved = requestChanges.compactMap { change in
            guard change.string("operation") == "remove" else { return nil }
            let userId = change.int("userId")
            return userId > 0 ? userId : nil
        }

        let banChanges = json.array("bans")
        bansUpserted = banChanges.compactMap { change in
            guard change.string("operation") == "upsert" else { return nil }
            let value = change.object("value")
            return value.object("user").int("id") > 0 ? AloGroupBan(value) : nil
        }
        banUserIdsRemoved = banChanges.compactMap { change in
            guard change.string("operation") == "remove" else { return nil }
            let userId = change.int("userId")
            return userId > 0 ? userId : nil
        }

        invitesUpserted = json.array("invites").compactMap { change in
            guard change.string("operation") == "upsert" else { return nil }
            let value = change.object("value")
            return value.int("id") > 0 ? AloGroupInviteLink(value) : nil
        }
        topicsUpserted = json.array("topics").compactMap { change in
            guard change.string("operation") == "upsert" else { return nil }
            let value = change.object("value")
            return value.int("id") > 0 ? AloForumTopic(value) : nil
        }
        topicIdsRemoved = json.array("topics").compactMap { change in
            guard change.string("operation") == "remove" else { return nil }
            let topicId = change.int("id")
            return topicId > 0 ? topicId : nil
        }
        adminEvent = json.optionalObject("adminEvent").flatMap { value in
            value.int("id") > 0 ? AloGroupAdminEvent(value) : nil
        }
    }
}

struct AloConversationSummary: Identifiable, Equatable {
    var id: Int { peerId }
    let peerId: Int
    let kind: String
    let roomId: Int
    let memberCount: Int
    let lastAt: String
    let lastBody: String
    let peer: AloConversationPeer
    /// Newest message in the chat and who sent it, as the server reports it. Used for the unread dot.
    let lastMessageId: Int
    let lastSenderId: Int
    /// Messages from the other side not read yet. `hasServerUnreadCount` is false on older servers.
    let unreadCount: Int
    /// Unread messages in a group that mention you: the chat list's "@".
    var unreadMentionCount = 0
    let hasServerUnreadCount: Bool

    init(_ json: [String: Any]) {
        peerId = json.int("peerId")
        kind = json.string("kind").ifBlank("direct")
        roomId = json.int("roomId")
        memberCount = json.int("memberCount")
        lastAt = json.string("lastAt")
        lastBody = json.string("lastBody")
        peer = AloConversationPeer(json.object("peer"))
        let last = json.object("lastMessage")
        lastMessageId = last.int("id")
        lastSenderId = last.int("senderId")
        unreadCount = max(0, json.int("unreadCount"))
        unreadMentionCount = max(0, json.int("unreadMentionCount"))
        hasServerUnreadCount = json["unreadCount"] != nil
    }

    init(
        peerId: Int,
        kind: String,
        roomId: Int,
        memberCount: Int,
        lastAt: String,
        lastBody: String,
        peer: AloConversationPeer,
        lastMessageId: Int = 0,
        lastSenderId: Int = 0,
        unreadCount: Int = 0,
        hasServerUnreadCount: Bool = false
    ) {
        self.peerId = peerId
        self.kind = kind
        self.roomId = roomId
        self.memberCount = memberCount
        self.lastAt = lastAt
        self.lastBody = lastBody
        self.peer = peer
        self.lastMessageId = lastMessageId
        self.lastSenderId = lastSenderId
        self.unreadCount = unreadCount
        self.hasServerUnreadCount = hasServerUnreadCount
    }
}

/// One finished call in the "Звонки" list.
struct AloCallHistoryItem: Identifiable, Equatable {
    enum Outcome: String { case completed, missed, cancelled, declined }
    let id: Int
    let isOutgoing: Bool
    let isVideo: Bool
    let outcome: Outcome
    let createdAt: String
    let durationSeconds: Int
    let peer: AloEntitySummary

    init(_ json: [String: Any]) {
        id = json.int("id")
        isOutgoing = json.string("direction") == "outgoing"
        isVideo = json.string("type") == "video"
        outcome = Outcome(rawValue: json.string("outcome")) ?? .completed
        createdAt = json.string("createdAt")
        durationSeconds = max(0, json.int("durationSeconds"))
        peer = AloEntitySummary(json.object("peer"))
    }

    /// Missed and declined incoming calls are shown in red, as in Telegram.
    var isMissed: Bool { !isOutgoing && (outcome == .missed || outcome == .declined) }
}

struct AloChatMessage: Identifiable, Equatable {
    let id: Int
    let senderId: Int
    let recipientId: Int
    let body: String
    let attachmentUrl: String
    let attachmentType: String
    let attachmentName: String
    let attachments: [AloMessageAttachment]
    let entities: [AloMessageTextEntity]
    let topicId: Int
    let replyToMessageId: Int
    let selfDestructSeconds: Int
    let selfDestructStartedAt: String
    let expiresAt: String
    let editedAt: String
    let readAt: String
    let forwardFrom: AloForwardMeta?
    let createdAt: String
    let reactions: [AloMessageReaction]
    let sender: AloConversationPeer?
    let senderIsAnonymous: Bool
    let senderAdminTitle: String
    let channelPostId: Int
    let channelPostCommentCount: Int
    let channelPostCommentsEnabled: Bool
    let scheduledMessageId: Int
    let scheduledAt: String
    let silent: Bool
    let sendWhenOnline: Bool
    let deliveryState: String
    let deliveryError: String

    var isScheduled: Bool {
        scheduledMessageId > 0 || sendWhenOnline || deliveryState == "scheduled"
    }

    init(_ json: [String: Any]) {
        id = json.int("id")
        senderId = json.int("senderId").ifZero(json.int("sender_id"))
        recipientId = json.int("recipientId").ifZero(json.int("recipient_id"))
        let rawBody = json.string("body")
        let explicitEntities = json.array("entities").compactMap(AloMessageTextEntity.init)
        let markup = explicitEntities.isEmpty ? AloMessageMarkup.parse(rawBody) : nil
        body = markup?.body ?? rawBody
        attachmentUrl = json.string("attachmentUrl")
        attachmentType = json.string("attachmentType")
        attachmentName = json.string("attachmentName")
        attachments = json.array("attachments").map(AloMessageAttachment.init)
        entities = AloMessageMarkup.normalized(
            markup?.entities ?? explicitEntities,
            utf16Length: body.utf16.count
        )
        topicId = max(0, json.int("topicId"))
        replyToMessageId = max(0, json.int("replyToMessageId"))
        selfDestructSeconds = max(0, json.int("selfDestructSeconds"))
        selfDestructStartedAt = json.string("selfDestructStartedAt")
        expiresAt = json.string("expiresAt")
        editedAt = json.string("editedAt")
        readAt = json.string("readAt")
        forwardFrom = json.optionalObject("forwardFrom").flatMap(AloForwardMeta.init)
        createdAt = json.string("createdAt")
        reactions = json.array("reactions").map(AloMessageReaction.init)
        sender = json.optionalObject("sender").map(AloConversationPeer.init)
        senderIsAnonymous = json.bool("senderIsAnonymous")
        senderAdminTitle = json.string("senderAdminTitle")
        channelPostId = max(0, json.int("channelPostId"))
        channelPostCommentCount = max(0, json.int("channelPostCommentCount"))
        channelPostCommentsEnabled = json.bool("channelPostCommentsEnabled")
        scheduledMessageId = max(0, json.int("scheduledMessageId"))
        scheduledAt = json.string("scheduledAt")
        silent = json.bool("silent")
        sendWhenOnline = json.bool("sendWhenOnline")
        deliveryState = json.string("deliveryState")
        deliveryError = json.string("deliveryError")
    }

    init(
        localId: Int,
        senderId: Int,
        recipientId: Int,
        body: String,
        topicId: Int = 0,
        replyToMessageId: Int = 0,
        createdAt: String,
        attachments: [AloMessageAttachment] = [],
        forwardFrom: AloForwardMeta? = nil,
        selfDestructSeconds: Int = 0,
        selfDestructStartedAt: String = "",
        expiresAt: String = "",
        scheduledAt: String = "",
        silent: Bool = false,
        sendWhenOnline: Bool = false
    ) {
        id = localId
        self.senderId = senderId
        self.recipientId = recipientId
        let markup = AloMessageMarkup.parse(body)
        self.body = markup.body
        attachmentUrl = attachments.first?.url ?? ""
        attachmentType = attachments.first?.type ?? ""
        attachmentName = attachments.first?.name ?? ""
        self.attachments = attachments
        entities = markup.entities
        self.topicId = max(0, topicId)
        self.replyToMessageId = max(0, replyToMessageId)
        self.selfDestructSeconds = max(0, selfDestructSeconds)
        self.selfDestructStartedAt = selfDestructStartedAt
        self.expiresAt = expiresAt
        editedAt = ""
        readAt = ""
        self.forwardFrom = forwardFrom
        self.createdAt = createdAt
        reactions = []
        sender = nil
        senderIsAnonymous = false
        senderAdminTitle = ""
        channelPostId = 0
        channelPostCommentCount = 0
        channelPostCommentsEnabled = false
        scheduledMessageId = 0
        self.scheduledAt = scheduledAt
        self.silent = silent
        self.sendWhenOnline = sendWhenOnline
        deliveryState = scheduledAt.isEmpty && !sendWhenOnline ? "" : "scheduled"
        deliveryError = ""
    }

    private init(
        id: Int,
        senderId: Int,
        recipientId: Int,
        body: String,
        attachmentUrl: String,
        attachmentType: String,
        attachmentName: String,
        attachments: [AloMessageAttachment],
        entities: [AloMessageTextEntity],
        topicId: Int,
        replyToMessageId: Int = 0,
        selfDestructSeconds: Int,
        selfDestructStartedAt: String,
        expiresAt: String,
        editedAt: String,
        readAt: String,
        forwardFrom: AloForwardMeta?,
        createdAt: String,
        reactions: [AloMessageReaction],
        sender: AloConversationPeer?,
        senderIsAnonymous: Bool = false,
        senderAdminTitle: String = "",
        channelPostId: Int = 0,
        channelPostCommentCount: Int = 0,
        channelPostCommentsEnabled: Bool = false,
        scheduledMessageId: Int = 0,
        scheduledAt: String = "",
        silent: Bool = false,
        sendWhenOnline: Bool = false,
        deliveryState: String = "",
        deliveryError: String = ""
    ) {
        self.id = id
        self.senderId = senderId
        self.recipientId = recipientId
        self.body = body
        self.attachmentUrl = attachmentUrl
        self.attachmentType = attachmentType
        self.attachmentName = attachmentName
        self.attachments = attachments
        self.entities = entities
        self.topicId = max(0, topicId)
        self.replyToMessageId = max(0, replyToMessageId)
        self.selfDestructSeconds = max(0, selfDestructSeconds)
        self.selfDestructStartedAt = selfDestructStartedAt
        self.expiresAt = expiresAt
        self.editedAt = editedAt
        self.readAt = readAt
        self.forwardFrom = forwardFrom
        self.createdAt = createdAt
        self.reactions = reactions
        self.sender = sender
        self.senderIsAnonymous = senderIsAnonymous
        self.senderAdminTitle = senderAdminTitle
        self.channelPostId = max(0, channelPostId)
        self.channelPostCommentCount = max(0, channelPostCommentCount)
        self.channelPostCommentsEnabled = channelPostCommentsEnabled
        self.scheduledMessageId = max(0, scheduledMessageId)
        self.scheduledAt = scheduledAt
        self.silent = silent
        self.sendWhenOnline = sendWhenOnline
        self.deliveryState = deliveryState
        self.deliveryError = deliveryError
    }

    func replacingReactions(_ reactions: [AloMessageReaction]) -> AloChatMessage {
        AloChatMessage(
            id: id,
            senderId: senderId,
            recipientId: recipientId,
            body: body,
            attachmentUrl: attachmentUrl,
            attachmentType: attachmentType,
            attachmentName: attachmentName,
            attachments: attachments,
            entities: entities,
            topicId: topicId,
            replyToMessageId: replyToMessageId,
            selfDestructSeconds: selfDestructSeconds,
            selfDestructStartedAt: selfDestructStartedAt,
            expiresAt: expiresAt,
            editedAt: editedAt,
            readAt: readAt,
            forwardFrom: forwardFrom,
            createdAt: createdAt,
            reactions: reactions,
            sender: sender,
            senderIsAnonymous: senderIsAnonymous,
            senderAdminTitle: senderAdminTitle,
            channelPostId: channelPostId,
            channelPostCommentCount: channelPostCommentCount,
            channelPostCommentsEnabled: channelPostCommentsEnabled,
            scheduledMessageId: scheduledMessageId,
            scheduledAt: scheduledAt,
            silent: silent,
            sendWhenOnline: sendWhenOnline,
            deliveryState: deliveryState,
            deliveryError: deliveryError
        )
    }

    func replacingBody(_ body: String, editedAt: String) -> AloChatMessage {
        let markup = AloMessageMarkup.parse(body)
        return AloChatMessage(
            id: id,
            senderId: senderId,
            recipientId: recipientId,
            body: markup.body,
            attachmentUrl: attachmentUrl,
            attachmentType: attachmentType,
            attachmentName: attachmentName,
            attachments: attachments,
            entities: markup.entities,
            topicId: topicId,
            replyToMessageId: replyToMessageId,
            selfDestructSeconds: selfDestructSeconds,
            selfDestructStartedAt: selfDestructStartedAt,
            expiresAt: expiresAt,
            editedAt: editedAt,
            readAt: readAt,
            forwardFrom: forwardFrom,
            createdAt: createdAt,
            reactions: reactions,
            sender: sender,
            senderIsAnonymous: senderIsAnonymous,
            senderAdminTitle: senderAdminTitle,
            channelPostId: channelPostId,
            channelPostCommentCount: channelPostCommentCount,
            channelPostCommentsEnabled: channelPostCommentsEnabled,
            scheduledMessageId: scheduledMessageId,
            scheduledAt: scheduledAt,
            silent: silent,
            sendWhenOnline: sendWhenOnline,
            deliveryState: deliveryState,
            deliveryError: deliveryError
        )
    }

    func acknowledgingDelivery(id: Int, createdAt: String) -> AloChatMessage {
        AloChatMessage(
            id: id > 0 ? id : self.id,
            senderId: senderId,
            recipientId: recipientId,
            body: body,
            attachmentUrl: attachmentUrl,
            attachmentType: attachmentType,
            attachmentName: attachmentName,
            attachments: attachments,
            entities: entities,
            topicId: topicId,
            replyToMessageId: replyToMessageId,
            selfDestructSeconds: selfDestructSeconds,
            selfDestructStartedAt: selfDestructStartedAt,
            expiresAt: expiresAt,
            editedAt: editedAt,
            readAt: readAt,
            forwardFrom: forwardFrom,
            createdAt: createdAt.isEmpty ? self.createdAt : createdAt,
            reactions: reactions,
            sender: sender,
            senderIsAnonymous: senderIsAnonymous,
            senderAdminTitle: senderAdminTitle,
            channelPostId: channelPostId,
            channelPostCommentCount: channelPostCommentCount,
            channelPostCommentsEnabled: channelPostCommentsEnabled,
            scheduledMessageId: scheduledMessageId,
            scheduledAt: scheduledAt,
            silent: silent,
            sendWhenOnline: sendWhenOnline,
            deliveryState: deliveryState,
            deliveryError: deliveryError
        )
    }

    func replacingSchedule(_ scheduledAt: String, silent: Bool? = nil) -> AloChatMessage {
        AloChatMessage(
            id: id,
            senderId: senderId,
            recipientId: recipientId,
            body: body,
            attachmentUrl: attachmentUrl,
            attachmentType: attachmentType,
            attachmentName: attachmentName,
            attachments: attachments,
            entities: entities,
            topicId: topicId,
            replyToMessageId: replyToMessageId,
            selfDestructSeconds: selfDestructSeconds,
            selfDestructStartedAt: selfDestructStartedAt,
            expiresAt: expiresAt,
            editedAt: editedAt,
            readAt: readAt,
            forwardFrom: forwardFrom,
            createdAt: createdAt,
            reactions: reactions,
            sender: sender,
            senderIsAnonymous: senderIsAnonymous,
            senderAdminTitle: senderAdminTitle,
            channelPostId: channelPostId,
            channelPostCommentCount: channelPostCommentCount,
            channelPostCommentsEnabled: channelPostCommentsEnabled,
            scheduledMessageId: scheduledMessageId,
            scheduledAt: scheduledAt,
            silent: silent ?? self.silent,
            sendWhenOnline: false,
            deliveryState: deliveryState,
            deliveryError: deliveryError
        )
    }

    var markupSource: String {
        AloMessageMarkup.source(body: body, entities: entities)
    }

    func replacingExpiry(startedAt: String, expiresAt: String) -> AloChatMessage {
        AloChatMessage(
            id: id,
            senderId: senderId,
            recipientId: recipientId,
            body: body,
            attachmentUrl: attachmentUrl,
            attachmentType: attachmentType,
            attachmentName: attachmentName,
            attachments: attachments,
            entities: entities,
            topicId: topicId,
            replyToMessageId: replyToMessageId,
            selfDestructSeconds: selfDestructSeconds,
            selfDestructStartedAt: startedAt,
            expiresAt: expiresAt,
            editedAt: editedAt,
            readAt: readAt,
            forwardFrom: forwardFrom,
            createdAt: createdAt,
            reactions: reactions,
            sender: sender,
            senderIsAnonymous: senderIsAnonymous,
            senderAdminTitle: senderAdminTitle,
            channelPostId: channelPostId,
            channelPostCommentCount: channelPostCommentCount,
            channelPostCommentsEnabled: channelPostCommentsEnabled,
            scheduledMessageId: scheduledMessageId,
            scheduledAt: scheduledAt,
            silent: silent,
            sendWhenOnline: sendWhenOnline,
            deliveryState: deliveryState,
            deliveryError: deliveryError
        )
    }

    func replacingMedia(
        attachments: [AloMessageAttachment],
        startedAt: String,
        expiresAt: String
    ) -> AloChatMessage {
        AloChatMessage(
            id: id,
            senderId: senderId,
            recipientId: recipientId,
            body: body,
            attachmentUrl: attachments.first?.url ?? attachmentUrl,
            attachmentType: attachments.first?.type ?? attachmentType,
            attachmentName: attachments.first?.name ?? attachmentName,
            attachments: attachments,
            entities: entities,
            topicId: topicId,
            replyToMessageId: replyToMessageId,
            selfDestructSeconds: selfDestructSeconds,
            selfDestructStartedAt: startedAt,
            expiresAt: expiresAt,
            editedAt: editedAt,
            readAt: readAt,
            forwardFrom: forwardFrom,
            createdAt: createdAt,
            reactions: reactions,
            sender: sender,
            senderIsAnonymous: senderIsAnonymous,
            senderAdminTitle: senderAdminTitle,
            channelPostId: channelPostId,
            channelPostCommentCount: channelPostCommentCount,
            channelPostCommentsEnabled: channelPostCommentsEnabled,
            scheduledMessageId: scheduledMessageId,
            scheduledAt: scheduledAt,
            silent: silent,
            sendWhenOnline: sendWhenOnline,
            deliveryState: deliveryState,
            deliveryError: deliveryError
        )
    }
}

struct AloMessageExpiryState: Equatable {
    let messageId: Int
    let selfDestructSeconds: Int
    let selfDestructStartedAt: String
    let expiresAt: String

    init(_ json: [String: Any]) {
        messageId = json.int("messageId")
        selfDestructSeconds = max(0, json.int("selfDestructSeconds"))
        selfDestructStartedAt = json.string("selfDestructStartedAt")
        expiresAt = json.string("expiresAt")
    }
}

extension AloChatMessage {
    var isCallLogMessage: Bool {
        if attachmentType == "call" {
            return true
        }
        return [attachmentName, body, attachmentUrl].contains { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.contains("\"kind\"") && value.contains("\"call\"") || value.contains("\"callType\"")
        }
    }
}

struct AloConversationDetail {
    let peerId: Int
    let kind: String
    let roomId: Int
    let entityType: String
    let title: String
    let subtitle: String
    let username: String
    let profileDescription: String
    let avatarUrl: String
    let canManageGroup: Bool
    let groupMemberRole: String
    let groupMembers: [AloGroupMember]
    let groupPolicy: AloGroupPolicy?
    let forumTopics: [AloForumTopic]
    let forumTopicStates: [AloForumTopicState]
    let pinnedMessageIds: [Int]
    let canonicalPolls: [String: AloCanonicalPollState]
    let online: Bool
    let lastSeenAt: String
    let isTyping: Bool
    /// "typing", "voice" or "circle" while `isTyping`; empty otherwise.
    let typingAction: String
    let items: [AloChatMessage]

    private static func membershipSubtitle(count: Int, isChannel: Bool) -> String {
        let normalizedCount = max(0, count)
        let mod10 = normalizedCount % 10
        let mod100 = normalizedCount % 100
        let label: String
        if isChannel {
            if mod10 == 1 && mod100 != 11 {
                label = "подписчик"
            } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
                label = "подписчика"
            } else {
                label = "подписчиков"
            }
        } else if mod10 == 1 && mod100 != 11 {
            label = "участник"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            label = "участника"
        } else {
            label = "участников"
        }
        return "\(normalizedCount) \(label)"
    }

    init(
        peerId: Int,
        kind: String,
        roomId: Int,
        entityType: String = "",
        title: String,
        subtitle: String,
        username: String = "",
        profileDescription: String = "",
        avatarUrl: String,
        canManageGroup: Bool = false,
        groupMemberRole: String = "",
        groupMembers: [AloGroupMember] = [],
        groupPolicy: AloGroupPolicy? = nil,
        forumTopics: [AloForumTopic] = [],
        forumTopicStates: [AloForumTopicState] = [],
        pinnedMessageIds: [Int] = [],
        canonicalPolls: [String: AloCanonicalPollState] = [:],
        online: Bool,
        lastSeenAt: String,
        isTyping: Bool = false,
        typingAction: String = "",
        items: [AloChatMessage]
    ) {
        self.peerId = peerId
        self.kind = kind
        self.roomId = roomId
        self.entityType = entityType
        self.title = title
        self.subtitle = subtitle
        self.username = username
        self.profileDescription = profileDescription
        self.avatarUrl = avatarUrl
        self.canManageGroup = canManageGroup
        self.groupMemberRole = groupMemberRole
        self.groupMembers = groupMembers
        self.groupPolicy = groupPolicy
        self.forumTopics = forumTopics
        self.forumTopicStates = forumTopicStates
        self.pinnedMessageIds = pinnedMessageIds
        self.canonicalPolls = canonicalPolls
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.isTyping = isTyping
        self.typingAction = typingAction
        self.items = items
    }

    init(summary: AloConversationSummary, items: [AloChatMessage]) {
        peerId = summary.peerId
        kind = summary.kind
        roomId = summary.roomId
        entityType = summary.peer.entityType
        title = summary.peer.entityType == "saved" ? "Избранное" : summary.peer.name
        subtitle = summary.peer.entityType == "saved"
            ? "Личное облако"
            : summary.kind == "group"
            ? Self.membershipSubtitle(
                count: summary.memberCount,
                isChannel: summary.peer.entityType == "channel"
            )
            : (summary.peer.online ? "в сети" : AloFormatters.lastSeenLabel(summary.peer.lastSeenAt))
        username = summary.peer.username
        profileDescription = ""
        avatarUrl = summary.peer.avatarUrl
        canManageGroup = false
        groupMemberRole = ""
        groupMembers = []
        groupPolicy = nil
        forumTopics = []
        forumTopicStates = []
        pinnedMessageIds = []
        canonicalPolls = [:]
        online = summary.peer.online
        lastSeenAt = summary.peer.lastSeenAt
        isTyping = false
        typingAction = ""
        self.items = items
    }

    init(peerId: Int, json: [String: Any]) {
        let peer = AloConversationPeer(json.object("peer"))
        let room = json.object("room")
        let parsedPolicy = room.isEmpty ? nil : AloGroupPolicy(room.object("policy"))
        let isChannel = parsedPolicy?.kind == "channel" || peer.entityType == "channel"
        self.peerId = peerId
        kind = room.isEmpty ? "direct" : "group"
        roomId = room.int("id")
        entityType = room.isEmpty ? peer.entityType : (isChannel ? "channel" : "group")
        title = peer.entityType == "saved" ? "Избранное" : room.string("title").ifBlank(peer.name)
        subtitle = peer.entityType == "saved"
            ? "Личное облако"
            : room.isEmpty
                ? (peer.online ? "в сети" : AloFormatters.lastSeenLabel(peer.lastSeenAt))
                : Self.membershipSubtitle(count: room.int("memberCount"), isChannel: isChannel)
        username = room.isEmpty ? peer.username : room.string("slug").ifBlank(room.object("policy").string("username"))
        profileDescription = room.string("description")
        avatarUrl = room.string("avatarEmoji").ifBlank(peer.avatarUrl)
        canManageGroup = room.bool("canManage")
        groupMemberRole = room.string("memberRole")
        groupMembers = room.array("members").map(AloGroupMember.init)
        groupPolicy = parsedPolicy
        // A channel cannot expose forum state. Discard stale data from cached
        // or older server payloads so it cannot reactivate topic UI locally.
        forumTopics = isChannel ? [] : room.array("topics").map(AloForumTopic.init)
        forumTopicStates = isChannel ? [] : room.array("topicStates").map(AloForumTopicState.init)
        let pinnedMessages = room.isEmpty ? json.array("pinnedMessages") : room.array("pinnedMessages")
        pinnedMessageIds = pinnedMessages.map { $0.int("id") }.filter { $0 > 0 }
        canonicalPolls = Dictionary(
            uniqueKeysWithValues: json.array("polls").map(AloCanonicalPollState.init).map { ($0.id, $0) }
        )
        online = peer.online
        lastSeenAt = peer.lastSeenAt
        isTyping = json.bool("typing") || json.bool("isTyping") || peer.isTyping
        typingAction = isTyping ? json.string("typingAction").ifBlank("typing") : ""
        items = json.array("items").map(AloChatMessage.init)
    }

    func replacingItems(_ items: [AloChatMessage]) -> AloConversationDetail {
        AloConversationDetail(
            peerId: peerId,
            kind: kind,
            roomId: roomId,
            entityType: entityType,
            title: title,
            subtitle: subtitle,
            username: username,
            profileDescription: profileDescription,
            avatarUrl: avatarUrl,
            canManageGroup: canManageGroup,
            groupMemberRole: groupMemberRole,
            groupMembers: groupMembers,
            groupPolicy: groupPolicy,
            forumTopics: forumTopics,
            forumTopicStates: forumTopicStates,
            pinnedMessageIds: pinnedMessageIds,
            canonicalPolls: canonicalPolls,
            online: online,
            lastSeenAt: lastSeenAt,
            isTyping: isTyping,
            typingAction: typingAction,
            items: items
        )
    }

    func replacingMessage(_ message: AloChatMessage) -> AloConversationDetail {
        AloConversationDetail(
            peerId: peerId,
            kind: kind,
            roomId: roomId,
            entityType: entityType,
            title: title,
            subtitle: subtitle,
            username: username,
            profileDescription: profileDescription,
            avatarUrl: avatarUrl,
            canManageGroup: canManageGroup,
            groupMemberRole: groupMemberRole,
            groupMembers: groupMembers,
            groupPolicy: groupPolicy,
            forumTopics: forumTopics,
            forumTopicStates: forumTopicStates,
            pinnedMessageIds: pinnedMessageIds,
            canonicalPolls: canonicalPolls,
            online: online,
            lastSeenAt: lastSeenAt,
            isTyping: isTyping,
            typingAction: typingAction,
            items: items.map { $0.id == message.id ? message : $0 }
        )
    }

    func replacingPinnedMessageIds(_ pinnedMessageIds: [Int]) -> AloConversationDetail {
        AloConversationDetail(
            peerId: peerId,
            kind: kind,
            roomId: roomId,
            entityType: entityType,
            title: title,
            subtitle: subtitle,
            username: username,
            profileDescription: profileDescription,
            avatarUrl: avatarUrl,
            canManageGroup: canManageGroup,
            groupMemberRole: groupMemberRole,
            groupMembers: groupMembers,
            groupPolicy: groupPolicy,
            forumTopics: forumTopics,
            forumTopicStates: forumTopicStates,
            pinnedMessageIds: pinnedMessageIds,
            canonicalPolls: canonicalPolls,
            online: online,
            lastSeenAt: lastSeenAt,
            isTyping: isTyping,
            typingAction: typingAction,
            items: items
        )
    }

    func replacingGroupState(
        policy: AloGroupPolicy? = nil,
        members: [AloGroupMember]? = nil
    ) -> AloConversationDetail {
        let resolvedMembers = members ?? groupMembers
        return AloConversationDetail(
            peerId: peerId,
            kind: kind,
            roomId: roomId,
            entityType: entityType,
            title: title,
            subtitle: kind == "group" && members != nil
                ? Self.membershipSubtitle(
                    count: resolvedMembers.count,
                    isChannel: entityType == "channel" || (policy ?? groupPolicy)?.kind == "channel"
                )
                : subtitle,
            username: username,
            profileDescription: profileDescription,
            avatarUrl: avatarUrl,
            canManageGroup: canManageGroup,
            groupMemberRole: groupMemberRole,
            groupMembers: resolvedMembers,
            groupPolicy: policy ?? groupPolicy,
            forumTopics: forumTopics,
            forumTopicStates: forumTopicStates,
            pinnedMessageIds: pinnedMessageIds,
            canonicalPolls: canonicalPolls,
            online: online,
            lastSeenAt: lastSeenAt,
            isTyping: isTyping,
            typingAction: typingAction,
            items: items
        )
    }

    func replacingGroupMemberCount(_ memberCount: Int) -> AloConversationDetail {
        AloConversationDetail(
            peerId: peerId,
            kind: kind,
            roomId: roomId,
            entityType: entityType,
            title: title,
            subtitle: kind == "group"
                ? Self.membershipSubtitle(
                    count: memberCount,
                    isChannel: entityType == "channel" || groupPolicy?.kind == "channel"
                )
                : subtitle,
            username: username,
            profileDescription: profileDescription,
            avatarUrl: avatarUrl,
            canManageGroup: canManageGroup,
            groupMemberRole: groupMemberRole,
            groupMembers: groupMembers,
            groupPolicy: groupPolicy,
            forumTopics: forumTopics,
            forumTopicStates: forumTopicStates,
            pinnedMessageIds: pinnedMessageIds,
            canonicalPolls: canonicalPolls,
            online: online,
            lastSeenAt: lastSeenAt,
            isTyping: isTyping,
            typingAction: typingAction,
            items: items
        )
    }

    func replacingForumTopicState(_ state: AloForumTopicState) -> AloConversationDetail {
        var states = forumTopicStates.filter { $0.topicId != state.topicId }
        states.append(state)
        states.sort { $0.topicId < $1.topicId }
        return AloConversationDetail(
            peerId: peerId,
            kind: kind,
            roomId: roomId,
            entityType: entityType,
            title: title,
            subtitle: subtitle,
            username: username,
            profileDescription: profileDescription,
            avatarUrl: avatarUrl,
            canManageGroup: canManageGroup,
            groupMemberRole: groupMemberRole,
            groupMembers: groupMembers,
            groupPolicy: groupPolicy,
            forumTopics: forumTopics,
            forumTopicStates: states,
            pinnedMessageIds: pinnedMessageIds,
            canonicalPolls: canonicalPolls,
            online: online,
            lastSeenAt: lastSeenAt,
            isTyping: isTyping,
            typingAction: typingAction,
            items: items
        )
    }
}

struct AloProfileStats: Equatable {
    let friends: Int
    let followers: Int
    let following: Int
    let channels: Int

    init(_ json: [String: Any]) {
        friends = json.int("friendsCount")
        followers = json.int("followersCount")
        following = json.int("followingCount")
        channels = json.int("channelsOwnedCount") + json.int("channelsSubscribedCount")
    }
}

struct AloProfileRelation: Equatable {
    let following: Bool
    let followedBy: Bool
    let isFriend: Bool
    let friendStatus: String
    let incomingRequestId: Int
    let outgoingRequestId: Int

    init(_ json: [String: Any]) {
        following = json.bool("following")
        followedBy = json.bool("followedBy") || json.bool("followsYou")
        isFriend = json.bool("isFriend")
        friendStatus = json.string("friendStatus").ifBlank(isFriend ? "friends" : "none")
        incomingRequestId = json.int("incomingRequestId")
        outgoingRequestId = json.int("outgoingRequestId")
    }
}

struct AloProfilePermissions: Equatable {
    let canMessage: Bool
    let canViewContent: Bool
    let isPrivate: Bool
    let profileVisibility: String
    let canSendFriendRequest: Bool

    init(_ json: [String: Any]) {
        canMessage = json.bool("canMessage")
        canViewContent = json.bool("canViewContent")
        isPrivate = json.bool("isPrivate")
        profileVisibility = json.string("profileVisibility")
        canSendFriendRequest = json.bool("canSendFriendRequest")
    }
}

enum AloBlockedUserList {
    static func userIds(from response: [String: Any]) -> Set<Int> {
        let data = response.object("data")
        var userIds = Set<Int>()
        let values: [Any?] = [
            response["blocks"],
            response["blockedUsers"],
            response["blockedUserIds"],
            response["userIds"],
            response["users"],
            data["blocks"],
            data["blockedUsers"],
            data["blockedUserIds"],
            data["userIds"],
            data["users"]
        ]
        values.forEach { appendUserIds(from: $0, into: &userIds) }
        return userIds
    }

    private static func appendUserIds(from value: Any?, into userIds: inout Set<Int>) {
        switch value {
        case let userId as Int:
            if userId > 0 { userIds.insert(userId) }
        case let number as NSNumber:
            if number.intValue > 0 { userIds.insert(number.intValue) }
        case let userId as String:
            if let userId = Int(userId.trimmingCharacters(in: .whitespacesAndNewlines)), userId > 0 {
                userIds.insert(userId)
            }
        case let item as [String: Any]:
            if let userId = item["userId"] ?? item["blockedUserId"] ?? item["peerId"] {
                appendUserIds(from: userId, into: &userIds)
            } else if let user = item["user"] {
                appendUserIds(from: user, into: &userIds)
            } else {
                appendUserIds(from: item["id"], into: &userIds)
            }
        case let values as [Any]:
            values.forEach { appendUserIds(from: $0, into: &userIds) }
        default:
            break
        }
    }
}

enum AloDirectContactPolicy {
    static let unavailableMessage = "Сообщения и звонки недоступны: пользователь заблокирован."

    static func isBlockedDirectPeer(
        kind: String,
        peerId: Int,
        blockedUserIds: Set<Int>
    ) -> Bool {
        kind == "direct" && peerId > 0 && blockedUserIds.contains(peerId)
    }
}

struct AloPrivacySettings: Equatable {
    let allowFriendRequests: Bool
    let messageScope: String
    let allowMessageForwards: Bool
    let callScope: String
    let profileVisibility: String
    let hideActivity: Bool

    init(
        allowFriendRequests: Bool,
        messageScope: String,
        allowMessageForwards: Bool,
        callScope: String,
        profileVisibility: String,
        hideActivity: Bool
    ) {
        self.allowFriendRequests = allowFriendRequests
        self.messageScope = messageScope
        self.allowMessageForwards = allowMessageForwards
        self.callScope = callScope
        self.profileVisibility = profileVisibility
        self.hideActivity = hideActivity
    }

    init(_ json: [String: Any]) {
        allowFriendRequests = json.bool("allowFriendRequests")
        messageScope = json.string("messageScope").ifBlank("all")
        allowMessageForwards = json["allowMessageForwards"] == nil ? true : json.bool("allowMessageForwards")
        callScope = json.string("callScope").ifBlank("all")
        profileVisibility = json.string("profileVisibility").ifBlank("all")
        hideActivity = json.bool("hideActivity")
    }

    static let `default` = AloPrivacySettings([
        "allowFriendRequests": true,
        "messageScope": "all",
        "allowMessageForwards": true,
        "callScope": "all",
        "profileVisibility": "all",
        "hideActivity": false
    ])

    var requestBody: [String: Any] {
        [
            "allowFriendRequests": allowFriendRequests,
            "messageScope": messageScope,
            "allowMessageForwards": allowMessageForwards,
            "callScope": callScope,
            "profileVisibility": profileVisibility,
            "hideActivity": hideActivity
        ]
    }
}

struct AloNotificationSettings: Equatable {
    var likesEnabled: Bool
    var commentsEnabled: Bool
    var repostsEnabled: Bool
    var followsEnabled: Bool
    var messagesEnabled: Bool
    var friendRequestsEnabled: Bool
    var friendAcceptsEnabled: Bool
    var channelSubscriptionsEnabled: Bool
    var commentLikesEnabled: Bool

    init(
        likesEnabled: Bool,
        commentsEnabled: Bool,
        repostsEnabled: Bool,
        followsEnabled: Bool,
        messagesEnabled: Bool,
        friendRequestsEnabled: Bool,
        friendAcceptsEnabled: Bool,
        channelSubscriptionsEnabled: Bool,
        commentLikesEnabled: Bool
    ) {
        self.likesEnabled = likesEnabled
        self.commentsEnabled = commentsEnabled
        self.repostsEnabled = repostsEnabled
        self.followsEnabled = followsEnabled
        self.messagesEnabled = messagesEnabled
        self.friendRequestsEnabled = friendRequestsEnabled
        self.friendAcceptsEnabled = friendAcceptsEnabled
        self.channelSubscriptionsEnabled = channelSubscriptionsEnabled
        self.commentLikesEnabled = commentLikesEnabled
    }

    init(_ json: [String: Any]) {
        likesEnabled = json["likesEnabled"] == nil ? true : json.bool("likesEnabled")
        commentsEnabled = json["commentsEnabled"] == nil ? true : json.bool("commentsEnabled")
        repostsEnabled = json["repostsEnabled"] == nil ? true : json.bool("repostsEnabled")
        followsEnabled = json["followsEnabled"] == nil ? true : json.bool("followsEnabled")
        messagesEnabled = json["messagesEnabled"] == nil ? true : json.bool("messagesEnabled")
        friendRequestsEnabled = json["friendRequestsEnabled"] == nil ? true : json.bool("friendRequestsEnabled")
        friendAcceptsEnabled = json["friendAcceptsEnabled"] == nil ? true : json.bool("friendAcceptsEnabled")
        channelSubscriptionsEnabled = json["channelSubscriptionsEnabled"] == nil ? true : json.bool("channelSubscriptionsEnabled")
        commentLikesEnabled = json["commentLikesEnabled"] == nil ? true : json.bool("commentLikesEnabled")
    }

    static let `default` = AloNotificationSettings([:])

    var requestBody: [String: Any] {
        [
            "likesEnabled": likesEnabled,
            "commentsEnabled": commentsEnabled,
            "repostsEnabled": repostsEnabled,
            "followsEnabled": followsEnabled,
            "messagesEnabled": messagesEnabled,
            "friendRequestsEnabled": friendRequestsEnabled,
            "friendAcceptsEnabled": friendAcceptsEnabled,
            "channelSubscriptionsEnabled": channelSubscriptionsEnabled,
            "commentLikesEnabled": commentLikesEnabled
        ]
    }
}

struct AloSecuritySession: Identifiable, Equatable {
    let id: Int
    let current: Bool
    let canRevoke: Bool
    let revokeAvailableAt: String
    let createdAt: String
    let lastSeenAt: String
    let expiresAt: String
    let ip: String
    let isSuspicious: Bool
    let deviceLabel: String
    let platform: String
    let deviceType: String

    init(_ json: [String: Any]) {
        let device = json.object("device")
        let parsedCurrent = json.bool("current")
        id = json.int("id")
        current = parsedCurrent
        canRevoke = parsedCurrent || (json["canRevoke"] as? Bool ?? true)
        revokeAvailableAt = json.string("revokeAvailableAt")
        createdAt = json.string("createdAt")
        lastSeenAt = json.string("lastSeenAt")
        expiresAt = json.string("expiresAt")
        ip = json.string("ip")
        isSuspicious = json.bool("isSuspicious")
        deviceLabel = device.string("label").ifBlank("Неизвестное устройство")
        platform = device.string("platform")
        deviceType = device.string("deviceType")
    }
}

struct AloSecurityEvent: Identifiable, Equatable {
    let id: Int
    let eventType: String
    let riskLevel: String
    let ip: String
    let createdAt: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        eventType = json.string("eventType")
        riskLevel = json.string("riskLevel")
        ip = json.string("ip")
        createdAt = json.string("createdAt")
    }
}

struct AloPasskeyStatus: Equatable {
    let configured: Bool
    let credentialCount: Int
    let relyingPartyID: String
    let lastUsedAt: String

    init(_ json: [String: Any]) {
        let value = json.object("passkey").isEmpty ? json : json.object("passkey")
        configured = value.bool("configured") || value.bool("isConfigured") || value.int("credentialCount") > 0
        credentialCount = max(0, value.int("credentialCount"))
        relyingPartyID = value.string("relyingPartyId").ifBlank(value.string("rpId"))
        lastUsedAt = value.string("lastUsedAt")
    }
}

struct AloPasskeyRegistrationOptions: Equatable {
    let challenge: String
    let relyingPartyID: String
    let userID: String
    let userName: String
    let userDisplayName: String
    let userVerification: String
    let excludedCredentialIDs: [String]

    init(_ json: [String: Any]) {
        let value = json.object("options").isEmpty ? json : json.object("options")
        challenge = value.string("challenge")
        relyingPartyID = value.string("relyingPartyId").ifBlank(value.string("rpId"))
        userID = value.string("userId")
        userName = value.string("userName")
        userDisplayName = value.string("userDisplayName").ifBlank(userName)
        userVerification = value.string("userVerification").ifBlank("preferred")
        excludedCredentialIDs = AloPasskeyRegistrationOptions.credentialIDs(
            value["excludedCredentialIds"] ?? value["excludeCredentials"]
        )
    }

    private static func credentialIDs(_ raw: Any?) -> [String] {
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { value in
            if let id = value as? String { return id }
            return (value as? [String: Any])?.string("id")
        }.filter { !$0.isEmpty }
    }
}

struct AloPasskeyAssertionOptions: Equatable {
    let challenge: String
    let relyingPartyID: String
    let userVerification: String
    let allowedCredentialIDs: [String]

    init(_ json: [String: Any]) {
        let value = json.object("options").isEmpty ? json : json.object("options")
        challenge = value.string("challenge")
        relyingPartyID = value.string("relyingPartyId").ifBlank(value.string("rpId"))
        userVerification = value.string("userVerification").ifBlank("preferred")
        allowedCredentialIDs = AloPasskeyAssertionOptions.credentialIDs(
            value["allowedCredentialIds"] ?? value["allowCredentials"]
        )
    }

    private static func credentialIDs(_ raw: Any?) -> [String] {
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { value in
            if let id = value as? String { return id }
            return (value as? [String: Any])?.string("id")
        }.filter { !$0.isEmpty }
    }
}

struct AloQRCodeLoginRequest: Equatable {
    let requestID: String
    let payload: String
    let expiresAt: String

    init(_ json: [String: Any]) {
        let value = json.object("request").isEmpty ? json : json.object("request")
        requestID = value.string("requestId").ifBlank(value.string("id"))
        payload = value.string("qrPayload").ifBlank(value.string("payload"))
        expiresAt = value.string("expiresAt")
    }
}

struct AloQRCodeLoginStatus: Equatable {
    let status: String
    let expiresAt: String
    /// Device link only: the new device has scanned the code and waits for the owner's confirmation.
    let claimed: Bool

    init(_ json: [String: Any]) {
        let value = json.object("request").isEmpty ? json : json.object("request")
        status = value.string("status").lowercased()
        expiresAt = value.string("expiresAt")
        claimed = value.bool("claimed")
    }

    var isApproved: Bool {
        status == "approved"
    }

    var isTerminalFailure: Bool {
        ["expired", "cancelled", "canceled", "rejected", "consumed"].contains(status)
    }
}

/// A downloaded account export stored only in the app's protected cache until
/// the person explicitly shares or saves it. The server returns the actual
/// JSON attachment, not an asynchronous export job.
struct AloDataExportFile: Identifiable, Equatable {
    let fileURL: URL
    let fileName: String
    let mimeType: String

    var id: String { fileURL.path }
}

struct AloUserProfile: Identifiable, Equatable {
    let id: Int
    let user: AloCurrentUser
    let stats: AloProfileStats
    let posts: [AloPost]
    let likes: [AloPost]
    let relation: AloProfileRelation
    let permissions: AloProfilePermissions

    init(
        id: Int,
        user: AloCurrentUser,
        stats: AloProfileStats,
        posts: [AloPost],
        likes: [AloPost],
        relation: AloProfileRelation,
        permissions: AloProfilePermissions
    ) {
        self.id = id
        self.user = user
        self.stats = stats
        self.posts = posts
        self.likes = likes
        self.relation = relation
        self.permissions = permissions
    }

    init(_ json: [String: Any]) {
        let profile = json.object("profile")
        user = AloCurrentUser(profile.object("user"))
        id = user.id
        stats = AloProfileStats(profile.object("stats"))
        posts = profile.array("posts").map(AloPost.init)
        likes = profile.array("likes").map(AloPost.init)
        relation = AloProfileRelation(profile.object("relation"))
        permissions = AloProfilePermissions(profile.object("permissions"))
    }
}

struct AloChannelAdminEvent: Identifiable, Equatable {
    let id: Int
    let action: String
    let postId: Int?
    let createdAt: String
    let actor: AloEntitySummary
    let target: AloEntitySummary?

    init(_ json: [String: Any]) {
        id = json.int("id")
        action = json.string("action")
        let rawPostId = json.int("postId")
        postId = rawPostId > 0 ? rawPostId : nil
        createdAt = json.string("createdAt")
        actor = AloEntitySummary(json.object("actor"))
        target = json.optionalObject("target").map(AloEntitySummary.init)
    }
}

struct AloChannelManagementDelta: Equatable {
    struct Settings: Equatable {
        let commentsEnabled: Bool
        let signMessages: Bool
        let showAuthorProfiles: Bool
        let discussionRoomId: Int?
    }

    let moderatorCount: Int
    let settings: Settings?
    let adminEvent: AloChannelAdminEvent?

    init?(_ json: [String: Any]) {
        guard json.int("version") == 1 else { return nil }
        moderatorCount = max(0, json.int("moderatorCount"))
        settings = json.optionalObject("settings").map { value in
            let roomId = value.int("discussionRoomId")
            return Settings(
                commentsEnabled: value.bool("commentsEnabled"),
                signMessages: value.bool("signMessages"),
                showAuthorProfiles: value.bool("showAuthorProfiles"),
                discussionRoomId: roomId > 0 ? roomId : nil
            )
        }
        adminEvent = json.optionalObject("adminEvent").flatMap { value in
            value.int("id") > 0 ? AloChannelAdminEvent(value) : nil
        }
    }
}

struct AloChannelProfile: Identifiable, Equatable {
    let id: Int
    let name: String
    let username: String
    let description: String
    let avatarUrl: String
    let coverImageUrl: String
    let verified: Bool
    let subscribersCount: Int
    let postsCount: Int
    let posts: [AloPost]
    let canManage: Bool
    let isOwner: Bool
    let commentsEnabled: Bool
    let signMessages: Bool
    let showAuthorProfiles: Bool
    let discussionRoomId: Int?

    init(_ json: [String: Any]) {
        let profile = json.object("profile")
        let channel = profile.object("channel")
        let stats = profile.object("stats")
        id = channel.int("id")
        name = channel.string("name").ifBlank("Сообщество")
        username = channel.string("username").ifBlank(channel.string("slug"))
        description = channel.string("description")
        avatarUrl = channel.string("avatarUrl").ifBlank(channel.string("avatarEmoji"))
        coverImageUrl = channel.string("coverImageUrl")
        verified = channel.bool("verified")
        subscribersCount = stats.int("subscribersCount")
        postsCount = stats.int("postsCount")
        posts = profile.array("posts").map(AloPost.init)
        canManage = channel.bool("canManage")
        isOwner = channel.bool("isOwner")
        commentsEnabled = channel["commentsEnabled"] == nil
            ? true
            : channel.bool("commentsEnabled")
        signMessages = channel.bool("signMessages")
        showAuthorProfiles = channel.bool("showAuthorProfiles")
        let rawDiscussionRoomId = channel.int("discussionRoomId")
        discussionRoomId = rawDiscussionRoomId > 0 ? rawDiscussionRoomId : nil
    }

    init(
        id: Int,
        name: String,
        username: String,
        description: String,
        avatarUrl: String,
        coverImageUrl: String,
        verified: Bool,
        subscribersCount: Int,
        postsCount: Int,
        posts: [AloPost],
        canManage: Bool,
        isOwner: Bool,
        commentsEnabled: Bool,
        signMessages: Bool,
        showAuthorProfiles: Bool,
        discussionRoomId: Int?
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.description = description
        self.avatarUrl = avatarUrl
        self.coverImageUrl = coverImageUrl
        self.verified = verified
        self.subscribersCount = subscribersCount
        self.postsCount = postsCount
        self.posts = posts
        self.canManage = canManage
        self.isOwner = isOwner
        self.commentsEnabled = commentsEnabled
        self.signMessages = signMessages
        self.showAuthorProfiles = showAuthorProfiles
        self.discussionRoomId = discussionRoomId
    }
}

struct AloBootstrapData {
    let me: AloCurrentUser
    let feedPopular: [AloPost]
    let feedSubscriptions: [AloPost]
    let notifications: [AloNotificationItem]
    let notificationSettings: AloNotificationSettings
    let searchUsers: [AloEntitySummary]
    let searchChannels: [AloEntitySummary]
    let profileStats: AloProfileStats
    let profilePosts: [AloPost]
    let privacySettings: AloPrivacySettings
    let conversations: [AloConversationSummary]
    let activePeerId: Int
    let activeMessages: [AloChatMessage]

    init(
        me: AloCurrentUser,
        feedPopular: [AloPost],
        feedSubscriptions: [AloPost],
        notifications: [AloNotificationItem],
        notificationSettings: AloNotificationSettings,
        searchUsers: [AloEntitySummary],
        searchChannels: [AloEntitySummary],
        profileStats: AloProfileStats,
        profilePosts: [AloPost],
        privacySettings: AloPrivacySettings,
        conversations: [AloConversationSummary],
        activePeerId: Int,
        activeMessages: [AloChatMessage]
    ) {
        self.me = me
        self.feedPopular = feedPopular
        self.feedSubscriptions = feedSubscriptions
        self.notifications = notifications
        self.notificationSettings = notificationSettings
        self.searchUsers = searchUsers
        self.searchChannels = searchChannels
        self.profileStats = profileStats
        self.profilePosts = profilePosts
        self.privacySettings = privacySettings
        self.conversations = conversations
        self.activePeerId = activePeerId
        self.activeMessages = activeMessages
    }

    init(_ json: [String: Any]) {
        let data = json.object("data")
        let feed = data.object("feed")
        let search = data.object("search")
        let profile = data.object("profile")
        let messages = data.object("messages")
        me = AloCurrentUser(data.object("me"))
        feedPopular = feed.array("popular").map(AloPost.init)
        feedSubscriptions = feed.array("subs").map(AloPost.init)
        notifications = data.array("notifications").map(AloNotificationItem.init)
        notificationSettings = AloNotificationSettings(data.object("notificationSettings"))
        searchUsers = search.array("users").map(AloEntitySummary.init)
        searchChannels = search.array("channels").map(AloEntitySummary.init)
        profileStats = AloProfileStats(profile.object("stats"))
        profilePosts = profile.array("posts").map(AloPost.init)
        privacySettings = AloPrivacySettings(data.object("privacySettings"))
        conversations = messages.array("conversations").map(AloConversationSummary.init)
        activePeerId = messages.int("activePeerId")
        activeMessages = messages.array("items").map(AloChatMessage.init)
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String {
        if let value = self[key] as? String { return value }
        if let value = self[key] { return String(describing: value) }
        return ""
    }

    func int(_ key: String) -> Int {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? String { return Int(value) ?? 0 }
        return 0
    }

    func bool(_ key: String) -> Bool {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? Int { return value != 0 }
        if let value = self[key] as? String { return value == "true" || value == "1" }
        return false
    }

    func object(_ key: String) -> [String: Any] {
        self[key] as? [String: Any] ?? [:]
    }

    func optionalObject(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func array(_ key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }

    func boolMap(_ key: String) -> [String: Bool] {
        object(key).reduce(into: [:]) { result, item in
            if let value = item.value as? Bool {
                result[item.key] = value
            } else if let value = item.value as? Int {
                result[item.key] = value != 0
            }
        }
    }
}

extension String {
    func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }

    var withAtPrefix: String {
        isEmpty ? "" : "@\(self)"
    }
}

extension Int {
    func ifZero(_ fallback: Int) -> Int {
        self == 0 ? fallback : self
    }
}

enum AloFormatters {
    static func lastSeenLabel(_ raw: String) -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "был(а) недавно"
        }
        guard let date = parseIsoDate(raw) else {
            return raw
        }

        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) {
            return "был(а) сегодня в \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "был(а) вчера в \(time)"
        }
        return "был(а) \(dayMonthFormatter.string(from: date)) в \(time)"
    }

    static func messageTime(_ raw: String) -> String {
        guard let date = parseIsoDate(raw) else {
            return String(raw.prefix(16))
        }
        return timeFormatter.string(from: date)
    }

    static func messageDateLabel(_ raw: String) -> String {
        guard let date = parseIsoDate(raw) else {
            return String(raw.prefix(10))
        }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Сегодня"
        }
        if calendar.isDateInYesterday(date) {
            return "Вчера"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return messageDayMonthFormatter.string(from: date)
        }
        return messageFullDateFormatter.string(from: date)
    }

    static func messageDayKey(_ raw: String) -> String {
        guard let date = parseIsoDate(raw) else {
            return String(raw.prefix(10))
        }
        return messageDayKeyFormatter.string(from: date)
    }

    private static func parseIsoDate(_ raw: String) -> Date? {
        if let cached = parsedDateCache.object(forKey: raw as NSString) { return cached as Date }
        guard let date = isoDateFormatter.date(from: raw) ?? isoDateFormatterWithoutFraction.date(from: raw) else { return nil }
        parsedDateCache.setObject(date as NSDate, forKey: raw as NSString)
        return date
    }

    // Cache instants, not labels; local calendar/time-zone formatting stays live.
    private static let parsedDateCache: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>()
        cache.countLimit = 2_048
        return cache
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateFormatterWithoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

    private static let messageDayMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return formatter
    }()

    private static let messageFullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        return formatter
    }()

    private static let messageDayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
