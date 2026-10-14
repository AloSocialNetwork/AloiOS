import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation
import ImageIO

/// One floating oval; the feed remains visible around it, with no rectangular shelf.
struct AloFeedModePicker: View {
    @Binding var selected: AloFeedMode

    init(selected: Binding<AloFeedMode>) { _selected = selected }

    var body: some View {
        AloSocialSegments(values: AloFeedMode.allCases, selected: $selected,
            title: { $0 == .popular ? "Для вас" : "Подписки" },
            identifier: { "alo.feed.tab.\($0 == .popular ? "popular" : "subscriptions")" })
            .padding(.horizontal, AloSocialMetrics.inset)
    }
}

struct FeedView: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var isComposerPresented = false
    @State private var isStoryComposerPresented = false
    @State private var selectedStoryGroup: AloStoryGroup?
    @State private var visibleNotice = ""
    @State private var noticeTask: Task<Void, Never>?
    @State private var settingsPresented = false
    private var visualAccessibility = AloVisualAccessibility()

    init() {}

    private func isMine(_ post: AloPost) -> Bool {
        guard let me = app.bootstrap?.me.id else { return false }
        return post.creatorId == me || post.author.id == me
    }

    private var posts: [AloPost] {
        guard let data = app.bootstrap else { return [] }
        return app.feedMode == .popular ? data.feedPopular : data.feedSubscriptions
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
                AloSocialScrollScreen(identifier: "alo.feed.scroll") {
                    VStack(spacing: AloSocialMetrics.headerControlSpacing) {
                        feedHeader
                        AloFeedModePicker(selected: $app.feedMode)
                    }
                } rows: {
                    LazyVStack(spacing: 0) {
                        storiesTray

                        ForEach(posts) { post in
                            AloTimelinePost(post: post,
                                            isMine: isMine(post),
                                            isLikePending: app.pendingLikePostIds.contains(post.id),
                                            isRepostPending: app.isRepostPending(post.id),
                                            onDelete: { app.deletePost(post) },
                                            onNotice: { app.notice = $0 }) {
                                app.toggleLike(post)
                            } onComment: {
                                app.openComments(for: post)
                            } onRepost: {
                                app.toggleRepost(post)
                            } onAuthor: {
                                app.openProfile(post.author)
                            }
                            .equatable()
                        }
                        if posts.isEmpty {
                            ContentUnavailableView(app.feedMode == .subscriptions ? "Пока нет публикаций" : "Лента пока пуста",
                                systemImage: "text.bubble", description: Text(app.feedMode == .subscriptions
                                    ? "Здесь появятся посты людей, на которых ты подписан." : "Создай первый пост кнопкой +."))
                                .foregroundStyle(AloTheme.muted).padding(.top, 28)
                        }
                    }
                }

            Button {
                isComposerPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(AloTheme.accent, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.24), radius: 8, y: 4)
            }
            .buttonStyle(AloFeedPressStyle())
            .contentShape(Circle())
            .accessibilityLabel("Создать пост")
            .accessibilityIdentifier("alo.feed.create-post")
            .padding(.trailing, 18)
            .padding(.bottom, 76)
        }
        .overlay(alignment: .bottom) {
            if !visibleNotice.isEmpty {
                Text(visibleNotice).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AloTheme.text).padding(.horizontal, 16).padding(.vertical, 12)
                    .modifier(AloChatGlass(interactive: false))
                    .padding(.horizontal, 24).padding(.bottom, 140)
                    .transition(.opacity).allowsHitTesting(false)
                    .accessibilityIdentifier("alo.feed.notice")
            }
        }
        .animation(visualAccessibility.reduceMotion ? nil : AloPressFeedback.release, value: visibleNotice)
        .onChange(of: app.notice) { _, value in
            guard !value.isEmpty else { return }
            noticeTask?.cancel()
            visibleNotice = value
            noticeTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                visibleNotice = ""
            }
        }
        .onDisappear { noticeTask?.cancel(); visibleNotice = "" }
        .refreshable { await app.loadBootstrap() }
        .task {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") { return }
            #endif
            await app.refreshStories(silently: true)
        }
        .fullScreenCover(isPresented: $isComposerPresented) {
            PostComposerSheet()
                .environmentObject(app)
        }
        .fullScreenCover(isPresented: $isStoryComposerPresented) {
            AloStoryEditorScreen()
                .environmentObject(app)
        }
        .sheet(item: $selectedStoryGroup) { group in
            StoryViewerSheet(group: group)
                .environmentObject(app)
        }
        .navigationDestination(isPresented: $settingsPresented) {
            AloSocialSettingsSheet().environmentObject(app)
        }
    }

    private var feedHeader: some View {
        HStack {
            Button { app.activeTab = .profile } label: {
                if let me = app.bootstrap?.me {
                    AloAvatar(name: me.name, url: me.avatarUrl, size: 34, colorSeed: String(me.id))
                        .frame(width: 44, height: 44)
                }
            }
            .buttonStyle(AloFeedPressStyle())
            .accessibilityLabel("Мой профиль")
            Spacer()
            AloSocialSettingsButton(label: "Настройки", identifier: "alo.feed.settings") {
                settingsPresented = true
            }
        }
        .overlay {
            if app.connectionState == .connected {
                AloSocialTitle(text: "ало", rounded: true)
                    .foregroundStyle(AloTheme.text).accessibilityLabel("Ало")
                    .allowsHitTesting(false)
            } else {
                Button(action: app.retryInitialBootstrap) {
                    HStack(spacing: 5) {
                        if case .updating = app.connectionState { ProgressView().controlSize(.mini) }
                        Text(app.connectionState == .updating ? "Обновление…" : "Нет связи · Повторить")
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AloTheme.muted)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain).accessibilityIdentifier("alo.connection.status")
            }
        }
        .frame(minHeight: AloSocialMetrics.controlHeight)
        .padding(.horizontal, AloSocialMetrics.inset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.feed.header")
    }

    @ViewBuilder
    private var storiesTray: some View {
        if app.bootstrap?.me != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button {
                        isStoryComposerPresented = true
                    } label: {
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottomTrailing) {
                                if let me = app.bootstrap?.me {
                                    AloAvatar(name: me.name, url: me.avatarUrl, size: 56, colorSeed: String(me.id))
                                }
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(AloTheme.accent))
                                    .overlay(Circle().stroke(AloTheme.background, lineWidth: 2))
                            }
                            Text("История")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AloTheme.muted)
                                .lineLimit(1)
                        }
                        .frame(width: 68)
                    }
                    .buttonStyle(AloFeedPressStyle())
                    .accessibilityLabel("Добавить историю")
                    .accessibilityIdentifier("alo.feed.create-story")

                    ForEach(app.stories) { group in
                        Button {
                            selectedStoryGroup = group
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .stroke(
                                            group.hasUnseen ? AloTheme.accent : AloTheme.border,
                                            lineWidth: 2
                                        )
                                        .frame(width: 60, height: 60)
                                    AloAvatar(
                                        name: group.user.name,
                                        url: group.user.avatarUrl,
                                        size: 54,
                                        colorSeed: String(group.user.id)
                                    )
                                }
                                Text(group.user.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AloTheme.text)
                                    .lineLimit(1)
                            }
                            .frame(width: 68)
                        }
                        .buttonStyle(AloFeedPressStyle())
                        .accessibilityLabel("История: \(group.user.name)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 12)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(AloTheme.feedDivider).frame(height: 0.5) }
        }
    }

}

