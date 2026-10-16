import Foundation

// The moderation panel (reports, appeals, audit log) and Alo's own ads.

struct AloModerationReport: Identifiable, Equatable {
    let id: Int
    let reporter: AloEntitySummary
    let targetType: String
    let targetId: Int
    let targetUserId: Int?
    let targetPostBody: String
    let targetPostMediaCount: Int
    /// What was reported, as the moderator needs to see it.
    let target: AloReportedContent?
    /// Other pending reports about the same post, comment, person or channel.
    let otherPendingCount: Int
    let reason: String
    let details: String
    let status: String
    let resolutionAction: String
    let createdAt: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        reporter = AloEntitySummary(json.object("reporter"))
        targetType = json.string("targetType")
        targetId = json.int("targetId")
        let target = json.int("targetUserId")
        targetUserId = target > 0 ? target : nil
        targetPostBody = json.object("targetPost").string("body")
        targetPostMediaCount = json.object("targetPost").int("mediaCount")
        self.target = json.optionalObject("target").map(AloReportedContent.init)
        otherPendingCount = json.int("otherPendingCount")
        reason = json.string("reason")
        details = json.string("details")
        status = json.string("status")
        resolutionAction = json.string("resolutionAction")
        createdAt = json.string("createdAt")
    }

    var targetTitle: String {
        switch targetType {
        case "post": return "Публикация"
        case "comment": return "Комментарий"
        case "channel": return "Канал"
        default: return "Пользователь"
        }
    }
}

/// The reported post, comment, person or channel. `deleted` once it is gone.
struct AloReportedContent: Equatable {
    let kind: String
    let id: Int
    let deleted: Bool
    let author: AloEntitySummary?
    let body: String
    let media: [AloMediaItem]
    let createdAt: String
    let postId: Int
    let likeCount: Int
    let commentCount: Int
    let user: AloEntitySummary?
    let bio: String
    let hierarchy: AloStaffHierarchy
    let accountStatus: String
    let blockedUntil: String
    let title: String
    let slug: String
    let channelDescription: String
    let avatar: String
    let subscribersCount: Int

    init(_ json: [String: Any]) {
        kind = json.string("kind")
        id = json.int("id")
        deleted = json.bool("deleted")
        author = json.optionalObject("author").map(AloEntitySummary.init)
        body = json.string("body")
        // The server names a video's still "poster"; the media grid reads "posterUrl".
        media = json.array("media").map { item in
            var item = item
            if item["posterUrl"] == nil { item["posterUrl"] = item["poster"] }
            return AloMediaItem(item)
        }
        createdAt = json.string("createdAt")
        postId = json.int("postId")
        likeCount = json.int("likeCount")
        commentCount = json.int("commentCount")
        user = json.optionalObject("user").map(AloEntitySummary.init)
        bio = json.string("bio")
        hierarchy = AloStaffHierarchy(rawValue: json.string("hierarchy")) ?? .user
        accountStatus = json.string("accountStatus").ifBlank("active")
        blockedUntil = json.string("blockedUntil")
        title = json.string("title")
        slug = json.string("slug")
        channelDescription = json.string("description")
        avatar = json.string("avatar")
        subscribersCount = json.int("subscribersCount")
    }

    static func == (lhs: AloReportedContent, rhs: AloReportedContent) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id && lhs.deleted == rhs.deleted && lhs.body == rhs.body
            && lhs.accountStatus == rhs.accountStatus && lhs.media.map(\.url) == rhs.media.map(\.url)
    }
}

/// A moment ahead or behind as "22 октября, 21:28" (the year only when it is not this one).
func aloModerationDate(_ iso: String) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
    formatter.dateFormat = sameYear ? "d MMMM, HH:mm" : "d MMMM yyyy, HH:mm"
    return formatter.string(from: date)
}

/// A count as the panel shows it: 128, 2,4 тыс., 12 тыс., 1,2 млн.
func aloCompactCount(_ value: Int) -> String {
    func oneDecimal(_ number: Double) -> String {
        let text = String(format: "%.1f", (number * 10).rounded(.down) / 10).replacingOccurrences(of: ".", with: ",")
        return text.hasSuffix(",0") ? String(text.dropLast(2)) : text
    }
    switch value {
    case 1_000_000...: return oneDecimal(Double(value) / 1_000_000) + " млн"
    case 10_000...: return "\(value / 1_000) тыс."
    case 1_000...: return oneDecimal(Double(value) / 1_000) + " тыс."
    default: return "\(value)"
    }
}

