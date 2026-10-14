import SwiftUI
import PhotosUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var selectedSection: ProfileSection = .posts
    @State private var isPalettePresented = false
    @State private var isEditPresented = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var avatarCrop: AloAvatarCropRequest?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let data = app.bootstrap {
                    ProfileHeroCard(
                        user: data.me,
                        coverStyleOverride: nil,
                        showsOwnerControls: true,
                        primaryTitle: nil,
                        primarySystemImage: nil,
                        primaryAccent: false,
                        onPrimary: nil,
                        secondarySystemImage: nil,
                        onSecondary: nil,
                        onEditProfile: { isEditPresented = true },
                        onEditBanner: { isPalettePresented = true },
                        avatarSelection: $selectedAvatarItem
                    )
                    .padding(.horizontal, AloSocialMetrics.inset)
                    .padding(.top, AloTheme.spacingSmall)
                    .padding(.bottom, AloTheme.spacingSmall)

                    Section {
                        let posts = selectedSection == .posts ? data.profilePosts : ownLikedPosts
                        if posts.isEmpty {
                            ContentUnavailableView(
                                selectedSection == .posts ? "Постов пока нет" : "Отметок пока нет",
                                systemImage: selectedSection == .posts ? "text.bubble" : "heart",
                                description: Text("Когда здесь появится контент, он будет показан списком.")
                            )
                            .foregroundStyle(AloTheme.muted)
                            .padding(.top, 34)
                        } else {
                            ForEach(posts) { post in
                                AloPostCard(post: post) {
                                    app.toggleLike(post)
                                } onComment: {
                                    app.openComments(for: post)
                                } onRepost: {
                                    app.toggleRepost(post)
                                } onAuthor: {
                                    app.openProfile(post.author)
                                }
                                .padding(.horizontal, AloTheme.pageInset)
                            }
                        }
                    } header: {
                        stickyProfileSwitcher
                    }
                }
            }
            .padding(.bottom, AloSocialMetrics.bottomClearance)
        }
        .accessibilityIdentifier("alo.profile.scroll")
        .background(AloTheme.background)
        .refreshable { await app.loadBootstrap() }
        .sheet(isPresented: $isPalettePresented) {
            ProfilePaletteSheet(
                name: app.bootstrap?.me.name ?? "Alo",
                selectedStyle: app.bootstrap?.me.coverStyle ?? "violet"
            ) { style in
                app.updateProfileCover(style: style)
            }
        }
        .navigationDestination(isPresented: $isEditPresented) {
            AloSocialSettingsSheet().environmentObject(app)
        }
        .onChange(of: selectedAvatarItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                // Always clear the selection, so picking the same photo again still works.
                selectedAvatarItem = nil
                guard let data, let image = await AloAvatarImage.decoded(from: data) else {
                    app.errorMessage = "Не удалось открыть это фото. Выберите другое."
                    return
                }
                avatarCrop = AloAvatarCropRequest(image: image)
            }
        }
        .fullScreenCover(item: $avatarCrop) { request in
            AloAvatarCropView(image: request.image, onCancel: { avatarCrop = nil }) { jpeg in
                avatarCrop = nil
                app.updateProfileAvatar(data: jpeg)
            }
        }
    }

    private var ownLikedPosts: [AloPost] {
        guard let data = app.bootstrap else { return [] }
        var seen = Set<Int>()
        return (data.profilePosts + data.feedPopular + data.feedSubscriptions).filter { post in
            post.viewerLiked && seen.insert(post.id).inserted
        }
    }

    private var stickyProfileSwitcher: some View {
        ProfileContentSwitcher(selected: $selectedSection)
            .padding(.horizontal, AloSocialMetrics.inset)
            .padding(.vertical, AloTheme.spacingSmall)
    }
}

struct ProfileDetailView: View {
    @EnvironmentObject private var app: AloAppModel
    let profile: AloUserProfile
    @State private var selectedSection: ProfileSection = .posts
    @State private var isBlockConfirmationPresented = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            AloTheme.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ProfileHeroCard(
                        user: profile.user,
                        coverStyleOverride: nil,
                        showsOwnerControls: false,
                        primaryTitle: relationTitle,
                        primarySystemImage: relationIcon,
                        primaryAccent: relationTitle == "Добавить" || relationTitle == "Подписаться" || relationTitle == "Принять",
                        onPrimary: handleRelationTap,
                        secondarySystemImage: profile.permissions.canMessage && !isBlocked ? "message.fill" : nil,
                        onSecondary: profile.permissions.canMessage && !isBlocked ? { app.openConversation(with: profile) } : nil,
                        onEditProfile: nil,
                        onEditBanner: nil
                    )
                    .padding(.horizontal, AloTheme.pageInset)
                    .padding(.top, AloTheme.spacingSmall)
                    .padding(.bottom, AloTheme.spacingSmall)

                    if !isOwnProfile {
                        blockControl
                            .padding(.horizontal, AloTheme.pageInset)
                        if isBlocked {
                            blockedContactNotice
                                .padding(.horizontal, AloTheme.pageInset)
                                .padding(.top, AloTheme.spacingSmall)
                        }
                    }

