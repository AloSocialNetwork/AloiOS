import AVFoundation
import SwiftUI

/// Telegram's story viewer: full screen, a progress segment per frame, tap right/left to move,
/// hold to pause, swipe sideways to the next person, swipe down to close. Photos stay 5 s, videos
/// play to the end. Your own stories show their view count and can be deleted; someone else's
/// offer "Ответить", which opens the chat with them.
struct AloStoryViewer: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let groups: [AloStoryGroup]
    @State private var groupIndex: Int
    @State private var frameIndex = 0
    @State private var progress: Double = 0
    @State private var isHolding = false
    @State private var isDeleteConfirmationPresented = false
    @State private var dragOffset: CGSize = .zero
    @State private var videoDuration: Double = 0

    private static let photoDuration: Double = 5

    init(groups: [AloStoryGroup], startGroupID: Int) {
        self.groups = groups
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
    private var isPaused: Bool { isHolding || isDeleteConfirmationPresented || dragOffset != .zero }

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
                        Text(isOwn ? "Ваша история" : group.user.name)
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        if let frame {
                            Text(Self.age(of: frame.story.createdAt))
                                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                Spacer(minLength: 0)
                if isOwn {
                    Menu {
                        Button("Удалить историю", systemImage: "trash", role: .destructive) {
                            isDeleteConfirmationPresented = true
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Ещё")
                    .accessibilityIdentifier("alo.story.viewer.more")
                }
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
                    Label("\(frame.story.viewCount) \(Self.viewsWord(frame.story.viewCount))", systemImage: "eye")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.85))
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
