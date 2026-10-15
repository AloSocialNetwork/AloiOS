import SwiftUI

// The moderation panel for admins and moderators, appeals for everyone, and Alo's own ads.

// MARK: - Panel

struct AloModerationPanel: View {
    @EnvironmentObject private var app: AloAppModel
    enum Tab: String, CaseIterable, Identifiable {
        case reports = "Жалобы", appeals = "Апелляции", audit = "Журнал", ads = "Реклама"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .reports

    private var tabs: [Tab] {
        let can = app.bootstrap?.me.adminCan ?? []
        return Tab.allCases.filter { tab in
            switch tab {
            case .reports, .appeals, .audit: return can.contains("reports")
            case .ads: return can.contains("moderation")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Раздел", selection: $tab) {
                ForEach(tabs) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .accessibilityIdentifier("alo.moderation.tabs")
            switch tab {
            case .reports: AloReportQueue()
            case .appeals: AloAppealQueue()
            case .audit: AloAuditLogList()
            case .ads: AloAdCampaignList()
            }
        }
        .background(AloTheme.background.ignoresSafeArea())
        .navigationTitle("Модерация")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { if !tabs.contains(tab), let first = tabs.first { tab = first } }
        .accessibilityIdentifier("alo.moderation.panel")
    }
}

/// Pending reports, oldest first; a tap opens the decision.
private struct AloReportQueue: View {
    @EnvironmentObject private var app: AloAppModel
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
                List(reports) { report in
                    Button { deciding = report } label: { row(report) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("alo.moderation.report.\(report.id)")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $deciding) { report in
            AloReportDecisionSheet(report: report) {
                reports.removeAll { $0.id == report.id }
            }
        }
    }

    private func load() async {
        reports = (try? await app.moderationReports()) ?? reports
        isLoading = false
    }

    private func row(_ report: AloModerationReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(report.reason)
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(AloTheme.destructive.opacity(0.85), in: Capsule())
                Text(report.targetTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.text)
                Spacer(minLength: 0)
                Text(AloPostTimestamp.string(report.createdAt)).font(.system(size: 12)).foregroundStyle(AloTheme.muted)
            }
            if !report.targetPostBody.isEmpty {
                Text(report.targetPostBody).font(.system(size: 14)).foregroundStyle(AloTheme.text).lineLimit(3)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AloTheme.surfaceRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text("Отправитель: \(report.reporter.name)\(report.details.isEmpty ? "" : " · «\(report.details)»")")
                .font(.system(size: 13)).foregroundStyle(AloTheme.muted).lineLimit(2)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Approve with a measure, or reject; the decision and its note go to the audit log.
private struct AloReportDecisionSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let report: AloModerationReport
    let onDecided: () -> Void
    @State private var action: AloModerationAction = .warn
    @State private var note = ""
    @State private var isSaving = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Жалоба") {
                    LabeledContent("Причина", value: report.reason)
                    LabeledContent("Объект", value: report.targetTitle)
                    if !report.details.isEmpty { Text(report.details).foregroundStyle(AloTheme.muted) }
                    if !report.targetPostBody.isEmpty { Text(report.targetPostBody) }
                }
                Section("Мера") {
                    Picker("Мера", selection: $action) {
                        ForEach(AloModerationAction.available(for: report.targetType)) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    TextField("Комментарий для журнала", text: $note, axis: .vertical).lineLimit(2...4)
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(AloTheme.destructive) } }
                Section {
                    Button(role: action.isDestructive ? .destructive : nil) { decide(approve: true) } label: {
                        Text("Подтвердить: \(action.title.lowercased())").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("alo.moderation.approve")
                    Button { decide(approve: false) } label: {
                        Text("Отклонить жалобу").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("alo.moderation.reject")
                }
                .disabled(isSaving)
            }
            .scrollContentBackground(.hidden)
            .background(AloTheme.background)
            .navigationTitle("Решение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func decide(approve: Bool) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await app.resolveModerationReport(report, approve: approve, action: action, note: note)
                AloHaptics.notification(.success)
                onDecided()
                dismiss()
            } catch {
                self.error = (error as? AloAPIError)?.message ?? "Не удалось сохранить решение."
            }
        }
    }
}

private struct AloAppealQueue: View {
    @EnvironmentObject private var app: AloAppModel
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
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        appeals = (try? await app.moderationAppeals()) ?? appeals
        isLoading = false
    }

    private func resolve(_ appeal: AloModerationAppeal, overturn: Bool) {
        Task {
            do {
                try await app.resolveModerationAppeal(appeal, overturn: overturn)
                withAnimation { appeals.removeAll { $0.id == appeal.id } }
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
                                if !entry.details.isEmpty {
                                    Text(entry.details).font(.system(size: 13)).foregroundStyle(AloTheme.text.opacity(0.85))
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