private struct StoryViewerSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let group: AloStoryGroup
    @State private var currentIndex = 0

    private var story: AloStory? {
        group.stories.indices.contains(currentIndex) ? group.stories[currentIndex] : nil
    }

    var body: some View {
        ZStack {
            AloTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    AloAvatar(name: group.user.name, url: group.user.avatarUrl, size: 38, colorSeed: String(group.user.id))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.user.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AloTheme.text)
                        Text("История · 24 часа")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AloTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AloTheme.text)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(AloTheme.surfaceRaised))
                    }
                    .buttonStyle(.plain)
                }

                if let story {
                    if let media = story.media.first,
                       let url = app.api.absoluteURL(media.url) {
                        AloAsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                ProgressView().tint(AloTheme.accent)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 500)
                        .background(AloTheme.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                    if !story.body.isEmpty {
                        Text(story.body)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(AloTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer()

                if group.stories.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(group.stories.indices, id: \.self) { index in
                            Button {
                                currentIndex = index
                                if let selected = story { app.markStoryViewed(selected) }
                            } label: {
                                Capsule()
                                    .fill(index == currentIndex ? AloTheme.accent : AloTheme.border)
                                    .frame(maxWidth: .infinity, minHeight: 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            if let story { app.markStoryViewed(story) }
        }
        .onChange(of: currentIndex) { _, _ in
            if let story { app.markStoryViewed(story) }
        }
    }
}

/// Shared preparation for public feed media. The server accepts JPEG/MP4, not
/// the original HEIC from an iPhone. Drafts remain file-backed and encrypted.
enum AloFeedMediaImport {
    @MainActor static func load(_ items: [PhotosPickerItem]) async throws -> [AloLocalAttachment] {
        var drafts: [AloLocalAttachment] = []
        do {
            for item in items {
                try Task.checkCancellation()
                guard let picked = try await item.loadTransferable(type: AloPickedMediaFile.self) else {
                    throw ImportError.unavailable
                }
                defer { try? FileManager.default.removeItem(at: picked.url) }
                let video = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                let draft = try await Task.detached(priority: .userInitiated) {
                    try await prepare(source: picked.url, video: video)
                }.value
                drafts.append(draft)
            }
            try Task.checkCancellation()
            return drafts
        } catch {
            drafts.forEach(AloDraftAttachmentStore.discard)
            throw error
        }
    }

    static func prepare(source: URL, video: Bool) async throws -> AloLocalAttachment {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("alo-feed-\(UUID().uuidString)")
            .appendingPathExtension(video ? "mp4" : "jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        if video {
            guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPreset1280x720) else {
                throw ImportError.unavailable
            }
            exporter.shouldOptimizeForNetworkUse = true
            try await exporter.export(to: output, as: .mp4)
        } else {
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary),
                  let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw ImportError.unavailable
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImportError.unavailable }
        }
        try Task.checkCancellation()
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= (video ? 30 : 12) * 1_024 * 1_024 else { throw ImportError.tooLarge }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: output.path)
        let dimensions = video ? await AloMediaDimensions.video(sourceURL: output) : AloMediaDimensions.image(sourceURL: output)
        return try AloDraftAttachmentStore.makePickedMedia(sourceURL: output, mime: video ? "video/mp4" : "image/jpeg",
            type: video ? "video" : "image", name: video ? "video.mp4" : "photo.jpg")
            .withMediaDimensions(dimensions)
    }

    enum ImportError: LocalizedError {
        case unavailable, tooLarge
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Не удалось подготовить медиа. Загрузите оригинал из iCloud и выберите его снова."
            case .tooLarge: return "После подготовки файл всё ещё слишком большой. Фото — до 12 МБ, видео — до 30 МБ; выберите более короткое видео."
            }
        }
    }
}

