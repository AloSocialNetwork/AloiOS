import SwiftUI
import PhotosUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject private var app: AloAppModel
    // Only the posts, under «Записи», as on the website (the owner, 2026-10-28: no «Посты / Нравится» switch).
    private let selectedSection: ProfileSection = .posts
    @State private var isPalettePresented = false
    @State private var isEditPresented = false
    @State private var isProfileInfoPresented = false
    @State private var isComposerPresented = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var avatarCrop: AloAvatarCropRequest?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let data = app.bootstrap {
                    ProfileHeroCard(
                        user: data.me,
                        coverStyleOverride: nil,
                        showsOwnerControls: true,
                        // The website's own page: «Редактировать» and «Новая запись» under the counts.
                        primaryTitle: "Редактировать",
                        primarySystemImage: "pencil",
                        primaryAccent: false,
                        onPrimary: { isProfileInfoPresented = true },
                        secondarySystemImage: "square.and.pencil",
                        onSecondary: { isComposerPresented = true },
                        onEditProfile: { isEditPresented = true },
                        onEditBanner: { isPalettePresented = true },
                        avatarSelection: $selectedAvatarItem,
                        details: AloProfileHeroDetails(bio: data.me.bio, counts: AloProfileHeroDetails.personCounts(data.profileStats)),
                        websiteLayout: true,
                        secondaryTitle: "Новая запись"
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
                        AloLoadMoreRow(list: selectedSection == .posts ? .profilePosts : .likedPosts, loaded: posts.count)
                    } header: {
                        stickyProfileSwitcher
                    }
                }
            }
            .padding(.bottom, AloSocialMetrics.bottomClearance)
        }
        .accessibilityIdentifier("alo.profile.scroll")
        // Posts scrolling up would otherwise slide under the clock.
        .overlay(alignment: .top) {
            // Laid out below the status bar, the shade reaches up under it by the safe area.
            GeometryReader { proxy in
                AloSocialTitleShade()
                    .frame(height: proxy.safeAreaInsets.top + AloTheme.spacingSmall)
                    .offset(y: -proxy.safeAreaInsets.top)
            }
            .frame(height: AloTheme.spacingSmall)
            .allowsHitTesting(false)
        }
        .background(AloTheme.background)
        .refreshable { await app.loadBootstrap() }
        // «Нравится» asks the server for every liked post when the tab is opened.
        .onChange(of: selectedSection) { _, section in
            if section == .likes, app.likedPosts.isEmpty { app.loadMore(.likedPosts) }
        }
        .fullScreenCover(isPresented: $isPalettePresented) {
            if let me = app.bootstrap?.me {
                AloProfileBannerEditor(user: me) { style, photo in
                    app.updateProfileBanner(style: style, photo: photo)
                }
                .environment(\.aloAPIClient, app.api)
            }
        }
        .navigationDestination(isPresented: $isEditPresented) {
            AloSocialSettingsSheet().environmentObject(app)
        }
        .navigationDestination(isPresented: $isProfileInfoPresented) {
            AloSocialSettingsSheet(initialPage: .profileInfo).environmentObject(app)
        }
        .fullScreenCover(isPresented: $isComposerPresented) {
            PostComposerSheet().environmentObject(app)
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

    /// «Нравится»: the server's list of every liked post, with what is already on the screen while it loads.
    private var ownLikedPosts: [AloPost] {
        guard let data = app.bootstrap else { return [] }
        var seen = Set<Int>()
        return (app.likedPosts + data.profilePosts + data.feedPopular + data.feedSubscriptions).filter { post in
            post.viewerLiked && seen.insert(post.id).inserted
        }
    }

    private var stickyProfileSwitcher: some View {
        AloProfilePostsTitle()
            .padding(.horizontal, AloSocialMetrics.inset)
    }
}

struct ProfileDetailView: View {
    @EnvironmentObject private var app: AloAppModel
    let profile: AloUserProfile
    // Only the posts, under «Записи», as on the website (the owner, 2026-10-28: no «Посты / Нравится» switch).
    private let selectedSection: ProfileSection = .posts
    @State private var isBlockConfirmationPresented = false
    @State private var isRelationUndoPresented = false
    @State private var reportTarget: AloReportTarget?

    var body: some View {
        ZStack(alignment: .topLeading) {
            AloTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
            viewedProfileTopBar
            ScrollView {
                LazyVStack(spacing: 0) {
                    ProfileHeroCard(
                        user: profile.user,
                        coverStyleOverride: nil,
                        showsOwnerControls: false,
                        primaryTitle: relationTitle,
                        primarySystemImage: relationIcon,
                        primaryAccent: relationIsInvitation,
                        onPrimary: handleRelationTap,
                        secondarySystemImage: profile.permissions.canMessage && !isBlocked ? "message.fill" : nil,
                        onSecondary: profile.permissions.canMessage && !isBlocked ? { app.openConversation(with: profile) } : nil,
                        onEditProfile: nil,
                        onEditBanner: nil,
                        moreMenu: nil,
                        // The website shows no registration date on a profile.
                        details: AloProfileHeroDetails(
                            bio: profile.user.bio,
                            counts: AloProfileHeroDetails.personCounts(profile.stats)
                        ),
                        websiteLayout: true,
                        showsOnline: profile.user.online
                    )
                    .padding(.horizontal, AloTheme.pageInset)
                    .padding(.top, 4)
                    .padding(.bottom, AloTheme.spacingSmall)

                    if !isOwnProfile, isBlocked {
                        blockedContactNotice
                            .padding(.horizontal, AloTheme.pageInset)
                            .padding(.bottom, AloTheme.spacingSmall)
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
                            if selectedSection == .posts {
                                AloLoadMoreRow(list: .viewedProfilePosts, loaded: posts.count)
                            }
                        } header: {
                            AloProfilePostsTitle()
                                .padding(.horizontal, AloTheme.pageInset)
                        }
                    }
                }
                .padding(.bottom, 28)
            }
            .clipped()
            .confirmationDialog(
                "Заблокировать \(profile.user.name)?",
                isPresented: $isBlockConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Заблокировать", role: .destructive) {
                    app.setUserBlocked(profile.user.id, blocked: true)
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Этот человек больше не сможет вам писать и звонить. Разблокировать можно здесь же или в настройках.")
            }
            // «В друзьях» and «Заявка отправлена» are not dead ends: a tap asks to undo them.
            .confirmationDialog(
                profile.relation.friendStatus == "friends" ? "Удалить из друзей?" : "Отменить заявку в друзья?",
                isPresented: $isRelationUndoPresented,
                titleVisibility: .visible
            ) {
                if profile.relation.friendStatus == "friends" {
                    Button("Удалить из друзей", role: .destructive) { app.removeFriend(userId: profile.user.id) }
                } else {
                    Button("Отменить заявку", role: .destructive) {
                        app.cancelFriendRequest(requestId: profile.relation.outgoingRequestId, userId: profile.user.id)
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                // The name is not declined, so it stands as it is in the text, not in the question.
                Text(profile.relation.friendStatus == "friends"
                     ? "\(profile.user.name) больше не будет в списке ваших друзей."
                     : "\(profile.user.name) не получит вашу заявку.")
            }
            .sheet(item: $reportTarget) { target in
                AloReportSheet(target: target) { reason, details in
                    try await app.report(target, reason: reason, details: details)
                }
            }

            }
        }
    }

