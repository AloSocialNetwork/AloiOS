import SwiftUI

// The moderation team: who is on it at which level, what each may do, and the people search for
// appointing or restricting someone. The server enforces the ladder; the screens only offer what
// this account may actually do.

struct AloModerationTeamScreen: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var staff: [AloStaffMember] = []
    @State private var assignable: [String] = []
    @State private var isLoading = true
    @State private var opened: AloStaffMember?
    @State private var isSearchPresented = false

    private let levels: [AloStaffHierarchy] = [.owner, .admin, .leadModerator, .moderator]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Button { isSearchPresented = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(AloTheme.muted)
                        Text("Найти человека, чтобы назначить").font(.system(size: 16)).foregroundStyle(AloTheme.muted)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: AloSocialMetrics.searchHeight)
                    .modifier(AloChatGlass(interactive: false, role: .chrome))
                    .contentShape(Capsule())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.98))
                .accessibilityIdentifier("alo.team.search")

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                }
                ForEach(levels, id: \.self) { level in
                    let members = staff.filter { $0.hierarchy == level }
                    if !members.isEmpty {
                        AloModerationCard(title: level.plural) {
                            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                                if index > 0 { AloModerationDivider() }
                                Button { opened = member } label: {
                                    AloStaffRow(member: member, isMe: member.id == app.bootstrap?.me.id)
                                }
                                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
                                .accessibilityIdentifier("alo.team.member.\(member.id)")
                            }
                        }
                    }
                }
                if !isLoading {
                    Text("Владелец назначает администраторов. Администраторы и старшие модераторы назначают модераторов ниже себя и не могут выдать права выше своих. Ограничивать и блокировать аккаунты могут администраторы. Все изменения попадают в журнал.")
                        .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, AloSocialMetrics.inset)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(AloTheme.background.ignoresSafeArea())
        .navigationTitle("Команда")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $opened) { member in
            NavigationStack {
                AloStaffMemberDetail(member: member, assignable: assignable) { await load() }
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { opened = nil } } }
            }
            .presentationDetents([.large])
            .presentationBackground(AloTheme.background)
        }
        .sheet(isPresented: $isSearchPresented) {
            AloStaffSearchSheet(assignable: assignable) { await load() }
                .presentationDetents([.large])
                .presentationBackground(AloTheme.background)
        }
        .accessibilityIdentifier("alo.team")
    }

    private func load() async {
        if let team = try? await app.moderationTeam() {
            staff = team.staff
            assignable = team.assignable
        }
        isLoading = false
    }
}

/// A person in the team or in the search: avatar, name, what they may do, their level.
struct AloStaffRow: View {
    let member: AloStaffMember
    var isMe = false

    var body: some View {
        HStack(spacing: 12) {
            AloAvatar(name: member.user.name, url: member.user.avatarUrl, size: 42, colorSeed: String(member.id))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.user.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text).lineLimit(1)
                    if isMe { Text("вы").font(.system(size: 13)).foregroundStyle(AloTheme.muted) }
                }
                Text(summary).font(.system(size: 13.5)).foregroundStyle(AloTheme.muted).lineLimit(1)
                if let status = member.accountStatusTitle {
                    Text(status).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(member.accountStatus == "banned" ? AloTheme.destructive : AloTheme.warning)
                }
            }
            Spacer(minLength: 8)
            if member.hierarchy != .user {
                Image(systemName: member.hierarchy.symbol).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(member.hierarchy.tint)
                    .accessibilityLabel(member.hierarchy.title)
            }
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .heavy)).foregroundStyle(AloTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .contentShape(Rectangle())
    }

    private var summary: String {
        switch member.hierarchy {
        case .owner, .admin: return "Все права"
        case .user: return member.user.username.isEmpty ? "Пользователь" : member.user.username.withAtPrefix
        default:
            let short: [String: String] = ["reports.review": "Жалобы", "stats.view": "Статистика",
                                           "verification.review": "Верификация", "censorship.manage": "Стоп-слова",
                                           "moderation.manage": "Команда"]
            return AloModeratorPermission.allCases.filter { member.permissions.contains($0.rawValue) }
                .compactMap { short[$0.rawValue] }.joined(separator: " · ")
        }
    }
}

