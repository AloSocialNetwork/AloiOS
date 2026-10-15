import AVFoundation
import SwiftUI

/// Telegram's story viewer: full screen, a progress segment per frame, tap right/left to move,
/// hold to pause, swipe sideways to the next person, swipe down to close. Photos stay 5 s, videos
/// play to the end. Any story's link can be copied from "⋯". Your own show who has seen them
/// (Telegram's viewers list) and can be deleted; someone else's offer "Ответить", which opens the
/// chat with them.
struct AloStoryViewer: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let groups: [AloStoryGroup]
    /// Set when playing a highlight: the title shows, and its owner can take a story out.
    let highlight: AloStoryHighlight?
    @State private var groupIndex: Int
    @State private var frameIndex = 0
    @State private var progress: Double = 0
    @State private var isHolding = false
    @State private var isDeleteConfirmationPresented = false
    @State private var dragOffset: CGSize = .zero
    @State private var videoDuration: Double = 0
    @State private var isViewersPresented = false
    @State private var isActionsPresented = false
    @State private var isAddToHighlightPresented = false
    @State private var toast: String?
    @State private var toastSymbol = "link"

    private static let photoDuration: Double = 5

    init(groups: [AloStoryGroup], startGroupID: Int, highlight: AloStoryHighlight? = nil) {
        self.groups = groups
        self.highlight = highlight
        _groupIndex = State(initialValue: groups.firstIndex(where: { $0.id == startGroupID }) ?? 0)
    }

    /// A story with several media shows each as its own frame; a story without media is one frame.
    private struct Frame: Equatable {
        let story: AloStory
        let media: AloMediaItem?
    }

    private var group: AloStoryGroup? { groups.indices.contains(groupIndex) ? groups[groupIndex] : nil }

    private var frames: [Frame] {
        (group?.stories ?? []).flatMap { story in
            story.media.isEmpty ? [Frame(story: story, media: nil)] : story.media.map { Frame(story: story, media: $0) }
        }
    }

    private var frame: Frame? { frames.indices.contains(frameIndex) ? frames[frameIndex] : nil }
    private var isOwn: Bool { group?.user.id == app.bootstrap?.me.id }
    private var isPaused: Bool {
        isHolding || isDeleteConfirmationPresented || isViewersPresented || isActionsPresented || isAddToHighlightPresented
            || dragOffset != .zero
    }

    var body: some View {
        GeometryReader { proxy in
            page(width: proxy.size.width, height: min(proxy.size.height - 70, proxy.size.width * 16 / 9))
        }
        .background(Color.black.opacity(backdropOpacity).ignoresSafeArea())
        .presentationBackground(.clear)
        .statusBarHidden()
        .task(id: tickKey) { await tick() }
        .onChange(of: frameIndex) { _, _ in markViewed() }
        .onChange(of: groupIndex) { _, _ in markViewed() }
        .onAppear { markViewed() }
        .confirmationDialog("Удалить историю?", isPresented: $isDeleteConfirmationPresented, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { deleteCurrent() }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(isPresented: $isAddToHighlightPresented) {
            if let frame {
                AloAddToHighlightSheet(stories: [frame.story]) {
                    isAddToHighlightPresented = false
                    showToast("Добавлено в актуальное", symbol: "star.fill")
                }
                .environmentObject(app)
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $isViewersPresented) {
            if let frame {
                AloStoryViewersSheet(story: frame.story) { user in
                    isViewersPresented = false
                    dismiss()
                    app.activeTab = .profile
                    app.openProfile(userId: user.id)
                }
                .environmentObject(app)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: toastSymbol)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 44)
                    .modifier(AloChatGlass(interactive: false, role: .chrome))
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("alo.story.viewer.toast")
            }
        }
        .accessibilityAction(named: "Следующая") { next() }
        .accessibilityAction(named: "Предыдущая") { previous() }
    }

    private var backdropOpacity: Double { 1 - min(0.6, Double(max(0, dragOffset.height)) / 500) }
    private var tickKey: String { "\(groupIndex)-\(frameIndex)-\(isPaused)" }
    private var dragScale: CGFloat { 1 - min(0.12, max(0, dragOffset.height) / 2_000) }

    private func page(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            card(width: width, height: height)
            bottomBar.frame(height: 62)
            Spacer(minLength: 0)
        }
        .offset(x: dragOffset.width, y: max(0, dragOffset.height))
        .scaleEffect(dragScale)
        .simultaneousGesture(swipe(width: width))
    }

    private func card(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            content
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            tapZones(width: width)
            chrome
        }
        .frame(width: width, height: height)
    }

    /// A third on the left goes back, the rest goes forward; a finger on the story holds it.
    private func tapZones(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle()).frame(width: width / 3)
                .onTapGesture { previous() }
            Color.clear.contentShape(Rectangle())
                .onTapGesture { next() }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !isHolding { isHolding = true } }
            .onEnded { _ in isHolding = false })
        .accessibilityHidden(true)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let frame {
            ZStack {
                Color.black
                if let media = frame.media, let url = app.api.absoluteURL(media.type == "video" ? media.url : media.posterUrl.ifBlank(media.url)) {
                    if media.type == "video" {
                        AloStoryVideo(url: url, isPaused: isPaused, onProgress: { current, duration in
                            videoDuration = duration
                            if duration > 0 { progress = min(1, current / duration) }
                        }, onEnd: next)
                        .id(url)
                    } else {
                        AloAsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            case .failure: Image(systemName: "photo").font(.system(size: 34)).foregroundStyle(.white.opacity(0.5))
                            default: ProgressView().tint(.white)
                            }
                        }
                    }
                } else {
                    LinearGradient(colors: [AloTheme.accent, Color(red: 0.42, green: 0.27, blue: 0.93)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                if !frame.story.body.isEmpty {
                    let isTextStory = frame.media == nil
                    VStack {
                        if !isTextStory { Spacer() }
                        Text(frame.story.body)
                            .font(.system(size: isTextStory ? 28 : 17, weight: isTextStory ? .bold : .regular))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(isTextStory ? .center : .leading)
                            .frame(maxWidth: .infinity, alignment: isTextStory ? .center : .leading)
                            .padding(.horizontal, isTextStory ? 28 : 16)
                            .padding(.vertical, isTextStory ? 0 : 14)
                            .background {
                                if !isTextStory {
                                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                                }
                            }
                    }
                    .accessibilityIdentifier("alo.story.viewer.text")
                }
            }
        } else {
            Color.black
        }
    }

    private var chrome: some View {
        VStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(frames.indices, id: \.self) { index in
                    GeometryReader { bar in
                        Capsule().fill(.white.opacity(0.35))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white)
                                    .frame(width: bar.size.width * (index < frameIndex ? 1 : index == frameIndex ? progress : 0))
                            }
                    }
                    .frame(height: 2.5)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("История \(frameIndex + 1) из \(frames.count)")
            .accessibilityIdentifier("alo.story.viewer.progress")
            HStack(spacing: 10) {
                if let group {
                    AloAvatar(name: group.user.name, url: group.user.avatarUrl, size: 34, colorSeed: String(group.user.id))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(highlight?.title.ifBlank(isOwn ? "Ваша история" : group.user.name) ?? (isOwn ? "Ваша история" : group.user.name))
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        if let frame {
                            Text(Self.age(of: frame.story.createdAt))
                                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                Spacer(minLength: 0)
                // The story holds still while its actions are open, as in Telegram.
                Button { isActionsPresented = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .confirmationDialog("История", isPresented: $isActionsPresented, titleVisibility: .hidden) {
                    if frame?.story.isExpired != true {
                        Button("Копировать ссылку") { copyLink() }
                    }
                    if isOwn {
                        if let highlight {
                            Button("Убрать из актуального", role: .destructive) { removeFromHighlight(highlight) }
                        } else {
                            Button("Добавить в актуальное") { isAddToHighlightPresented = true }
                        }
                        if highlight == nil {
                            Button("Удалить историю", role: .destructive) { isDeleteConfirmationPresented = true }
                        }
                    }
                    Button("Отмена", role: .cancel) {}
                }
                .accessibilityLabel("Ещё")
                .accessibilityIdentifier("alo.story.viewer.more")
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel("Закрыть историю")
                .accessibilityIdentifier("alo.story.viewer.close")
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 10) {
            if isOwn {
                if let frame {
                    // Telegram's viewers button: the count opens who has seen the story.
                    Button { isViewersPresented = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "eye")
                            Text("\(frame.story.viewCount) \(Self.viewsWord(frame.story.viewCount))")
                        }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 40)
                        .modifier(AloChatGlass(interactive: false, role: .chrome))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(AloControlPressStyle())
                    .accessibilityLabel("\(frame.story.viewCount) \(Self.viewsWord(frame.story.viewCount)). Показать, кто посмотрел")
                    .accessibilityIdentifier("alo.story.viewer.views")
                }
                Spacer()
            } else if let group {
                Button { reply(to: group.user) } label: {
                    HStack {
                        Text("Ответить…")
                            .font(.system(size: 16)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        Spacer()
                        Image(systemName: "paperplane").foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16).frame(height: 44)
                    .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(AloControlPressStyle())
                .accessibilityIdentifier("alo.story.viewer.reply")
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: Behaviour

    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                if abs(value.translation.height) > abs(value.translation.width) {
                    dragOffset = CGSize(width: 0, height: value.translation.height)
                } else {
                    dragOffset = CGSize(width: value.translation.width * 0.6, height: 0)
                }
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                if !horizontal, value.translation.height > 120 || value.predictedEndTranslation.height > 400 {
                    dismiss()
                    return
                }
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                    if horizontal, value.translation.width < -width / 4 {
                        nextGroup()
                    } else if horizontal, value.translation.width > width / 4 {
                        previousGroup()
                    }
                    dragOffset = .zero
                }
            }
    }

    /// Photos and text advance on a timer; videos report their own progress.
    private func tick() async {
        guard !isPaused, let frame else { return }
        if frame.media?.type == "video" { return }
        let step = 0.05
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int(step * 1_000)))
            guard !Task.isCancelled else { return }
            progress += step / Self.photoDuration
            if progress >= 1 {
                next()
                return
            }
        }
    }

    private func next() {
        if frameIndex + 1 < frames.count {
            frameIndex += 1
            progress = 0
        } else {
            nextGroup()
        }
    }

    private func previous() {
        if frameIndex > 0 {
            frameIndex -= 1
        } else if groupIndex > 0 {
            groupIndex -= 1
            frameIndex = 0
        }
        progress = 0
    }

    private func nextGroup() {
        guard groupIndex + 1 < groups.count else { dismiss(); return }
        groupIndex += 1
        frameIndex = 0
        progress = 0
    }

    private func previousGroup() {
        guard groupIndex > 0 else { return }
        groupIndex -= 1
        frameIndex = 0
        progress = 0
    }

    private func markViewed() {
        guard let frame, !isOwn else { return }
        app.markStoryViewed(frame.story)
    }

    private func copyLink() {
        guard let frame else { return }
        Task {
            guard await app.copyStoryLink(frame.story) else { return }
            AloHaptics.notification(.success)
            showToast("Ссылка скопирована", symbol: "link")
        }
    }

    private func showToast(_ text: String, symbol: String) {
        toastSymbol = symbol
        Task {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) { toast = text }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { toast = nil }
        }
    }

    private func removeFromHighlight(_ highlight: AloStoryHighlight) {
        guard let frame else { return }
        Task {
            try? await app.removeFromHighlight(highlight, story: frame.story)
            dismiss()
        }
    }

    private func deleteCurrent() {
        guard let frame else { return }
        Task {
            do {
                try await app.api.deleteStory(storyId: frame.story.id)
                await app.refreshStories(silently: true)
                dismiss()
            } catch {
                app.errorMessage = "Не удалось удалить историю."
            }
        }
    }

    private func reply(to user: AloEntitySummary) {
        if let conversation = app.bootstrap?.conversations.first(where: { $0.kind == "direct" && $0.peer.id == user.id }) {
            dismiss()
            app.activeTab = .messages
            app.openConversation(conversation)
            return
        }
        Task {
            guard let profile = try? await app.api.loadUserProfile(userId: user.id) else { return }
            dismiss()
            app.openConversation(with: profile)
        }
    }

    static func age(of iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func viewsWord(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "просмотр" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "просмотра" }
        return "просмотров"
    }
}