                    if profile.permissions.isPrivate {
                        privateNotice
                            .padding(.horizontal, AloTheme.pageInset)
                    } else {
                        Section {
                            let posts = selectedSection == .posts ? profile.posts : profile.likes
                            if posts.isEmpty {
                                ContentUnavailableView(
                                    selectedSection == .posts ? "Постов пока нет" : "Отметок пока нет",
                                    systemImage: selectedSection == .posts ? "text.bubble" : "heart",
                                    description: Text("Когда здесь появится контент, он будет показан списком.")
                                )
                                .foregroundStyle(AloTheme.muted)
                                .padding(.top, 34)
                            } else {
                                ForEach(posts) { post in
                                    AloPostCard(post: post) {
                                        app.toggleLike(post)
                                    } onComment: {
                                        app.openComments(for: post)
                                    } onRepost: {
                                        app.toggleRepost(post)
                                    } onAuthor: {
                                        app.openProfile(post.author)
                                    }
                                    .padding(.horizontal, AloTheme.pageInset)
                                }
                            }
                        } header: {
                            ProfileContentSwitcher(selected: $selectedSection)
                                .padding(.horizontal, AloTheme.pageInset)
                                .padding(.vertical, AloTheme.spacingSmall)
                        }
                    }
                }
                .padding(.bottom, 28)
            }
            .clipped()

            Button(action: app.closeProfile) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 42, height: 46)
                    .contentShape(Rectangle())
            }
            .padding(.leading, 20)
            .padding(.top, 18)
        }
    }

    private var privateNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Закрытый профиль", systemImage: "lock.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AloTheme.text)
            Text("Посты, фото и отметки откроются только после добавления в друзья.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .aloCard(radius: 22)
    }

    private var relationTitle: String {
        switch profile.relation.friendStatus {
        case "friends":
            return "В друзьях"
        case "outgoing":
            return "Отправлено"
        case "incoming":
            return "Принять"
        default:
            if profile.permissions.canSendFriendRequest {
                return "Добавить"
            }
            return profile.relation.following ? "Вы подписаны" : "Подписаться"
        }
    }

    private var relationIcon: String {
        switch profile.relation.friendStatus {
        case "friends":
            return "checkmark"
        case "outgoing":
            return "clock"
        case "incoming":
            return "checkmark"
        default:
            return profile.permissions.canSendFriendRequest ? "person.badge.plus" : "bell.badge"
        }
    }

    private var isOwnProfile: Bool {
        app.bootstrap?.me.id == profile.user.id
    }

    private var isBlocked: Bool {
        app.isUserBlocked(profile.user.id)
    }

    private var blockControl: some View {
        let isUpdating = app.isBlockActionInFlight(for: profile.user.id)
        let tint: Color = isBlocked ? .green : .red
        let title = isBlocked ? "Разблокировать" : "Заблокировать"
        let systemImage = isBlocked ? "person.badge.checkmark" : "person.fill.xmark"

        return Button {
            if isBlocked {
                app.setUserBlocked(profile.user.id, blocked: false)
            } else {
                isBlockConfirmationPresented = true
            }
        } label: {
            HStack(spacing: 10) {
                if isUpdating {
                    ProgressView()
                        .tint(tint)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 20)
                }
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(AloTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(0.42), lineWidth: 1)
            )
        }
        .disabled(isUpdating)
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))
        .confirmationDialog(
            "Заблокировать пользователя?",
            isPresented: $isBlockConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Заблокировать", role: .destructive) {
                app.setUserBlocked(profile.user.id, blocked: true)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сообщения и звонки станут недоступны.")
        }
    }

    private var blockedContactNotice: some View {
        Label(AloDirectContactPolicy.unavailableMessage, systemImage: "person.fill.xmark")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AloTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AloTheme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("Связь недоступна")
    }

    private func handleRelationTap() {
        switch profile.relation.friendStatus {
        case "incoming":
            guard profile.relation.incomingRequestId > 0 else { return }
            app.respondFriendRequest(requestId: profile.relation.incomingRequestId, accept: true)
        case "none":
            if profile.permissions.canSendFriendRequest {
                app.sendFriendRequest(userId: profile.user.id)
            } else {
                app.toggleFollowUser(userId: profile.user.id)
            }
        default:
            return
        }
    }
}

struct ChannelProfileDetailView: View {
    @EnvironmentObject private var app: AloAppModel
    let channel: AloChannelProfile
    @State private var managementPresented = false
    @State private var adminLogPresented = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            AloTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 10) {
                    VStack(spacing: 12) {
                        AloAvatar(
                            name: channel.name,
                            url: channel.avatarUrl,
                            size: 92,
                            colorSeed: "channel-\(channel.id)"
                        )
                        HStack(spacing: 6) {
                            Text(channel.name)
                                .font(.system(size: 27, weight: .bold))
                            if channel.verified {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(AloTheme.accent)
                            }
                        }
                        if !channel.username.isEmpty {
                            Text(channel.username.withAtPrefix)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AloTheme.muted)
                        }
                        if !channel.description.isEmpty {
                            Text(channel.description)
                                .font(.system(size: 16))
                                .foregroundStyle(AloTheme.text)
                                .multilineTextAlignment(.center)
                        }
                        HStack(spacing: 28) {
                            channelMetric(
                                value: channel.subscribersCount,
                                title: "подписчиков"
                            )
                            channelMetric(
                                value: channel.postsCount,
                                title: "публикаций"
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .aloCard(radius: 22)
                    .padding(.top, 8)

                    if channel.canManage {
                        HStack(spacing: 10) {
                            Button {
                                managementPresented = true
                            } label: {
                                Label("Управление", systemImage: "slider.horizontal.3")
                                    .frame(maxWidth: .infinity)
                            }
                            Button {
                                app.loadChannelAdminLog()
                                adminLogPresented = true
                            } label: {
                                Label("Журнал", systemImage: "clock.arrow.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(AloTheme.accent)
                    }

                    if channel.posts.isEmpty {
                        ContentUnavailableView(
                            "Публикаций пока нет",
                            systemImage: "megaphone",
                            description: Text("Новые записи сообщества появятся здесь.")
                        )
                        .foregroundStyle(AloTheme.muted)
                        .padding(.top, 36)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(channel.posts) { post in
                                AloPostCard(post: post) {
                                    app.toggleLike(post)
                                } onComment: {
                                    app.openComments(for: post)
                                } onRepost: {
                                    app.toggleRepost(post)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, AloTheme.pageInset)
                .padding(.bottom, 28)
            }

            Button(action: app.closeProfile) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 42, height: 46)
                    .contentShape(Rectangle())
            }
            .padding(.leading, 20)
            .padding(.top, 18)
        }
        .sheet(isPresented: $managementPresented) {
            ChannelManagementSheet(channel: channel)
                .environmentObject(app)
        }
        .sheet(isPresented: $adminLogPresented) {
            ChannelAdminLogSheet(events: app.channelAdminEvents) { action in
                app.loadChannelAdminLog(action: action)
            }
        }
    }

    private func channelMetric(value: Int, title: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AloTheme.text)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
        }
    }
}