/// One person: their level and rights, and what this account may change about them.
struct AloStaffMemberDetail: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    @State var member: AloStaffMember
    let assignable: [String]
    let onChanged: () async -> Void
    @State private var selected: Set<String> = []
    @State private var reason = ""
    @State private var isSaving = false
    @State private var error = ""
    @State private var confirmation: Confirmation?

    private enum Confirmation: Identifiable {
        case revokeModerator, grantAdmin, revokeAdmin, block(Int), ban, restore
        var id: String {
            switch self {
            case .revokeModerator: return "revokeModerator"
            case .grantAdmin: return "grantAdmin"
            case .revokeAdmin: return "revokeAdmin"
            case .block(let hours): return "block\(hours)"
            case .ban: return "ban"
            case .restore: return "restore"
            }
        }
    }

    private var actorLevel: AloStaffHierarchy { app.bootstrap?.me.staffHierarchy ?? .user }
    private var isMe: Bool { app.bootstrap?.me.id == member.id }
    private var canManage: Bool { !isMe && actorLevel.rank >= 2 && actorLevel.rank > member.hierarchy.rank }
    /// A restricted account is restored first, then appointed.
    private var editableRights: Bool {
        canManage && member.hierarchy.rank < AloStaffHierarchy.admin.rank
            && (member.hierarchy != .user || member.accountStatus == "active")
    }
    private var canAppointAdmins: Bool { actorLevel == .owner && !isMe && member.hierarchy != .owner }
    private var canRestrict: Bool { !isMe && actorLevel.rank >= AloStaffHierarchy.admin.rank && actorLevel.rank > member.hierarchy.rank }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if editableRights { rights }
                if !canManage, !isMe, member.hierarchy != .user {
                    Text("Этот уровень не ниже вашего: изменить его права нельзя.")
                        .font(.system(size: 14)).foregroundStyle(AloTheme.muted)
                }
                if canAppointAdmins, member.accountStatus == "active" || member.hierarchy == .admin { administrator }
                if canRestrict { account }
                if !error.isEmpty {
                    Text(error).font(.system(size: 14)).foregroundStyle(AloTheme.destructive)
                }
            }
            .padding(.horizontal, AloSocialMetrics.inset)
            .padding(.vertical, 12)
        }
        .background(AloTheme.background.ignoresSafeArea())
        .navigationTitle(member.hierarchy == .user ? "Пользователь" : member.hierarchy.title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .onAppear { selected = Set(member.permissions) }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            titleVisibility: .visible, presenting: confirmation) { item in
            Button(confirmationButton(item), role: isDestructive(item) ? .destructive : nil) { perform(item) }
            Button("Отмена", role: .cancel) {}
        }
        .accessibilityIdentifier("alo.team.detail")
    }

    private var header: some View {
        VStack(spacing: 8) {
            AloAvatar(name: member.user.name, url: member.user.avatarUrl, size: 76, colorSeed: String(member.id))
            Text(member.user.name).font(.system(size: 22, weight: .bold)).foregroundStyle(AloTheme.text)
                .multilineTextAlignment(.center)
            if !member.user.username.isEmpty {
                Text(member.user.username.withAtPrefix).font(.system(size: 15)).foregroundStyle(AloTheme.muted)
            }
            AloStaffBadge(hierarchy: member.hierarchy)
            if let status = member.accountStatusTitle {
                Text(member.blockReason.isEmpty ? status : "\(status) · \(member.blockReason)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(member.accountStatus == "banned" ? AloTheme.destructive : AloTheme.warning)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var rights: some View {
        VStack(alignment: .leading, spacing: 12) {
            AloModerationCard(title: "Права модератора") {
                let options = AloModeratorPermission.allCases.filter { assignable.contains($0.rawValue) }
                ForEach(Array(options.enumerated()), id: \.element) { index, permission in
                    if index > 0 { AloModerationDivider() }
                    Toggle(isOn: Binding(get: { selected.contains(permission.rawValue) },
                                         set: { on in if on { selected.insert(permission.rawValue) } else { selected.remove(permission.rawValue) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title).font(.system(size: 16)).foregroundStyle(AloTheme.text)
                            Text(permission.footnote).font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(AloTheme.success)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("alo.team.permission.\(permission.rawValue)")
                }
            }
            let changed = selected != Set(member.permissions)
            primaryButton(member.hierarchy == .user ? "Назначить модератором" : "Сохранить права",
                          identifier: "alo.team.save") { saveRights() }
                .disabled(selected.isEmpty || !changed)
                .opacity(selected.isEmpty || !changed ? 0.5 : 1)
            if member.hierarchy != .user {
                secondaryButton("Снять с модерации", destructive: true, identifier: "alo.team.revoke") {
                    confirmation = .revokeModerator
                }
            }
        }
    }

    private var administrator: some View {
        VStack(alignment: .leading, spacing: 8) {
            AloModerationCard(title: "Администратор") {
                Button {
                    confirmation = member.hierarchy == .admin ? .revokeAdmin : .grantAdmin
                } label: {
                    HStack {
                        Text(member.hierarchy == .admin ? "Снять с должности администратора" : "Сделать администратором")
                            .font(.system(size: 16))
                            .foregroundStyle(member.hierarchy == .admin ? AloTheme.destructive : AloTheme.accent)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("alo.team.admin")
            }
            Text("Администратор получает все права модерации, может ограничивать аккаунты и назначать модераторов. Назначает и снимает администраторов только владелец.")
                .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 8) {
            AloModerationCard(title: "Доступ к аккаунту") {
                if member.accountStatus == "active" {
                    accountRow("Ограничить на сутки", symbol: "clock", color: AloTheme.warning) { confirmation = .block(24) }
                    AloModerationDivider()
                    accountRow("Ограничить на неделю", symbol: "calendar", color: AloTheme.warning) { confirmation = .block(24 * 7) }
                    AloModerationDivider()
                    accountRow("Заблокировать навсегда", symbol: "hand.raised.slash", color: AloTheme.destructive) { confirmation = .ban }
                    AloModerationDivider()
                    TextField("Причина (её увидит человек)", text: $reason, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.system(size: 16)).foregroundStyle(AloTheme.text)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("alo.team.reason")
                } else {
                    accountRow("Восстановить доступ", symbol: "arrow.uturn.backward", color: AloTheme.success) { confirmation = .restore }
                }
            }
            Text("Ограниченный или заблокированный аккаунт сразу выходит со всех устройств. Человек может обжаловать решение со страницы входа.")
                .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func accountRow(_ title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(color).frame(width: 24)
                Text(title).font(.system(size: 16)).foregroundStyle(color)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(AloTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.98))
        .accessibilityIdentifier(identifier)
    }

    private func secondaryButton(_ title: String, destructive: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(destructive ? AloTheme.destructive : AloTheme.text)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.98))
        .accessibilityIdentifier(identifier)
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .revokeModerator: return "Снять \(member.user.name) с модерации?"
        case .grantAdmin: return "Сделать \(member.user.name) администратором?"
        case .revokeAdmin: return "Снять \(member.user.name) с должности администратора?"
        case .block(let hours): return hours > 24 ? "Ограничить доступ на неделю?" : "Ограничить доступ на сутки?"
        case .ban: return "Заблокировать \(member.user.name) навсегда?"
        case .restore: return "Восстановить доступ \(member.user.name)?"
        case nil: return ""
        }
    }

    private func confirmationButton(_ item: Confirmation) -> String {
        switch item {
        case .revokeModerator: return "Снять с модерации"
        case .grantAdmin: return "Назначить"
        case .revokeAdmin: return "Снять"
        case .block: return "Ограничить"
        case .ban: return "Заблокировать"
        case .restore: return "Восстановить"
        }
    }

    private func isDestructive(_ item: Confirmation) -> Bool {
        switch item {
        case .grantAdmin, .restore: return false
        default: return true
        }
    }

    private func perform(_ item: Confirmation) {
        switch item {
        case .revokeModerator: run(notice: "Снят с модерации") { try await app.setModeratorPermissions(member, permissions: []) }
        case .grantAdmin: run(notice: "Назначен администратором") { member = try await app.setAdministrator(member, granted: true) }
        case .revokeAdmin: run(notice: "Снят с должности администратора") { member = try await app.setAdministrator(member, granted: false) }
        case .block(let hours):
            run(notice: "Доступ ограничен") { member = try await app.setAccountStatus(member, status: "blocked", hours: hours, reason: reason) }
        case .ban: run(notice: "Аккаунт заблокирован") { member = try await app.setAccountStatus(member, status: "banned", hours: 24, reason: reason) }
        case .restore: run(notice: "Доступ восстановлен") { member = try await app.setAccountStatus(member, status: "active", hours: 24, reason: "") }
        }
    }

    private func saveRights() {
        let permissions = AloModeratorPermission.allCases.map(\.rawValue).filter(selected.contains)
        run(notice: member.hierarchy == .user ? "Назначен модератором" : "Права сохранены") {
            try await app.setModeratorPermissions(member, permissions: permissions)
        }
    }

    private func run(notice: String, _ work: @escaping () async throws -> Void) {
        isSaving = true
        error = ""
        Task {
            defer { isSaving = false }
            do {
                try await work()
                AloHaptics.notification(.success)
                app.notice = notice
                await onChanged()
                dismiss()
            } catch {
                self.error = (error as? AloAPIError)?.message ?? "Не удалось сохранить."
            }
        }
    }
}

/// Anyone by name, @username or id, to appoint as a moderator or to restrict.
private struct AloStaffSearchSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let assignable: [String]
    let onChanged: () async -> Void
    @State private var query = ""
    @State private var results: [AloStaffMember] = []
    @State private var isFocused = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AloSocialSearchField(text: $query, identifier: "alo.team.people", focused: $isFocused)
                    if !results.isEmpty {
                        AloModerationCard {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, member in
                                if index > 0 { AloModerationDivider() }
                                NavigationLink {
                                    AloStaffMemberDetail(member: member, assignable: assignable) {
                                        await onChanged()
                                    }
                                } label: {
                                    AloStaffRow(member: member, isMe: member.id == app.bootstrap?.me.id)
                                }
                                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
                                .accessibilityIdentifier("alo.team.result.\(member.id)")
                            }
                        }
                    } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Никого не нашли").font(.system(size: 15)).foregroundStyle(AloTheme.muted)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    } else {
                        Text("Имя, @username или номер аккаунта. Найдутся и заблокированные.")
                            .font(.system(size: 14)).foregroundStyle(AloTheme.muted)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, AloSocialMetrics.inset)
                .padding(.vertical, 8)
            }
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Найти человека")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .task(id: query) {
                let text = query.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { results = []; return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                results = (try? await app.searchStaffCandidates(text)) ?? results
            }
        }
    }
}
