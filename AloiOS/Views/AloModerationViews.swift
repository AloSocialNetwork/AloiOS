import SwiftUI

// The moderation panel for admins and moderators, appeals for everyone, and Alo's own ads.

// MARK: - Panel

/// The panel's root: the queues with their counts, the team, the log and the ads, as settings-style
/// cards; each opens its own screen. Sections follow what this account may do.
struct AloModerationPanel: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var reportCount: Int?
    @State private var appealCount: Int?

    var body: some View {
        let me = app.bootstrap?.me
        let can = me?.adminCan ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let me { AloStaffIdentityCard(user: me) }
                if can.contains("reports") {
                    AloModerationCard(title: "Очередь") {
                        NavigationLink { AloReportQueue(onCount: { reportCount = $0 }) } label: {
                            AloModerationNavRow(title: "Жалобы", subtitle: "Публикации, комментарии, люди и каналы",
                                                symbol: "flag.fill", tint: AloTheme.destructive, badge: reportCount)
                        }
                        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
                        .accessibilityIdentifier("alo.moderation.reports")
                        AloModerationDivider()
                        NavigationLink { AloAppealQueue(onCount: { appealCount = $0 }) } label: {
                            AloModerationNavRow(title: "Апелляции", subtitle: "Обжалования решений и блокировок",
                                                symbol: "arrow.uturn.backward", tint: AloTheme.warning, badge: appealCount)
                        }
                        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
                        .accessibilityIdentifier("alo.moderation.appeals")
                    }
                }
                if can.contains("moderation") {
                    AloModerationCard(title: "Команда") {
                        NavigationLink { AloModerationTeamScreen() } label: {
                            AloModerationNavRow(title: "Команда и права", subtitle: "Модераторы, уровни и доступ к аккаунтам",
                                                symbol: "person.3.fill", tint: Color(red: 0.53, green: 0.41, blue: 0.94))
                        }
                        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
                        .accessibilityIdentifier("alo.moderation.team")
                    }
                }
                if can.contains("reports") || can.contains("moderation") {
                    AloModerationCard(title: "История и реклама") {
                        if can.contains("reports") {
                            NavigationLink { AloAuditLogList() } label: {
                                AloModerationNavRow(title: "Журнал действий", subtitle: "Кто, что и когда решил",
                                                    symbol: "list.bullet.rectangle", tint: AloTheme.accent)
                            }
                            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
                            .accessibilityIdentifier("alo.moderation.audit")
                        }
                        if can.contains("reports"), can.contains("moderation") { AloModerationDivider() }
                        if can.contains("moderation") {
                            NavigationLink { AloAdCampaignList() } label: {
                                AloModerationNavRow(title: "Реклама", subtitle: "Кампании, показы и клики",
                                                    symbol: "megaphone.fill", tint: AloTheme.success)
                            }
                            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
                            .accessibilityIdentifier("alo.moderation.ads")
                        }
                    }
                }
            }
            .padding(.horizontal, AloSocialMetrics.inset)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(AloTheme.background.ignoresSafeArea())
        .navigationTitle("Модерация")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            if can.contains("reports") {
                reportCount = (try? await app.moderationReports())?.count
                appealCount = (try? await app.moderationAppeals())?.count
            }
        }
        .accessibilityIdentifier("alo.moderation.panel")
    }
}

/// Who you are in the team: your avatar, name and level.
private struct AloStaffIdentityCard: View {
    let user: AloCurrentUser

