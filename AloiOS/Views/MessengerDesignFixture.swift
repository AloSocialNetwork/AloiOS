#if DEBUG
import Foundation
import SwiftUI
import AVFoundation
import UIKit

struct AloMessengerAccessibilityPreviewModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicType

    func body(content: Content) -> some View {
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") {
            let defaults = UserDefaults.standard
            content
                .environment(\.dynamicTypeSize, defaults.bool(forKey: "ALO_UI_MESSENGER_ACCESSIBILITY") ? .accessibility3 : dynamicType)
                .environment(\.aloLegacyGlassPreview, defaults.bool(forKey: "ALO_UI_LEGACY_GLASS"))
                .environment(\.aloVisualAccessibilityPreview, AloVisualAccessibilityPreview(
                    reduceMotion: defaults.bool(forKey: "ALO_UI_REDUCE_MOTION"),
                    reduceTransparency: defaults.bool(forKey: "ALO_UI_REDUCE_TRANSPARENCY"),
                    increasedContrast: defaults.bool(forKey: "ALO_UI_INCREASE_CONTRAST")))
        } else {
            content
        }
    }
}

/// Report the actual GeometryReader measurement, not the full-width message row.
/// SwiftUI flattens nested accessibility containers; this probe is test-only.
struct AloMessageDesignGeometryModifier: ViewModifier {
    let frame: CGRect

    func body(content: Content) -> some View {
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") {
            content.accessibilityValue(String(format: "%.3f,%.3f,%.3f,%.3f", frame.minX, frame.minY, frame.width, frame.height))
        } else {
            content
        }
    }
}

