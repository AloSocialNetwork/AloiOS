import Combine
import PhotosUI
import SwiftUI

/// Someone who can be invited into a new group or channel.
struct AloCommunityCandidate: Identifiable, Hashable {
    let id: Int
    let name: String
    let username: String
    let avatarUrl: String
}

/// Everything the creation steps fill in before the community is created in one request.
struct AloCommunityDraft {
    var kind = "group"
    var title = ""
    var description = ""
    var isPublic = true
    var username = ""
    var members: [AloCommunityCandidate] = []
    var avatarJPEG: Data?

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasTitle: Bool { trimmedTitle.count >= 2 }
    var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^@+", with: "", options: .regularExpression).lowercased()
    }
    var hasValidUsername: Bool { normalizedUsername.range(of: "^[a-z0-9_]{5,32}$", options: .regularExpression) != nil }
}

private enum AloCommunityStep: Hashable {
    case groupMembers, groupInfo, channelInfo, channelType, channelSubscribers
}

/// "Новое сообщение", Telegram's compose screen: a new group, a new channel (two separate flows,
/// never one form with a switch), joining by link, and the people to write to.
struct AloNewMessageSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AloCommunityStep] = []
    @State private var draft = AloCommunityDraft()
    @State private var query = ""
    @StateObject private var peopleSearch = AloPeopleSearch()
    @State private var isJoinPresented = false
    @State private var joinCode = ""
    @State private var isWorking = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: AloCommunityStep.self) { step in
                    screen(for: step)
                }
        }
        .tint(AloTheme.accent)
        .interactiveDismissDisabled(isWorking)
        .alert("Ошибка", isPresented: Binding(get: { !errorMessage.isEmpty }, set: { if !$0 { errorMessage = "" } })) {
            Button("Ок", role: .cancel) {}
        } message: { Text(errorMessage) }
    }

    // MARK: Root

    private var root: some View {
        VStack(spacing: 0) {
            AloCreationHeader(title: "Новое сообщение", leading: .close, onLeading: { dismiss() })
            AloSocialSearchField(text: $query, identifier: "alo.compose.search")
                .padding(.horizontal, AloSocialMetrics.inset)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 0) {
                    if query.isEmpty {
                        AloCreationCard {
                            AloCreationActionRow(title: "Новая группа", systemImage: "person.2.fill",
                                                 identifier: "alo.compose.group") { start("group") }
                            AloCreationDivider(leading: 58)
                            AloCreationActionRow(title: "Новый канал", systemImage: "megaphone.fill",
                                                 identifier: "alo.compose.channel") { start("channel") }
                            AloCreationDivider(leading: 58)
                            AloCreationActionRow(title: "Вступить по ссылке", systemImage: "link",
                                                 identifier: "alo.compose.join") { isJoinPresented = true }
                        }
                        .padding(.bottom, 18)
                    }
                    AloCreationSectionTitle(text: "Контакты")
                    let people = peopleSearch.merged(with: AloCommunityCandidates.filter(AloCommunityCandidates.all(app), query: query))
                    if people.isEmpty {
                        Text(query.isEmpty ? "Здесь появятся люди, с которыми вы переписываетесь." : "Никого не найдено.")
                            .font(.system(size: 15)).foregroundStyle(AloTheme.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        AloCreationCard {
                            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                                if index > 0 { AloCreationDivider(leading: 70) }
                                Button { openChat(with: person) } label: {
                                    AloCandidateRow(person: person, selection: nil)
                                }
                                .buttonStyle(AloChatRowPressStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, AloSocialMetrics.inset)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(AloTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: query) { await peopleSearch.update(query: query, app: app) }
        .alert("Вступить по ссылке", isPresented: $isJoinPresented) {
            TextField("Ссылка или код приглашения", text: $joinCode)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Вступить") { join() }
            Button("Отмена", role: .cancel) { joinCode = "" }
        } message: {
            Text("Вставьте ссылку-приглашение в группу или канал.")
        }
    }

    @ViewBuilder
    private func screen(for step: AloCommunityStep) -> some View {
        switch step {
        case .groupMembers:
            AloCandidatePickerScreen(title: "Новая группа", actionTitle: "Далее", members: $draft.members,
                                     isWorking: false) { path.append(.groupInfo) }
        case .groupInfo:
            AloCommunityInfoScreen(draft: $draft, isWorking: isWorking) { create() }
        case .channelInfo:
            AloCommunityInfoScreen(draft: $draft, isWorking: false) { path.append(.channelType) }
        case .channelType:
            AloChannelTypeScreen(draft: $draft) { path.append(.channelSubscribers) }
        case .channelSubscribers:
            AloCandidatePickerScreen(title: "Подписчики", actionTitle: "Создать", members: $draft.members,
                                     isWorking: isWorking,
                                     footnote: "Пригласите тех, кому канал будет интересен. Это можно сделать и позже.") { create() }
        }
    }

    // MARK: Actions

    private func start(_ kind: String) {
        draft = AloCommunityDraft(kind: kind)
        path = [kind == "channel" ? .channelInfo : .groupMembers]
    }

    private func create() {
        guard draft.hasTitle, !isWorking else { return }
        isWorking = true
        let draft = self.draft
        let isChannel = draft.kind == "channel"
        Task {
            do {
                let result = try await app.api.createGroupChat(
                    title: draft.trimmedTitle,
                    description: draft.description,
                    kind: draft.kind,
                    joinPolicy: isChannel && draft.isPublic ? "public" : "invite",
                    username: isChannel && draft.isPublic ? draft.normalizedUsername : "",
                    memberIds: draft.members.map(\.id))
                await app.loadBootstrap(peerId: result.peerId)
                if app.activeConversation?.peerId != result.peerId,
                   let conversation = app.bootstrap?.conversations.first(where: { $0.peerId == result.peerId }) {
                    app.openConversation(conversation)
                }
                if let avatar = draft.avatarJPEG, let conversation = app.activeConversation,
                   conversation.peerId == result.peerId {
                    app.updateGroupAvatar(conversation: conversation, data: avatar)
                }
                isWorking = false
                dismiss()
            } catch let error as AloAPIError {
                errorMessage = error.message
                isWorking = false
            } catch {
                errorMessage = isChannel ? "Не удалось создать канал." : "Не удалось создать группу."
                isWorking = false
            }
        }
    }

    private func join() {
        var code = joinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        joinCode = ""
        // A pasted link carries the code as its last path component.
        if code.contains("/"), let last = code.split(separator: "/").last { code = String(last) }
        guard !code.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            do {
                let result = try await app.api.joinGroupInvite(token: code)
                if result.pendingApproval {
                    app.notice = "Заявка на вступление отправлена."
                } else if result.peerId > 0 {
                    await app.loadBootstrap(peerId: result.peerId)
                    if app.activeConversation?.peerId != result.peerId,
                       let conversation = app.bootstrap?.conversations.first(where: { $0.peerId == result.peerId }) {
                        app.openConversation(conversation)
                    }
                }
                isWorking = false
                dismiss()
            } catch let error as AloAPIError {
                errorMessage = error.message
                isWorking = false
            } catch {
                errorMessage = "Не удалось открыть приглашение."
                isWorking = false
            }
        }
    }

    private func openChat(with person: AloCommunityCandidate) {
        if let conversation = app.bootstrap?.conversations.first(where: { $0.kind == "direct" && $0.peer.id == person.id }) {
            app.openConversation(conversation)
            dismiss()
            return
        }
        Task {
            guard let profile = try? await app.api.loadUserProfile(userId: person.id) else {
                errorMessage = "Не удалось открыть чат."
                return
            }
            app.openConversation(with: profile)
            dismiss()
        }
    }
}

/// Server people search for a query, debounced; local matches always come first.
@MainActor
final class AloPeopleSearch: ObservableObject {
    @Published private(set) var remote: [AloCommunityCandidate] = []

    func update(query: String, app: AloAppModel) async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.replacingOccurrences(of: "@", with: "").count >= 2 else {
            remote = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled,
              let users = try? await app.api.searchUsers(query: needle) else { return }
        guard !Task.isCancelled else { return }
        remote = users.filter { !$0.isChannel }.map {
            AloCommunityCandidate(id: $0.id, name: $0.name, username: $0.username, avatarUrl: $0.avatarUrl)
        }
    }

    func merged(with local: [AloCommunityCandidate]) -> [AloCommunityCandidate] {
        let known = Set(local.map(\.id))
        return local + remote.filter { !known.contains($0.id) }
    }
}

enum AloCommunityCandidates {
    /// People from direct chats first, then suggestions; never yourself, saved messages or communities.
    @MainActor
    static func all(_ app: AloAppModel) -> [AloCommunityCandidate] {
        guard let data = app.bootstrap else { return [] }
        var seen = Set<Int>([data.me.id])
        var result: [AloCommunityCandidate] = []
        for conversation in data.conversations where conversation.kind == "direct" && conversation.peer.entityType != "saved" {
            let peer = conversation.peer
            guard peer.id > 0, seen.insert(peer.id).inserted else { continue }
            result.append(AloCommunityCandidate(id: peer.id, name: peer.name, username: peer.username, avatarUrl: peer.avatarUrl))
        }
        for user in data.searchUsers where !user.isChannel {
            guard user.id > 0, seen.insert(user.id).inserted else { continue }
            result.append(AloCommunityCandidate(id: user.id, name: user.name, username: user.username, avatarUrl: user.avatarUrl))
        }
        return result
    }

    static func filter(_ people: [AloCommunityCandidate], query: String) -> [AloCommunityCandidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return people }
        return people.filter { $0.name.lowercased().contains(needle) || $0.username.lowercased().contains(needle) }
    }
}

// MARK: - Steps

/// Telegram's member picker: chosen people as chips above the search, a check beside each row.
private struct AloCandidatePickerScreen: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let title: String
    let actionTitle: String
    @Binding var members: [AloCommunityCandidate]
    let isWorking: Bool
    var footnote: String = ""
    let onNext: () -> Void
    @State private var query = ""
    @StateObject private var peopleSearch = AloPeopleSearch()

    var body: some View {
        VStack(spacing: 0) {
            AloCreationHeader(title: title, subtitle: members.isEmpty ? "" : "Выбрано: \(members.count)",
                              leading: .back, actionTitle: actionTitle, isWorking: isWorking,
                              onLeading: { dismiss() }, onAction: onNext)
            if !members.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(members) { person in
                            Button { toggle(person) } label: {
                                HStack(spacing: 6) {
                                    AloAvatar(name: person.name, url: person.avatarUrl, size: 24, colorSeed: String(person.id))
                                    Text(person.name.components(separatedBy: " ").first ?? person.name)
                                        .font(.system(size: 15)).foregroundStyle(AloTheme.text).lineLimit(1)
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(AloTheme.muted)
                                }
                                .padding(.leading, 3).padding(.trailing, 10)
                                .frame(height: 30)
                                .background(AloTheme.accent.opacity(0.2), in: Capsule())
                            }
                            .buttonStyle(AloControlPressStyle())
                            .accessibilityLabel("Убрать \(person.name)")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, AloSocialMetrics.inset)
                }
                .padding(.bottom, 8)
            }
            AloSocialSearchField(text: $query, identifier: "alo.compose.members.search")
                .padding(.horizontal, AloSocialMetrics.inset)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 0) {
                    let people = peopleSearch.merged(with: AloCommunityCandidates.filter(AloCommunityCandidates.all(app), query: query))
                    if people.isEmpty {
                        Text(query.isEmpty ? "Пока некого пригласить: начните переписку или найдите людей по имени." : "Никого не найдено.")
                            .font(.system(size: 15)).foregroundStyle(AloTheme.muted).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        AloCreationCard {
                            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                                if index > 0 { AloCreationDivider(leading: 70) }
                                Button { toggle(person) } label: {
                                    AloCandidateRow(person: person, selection: members.contains(person))
                                }
                                .buttonStyle(AloChatRowPressStyle())
                                .accessibilityAddTraits(members.contains(person) ? .isSelected : [])
                            }
                        }
                    }
                    if !footnote.isEmpty {
                        AloCreationFootnote(text: footnote)
                    }
                }
                .padding(.horizontal, AloSocialMetrics.inset)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(AloTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .background(AloNativeBackSwipe())
        .task(id: query) { await peopleSearch.update(query: query, app: app) }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: members)
    }

    private func toggle(_ person: AloCommunityCandidate) {
        if let index = members.firstIndex(of: person) {
            members.remove(at: index)
        } else {
            members.append(person)
        }
        AloHaptics.impact(.light)
    }
}