private struct ChannelManagementSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let channel: AloChannelProfile
    @State private var commentsEnabled: Bool
    @State private var signMessages: Bool
    @State private var showAuthorProfiles: Bool

    init(channel: AloChannelProfile) {
        self.channel = channel
        _commentsEnabled = State(initialValue: channel.commentsEnabled)
        _signMessages = State(initialValue: channel.signMessages)
        _showAuthorProfiles = State(initialValue: channel.showAuthorProfiles)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Обсуждение") {
                    Toggle("Комментарии", isOn: $commentsEnabled)
                    if channel.discussionRoomId != nil {
                        Label("Группа обсуждения подключена", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                }
                Section {
                    Toggle("Подписывать сообщения", isOn: $signMessages)
                    Toggle("Показывать профиль автора", isOn: $showAuthorProfiles)
                        .disabled(!signMessages)
                } header: {
                    Text("Подписи публикаций")
                } footer: {
                    Text("Подпись формируется сервером из аккаунта администратора и не может быть подменена клиентом.")
                }
            }
            .navigationTitle("Управление сообществом")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        app.updateChannelSettings(
                            commentsEnabled: commentsEnabled,
                            signMessages: signMessages,
                            showAuthorProfiles: signMessages && showAuthorProfiles
                        )
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ChannelAdminLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let events: [AloChannelAdminEvent]
    let onFilter: (String?) -> Void
    @State private var actionFilter = "all"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Показывать", selection: $actionFilter) {
                        Text("Все").tag("all")
                        Text("Публикации").tag("post_published")
                        Text("Настройки").tag("channel_settings_updated")
                        Text("Комментарии").tag("comments")
                        Text("Администраторы").tag("moderators")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: actionFilter) { _, value in
                        switch value {
                        case "comments":
                            onFilter(nil)
                        case "moderators":
                            onFilter(nil)
                        default:
                            onFilter(value == "all" ? nil : value)
                        }
                    }
                } header: {
                    Text("Фильтр")
                }

                let displayedEvents = events.filter { event in
                    switch actionFilter {
                    case "comments":
                        return event.action == "post_comments_enabled" || event.action == "post_comments_disabled"
                    case "moderators":
                        return event.action == "moderator_added" || event.action == "moderator_removed"
                    default:
                        return true
                    }
                }
                if displayedEvents.isEmpty {
                    ContentUnavailableView(
                        "Действий пока нет",
                        systemImage: "clock.arrow.circlepath"
                    )
                } else {
                    ForEach(displayedEvents) { event in
                        HStack(alignment: .top, spacing: 12) {
                            AloAvatar(
                                name: event.actor.name,
                                url: event.actor.avatarUrl,
                                size: 38,
                                colorSeed: String(event.actor.id)
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.actor.name)
                                    .font(.system(size: 15, weight: .semibold))
                                Text(adminActionTitle(event))
                                    .font(.system(size: 14))
                                    .foregroundStyle(AloTheme.muted)
                                Text(String(event.createdAt.prefix(16)).replacingOccurrences(of: "T", with: " "))
                                    .font(.system(size: 12))
                                    .foregroundStyle(AloTheme.muted)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Журнал действий")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func adminActionTitle(_ event: AloChannelAdminEvent) -> String {
        switch event.action {
        case "channel_created": return "создал(а) сообщество"
        case "channel_settings_updated": return "изменил(а) настройки"
        case "post_published": return "опубликовал(а) запись"
        case "post_comments_enabled": return "открыл(а) комментарии"
        case "post_comments_disabled": return "закрыл(а) комментарии"
        case "moderator_added": return "назначил(а) администратора"
        case "moderator_removed": return "снял(а) администратора"
        default: return event.action
        }
    }
}

private struct ProfileHeroCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let user: AloCurrentUser
    let coverStyleOverride: String?
    let showsOwnerControls: Bool
    let primaryTitle: String?
    let primarySystemImage: String?
    let primaryAccent: Bool
    let onPrimary: (() -> Void)?
    let secondarySystemImage: String?
    let onSecondary: (() -> Void)?
    let onEditProfile: (() -> Void)?
    let onEditBanner: (() -> Void)?
    var avatarSelection: Binding<PhotosPickerItem?>? = nil
    @State private var isAvatarOptionsPresented = false
    @State private var isAvatarPickerPresented = false

    var body: some View {
        let outerRadius = AloTheme.radiusLarge
        let bannerRadius: CGFloat = outerRadius
        let bannerHeight: CGFloat = 154
        let avatarSize: CGFloat = 116
        let avatarOverlap: CGFloat = avatarSize / 2
        let hasActions = primaryTitle != nil || secondarySystemImage != nil

        VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: bannerRadius, style: .continuous)
                    .fill(aloProfileGradient(coverStyleOverride ?? user.coverStyle))
                    .frame(height: bannerHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: bannerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    }

                .overlay(alignment: .topTrailing) {
                    if showsOwnerControls {
                        HStack(spacing: 8) {
                            if let onEditProfile {
                                AloSocialSettingsButton(label: "Настройки профиля", identifier: "alo.profile.settings", action: onEditProfile)
                            }
                            if let onEditBanner {
                                Button(action: onEditBanner) {
                                    Image(systemName: "paintpalette")
                                        .font(.system(size: 19, weight: .regular))
                                        .foregroundStyle(AloTheme.muted)
                                        .frame(width: AloSocialMetrics.glassButton, height: AloSocialMetrics.glassButton)
                                        .modifier(AloChatGlass(interactive: false, role: .chrome))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(AloControlPressStyle())
                                .accessibilityLabel("Оформление профиля")
                            }
                        }.padding(12)
                    } else if hasActions {
                        profileActionRow.padding(14)
                    }
                }

            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        avatarView(size: avatarSize)
                        identity
                    }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        avatarView(size: avatarSize)
                        identity.padding(.top, avatarOverlap + 8)
                    }
                }
            }
            .padding(.leading, AloTheme.spacingLarge)
            .padding(.trailing, AloTheme.spacingLarge)
            // The row participates in layout instead of overflowing a fixed 250pt card.
            .padding(.top, -avatarOverlap + 2)
            .padding(.bottom, AloTheme.spacingLarge)
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog(
            "Фотография профиля",
            isPresented: $isAvatarOptionsPresented,
            titleVisibility: .visible
        ) {
            // A PhotosPicker placed inside a confirmation dialog never opens; the dialog button
            // only asks for the picker, which is presented on its own below.
            Button("Загрузить новое фото") { isAvatarPickerPresented = true }
            Button("Отмена", role: .cancel) {}
        }
        .photosPicker(isPresented: $isAvatarPickerPresented,
                      selection: avatarSelection ?? .constant(nil),
                      matching: .images)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Text(user.name).font(.system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                if user.verified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AloTheme.accent).accessibilityHidden(true)
                }
            }.foregroundStyle(AloTheme.text)
            Text(user.username.withAtPrefix).font(.subheadline.weight(.semibold))
                .foregroundStyle(AloTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func avatarView(size: CGFloat) -> some View {
        if showsOwnerControls, avatarSelection != nil {
            Button {
                isAvatarOptionsPresented = true
            } label: {
                AloAvatar(name: user.name, url: user.avatarUrl, size: size, colorSeed: String(user.id))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(AloTheme.accent)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(AloTheme.surface, lineWidth: 3))
                            .offset(x: 2, y: 2)
                    }
            }
            .buttonStyle(.plain)
        } else {
            AloAvatar(name: user.name, url: user.avatarUrl, size: size, colorSeed: String(user.id))
        }
    }

    private var profileActionRow: some View {
        HStack(spacing: 8) {
            if let primaryTitle, let onPrimary {
                Button(action: onPrimary) {
                    HStack(spacing: 6) {
                        if let primarySystemImage {
                            Image(systemName: primarySystemImage)
                                .font(.system(size: 13, weight: .bold))
                        }
                        Text(primaryTitle)
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 15)
                    .frame(height: 40)
                    .background(Color.black.opacity(primaryAccent ? 0.28 : 0.24))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.30), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!(primaryTitle == "Отправлено" || primaryTitle == "В друзьях"))
            }

            if let secondarySystemImage, let onSecondary {
                Button(action: onSecondary) {
                    Image(systemName: secondarySystemImage)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.24))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.30), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

}

private struct ProfilePaletteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State var selectedStyle: String
    let onApply: (String) -> Void

    private let styles = ["violet", "azure", "emerald", "sunset", "rose", "ocean"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(AloTheme.muted.opacity(0.55))
                .frame(width: 54, height: 5)
                .frame(maxWidth: .infinity)

            Text("Баннер профиля")
                .font(.system(size: 24, weight: .heavy, design: .rounded))

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(aloProfileGradient(selectedStyle))
                .frame(height: 158)
                .overlay(alignment: .bottomLeading) {
                    Text(name)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white)
                        .padding(22)
                }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(styles, id: \.self) { style in
                    Button {
                        selectedStyle = style
                    } label: {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(aloProfileGradient(style))
                            .frame(height: 86)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(selectedStyle == style ? Color.white : Color.white.opacity(0.08), lineWidth: selectedStyle == style ? 3 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)

            AloPrimaryButton(title: "Применить") {
                onApply(selectedStyle)
                dismiss()
            }
        }
        .padding(20)
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

}