    var body: some View {
        HStack(spacing: 12) {
            AloAvatar(name: user.name, url: user.avatarUrl, size: 48, colorSeed: String(user.id))
            VStack(alignment: .leading, spacing: 4) {
                Text(user.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(AloTheme.text).lineLimit(1)
                AloStaffBadge(hierarchy: user.staffHierarchy)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Pending reports, newest first; a tap opens the decision.
private struct AloReportQueue: View {
    @EnvironmentObject private var app: AloAppModel
    var onCount: (Int) -> Void = { _ in }
    @State private var reports: [AloModerationReport] = []
    @State private var isLoading = true
    @State private var deciding: AloModerationReport?

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if reports.isEmpty {
                ContentUnavailableView("Жалоб нет", systemImage: "checkmark.shield",
                                       description: Text("Новые жалобы пользователей появятся здесь."))
                    .foregroundStyle(AloTheme.muted)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(reports) { report in
                            Button { deciding = report } label: { AloReportRow(report: report) }
                                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
                                .accessibilityIdentifier("alo.moderation.report.\(report.id)")
                        }
                    }
                    .padding(.horizontal, AloSocialMetrics.inset)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(AloTheme.background.ignoresSafeArea())
        .navigationTitle("Жалобы")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $deciding) { report in
            AloReportDecisionSheet(report: report) {
                reports.removeAll { $0.id == report.id }
                onCount(reports.count)
            }
        }
    }

    private func load() async {
        reports = (try? await app.moderationReports()) ?? reports
        isLoading = false
        onCount(reports.count)
    }
}

/// A report in the queue: the reason, what it is about with a short preview, who sent it.
private struct AloReportRow: View {
    let report: AloModerationReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(report.reason)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(AloTheme.destructive.opacity(0.85), in: Capsule())
                Text(report.targetTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.text)
                Spacer(minLength: 0)
                Text(AloPostTimestamp.string(report.createdAt)).font(.system(size: 13)).foregroundStyle(AloTheme.muted)
            }
            if let target = report.target {
                AloReportTargetView(target: target, compact: true)
            } else if !report.targetPostBody.isEmpty {
                Text(report.targetPostBody).font(.system(size: 15)).foregroundStyle(AloTheme.text).lineLimit(3)
            }
            HStack(spacing: 6) {
                Text("От \(report.reporter.name)\(report.details.isEmpty ? "" : ": «\(report.details)»")")
                    .lineLimit(2)
                Spacer(minLength: 0)
                if report.otherPendingCount > 0 {
                    Text("ещё \(report.otherPendingCount)").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AloTheme.destructive)
                }
            }
            .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// What a report points at: the post or comment with its author, text and media, the person, or
/// the channel. `compact` is the queue's short form; the decision shows everything, photos open.
struct AloReportTargetView: View {
    let target: AloReportedContent
    var compact = false

    var body: some View {
        Group {
            if target.deleted {
                Label("Уже удалено", systemImage: "trash.slash")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(AloTheme.muted)
            } else {
                switch target.kind {
                case "post", "comment": content
                case "channel": channel
                default: person
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AloTheme.surfaceRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let author = target.author { authorRow(author, size: 30) }
            if !target.body.isEmpty {
                Text(target.body).font(.system(size: 15)).foregroundStyle(AloTheme.text)
                    .lineLimit(compact ? 3 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !target.media.isEmpty {
                if compact {
                    HStack(spacing: 4) {
                        ForEach(target.media.prefix(4)) { item in
                            AloReportMediaThumbnail(item: item).frame(width: 56, height: 56)
                        }
                        if target.media.count > 4 {
                            Text("+\(target.media.count - 4)").font(.system(size: 13, weight: .semibold)).foregroundStyle(AloTheme.muted)
                        }
                    }
                } else {
                    AloPostMediaGrid(media: target.media, timeline: true)
                }
            }
            if !compact {
                HStack(spacing: 14) {
                    if target.kind == "post" {
                        Label("\(target.likeCount)", systemImage: "heart")
                        Label("\(target.commentCount)", systemImage: "bubble.right")
                    } else if target.postId > 0 {
                        Text("Комментарий к публикации #\(target.postId)")
                    }
                    Spacer(minLength: 0)
                    if !target.createdAt.isEmpty { Text(AloPostTimestamp.string(target.createdAt)) }
                }
                .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
            }
        }
    }

    private var person: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let user = target.user { authorRow(user, size: compact ? 34 : 48) }
            if !target.bio.isEmpty {
                Text(target.bio).font(.system(size: 14)).foregroundStyle(AloTheme.text).lineLimit(compact ? 2 : nil)
            }
            HStack(spacing: 8) {
                if target.hierarchy != .user { AloStaffBadge(hierarchy: target.hierarchy) }
                if target.accountStatus == "blocked" {
                    Text("Доступ ограничен").font(.system(size: 13, weight: .semibold)).foregroundStyle(AloTheme.warning)
                } else if target.accountStatus == "banned" {
                    Text("Заблокирован").font(.system(size: 13, weight: .semibold)).foregroundStyle(AloTheme.destructive)
                }
            }
        }
    }

    private var channel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AloAvatar(name: target.title, url: target.avatar, size: compact ? 34 : 48, colorSeed: "channel-\(target.id)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.text)
                    Text("\(target.slug.isEmpty ? "" : "@\(target.slug) · ")\(aloCompactCount(target.subscribersCount)) подписчиков")
                        .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                }
            }
            if !target.channelDescription.isEmpty {
                Text(target.channelDescription).font(.system(size: 14)).foregroundStyle(AloTheme.text).lineLimit(compact ? 2 : nil)
            }
            if !compact, let owner = target.author {
                Text("Владелец: \(owner.name)").font(.system(size: 13)).foregroundStyle(AloTheme.muted)
            }
        }
    }

    private func authorRow(_ user: AloEntitySummary, size: CGFloat) -> some View {
        HStack(spacing: 8) {
            AloAvatar(name: user.name, url: user.avatarUrl, size: size, colorSeed: String(user.id))
            VStack(alignment: .leading, spacing: 1) {
                Text(user.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.text).lineLimit(1)
                if !user.username.isEmpty {
                    Text(user.username.withAtPrefix).font(.system(size: 13)).foregroundStyle(AloTheme.muted).lineLimit(1)
                }
            }
        }
    }
}

/// A square of a reported photo (or a video's still) in the queue.
private struct AloReportMediaThumbnail: View {
    @Environment(\.aloAPIClient) private var api
    let item: AloMediaItem

