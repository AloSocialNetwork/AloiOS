import SwiftUI
import Charts

// The reader's tools around a post (why it is shown, hide, "не интересно", report), drafts,
// a creator's statistics and "@" suggestions.

// MARK: - Why this post

/// Instagram's "Почему вы видите эту публикацию": the reasons the feed gave this post a place,
/// with the two ways to see less of it.
struct AloWhyShownSheet: View {
    @Environment(\.dismiss) private var dismiss
    let post: AloPost
    let onHide: (AloFeedHideReason) -> Void

    private var reason: AloFeedReason { post.feedReason ?? .popular }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ZStack(alignment: .bottomTrailing) {
                        AloAvatar(name: post.author.name, url: post.author.avatarUrl, size: 64, colorSeed: String(post.author.id))
                        Image(systemName: "info")
                            .font(.system(size: 13, weight: .black)).foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(AloTheme.accent, in: Circle())
                            .overlay(Circle().stroke(AloTheme.background, lineWidth: 2.5))
                    }
                    .padding(.top, 6)
                    .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text("Почему вы видите эту публикацию")
                            .font(.system(size: 20, weight: .bold)).foregroundStyle(AloTheme.text)
                            .multilineTextAlignment(.center)
                        Text("Лента складывается из ваших подписок и того, что сейчас популярно в Alo.")
                            .font(.system(size: 14)).foregroundStyle(AloTheme.muted).multilineTextAlignment(.center)
                    }
                    group(rows)
                    if reason != .own && reason != .ownChannel {
                        group([
                            action("Не интересно", detail: "Скроем публикацию и реже будем рекомендовать \(handle)",
                                   symbol: "hand.thumbsdown", id: "not-interested") { finish(.notInterested) },
                            action("Скрыть публикацию", detail: "Только эту, автор останется в ленте",
                                   symbol: "eye.slash", id: "hide") { finish(.hide) }
                        ])
                    }
                }
                .padding(16)
            }
            .background(AloTheme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.fraction(0.86), .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("alo.post.why-sheet")
    }

    /// "@alex" when there is a handle (a name would need declining after "на"), otherwise the name.
    private var handle: String {
        post.author.username.isEmpty ? post.author.name : post.author.username.withAtPrefix
    }

    private var rows: [AnyView] {
        let name = post.author.name
        let handle = handle
        var items: [AnyView] = []
        switch reason {
        case .own:
            items.append(row("Это ваша публикация", detail: "Свои публикации вы видите первыми.", symbol: "person.crop.circle"))
        case .ownChannel:
            items.append(row("Это ваш канал «\(name)»", detail: "Публикации ваших каналов стоят в ленте выше остальных.", symbol: "megaphone"))
        case .subscribedChannel:
            items.append(row("Вы подписаны на канал «\(name)»", detail: "Каналы из подписок идут выше рекомендаций.", symbol: "bell"))
        case .friend:
            items.append(row("Вы подписаны на \(handle)", detail: "Люди из ваших подписок идут выше рекомендаций.", symbol: "person.2"))
        case .popular:
            items.append(row("Популярно в Alo", detail: popularity, symbol: "flame"))
            items.append(row("Вы не подписаны на \(handle)", detail: "Это рекомендация. Подпишитесь, чтобы видеть публикации чаще.", symbol: "person.badge.plus"))
        }
        items.append(row(AloFeedCurationText.published(post.createdAt), detail: "Среди похожих свежие публикации стоят выше.", symbol: "clock"))
        return items
    }

    private var popularity: String {
        [AloFeedCurationText.count(post.viewCount, "просмотр", "просмотра", "просмотров"),
         AloFeedCurationText.count(post.likeCount, "отметка «Нравится»", "отметки «Нравится»", "отметок «Нравится»"),
         AloFeedCurationText.count(post.commentCount, "комментарий", "комментария", "комментариев")]
            .joined(separator: " · ")
    }

    private func finish(_ reason: AloFeedHideReason) {
        dismiss()
        onHide(reason)
    }

    private func group(_ items: [AnyView]) -> some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                items[index]
                if index < items.count - 1 { Divider().overlay(AloTheme.border).padding(.leading, 60) }
            }
        }
        .background(AloTheme.surfaceRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func row(_ title: String, detail: String, symbol: String) -> AnyView {
        AnyView(HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium)).foregroundStyle(AloTheme.text)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                Text(detail).font(.system(size: 14)).foregroundStyle(AloTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine))
    }

    private func action(_ title: String, detail: String, symbol: String, id: String, perform: @escaping () -> Void) -> AnyView {
        AnyView(Button(action: perform) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(AloTheme.accent)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.accent)
                    Text(detail).font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("alo.post.why.\(id)"))
    }
}