private func aloProfileGradient(_ style: String) -> LinearGradient {
    let colors: [Color]
    switch style {
    case "sunset":
        colors = [
            Color(red: 0.60, green: 0.20, blue: 0.07),
            Color(red: 0.92, green: 0.35, blue: 0.03),
            Color(red: 0.98, green: 0.72, blue: 0.18)
        ]
    case "violet":
        colors = [
            Color(red: 0.36, green: 0.13, blue: 0.71),
            Color(red: 0.49, green: 0.23, blue: 0.92),
            Color(red: 0.73, green: 0.67, blue: 0.98)
        ]
    case "azure", "ocean":
        colors = [
            Color(red: 0.02, green: 0.34, blue: 0.52),
            Color(red: 0.02, green: 0.52, blue: 0.78),
            Color(red: 0.49, green: 0.83, blue: 0.98)
        ]
    case "rose":
        colors = [
            Color(red: 0.62, green: 0.09, blue: 0.30),
            Color(red: 0.86, green: 0.15, blue: 0.47),
            Color(red: 0.98, green: 0.66, blue: 0.82)
        ]
    case "emerald":
        colors = [
            Color(red: 0.06, green: 0.46, blue: 0.43),
            Color(red: 0.09, green: 0.64, blue: 0.29),
            Color(red: 0.37, green: 0.92, blue: 0.68)
        ]
    default:
        colors = [
            Color(red: 0.36, green: 0.13, blue: 0.71),
            Color(red: 0.49, green: 0.23, blue: 0.92),
            Color(red: 0.73, green: 0.67, blue: 0.98)
        ]
    }
    return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
}

enum ProfileSettingsPage: String, CaseIterable, Identifiable {
    case root
    case privacy
    case notifications
    case theme
    case business
    case security
    case passwordChange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .root: return "Настройки"
        case .privacy: return "Приватность"
        case .notifications: return "Уведомления"
        case .theme: return "Оформление"
        case .business: return "Бизнес-профиль"
        case .security: return "Безопасность"
        case .passwordChange: return "Смена пароля"
        }
    }

    var subtitle: String {
        switch self {
        case .root: return "Тема, приватность и управление аккаунтом"
        case .privacy: return "Кто может писать, звонить и видеть активность"
        case .notifications: return "Какие события приходят в Alo"
        case .theme: return "Внешний вид и режим приложения"
        case .business: return "Часы работы, приветствие и быстрые ответы"
        case .security: return "Пароль, устройства и защита аккаунта"
        case .passwordChange: return "Введите текущий и новый пароль"
        }
    }
}

