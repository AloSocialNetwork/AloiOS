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

/// Bytes of an outgoing attachment the server has acknowledged, for the bubble's progress ring.
struct AloUploadProgress: Equatable {
    let sent: Int64
    let total: Int64
    let index: Int
    let count: Int

    var fraction: Double { total > 0 ? min(1, Double(sent) / Double(total)) : 0 }

    /// "120 МБ из 1,4 ГБ", and "файл 2 из 3" when a message has several.
    var label: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        let bytes = "\(formatter.string(fromByteCount: sent)) из \(formatter.string(fromByteCount: total))"
        return count > 1 ? "\(bytes) · файл \(index + 1) из \(count)" : bytes
    }
}

/// A channel's statistics for a period, as the channel's admins see them.
struct AloChannelStats: Equatable {
    struct Growth: Equatable, Identifiable {
        let day: String
        let joined: Int
        var id: String { day }
    }

    struct Publication: Equatable, Identifiable {
        let postId: Int
        let publishedAt: String
        let views: Int
        let likes: Int
        let comments: Int
        let reposts: Int
        var id: Int { postId }
    }

    let days: Int
    let subscribers: Int
    let posts: Int
    let views: Int
    let likes: Int
    let comments: Int
    let reposts: Int
    let growth: [Growth]
    let publications: [Publication]

    init(_ json: [String: Any]) {
        days = json.object("period").int("days")
        let totals = json.object("totals")
        subscribers = totals.int("subscribers")
        posts = totals.int("posts")
        views = totals.int("views")
        likes = totals.int("likes")
        comments = totals.int("comments")
        reposts = totals.int("reposts")
        growth = json.array("audienceGrowth").map { Growth(day: $0.string("day"), joined: $0.int("joined")) }
        publications = json.array("publications").map {
            Publication(postId: $0.int("postId"), publishedAt: $0.string("publishedAt"), views: $0.int("views"),
                        likes: $0.int("likes"), comments: $0.int("comments"), reposts: $0.int("reposts"))
        }
    }

    var viewsPerPost: Int { posts > 0 ? views / posts : 0 }
    var joinedInPeriod: Int { growth.reduce(0) { $0 + $1.joined } }

    /// Every day of the period with how many people joined, zeros included, for the chart.
    func growthByDay(now: Date = Date()) -> [AloCreatorStats.Day] {
        let joined = Dictionary(growth.map { ($0.day, $0.joined) }, uniquingKeysWith: +)
        let viewsByDay = Dictionary(publications.map { (String($0.publishedAt.prefix(10)), $0.views) }, uniquingKeysWith: +)
        return (0..<max(1, days)).reversed().map { offset in
            let key = String(ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(offset) * 86_400)).prefix(10))
            return AloCreatorStats.Day(date: key, views: viewsByDay[key] ?? 0, likes: joined[key] ?? 0, comments: 0)
        }
    }
}