/// A story video: fills the frame, plays once, reports progress and its end; pauses with the viewer.
private struct AloStoryVideo: View {
    let url: URL
    let isPaused: Bool
    let onProgress: (Double, Double) -> Void
    let onEnd: () -> Void
    @State private var player = AVPlayer()
    @State private var observer: Any?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        AloPlayerLayerView(player: player) { layer in layer.videoGravity = .resizeAspectFill }
            .onAppear {
                let item = AVPlayerItem(url: url)
                player.replaceCurrentItem(with: item)
                observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
                    let duration = item.duration.seconds
                    onProgress(time.seconds, duration.isFinite ? duration : 0)
                }
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                    onEnd()
                }
                if !isPaused { player.play() }
            }
            .onChange(of: isPaused) { _, paused in paused ? player.pause() : player.play() }
            .onDisappear {
                player.pause()
                if let observer { player.removeTimeObserver(observer) }
                if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            }
    }
}

/// Telegram's story viewers list: who opened the story and when, newest first, with search and a
/// sort menu. A row opens that person's profile.
struct AloStoryViewersSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let story: AloStory
    let onOpenProfile: (AloEntitySummary) -> Void
    @State private var viewers: [AloStoryViewerEntry] = []
    @State private var isLoading = true
    @State private var failed = false
    @State private var query = ""
    @State private var byName = false

    private var shown: [AloStoryViewerEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let found = needle.isEmpty ? viewers : viewers.filter {
            $0.user.name.lowercased().contains(needle) || $0.user.username.lowercased().contains(needle)
        }
        return byName ? found.sorted { $0.user.name.localizedCompare($1.user.name) == .orderedAscending } : found
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if failed {
                    ContentUnavailableView("Не удалось загрузить", systemImage: "wifi.exclamationmark",
                                           description: Text("Проверьте соединение и откройте список ещё раз."))
                } else if viewers.isEmpty {
                    ContentUnavailableView("Пока никто не посмотрел", systemImage: "eye",
                                           description: Text("Здесь появятся те, кто откроет историю."))
                } else {
                    List(shown) { entry in
                        Button { onOpenProfile(entry.user) } label: { row(entry) }
                            .listRowBackground(Color.clear)
                            .accessibilityIdentifier("alo.story.viewers.row")
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск")
                    .overlay {
                        if shown.isEmpty { ContentUnavailableView.search(text: query) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                        .accessibilityIdentifier("alo.story.viewers.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Порядок", selection: $byName) {
                            Label("Сначала новые", systemImage: "clock").tag(false)
                            Label("По имени", systemImage: "textformat").tag(true)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Порядок")
                    .accessibilityIdentifier("alo.story.viewers.sort")
                }
            }
            .background(AloTheme.background)
        }
        .task { await load() }
        .accessibilityIdentifier("alo.story.viewers")
    }

    private var title: String {
        let count = isLoading ? story.viewCount : viewers.count
        return "\(count) \(AloStoryViewer.viewsWord(count))"
    }

    private func row(_ entry: AloStoryViewerEntry) -> some View {
        HStack(spacing: 12) {
            AloAvatar(name: entry.user.name, url: entry.user.avatarUrl, size: 44, colorSeed: String(entry.user.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.user.name)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text).lineLimit(1)
                Text(Self.viewedText(entry.viewedAt))
                    .font(.system(size: 14)).foregroundStyle(AloTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func load() async {
        do {
            viewers = try await app.storyViewers(storyId: story.id)
            failed = false
        } catch {
            failed = true
        }
        isLoading = false
    }

    /// "только что", "5 мин назад", then the time, Telegram-style.
    static func viewedText(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "только что" }
        if minutes < 60 { return "\(minutes) мин назад" }
        let time = date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "ru_RU")))
        return Calendar.current.isDateInToday(date) ? "сегодня в \(time)" : "вчера в \(time)"
    }
}