    var body: some View {
        ZStack {
            AloTheme.surface
            if let url = api?.absoluteURL(item.posterUrl.ifBlank(item.url)) {
                AloAsyncImage(url: url) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() } else { Color.clear }
                }
            }
            if item.type == "video" {
                Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Approve with a measure, or reject; the decision and its note go to the audit log.
private struct AloReportDecisionSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let report: AloModerationReport
    let onDecided: () -> Void
    @State private var action: AloModerationAction = .warn
    @State private var blockHours = 24
    @State private var note = ""
    @State private var isSaving = false
    @State private var error = ""

    private let durations: [(hours: Int, title: String)] = [(24, "Сутки"), (24 * 7, "Неделя"), (24 * 30, "Месяц")]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(report.reason)
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 9).frame(height: 24)
                                .background(AloTheme.destructive.opacity(0.85), in: Capsule())
                            Text(report.targetTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.text)
                            Spacer(minLength: 0)
                        }
                        Text("От \(report.reporter.name) · \(AloPostTimestamp.string(report.createdAt))")
                            .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                        if !report.details.isEmpty {
                            Text("«\(report.details)»").font(.system(size: 15)).foregroundStyle(AloTheme.text)
                        }
                        if report.otherPendingCount > 0 {
                            Text("На это пожаловались ещё \(report.otherPendingCount)")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(AloTheme.destructive)
                        }
                    }
                    if let target = report.target {
                        AloReportTargetView(target: target)
                    } else if !report.targetPostBody.isEmpty {
                        Text(report.targetPostBody).font(.system(size: 15)).foregroundStyle(AloTheme.text)
                    }

                    AloModerationCard(title: "Мера") {
                        ForEach(Array(AloModerationAction.available(for: report.targetType).enumerated()), id: \.element) { index, option in
                            if index > 0 { AloModerationDivider() }
                            Button { action = option } label: {
                                HStack {
                                    Text(option.title).font(.system(size: 16))
                                        .foregroundStyle(option.isDestructive ? AloTheme.destructive : AloTheme.text)
                                    Spacer(minLength: 0)
                                    if action == option {
                                        Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(AloTheme.accent)
                                    }
                                }
                                .frame(minHeight: 46).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(action == option ? .isSelected : [])
                        }
                        if action == .block {
                            AloModerationDivider()
                            Picker("Срок", selection: $blockHours) {
                                ForEach(durations, id: \.hours) { Text($0.title).tag($0.hours) }
                            }
                            .pickerStyle(.segmented)
                            .padding(.vertical, 10)
                            .accessibilityIdentifier("alo.moderation.block-duration")
                        }
                    }

                    TextField("Комментарий для журнала", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.system(size: 16)).foregroundStyle(AloTheme.text)
                        .padding(14)
                        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if !error.isEmpty {
                        Text(error).font(.system(size: 14)).foregroundStyle(AloTheme.destructive)
                    }

                    VStack(spacing: 10) {
                        Button { decide(approve: true) } label: {
                            Text("Подтвердить: \(action.title.lowercased())")
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(action.isDestructive ? AloTheme.destructive : AloTheme.accent,
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .accessibilityIdentifier("alo.moderation.approve")
                        Button { decide(approve: false) } label: {
                            Text("Отклонить жалобу")
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .accessibilityIdentifier("alo.moderation.reject")
                    }
                    .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.98))
                    .disabled(isSaving)
                }
                .padding(.horizontal, AloSocialMetrics.inset)
                .padding(.vertical, 12)
            }
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Решение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationBackground(AloTheme.background)
    }

    private func decide(approve: Bool) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await app.resolveModerationReport(report, approve: approve, action: action, note: note,
                                                      blockHours: action == .block ? blockHours : 24)
                AloHaptics.notification(.success)
                onDecided()
                dismiss()
            } catch {
                self.error = (error as? AloAPIError)?.message ?? "Не удалось сохранить решение."
            }
        }
    }
}

