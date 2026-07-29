import SwiftUI
import PhotosUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var selectedSection: ProfileSection = .posts
    @State private var isPalettePresented = false
    @State private var isEditPresented = false
    @State private var selectedAvatarItem: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
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

                    ProfileContentSwitcher(selected: $selectedSection)

                    ForEach(selectedSection == .posts ? data.profilePosts : []) { post in
                        AloPostCard(post: post) {
                            app.toggleLike(post)
                        } onComment: {
                            app.openComments(for: post)
                        } onAuthor: {
                            app.openProfile(post.author)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 100)
        }
        .refreshable { await app.loadBootstrap() }
        .sheet(isPresented: $isPalettePresented) {
            ProfilePaletteSheet(
                name: app.bootstrap?.me.name ?? "Alo",
                selectedStyle: app.bootstrap?.me.coverStyle ?? "violet"
            ) { style in
                app.updateProfileCover(style: style)
            }
        }
        .fullScreenCover(isPresented: $isEditPresented) {
            ProfileEditSheet(
                user: app.bootstrap?.me,
                notificationSettings: app.bootstrap?.notificationSettings ?? .default,
                privacySettings: app.bootstrap?.privacySettings ?? .default,
                onApplyNotifications: { settings in app.updateNotificationSettings(settings) },
                onApplyPrivacy: { settings in app.updatePrivacy(settings: settings) },
                onLogout: { app.logout() }
            )
        }
        .onChange(of: selectedAvatarItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        app.updateProfileAvatar(data: data)
                        selectedAvatarItem = nil
                    }
                }
            }
        }
    }
}

struct ProfileDetailView: View {
    @EnvironmentObject private var app: AloAppModel
    let profile: AloUserProfile
    @State private var selectedSection: ProfileSection = .posts