enum AloFeedCurationText {
    /// "1 просмотр", "3 просмотра", "12 просмотров".
    static func count(_ value: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = value % 10, mod100 = value % 100
        let word = mod10 == 1 && mod100 != 11 ? one
            : (2...4).contains(mod10) && !(12...14).contains(mod100) ? few : many
        return "\(AloCompactCount.string(value)) \(word)"
    }

    /// "Опубликовано 28 мин назад", "… только что" or "… 12 сент.".
    @MainActor static func published(_ raw: String) -> String { "Опубликовано \(ago(raw))" }

    /// "только что", "28 мин назад", "2 д назад" or a date.
    @MainActor static func ago(_ raw: String) -> String {
        let value = AloPostTimestamp.string(raw)
        if value == "сейчас" { return "только что" }
        let relative = value.hasSuffix(" мин") || value.hasSuffix(" ч") || value.hasSuffix(" д")
        return relative ? "\(value) назад" : value
    }
}

// MARK: - A hidden post's place in the feed

/// What stays where a hidden post was until the next refresh, with "Вернуть".
struct AloHiddenPostRow: View {
    let reason: AloFeedHideReason
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: reason == .report ? "checkmark.shield" : "eye.slash")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.muted)
                .frame(width: 40, height: 40)
                .background(AloTheme.surfaceRaised, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(reason.notice).font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.text)
                Text(reason == .notInterested ? "Публикация скрыта из ленты." : "Её больше не будет в вашей ленте.")
                    .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
            }
            Spacer(minLength: 8)
            Button("Вернуть", action: onUndo)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("alo.post.hidden.undo")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(AloTheme.feedDivider).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.post.hidden")
    }
}

// MARK: - Report

/// Telegram's report flow: a reason, an optional note, then a thank-you.
struct AloReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let target: AloReportTarget
    let onSend: (AloReportReason, String) async throws -> Void
    @State private var chosen: AloReportReason?
    @State private var details = ""
    @State private var isSending = false
    @State private var error = ""
    @State private var isSent = false
    @FocusState private var detailsFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if isSent { sent } else { reasons }
            }
            .background(AloTheme.background)
            .navigationTitle(isSent ? "" : target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !isSent { Button("Отмена") { dismiss() } }
                }
            }
            .navigationDestination(item: $chosen) { reason in detailsPage(reason) }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("alo.report.sheet")
    }

    private var reasons: some View {
        List {
            Section {
                ForEach(AloReportReason.allCases) { reason in
                    Button { chosen = reason } label: {
                        HStack(spacing: 14) {
                            Image(systemName: reason.symbol)
                                .font(.system(size: 16, weight: .medium)).foregroundStyle(AloTheme.text)
                                .frame(width: 28)
                            Text(reason.title).font(.system(size: 16)).foregroundStyle(AloTheme.text)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(AloTheme.muted.opacity(0.7))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(AloTheme.surfaceRaised.opacity(0.7))
                    .accessibilityIdentifier("alo.report.reason.\(reason.rawValue)")
                }
            } header: {
                Text("Что не так?").textCase(nil)
            } footer: {
                Text("Жалоба анонимна: автор не узнает, кто её отправил.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func detailsPage(_ reason: AloReportReason) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(reason.title, systemImage: reason.symbol)
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(AloTheme.text)
                TextField(reason == .other ? "Опишите, что не так" : "Подробности (необязательно)", text: $details, axis: .vertical)
                    .lineLimit(4...8)
                    .focused($detailsFocused)
                    .padding(14)
                    .background(AloTheme.surfaceRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(AloTheme.text)
                    .accessibilityIdentifier("alo.report.details")
                if !error.isEmpty {
                    Text(error).font(.system(size: 14)).foregroundStyle(AloTheme.destructive)
                }
                AloPrimaryButton(title: isSending ? "Отправка…" : "Отправить жалобу",
                                 disabled: isSending || (reason == .other && details.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)) {
                    send(reason)
                }
                .accessibilityIdentifier("alo.report.send")
            }
            .padding(16)
        }
        .background(AloTheme.background)
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if reason == .other { detailsFocused = true } }
    }

    private var sent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 58, weight: .semibold)).foregroundStyle(AloTheme.success)
                .symbolEffect(.bounce, value: isSent)
            Text("Спасибо! Жалоба отправлена").font(.system(size: 21, weight: .bold)).foregroundStyle(AloTheme.text)
            Text(target.type == "user"
                 ? "Модераторы проверят профиль и примут меры, если найдут нарушение."
                 : "Модераторы проверят её и примут меры, если найдут нарушение. Мы скрыли это из вашей ленты.")
                .font(.system(size: 15)).foregroundStyle(AloTheme.muted).multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            AloPrimaryButton(title: "Готово") { dismiss() }
                .padding(.horizontal, 16).padding(.bottom, 12)
                .accessibilityIdentifier("alo.report.done")
        }
    }

    private func send(_ reason: AloReportReason) {
        isSending = true
        error = ""
        detailsFocused = false
        Task {
            defer { isSending = false }
            do {
                try await onSend(reason, details.trimmingCharacters(in: .whitespacesAndNewlines))
                chosen = nil
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isSent = true }
                AloHaptics.notification(.success)
            } catch let failure as AloAPIError {
                error = failure.message
            } catch {
                self.error = "Не удалось отправить жалобу. Проверьте подключение."
            }
        }
    }
}