struct ProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AloAppModel
    let user: AloCurrentUser?
    let notificationSettings: AloNotificationSettings
    let privacySettings: AloPrivacySettings
    let onApplyNotifications: (AloNotificationSettings) -> Void
    let onApplyPrivacy: (AloPrivacySettings) -> Void
    let onLogout: () -> Void
    /// Settings pages are pushed like any other screen: a section on top of the list, and
    /// "Смена пароля" on top of "Безопасность", so Back and the edge swipe walk up one level.
    @State private var openedPage: ProfileSettingsPage?
    @State private var isPasswordChangeOpen = false
    @State private var notificationSettingsDraft: AloNotificationSettings
    @AppStorage("alo.notificationSoundsEnabled") private var notificationSoundsEnabled = true
    @State private var allowFriendRequests: Bool
    @State private var messageScope: String
    @State private var allowMessageForwards: Bool
    @State private var callScope: String
    @State private var profileVisibility: String
    @State private var hideActivity: Bool
    @State private var chatAppearanceDraft: AloChatAppearance
    @State private var isChatAppearancePresented = false
    @State private var isBlockedUsersPresented = false
    @State private var cacheNotice = ""
    @State private var securitySessions = [AloSecuritySession]()
    @State private var securityEvents = [AloSecurityEvent]()
    @State private var securityLoading = false
    @State private var securityNotice = ""
    @State private var pendingSessionRevocation: AloSecuritySession?
    @State private var revokeOtherSessionsConfirmationPresented = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    init(
        user: AloCurrentUser?,
        notificationSettings: AloNotificationSettings,
        privacySettings: AloPrivacySettings,
        onApplyNotifications: @escaping (AloNotificationSettings) -> Void,
        onApplyPrivacy: @escaping (AloPrivacySettings) -> Void,
        onLogout: @escaping () -> Void,
        initialPage: ProfileSettingsPage = .root
    ) {
        self.user = user
        self.notificationSettings = notificationSettings
        self.privacySettings = privacySettings
        self.onApplyNotifications = onApplyNotifications
        self.onApplyPrivacy = onApplyPrivacy
        self.onLogout = onLogout
        // The notifications gear opens settings with that section already on top.
        _openedPage = State(initialValue: initialPage == .root ? nil : initialPage)
        _notificationSettingsDraft = State(initialValue: notificationSettings)
        _allowFriendRequests = State(initialValue: privacySettings.allowFriendRequests)
        _messageScope = State(initialValue: privacySettings.messageScope.ifBlank("all"))
        _allowMessageForwards = State(initialValue: privacySettings.allowMessageForwards)
        _callScope = State(initialValue: privacySettings.callScope.ifBlank("all"))
        _profileVisibility = State(initialValue: privacySettings.profileVisibility.ifBlank("all"))
        _hideActivity = State(initialValue: privacySettings.hideActivity)
        _chatAppearanceDraft = State(initialValue: AloChatAppearanceStore.readGlobal())
    }

    var body: some View {
        settingsScreen(.root)
            .navigationDestination(item: $openedPage) { page in
                settingsScreen(page)
                    .navigationDestination(isPresented: $isPasswordChangeOpen) { settingsScreen(.passwordChange) }
            }
    }

    /// One settings page as a full screen. Sheets and dialogs hang off the page that shows them,
    /// because a page covered by a pushed one can no longer present anything.
    private func settingsScreen(_ page: ProfileSettingsPage) -> some View {
        VStack(spacing: 0) {
            header(for: page)

            ScrollView(showsIndicators: false) {
                pageContent(page)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 44)
            }
        }
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .background(AloNativeBackSwipe())
        .sheet(isPresented: page == .theme ? $isChatAppearancePresented : .constant(false)) {
            ChatAppearanceSheet(appearance: chatAppearanceDraft) { updated in
                chatAppearanceDraft = updated
                AloChatAppearanceStore.saveGlobal(updated)
            }
        }
        .sheet(isPresented: page == .privacy ? $isBlockedUsersPresented : .constant(false)) {
            BlockedUsersSheet()
                .environmentObject(app)
        }
        .task {
            if page == .security {
                await loadSecuritySessions()
            }
        }
        .confirmationDialog(
            "Завершить сеанс?",
            isPresented: Binding(
                get: { page == .security && pendingSessionRevocation != nil },
                set: { if !$0 { pendingSessionRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Завершить", role: .destructive) {
                guard let session = pendingSessionRevocation else { return }
                pendingSessionRevocation = nil
                Task { await revokeSession(session) }
            }
            Button("Отмена", role: .cancel) {
                pendingSessionRevocation = nil
            }
        } message: {
            Text("На этом устройстве потребуется войти в Alo заново.")
        }
        .confirmationDialog(
            "Завершить остальные сеансы?",
            isPresented: page == .security ? $revokeOtherSessionsConfirmationPresented : .constant(false),
            titleVisibility: .visible
        ) {
            Button("Завершить остальные", role: .destructive) {
                Task { await revokeOtherSessions() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все другие устройства будут отключены от аккаунта. Это действие нельзя отменить.")
        }
    }

    /// The chat header's layout: the same glass Back in the same place, the title centred between
    /// fixed side slots.
    private func header(for page: ProfileSettingsPage) -> some View {
        let hasChanges = hasChanges(page)
        return ZStack {
            Text(page.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AloTheme.text)
                .lineLimit(1)
                .padding(.horizontal, 96)
                .accessibilityAddTraits(.isHeader)

            HStack {
                AloChatCircleButton(
                    systemImage: "chevron.left",
                    label: page == .root
                        ? "Закрыть настройки"
                        : page == .passwordChange ? "Назад к безопасности" : "Назад к настройкам"
                ) {
                    switch page {
                    case .root: dismiss()
                    case .passwordChange: isPasswordChangeOpen = false
                    default: openedPage = nil
                    }
                }
                .accessibilityIdentifier("alo.settings.back")

                Spacer(minLength: 0)
                if page == .privacy || page == .notifications {
                    Button("Сохранить") {
                        save(page)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hasChanges ? AloTheme.accent : AloTheme.muted.opacity(0.55))
                    .frame(width: 82, height: AloChatMetrics.control, alignment: .trailing)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .disabled(!hasChanges)
                    .accessibilityHint(hasChanges ? "Сохранить изменения на сервере" : "Нет изменений для сохранения")
                }
            }
        }
        .frame(height: AloChatMetrics.headerHeight)
        .padding(.horizontal, AloChatMetrics.headerHorizontalInset)
        .padding(.top, AloChatMetrics.headerTopInset)
    }

    @ViewBuilder
    private func pageContent(_ page: ProfileSettingsPage) -> some View {
        switch page {
        case .root:
            rootPage
        case .privacy:
            privacyPage
        case .notifications:
            notificationsPage
        case .theme:
            themePage
        case .business:
            BusinessProfileSettingsContent()
        case .security:
            securityPage
        case .passwordChange:
            passwordChangePage
        }
    }

    private var rootPage: some View {
        VStack(spacing: 0) {
            settingsCard(title: nil) {
                settingsNavRow(title: "Безопасность", subtitle: "", systemName: "shield", target: .security, showsIconTile: false, showsChevron: false)
                settingDivider
                settingsNavRow(title: "Приватность", subtitle: "", systemName: "hand.raised", target: .privacy, showsIconTile: false, showsChevron: false)
                settingDivider
                settingsNavRow(title: "Уведомления", subtitle: "", systemName: "bell", target: .notifications, showsIconTile: false, showsChevron: false)
                settingDivider
                settingsNavRow(title: "Бизнес-профиль", subtitle: "", systemName: "briefcase", target: .business, showsIconTile: false, showsChevron: false)
            }

            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
            Text("Версия \(version) (\(build))")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AloTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
        }
    }

    private func save(_ page: ProfileSettingsPage) {
        switch page {
        case .privacy:
            savePrivacy()
        case .notifications:
            onApplyNotifications(notificationSettingsDraft)
        default:
            return
        }
        openedPage = nil
    }

    private var privacyPage: some View {
        VStack(spacing: 14) {
            privacySelectionCard(
                title: "Стена",
                subtitle: "Кто может писать на вашей стене",
                selected: $messageScope,
                options: [
                    ("all", "Все"),
                    ("friends", "Только друзья"),
                    ("friends_of_friends", "Друзья и друзья друзей")
                ]
            )

            privacySelectionCard(
                title: "Лайки",
                subtitle: "Кто может видеть ваши лайкнутые посты",
                selected: $profileVisibility,
                options: [
                    ("all", "Все"),
                    ("friends", "Только друзья")
                ]
            )

            settingsCard(title: nil) {
                settingToggle(
                    title: "Онлайн-статус",
                    subtitle: "Показывать время последнего визита",
                    isOn: Binding(
                        get: { !hideActivity },
                        set: { hideActivity = !$0 }
                    )
                )
            }

            settingsCard(title: nil) {
                blacklistRow
            }

            settingsCard(title: "Дополнительно") {
                settingToggle(
                    title: "Заявки в друзья",
                    subtitle: "Разрешать другим отправлять запросы",
                    isOn: $allowFriendRequests
                )
                settingDivider
                settingToggle(
                    title: "Пересылка сообщений",
                    subtitle: "Разрешать другим пересылать ваши сообщения",
                    isOn: $allowMessageForwards
                )
                settingDivider
                privacyInlineSelection(
                    title: "Кто может звонить",
                    selected: $callScope,
                    options: [
                        ("friends", "Друзья"),
                        ("friends_of_friends", "Друзья и друзья друзей"),
                        ("all", "Все, включая незнакомых"),
                        ("none", "Никто")
                    ]
                )
            }
        }
    }

    private var notificationsPage: some View {
        VStack(spacing: 22) {
            settingsCard(title: "Основные") {
                settingToggle(
                    title: "Уведомления",
                    subtitle: "Включение или отключение всех уведомлений",
                    systemName: "bell.fill",
                    isOn: allNotificationsBinding
                )
                settingDivider
                settingToggle(
                    title: "Уведомления со звуком",
                    subtitle: "Воспроизводить звуки уведомлений",
                    systemName: "bell.and.waves.left.and.right.fill",
                    isOn: $notificationSoundsEnabled
                )
            }

            settingsCard(title: "Пользователи") {
                settingToggle(
                    title: "Подписки",
                    subtitle: "Уведомления о подписках и запросах в друзья",
                    systemName: "person.badge.plus",
                    isOn: $notificationSettingsDraft.followsEnabled
                )
                settingDivider
                settingToggle(
                    title: "Посты на стене",
                    subtitle: "Уведомления о новых постах на вашей стене",
                    systemName: "text.bubble.fill",
                    isOn: $notificationSettingsDraft.friendRequestsEnabled
                )
            }

            settingsCard(title: "Посты") {
                settingToggle(
                    title: "Лайки и реакции",
                    subtitle: "Уведомления о реакциях на ваши посты и комментарии",
                    systemName: "heart.fill",
                    tint: Color(red: 1.0, green: 0.28, blue: 0.36),
                    isOn: $notificationSettingsDraft.likesEnabled
                )
                settingDivider
                settingToggle(
                    title: "Комментарии и ответы",
                    subtitle: "Уведомления о новых комментариях и ответах",
                    systemName: "bubble.left.and.bubble.right.fill",
                    isOn: $notificationSettingsDraft.commentsEnabled
                )
                settingDivider
                settingToggle(
                    title: "Упоминания",
                    subtitle: "Уведомления, когда вас упоминают в постах",
                    systemName: "at",
                    tint: AloTheme.success,
                    isOn: $notificationSettingsDraft.repostsEnabled
                )
            }

            settingsCard(title: "Дополнительно") {
                settingToggle(
                    title: "Сообщения",
                    subtitle: "Новые личные и групповые сообщения",
                    systemName: "bubble.fill",
                    isOn: $notificationSettingsDraft.messagesEnabled
                )
                settingDivider
                settingToggle(
                    title: "Лайки комментариев",
                    subtitle: "Реакции на ваши комментарии",
                    systemName: "hand.thumbsup.fill",
                    tint: Color(red: 0.49, green: 0.42, blue: 0.96),
                    isOn: $notificationSettingsDraft.commentLikesEnabled
                )
                settingDivider
                settingToggle(
                    title: "Принятые заявки",
                    subtitle: "Когда другой пользователь принимает вашу заявку",
                    systemName: "person.crop.circle.badge.checkmark",
                    tint: AloTheme.success,
                    isOn: $notificationSettingsDraft.friendAcceptsEnabled
                )
                settingDivider
                settingToggle(
                    title: "Сообщества",
                    subtitle: "События сообществ, на которые вы подписаны",
                    systemName: "megaphone.fill",
                    tint: AloTheme.success,
                    isOn: $notificationSettingsDraft.channelSubscriptionsEnabled
                )
            }
        }
    }

    private var themePage: some View {
        VStack(spacing: 22) {
            settingsCard(title: "Интерфейс") {
                HStack(spacing: 12) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 40, height: 40)
                        .background(AloTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Тёмная тема")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                        Text("Системная палитра Alo")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(AloTheme.muted)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AloTheme.accent)
                }
            }

            settingsCard(title: nil) {
                settingsActionRow(
                    title: "Оформление чатов",
                    subtitle: "Обои, цвета сообщений и интервалы во всех диалогах",
                    systemName: "paintpalette.fill",
                    tint: chatAppearanceDraft.outgoingColor
                ) {
                    isChatAppearancePresented = true
                }
            }

            infoRow(
                title: "Текущий вариант",
                value: AloChatAppearance.presets.first(where: { $0.id == chatAppearanceDraft.preset })?.title ?? "Пользовательский"
            )
        }
    }

    private var securityPage: some View {
        VStack(spacing: 22) {
            settingsCard(title: nil) {
                settingsActionRow(
                    title: "Сменить пароль",
                    subtitle: "После смены пароля другие устройства будут отключены",
                    systemName: "key.fill",
                    tint: AloTheme.accent
                ) {
                    isPasswordChangeOpen = true
                }
            }

            AloAccountSecurityControls()
                .environmentObject(app)

            if !securityNotice.isEmpty {
                infoRow(title: "Безопасность", value: securityNotice)
            }

            settingsCard(title: "Активные устройства") {
                if securityLoading && securitySessions.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().tint(AloTheme.accent)
                        Text("Загружаем устройства…")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AloTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if securitySessions.isEmpty {
                    Text("Активных сеансов не найдено.")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                } else {
                    ForEach(Array(securitySessions.enumerated()), id: \.element.id) { index, session in
                        securitySessionRow(session)
                        if index < securitySessions.count - 1 {
                            settingDivider
                        }
                    }
                }
            }

            if securitySessions.contains(where: { !$0.current && !$0.canRevoke }) {
                infoRow(
                    title: "Защита нового устройства",
                    value: "Сеансы, созданные до этого входа, нельзя завершить в течение первых 24 часов."
                )
            }

            if securitySessions.contains(where: { !$0.current }) {
                settingsCard(title: nil) {
                    settingsActionRow(
                        title: "Завершить остальные сеансы",
                        subtitle: securitySessions.contains(where: { !$0.current && !$0.canRevoke })
                            ? "Станет доступно после периода защиты нового входа"
                            : "Оставить активным только это устройство",
                        systemName: "rectangle.stack.badge.minus",
                        tint: .red
                    ) {
                        guard !securityLoading,
                              !securitySessions.contains(where: { !$0.current && !$0.canRevoke }) else { return }
                        revokeOtherSessionsConfirmationPresented = true
                    }
                    .disabled(!canRevokeOtherSessions)
                    .opacity(canRevokeOtherSessions ? 1 : 0.48)
                }
            }

            if !securityEvents.isEmpty {
                settingsCard(title: "Недавняя активность") {
                    ForEach(Array(securityEvents.prefix(6).enumerated()), id: \.element.id) { index, event in
                        securityEventRow(event)
                        if index < min(securityEvents.count, 6) - 1 {
                            settingDivider
                        }
                    }
                }
            }

            settingsCard(title: nil) {
                settingsActionRow(
                    title: "Выйти из аккаунта",
                    subtitle: "Завершить текущий сеанс на этом устройстве",
                    systemName: "rectangle.portrait.and.arrow.right",
                    tint: AloTheme.destructive
                ) {
                    onLogout()
                    dismiss()
                }
            }
        }
    }

    private var passwordChangePage: some View {
        VStack(spacing: 22) {
            settingsCard(title: "Новый пароль") {
                secureField("Текущий пароль", text: $currentPassword)
                settingDivider
                secureField("Новый пароль", text: $newPassword)
                settingDivider
                secureField("Повторите новый пароль", text: $confirmPassword)
            }

            Text("Новый пароль должен содержать не менее 8 символов. После смены пароля остальные активные устройства будут отключены.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AloTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await changePassword() }
            } label: {
                Text(securityLoading ? "Сохраняем…" : "Изменить пароль")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(passwordChangeDisabled ? AloTheme.surfaceRaised : AloTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))
            .disabled(passwordChangeDisabled || securityLoading)

            if !securityNotice.isEmpty {
                infoRow(title: "Безопасность", value: securityNotice)
            }
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Аккаунт")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AloTheme.muted)
            Text(user?.name ?? "Alo")
                .font(.system(size: 19, weight: .bold, design: .rounded))
            Text("Настройки синхронизируются с сервером и применяются на всех устройствах.")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(AloTheme.muted)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AloTheme.border.opacity(0.75), lineWidth: 1)
        }
    }

    private func settingsNavRow(
        title: String,
        subtitle: String,
        systemName: String,
        target: ProfileSettingsPage,
        showsIconTile: Bool = true,
        showsChevron: Bool = true
    ) -> some View {
        let tint: Color
        switch target {
        case .privacy: tint = Color(red: 0.20, green: 0.77, blue: 0.39)
        case .notifications: tint = Color(red: 0.11, green: 0.54, blue: 0.98)
        case .theme: tint = Color(red: 0.53, green: 0.41, blue: 0.94)
        case .business: tint = Color(red: 0.10, green: 0.69, blue: 0.46)
        case .security: tint = Color(red: 1.0, green: 0.62, blue: 0.06)
        case .passwordChange: tint = AloTheme.accent
        case .root: tint = AloTheme.accent
        }
        return Button {
            openedPage = target
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.system(size: showsIconTile ? 18 : 17, weight: .semibold))
                    .foregroundStyle(showsIconTile ? Color.white : AloTheme.text)
                    .frame(width: showsIconTile ? 34 : 22, height: showsIconTile ? 34 : 44)
                    .background {
                        if showsIconTile {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(tint)
                        }
                    }
                VStack(alignment: .leading, spacing: subtitle.isEmpty ? 0 : 3) {
                    Text(title)
                    .font(.system(size: subtitle.isEmpty ? 17 : 16, weight: subtitle.isEmpty ? .regular : .semibold))
                        .foregroundStyle(AloTheme.text)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(AloTheme.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(AloTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: subtitle.isEmpty ? 44 : 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
        .accessibilityHint("Открыть раздел \(title)")
    }

    private func settingsActionRow(
        title: String,
        subtitle: String,
        systemName: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 34, height: 34)
                    .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AloTheme.text)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(AloTheme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(AloTheme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
    }

    private var allNotificationsBinding: Binding<Bool> {
        Binding(
            get: {
                notificationSettingsDraft.messagesEnabled &&
                    notificationSettingsDraft.friendRequestsEnabled &&
                    notificationSettingsDraft.friendAcceptsEnabled &&
                    notificationSettingsDraft.followsEnabled &&
                    notificationSettingsDraft.likesEnabled &&
                    notificationSettingsDraft.commentsEnabled &&
                    notificationSettingsDraft.commentLikesEnabled &&
                    notificationSettingsDraft.repostsEnabled &&
                    notificationSettingsDraft.channelSubscriptionsEnabled
            },
            set: { isEnabled in
                notificationSettingsDraft = AloNotificationSettings(
                    likesEnabled: isEnabled,
                    commentsEnabled: isEnabled,
                    repostsEnabled: isEnabled,
                    followsEnabled: isEnabled,
                    messagesEnabled: isEnabled,
                    friendRequestsEnabled: isEnabled,
                    friendAcceptsEnabled: isEnabled,
                    channelSubscriptionsEnabled: isEnabled,
                    commentLikesEnabled: isEnabled
                )
            }
        )
    }

    private func hasChanges(_ page: ProfileSettingsPage) -> Bool {
        switch page {
        case .notifications:
            return notificationSettingsDraft != notificationSettings
        case .privacy:
            return AloPrivacySettings(
                allowFriendRequests: allowFriendRequests,
                messageScope: messageScope,
                allowMessageForwards: allowMessageForwards,
                callScope: callScope,
                profileVisibility: profileVisibility,
                hideActivity: hideActivity
            ) != privacySettings
        default:
            return false
        }
    }

    private func privacySelectionCard(
        title: String,
        subtitle: String,
        selected: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        settingsCard(title: nil) {
            privacySelectionContent(
                title: title,
                subtitle: subtitle,
                selected: selected,
                options: options,
                compact: false
            )
        }
    }

    private func privacyInlineSelection(
        title: String,
        selected: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        privacySelectionContent(
            title: title,
            subtitle: "",
            selected: selected,
            options: options,
            compact: true
        )
    }

    private func privacySelectionContent(
        title: String,
        subtitle: String,
        selected: Binding<String>,
        options: [(String, String)],
        compact: Bool
    ) -> some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(option.1) {
                    selected.wrappedValue = option.0
                }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: compact ? 16 : 17, weight: .regular))
                        .foregroundStyle(AloTheme.text)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(AloTheme.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 10)
                HStack(spacing: 5) {
                    Text(options.first(where: { $0.0 == selected.wrappedValue })?.1 ?? "Все")
                        .font(.system(size: 17, weight: .regular))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(AloTheme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 56 : 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Выбрать параметр \(title)")
    }

    private var blacklistRow: some View {
        Button {
            isBlockedUsersPresented = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "nosign")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(AloTheme.text)
                    .frame(width: 30, height: 44)
                Text("Чёрный список")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(AloTheme.text)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
        .accessibilityHint("Открыть список заблокированных пользователей")
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .textContentType(.password)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(AloTheme.text)
            .padding(.vertical, 9)
            .frame(minHeight: 50)
    }

    private func securitySessionRow(_ session: AloSecuritySession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: securitySessionIcon(session.deviceType))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(session.isSuspicious ? Color.red : AloTheme.accent)
                .frame(width: 40, height: 40)
                .background(
                    (session.isSuspicious ? Color.red : AloTheme.accent).opacity(0.14),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.deviceLabel)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    if session.current {
                        Text("это устройство")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(AloTheme.accent)
                    }
                }
                Text(securitySessionSubtitle(session))
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(session.isSuspicious ? Color.red : AloTheme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)

            if !session.current {
                Button {
                    pendingSessionRevocation = session
                } label: {
                    Image(systemName: session.canRevoke ? "xmark" : "lock.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(session.canRevoke ? Color.red : AloTheme.muted)
                        .frame(width: 40, height: 40)
                        .background(
                            (session.canRevoke ? Color.red : AloTheme.muted).opacity(0.12),
                            in: Circle()
                        )
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.88))
                .disabled(securityLoading || !session.canRevoke)
                .accessibilityLabel(session.canRevoke ? "Завершить сеанс \(session.deviceLabel)" : "Сеанс \(session.deviceLabel) защищён новым входом")
            }
        }
        .padding(.vertical, 10)
    }

    private func securityEventRow(_ event: AloSecurityEvent) -> some View {
        HStack(spacing: 11) {
            Image(systemName: securityEventIcon(event))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(event.riskLevel == "high" ? Color.red : AloTheme.accent)
                .frame(width: 34, height: 34)
                .background(
                    (event.riskLevel == "high" ? Color.red : AloTheme.accent).opacity(0.14),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(securityEventTitle(event))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AloTheme.text)
                Text([AloFormatters.messageDateLabel(event.createdAt), AloFormatters.messageTime(event.createdAt), event.ip]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }

    private func securityEventTitle(_ event: AloSecurityEvent) -> String {
        switch event.eventType {
        case "login_verified": return "Вход с нового устройства"
        case "password_changed": return "Пароль изменён"
        case "session_revoked": return "Сеанс завершён"
        case "sessions_revoked_others": return "Завершены другие сеансы"
        case "session_revoked_current": return "Выполнен выход с устройства"
        default: return "Событие безопасности"
        }
    }

    private func securityEventIcon(_ event: AloSecurityEvent) -> String {
        switch event.eventType {
        case "login_verified": return "arrow.right.circle.fill"
        case "password_changed": return "key.fill"
        case "session_revoked", "sessions_revoked_others", "session_revoked_current": return "rectangle.portrait.and.arrow.right"
        default: return "checkmark.shield.fill"
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AloTheme.text)
            Text(value)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(AloTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func settingsCard<Content: View>(title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AloTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingToggle(
        title: String,
        subtitle: String,
        systemName: String? = nil,
        tint: Color = AloTheme.accent,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn.animation(.spring(response: 0.24, dampingFraction: 0.9))) {
            HStack(spacing: 9) {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(tint)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .regular))
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(AloTheme.muted)
                        .lineLimit(2)
                }
            }
        }
        .tint(AloTheme.success)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: systemName == nil ? 62 : 68, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var settingDivider: some View {
        Rectangle()
            .fill(AloTheme.separator)
            .frame(height: 0.5)
    }

    private func settingDivider(inset: CGFloat) -> some View {
        Rectangle()
            .fill(AloTheme.separator)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }

    private func choiceBlock(title: String, options: [(String, String)], selected: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .heavy, design: .rounded))

            ForEach(Array(options.enumerated()), id: \.element.0) { index, option in
                let value = option.0
                let label = option.1
                Toggle(isOn: Binding(
                    get: { selected.wrappedValue == value },
                    set: { isOn in
                        guard isOn else { return }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            selected.wrappedValue = value
                        }
                    }
                )) {
                    Text(label)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(AloTheme.text)
                }
                .tint(AloTheme.accent)

                if index < options.count - 1 {
                    settingDivider.opacity(0.55)
                }
            }
        }
    }

    private func savePrivacy() {
        onApplyPrivacy(AloPrivacySettings(
            allowFriendRequests: allowFriendRequests,
            messageScope: messageScope,
            allowMessageForwards: allowMessageForwards,
            callScope: callScope,
            profileVisibility: profileVisibility,
            hideActivity: hideActivity
        ))
    }

    private var passwordChangeDisabled: Bool {
        currentPassword.isEmpty || newPassword.count < 8 || confirmPassword.count < 8
    }

    private var canRevokeOtherSessions: Bool {
        !securityLoading && !securitySessions.contains(where: { !$0.current && !$0.canRevoke })
    }

    private func securitySessionIcon(_ deviceType: String) -> String {
        switch deviceType.lowercased() {
        case "phone", "mobile": return "iphone"
        case "tablet": return "ipad"
        default: return "desktopcomputer"
        }
    }

    private func securitySessionSubtitle(_ session: AloSecuritySession) -> String {
        var parts = [String]()
        if !session.lastSeenAt.isEmpty {
            parts.append("\(AloFormatters.messageDateLabel(session.lastSeenAt)), \(AloFormatters.messageTime(session.lastSeenAt))")
        }
        if !session.ip.isEmpty {
            parts.append(session.ip)
        }
        if session.isSuspicious {
            parts.append("требует внимания")
        }
        if !session.current && !session.canRevoke {
            let availableDate = AloFormatters.messageDateLabel(session.revokeAvailableAt)
            let availableTime = AloFormatters.messageTime(session.revokeAvailableAt)
            parts.append(
                session.revokeAvailableAt.isEmpty
                    ? "защищён новым входом"
                    : "можно завершить \(availableDate), \(availableTime)"
            )
        }
        return parts.joined(separator: " · ").ifBlank(session.platform)
    }

    @MainActor
    private func loadSecuritySessions() async {
        securityLoading = true
        defer { securityLoading = false }
        do {
            async let sessionsRequest = app.api.loadSecuritySessions()
            async let eventsRequest = app.api.loadSecurityEvents()
            securitySessions = try await sessionsRequest
            securityEvents = (try? await eventsRequest) ?? securityEvents
        } catch let error as AloAPIError {
            securityNotice = error.message
        } catch {
            securityNotice = "Не удалось загрузить активные сеансы."
        }
    }

    @MainActor
    private func changePassword() async {
        guard newPassword == confirmPassword else {
            securityNotice = "Новые пароли не совпадают."
            return
        }
        securityLoading = true
        defer { securityLoading = false }
        do {
            let revoked = try await app.api.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword
            )
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            securityNotice = revoked > 0
                ? "Пароль изменён. Завершено других сеансов: \(revoked)."
                : "Пароль изменён."
            await refreshSecurityData()
            isPasswordChangeOpen = false
        } catch let error as AloAPIError {
            securityNotice = error.message
        } catch {
            securityNotice = "Не удалось изменить пароль."
        }
    }

    @MainActor
    private func revokeSession(_ session: AloSecuritySession) async {
        guard !session.current, session.canRevoke else { return }
        securityLoading = true
        defer { securityLoading = false }
        do {
            try await app.api.revokeSecuritySession(id: session.id)
            await refreshSecurityData()
            securityNotice = "Сеанс завершён."
        } catch let error as AloAPIError {
            securityNotice = error.message
        } catch {
            securityNotice = "Не удалось завершить сеанс."
        }
    }

    @MainActor
    private func revokeOtherSessions() async {
        securityLoading = true
        defer { securityLoading = false }
        do {
            let revoked = try await app.api.revokeOtherSecuritySessions()
            await refreshSecurityData()
            securityNotice = revoked > 0
                ? "Завершено других сеансов: \(revoked)."
                : "Других активных сеансов нет."
        } catch let error as AloAPIError {
            securityNotice = error.message
        } catch {
            securityNotice = "Не удалось завершить другие сеансы."
        }
    }

    @MainActor
    private func refreshSecurityData() async {
        do {
            async let sessionsRequest = app.api.loadSecuritySessions()
            async let eventsRequest = app.api.loadSecurityEvents()
            securitySessions = try await sessionsRequest
            securityEvents = (try? await eventsRequest) ?? securityEvents
        } catch let error as AloAPIError {
            securityNotice = error.message
        } catch {
            securityNotice = "Не удалось обновить список устройств."
        }
    }
}