/// "Новый пост": full screen like the rest of Alo's chrome, the app's header (glass close, centred
/// title, a filled publish button), large media previews and a glass tool bar above the keyboard.
private struct PostComposerSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isComposerFocused: Bool
    @State private var attachments = [AloLocalAttachment]()
    @State private var pickedItems = [PhotosPickerItem]()
    @State private var publishRequested = false
    @State private var publishingError = ""
    @State private var isImporting = false
    @State private var importError = ""
    @State private var importTask: Task<Void, Never>?
    private var accessibility = AloVisualAccessibility()

    /// The server accepts up to 1200 characters.
    private static let maximumLength = 1_200
    private var remaining: Int { Self.maximumLength - app.composeText.count }

    private var isPublishDisabled: Bool {
        isImporting || remaining < 0
            || (app.composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !publishingError.isEmpty { errorBanner }
                    if !importError.isEmpty {
                        Label(importError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 14)).foregroundStyle(AloTheme.destructive)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        if let me = app.bootstrap?.me {
                            AloAvatar(name: me.name, url: me.avatarUrl, size: 44, colorSeed: String(me.id))
                        } else {
                            Circle().fill(AloTheme.surfaceRaised).frame(width: 44, height: 44)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if let me = app.bootstrap?.me {
                                Text(me.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                            }
                            TextEditor(text: $app.composeText)
                                .scrollContentBackground(.hidden)
                                .scrollDisabled(true)
                                .foregroundStyle(AloTheme.text)
                                .font(.system(size: 17))
                                .focused($isComposerFocused)
                                .textInputAutocapitalization(.sentences)
                                .frame(minHeight: 120, alignment: .topLeading)
                                .padding(.leading, -5)
                                .disabled(app.isCreatingPost)
                                .accessibilityLabel("Текст поста")
                                .accessibilityIdentifier("alo.post.text")
                                .overlay(alignment: .topLeading) {
                                    if app.composeText.isEmpty {
                                        Text("Что нового?")
                                            .font(.system(size: 17)).foregroundStyle(AloTheme.muted)
                                            .padding(.top, 8)
                                            .allowsHitTesting(false)
                                    }
                                }
                        }
                    }

                    if isImporting || !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(attachments) { attachment in
                                    FeedDraftThumbnail(attachment: attachment, side: 180, isPublishing: app.isCreatingPost) {
                                        AloDraftAttachmentStore.discard(attachment)
                                        attachments.removeAll { $0.id == attachment.id }
                                    }
                                }
                                if isImporting {
                                    ProgressView().tint(AloTheme.accent)
                                        .frame(width: 120, height: 180)
                                        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                } else if attachments.count < 10 {
                                    mediaPicker {
                                        Image(systemName: "plus")
                                            .font(.system(size: 24, weight: .medium)).foregroundStyle(AloTheme.accent)
                                            .frame(width: 96, height: 180)
                                            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    }
                                    .accessibilityLabel("Добавить медиа")
                                }
                            }
                            .padding(.leading, 56)
                        }
                        .padding(.horizontal, -16)
                        .padding(.leading, 16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            toolbar
        }
        .background(AloTheme.background.ignoresSafeArea())
        .interactiveDismissDisabled(app.isCreatingPost)
        .animation(accessibility.reduceMotion ? nil : .easeOut(duration: 0.2), value: isImporting)
        .animation(accessibility.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88), value: attachments.map(\.id))
        .onAppear {
            // Open straight into typing, once the cover has finished presenting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { isComposerFocused = true }
        }
        .onChange(of: app.isCreatingPost) { wasCreating, isCreating in
            guard publishRequested, wasCreating, !isCreating else { return }
            publishRequested = false
            if app.postPublishingError.isEmpty && app.lastPublishedPostId > 0 {
                AloHaptics.notification(.success)
                dismiss()
            } else if !app.postPublishingError.isEmpty {
                publishingError = app.postPublishingError
            }
        }
        .onDisappear {
            isComposerFocused = false
            importTask?.cancel()
            attachments.forEach(AloDraftAttachmentStore.discard)
        }
        .onChange(of: pickedItems) { _, items in
            importTask?.cancel()
            isImporting = true
            importError = ""
            importTask = Task { await loadPickedItems(items) }
        }
    }

    /// Close, title and publish in one row, as X and Threads lay out a composer: the long
    /// "Опубликовать" capsule leaves no room for a centred title.
    private var header: some View {
        HStack(spacing: 12) {
                AloChatCircleButton(systemImage: "xmark", label: "Закрыть редактор поста") {
                    isComposerFocused = false
                    dismiss()
                }
                .disabled(app.isCreatingPost)
                Text("Новый пост").font(.system(size: 17, weight: .semibold)).foregroundStyle(AloTheme.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button {
                    publishRequested = true
                    publishingError = ""
                    isComposerFocused = false
                    app.createPost(localAttachments: attachments)
                    AloHaptics.impact(.light)
                } label: {
                    Group {
                        if app.isCreatingPost {
                            ProgressView().tint(.white)
                        } else {
                            Text("Опубликовать").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        }
                    }
                    .foregroundStyle(isPublishDisabled ? AloTheme.muted : .white)
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(isPublishDisabled ? AloTheme.surfaceRaised : AloTheme.accent, in: Capsule())
                    .fixedSize()
                }
                .buttonStyle(AloControlPressStyle())
                .disabled(isPublishDisabled || app.isCreatingPost)
                .frame(minHeight: 44)
                .accessibilityIdentifier("alo.post.publish")
        }
        .frame(height: AloChatMetrics.headerHeight)
        .padding(.horizontal, AloChatMetrics.headerHorizontalInset)
        .padding(.top, AloChatMetrics.headerTopInset)
    }

    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AloTheme.destructive)
            Text(publishingError).font(.system(size: 14, weight: .medium)).foregroundStyle(AloTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Повторить") {
                publishRequested = true
                publishingError = ""
                app.createPost(localAttachments: attachments)
            }
            .font(.system(size: 14, weight: .bold)).foregroundStyle(AloTheme.accent)
            .disabled(app.isCreatingPost)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(AloTheme.destructive.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("alo.post.publish-error")
    }

    /// A glass media button and the length counter, riding above the keyboard.
    private var toolbar: some View {
        HStack(spacing: 6) {
            mediaPicker {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 19)).foregroundStyle(AloTheme.accent)
                    .frame(width: 44, height: 44)
                    .modifier(AloChatGlass(interactive: false, role: .chrome))
                    .contentShape(Circle())
            }
            .accessibilityLabel("Фото или видео")
            Spacer(minLength: 0)
            if remaining <= 200 {
                Text("\(remaining)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(remaining < 0 ? AloTheme.destructive : AloTheme.muted)
                    .contentTransition(.numericText())
                    .accessibilityLabel(remaining < 0 ? "Превышено на \(-remaining) символов" : "Осталось \(remaining) символов")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func mediaPicker<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        PhotosPicker(selection: $pickedItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]),
                     preferredItemEncoding: .compatible, label: label)
            .buttonStyle(AloControlPressStyle())
            .disabled(app.isCreatingPost)
    }

    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        do {
            let next = try await AloFeedMediaImport.load(items)
            attachments.forEach(AloDraftAttachmentStore.discard)
            attachments = next
        } catch {
            guard !Task.isCancelled else { return }
            importError = error.localizedDescription
        }
        isImporting = false
    }
}