// MARK: - Shared pieces

/// A settings-style card: an optional grey title over rows on the surface colour.
struct AloModerationCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AloTheme.muted)
                    .textCase(.uppercase).padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

struct AloModerationDivider: View {
    var body: some View { Rectangle().fill(AloTheme.separator).frame(height: 0.5) }
}

/// An icon tile, a title with a line of explanation, a count and a chevron.
struct AloModerationNavRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    var badge: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                Text(subtitle).font(.system(size: 13.5)).foregroundStyle(AloTheme.muted).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let badge, badge > 0 {
                Text("\(badge)").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(minWidth: 24, minHeight: 24)
                    .background(AloTheme.destructive, in: Capsule())
            }
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .heavy)).foregroundStyle(AloTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .contentShape(Rectangle())
    }
}

/// A level on the moderation ladder: its symbol and name in its colour.
struct AloStaffBadge: View {
    let hierarchy: AloStaffHierarchy

    var body: some View {
        Label(hierarchy.title, systemImage: hierarchy.symbol)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(hierarchy.tint)
            .padding(.horizontal, 8).frame(height: 22)
            .background(hierarchy.tint.opacity(0.15), in: Capsule())
            .labelStyle(.titleAndIcon)
    }
}

extension AloStaffHierarchy {
    var tint: Color {
        switch self {
        case .owner: return Color(red: 1.0, green: 0.76, blue: 0.20)
        case .admin: return AloTheme.destructive
        case .leadModerator: return Color(red: 0.69, green: 0.52, blue: 1.0)
        case .moderator: return AloTheme.accent
        case .user: return AloTheme.muted
        }
    }
}