/// A story link opened after the story has gone: who posted it and that it expired.
struct AloStoryExpiredSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let notice: AloExpiredStoryNotice

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                if let author = notice.author {
                    AloAvatar(name: author.name, url: author.avatarUrl, size: 76, colorSeed: String(author.id))
                        .overlay(Circle().stroke(AloTheme.border, style: StrokeStyle(lineWidth: 2, dash: [4, 4])).padding(-5))
                } else {
                    Circle().fill(AloTheme.surfaceRaised).frame(width: 76, height: 76)
                }
                Image(systemName: "clock.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(AloTheme.muted, in: Circle())
                    .overlay(Circle().stroke(AloTheme.background, lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
            .padding(.top, 8)
            Text("История истекла")
                .font(.system(size: 22, weight: .bold)).foregroundStyle(AloTheme.text)
            Text(notice.author.map { "\($0.name) публиковал(а) эту историю, но она уже исчезла. Истории живут до 48 часов." }
                 ?? "Эта история уже исчезла. Истории живут до 48 часов.")
                .font(.system(size: 15)).foregroundStyle(AloTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            VStack(spacing: 10) {
                if let author = notice.author {
                    AloPrimaryButton(title: "Открыть профиль") {
                        dismiss()
                        app.activeTab = .profile
                        app.openProfile(userId: author.id)
                    }
                }
                Button("Закрыть") { dismiss() }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("alo.story.expired.close")
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity)
        .background(AloTheme.background.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("alo.story.expired")
    }
}
