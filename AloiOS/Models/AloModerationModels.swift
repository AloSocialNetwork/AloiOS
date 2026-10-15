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
        reason = json.string("reason")
        details = json.string("details")
        status = json.string("status")
        resolutionAction = json.string("resolutionAction")
        createdAt = json.string("createdAt")
    }

    var targetTitle: String {
        switch targetType {
        case "post": return "Публикация #\(targetId)"
        case "comment": return "Комментарий #\(targetId)"
        case "channel": return "Канал #\(targetId)"
        default: return "Пользователь #\(targetId)"
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
        case .block: return "Ограничить на сутки"
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
        default: return AloModerationAction(rawValue: action)?.title ?? action
        }
    }
    var symbol: String {
        switch action {
        case "report_rejected": return "xmark.circle"
        case "appeal_overturned": return "arrow.uturn.backward.circle"
        case "appeal_upheld": return "checkmark.seal"
        case "warn": return "exclamationmark.triangle"
        case "block", "ban": return "hand.raised.slash"
        default: return "trash"
        }
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