/// Photo and name (and, for a channel, a description), as on Telegram's second group / first
/// channel step.
private struct AloCommunityInfoScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: AloCommunityDraft
    let isWorking: Bool
    let onNext: () -> Void
    @State private var photoItem: PhotosPickerItem?
    @State private var cropRequest: AloAvatarCropRequest?
    @State private var preview: UIImage?
    @FocusState private var titleFocused: Bool

    private var isChannel: Bool { draft.kind == "channel" }

    var body: some View {
        VStack(spacing: 0) {
            AloCreationHeader(title: isChannel ? "Новый канал" : "Новая группа", leading: .back,
                              actionTitle: isChannel ? "Далее" : "Создать", actionEnabled: draft.hasTitle,
                              isWorking: isWorking, onLeading: { dismiss() }, onAction: onNext)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AloCreationCard {
                        HStack(spacing: 14) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                avatar
                            }
                            .buttonStyle(AloControlPressStyle())
                            .accessibilityLabel(preview == nil ? "Выбрать фото" : "Изменить фото")
                            .accessibilityIdentifier("alo.community.photo")
                            TextField(isChannel ? "Название канала" : "Название группы", text: $draft.title)
                                .font(.system(size: 17))
                                .foregroundStyle(AloTheme.text)
                                .focused($titleFocused)
                                .submitLabel(.next)
                                .accessibilityIdentifier("alo.community.title")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    if isChannel {
                        AloCreationCard {
                            TextField("Описание", text: $draft.description, axis: .vertical)
                                .font(.system(size: 17))
                                .foregroundStyle(AloTheme.text)
                                .lineLimit(3...6)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 13)
                                .accessibilityIdentifier("alo.community.description")
                        }
                        .padding(.top, 18)
                        AloCreationFootnote(text: "Описание увидят подписчики в профиле канала.")
                    } else {
                        AloCreationFootnote(text: "Укажите название группы и, если хотите, фото.")
                        if !draft.members.isEmpty {
                            AloCreationSectionTitle(text: AloCommunityPlural.members(draft.members.count))
                                .padding(.top, 14)
                            AloCreationCard {
                                ForEach(Array(draft.members.enumerated()), id: \.element.id) { index, person in
                                    if index > 0 { AloCreationDivider(leading: 70) }
                                    AloCandidateRow(person: person, selection: nil)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, AloSocialMetrics.inset)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(AloTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .background(AloNativeBackSwipe())
        .onAppear { if draft.title.isEmpty { titleFocused = true } }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                photoItem = nil
                guard let data, let image = await AloAvatarImage.decoded(from: data) else { return }
                cropRequest = AloAvatarCropRequest(image: image)
            }
        }
        .fullScreenCover(item: $cropRequest) { request in
            AloAvatarCropView(image: request.image, onCancel: { cropRequest = nil }) { jpeg in
                cropRequest = nil
                draft.avatarJPEG = jpeg
                preview = UIImage(data: jpeg)
            }
        }
    }

    private var avatar: some View {
        ZStack {
            if let preview {
                Image(uiImage: preview).resizable().scaledToFill()
            } else {
                AloTheme.accent.opacity(0.18)
                Image(systemName: "camera.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(AloTheme.accent)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
    }
}

/// Telegram's "Тип канала": public with a permanent link, or private by invitation.
private struct AloChannelTypeScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: AloCommunityDraft
    let onNext: () -> Void

    private var canContinue: Bool { !draft.isPublic || draft.hasValidUsername }

    var body: some View {
        VStack(spacing: 0) {
            AloCreationHeader(title: "Тип канала", leading: .back, actionTitle: "Далее", actionEnabled: canContinue,
                              onLeading: { dismiss() }, onAction: onNext)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AloCreationCard {
                        typeRow(public: true, title: "Публичный канал",
                                detail: "Любой может найти канал в поиске и подписаться.")
                        AloCreationDivider(leading: 52)
                        typeRow(public: false, title: "Частный канал",
                                detail: "Подписаться можно только по ссылке-приглашению.")
                    }
                    if draft.isPublic {
                        AloCreationSectionTitle(text: "Постоянная ссылка").padding(.top, 18)
                        AloCreationCard {
                            HStack(spacing: 0) {
                                Text("\(AloServerConfiguration.appLinkDisplayHost)/")
                                    .font(.system(size: 17)).foregroundStyle(AloTheme.muted)
                                TextField("ссылка", text: $draft.username)
                                    .font(.system(size: 17)).foregroundStyle(AloTheme.text)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .keyboardType(.asciiCapable)
                                    .accessibilityIdentifier("alo.community.username")
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 50)
                        }
                        AloCreationFootnote(
                            text: !draft.username.isEmpty && !draft.hasValidUsername
                                ? "Ссылка: от 5 до 32 символов — латинские буквы, цифры и «_»."
                                : "По этой ссылке канал можно открыть и найти в поиске.",
                            isWarning: !draft.username.isEmpty && !draft.hasValidUsername)
                    } else {
                        AloCreationFootnote(text: "Ссылку-приглашение можно будет создать в управлении каналом.")
                    }
                }
                .padding(.horizontal, AloSocialMetrics.inset)
                .padding(.bottom, 28)
            }
        }
        .background(AloTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .background(AloNativeBackSwipe())
    }

    private func typeRow(public isPublic: Bool, title: String, detail: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { draft.isPublic = isPublic }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().stroke(draft.isPublic == isPublic ? Color.clear : AloTheme.muted.opacity(0.6), lineWidth: 1.5)
                    if draft.isPublic == isPublic {
                        Circle().fill(AloTheme.accent)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 22, height: 22)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 17)).foregroundStyle(AloTheme.text)
                    Text(detail).font(.system(size: 14)).foregroundStyle(AloTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloChatRowPressStyle())
        .accessibilityAddTraits(draft.isPublic == isPublic ? .isSelected : [])
        .accessibilityIdentifier(isPublic ? "alo.community.public" : "alo.community.private")
    }
}