private struct BlockedUsersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AloAppModel

    private var blockedIds: [Int] {
        app.blockedUserIds.sorted()
    }

    private func user(for id: Int) -> AloEntitySummary? {
        app.bootstrap?.searchUsers.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Чёрный список")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AloTheme.text)

                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(AloTheme.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Закрыть чёрный список")

                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 8)

            if blockedIds.isEmpty {
                ContentUnavailableView(
                    "Чёрный список пуст",
                    systemImage: "nosign",
                    description: Text("Заблокированные пользователи появятся здесь."))
                .foregroundStyle(AloTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(blockedIds, id: \.self) { id in
                            let user = user(for: id)
                            HStack(spacing: 10) {
                                AloAvatar(
                                    name: user?.name ?? "Пользователь",
                                    url: user?.avatarUrl ?? "",
                                    size: 34,
                                    colorSeed: String(id)
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user?.name ?? "Пользователь #\(id)")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AloTheme.text)
                                        .lineLimit(1)
                                    if let username = user?.username, !username.isEmpty {
                                        Text("@\(username)")
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundStyle(AloTheme.muted)
                                    } else {
                                        Text("Заблокирован")
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundStyle(AloTheme.muted)
                                    }
                                }

                                Spacer(minLength: 8)

                                Button("Разблокировать") {
                                    app.setUserBlocked(id, blocked: false)
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AloTheme.accent)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                                .buttonStyle(.plain)
                                .disabled(app.isBlockActionInFlight(for: id))
                            }
                            .frame(maxWidth: .infinity, minHeight: 56)

                            if id != (blockedIds.last ?? id) {
                                Rectangle()
                                    .fill(AloTheme.separator)
                                    .frame(height: 0.5)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(AloTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 36)
                }
            }
        }
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
    }
}

private struct ProfileContentSwitcher: View {
    @Binding var selected: ProfileSection

    var body: some View {
        AloSocialSegments(values: ProfileSection.allCases, selected: $selected,
            title: { $0.title }, identifier: { "alo.profile.tab.\($0.rawValue)" })
    }
}

private enum ProfileSection: String, CaseIterable, Identifiable {
    case posts
    case likes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .posts: return "Посты"
        case .likes: return "Нравится"
        }
    }
}