private struct FeedDraftThumbnail: View {
    let attachment: AloLocalAttachment
    var side: CGFloat = 86
    let isPublishing: Bool
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            FeedAttachmentPreview(attachment: attachment, side: side)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.6), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloControlPressStyle())
            .disabled(isPublishing)
            .accessibilityLabel("Удалить вложение")
        }
    }
}

/// A local draft's picture. `side` is the height of a strip tile (width follows the photo, within
/// limits); nil fills whatever frame it is given, as on the story canvas.
struct FeedAttachmentPreview: View {
    let attachment: AloLocalAttachment
    var side: CGFloat? = 86
    var maxPixelSize = 512
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            AloTheme.surfaceRaised
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: attachment.type == "video" ? "play.rectangle.fill" : "photo")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
            }
            if attachment.type == "video" {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .frame(width: side.map { side in
            guard let thumbnail, thumbnail.size.height > 0 else { return side }
            return min(side * 1.6, max(side * 0.62, side * thumbnail.size.width / thumbnail.size.height))
        }, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side == nil ? 0 : 16, style: .continuous))
        .task(id: attachment.id) {
            if attachment.type == "image" {
                thumbnail = try? await AloImageCache.draftImage(attachment, maxPixelSize: maxPixelSize)
            }
        }
    }
}