// MARK: - Shared pieces

/// The settings/chat header: a glass circle on the left, the title centred, a text action on the right.
private struct AloCreationHeader: View {
    enum Leading { case close, back }
    let title: String
    var subtitle = ""
    let leading: Leading
    var actionTitle: String?
    var actionEnabled = true
    var isWorking = false
    let onLeading: () -> Void
    var onAction: () -> Void = {}

    var body: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(AloTheme.text)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                        .contentTransition(.numericText())
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 96)
            .accessibilityAddTraits(.isHeader)
            HStack {
                AloChatCircleButton(systemImage: leading == .close ? "xmark" : "chevron.left",
                                    label: leading == .close ? "Закрыть" : "Назад", action: onLeading)
                    .accessibilityIdentifier("alo.compose.leading")
                Spacer(minLength: 0)
                if let actionTitle {
                    Button(action: onAction) {
                        if isWorking {
                            ProgressView().tint(AloTheme.accent)
                        } else {
                            Text(actionTitle).font(.system(size: 17, weight: .semibold))
                        }
                    }
                    .foregroundStyle(actionEnabled ? AloTheme.accent : AloTheme.muted.opacity(0.55))
                    .disabled(!actionEnabled || isWorking)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .accessibilityIdentifier("alo.compose.action")
                }
            }
        }
        .frame(height: AloChatMetrics.headerHeight)
        .padding(.horizontal, AloChatMetrics.headerHorizontalInset)
        .padding(.top, AloChatMetrics.headerTopInset)
        .padding(.bottom, 8)
    }
}

