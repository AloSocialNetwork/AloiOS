import Foundation

// The reader's side of the feed: why a post is shown, hiding it, reports, drafts and a
// creator's statistics.

/// Why the server put a post in the feed (from the feed's ranking).
enum AloFeedReason: String {
    case own
    case ownChannel = "own_channel"
    case subscribedChannel = "subscribed_channel"
    case friend
    case popular
}

enum AloFeedHideReason: String {
    case hide
    case notInterested = "not_interested"
    case report

    var notice: String {
        switch self {
        case .hide: return "Публикация скрыта"
        case .notInterested: return "Будем реже показывать такие публикации"
        case .report: return "Спасибо! Жалоба отправлена модераторам"
        }
    }
}

/// What a report is about. The server keeps the reason as text, in Russian, for moderators.
enum AloReportTarget: Identifiable, Equatable {
    case post(Int)
    case comment(Int)
    case user(Int)

    var id: String { "\(type)-\(targetId)" }
    var type: String {
        switch self {
        case .post: return "post"
        case .comment: return "comment"
        case .user: return "user"
        }
    }
    var targetId: Int {
        switch self {
        case let .post(id), let .comment(id), let .user(id): return id
        }
    }
    var title: String {
        switch self {
        case .post: return "Жалоба на публикацию"
        case .comment: return "Жалоба на комментарий"
        case .user: return "Жалоба на пользователя"
        }
    }
}

/// Telegram's report reasons.
enum AloReportReason: String, CaseIterable, Identifiable {
    case spam, violence, childAbuse, pornography, copyright, personalData, illegalGoods, fraud, other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .spam: return "Спам"
        case .violence: return "Насилие"
        case .childAbuse: return "Жестокое обращение с детьми"
        case .pornography: return "Порнография"
        case .copyright: return "Нарушение авторских прав"
        case .personalData: return "Личные данные"
        case .illegalGoods: return "Незаконные товары"
        case .fraud: return "Мошенничество"
        case .other: return "Другое"
        }
    }
    var symbol: String {
        switch self {
        case .spam: return "envelope.badge"
        case .violence: return "hand.raised.slash"
        case .childAbuse: return "figure.and.child.holdinghands"
        case .pornography: return "eye.slash"
        case .copyright: return "c.circle"
        case .personalData: return "person.text.rectangle"
        case .illegalGoods: return "pills"
        case .fraud: return "exclamationmark.shield"
        case .other: return "ellipsis.bubble"
        }
    }
}

struct AloPostDraft: Identifiable, Equatable {
    let id: Int
    let body: String
    let media: [AloMediaItem]
    let createdAt: String
    let updatedAt: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        body = json.string("body")
        media = json.array("media").map(AloMediaItem.init)
        createdAt = json.string("createdAt")
        updatedAt = json.string("updatedAt")
    }

    init(id: Int, body: String, media: [AloMediaItem] = [], updatedAt: String) {
        self.id = id
        self.body = body
        self.media = media
        createdAt = updatedAt
        self.updatedAt = updatedAt
    }
}

extension AloMediaItem {
    /// The server's media item, for media that is already uploaded (a draft's).
    var payload: [String: Any] {
        var value: [String: Any] = ["type": type, "url": url]
        if !posterUrl.isEmpty { value["poster"] = posterUrl }
        if !caption.isEmpty { value["caption"] = caption }
        if let dimensions {
            value["width"] = Int(dimensions.width.rounded())
            value["height"] = Int(dimensions.height.rounded())
        }
        return value
    }

    init(uploaded attachment: AloMessageAttachment, dimensions: AloMediaDimensions?) {
        self.init(type: attachment.type, url: attachment.url, posterUrl: attachment.posterUrl, dimensions: dimensions)
    }
}

struct AloCreatorStats: Equatable {
    struct Metric: Equatable {
        let current: Int
        let previous: Int

        init(_ json: [String: Any]) {
            current = json.int("current")
            previous = json.int("previous")
        }

        init(current: Int, previous: Int) {
            self.current = current
            self.previous = previous
        }

        /// Change against the period before, in percent; nil when there is nothing to compare with.
        var change: Double? {
            guard previous > 0 else { return current > 0 ? nil : 0 }
            return (Double(current) - Double(previous)) / Double(previous) * 100
        }
    }

    struct Day: Equatable, Identifiable {
        let date: String
        let views: Int
        let likes: Int
        let comments: Int
        var id: String { date }

        var day: Date {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: date) ?? Date()
        }
    }

    struct AllTime: Equatable {
        let posts: Int
        let views: Int
        let likes: Int
        let comments: Int
        let reposts: Int
        let followers: Int
    }

    let days: Int
    let views: Metric
    let likes: Metric
    let comments: Metric
    let reposts: Metric
    let followers: Metric
    let engagementRate: Double
    let postsInPeriod: Int
    let allTime: AllTime
    let daily: [Day]
    let topPosts: [AloPost]

    init(_ json: [String: Any]) {
        days = json.int("days")
        views = Metric(json.object("views"))
        likes = Metric(json.object("likes"))
        comments = Metric(json.object("comments"))
        reposts = Metric(json.object("reposts"))
        followers = Metric(json.object("followers"))
        engagementRate = (json["engagementRate"] as? Double) ?? Double(json.int("engagementRate"))
        postsInPeriod = json.int("postsInPeriod")
        let all = json.object("allTime")
        allTime = AllTime(posts: all.int("posts"), views: all.int("views"), likes: all.int("likes"),
                          comments: all.int("comments"), reposts: all.int("reposts"), followers: all.int("followers"))
        daily = json.array("daily").map {
            Day(date: $0.string("date"), views: $0.int("views"), likes: $0.int("likes"), comments: $0.int("comments"))
        }
        topPosts = json.array("topPosts").map(AloPost.init)
    }

    init(days: Int, views: Metric, likes: Metric, comments: Metric, reposts: Metric, followers: Metric,
         engagementRate: Double, postsInPeriod: Int, allTime: AllTime, daily: [Day], topPosts: [AloPost]) {
        self.days = days
        self.views = views
        self.likes = likes
        self.comments = comments
        self.reposts = reposts
        self.followers = followers
        self.engagementRate = engagementRate
        self.postsInPeriod = postsInPeriod
        self.allTime = allTime
        self.daily = daily
        self.topPosts = topPosts
    }
}

/// The "@name" being typed at the end of a text, and putting the chosen person there.
enum AloMentionQuery {
    /// The handle typed after the last "@", when the text ends inside it.
    static func current(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            guard before.isWhitespace || before.isNewline || "([{«\"".contains(before) else { return nil }
        }
        let handle = text[text.index(after: at)...]
        guard handle.count <= 32, handle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            return nil
        }
        return String(handle)
    }

    /// Replaces the trailing "@…" with the person's handle and a space.
    static func insert(_ username: String, into text: String) -> String {
        guard current(in: text) != nil, let at = text.lastIndex(of: "@") else { return text + "@\(username) " }
        return String(text[..<at]) + "@\(username) "
    }
}