struct AloPostDetailScreen: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deleteCandidate: AloPostComment?
    private var accessibility = AloVisualAccessibility()

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            if let post = app.commentsPost {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        AloTimelinePost(post: post, presentation: .detail,
                                        isMine: post.creatorId == app.bootstrap?.me.id || post.author.id == app.bootstrap?.me.id,
                                        isLikePending: app.pendingLikePostIds.contains(post.id),
                                        isRepostPending: app.isRepostPending(post.id),
                                        onDelete: { app.deletePost(post) },
                                        onNotice: { app.notice = $0 }) {
                            app.toggleLike(post)
                        } onComment: {
                            withAnimation(accessibility.reduceMotion ? nil : AloPressFeedback.release) {
                                proxy.scrollTo("alo.comments.heading", anchor: .top)
                            }
                        } onRepost: {
                            app.toggleRepost(post)
                        } onAuthor: {
                            dismiss()
                            app.openProfile(post.author)
                        }

                        HStack {
                            Text("Комментарии").font(.headline)
                            Text(AloCompactCount.string(post.commentCount)).font(.subheadline)
                                .foregroundStyle(AloTheme.muted)
                            Spacer()
                        }
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .id("alo.comments.heading")
                        .accessibilityIdentifier("alo.comments.heading")

                        if app.commentsLoading {
                            ProgressView().tint(AloTheme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        } else if app.comments.isEmpty && app.commentsError.isEmpty {
                            ContentUnavailableView(
                                "Комментариев пока нет",
                                systemImage: "bubble.left",
                                description: Text("Будь первым в обсуждении.")
                            )
                            .foregroundStyle(AloTheme.muted)
                            .padding(.vertical, 28)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(app.comments) { comment in
                                    CommentRow(
                                        comment: comment,
                                        isMine: comment.author.id == app.bootstrap?.me.id,
                                        onLike: { app.toggleCommentLike(comment) },
                                        onAuthor: {
                                            dismiss()
                                            app.openProfile(comment.author)
                                        },
                                        onDelete: { deleteCandidate = comment }
                                    )
                                    .id(comment.id)
                                    Divider().background(AloTheme.border).padding(.leading, 72)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("alo.comments.scroll")
                .onChange(of: app.lastCreatedCommentId) { _, id in
                    guard id > 0 else { return }
                    withAnimation(accessibility.reduceMotion ? nil : AloPressFeedback.release) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
                }
            }
            if !app.commentsError.isEmpty {
                HStack(spacing: 8) {
                    Text(app.commentsError).font(.caption).foregroundStyle(AloTheme.muted)
                    Spacer(minLength: 0)
                    Button("Обновить") {
                        if let id = app.commentsPost?.id { Task { await app.loadComments(for: id) } }
                    }
                    .font(.caption).foregroundStyle(AloTheme.accent).frame(minHeight: 44)
                }
                .padding(.horizontal, 16)
            }

            commentComposer
        }
        .background(AloTheme.background.ignoresSafeArea())
        .navigationTitle("Публикация")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(AloTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .confirmationDialog("Комментарий", isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let deleteCandidate {
                    app.deleteComment(deleteCandidate)
                }
                deleteCandidate = nil
            }
            Button("Отмена", role: .cancel) {
                deleteCandidate = nil
            }
        }
    }

    private var commentComposer: some View {
        HStack(spacing: 10) {
            TextField("Ваш комментарий…", text: $app.commentText, axis: .vertical)
                .foregroundStyle(AloTheme.text)
                .font(.body)
                .lineLimit(1...5)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(minHeight: AloInputMetrics.height)
                .modifier(AloChatPanelGlass(radius: app.commentText.contains("\n") || app.commentText.count > 40 ? AloInputMetrics.multiLineRadius : AloInputMetrics.singleLineRadius, role: .control))
                .frame(minHeight: AloInputMetrics.touchHeight)
                .accessibilityIdentifier("alo.comments.input")
            Button {
                app.createComment()
            } label: {
                Group {
                    if app.isSendingComment { ProgressView().tint(.white) }
                    else { Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold)) }
                }
                .foregroundStyle(.white)
                .frame(width: AloInputMetrics.height, height: AloInputMetrics.height)
                .background(app.commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AloTheme.surfaceRaised : AloTheme.accent, in: Circle())
                .frame(width: AloInputMetrics.touchHeight, height: AloInputMetrics.touchHeight)
                .contentShape(Rectangle())
            }
            .disabled(app.isSendingComment || app.commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(AloFeedPressStyle())
            .accessibilityLabel("Отправить комментарий").accessibilityIdentifier("alo.comments.send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, AloInputMetrics.verticalPadding)
        .background(AloTheme.background.opacity(0.98))
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { deleteCandidate != nil },
            set: { presented in
                if !presented { deleteCandidate = nil }
            }
        )
    }
}

