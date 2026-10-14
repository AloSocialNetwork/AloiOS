import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var selectedRelationList: SearchRelationListKind?
    @State private var localMessageHits = [AloOfflineMessageSearchHit]()
    @State private var settingsPresented = false
    @State private var incomingRequest: AloEntitySummary?

    private var users: [AloEntitySummary] {
        let query = app.searchQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let all = (app.bootstrap?.searchUsers ?? []) + (app.bootstrap?.searchChannels ?? [])
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(query) || $0.username.lowercased().contains(query) }
    }

    var body: some View {
        AloSocialScrollScreen(identifier: "alo.search.scroll") {
            VStack(spacing: AloSocialMetrics.searchSpacing) {
                AloSocialHeader(title: "Поиск", subtitle: connectionSubtitle,
                    settingsLabel: "Настройки", identifier: "alo.search") {
                    settingsPresented = true
                }
                AloSocialSearchField(text: $app.searchQuery)
                    .padding(.horizontal, AloSocialMetrics.inset)
            }
        } rows: {
                LazyVStack(spacing: 0) {
                    if let stats = app.bootstrap?.profileStats {
                        SearchRelationsOverview(stats: stats) { selectedRelationList = $0 }
                            .padding(.horizontal, AloSocialMetrics.inset)
                            .padding(.bottom, 8)
                    }
                    ForEach(users) { item in
                        searchResult(item)
                        Divider().background(AloTheme.border).padding(.leading, 82)
                    }

                    if !localMessageHits.isEmpty {
                        HStack {
                            Text("Сообщения на этом устройстве")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AloTheme.muted)
                            Spacer()
                            Text("E2EE")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AloTheme.accent)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                        .padding(.bottom, 2)

                        ForEach(localMessageHits) { hit in
                            Button {
                                openLocalMessageHit(hit)
                            } label: {
                                HStack(spacing: 12) {
                                    AloAvatar(
                                        name: hit.conversation.title,
                                        url: hit.conversation.avatarUrl,
                                        size: 46,
                                        colorSeed: "search-\(hit.conversation.peerId)"
                                    )
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Text(hit.conversation.title)
                                                .font(.system(size: 16, weight: .bold))
                                                .lineLimit(1)
                                            Spacer(minLength: 4)
                                            Text(AloFormatters.messageTime(hit.message.createdAt))
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(AloTheme.muted)
                                        }
                                        Text(messagePreview(hit.message))
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(AloTheme.text)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            Divider().background(AloTheme.border).padding(.leading, 74)
                        }
                    }
                }
        }
        .navigationDestination(isPresented: $settingsPresented) { AloSocialSettingsSheet().environmentObject(app) }
        .confirmationDialog("Заявка в друзья", isPresented: Binding(
            get: { incomingRequest != nil }, set: { if !$0 { incomingRequest = nil } }
        ), titleVisibility: .visible) {
            if let user = incomingRequest, let relation = user.relation {
                Button("Принять") { app.respondFriendRequest(requestId: relation.incomingRequestId, accept: true) }
                Button("Отклонить", role: .destructive) { app.respondFriendRequest(requestId: relation.incomingRequestId, accept: false) }
            }
            Button("Отмена", role: .cancel) {}
        }
        .task(id: "\(app.searchQuery):\(app.bootstrap?.me.id ?? 0)") {
            let query = app.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let ownerUserId = app.bootstrap?.me.id ?? 0
            guard !query.isEmpty, ownerUserId > 0 else {
                localMessageHits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                AloSecureOfflineCacheStore.shared.searchAllMessages(
                    ownerUserId: ownerUserId,
                    query: query,
                    limit: 100
                )
            }.value
            guard !Task.isCancelled,
                  query == app.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return
            }
            localMessageHits = hits
        }
        .fullScreenCover(item: $selectedRelationList) { kind in
            SearchRelationListScreen(
                kind: kind,
                items: relationItems(for: kind),
                onClose: { selectedRelationList = nil }
            )
            .environmentObject(app)
        }
    }

    private func searchResult(_ item: AloEntitySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button { app.openProfile(item) } label: {
                    HStack(spacing: 12) {
                        AloAvatar(name: item.name, url: item.avatarUrl, size: 56, colorSeed: String(item.id))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(item.name).font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                                if item.verified {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(AloTheme.accent).accessibilityHidden(true)
                                }
                            }
                            Text(item.isChannel ? "Сообщество" : item.username.withAtPrefix)
                                .font(.subheadline).foregroundStyle(AloTheme.muted).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.foregroundStyle(AloTheme.text)
                }
                .buttonStyle(AloFeedPressStyle())
                .accessibilityLabel("Профиль: \(item.name), \(item.username.withAtPrefix)")
                if !item.isChannel && !dynamicType.isAccessibilitySize { friendAction(item) }
            }
            if !item.isChannel && dynamicType.isAccessibilitySize {
                friendAction(item).padding(.leading, 68)
            }
        }
        .padding(.horizontal, AloSocialMetrics.inset).padding(.vertical, 12)
    }

    private func friendAction(_ item: AloEntitySummary) -> some View {
        Button {
            if item.relation?.friendStatus == "incoming" {
                if (item.relation?.incomingRequestId ?? 0) > 0 { incomingRequest = item }
                else { app.openProfile(item) }
            } else { app.sendFriendRequest(item) }
        } label: {
            Text(friendButtonTitle(for: item)).fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(AloSocialRequestButtonStyle(prominent: friendButtonEnabled(for: item)))
        .disabled(!friendButtonEnabled(for: item))
    }

    private var connectionSubtitle: String {
        switch app.connectionState {
        case .connected: return ""
        case .updating: return "Обновление…"
        case .unavailable: return "Нет связи с сервером"
        }
    }

    private func friendButtonTitle(for item: AloEntitySummary) -> String {
        switch item.relation?.friendStatus {
        case "friends":
            return "В друзьях"
        case "outgoing":
            return "Отправлено"
        case "incoming":
            return "Ответить"
        default:
            return "Добавить"
        }
    }

    private func friendButtonEnabled(for item: AloEntitySummary) -> Bool {
        let status = item.relation?.friendStatus ?? "none"
        let pending = app.pendingFriendRequestIds.contains(item.relation?.incomingRequestId ?? 0)
        return ["none", "incoming"].contains(status) && !pending
    }

    private func openLocalMessageHit(_ hit: AloOfflineMessageSearchHit) {
        guard let summary = app.bootstrap?.conversations.first(where: {
            $0.peerId == hit.conversation.peerId
        }) else {
            app.notice = "Этот чат больше недоступен."
            return
        }
        app.openConversation(summary)
    }

    private func messagePreview(_ message: AloChatMessage) -> String {
        message.body.ifBlank(message.attachmentName).ifBlank("Вложение")
    }

    private func relationItems(for kind: SearchRelationListKind) -> [AloEntitySummary] {
        let users = app.bootstrap?.searchUsers ?? []
        let channels = app.bootstrap?.searchChannels ?? []

        switch kind {
        case .friends:
            return users.filter { $0.relation?.friendStatus == "friends" }
        case .followers:
            return users.filter { ($0.relation?.followedBy ?? false) && $0.relation?.friendStatus != "friends" }
        case .following:
            return users.filter { ($0.relation?.following ?? false) && $0.relation?.friendStatus != "friends" }
        case .channels:
            return channels
        }
    }
}