private struct AloCreationCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AloCreationDivider: View {
    let leading: CGFloat
    var body: some View {
        Rectangle().fill(AloTheme.separator).frame(height: 1 / UIScreen.main.scale).padding(.leading, leading)
    }
}

private struct AloCreationSectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct AloCreationFootnote: View {
    let text: String
    var isWarning = false
    var body: some View {
        Text(text)
            .font(.system(size: 13)).foregroundStyle(isWarning ? AloTheme.destructive : AloTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.top, 7)
    }
}

private struct AloCreationActionRow: View {
    let title: String
    let systemImage: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(AloTheme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title).font(.system(size: 17)).foregroundStyle(AloTheme.accent)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloChatRowPressStyle())
        .accessibilityIdentifier(identifier)
    }
}

private struct AloCandidateRow: View {
    let person: AloCommunityCandidate
    /// nil: a plain row; true/false: a selectable row with Telegram's check circle.
    let selection: Bool?

    var body: some View {
        HStack(spacing: 12) {
            AloAvatar(name: person.name, url: person.avatarUrl, size: 42, colorSeed: String(person.id))
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name).font(.system(size: 17)).foregroundStyle(AloTheme.text).lineLimit(1)
                if !person.username.isEmpty {
                    Text("@\(person.username)").font(.system(size: 14)).foregroundStyle(AloTheme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let selection {
                ZStack {
                    Circle().stroke(selection ? Color.clear : AloTheme.muted.opacity(0.6), lineWidth: 1.5)
                    if selection {
                        Circle().fill(AloTheme.accent)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 24, height: 24)
                .animation(.spring(response: 0.24, dampingFraction: 0.8), value: selection)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("alo.compose.person.\(person.id)")
    }
}

enum AloCommunityPlural {
    static func members(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        let word = mod10 == 1 && mod100 != 11 ? "участник"
            : (2...4).contains(mod10) && !(12...14).contains(mod100) ? "участника" : "участников"
        return "\(count) \(word)"
    }
}