private struct CommentRow: View {
    let comment: AloPostComment
    let isMine: Bool
    let onLike: () -> Void
    let onAuthor: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject private var app: AloAppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onAuthor) {
                AloAvatar(
                    name: comment.author.name,
                    url: comment.author.avatarUrl,
                    size: 42,
                    colorSeed: String(comment.author.id)
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Button(action: onAuthor) {
                    HStack(spacing: 5) {
                        Text(comment.author.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AloTheme.text)
                        if comment.author.verified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AloTheme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)

                if !comment.body.isEmpty {
                    Text(comment.body)
                        .font(.body)
                        .foregroundStyle(AloTheme.text)
                }
                if !comment.media.isEmpty { AloPostMediaGrid(media: comment.media, timeline: true) }

                HStack(spacing: 16) {
                    Button(action: onLike) {
                        Label("\(comment.likeCount)", systemImage: comment.viewerLiked ? "heart.fill" : "heart")
                            .foregroundStyle(comment.viewerLiked ? Color(red: 1, green: 0.32, blue: 0.42) : AloTheme.muted)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(AloFeedPressStyle())
                    .disabled(app.pendingCommentLikeIds.contains(comment.id))
                    .accessibilityLabel(comment.viewerLiked ? "Убрать лайк комментария" : "Лайк комментария")
                    .accessibilityValue("\(comment.likeCount)")
                    Text(comment.editedAt.isEmpty ? shortDate(comment.createdAt) : "\(shortDate(comment.createdAt)) · изменено")
                        .foregroundStyle(AloTheme.muted)
                    if isMine {
                        Button("Удалить", role: .destructive, action: onDelete).frame(minHeight: 44)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                // The 44 pt touch targets stay, but they no longer stretch the gap between comments.
                .padding(.vertical, -9)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func shortDate(_ raw: String) -> String {
        AloPostTimestamp.string(raw)
    }
}
