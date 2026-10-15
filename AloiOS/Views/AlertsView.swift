import SwiftUI

enum AloNotificationFilter: String, CaseIterable {
    case all = "Все", replies = "Ответы", reactions = "Реакции"
    func includes(_ item: AloNotificationItem) -> Bool {
        switch self {
        case .all: return true
        case .replies: return ["comment", "reply", "comment_reply", "message"].contains(item.type)
        case .reactions: return ["like", "comment_like", "repost", "reaction"].contains(item.type)
        }
    }
}

struct AloNotificationSection: Identifiable {
    let id: String
    let title: String
    var items: [AloNotificationItem]
    static func grouped(_ items: [AloNotificationItem], filter: AloNotificationFilter) -> [Self] {
        var sections: [Self] = []
        for item in items.filter({ filter.includes($0) }).sorted(by: { $0.createdAt > $1.createdAt }) {
            let key = AloFormatters.messageDayKey(item.createdAt)
            if let index = sections.firstIndex(where: { $0.id == key }) { sections[index].items.append(item) }
            else { sections.append(Self(id: key, title: AloFormatters.messageDateLabel(item.createdAt), items: [item])) }
        }
        return sections
    }
}

struct AlertsView: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var filter: AloNotificationFilter = .all
    @State private var settingsPresented = false
    @State private var appealReportId: Int?
    // Acknowledge remotely while retaining the session's unread affordance.
    @State private var initiallyUnread = Set<Int>()
    private var accessibility = AloVisualAccessibility()
    @ScaledMetric(relativeTo: .body) private var bodySize = 16

    var body: some View {
        AloSocialScrollScreen(identifier: "alo.alerts.scroll") {
            VStack(spacing: AloSocialMetrics.headerControlSpacing) {
                AloSocialHeader(title: "Уведомления", subtitle: connectionSubtitle,
                    settingsLabel: "Настройки уведомлений", identifier: "alo.alerts") {
                    settingsPresented = true
                }
                filters.padding(.horizontal, AloSocialMetrics.inset)
            }
        } rows: {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let sections = AloNotificationSection.grouped(app.bootstrap?.notifications ?? [], filter: filter)
                    if sections.isEmpty {
                        ContentUnavailableView("Пока нет уведомлений", systemImage: "bell", description:
                            Text(filter == .all ? "Новые события появятся здесь." : "В этой категории пока нет событий."))
                            .padding(.top, 48)
                    }
                    ForEach(sections) { section in
                        Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(AloTheme.muted)
                            .padding(.top, 18).padding(.bottom, 4).padding(.horizontal, 16)
                        ForEach(section.items) { item in
                            row(item)
                            Rectangle().fill(AloTheme.separator).frame(height: 0.5).padding(.horizontal, 16)
                        }
                    }
                }.id(filter).transition(.opacity)
        }
        .refreshable { await app.loadBootstrap() }
        .accessibilityAction(named: "Обновить уведомления") { Task { await app.loadBootstrap() } }
        .foregroundStyle(AloTheme.text).background(AloTheme.background)
        .animation(accessibility.reduceMotion ? nil : .easeOut(duration: 0.16), value: filter)
        .onAppear { acknowledge() }
        .onChange(of: app.bootstrap?.notifications.map(\.id) ?? []) { _, _ in acknowledge() }
        .navigationDestination(isPresented: $settingsPresented) {
            AloSocialSettingsSheet(initialPage: .notifications).environmentObject(app)
        }
        .sheet(item: Binding(get: { appealReportId.map(AloAppealTarget.init) }, set: { appealReportId = $0?.id })) { target in
            AloAppealSheet(title: "Обжалование") { text in
                try await app.appealModerationDecision(reportId: target.id, text: text)
            }
        }
    }
    private var filters: some View {
        AloSocialSegments(values: AloNotificationFilter.allCases, selected: $filter,
            title: { $0.rawValue }, identifier: { "alo.alerts.filter.\($0)" })
    }
    private var connectionSubtitle: String {
        switch app.connectionState {
        case .connected: return ""
        case .updating: return "Обновление…"
        case .unavailable: return "Нет связи с сервером"
        }
    }
    private func row(_ item: AloNotificationItem) -> some View {
        let post = sourcePost(item)
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(initiallyUnread.contains(item.id) ? AloTheme.accent : .clear)
                .frame(width: 6, height: 6).padding(.top, 21).accessibilityHidden(true)
            Button { if let actor = item.actor { app.openProfile(actor) } } label: {
                AloAvatar(name: item.actor?.name ?? "Alo", url: item.actor?.avatarUrl ?? "", size: 46,
                          colorSeed: item.actor.map { String($0.id) })
                    .overlay(alignment: .bottomTrailing) {
                        if ["like", "comment_like"].contains(item.type) {
                            Image(systemName: "heart.fill").font(.system(size: 15))
                                .foregroundStyle(Color(red: 1, green: 0.2, blue: 0.38))
                                .padding(3).background(AloTheme.background, in: Circle())
                        }
                    }
            }
            .buttonStyle(AloFeedPressStyle()).disabled(item.actor == nil)
            .accessibilityLabel("Профиль: \(item.actor?.name ?? "Alo")")
            VStack(alignment: .leading, spacing: 4) {
                Button { app.openNotification(item) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        (Text(item.actor?.name ?? "").bold() + Text(item.actor == nil ? item.text : " " + item.text))
                            .font(.system(size: bodySize)).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let post, !post.body.isEmpty {
                            Text(post.body).font(.subheadline).foregroundStyle(AloTheme.muted).lineLimit(2)
                        }
                        Text(AloFormatters.messageDateLabel(item.createdAt) == "Вчера" ? "Вчера" : AloPostTimestamp.string(item.createdAt))
                            .font(.caption).foregroundStyle(AloTheme.muted)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading).contentShape(Rectangle())
                }
                .buttonStyle(AloFeedPressStyle()).accessibilityIdentifier("alo.alerts.item.\(item.id)")
                .accessibilityValue(initiallyUnread.contains(item.id) ? "Непрочитанное" : "Прочитанное")
                // A moderation decision about you can be appealed from its notice.
                if item.entityType == "moderation", item.entityId > 0 {
                    Button { appealReportId = item.entityId } label: {
                        Text("Обжаловать").fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(AloSocialRequestButtonStyle())
                    .accessibilityIdentifier("alo.alerts.appeal.\(item.id)")
                }
                if item.actionableFriendRequestId > 0 {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { friendActions(item) }
                        VStack(alignment: .leading, spacing: 0) { friendActions(item) }
                    }
                    .disabled(app.pendingFriendRequestIds.contains(item.actionableFriendRequestId))
                }
            }
            if let media = post?.media.first, let url = app.api.absoluteURL(media.posterUrl.ifBlank(media.url)) {
                Button { app.openNotification(item) } label: {
                    AloAsyncImage(url: url) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFill() }
                        else { AloTheme.surfaceRaised }
                    }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(AloFeedPressStyle()).accessibilityLabel("Открыть публикацию")
            }
        }
        .padding(.leading, 10).padding(.trailing, 16).padding(.vertical, 12)
        .contextMenu {
            Button("Удалить уведомление", systemImage: "trash", role: .destructive) { app.deleteNotification(item) }
        }
    }
    @ViewBuilder
    private func friendActions(_ item: AloNotificationItem) -> some View {
        Button { app.respondFriendRequest(item, accept: true) } label: {
            Text("Принять").fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(AloSocialRequestButtonStyle(prominent: true))
        Button { app.respondFriendRequest(item, accept: false) } label: {
            Text("Отклонить").fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(AloSocialRequestButtonStyle())
    }
    private func sourcePost(_ item: AloNotificationItem) -> AloPost? {
        guard item.entityType == "post", let data = app.bootstrap else { return nil }
        return (data.feedPopular + data.feedSubscriptions + data.profilePosts).first { $0.id == item.entityId }
    }
    private func acknowledge() {
        initiallyUnread.formUnion((app.bootstrap?.notifications ?? []).filter { !$0.isRead }.map(\.id))
        app.markAllNotificationsRead()
    }
}

struct AloAppealTarget: Identifiable {
    let id: Int
}