private struct AloAppealQueue: View {
    @EnvironmentObject private var app: AloAppModel
    var onCount: (Int) -> Void = { _ in }
    @State private var appeals: [AloModerationAppeal] = []
    @State private var isLoading = true
    @State private var note = ""

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appeals.isEmpty {
                ContentUnavailableView("Обжалований нет", systemImage: "scale.3d",
                                       description: Text("Когда кто-то оспорит решение, оно появится здесь."))
                    .foregroundStyle(AloTheme.muted)
            } else {
                List(appeals) { appeal in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            if let user = appeal.user {
                                AloAvatar(name: user.name, url: user.avatarUrl, size: 36, colorSeed: String(user.id))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(user.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.text)
                                    Text(appeal.actionTitle).font(.system(size: 12)).foregroundStyle(AloTheme.muted)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(AloPostTimestamp.string(appeal.createdAt)).font(.system(size: 12)).foregroundStyle(AloTheme.muted)
                        }
                        Text("«\(appeal.text)»").font(.system(size: 14)).foregroundStyle(AloTheme.text)
                        HStack(spacing: 10) {
                            Button("Отменить решение") { resolve(appeal, overturn: true) }
                                .buttonStyle(.borderedProminent).tint(AloTheme.success)
                                .accessibilityIdentifier("alo.moderation.appeal.overturn")
                            Button("Оставить в силе") { resolve(appeal, overturn: false) }
                                .buttonStyle(.bordered)
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AloTheme.background.ignoresSafeArea())
        .navigationTitle("Апелляции")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        appeals = (try? await app.moderationAppeals()) ?? appeals
        isLoading = false
        onCount(appeals.count)
    }

    private func resolve(_ appeal: AloModerationAppeal, overturn: Bool) {
        Task {
            do {
                try await app.resolveModerationAppeal(appeal, overturn: overturn)
                withAnimation { appeals.removeAll { $0.id == appeal.id } }
                onCount(appeals.count)
                app.notice = overturn ? "Решение отменено, доступ восстановлен" : "Решение оставлено в силе"
            } catch {
                app.notice = (error as? AloAPIError)?.message ?? "Не удалось сохранить решение."
            }
        }
    }
}

private struct AloAuditLogList: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var entries: [AloModerationAuditEntry] = []
    @State private var nextBefore: Int?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("Журнал пуст", systemImage: "list.bullet.clipboard",
                                       description: Text("Здесь будут все решения модераторов."))
                    .foregroundStyle(AloTheme.muted)
            } else {
                List {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: entry.symbol)
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.accent)
                                .frame(width: 30, height: 30)
                                .background(AloTheme.accent.opacity(0.14), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.text)
                                Text([entry.actor.name, entry.target.map { "→ \($0.name)" }].compactMap { $0 }.joined(separator: " "))
                                    .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                                if !entry.readableDetails.isEmpty {
                                    Text(entry.readableDetails).font(.system(size: 13)).foregroundStyle(AloTheme.text.opacity(0.85))
                                }
                            }
                            Spacer(minLength: 0)
                            Text(AloPostTimestamp.string(entry.createdAt)).font(.system(size: 12)).foregroundStyle(AloTheme.muted)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                        .onAppear { if entry.id == entries.last?.id, nextBefore != nil { Task { await loadMore() } } }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AloTheme.background.ignoresSafeArea())
        .navigationTitle("Журнал")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let page = try? await app.moderationAudit(before: nil) {
                entries = page.entries
                nextBefore = page.nextBefore
            }
            isLoading = false
        }
    }

    private func loadMore() async {
        guard let before = nextBefore, let page = try? await app.moderationAudit(before: before) else { return }
        entries += page.entries
        nextBefore = page.nextBefore
    }
}

// MARK: - Ads admin