/// Explicit, offline UI-test fixture. Never loaded in Release or persisted as an account.
extension AloAppModel {
    func installMessengerDesignFixture() async {
        var peer: [String: Any] = ["id": 990002, "name": "Александр", "username": "alex_ui_fixture", "description": "Тестовый профиль интерфейса, не реальный аккаунт", "online": false, "lastSeenAt": "2026-09-05T09:40:00Z"]
        if UserDefaults.standard.bool(forKey: "ALO_UI_SEARCH_INCOMING") {
            peer["relation"] = ["friendStatus": "incoming", "incomingRequestId": 990012]
        }
        var summary: [String: Any] = ["peerId": 990002, "kind": "direct", "peer": peer, "lastBody": "До встречи!", "lastAt": "2026-09-05T10:05:00Z"]
        let communityContent = UserDefaults.standard.string(forKey: "ALO_UI_MESSENGER_CONTENT") ?? ""
        if ["group-info", "group-owner", "channel-owner"].contains(communityContent) {
            let isChannel = communityContent == "channel-owner"
            summary["kind"] = "group"
            summary["roomId"] = 77
            summary["memberCount"] = isChannel ? 1_284 : 5
            summary["peer"] = ["id": 990002, "name": isChannel ? "Новости Alo" : "Семья",
                               "username": isChannel ? "alo_news_ui_fixture" : "family_ui_fixture",
                               "entityType": isChannel ? "channel" : "group"]
        }
        let bodies = [
            "Привет! Посмотрел фотографии с поездки?",
            "Да, очень красиво. Особенно тот кадр у озера.",
            "Давай на выходных выберемся ещё раз. Можно взять велосипеды и поехать по набережной.",
            "Отличная идея! В субботу после обеда я свободен.",
            "Тогда встречаемся в два у парка?",
            "Договорились. Возьму кофе с собой ☕️",
            "До встречи!"
        ]
        var items: [[String: Any]] = bodies.enumerated().map { index, body in
            ["id": 990100 + index, "senderId": index.isMultiple(of: 2) ? 990002 : 990001,
             "recipientId": index.isMultiple(of: 2) ? 990001 : 990002, "body": body,
             "createdAt": "2026-09-05T10:0\(index):00Z", "readAt": "2026-09-05T10:07:00Z"]
        }
        let content = UserDefaults.standard.string(forKey: "ALO_UI_MESSENGER_CONTENT") ?? ""
        if !content.isEmpty {
            let sample = await AloMessengerSampleMedia.make()
            func message(_ id: Int, body: String = "", extra: [String: Any] = [:]) -> [String: Any] {
                var value: [String: Any] = ["id": id, "senderId": 990002, "recipientId": 990001,
                    "body": body, "createdAt": "2026-09-05T10:08:00Z"]
                value.merge(extra) { _, new in new }
                return value
            }
            let definition = AloPollDefinition(id: "fixture-poll", question: "Куда отправимся в выходные?",
                options: [AloPollOption(id: "park", text: "Прогулка по парку"),
                          AloPollOption(id: "lake", text: "Поездка к озеру с длинным названием")],
                allowsMultipleAnswers: false, isQuiz: false, correctOptionIds: [], isAnonymous: true, allowsRevoting: true)
            let reply: [String: Any] = ["replyToMessageId": 990100]
            var extra = reply
            switch content {
            case "reply-layout":
                items = [message(990100, body: "Первая строка\nОчень длинный исходный текст для проверки обрезки ответа.", extra: [
                    "sender": ["id": 990002, "name": "Александр с очень длинным именем собеседника для проверки ответа"]]),
                    message(990200, body: "Отвечаю на это сообщение", extra: reply)]
            case "reply-photo", "reply-voice":
                let voice = content == "reply-voice"
                items = [message(990100, extra: ["attachments": [[
                    "type": voice ? "voice" : "image",
                    "url": voice ? (sample.audio?.absoluteString ?? "") : sample.imageURI,
                    "name": "opaque-attachment-id-7f20", "metadata": ["durationSeconds": "3"]]]]),
                    message(990200, body: "Ответ на вложение", extra: ["replyToMessageId": 990100,
                        "senderId": 990001, "recipientId": 990002])]
            case "contact":
                items = [message(990200, extra: ["attachments": [["type": "contact",
                    "name": "Контакт", "metadata": ["id": "fixture-contact", "userId": "990002",
                        "displayName": "Александр с длинным именем контакта", "username": "alex_ui_fixture"]]]])]
            case "time-layout":
                items = [
                    message(990200, body: "Привет!"),
                    message(990201, body: "Привет!", extra: ["entities": [["type": "bold", "offset": 0, "length": 7]]]),
                    message(990202, body: "Первая строка\nВторая строка", extra: ["senderId": 990001, "recipientId": 990002]),
                    message(990203, body: "Давай на выходных выберемся ещё раз. Можно взять велосипеды и поехать по набережной."),
                    message(990204, body: "Прочитано", extra: ["senderId": 990001, "recipientId": 990002, "readAt": "2026-09-05T10:09:00Z"])
                ]
            case "date-scroll":
                items = (0..<48).map { index in
                    message(990200 + index, body: "Сообщение \(index). Проверяем закрепление даты и смену дня.",
                        extra: ["createdAt": String(format: "2026-09-%02dT10:08:00Z", 5 + index / 12)])
                }
            case "media-portrait", "media-landscape", "media-square", "media-edit-empty":
                let portrait = content == "media-portrait"
                let square = content == "media-square"
                items = [message(990200, body: "", extra: ["senderId": 990001, "recipientId": 990002,
                    "attachments": [["type": "image", "url": sample.imageURI, "posterUrl": sample.imageURI,
                        "name": "image.jpg", "metadata": ["width": portrait || square ? "1080" : "1920",
                                                              "height": portrait ? "1920" : "1080"]]]])]
            case "bubble-shapes":
                // Short words, a wrapping line, a photo without stored size, a portrait photo with
                // a caption and a two-photo album: the shapes compared against Telegram.
                let mine: [String: Any] = ["senderId": 990001, "recipientId": 990002, "readAt": "2026-09-05T10:09:00Z"]
                func photo(_ width: String?, _ height: String?) -> [String: Any] {
                    var value: [String: Any] = ["type": "image", "url": sample.imageURI, "posterUrl": sample.imageURI, "name": "photo.jpg"]
                    if let width, let height { value["metadata"] = ["width": width, "height": height] }
                    return value
                }
                items = [
                    message(990210, body: "Ок"),
                    message(990211, body: "Да", extra: mine),
                    message(990212, body: "Привет!"),
                    message(990213, body: "Отлично, договорились", extra: mine),
                    message(990214, body: "Сегодня в семь у входа в парк, не опаздывай пожалуйста"),
                    message(990215, body: "Хорошо, буду вовремя и захвачу кофе на двоих", extra: mine),
                    message(990216, extra: mine.merging(["attachments": [photo(nil, nil)]]) { _, new in new }),
                    message(990217, body: "Вот это место", extra: ["attachments": [photo("1080", "1440")]]),
                    message(990218, extra: mine.merging(["attachments": [photo("1080", "1440"), photo("1080", "1440")]]) { _, new in new }),
                    message(990219, extra: ["attachments": [photo("1920", "1080"), photo("1080", "1440"), photo("1080", "1080"),
                                                            photo("1440", "1080"), photo("1080", "1920")]]),
                    message(990220, extra: mine.merging(["attachments": (0..<7).map { index in
                        index.isMultiple(of: 3) ? photo("1920", "1080") : photo("1080", "1350") }]) { _, new in new })
                ]
            case "reaction-short":
                items = [message(990200, body: "Привет!")]
            case "reaction-own":
                items = [message(990200, body: "До встречи ☕️", extra: ["senderId": 990001, "recipientId": 990002])]
            case "reaction-long":
                items = [message(990200, body: "Давай в субботу поедем к озеру. Возьмём велосипеды, кофе и тёплые вещи. Если погода изменится, встретимся у парка и выберем другой маршрут."),
                    message(990201, body: "Договорились ☕️", extra: ["senderId": 990001, "recipientId": 990002])]
            case "reaction-counts":
                items = [message(990200, body: "Проверяем реакции на длинном сообщении: текст не должен менять ширину, а счётчики — выходить за границы.", extra: ["reactions": [
                    ["emoji": "❤️", "count": 999], ["emoji": "👍", "count": 128],
                    ["emoji": "🔥", "count": 24], ["emoji": "🎉", "count": 3],
                    ["emoji": "🥰", "count": 1_200_000], ["emoji": "👏", "count": 12]]])]
            case "poll", "poll-own":
                let sender = content == "poll-own" ? ["senderId": 990001, "recipientId": 990002] : [:]
                items = [items[0], message(990200, body: AloPollCodec.encodeCreate(definition) ?? "", extra: sender)]
            case "voice", "circle":
                let isVoice = content == "voice"
                extra["attachments"] = [["type": content, "url": (isVoice ? sample.audio : sample.video)?.absoluteString ?? "",
                    "name": isVoice ? "Тестовое аудио.m4a" : "Тестовый кружок.mp4",
                    "waveform": [0.2, 0.8, 0.4, 0.6, 0.9, 0.3, 0.7], "metadata": ["id": "fixture-" + content]]]
                items = [items[0], message(990200, extra: extra)]
            case "circle-flow", "unread-navigation":
                items = (0..<24).map { index in
                    if index == 0 || index == 23 {
                        return message(990200 + index, extra: ["attachments": [[
                            "type": "circle", "url": sample.video?.absoluteString ?? "",
                            "name": "Тестовый кружок", "metadata": ["id": "circle-flow-\(index)", "durationSeconds": "30"]
                        ]]])
                    }
                    return message(990200 + index, body: "Сообщение \(index). Проверяем прокрутку и непрерывность воспроизведения кружка.")
                }
            case "media-stress":
                items = (0..<60).map { index in
                    let circle = index.isMultiple(of: 2)
                    return message(990200 + index, extra: ["attachments": [[
                        "type": circle ? "circle" : "audio",
                        "url": (circle ? sample.video : sample.audio)?.absoluteString ?? "",
                        "name": "Тестовое вложение \(index)",
                        "waveform": [0.2, 0.8, 0.4, 0.6, 0.9, 0.3, 0.7],
                        "metadata": ["id": "stress-\(index)", "durationSeconds": "3"]
                    ]]])
                }
            case "channel-media":
                items = [message(990200, body: "Медиа, подпись и реакции — один пост. Комментарии находятся под отдельным разделителем.", extra: [
                    "channelPostId": 990400, "channelPostCommentsEnabled": true, "channelPostCommentCount": 22,
                    "reactions": [["emoji": "❤️", "count": 190], ["emoji": "🔥", "count": 34], ["emoji": "👍", "count": 3]],
                    "attachments": [["type": "image", "url": sample.imageURI, "posterUrl": sample.imageURI, "name": "UI fixture.png"]]])]
            case "media":
                items = [message(990200, body: "Тестовая карточка медиа", extra: ["attachments": [
                    ["type": "image", "url": sample.imageURI, "posterUrl": sample.imageURI, "name": "UI fixture.png"]]]),
                    message(990201, extra: ["attachments": [["type": "video", "url": sample.video?.absoluteString ?? "",
                        "posterUrl": sample.imageURI, "name": "UI fixture.mp4"]]])]
            case "profile":
                // A long, explicitly labelled local library exercises sticky tabs,
                // paging and scroll restoration without touching account data.
                items = (0..<36).map { index in
                    message(990300 + index, extra: ["attachments": [[
                        "type": "image", "url": sample.imageURI, "posterUrl": sample.imageURI,
                        "name": "UI fixture \(index + 1).png", "metadata": ["id": "profile-\(index)"]
                    ]]])
                }
            case "forward":
                extra["forwardFrom"] = ["userId": 990003, "messageId": 990090,
                    "user": ["id": 990003, "name": "Александр с очень длинным именем отправителя"]]
                extra["reactions"] = [["emoji": "❤️", "count": 12, "reactedByMe": true],
                    ["emoji": "👍", "count": 128], ["emoji": "🔥", "count": 24], ["emoji": "🎉", "count": 3]]
                items = [items[0], message(990200, body: "Пересланное сообщение с ответом и реакциями.", extra: extra)]
            case "links":
                items = [message(990200, body: "Открыть сайт", extra: ["entities": [["type": "link", "offset": 0,
                    "length": 11, "url": "https://telegram.org"]]]),
                    message(990201, body: "https://telegram.org/blog")]
            default: break
            }
        }
        var feedPosts: [[String: Any]] = (0..<12).map { index in
            ["id": 990400 + index, "body": "Тест интерфейса №\(index + 1). Общий овал над лентой: контент прокручивается под ним, без чёрного прямоугольника позади.",
             "likeCount": 12, "commentCount": 3, "repostCount": 1, "viewCount": 128,
             "createdAt": "2026-09-10T10:00:00Z", "viewerLiked": true,
             "author": ["id": 990001, "name": "Тест интерфейса", "username": "ui_fixture"]]
        }
        if ["feed-timeline", "feed-video", "notifications", "social-overview"].contains(content) {
            let sample = await AloMessengerSampleMedia.make()
            let authors: [[String: Any]] = [
                ["id": 990001, "name": "makkarov", "username": "makkarov", "verified": true],
                ["id": 990002, "name": "Александр", "username": "alex"],
                ["id": 990003, "name": "Мария", "username": "maria"]]
            let bodies = ["Осень в городе. Сохраняю эти моменты.",
                          "Лучшие идеи приходят после прогулки.\nА вы где находите вдохновение?",
                          "Небольшая подборка фотографий за неделю."]
            feedPosts = (0..<12).map { index in
                var post: [String: Any] = ["id": 990400 + index, "body": bodies[index % 3],
                    "likeCount": index == 0 ? 42 : 18, "commentCount": index == 0 ? 8 : 12,
                    "repostCount": index == 0 ? 3 : 2, "viewCount": index == 0 ? 1200 : 640,
                    "viewerLiked": index == 0, "author": authors[index % 3],
                    "createdAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(-720 - index * 960)))]
                if index % 3 != 1 {
                    post["media"] = (0..<(index % 3 == 0 ? 1 : 2)).map { _ in
                        ["type": "image", "url": sample.imageURI, "posterUrl": sample.imageURI]
                    }
                }
                if content == "feed-video", index == 0 {
                    post["media"] = [["type": "video", "url": sample.video?.absoluteString ?? "", "posterUrl": sample.imageURI]]
                }
                return post
            }
        }
        let notificationTypes = ["comment", "like", "friend_request", "message", "repost", "comment_like"]
        let notifications: [[String: Any]] = ["notifications", "social-overview"].contains(content) ? notificationTypes.enumerated().map { index, type in
            ["id": 990900 + index, "type": type,
             "text": ["прокомментировал ваш пост", "нравится ваша фотография", "хочет добавить вас в друзья",
                      "ответил вам", "сделал репост вашей записи", "нравится ваш комментарий"][index],
             "actor": ["id": 990002 + index, "name": ["Александр", "Мария", "Даша", "Илья", "Александр", "Анна"][index]],
             "createdAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(index < 4 ? Double(-300 - index * 600) : -86400)),
             "isRead": index >= 4, "entityType": type == "friend_request" ? "friend_request" : "post",
             "entityId": type == "friend_request" ? 990012 : 990400,
             "friendRequestActionable": type == "friend_request"]
        } : []
        var fixtureConversations: [[String: Any]] = [summary]
        if content == "chat-list" {
            let names = ["Мария", "Команда Alo", "Илья", "Даша", "Анна", "Семья", "Работа", "Макс", "Оля", "Университет", "Соседи"]
            let texts = ["Привет! Когда увидимся на выходных? Можно сходить в кино или просто прогуляться по набережной.",
                         "Новая версия уже в TestFlight", "Спасибо!", "Фото с поездки 📷", "Договорились, до встречи", "Не забудь купить хлеб",
                         "Созвон в 15:00", "Ок", "Посмотри это видео", "Расписание на завтра", "Отопление включили"]
            fixtureConversations += names.enumerated().map { index, name in
                ["peerId": 990100 + index, "kind": index == 5 || index == 9 ? "group" : "direct",
                 "roomId": index == 5 || index == 9 ? 500 + index : 0,
                 "unreadCount": [0: 3, 2: 1, 4: 12, 5: 2][index] ?? 0,
                 "peer": ["id": 990100 + index, "name": name, "username": "fixture_\(index)"],
                 "lastBody": texts[index], "lastAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(-index * 5400 - 600))),
                 "lastMessage": ["id": 7000 + index, "senderId": 990100 + index]]
            }
            // Chats 0, 2 and 4 have an unseen newest message: they show the unread dot.
            var seen = [String: Int]()
            for index in 0..<names.count { seen["990001:direct:\(990100 + index)"] = index % 2 == 0 && index < 5 ? 7000 + index - 1 : 7000 + index }
            unreadTracker.replaceSeen(seen)
            chatPrefs.replace(owner: 990001, pinned: ["direct:990101"], archived: ["direct:990108", "direct:990110"])
        }
        let data = AloBootstrapData(["data": [
            "me": ["id": 990001, "name": "Тест интерфейса", "username": "ui_fixture"],
            "feed": ["popular": feedPosts, "subs": Array(feedPosts.suffix(3))],
            "profile": ["posts": feedPosts],
            "messages": ["conversations": fixtureConversations, "items": items, "activePeerId": 990002],
            "search": ["users": [peer]], "notifications": notifications
        ]])
        bootstrap = data
        if ["feed-timeline", "feed-video", "social-overview"].contains(content) {
            let sample = await AloMessengerSampleMedia.make()
            installFeedStoryPreview(["Маша", "Александр", "Даша", "Друзья"].enumerated().map { index, name in
                AloStoryGroup(["user": ["id": 990010 + index, "name": name], "hasUnseen": true,
                    "stories": [["id": 990800 + index, "userId": 990010 + index,
                        "media": [["type": "image", "url": sample.imageURI]],
                        "createdAt": ISO8601DateFormatter().string(from: Date()),
                        "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))]]])
            })
        }
        activeTab = content == "notifications" ? .alerts : (["feed-surface", "feed-timeline", "feed-video", "social-overview"].contains(content) ? .feed : (content == "own-profile" ? .profile : .messages))
        activeConversation = activeTab == .messages && content != "chat-list"
            ? data.conversations.first.map { AloConversationDetail(summary: $0, items: data.activeMessages) }
            : nil
        if ["group-owner", "channel-owner"].contains(content), let base = activeConversation {
            // The signed-in fixture user owns this community, as a creator would.
            activeConversation = AloConversationDetail(
                peerId: base.peerId, kind: "group", roomId: base.roomId, entityType: base.entityType,
                title: base.title, subtitle: base.subtitle, username: base.username,
                profileDescription: content == "channel-owner" ? "Новости и обновления приложения." : "",
                avatarUrl: base.avatarUrl, canManageGroup: true, groupMemberRole: "owner",
                online: false, lastSeenAt: "", items: base.items)
        }
        phase = .app
    }
}

/// Real feed cards with local interaction state, not a simulated server/account.
struct AloFeedDesignFixture: View {
    @State private var liked = false
    @State private var reposted = false
    @State private var sampleImageURI = ""

    private var post: AloPost {
        AloPost(["id": 990400, "body": "В выходные выбрались к озеру. Тихая вода, свежий воздух и несколько часов без спешки. Как вы провели субботу?",
            "likeCount": liked ? 1000 : 999, "commentCount": 128, "repostCount": reposted ? 10 : 9,
            "viewCount": 12400, "viewerLiked": liked, "viewerReposted": reposted,
            "createdAt": "2026-09-10T10:05:00Z",
            "author": ["id": 990002, "name": "Александр", "username": "ui_fixture"]])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Лента · тест интерфейса").font(.headline).padding(.vertical, 12)
                AloPostCard(post: post, onLike: { liked.toggle() }, onRepost: { reposted.toggle() })
                AloPostCard(post: AloPost(["id": 990401,
                    "body": "Карточка с большими счётчиками. Проверка границ и расположения кнопок.",
                    "likeCount": 999_999, "commentCount": 12_400, "repostCount": 100_000,
                    "viewCount": 1_200_000, "createdAt": "2026-09-10T10:00:00Z",
                    "author": ["id": 990003, "name": "Команда Alo", "username": "alo_ui_fixture"]]), onLike: {})
                if !sampleImageURI.isEmpty {
                    AloPostCard(post: AloPost(["id": 990402, "body": "",
                        "media": [["type": "image", "url": sampleImageURI]],
                        "likeCount": 37, "commentCount": 1, "repostCount": 2, "viewCount": 688,
                        "createdAt": "2026-09-10T10:00:00Z",
                        "author": ["id": 990003, "name": "Команда Alo", "username": "alo_ui_fixture"]]), onLike: {})
                }
            }
            .padding(.horizontal, AloTheme.pageInset)
        }
        .accessibilityIdentifier("alo.feed.fixture")
        .clipped()
        .task { sampleImageURI = await AloMessengerSampleMedia.make().imageURI }
    }
}

/// Locally generated test media, never downloaded or presented as user content.
@MainActor
enum AloMessengerSampleMedia {
    static func make() async -> (imageURI: String, audio: URL?, video: URL?) {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            ("ALO\nUI TEST" as NSString).draw(in: CGRect(x: 30, y: 60, width: 260, height: 150),
                withAttributes: [.font: UIFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: UIColor.white])
        }
        let uri = "data:image/png;base64," + (image.pngData()?.base64EncodedString() ?? "")
        if let url = URL(string: uri) { AloImageCache.installPreviewImage(image, for: url) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alo-messenger-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("tone-v38.m4a")
        if !FileManager.default.fileExists(atPath: audio.path),
           let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050 * 3) {
            buffer.frameLength = buffer.frameCapacity
            if let samples = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { samples[i] = Float(sin(Double(i) * 2 * .pi * 220 / 22050)) * 0.03 }
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 22050, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
                if let file = try? AVAudioFile(forWriting: audio, settings: settings) { try? file.write(from: buffer) }
            }
        }
        let longVideo = UserDefaults.standard.string(forKey: "ALO_UI_MESSENGER_CONTENT") == "circle-flow"
        let video = directory.appendingPathComponent(longVideo ? "motion-long.mp4" : "motion.mp4")
        if !FileManager.default.fileExists(atPath: video.path),
           let writer = try? AVAssetWriter(outputURL: video, fileType: .mp4) {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320, AVVideoHeightKey: 240])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<(longVideo ? 300 : 30) {
                while !input.isReadyForMoreMediaData && writer.status == .writing { try? await Task.sleep(nanoseconds: 5_000_000) }
                guard writer.status == .writing else { break }
                var pixel: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32ARGB,
                    [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixel)
                guard let pixel else { break }
                CVPixelBufferLockBaseAddress(pixel, [])
                if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 320, height: 240,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue), let cg = image.cgImage {
                    context.draw(cg, in: CGRect(x: 0, y: 0, width: 320, height: 240))
                    context.setFillColor(UIColor.white.cgColor)
                    context.fill(CGRect(x: (frame % 30) * 10, y: 210, width: 20, height: 10))
                }
                CVPixelBufferUnlockBaseAddress(pixel, [])
                adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
            }
            input.markAsFinished()
            await writer.finishWriting()
        }
        return (uri, FileManager.default.fileExists(atPath: audio.path) ? audio : nil,
            FileManager.default.fileExists(atPath: video.path) ? video : nil)
    }
}
#endif