    /// The website's profile bar: Back, the person's name in the middle, «⋯» with the profile's actions.
    private var viewedProfileTopBar: some View {
        HStack(spacing: 8) {
            AloChatCircleButton(systemImage: "chevron.left", label: "Назад", action: app.closeProfile)
                .accessibilityIdentifier("alo.profile.back")
            Text(profile.user.name)
                .font(.headline)
                .foregroundStyle(AloTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            if isOwnProfile {
                Color.clear.frame(width: AloChatMetrics.control, height: AloChatMetrics.control)
            } else {
                Menu { profileMenuItems } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(AloTheme.text)
                        .frame(width: AloChatMetrics.control, height: AloChatMetrics.control)
                        .modifier(AloChatGlass())
                        .contentShape(Circle())
                }
                .accessibilityLabel("Ещё")
                .accessibilityIdentifier("alo.profile.more")
            }
        }
        .padding(.horizontal, AloTheme.pageInset)
        .padding(.top, 4)
        .padding(.bottom, 8)
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

    /// One friend / follow button, the rule of the website and Android (the owner, 2026-10-28): a friend request first;
    /// following only when the person closed friend requests, and a follow back makes friends (the server does it).
    private var relationTitle: String {
        switch profile.relation.friendStatus {
        case "friends":
            return "В друзьях"
        case "outgoing":
            return "Заявка отправлена"
        case "incoming":
            return "Принять заявку"
        default:
            if profile.permissions.canSendFriendRequest {
                return "В друзья" // «Добавить в друзья» did not fit the button (the owner, 2026-10-28)
            }
            if profile.relation.following { return "Вы подписаны" }
            return profile.relation.followedBy ? "Подписаться в ответ" : "Подписаться"
        }
    }

    /// The button calls to act (a request, an answer, a follow), not reports a state.
    private var relationIsInvitation: Bool {
        switch profile.relation.friendStatus {
        case "friends", "outgoing": return false
        case "incoming": return true
        default: return profile.permissions.canSendFriendRequest || !profile.relation.following
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
            return profile.permissions.canSendFriendRequest ? "plus" : "bell.badge"
        }
    }

    private var isOwnProfile: Bool {
        app.bootstrap?.me.id == profile.user.id
    }

    private var isBlocked: Bool {
        app.isUserBlocked(profile.user.id)
    }

    /// What the «⋯» on the banner offers. Blocking asks first; the big buttons under the card are gone (owner, 2026-10-27).
    @ViewBuilder
    private var profileMenuItems: some View {
        if app.secretChats.available, profile.permissions.canMessage, !isBlocked {
            Button {
                Task { if let problem = await app.secretChats.start(userId: profile.user.id) { app.notice = problem } }
            } label: { Label("Начать секретный чат", systemImage: "lock.fill") }
            .accessibilityIdentifier("alo.profile.secret-chat")
        }
        if let url = AloServerConfiguration.appLinkURL(path: "u/\(profile.user.id)") {
            ShareLink(item: url) { Label("Поделиться", systemImage: "square.and.arrow.up") }
            Button { UIPasteboard.general.url = url } label: { Label("Скопировать ссылку", systemImage: "link") }
        }
        Button { reportTarget = .user(profile.user.id) } label: {
            Label("Пожаловаться", systemImage: "exclamationmark.bubble")
        }
        .accessibilityIdentifier("alo.profile.report")
        // Staff with the «Верификация» right give or take the checkmark on the spot, with no request (as on the website).
        if app.bootstrap?.me.adminCan.contains("verification") == true {
            Button {
                let verified = profile.user.verified
                Task {
                    do {
                        try await app.api.setVerified(targetType: "user", targetId: profile.user.id, verified: !verified)
                        app.notice = verified ? "Галочка снята" : "Галочка выдана"
                        app.openProfile(userId: profile.user.id)
                    } catch let failure as AloAPIError {
                        app.notice = failure.message
                    } catch {
                        app.notice = "Не удалось изменить галочку."
                    }
                }
            } label: {
                Label(profile.user.verified ? "Снять галочку" : "Выдать галочку", systemImage: "checkmark.seal")
            }
            .accessibilityIdentifier("alo.profile.verify")
        }
        Divider()
        if isBlocked {
            Button { app.setUserBlocked(profile.user.id, blocked: false) } label: {
                Label("Разблокировать", systemImage: "person.badge.checkmark")
            }
        } else {
            Button(role: .destructive) { isBlockConfirmationPresented = true } label: {
                Label("Заблокировать", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("alo.profile.block")
        }
    }

    private var blockedContactNotice: some View {
        let isUpdating = app.isBlockActionInFlight(for: profile.user.id)
        return HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
            Text("Вы заблокировали этого человека")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                app.setUserBlocked(profile.user.id, blocked: false)
            } label: {
                if isUpdating {
                    ProgressView().frame(width: 20, height: 20)
                } else {
                    Text("Разблокировать").font(.system(size: 14, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(AloTheme.accent)
            .disabled(isUpdating)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AloTheme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func handleRelationTap() {
        switch profile.relation.friendStatus {
        case "incoming":
            guard profile.relation.incomingRequestId > 0 else { return }
            app.respondFriendRequest(requestId: profile.relation.incomingRequestId, accept: true)
        case "friends":
            isRelationUndoPresented = true
        case "outgoing":
            if profile.relation.outgoingRequestId > 0 { isRelationUndoPresented = true }
        default:
            if profile.permissions.canSendFriendRequest {
                app.sendFriendRequest(userId: profile.user.id)
            } else {
                app.toggleFollowUser(userId: profile.user.id)
            }
        }
    }
}

struct ChannelProfileDetailView: View {
    @EnvironmentObject private var app: AloAppModel
    let channel: AloChannelProfile
    @State private var managementPresented = false
    @State private var adminLogPresented = false
    @State private var statsPresented = false

    /// The channel drawn as the website's profile page: the same hero as a person (cover, ringed avatar, name, «@handle ·
    /// сообщество», the description and the counts), «Подписаться» and «Чат» under it, then «Записи».
    private var heroUser: AloCurrentUser {
        AloCurrentUser(["id": channel.id, "name": channel.name, "username": channel.username, "bio": channel.description,
                        "avatarUrl": channel.avatarUrl, "verified": channel.verified, "coverImageUrl": channel.coverImageUrl])
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AloTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ProfileHeroCard(
                            user: heroUser,
                            coverStyleOverride: nil,
                            showsOwnerControls: false,
                            primaryTitle: channel.isOwner ? nil : (channel.subscribed ? "Вы подписаны" : "Подписаться"),
                            primarySystemImage: channel.subscribed ? "checkmark" : "plus",
                            primaryAccent: !channel.subscribed,
                            onPrimary: channel.isOwner ? nil : { app.toggleChannelSubscription() },
                            // The channel's chat, also before subscribing: Telegram opens it read-only with «Подписаться».
                            secondarySystemImage: channel.messengerRoomId == nil ? nil : "message.fill",
                            onSecondary: channel.messengerRoomId == nil ? nil : { app.openChannelChat(channel) },
                            onEditProfile: nil,
                            onEditBanner: nil,
                            details: AloProfileHeroDetails(
                                bio: channel.description,
                                counts: [
                                    (channel.subscribersCount, aloRussianPlural(channel.subscribersCount, "подписчик", "подписчика", "подписчиков")),
                                    (channel.postsCount, aloRussianPlural(channel.postsCount, "запись", "записи", "записей"))
                                ]
                            ),
                            websiteLayout: true,
                            handleSuffix: " · сообщество",
                            secondaryTitle: "Чат",
                            avatarColorSeed: "channel-\(channel.id)"
                        )
                        .padding(.horizontal, AloTheme.pageInset)
                        .padding(.top, 4)
                        .padding(.bottom, AloTheme.spacingSmall)

                        if channel.canManage {
                            // Android's row of three tools, each on one line (iOS's bordered buttons broke «Управ-ление» in two).
                            HStack(spacing: 8) {
                                adminButton("Управление", systemImage: "slider.horizontal.3") { managementPresented = true }
                                adminButton("Статистика", systemImage: "chart.bar.xaxis") { statsPresented = true }
                                    .accessibilityIdentifier("alo.channel.stats-button")
                                adminButton("Журнал", systemImage: "clock.arrow.circlepath") {
                                    app.loadChannelAdminLog()
                                    adminLogPresented = true
                                }
                            }
                            .padding(.horizontal, AloTheme.pageInset)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                        }

                        Section {
                            if channel.posts.isEmpty {
                                ContentUnavailableView(
                                    "Публикаций пока нет",
                                    systemImage: "megaphone",
                                    description: Text("Новые записи сообщества появятся здесь.")
                                )
                                .foregroundStyle(AloTheme.muted)
                                .padding(.top, 36)
                            } else {
                                ForEach(channel.posts) { post in
                                    AloPostCard(post: post) {
                                        app.toggleLike(post)
                                    } onComment: {
                                        app.openComments(for: post)
                                    } onRepost: {
                                        app.toggleRepost(post)
                                    }
                                    .padding(.horizontal, AloTheme.pageInset)
                                }
                                AloLoadMoreRow(list: .viewedProfilePosts, loaded: channel.posts.count)
                            }
                        } header: {
                            AloProfilePostsTitle()
                                .padding(.horizontal, AloTheme.pageInset)
                        }
                    }
                    .padding(.bottom, 28)
                }
                .clipped()
            }
        }
        .sheet(isPresented: $managementPresented) {
            ChannelManagementSheet(channel: channel)
                .environmentObject(app)
        }
        .sheet(isPresented: $statsPresented) {
            AloChannelStatsScreen(channel: channel).environmentObject(app)
        }
        .sheet(isPresented: $adminLogPresented) {
            ChannelAdminLogSheet(events: app.channelAdminEvents) { action in
                app.loadChannelAdminLog(action: action)
            }
        }
    }

    /// The bar over the page, as someone else's profile has: back, the name, and the link in «⋯».
    private var topBar: some View {
        HStack(spacing: 8) {
            AloChatCircleButton(systemImage: "chevron.left", label: "Назад", action: app.closeProfile)
                .accessibilityIdentifier("alo.profile.back")
            Text(channel.name)
                .font(.headline)
                .foregroundStyle(AloTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            Menu {
                if let url = AloServerConfiguration.appLinkURL(path: "ch/\(channel.id)") {
                    ShareLink(item: url) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.url = url } label: { Label("Скопировать ссылку", systemImage: "link") }
                }
                if channel.canManage {
                    Button("Управление", systemImage: "slider.horizontal.3") { managementPresented = true }
                    Button("Статистика", systemImage: "chart.bar.xaxis") { statsPresented = true }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(AloTheme.text)
                    .frame(width: AloChatMetrics.control, height: AloChatMetrics.control)
                    .modifier(AloChatGlass())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Ещё")
            .accessibilityIdentifier("alo.profile.more")
        }
        .padding(.horizontal, AloTheme.pageInset)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func adminButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(AloTheme.accent)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(AloTheme.accent.opacity(0.15), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(AloControlPressStyle())
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
    /// «⋯» on someone else's banner: secret chat, link, report, block — as on the web profile.
    var moreMenu: (() -> AnyView)? = nil
    /// The bio, the counts and the registration date: under the avatar, across the whole card (beside the avatar there is
    /// only room for the name and the @handle, so a long bio there ran far down in a narrow column).
    var details: AloProfileHeroDetails? = nil
    /// Someone else's profile as the website draws it (the owner, 2026-10-28): nothing on the cover, the person's buttons
    /// under the bio and the counts, two of the same size (the friend/follow button and «Сообщение»); the menu lives in
    /// the bar above the card (ViewedProfileTopBar).
    var websiteLayout = false
    /// The green dot of someone who is online, at the avatar's lower right (the website's `.profile-online`).
    var showsOnline = false
    /// After the @handle: a channel reads «@alo_news · сообщество», as on the website.
    var handleSuffix = ""
    /// The second button's title: «Сообщение» for a person, «Чат» for a channel.
    var secondaryTitle = "Сообщение"
    /// The avatar's placeholder colour; a channel uses its own seed so it keeps the colour it has elsewhere.
    var avatarColorSeed: String? = nil
    @State private var isAvatarOptionsPresented = false
    @State private var isAvatarPickerPresented = false
    @Environment(\.aloAPIClient) private var premiumAPI
    @ObservedObject private var premiumDirectory = AloPremiumDirectory.shared

    /// Alo Премиум belongs to people: a channel's id is another sequence, so a channel card asks for nobody.
    private var premiumUserId: Int { handleSuffix.isEmpty ? user.id : 0 }
    private var premiumExtras: AloPremiumProfileExtras? { premiumUserId > 0 ? premiumDirectory.extras[premiumUserId] : nil }

    @ViewBuilder private var premiumMusicButton: some View {
        if let extras = premiumExtras, !extras.musicUrl.isEmpty, let url = premiumAPI?.absoluteURL(extras.musicUrl) {
            AloProfileMusicButton(url: url, title: extras.musicTitle.ifBlank("Музыка профиля"))
        }
    }

    var body: some View {
        let outerRadius = AloTheme.radiusLarge
        let bannerRadius: CGFloat = outerRadius
        let bannerHeight: CGFloat = websiteLayout ? 168 : 154
        let avatarSize: CGFloat = websiteLayout ? 112 : 116
        let avatarOverlap: CGFloat = avatarSize / 2
        let hasActions = primaryTitle != nil || secondarySystemImage != nil || moreMenu != nil

        VStack(alignment: .leading, spacing: 0) {
                AloProfileBannerSurface(style: coverStyleOverride ?? user.coverStyle,
                                        imageURL: user.coverImageUrl,
                                        cornerRadius: bannerRadius)
                    .frame(height: bannerHeight)
                    // Alo Премиум: the person's own GIF over the header picture.
                    .overlay {
                        if let gif = premiumExtras?.coverGifUrl, !gif.isEmpty, let url = premiumAPI?.absoluteURL(gif) {
                            AloAnimatedGIF(url: url, api: premiumAPI)
                                .clipShape(RoundedRectangle(cornerRadius: bannerRadius, style: .continuous))
                                .allowsHitTesting(false)
                        }
                    }

                .overlay(alignment: .topTrailing) {
                    if showsOwnerControls {
                        HStack(spacing: 8) {
                            premiumMusicButton
                            if let onEditProfile {
                                AloSocialSettingsButton(label: "Настройки профиля", identifier: "alo.profile.settings", action: onEditProfile)
                            }
                            if let onEditBanner {
                                Button(action: onEditBanner) {
                                    Image(systemName: "paintpalette")
                                        .font(.system(size: 19, weight: .regular))
                                        .foregroundStyle(AloTheme.text)
                                        .frame(width: AloSocialMetrics.glassButton, height: AloSocialMetrics.glassButton)
                                        .modifier(AloChatGlass(interactive: false, role: .chrome))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(AloControlPressStyle())
                                .accessibilityLabel("Оформление профиля")
                            }
                        }.padding(12)
                    } else if hasActions && !websiteLayout {
                        profileActionRow.padding(14)
                    } else {
                        premiumMusicButton.padding(12)
                    }
                }

            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        avatarView(size: avatarSize)
                        identity
                    }
                } else {
                    // The website's geometry, measured at the iPhone's width (#profile in Chromium, 402pt): the avatar
                    // with its ring starts 17pt in and 45pt above the cover's lower edge, the name 19pt to its right
                    // and 63pt below its top, the bio 15pt under the ring.
                    HStack(alignment: .top, spacing: websiteLayout ? 19 : 10) {
                        avatarView(size: avatarSize)
                        identity.padding(.top, websiteLayout ? 63 : avatarOverlap + 8)
                    }
                }
            }
            .padding(.leading, websiteLayout ? 17 : AloTheme.spacingLarge)
            .padding(.trailing, AloTheme.spacingLarge)
            // The row participates in layout instead of overflowing a fixed 250pt card.
            .padding(.top, websiteLayout ? -45 : -avatarOverlap + 2)
            .padding(.bottom, websiteLayout ? 15 : (details?.isEmpty == false ? 10 : AloTheme.spacingLarge))

            if let details, !details.isEmpty {
                // From the banner's left edge, as the posts below (the owner, 2026-10-28): not indented under it.
                heroDetails(details)
                    .padding(.horizontal, 2)
                    .padding(.bottom, websiteLayout && hasActions ? 0 : AloTheme.spacingLarge)
            }
            if websiteLayout && hasActions {
                // 16 above the buttons, 4 under them, as `.profile-actions`.
                websiteActionRow
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            }
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
                AloPremiumName(text: user.name, userId: premiumUserId,
                               font: websiteLayout ? .system(size: 26, weight: .heavy) : .system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                if user.verified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AloTheme.accent).accessibilityHidden(true)
                }
                AloPremiumMark(userId: premiumUserId, size: websiteLayout ? 22 : 20)
            }.foregroundStyle(AloTheme.text)
            Text(user.username.withAtPrefix + handleSuffix).font(websiteLayout ? .system(size: 17) : .subheadline.weight(.semibold))
                .foregroundStyle(AloTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heroDetails(_ details: AloProfileHeroDetails) -> some View {
        // The website: 12 between the bio (17pt, line height 1.32) and the counts.
        VStack(alignment: .leading, spacing: websiteLayout ? 12 : 8) {
            if !details.bio.isEmpty {
                Text(details.bio)
                    .font(websiteLayout ? .system(size: 17) : .body)
                    .lineSpacing(websiteLayout ? 2 : 0)
                    .foregroundStyle(AloTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !details.counts.isEmpty {
                HStack(spacing: websiteLayout ? 20 : 14) {
                    ForEach(Array(details.counts.enumerated()), id: \.offset) { _, count in
                        let size: CGFloat = websiteLayout ? 16 : 15
                        (Text(aloCompactCount(count.value)).font(.system(size: size, weight: .bold)).foregroundColor(AloTheme.text)
                            + Text(" \(count.label)").font(.system(size: size)).foregroundColor(AloTheme.muted))
                            .lineLimit(1)
                    }
                }
            }
            if !details.registered.isEmpty {
                Label("Регистрация: \(details.registered)", systemImage: "calendar")
                    .font(.footnote)
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The avatar holds the stories (green ring, tap to open); on your own profile the camera
    /// badge changes the photo.
    private func avatarView(size: CGFloat) -> some View {
        AloProfileStoryAvatar(
            user: AloEntitySummary(["id": user.id, "name": user.name, "username": user.username,
                                    "avatarEmoji": user.avatarUrl, "verified": user.verified]),
            isOwn: showsOwnerControls
        ) {
            AloAvatar(name: user.name, url: user.avatarUrl, size: size, colorSeed: avatarColorSeed ?? String(user.id))
                .aloPremiumFrame(userId: premiumUserId, size: size)
                // The website's 4pt ring of the page colour around someone else's avatar.
                .padding(websiteLayout ? 4 : 0)
                .background(websiteLayout ? AloTheme.background : Color.clear, in: Circle())
        }
        .overlay(alignment: .bottomTrailing) {
            if showsOnline && !showsOwnerControls {
                Circle()
                    .fill(AloTheme.success)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(AloTheme.background, lineWidth: 4))
                    .offset(x: -6, y: -6)
                    .accessibilityLabel("В сети")
            }
            if showsOwnerControls, avatarSelection != nil {
                Button {
                    isAvatarOptionsPresented = true
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(AloTheme.accent)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AloTheme.background, lineWidth: 3))
                        // A full touch target around the small badge.
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 9, y: 9)
                .accessibilityLabel("Изменить фото профиля")
                .accessibilityIdentifier("alo.profile.avatar.photo")
            }
        }
    }

    /// The website's `.profile-actions`: the friend/follow button (filled when it calls to act) and «Сообщение», each half
    /// of the row, 44pt tall, whatever their labels.
    private var websiteActionRow: some View {
        HStack(spacing: 10) {
            if let primaryTitle, let onPrimary {
                Button(action: onPrimary) {
                    HStack(spacing: 6) {
                        if let primarySystemImage {
                            Image(systemName: primarySystemImage).font(.system(size: 14, weight: .semibold))
                        }
                        Text(primaryTitle).font(.system(size: 16, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(primaryAccent ? Color.white : AloTheme.text)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(primaryAccent ? AloTheme.accent : AloTheme.surfaceRaised, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(AloControlPressStyle())
                .accessibilityIdentifier("alo.profile.relation")
            }
            if let secondarySystemImage, let onSecondary {
                Button(action: onSecondary) {
                    HStack(spacing: 6) {
                        Image(systemName: secondarySystemImage).font(.system(size: 14, weight: .semibold))
                        Text(secondaryTitle).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(AloTheme.text)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AloTheme.surfaceRaised, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(AloControlPressStyle())
                .accessibilityIdentifier("alo.profile.message")
            }
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

            if let moreMenu {
                Menu { moreMenu() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.24))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.30), lineWidth: 1))
                        .contentShape(Circle())
                }
                .accessibilityLabel("Ещё")
                .accessibilityIdentifier("alo.profile.more")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

}

/// The website's «Записи» over a profile's posts (`.section-title.posts-title`): 20pt bold, a hairline under it, opaque
/// so the posts scroll under it while it stays pinned.
struct AloProfilePostsTitle: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Записи")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AloTheme.text)
                .padding(.leading, 4)
                // With the card's 8 under the buttons: 26 to the buttons, 12 to the line, as `.section-title.posts-title`.
                .padding(.top, 14)
                .padding(.bottom, 12)
            Rectangle().fill(AloTheme.separator).frame(height: 1 / UIScreen.main.scale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.background)
    }
}

/// What a profile shows under its avatar (ProfileHeroCard), in the website's and Android's order: bio, counts, registration.
struct AloProfileHeroDetails {
    var bio: String = ""
    var counts: [(value: Int, label: String)] = []
    var registered: String = ""
    var isEmpty: Bool { bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && counts.isEmpty && registered.isEmpty }

    /// «86 подписок», «1 204 подписчика»: the counts of a person, as the website writes them.
    static func personCounts(_ stats: AloProfileStats) -> [(value: Int, label: String)] {
        [(stats.following, aloRussianPlural(stats.following, "подписка", "подписки", "подписок")),
         (stats.followers, aloRussianPlural(stats.followers, "подписчик", "подписчика", "подписчиков"))]
    }
}

/// The Russian plural for a count: 1 подписчик, 2 подписчика, 5 подписчиков (11–14 take the last form). From a thousand on
/// the count is shown rounded («2.4K»), which reads with the last form: «2.4K подписчиков».
func aloRussianPlural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    if abs(count) >= 1_000 { return many }
    let n = abs(count) % 100
    if (11...14).contains(n) { return many }
    switch n % 10 {
    case 1: return one
    case 2, 3, 4: return few
    default: return many
    }
}

/// The ten banner colours the server accepts (PROFILE_COVER_STYLES), as gradients.
func aloProfileGradient(_ style: String) -> LinearGradient {
    func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
    let colors: [Color]
    switch style {
    case "sunset": colors = [rgb(0.60, 0.20, 0.07), rgb(0.92, 0.35, 0.03), rgb(0.98, 0.72, 0.18)]
    case "violet": colors = [rgb(0.36, 0.13, 0.71), rgb(0.49, 0.23, 0.92), rgb(0.73, 0.67, 0.98)]
    case "azure": colors = [rgb(0.02, 0.34, 0.52), rgb(0.02, 0.52, 0.78), rgb(0.49, 0.83, 0.98)]
    case "ocean": colors = [rgb(0.03, 0.16, 0.40), rgb(0.05, 0.36, 0.62), rgb(0.16, 0.72, 0.78)]
    case "rose": colors = [rgb(0.62, 0.09, 0.30), rgb(0.86, 0.15, 0.47), rgb(0.98, 0.66, 0.82)]
    case "emerald": colors = [rgb(0.06, 0.46, 0.43), rgb(0.09, 0.64, 0.29), rgb(0.37, 0.92, 0.68)]
    case "amber": colors = [rgb(0.55, 0.32, 0.02), rgb(0.88, 0.58, 0.05), rgb(1.00, 0.84, 0.36)]
    case "forest": colors = [rgb(0.07, 0.22, 0.12), rgb(0.16, 0.40, 0.20), rgb(0.53, 0.70, 0.35)]
    case "graphite": colors = [rgb(0.10, 0.11, 0.13), rgb(0.24, 0.26, 0.30), rgb(0.50, 0.53, 0.58)]
    default: colors = [rgb(0.00, 0.33, 0.86), rgb(0.04, 0.52, 1.00), rgb(0.42, 0.27, 0.93)]
    }
    return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Hide only the iOS 26 button capsule, not the native bar's scroll-edge blur.
private extension ToolbarContent {
    @ToolbarContentBuilder
    func profileSettingsTextBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

enum ProfileSettingsPage: String, CaseIterable, Identifiable {
    case root
    case privacy
    case notifications
    case theme
    case business
    case security
    case passwordChange
    case moderation
    case creatorStats
    case dataStorage
    case profileInfo
    case contentTools
    case premium
    case premiumLook

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
        case .moderation: return "Модерация"
        case .creatorStats: return "Панель автора"
        case .dataStorage: return "Данные и память"
        case .profileInfo: return "Профиль"
        case .contentTools: return "Перевод и расшифровка"
        case .premium: return "Alo Премиум"
        case .premiumLook: return "Премиум-оформление"
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
        case .moderation: return "Жалобы, обжалования, журнал и реклама"
        case .creatorStats: return "Просмотры, реакции и подписчики"
        case .dataStorage: return "Кеш и автозагрузка медиа"
        case .profileInfo: return "Имя, имя пользователя и о себе"
        case .contentTools: return "Согласие и сохранённые тексты"
        case .premium: return "Значок, цвет имени, статус и другое"
        case .premiumLook: return "Статус, цвет имени, рамка, GIF и музыка"
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
    /// Alo Премиум rows appear only when the server switches it on (`premiumEnabled`).
    @ObservedObject private var premiumDirectory = AloPremiumDirectory.shared
    @State private var isPasswordChangeOpen = false
    @State private var isFavoriteReactionSheetOpen = false
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
    @State private var infoName = ""
    @State private var infoUsername = ""
    @State private var infoBio = ""
    @State private var infoLoaded = false
    @State private var infoSaving = false
    @State private var infoNotice = ""
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
                if page == .moderation {
                    AloModerationPanel()
                } else if page == .creatorStats {
                    AloCreatorStatsScreen().environmentObject(app)
                } else {
                    settingsScreen(page)
                        .navigationDestination(isPresented: $isPasswordChangeOpen) { settingsScreen(.passwordChange) }
                }
            }
    }

    /// One settings page as a full screen. Sheets and dialogs hang off the page that shows them,
    /// because a page covered by a pushed one can no longer present anything.
    private func settingsScreen(_ page: ProfileSettingsPage) -> some View {
        ScrollView(showsIndicators: false) {
            pageContent(page)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 44)
        }
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
        // Reuse moderation's system navigation and scroll-edge effect. No
        // global bar appearance is changed, so moderation stays untouched.
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.visible, for: .navigationBar)
        .toolbar { settingsToolbar(for: page) }
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

    @ToolbarContentBuilder
    private func settingsToolbar(for page: ProfileSettingsPage) -> some ToolbarContent {
        let hasChanges = hasChanges(page)
        ToolbarItem(placement: .principal) {
            Text(page.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AloTheme.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
        ToolbarItem(placement: .topBarLeading) {
            // The glass back circle every full screen has (Android's AloScreenBackButton, the web's .back-btn).
            AloChatCircleButton(systemImage: "chevron.left", label: "Назад") {
                switch page {
                case .root: dismiss()
                case .passwordChange: isPasswordChangeOpen = false
                default: openedPage = nil
                }
            }
            .accessibilityIdentifier("alo.settings.back")
        }
        .profileSettingsTextBackground()

        if page == .privacy || page == .notifications {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Сохранить") { save(page) }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hasChanges ? AloTheme.accent : AloTheme.muted.opacity(0.55))
                    .frame(width: 82, height: AloSocialMetrics.controlHeight, alignment: .trailing)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .disabled(!hasChanges)
                    .accessibilityHint(hasChanges ? "Сохранить изменения на сервере" : "Нет изменений для сохранения")
            }
            .profileSettingsTextBackground()
        }
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
        case .dataStorage:
            AloDataStorageSettings()
        case .profileInfo:
            profileInfoPage
        case .contentTools:
            AloContentToolsSettingsView(store: app.contentTools)
        case .premium:
            AloPremiumSettingsView(onOpenLook: { openedPage = .premiumLook })
        case .premiumLook:
            AloPremiumLookView(onOpenPremium: { openedPage = .premium })
        case .moderation, .creatorStats:
            EmptyView()
        }
    }

    /// The reaction a double tap on a message sends, in every app of the account.
    private var favoriteReactionRow: some View {
        Button {
            isFavoriteReactionSheetOpen = true
        } label: {
            settingsCellLabel(
                title: "Любимая реакция",
                subtitle: "Ставится двойным нажатием на сообщение",
                systemName: "face.smiling",
                tint: Color(red: 1, green: 0.584, blue: 0),
                value: app.bootstrap?.me.favoriteReaction ?? "❤️"
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("alo.settings.favorite-reaction")
        .sheet(isPresented: $isFavoriteReactionSheetOpen) {
            favoriteReactionSheet
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
        }
    }

    private var favoriteReactionSheet: some View {
        let current = app.bootstrap?.me.favoriteReaction ?? "❤️"
        return VStack(alignment: .leading, spacing: 6) {
            Text("Любимая реакция")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(AloTheme.text)
            Text("Её ставит двойное нажатие на сообщение в iPhone, Android и на сайте.")
                .font(.system(size: 14))
                .foregroundStyle(AloTheme.muted)
                .padding(.bottom, 10)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 8) {
                ForEach(aloMessageReactionEmojis, id: \.self) { emoji in
                    Button {
                        app.setFavoriteReaction(emoji)
                        isFavoriteReactionSheetOpen = false
                    } label: {
                        Text(emoji)
                            .font(.system(size: 26))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(emoji == current ? AloTheme.accent.opacity(0.28) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(emoji)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .background(AloTheme.background.ignoresSafeArea())
    }

    /// Telegram's Settings: the other accounts of this phone first, with their unread count, then «Добавить аккаунт».
    private var accountsCard: some View {
        settingsCard(title: nil) {
            let others = app.otherStoredAccounts
            ForEach(Array(others.enumerated()), id: \.element.id) { index, account in
                Button {
                    app.switchToStoredAccount(account)
                } label: {
                    HStack(spacing: 10) {
                        AloAccountAvatar(account: account, size: 30)
                        Text(account.name.isEmpty ? "@\(account.username)" : account.name)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(AloTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        let unread = app.accountUnread[account.userId] ?? 0
                        if unread > 0 {
                            Text(unread > 99 ? "99+" : "\(unread)")
                                .font(.system(size: 13, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .frame(minWidth: 22, minHeight: 22)
                                .background(AloTheme.accent, in: Capsule())
                                .accessibilityLabel("Непрочитанных: \(unread)")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
                .disabled(app.isBusy)
                .accessibilityIdentifier("alo.settings.account.\(account.userId)")
                if index < others.count - 1 || app.canAddAccount { settingDivider }
            }
            if app.canAddAccount {
                Button {
                    app.addAnotherAccount()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AloTheme.accent)
                            .frame(width: 30, height: 44)
                        Text("Добавить аккаунт")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(AloTheme.accent)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
                .disabled(app.isBusy)
                .accessibilityIdentifier("alo.settings.add-account")
            }
        }
    }

    /// The website's .settings-me: a 64 avatar, the 20 name over the grey @username, a chevron to the profile editor.
    private var profileCard: some View {
        let me = app.bootstrap?.me
        return Button {
            openedPage = .profileInfo
        } label: {
            HStack(spacing: 16) {
                AloAvatar(name: me?.name ?? "", url: me?.avatarUrl ?? "", size: 64, colorSeed: String(me?.id ?? 0))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text((me?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "Профиль")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(AloTheme.text)
                            .lineLimit(1)
                        if me?.verified == true {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color(red: 0.24, green: 0.63, blue: 1))
                        }
                    }
                    if let username = me?.username, !username.isEmpty {
                        Text("@\(username)")
                            .font(.system(size: 15))
                            .foregroundStyle(AloTheme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                settingsChevron
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
        .accessibilityIdentifier("alo.settings.profile-info")
    }

    /// A page of the website (terms, privacy, contacts), opened in the browser.
    private func siteLinkRow(_ title: String, subtitle: String = "", systemName: String, path: String) -> some View {
        Button {
            if let base = AloServerConfiguration.baseURLs.first, let url = URL(string: path, relativeTo: base) {
                UIApplication.shared.open(url.absoluteURL)
            }
        } label: {
            settingsCellLabel(title: title, subtitle: subtitle, systemName: systemName, tint: Color(red: 0.557, green: 0.557, blue: 0.576))
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
    }

    /// The website's settings (web/js/views/settings.js rootPage): the profile card, the accounts, then groups with
    /// a colour tile, a title and a grey subtitle on every row, «Выйти из аккаунта» and the version.
    private var rootPage: some View {
        VStack(spacing: 0) {
            profileCard
                .padding(.bottom, 16)
            if !app.otherStoredAccounts.isEmpty || app.canAddAccount {
                accountsCard
            }
            if premiumDirectory.enabled {
                settingsCard(title: nil) {
                    settingsNavRow(title: "Alo Премиум", subtitle: "Значок, цвет имени, статус и другое", systemName: "sparkles", target: .premium)
                        .accessibilityIdentifier("alo.settings.premium")
                    tileDivider
                    settingsNavRow(title: "Премиум-оформление", subtitle: "Статус, цвет имени, рамка, GIF и музыка", systemName: "paintbrush.pointed", target: .premiumLook)
                        .accessibilityIdentifier("alo.settings.premium-look")
                }
                .padding(.top, 16)
            }
            settingsCard(title: "Аккаунт") {
                settingsNavRow(title: "Безопасность", subtitle: "Пароль, устройства и защита аккаунта", systemName: "shield.fill", target: .security)
                tileDivider
                settingsNavRow(title: "Приватность", subtitle: "Кто может писать, звонить и видеть активность", systemName: "hand.raised.fill", target: .privacy)
                tileDivider
                settingsNavRow(title: "Уведомления", subtitle: "Какие события приходят в Alo", systemName: "bell.fill", target: .notifications)
                tileDivider
                settingsNavRow(title: "Данные и память", subtitle: "Кэш и автозагрузка медиа", systemName: "internaldrive.fill", target: .dataStorage)
                    .accessibilityIdentifier("alo.settings.storage")
            }
            .padding(.top, 24)
            settingsCard(title: "Чаты") {
                settingsNavRow(title: "Оформление", subtitle: "Тема, цвета и фон чатов", systemName: "paintpalette.fill", target: .theme)
                    .accessibilityIdentifier("alo.settings.theme")
                tileDivider
                favoriteReactionRow
                tileDivider
                settingsNavRow(title: "Перевод и расшифровка", subtitle: "Перевод сообщений и текст голосовых", systemName: "translate", target: .contentTools)
                    .accessibilityIdentifier("alo.settings.content-tools")
            }
            .padding(.top, 24)
            settingsCard(title: "Для автора и бизнеса") {
                settingsNavRow(title: "Бизнес-профиль", subtitle: "Часы работы, приветствие и быстрые ответы", systemName: "briefcase.fill", target: .business)
                tileDivider
                // «Панель автора» lives here rather than on the profile, as on Android.
                settingsNavRow(title: "Панель автора", subtitle: "Просмотры, реакции и подписчики", systemName: "chart.bar.fill", target: .creatorStats)
                    .accessibilityIdentifier("alo.settings.creator-stats")
                // Admins and moderators only.
                if !(app.bootstrap?.me.adminCan.isEmpty ?? true) {
                    tileDivider
                    settingsNavRow(title: "Модерация", subtitle: "Жалобы, апелляции, команда", systemName: "checkmark.shield.fill", target: .moderation)
                        .accessibilityIdentifier("alo.settings.moderation")
                }
            }
            .padding(.top, 24)
            settingsCard(title: "Alo") {
                siteLinkRow("Условия", systemName: "doc.text.fill", path: "/legal/terms.html")
                tileDivider
                siteLinkRow("Конфиденциальность", systemName: "lock.fill", path: "/legal/privacy.html")
                tileDivider
                siteLinkRow("Контакты и поддержка", systemName: "envelope.fill", path: "/legal/contacts.html")
                tileDivider
                siteLinkRow("Исходный код и лицензии", subtitle: "Код приложений на GitHub, libsignal и код сайта", systemName: "chevron.left.forwardslash.chevron.right", path: "/legal/open-source.html")
            }
            .padding(.top, 24)
            settingsCard(title: nil) {
                Button(role: .destructive) {
                    onLogout()
                } label: {
                    Text("Выйти из аккаунта")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(red: 1, green: 0.302, blue: 0.373))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("alo.settings.logout")
            }
            .padding(.top, 24)

            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
            Text("Alo для iPhone · версия \(version) (\(build))")
                .font(.system(size: 13))
                .foregroundStyle(AloTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
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
                title: "Личные сообщения",
                subtitle: "Кто может писать вам личные сообщения",
                selected: $messageScope,
                options: [
                    ("all", "Все"),
                    ("friends", "Только друзья"),
                    ("friends_of_friends", "Друзья и друзья друзей")
                ]
            )

            privacySelectionCard(
                title: "Профиль",
                subtitle: "Кто может видеть публикации вашего профиля",
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
            }

            privacySelectionCard(
                title: "Звонки",
                subtitle: "Кто может вам звонить",
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
                    subtitle: "Уведомления о новых подписчиках",
                    systemName: "person.badge.plus",
                    isOn: $notificationSettingsDraft.followsEnabled
                )
                settingDivider
                settingToggle(
                    title: "Заявки в друзья",
                    subtitle: "Уведомления о новых заявках в друзья",
                    systemName: "person.2.fill",
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

    /// Name, @username and about text of the signed-in person (the same page as «Редактировать профиль» on Android and the web).
    private var profileInfoPage: some View {
        let usernameOK = infoUsername.count >= 3
        let nameOK = infoName.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
        let changed = infoName.trimmingCharacters(in: .whitespacesAndNewlines) != (user?.name ?? "")
            || infoUsername != (user?.username ?? "")
            || infoBio.trimmingCharacters(in: .whitespacesAndNewlines) != (user?.bio ?? "")
        return VStack(spacing: 22) {
            settingsCard(title: "Имя") {
                TextField("Имя", text: $infoName)
                    .textContentType(.name)
                    .font(.system(size: 16))
                    .foregroundStyle(AloTheme.text)
                    .frame(minHeight: 50)
                    .onChange(of: infoName) { _, value in if value.count > 30 { infoName = String(value.prefix(30)) } }
            }
            settingsCard(title: "Имя пользователя") {
                HStack(spacing: 2) {
                    Text("@").foregroundStyle(AloTheme.muted)
                    TextField("username", text: $infoUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: infoUsername) { _, value in
                            let cleaned = String((value.hasPrefix("@") ? String(value.dropFirst()) : value).lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }.prefix(32))
                            if cleaned != value { infoUsername = cleaned }
                        }
                }
                .font(.system(size: 16))
                .foregroundStyle(AloTheme.text)
                .frame(minHeight: 50)
            }
            Text("От 3 символов: латинские буквы, цифры и «_». По нему вас находят и упоминают.")
                .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            settingsCard(title: "О себе") {
                TextField("Расскажите о себе", text: $infoBio, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.system(size: 16))
                    .foregroundStyle(AloTheme.text)
                    .padding(.vertical, 12)
                    .onChange(of: infoBio) { _, value in if value.count > 70 { infoBio = String(value.prefix(70)) } }
            }
            Text("\(infoBio.count) из 70").font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await saveProfileInfo() }
            } label: {
                Text(infoSaving ? "Сохраняем…" : "Сохранить")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(changed && usernameOK && nameOK ? AloTheme.accent : AloTheme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))
            .disabled(!(changed && usernameOK && nameOK) || infoSaving)
            .accessibilityIdentifier("alo.settings.profile-info.save")
            if !infoNotice.isEmpty {
                infoRow(title: "Профиль", value: infoNotice)
            }
            AloOwnVerificationCard(verified: user?.verified ?? false)
        }
        .onAppear {
            guard !infoLoaded else { return }
            infoLoaded = true
            infoName = user?.name ?? ""
            infoUsername = user?.username ?? ""
            infoBio = user?.bio ?? ""
        }
    }

    @MainActor
    private func saveProfileInfo() async {
        infoSaving = true
        infoNotice = ""
        defer { infoSaving = false }
        if let problem = await app.updateProfileInfo(name: infoName, username: infoUsername, bio: infoBio) {
            infoNotice = problem
        } else {
            infoNotice = "Профиль сохранён."
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
        // The website's tile colours (web/js/views/settings.js).
        let tint: Color
        switch target {
        case .privacy: tint = Color(red: 0.204, green: 0.78, blue: 0.349)
        case .notifications: tint = Color(red: 1.0, green: 0.231, blue: 0.188)
        case .theme: tint = Color(red: 0.686, green: 0.322, blue: 0.871)
        case .business: tint = Color(red: 0.122, green: 0.71, blue: 0.459)
        case .security: tint = Color(red: 1.0, green: 0.624, blue: 0.039)
        case .passwordChange: tint = AloTheme.accent
        case .moderation: tint = Color(red: 1.0, green: 0.302, blue: 0.373)
        case .creatorStats: tint = AloTheme.accent
        case .dataStorage: tint = AloTheme.accent
        case .profileInfo: tint = AloTheme.accent
        case .contentTools: tint = Color(red: 0.357, green: 0.553, blue: 0.937)
        case .premium, .premiumLook: tint = Color(red: 1, green: 0.435, blue: 0.71)
        case .root: tint = AloTheme.accent
        }
        let gradient = target == .premium
            ? LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.3), Color(red: 1, green: 0.435, blue: 0.71), Color(red: 0.56, green: 0.48, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            : nil
        return Button {
            openedPage = target
        } label: {
            settingsCellLabel(
                title: title,
                subtitle: subtitle,
                systemName: showsIconTile ? systemName : nil,
                tint: tint,
                gradient: gradient,
                showsChevron: showsChevron
            )
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
            settingsCellLabel(title: title, subtitle: subtitle, systemName: systemName, tint: tint)
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

    /// The website's privacy choice: the group title, every option as a row with a check on the chosen one, a note.
    private func privacySelectionCard(
        title: String,
        subtitle: String,
        selected: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        settingsCard(title: title, note: subtitle) {
            ForEach(Array(options.enumerated()), id: \.element.0) { index, option in
                Button {
                    selected.wrappedValue = option.0
                } label: {
                    HStack {
                        Text(option.1)
                            .font(.system(size: 17))
                            .foregroundStyle(AloTheme.text)
                        Spacer(minLength: 8)
                        if selected.wrappedValue == option.0 {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AloTheme.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.wrappedValue == option.0 ? .isSelected : [])
                if index < options.count - 1 { settingDivider }
            }
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
            settingsCellLabel(title: "Чёрный список", subtitle: "", systemName: nil, tint: AloTheme.accent)
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
        case "login_failed": return "Неверный пароль при входе"
        case "login_attack_alert": return "Попытка подобрать пароль"
        case "password_reset": return "Пароль восстановлен по почте"
        case "login_requires_verification": return "Запрошен код входа"
        case "session_invalidated": return "Сеанс завершён: сменилось устройство"
        default: return "Событие безопасности"
        }
    }

    private func securityEventIcon(_ event: AloSecurityEvent) -> String {
        switch event.eventType {
        case "login_verified": return "arrow.right.circle.fill"
        case "password_changed", "password_reset": return "key.fill"
        case "login_failed", "login_attack_alert", "session_invalidated": return "exclamationmark.shield.fill"
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

    /// The website's settings group (web/css/base.css .group): an uppercase 13 grey title, a card of 22 corners with
    /// 16 insets, and an optional grey note under it.
    private func settingsCard<Content: View>(title: String?, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                Text(title.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.26)
                    .foregroundStyle(AloTheme.muted)
                    .padding(.leading, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AloTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            if let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(AloTheme.muted)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The website's .cell-icon: a 30 tile of 8 corners in the row's colour with a white symbol.
    private func settingsIconTile(_ systemName: String, tint: Color, gradient: LinearGradient? = nil) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 30, height: 30)
            .background {
                if let gradient {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(gradient)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint)
                }
            }
    }

    /// The website's faint chevron (--text-3).
    private var settingsChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AloTheme.muted.opacity(0.7))
    }

    /// A hairline under a row with a tile starts where the website's does: 54 from the card edge.
    private var tileDivider: some View { settingDivider(inset: 38) }

    /// The website's .cell: a tile, a 17 title over a 14 grey subtitle, an optional value and a chevron.
    private func settingsCellLabel(
        title: String,
        subtitle: String,
        systemName: String?,
        tint: Color,
        gradient: LinearGradient? = nil,
        detail: String? = nil,
        value: String? = nil,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 14) {
            if let systemName { settingsIconTile(systemName, tint: tint, gradient: gradient) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(AloTheme.text)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(AloTheme.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.system(size: 16)).foregroundStyle(AloTheme.muted)
            }
            if let value {
                Text(value).font(.system(size: 22))
            }
            if showsChevron { settingsChevron }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func settingToggle(
        title: String,
        subtitle: String,
        systemName: String? = nil,
        tint: Color = AloTheme.accent,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn.animation(.spring(response: 0.24, dampingFraction: 0.9))) {
            HStack(spacing: 14) {
                if let systemName { settingsIconTile(systemName, tint: tint) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .regular))
                    Text(subtitle)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(AloTheme.muted)
                        .lineLimit(3)
                }
            }
        }
        .tint(AloTheme.success)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
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
        app.blockedUsers.first(where: { $0.id == id })
            ?? app.bootstrap?.searchUsers.first(where: { $0.id == id })
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