/// The moderation ladder: nobody acts on someone at or above them.
enum AloStaffHierarchy: String, CaseIterable {
    case owner, admin, leadModerator = "lead_moderator", moderator, user

    var rank: Int {
        switch self {
        case .owner: return 4
        case .admin: return 3
        case .leadModerator: return 2
        case .moderator: return 1
        case .user: return 0
        }
    }
    var title: String {
        switch self {
        case .owner: return "Владелец"
        case .admin: return "Администратор"
        case .leadModerator: return "Старший модератор"
        case .moderator: return "Модератор"
        case .user: return "Пользователь"
        }
    }
    var plural: String {
        switch self {
        case .owner: return "Владелец"
        case .admin: return "Администраторы"
        case .leadModerator: return "Старшие модераторы"
        case .moderator: return "Модераторы"
        case .user: return "Пользователи"
        }
    }
    var symbol: String {
        switch self {
        case .owner: return "crown.fill"
        case .admin: return "shield.lefthalf.filled"
        case .leadModerator: return "star.circle.fill"
        case .moderator: return "shield.fill"
        case .user: return "person.fill"
        }
    }
}

/// What a moderator may be given, with the name the panel shows.
enum AloModeratorPermission: String, CaseIterable, Identifiable {
    case reports = "reports.review", stats = "stats.view", verification = "verification.review",
         censorship = "censorship.manage", team = "moderation.manage"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .reports: return "Жалобы, апелляции и журнал"
        case .stats: return "Статистика"
        case .verification: return "Верификация"
        case .censorship: return "Стоп-слова"
        case .team: return "Управление командой"
        }
    }
    var footnote: String {
        switch self {
        case .reports: return "Решает жалобы и обжалования, видит журнал."
        case .stats: return "Видит общую статистику сервиса."
        case .verification: return "Рассматривает заявки на галочку."
        case .censorship: return "Ведёт список запрещённых слов."
        case .team: return "Делает старшим модератором: назначает модераторов ниже себя."
        }
    }
}

/// Someone in the moderation team, or a person found to appoint or restrict.
struct AloStaffMember: Identifiable, Equatable {
    let user: AloEntitySummary
    let permissions: [String]
    let hierarchy: AloStaffHierarchy
    let isOwner: Bool
    let accountStatus: String
    let blockedUntil: String
    let blockReason: String
    var id: Int { user.id }

    init(_ json: [String: Any]) {
        user = AloEntitySummary(json)
        permissions = (json["permissions"] as? [String]) ?? []
        hierarchy = AloStaffHierarchy(rawValue: json.string("hierarchy")) ?? .user
        isOwner = json.bool("isOwner")
        accountStatus = json.string("accountStatus").ifBlank("active")
        blockedUntil = json.string("blockedUntil")
        blockReason = json.string("blockReason")
    }

    var accountStatusTitle: String? {
        switch accountStatus {
        case "blocked": return blockedUntil.isEmpty ? "Доступ ограничен" : "Ограничен до \(aloModerationDate(blockedUntil))"
        case "banned": return "Заблокирован навсегда"
        default: return nil
        }
    }
}

/// What a moderator can do with an approved report, by what it is about.
enum AloModerationAction: String, CaseIterable, Identifiable {
    case none, warn, block, ban, deletePost = "delete_post", deleteComment = "delete_comment", deleteChannel = "delete_channel"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Без наказания"
        case .warn: return "Предупредить"
        case .block: return "Ограничить доступ"
        case .ban: return "Заблокировать навсегда"
        case .deletePost: return "Удалить публикацию"
        case .deleteComment: return "Удалить комментарий"
        case .deleteChannel: return "Удалить канал"
        }
    }
    var isDestructive: Bool { self != .none && self != .warn }

    static func available(for targetType: String) -> [AloModerationAction] {
        let content: [AloModerationAction] = switch targetType {
        case "post": [.deletePost]
        case "comment": [.deleteComment]
        case "channel": [.deleteChannel]
        default: []
        }
        return [.warn] + content + [.block, .ban]
    }
}

struct AloModerationAppeal: Identifiable, Equatable {
    let id: Int
    let kind: String
    let reportId: Int?
    let text: String
    let status: String
    let decisionNote: String
    let action: String
    let accountStatus: String
    let createdAt: String
    let user: AloEntitySummary?