private struct AloAdCampaignList: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var campaigns: [AloAdCampaign] = []
    @State private var isLoading = true
    @State private var editing: AloAdEditorRequest?

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        Button { editing = AloAdEditorRequest(campaign: nil) } label: {
                            Label("Новая кампания", systemImage: "plus.circle.fill").font(.system(size: 16, weight: .semibold))
                        }
                        .accessibilityIdentifier("alo.ads.new")
                    } footer: {
                        Text("Реклама Alo показывается с меткой «Реклама» в ленте (одна на 6 публикаций) и под постами каналов. Не больше трёх показов одного объявления в день.")
                    }
                    ForEach(campaigns) { campaign in
                        Button { editing = AloAdEditorRequest(campaign: campaign) } label: { row(campaign) }
                            .buttonStyle(.plain)
                            .listRowBackground(AloTheme.surfaceRaised.opacity(0.55))
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(AloTheme.background.ignoresSafeArea())
        .navigationTitle("Реклама")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { request in
            AloAdCampaignEditor(campaign: request.campaign) { saved in
                if let index = campaigns.firstIndex(where: { $0.id == saved.id }) { campaigns[index] = saved } else { campaigns.insert(saved, at: 0) }
            }
        }
    }

    private func load() async {
        campaigns = (try? await app.adCampaigns()) ?? campaigns
        isLoading = false
    }

    private func row(_ campaign: AloAdCampaign) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(campaign.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                Spacer()
                Text(campaign.statusTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(campaign.status == "active" ? AloTheme.success : AloTheme.muted)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background((campaign.status == "active" ? AloTheme.success : AloTheme.muted).opacity(0.15), in: Capsule())
            }
            Text("\(campaign.ad.placement == "channel" ? "Каналы" : "Лента") · \(campaign.ad.advertiser)")
                .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
            HStack(spacing: 0) {
                metric(campaign.impressions, "показов")
                metric(campaign.reach, "охват")
                metric(campaign.clicks, "кликов")
                VStack(spacing: 1) {
                    Text(String(format: "%.1f%%", campaign.ctr)).font(.system(size: 16, weight: .bold).monospacedDigit())
                    Text("CTR").font(.system(size: 11)).foregroundStyle(AloTheme.muted)
                }
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(AloTheme.text)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func metric(_ value: Int, _ title: String) -> some View {
        VStack(spacing: 1) {
            Text(AloCompactCount.string(value)).font(.system(size: 16, weight: .bold).monospacedDigit())
            Text(title).font(.system(size: 11)).foregroundStyle(AloTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

struct AloAdEditorRequest: Identifiable {
    let id = UUID()
    let campaign: AloAdCampaign?
}

private struct AloAdCampaignEditor: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let campaign: AloAdCampaign?
    let onSaved: (AloAdCampaign) -> Void
    @State private var name = ""
    @State private var advertiser = "Alo"
    @State private var title = ""
    @State private var text = ""
    @State private var ctaLabel = "Подробнее"
    @State private var ctaUrl = ""
    @State private var placement = "feed"
    @State private var status = "draft"
    @State private var impressionLimit = 0
    @State private var error = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Кампания") {
                    TextField("Название", text: $name).accessibilityIdentifier("alo.ads.name")
                    Picker("Где показывать", selection: $placement) {
                        Text("Лента").tag("feed")
                        Text("Каналы").tag("channel")
                    }
                    Picker("Статус", selection: $status) {
                        Text("Черновик").tag("draft")
                        Text("Показывается").tag("active")
                        Text("На паузе").tag("paused")
                        Text("Завершена").tag("ended")
                    }
                    Stepper(impressionLimit == 0 ? "Без лимита показов" : "Лимит: \(AloCompactCount.string(impressionLimit))",
                            value: $impressionLimit, in: 0...1_000_000, step: 1_000)
                }
                Section("Объявление") {
                    TextField("Рекламодатель", text: $advertiser)
                    TextField("Заголовок", text: $title)
                    TextField("Текст", text: $text, axis: .vertical).lineLimit(3...6).accessibilityIdentifier("alo.ads.text")
                    TextField("Кнопка", text: $ctaLabel)
                    TextField("Ссылка (https:// или alo://)", text: $ctaUrl)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("alo.ads.link")
                }
                Section("Так увидят пользователи") {
                    AloSponsoredCard(ad: preview, placement: placement, onAction: { _ in })
                        .allowsHitTesting(false)
                        .listRowInsets(EdgeInsets())
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(AloTheme.destructive) } }
            }
            .scrollContentBackground(.hidden)
            .background(AloTheme.background)
            .navigationTitle(campaign == nil ? "Новая кампания" : "Кампания")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") { save() }.fontWeight(.semibold).disabled(isSaving)
                        .accessibilityIdentifier("alo.ads.save")
                }
            }
        }
        .onAppear {
            guard let campaign else { return }
            name = campaign.name; advertiser = campaign.ad.advertiser; title = campaign.ad.title; text = campaign.ad.body
            ctaLabel = campaign.ad.ctaLabel; ctaUrl = campaign.ad.ctaUrl; placement = campaign.ad.placement
            status = campaign.status; impressionLimit = campaign.impressionLimit
        }
    }

    private var preview: AloAd {
        AloAd(["id": campaign?.id ?? 0, "placement": placement, "advertiser": advertiser, "title": title,
               "body": text.ifBlank("Текст объявления"), "ctaLabel": ctaLabel, "ctaUrl": ctaUrl])
    }

    private func save() {
        isSaving = true
        error = ""
        let fields: [String: Any] = ["name": name, "advertiser": advertiser, "title": title, "body": text, "ctaLabel": ctaLabel,
                                     "ctaUrl": ctaUrl, "placement": placement, "status": status, "impressionLimit": impressionLimit]
        Task {
            defer { isSaving = false }
            do {
                onSaved(try await app.saveAdCampaign(id: campaign?.id, fields: fields))
                dismiss()
            } catch {
                self.error = (error as? AloAPIError)?.message ?? "Не удалось сохранить кампанию."
            }
        }
    }
}

// MARK: - Ads as viewers see them

enum AloAdAction { case open, why, hide, report }