private struct SearchRelationsOverview: View {
    let stats: AloProfileStats
    let onTap: (SearchRelationListKind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                relationTile(.friends, "Друзья", stats.friends)
                relationTile(.followers, "Подписчики", stats.followers)
                relationTile(.following, "Подписки", stats.following)
                relationTile(.channels, "Сообщества", stats.channels)
            }
        }
        .scrollClipDisabled()
    }

    private func relationTile(_ kind: SearchRelationListKind, _ title: String, _ value: Int) -> some View {
        Button {
            onTap(kind)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AloTheme.text)
                    .lineLimit(1)
                Text("\(value)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AloTheme.accent)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(AloTheme.surfaceRaised.opacity(0.84), in: Capsule())
            .overlay(Capsule().stroke(AloTheme.border.opacity(0.5), lineWidth: 0.5))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(AloControlPressStyle())
    }
}

private enum SearchRelationListKind: String, Identifiable {
    case friends
    case followers
    case following
    case channels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friends:
            return "Друзья"
        case .followers:
            return "Подписчики"
        case .following:
            return "Подписки"
        case .channels:
            return "Сообщества"
        }
    }
}

private struct SearchRelationListScreen: View {
    @EnvironmentObject private var app: AloAppModel
    let kind: SearchRelationListKind
    let items: [AloEntitySummary]
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            AloTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.title)
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .foregroundStyle(AloTheme.text)

                        Text(subtitle)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(AloTheme.muted)
                    }
                    .padding(.top, 96)
                    .padding(.horizontal, 14)

                    if items.isEmpty {
                        ContentUnavailableView(
                            "\(kind.title.lowercased()) пока нет",
                            systemImage: emptySymbol,
                            description: Text("Когда здесь появятся связи, они будут показаны списком.")
                        )
                        .foregroundStyle(AloTheme.muted)
                        .padding(.top, 48)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                Button {
                                    onClose()
                                    app.openProfile(item)
                                } label: {
                                    HStack(spacing: 12) {
                                        AloAvatar(
                                            name: item.name,
                                            url: item.avatarUrl,
                                            size: 58,
                                            colorSeed: String(item.id)
                                        )

                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 5) {
                                                Text(item.name)
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundStyle(AloTheme.text)
                                                if item.verified {
                                                    Image(systemName: "checkmark.seal.fill")
                                                        .font(.system(size: 15, weight: .bold))
                                                        .foregroundStyle(AloTheme.accent)
                                                }
                                            }

                                            Text(item.isChannel ? "Сообщество" : item.username.withAtPrefix)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(AloTheme.muted)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(AloTheme.muted.opacity(0.85))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Divider()
                                    .background(AloTheme.border)
                                    .padding(.leading, 86)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.bottom, 36)
            }

            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 58, height: 58)
                    .contentShape(Rectangle())
            }
            .padding(.leading, 14)
            .padding(.top, 20)
        }
    }

    private var subtitle: String {
        switch kind {
        case .friends:
            return "Список твоих подтверждённых друзей."
        case .followers:
            return "Кто подписан на тебя."
        case .following:
            return "На кого подписан ты."
        case .channels:
            return "Сообщества, доступные в подборке."
        }
    }

    private var emptySymbol: String {
        switch kind {
        case .friends:
            return "person.2"
        case .followers:
            return "person.badge.shield.checkmark"
        case .following:
            return "person.crop.circle.badge.plus"
        case .channels:
            return "megaphone"
        }
    }
}