    init(_ json: [String: Any]) {
        id = json.int("id")
        kind = json.string("kind")
        let report = json.int("reportId")
        reportId = report > 0 ? report : nil
        text = json.string("text")
        status = json.string("status")
        decisionNote = json.string("decisionNote")
        action = json.string("action")
        accountStatus = json.string("accountStatus")
        createdAt = json.string("createdAt")
        user = json.optionalObject("user").map(AloEntitySummary.init)
    }

    var actionTitle: String {
        AloModerationAction(rawValue: action)?.title ?? (kind == "account" ? "Блокировка аккаунта" : "Решение модерации")
    }
}

struct AloModerationAuditEntry: Identifiable, Equatable {
    let id: Int
    let action: String
    let details: String
    let createdAt: String
    let actor: AloEntitySummary
    let target: AloEntitySummary?

    init(_ json: [String: Any]) {
        id = json.int("id")
        action = json.string("action")
        details = json.string("details")
        createdAt = json.string("createdAt")
        actor = AloEntitySummary(json.object("actor"))
        target = json.optionalObject("target").map(AloEntitySummary.init)
    }

    var title: String {
        switch action {
        case "report_rejected": return "Жалоба отклонена"
        case "appeal_overturned": return "Обжалование принято"
        case "appeal_upheld": return "Обжалование отклонено"
        case "moderator_granted": return "Назначен модератор"
        case "moderator_updated": return "Права модератора изменены"
        case "moderator_revoked": return "Снят с модерации"
        case "admin_granted": return "Назначен администратор"
        case "admin_revoked": return "Снят администратор"
        case "account_blocked": return "Доступ ограничен"
        case "account_banned": return "Аккаунт заблокирован"
        case "account_active": return "Доступ восстановлен"
        case "block": return "Доступ ограничен по жалобе"
        case "ban": return "Заблокирован по жалобе"
        default: return AloModerationAction(rawValue: action)?.title ?? action
        }
    }
    var symbol: String {
        switch action {
        case "report_rejected": return "xmark.circle"
        case "appeal_overturned", "account_active": return "arrow.uturn.backward.circle"
        case "appeal_upheld": return "checkmark.seal"
        case "warn": return "exclamationmark.triangle"
        case "block", "ban", "account_blocked", "account_banned": return "hand.raised.slash"
        case "moderator_granted", "moderator_updated": return "shield"
        case "moderator_revoked", "admin_revoked": return "person.badge.minus"
        case "admin_granted": return "shield.lefthalf.filled"
        default: return "trash"
        }
    }
    /// Permission ids in the details of a role change, by their panel names.
    var readableDetails: String {
        guard action.hasPrefix("moderator_") else { return details }
        return details.split(separator: ",")
            .map { AloModeratorPermission(rawValue: $0.trimmingCharacters(in: .whitespaces))?.title ?? String($0) }
            .joined(separator: ", ")
    }
}

/// An ad as viewers see it: always labelled, always hideable.
struct AloAd: Identifiable, Equatable {
    let id: Int
    let placement: String
    let label: String
    let advertiser: String
    let title: String
    let body: String
    let mediaUrl: String
    let ctaLabel: String
    let ctaUrl: String
    let why: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        placement = json.string("placement").ifBlank("feed")
        label = json.string("label").ifBlank("Реклама")
        advertiser = json.string("advertiser")
        title = json.string("title")
        body = json.string("body")
        mediaUrl = json.string("mediaUrl")
        ctaLabel = json.string("ctaLabel").ifBlank("Подробнее")
        ctaUrl = json.string("ctaUrl")
        why = json.string("why")
    }
}

/// A campaign in the admin panel, with its reach.
struct AloAdCampaign: Identifiable, Equatable {
    let ad: AloAd
    let name: String
    let status: String
    let impressionLimit: Int
    let impressions: Int
    let reach: Int
    let clicks: Int
    let hides: Int
    let ctr: Double
    var id: Int { ad.id }

    init(_ json: [String: Any]) {
        ad = AloAd(json)
        name = json.string("name")
        status = json.string("status")
        impressionLimit = json.int("impressionLimit")
        let stats = json.object("stats")
        impressions = stats.int("impressions")
        reach = stats.int("reach")
        clicks = stats.int("clicks")
        hides = stats.int("hides")
        ctr = (stats["ctr"] as? Double) ?? Double(stats.int("ctr"))
    }

    var statusTitle: String {
        switch status {
        case "active": return "Показывается"
        case "paused": return "На паузе"
        case "ended": return "Завершена"
        default: return "Черновик"
        }
    }
}