/// A sponsored post in the feed or Telegram's sponsored message under a channel: always labelled
/// "Реклама", with "Почему я это вижу", hide and report.
struct AloSponsoredCard: View {
    let ad: AloAd
    var placement = "feed"
    let onAction: (AloAdAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(ad.label)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(AloTheme.accent)
                    .accessibilityIdentifier("alo.ad.label")
                Text("· \(ad.advertiser)").font(.system(size: 12)).foregroundStyle(AloTheme.muted).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button { onAction(.why) } label: { Label("Почему я это вижу", systemImage: "info.circle") }
                    Button { onAction(.hide) } label: { Label("Скрыть рекламу", systemImage: "eye.slash") }
                    Button(role: .destructive) { onAction(.report) } label: { Label("Пожаловаться", systemImage: "exclamationmark.bubble") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.muted)
                        .frame(width: 36, height: 28).contentShape(Rectangle())
                }
                .accessibilityLabel("Действия с рекламой")
                .accessibilityIdentifier("alo.ad.menu.\(ad.id)")
            }
            if !ad.title.isEmpty {
                Text(ad.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
            }
            Text(ad.body).font(.system(size: 15)).foregroundStyle(AloTheme.text).fixedSize(horizontal: false, vertical: true)
            Button { onAction(.open) } label: {
                Text(ad.ctaLabel)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.accent)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(AloTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(AloFeedPressStyle())
            .accessibilityIdentifier("alo.ad.open.\(ad.id)")
        }
        .padding(14)
        .background(AloTheme.surfaceRaised.opacity(placement == "channel" ? 0.9 : 0.55),
                    in: RoundedRectangle(cornerRadius: placement == "channel" ? 18 : 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.ad.\(ad.id)")
    }
}

/// Shows an ad, counts the impression once, and handles its menu.
struct AloSponsoredSlot: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.openURL) private var openURL
    let ad: AloAd
    var placement = "feed"
    @State private var showsWhy = false
    @State private var counted = false

    var body: some View {
        AloSponsoredCard(ad: ad, placement: placement) { action in
            switch action {
            case .open:
                app.recordAdEvent(ad, kind: "click", placement: placement)
                if let url = URL(string: ad.ctaUrl) {
                    if AloDeepLinkTarget(url: url) != nil { app.handleDeepLink(url) } else { openURL(url) }
                }
            case .why: showsWhy = true
            case .hide: app.hideAd(ad, report: false, placement: placement)
            case .report: app.hideAd(ad, report: true, placement: placement)
            }
        }
        .onAppear {
            guard !counted else { return }
            counted = true
            app.recordAdEvent(ad, kind: "impression", placement: placement)
        }
        .alert("Почему я вижу эту рекламу", isPresented: $showsWhy) {
            Button("Понятно", role: .cancel) {}
            Button("Скрыть рекламу") { app.hideAd(ad, report: false, placement: placement) }
        } message: {
            Text(ad.why.ifBlank("Это реклама Alo. Её показывают всем в этом разделе, без учёта ваших переписок и интересов."))
        }
    }
}

// MARK: - Appeals

/// Contest a moderation decision about you, from its notification.
struct AloAppealSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSend: (String) async throws -> Void
    @State private var text = ""
    @State private var isSending = false
    @State private var error = ""
    @State private var isSent = false

    var body: some View {
        NavigationStack {
            Form {
                if isSent {
                    Section {
                        Label("Обжалование отправлено. Модераторы рассмотрят его и пришлют ответ.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(AloTheme.success)
                    }
                } else {
                    Section {
                        TextField("Почему решение неверно?", text: $text, axis: .vertical)
                            .lineLimit(4...8)
                            .accessibilityIdentifier("alo.appeal.text")
                    } footer: {
                        Text("Модератор, который не принимал первое решение, посмотрит ещё раз. Ответ придёт в уведомлениях.")
                    }
                    if !error.isEmpty { Section { Text(error).foregroundStyle(AloTheme.destructive) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AloTheme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(isSent ? "Готово" : "Отмена") { dismiss() } }
                if !isSent {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Отправить") { send() }
                            .fontWeight(.semibold)
                            .disabled(isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
                            .accessibilityIdentifier("alo.appeal.send")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        isSending = true
        error = ""
        Task {
            defer { isSending = false }
            do {
                try await onSend(text.trimmingCharacters(in: .whitespacesAndNewlines))
                withAnimation { isSent = true }
            } catch {
                self.error = (error as? AloAPIError)?.message ?? "Не удалось отправить обжалование."
            }
        }
    }
}