    var body: some View {
        ZStack(alignment: .topLeading) {
            AloTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 10) {
                    ProfileHeroCard(
                        user: profile.user,
                        coverStyleOverride: nil,
                        showsOwnerControls: false,
                        primaryTitle: relationTitle,
                        primarySystemImage: relationIcon,
                        primaryAccent: relationTitle == "Добавить" || relationTitle == "Подписаться" || relationTitle == "Принять",
                        onPrimary: handleRelationTap,
                        secondarySystemImage: profile.permissions.canMessage ? "message.fill" : nil,
                        onSecondary: profile.permissions.canMessage ? { app.openConversation(with: profile) } : nil,
                        onEditProfile: nil,
                        onEditBanner: nil
                    )
                    .padding(.top, 8)

                    if profile.permissions.isPrivate {
                        privateNotice
                    } else {
                        ProfileContentSwitcher(selected: $selectedSection)

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
                                } onAuthor: {
                                    app.openProfile(post.author)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
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
    }

    private var privateNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Закрытый профиль", systemImage: "lock.fill")
                .font(.system(size: 18, weight: .bold))
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

private struct ProfileHeroCard: View {
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

    var body: some View {
        let outerRadius: CGFloat = 30
        let bannerRadius: CGFloat = outerRadius
        let bannerHeight: CGFloat = 178
        let avatarSize: CGFloat = 116
        let avatarOverlap: CGFloat = avatarSize / 2
        let hasActions = primaryTitle != nil || secondarySystemImage != nil

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .fill(AloTheme.surface)

            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: bannerRadius, style: .continuous)
                    .fill(aloProfileGradient(coverStyleOverride ?? user.coverStyle))
                    .frame(height: bannerHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: bannerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    }

                Color.clear.frame(height: 82)
            }

            HStack(alignment: .top, spacing: 10) {
                avatarView(size: avatarSize)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(user.name)
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                            .layoutPriority(1)
                        if user.verified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(AloTheme.accent)
                        }
                    }
                    .foregroundStyle(AloTheme.text)

                    Text(user.username.withAtPrefix)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(AloTheme.muted)
                }
                .padding(.top, avatarOverlap + 8)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.leading, 24)
            .padding(.trailing, 24)
            .padding(.top, bannerHeight - avatarOverlap)
            .padding(.bottom, 20)

            if showsOwnerControls {
                HStack(spacing: 8) {
                    if let onEditProfile {
                        Button(action: onEditProfile) {
                            Text("Редактировать")
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 16)
                                .frame(height: 40)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    if let onEditBanner {
                        Button(action: onEditBanner) {
                            Image(systemName: "paintpalette.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(width: 40, height: 40)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 14)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }

            if !showsOwnerControls && hasActions {
                profileActionRow
                    .padding(.top, 14)
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 284)
        .clipShape(RoundedRectangle(cornerRadius: outerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 12)
        .confirmationDialog(
            "Фотография профиля",
            isPresented: $isAvatarOptionsPresented,
            titleVisibility: .visible
        ) {
            if let avatarSelection {
                PhotosPicker(selection: avatarSelection, matching: .images) {
                    Text("Загрузить новое фото")
                }
            }
            Button("Отмена", role: .cancel) {}
        }
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
            Color(red: 1.00, green: 0.31, blue: 0.12),
            Color(red: 1.00, green: 0.52, blue: 0.20),
            Color(red: 1.00, green: 0.74, blue: 0.18)
        ]
    case "violet":
        colors = [
            Color(red: 0.88, green: 0.20, blue: 1.00),
            Color(red: 0.60, green: 0.44, blue: 1.00),
            Color(red: 0.16, green: 0.58, blue: 1.00)
        ]
    case "azure", "ocean":
        colors = [
            Color(red: 0.00, green: 0.31, blue: 1.00),
            Color(red: 0.16, green: 0.58, blue: 1.00),
            Color(red: 0.65, green: 0.93, blue: 1.00)
        ]
    case "rose":
        colors = [
            Color(red: 1.00, green: 0.12, blue: 0.44),
            Color(red: 1.00, green: 0.36, blue: 0.56),
            Color(red: 1.00, green: 0.54, blue: 0.66)
        ]
    case "emerald":
        colors = [
            Color(red: 0.00, green: 0.48, blue: 0.33),
            Color(red: 0.03, green: 0.83, blue: 0.59),
            Color(red: 0.53, green: 1.00, blue: 0.89)
        ]
    default:
        colors = [
            Color(red: 0.88, green: 0.20, blue: 1.00),
            Color(red: 0.60, green: 0.44, blue: 1.00),
            Color(red: 0.16, green: 0.58, blue: 1.00)
        ]
    }
    return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
}

private enum ProfileSettingsPage: String, CaseIterable, Identifiable {
    case root
    case privacy
    case notifications
    case theme
    case security

    var id: String { rawValue }

    var title: String {
        switch self {
        case .root: return "Настройки"
        case .privacy: return "Приватность"
        case .notifications: return "Уведомления"
        case .theme: return "Оформление"
        case .security: return "Безопасность"
        }
    }

    var subtitle: String {
        switch self {
        case .root: return "Тема, приватность и управление аккаунтом"
        case .privacy: return "Кто может писать, звонить и видеть активность"
        case .notifications: return "Какие события приходят в Alo"
        case .theme: return "Внешний вид и режим приложения"
        case .security: return "Пароль, устройства и защита аккаунта"
        }
    }
}

private struct ProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AloAppModel
    let user: AloCurrentUser?
    let notificationSettings: AloNotificationSettings
    let privacySettings: AloPrivacySettings
    let onApplyNotifications: (AloNotificationSettings) -> Void
    let onApplyPrivacy: (AloPrivacySettings) -> Void
    let onLogout: () -> Void
    @State private var page: ProfileSettingsPage = .root
    @State private var notificationSettingsDraft: AloNotificationSettings
    @State private var allowFriendRequests: Bool
    @State private var messageScope: String
    @State private var allowMessageForwards: Bool
    @State private var callScope: String
    @State private var profileVisibility: String
    @State private var hideActivity: Bool
    @State private var chatAppearanceDraft: AloChatAppearance
    @State private var isChatAppearancePresented = false
    @State private var cacheNotice = ""
    @State private var securitySessions = [AloSecuritySession]()
    @State private var securityLoading = false
    @State private var securityNotice = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    init(
        user: AloCurrentUser?,
        notificationSettings: AloNotificationSettings,
        privacySettings: AloPrivacySettings,
        onApplyNotifications: @escaping (AloNotificationSettings) -> Void,
        onApplyPrivacy: @escaping (AloPrivacySettings) -> Void,
        onLogout: @escaping () -> Void
    ) {
        self.user = user
        self.notificationSettings = notificationSettings
        self.privacySettings = privacySettings
        self.onApplyNotifications = onApplyNotifications
        self.onApplyPrivacy = onApplyPrivacy
        self.onLogout = onLogout
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
        VStack(spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                pageContent
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 100)
            }

            AloPrimaryButton(title: footerTitle) {
                if page == .root {
                    dismiss()
                } else {
                    if page == .privacy {
                        savePrivacy()
                    } else if page == .notifications {
                        onApplyNotifications(notificationSettingsDraft)
                    }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        page = .root
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
        .sheet(isPresented: $isChatAppearancePresented) {
            ChatAppearanceSheet(appearance: chatAppearanceDraft) { updated in
                chatAppearanceDraft = updated
                AloChatAppearanceStore.saveGlobal(updated)
            }
        }
        .task(id: page) {
            if page == .security {
                await loadSecuritySessions()
            }
        }
    }

    private var footerTitle: String {
        page == .privacy || page == .notifications ? "Сохранить" : "Готово"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                if page == .root {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        page = .root
                    }
                }
            } label: {
                Image(systemName: page == .root ? "xmark" : "chevron.left")
                    .font(.system(size: page == .root ? 18 : 27, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 44, height: 44)
                    .background(AloTheme.surface.opacity(0.78))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                Text(page.subtitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .root:
            rootPage
        case .privacy:
            privacyPage
        case .notifications:
            notificationsPage
        case .theme:
            themePage
        case .security:
            securityPage
        }
    }

    private var rootPage: some View {
        VStack(spacing: 12) {
            infoCard
            settingsNavRow(
                title: "Приватность",
                subtitle: "Заявки, сообщения, звонки и активность",
                systemName: "shield.fill",
                target: .privacy
            )
            settingsNavRow(
                title: "Уведомления",
                subtitle: "Лайки, комментарии, диалоги и подписки",
                systemName: "bell.badge.fill",
                target: .notifications
            )
            settingsNavRow(
                title: "Оформление",
                subtitle: "Тема приложения и визуальный режим",
                systemName: "moon.fill",
                target: .theme
            )
            settingsNavRow(
                title: "Безопасность",
                subtitle: "Пароль, устройства и защита аккаунта",
                systemName: "lock.fill",
                target: .security
            )

            if !cacheNotice.isEmpty {
                infoRow(title: "Кэш", value: cacheNotice)
            }

            settingsActionRow(
                title: "Очистить кэш",
                subtitle: "Удалить локальную историю быстрого запуска и загруженные медиа",
                systemName: "trash.slash",
                tint: AloTheme.accent
            ) {
                app.clearLocalCache()
                cacheNotice = "Локальные данные очищены. Переписка на сервере не удалена."
            }

            Button(role: .destructive) {
                onLogout()
                dismiss()
            } label: {
                Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(AloTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var privacyPage: some View {
        VStack(spacing: 12) {
            settingsCard(title: "Доступ") {
                settingToggle(
                    title: "Заявки в друзья",
                    subtitle: "Разрешать другим отправлять запросы",
                    isOn: $allowFriendRequests
                )
                settingDivider
                choiceBlock(
                    title: "Кто может писать",
                    options: [
                        ("friends", "Друзья"),
                        ("friends_of_friends", "Друзья и друзья друзей"),
                        ("all", "Все, включая незнакомых")
                    ],
                    selected: $messageScope
                )
                settingDivider
                choiceBlock(
                    title: "Кто видит профиль",
                    options: [
                        ("all", "Все"),
                        ("friends", "Только друзья")
                    ],
                    selected: $profileVisibility
                )
            }

            settingsCard(title: "Сообщения и звонки") {
                settingToggle(
                    title: "Пересылка сообщений",
                    subtitle: "Разрешать другим пересылать ваши сообщения",
                    isOn: $allowMessageForwards
                )
                settingDivider
                choiceBlock(
                    title: "Кто может звонить",
                    options: [
                        ("friends", "Друзья"),
                        ("friends_of_friends", "Друзья и друзья друзей"),
                        ("all", "Все, включая незнакомых"),
                        ("none", "Никто")
                    ],
                    selected: $callScope
                )
                settingDivider
                settingToggle(
                    title: "Скрывать активность",
                    subtitle: "Показывать общий статус вместо точного онлайна",
                    isOn: $hideActivity
                )
            }
        }
    }

    private var notificationsPage: some View {
        VStack(spacing: 12) {
            settingsCard(title: "Общение") {
                settingToggle(
                    title: "Сообщения",
                    subtitle: "Новые личные и групповые сообщения",
                    isOn: $notificationSettingsDraft.messagesEnabled
                )
                settingDivider
                settingToggle(
                    title: "Заявки в друзья",
                    subtitle: "Новые входящие заявки",
                    isOn: $notificationSettingsDraft.friendRequestsEnabled
                )
                settingDivider
                settingToggle(
                    title: "Принятые заявки",
                    subtitle: "Когда другой пользователь принимает вашу заявку",
                    isOn: $notificationSettingsDraft.friendAcceptsEnabled
                )
                settingDivider
                settingToggle(
                    title: "Подписки",
                    subtitle: "Новые подписчики и события каналов",
                    isOn: $notificationSettingsDraft.followsEnabled
                )
            }

            settingsCard(title: "Публикации") {
                settingToggle(
                    title: "Лайки",
                    subtitle: "Реакции на ваши публикации",
                    isOn: $notificationSettingsDraft.likesEnabled
                )
                settingDivider
                settingToggle(
                    title: "Комментарии",
                    subtitle: "Ответы и новые обсуждения",
                    isOn: $notificationSettingsDraft.commentsEnabled
                )
                settingDivider
                settingToggle(
                    title: "Лайки комментариев",
                    subtitle: "Реакции на ваши комментарии",
                    isOn: $notificationSettingsDraft.commentLikesEnabled
                )
                settingDivider
                settingToggle(
                    title: "Репосты",
                    subtitle: "Когда публикацией делятся дальше",
                    isOn: $notificationSettingsDraft.repostsEnabled
                )
                settingDivider
                settingToggle(
                    title: "Каналы",
                    subtitle: "События каналов, на которые вы подписаны",
                    isOn: $notificationSettingsDraft.channelSubscriptionsEnabled
                )
            }

            settingsActionRow(
                title: "Системные уведомления",
                subtitle: "Звук, баннеры и разрешение iOS",
                systemName: "gearshape.fill",
                tint: AloTheme.accent
            ) {
                guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        }
    }

    private var themePage: some View {
        VStack(spacing: 12) {
            settingsCard(title: "Интерфейс") {
                HStack(spacing: 12) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 40, height: 40)
                        .background(AloTheme.accent, in: Circle())
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

            settingsActionRow(
                title: "Оформление чатов",
                subtitle: "Обои, цвета сообщений и интервалы во всех диалогах",
                systemName: "paintpalette.fill",
                tint: chatAppearanceDraft.outgoingColor
            ) {
                isChatAppearancePresented = true
            }

            infoRow(
                title: "Текущий вариант",
                value: AloChatAppearance.presets.first(where: { $0.id == chatAppearanceDraft.preset })?.title ?? "Пользовательский"
            )
        }
    }

    private var securityPage: some View {
        VStack(spacing: 12) {
            settingsCard(title: "Смена пароля") {
                secureField("Текущий пароль", text: $currentPassword)
                settingDivider
                secureField("Новый пароль", text: $newPassword)
                settingDivider
                secureField("Повторите новый пароль", text: $confirmPassword)

                Button {
                    Task { await changePassword() }
                } label: {
                    Text("Изменить пароль")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(passwordChangeDisabled ? AloTheme.surfaceRaised : AloTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))
                .disabled(passwordChangeDisabled || securityLoading)
            }

            if !securityNotice.isEmpty {
                infoRow(title: "Безопасность", value: securityNotice)
            }

            settingsCard(title: "Активные сеансы") {
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

            if securitySessions.contains(where: { !$0.current }) {
                settingsActionRow(
                    title: "Завершить остальные сеансы",
                    subtitle: "Оставить активным только это устройство",
                    systemName: "rectangle.stack.badge.minus",
                    tint: .red
                ) {
                    Task { await revokeOtherSessions() }
                }
            }
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(user?.name ?? "Alo")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
            Text("Эти параметры синхронизируются с сервером и применяются на всех устройствах.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func settingsNavRow(title: String, subtitle: String, systemName: String, target: ProfileSettingsPage) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                page = target
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 38, height: 38)
                    .background(AloTheme.accent)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(AloTheme.text)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(AloTheme.muted)
            }
            .padding(14)
            .background(AloTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
    }

    private func settingsActionRow(
        title: String,
        subtitle: String,
        systemName: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 38, height: 38)
                    .background(tint, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(AloTheme.text)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(AloTheme.muted)
            }
            .padding(14)
            .background(AloTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .textContentType(.password)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AloTheme.text)
            .padding(.vertical, 8)
    }

    private func securitySessionRow(_ session: AloSecuritySession) -> some View {
        HStack(spacing: 11) {
            Image(systemName: securitySessionIcon(session.deviceType))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(session.isSuspicious ? Color.red : AloTheme.accent)
                .frame(width: 38, height: 38)
                .background(
                    (session.isSuspicious ? Color.red : AloTheme.accent).opacity(0.14),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.deviceLabel)
                        .font(.system(size: 14.5, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                    if session.current {
                        Text("это устройство")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(AloTheme.accent)
                    }
                }
                Text(securitySessionSubtitle(session))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(session.isSuspicious ? Color.red : AloTheme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)

            if !session.current {
                Button {
                    Task { await revokeSession(session) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Color.red)
                        .frame(width: 34, height: 34)
                        .background(Color.red.opacity(0.12), in: Circle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.88))
                .disabled(securityLoading)
            }
        }
        .padding(.vertical, 2)
    }

    private func infoRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(AloTheme.text)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func settingToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn.animation(.spring(response: 0.24, dampingFraction: 0.9))) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
            }
        }
        .tint(AloTheme.accent)
    }

    private var settingDivider: some View {
        Rectangle()
            .fill(AloTheme.border.opacity(0.7))
            .frame(height: 1)
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

    private func securitySessionIcon(_ deviceType: String) -> String {
        switch deviceType.lowercased() {
        case "phone": return "iphone"
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
        return parts.joined(separator: " · ").ifBlank(session.platform)
    }

    @MainActor
    private func loadSecuritySessions() async {
        securityLoading = true
        defer { securityLoading = false }
        do {
            securitySessions = try await app.api.loadSecuritySessions()
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
            securitySessions = try await app.api.loadSecuritySessions()
        } catch let error as AloAPIError {
            securityNotice = error.message
        } catch {
            securityNotice = "Не удалось изменить пароль."
        }
    }

    @MainActor
    private func revokeSession(_ session: AloSecuritySession) async {
        guard !session.current else { return }
        securityLoading = true
        defer { securityLoading = false }
        do {
            try await app.api.revokeSecuritySession(id: session.id)
            securitySessions.removeAll { $0.id == session.id }
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
            securitySessions.removeAll { !$0.current }
            securityNotice = revoked > 0
                ? "Завершено других сеансов: \(revoked)."
                : "Других активных сеансов нет."
        } catch let error as AloAPIError {
            securityNotice = error.message
        } catch {
            securityNotice = "Не удалось завершить другие сеансы."
        }
    }
}

private struct ProfileContentSwitcher: View {
    @Binding var selected: ProfileSection
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ProfileSection.allCases) { section in
                Button(section.title) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        selected = section
                    }
                }
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(selected == section ? AloTheme.text : AloTheme.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background {
                    if selected == section {
                        Capsule()
                            .fill(AloTheme.surfaceRaised)
                            .matchedGeometryEffect(id: "profile-switcher", in: namespace)
                    }
                }
            }
        }
        .padding(4)
        .background(AloTheme.surface)
        .clipShape(Capsule())
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