// MARK: - Drafts

/// Saved drafts of posts, newest first. A tap opens one in the editor; a swipe deletes it.
struct AloPostDraftsSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.aloAPIClient) private var api
    @Environment(\.dismiss) private var dismiss
    let onPick: (AloPostDraft) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if app.postDrafts.isEmpty {
                    ContentUnavailableView("Черновиков нет", systemImage: "doc.text",
                                           description: Text("Закройте незаконченный пост и выберите «Сохранить черновик»."))
                        .foregroundStyle(AloTheme.muted)
                } else {
                    List {
                        ForEach(app.postDrafts) { draft in
                            Button {
                                dismiss()
                                onPick(draft)
                            } label: { row(draft) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .accessibilityIdentifier("alo.post.draft.\(draft.id)")
                            .swipeActions {
                                Button(role: .destructive) { app.deletePostDraft(draft) } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AloTheme.background)
            .navigationTitle("Черновики")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() }.fontWeight(.semibold) }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await app.loadPostDrafts() }
        .accessibilityIdentifier("alo.post.drafts")
    }

    private func row(_ draft: AloPostDraft) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.body.isEmpty ? "Без текста" : draft.body)
                    .font(.system(size: 15)).foregroundStyle(draft.body.isEmpty ? AloTheme.muted : AloTheme.text)
                    .lineLimit(3)
                Text([draft.media.isEmpty ? "" : AloFeedCurationText.count(draft.media.count, "вложение", "вложения", "вложений"),
                      "изменён \(AloFeedCurationText.ago(draft.updatedAt))"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(AloTheme.muted)
            }
            Spacer(minLength: 0)
            if let media = draft.media.first,
               let url = api?.absoluteURL(media.type == "video" ? media.posterUrl.ifBlank(media.url) : media.url) {
                AloTheme.surfaceRaised
                    .overlay {
                        AloAsyncImage(url: url) { phase in
                            if case .success(let image) = phase { image.resizable().scaledToFill() } else { Color.clear }
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// A draft's already uploaded picture in the post editor.
struct AloDraftMediaThumbnail: View {
    @Environment(\.aloAPIClient) private var api
    let media: AloMediaItem
    let side: CGFloat
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AloTheme.surfaceRaised
                .overlay {
                    if let url = api?.absoluteURL(media.type == "video" ? media.posterUrl.ifBlank(media.url) : media.url) {
                        AloAsyncImage(url: url) { phase in
                            if case .success(let image) = phase { image.resizable().scaledToFill() } else { Color.clear }
                        }
                    }
                }
                .overlay {
                    if media.type == "video" {
                        Image(systemName: "play.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(.black.opacity(0.45), in: Circle())
                    }
                }
                .frame(width: side * 0.75, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(.black.opacity(0.6), in: Circle())
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityLabel("Удалить вложение")
        }
    }
}

// MARK: - "@" suggestions

/// People to name after "@": the ones you follow first. Shown above the field being typed in.
struct AloMentionSuggestions: View {
    @EnvironmentObject private var app: AloAppModel
    let query: String
    let onPick: (AloEntitySummary) -> Void
    @State private var people: [AloEntitySummary] = []

    var body: some View {
        // Never empty: a view with no content does not run its `.task`.
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if !people.isEmpty {
                VStack(spacing: 0) {
                    ForEach(people.prefix(5)) { person in
                        Button { onPick(person) } label: {
                            HStack(spacing: 10) {
                                AloAvatar(name: person.name, url: person.avatarUrl, size: 32, colorSeed: String(person.id))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(person.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.text)
                                        .lineLimit(1)
                                    Text(person.username.withAtPrefix).font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).frame(minHeight: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("alo.mention.\(person.username)")
                    }
                }
                .padding(.vertical, 4)
                .modifier(AloChatPanelGlass(radius: 18, role: .panel))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: people.map(\.id))
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            people = (try? await app.mentionSuggestions(query)) ?? []
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.mention.suggestions")
    }
}

// MARK: - Creator statistics

/// Telegram's channel statistics, for your own posts: an overview against the previous period,
/// views and interactions by day, and the posts that did best.
struct AloCreatorStatsScreen: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var days = 30
    @State private var stats: AloCreatorStats?
    @State private var error = ""
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Период", selection: $days) {
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("alo.stats.period")

                if let stats {
                    overview(stats)
                    viewsChart(stats)
                    interactionsChart(stats)
                    allTime(stats)
                    topPosts(stats)
                } else if !error.isEmpty {
                    ContentUnavailableView("Статистика недоступна", systemImage: "chart.xyaxis.line", description: Text(error))
                        .foregroundStyle(AloTheme.muted)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                }
            }
            .padding(16)
            .opacity(isLoading && stats != nil ? 0.6 : 1)
        }
        .background(AloTheme.background.ignoresSafeArea())
        .navigationTitle("Статистика")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: days) { await load() }
        .accessibilityIdentifier("alo.stats.screen")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await app.creatorStats(days: days)
            withAnimation(.easeOut(duration: 0.25)) { stats = value }
            error = ""
        } catch let failure as AloAPIError {
            error = failure.message
        } catch {
            self.error = "Проверьте подключение и попробуйте ещё раз."
        }
    }

    private func overview(_ stats: AloCreatorStats) -> some View {
        section("Обзор") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                tile("Просмотры", stats.views)
                tile("Отметки «Нравится»", stats.likes)
                tile("Комментарии", stats.comments)
                tile("Репосты", stats.reposts)
                tile("Новые подписчики", stats.followers)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "%.1f%%", stats.engagementRate))
                        .font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(AloTheme.text)
                    Text("Вовлечённость").font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("alo.stats.overview")
    }

    private func tile(_ title: String, _ metric: AloCreatorStats.Metric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(AloCompactCount.string(metric.current))
                    .font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(AloTheme.text)
                    .contentTransition(.numericText())
                if let change = metric.change, metric.current != metric.previous {
                    Text(String(format: "%@%.0f%%", change >= 0 ? "+" : "−", abs(change)))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(change >= 0 ? AloTheme.success : AloTheme.destructive)
                }
            }
            Text(title).font(.system(size: 13)).foregroundStyle(AloTheme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func viewsChart(_ stats: AloCreatorStats) -> some View {
        section("Просмотры") {
            Chart(stats.daily) { day in
                AreaMark(x: .value("День", day.day, unit: .day), y: .value("Просмотры", day.views))
                    .foregroundStyle(LinearGradient(colors: [AloTheme.accent.opacity(0.35), AloTheme.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("День", day.day, unit: .day), y: .value("Просмотры", day.views))
                    .foregroundStyle(AloTheme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine().foregroundStyle(AloTheme.border); AxisValueLabel() } }
            .frame(height: 170)
            .environment(\.locale, Locale(identifier: "ru_RU"))
        }
        .accessibilityIdentifier("alo.stats.views-chart")
    }

    private func interactionsChart(_ stats: AloCreatorStats) -> some View {
        section("Реакции") {
            Chart {
                ForEach(stats.daily) { day in
                    BarMark(x: .value("День", day.day, unit: .day), y: .value("Количество", day.likes))
                        .foregroundStyle(by: .value("Тип", "Нравится"))
                    BarMark(x: .value("День", day.day, unit: .day), y: .value("Количество", day.comments))
                        .foregroundStyle(by: .value("Тип", "Комментарии"))
                }
            }
            .chartForegroundStyleScale(["Нравится": Color(red: 1, green: 0.2, blue: 0.38), "Комментарии": AloTheme.accent])
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine().foregroundStyle(AloTheme.border); AxisValueLabel() } }
            .frame(height: 150)
            .environment(\.locale, Locale(identifier: "ru_RU"))
        }
    }

    private func allTime(_ stats: AloCreatorStats) -> some View {
        section("За всё время") {
            HStack(spacing: 0) {
                total(stats.allTime.posts, "публикаций")
                total(stats.allTime.followers, "подписчиков")
                total(stats.allTime.views, "просмотров")
                total(stats.allTime.likes, "«Нравится»")
            }
        }
    }

    private func total(_ value: Int, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(AloCompactCount.string(value)).font(.system(size: 18, weight: .bold).monospacedDigit()).foregroundStyle(AloTheme.text)
            Text(title).font(.system(size: 12)).foregroundStyle(AloTheme.muted).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func topPosts(_ stats: AloCreatorStats) -> some View {
        if !stats.topPosts.isEmpty {
            section("Лучшие публикации") {
                VStack(spacing: 0) {
                    ForEach(stats.topPosts) { post in
                        Button { app.openComments(for: post) } label: { topRow(post) }
                            .buttonStyle(.plain)
                        if post.id != stats.topPosts.last?.id { Divider().overlay(AloTheme.border) }
                    }
                }
            }
        }
    }

    private func topRow(_ post: AloPost) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(post.body.isEmpty ? (post.media.isEmpty ? "Публикация" : "Фото или видео") : post.body)
                    .font(.system(size: 15)).foregroundStyle(AloTheme.text).lineLimit(2)
                HStack(spacing: 12) {
                    Label(AloCompactCount.string(post.viewCount), systemImage: "eye")
                    Label(AloCompactCount.string(post.likeCount), systemImage: "heart")
                    Label(AloCompactCount.string(post.commentCount), systemImage: "bubble.left")
                    Text(AloPostTimestamp.string(post.createdAt))
                }
                .font(.system(size: 12)).foregroundStyle(AloTheme.muted).labelStyle(AloCompactLabelStyle())
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AloTheme.muted.opacity(0.6))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AloTheme.muted).textCase(.uppercase)
            content()
        }
        .padding(16)
        .background(AloTheme.surfaceRaised.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct AloCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}

// MARK: - Channel statistics

/// Telegram's channel statistics: overview, follower growth, views of publications and the
/// latest posts with their reach.
struct AloChannelStatsScreen: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let channel: AloChannelProfile
    @State private var days = 30
    @State private var stats: AloChannelStats?
    @State private var error = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Период", selection: $days) {
                        Text("7 дней").tag(7)
                        Text("30 дней").tag(30)
                        Text("90 дней").tag(90)
                    }
                    .pickerStyle(.segmented)
                    if let stats {
                        overview(stats)
                        growthChart(stats)
                        viewsChart(stats)
                        recent(stats)
                    } else if !error.isEmpty {
                        ContentUnavailableView("Статистика недоступна", systemImage: "chart.xyaxis.line", description: Text(error))
                            .foregroundStyle(AloTheme.muted)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                }
                .padding(16)
            }
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Статистика")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() }.fontWeight(.semibold) }
            }
            .task(id: days) {
                do {
                    let value = try await app.channelStats(channelId: channel.id, days: days)
                    withAnimation(.easeOut(duration: 0.25)) { stats = value }
                    error = ""
                } catch {
                    self.error = (error as? AloAPIError)?.message ?? "Проверьте подключение и попробуйте ещё раз."
                }
            }
        }
        .accessibilityIdentifier("alo.channel.stats")
    }

    private func overview(_ stats: AloChannelStats) -> some View {
        AloStatsSection(title: "Обзор") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                AloStatsTile(value: AloCompactCount.string(stats.subscribers), title: "Подписчики",
                             change: stats.joinedInPeriod > 0 ? "+\(AloCompactCount.string(stats.joinedInPeriod))" : nil)
                AloStatsTile(value: AloCompactCount.string(stats.viewsPerPost), title: "Просмотров на пост")
                AloStatsTile(value: AloCompactCount.string(stats.posts), title: "Публикаций")
                AloStatsTile(value: AloCompactCount.string(stats.views), title: "Просмотры")
                AloStatsTile(value: AloCompactCount.string(stats.likes), title: "Отметки «Нравится»")
                AloStatsTile(value: AloCompactCount.string(stats.reposts), title: "Репосты")
            }
        }
    }

    private func growthChart(_ stats: AloChannelStats) -> some View {
        AloStatsSection(title: "Новые подписчики") {
            Chart(stats.growthByDay()) { day in
                BarMark(x: .value("День", day.day, unit: .day), y: .value("Подписались", day.likes))
                    .foregroundStyle(AloTheme.success)
                    .cornerRadius(2)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine().foregroundStyle(AloTheme.border); AxisValueLabel() } }
            .frame(height: 150)
            .environment(\.locale, Locale(identifier: "ru_RU"))
        }
    }

    private func viewsChart(_ stats: AloChannelStats) -> some View {
        AloStatsSection(title: "Просмотры публикаций по дню выхода") {
            // Posts come out on separate days, so bars, not a curve between them.
            Chart(stats.growthByDay()) { day in
                BarMark(x: .value("День", day.day, unit: .day), y: .value("Просмотры", day.views))
                    .foregroundStyle(AloTheme.accent)
                    .cornerRadius(2)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine().foregroundStyle(AloTheme.border); AxisValueLabel() } }
            .frame(height: 150)
            .environment(\.locale, Locale(identifier: "ru_RU"))
        }
    }

    @ViewBuilder
    private func recent(_ stats: AloChannelStats) -> some View {
        if !stats.publications.isEmpty {
            AloStatsSection(title: "Последние публикации") {
                VStack(spacing: 0) {
                    ForEach(stats.publications.prefix(10)) { publication in
                        let post = channel.posts.first { $0.id == publication.postId }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(post.map { $0.body.isEmpty ? "Фото или видео" : $0.body } ?? "Публикация")
                                    .font(.system(size: 15)).foregroundStyle(AloTheme.text).lineLimit(2)
                                Text(AloPostTimestamp.string(publication.publishedAt))
                                    .font(.system(size: 12)).foregroundStyle(AloTheme.muted)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 3) {
                                Label(AloCompactCount.string(publication.views), systemImage: "eye")
                                Label(AloCompactCount.string(publication.reposts), systemImage: "arrow.2.squarepath")
                            }
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(AloTheme.muted)
                        }
                        .padding(.vertical, 9)
                        if publication.id != stats.publications.prefix(10).last?.id { Divider().overlay(AloTheme.border) }
                    }
                }
            }
        }
    }
}

struct AloStatsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AloTheme.muted).textCase(.uppercase)
            content()
        }
        .padding(16)
        .background(AloTheme.surfaceRaised.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct AloStatsTile: View {
    let value: String
    let title: String
    var change: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(AloTheme.text)
                if let change {
                    Text(change).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(AloTheme.success)
                }
            }
            Text(title).font(.system(size: 13)).foregroundStyle(AloTheme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
