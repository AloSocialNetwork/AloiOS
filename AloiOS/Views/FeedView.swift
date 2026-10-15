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
    @State private var whyShownPost: AloPost?
    @State private var reportTarget: AloReportTarget?
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
                            if let reason = app.hiddenFeedPosts[post.id] {
                                AloHiddenPostRow(reason: reason) { app.undoHideFeedPost(post) }
                                    .transition(.opacity)
                            } else {
                                AloTimelinePost(post: post,
                                                isMine: isMine(post),
                                                isLikePending: app.pendingLikePostIds.contains(post.id),
                                                isRepostPending: app.isRepostPending(post.id),
                                                onDelete: { app.deletePost(post) },
                                                onNotice: { app.notice = $0 },
                                                onReaderAction: { readerAction($0, on: post) }) {
                                    app.toggleLike(post)
                                } onComment: {
                                    app.openComments(for: post)
                                } onRepost: {
                                    app.toggleRepost(post)
                                } onAuthor: {
                                    app.openProfile(post.author)
                                }
                                .equatable()
                                .transition(.opacity)
                            }
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
        .fullScreenCover(item: $selectedStoryGroup) { group in
            AloStoryViewer(groups: app.stories, startGroupID: group.id)
                .environmentObject(app)
        }
        .navigationDestination(isPresented: $settingsPresented) {
            AloSocialSettingsSheet().environmentObject(app)
        }
        .sheet(item: $whyShownPost) { post in
            AloWhyShownSheet(post: post) { app.hideFeedPost(post, reason: $0) }
        }
        .sheet(item: $reportTarget) { target in
            AloReportSheet(target: target) { reason, details in
                try await app.report(target, reason: reason, details: details)
            }
        }
    }

    private func readerAction(_ action: AloPostReaderAction, on post: AloPost) {
        switch action {
        case .whyShown: whyShownPost = post
        case .notInterested: app.hideFeedPost(post, reason: .notInterested)
        case .hide: app.hideFeedPost(post, reason: .hide)
        case .report: reportTarget = .post(post.id)
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
    /// A saved draft opened here: its id and its already uploaded media.
    @State private var draftId: Int?
    @State private var draftMedia = [AloMediaItem]()
    @State private var isDraftsPresented = false
    @State private var confirmsClose = false
    @State private var isSavingDraft = false
    private var accessibility = AloVisualAccessibility()

    /// The server accepts up to 1200 characters.
    private static let maximumLength = 1_200
    private var remaining: Int { Self.maximumLength - app.composeText.count }
    private var mediaCount: Int { attachments.count + draftMedia.count }

    private var hasContent: Bool {
        !app.composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mediaCount > 0
    }

    private var isPublishDisabled: Bool {
        isImporting || isSavingDraft || remaining < 0 || !hasContent
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

                    if isImporting || mediaCount > 0 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(draftMedia.enumerated()), id: \.offset) { index, media in
                                    AloDraftMediaThumbnail(media: media, side: 180) {
                                        draftMedia.remove(at: index)
                                    }
                                    .disabled(app.isCreatingPost)
                                }
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
                                } else if mediaCount < 10 {
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

            if let query = AloMentionQuery.current(in: app.composeText) {
                AloMentionSuggestions(query: query) { person in
                    app.composeText = AloMentionQuery.insert(person.username, into: app.composeText)
                }
                .padding(.horizontal, 12)
            }
            toolbar
        }
        .background(AloTheme.background.ignoresSafeArea())
        .interactiveDismissDisabled(app.isCreatingPost || hasContent)
        .confirmationDialog(draftId == nil ? "Сохранить черновик?" : "Сохранить изменения?", isPresented: $confirmsClose,
                            titleVisibility: .visible) {
            if let draftId {
                Button("Сохранить изменения") { saveDraftAndClose() }
                Button("Не сохранять") {
                    app.composeText = ""
                    dismiss()
                }
                Button("Удалить черновик", role: .destructive) {
                    if let draft = app.postDrafts.first(where: { $0.id == draftId }) { app.deletePostDraft(draft) }
                    app.composeText = ""
                    dismiss()
                }
            } else {
                Button("Сохранить черновик") { saveDraftAndClose() }
                Button("Удалить", role: .destructive) {
                    app.composeText = ""
                    dismiss()
                }
            }
            Button("Продолжить редактирование", role: .cancel) {}
        } message: {
            Text(draftId == nil ? "Черновик можно будет открыть с любого устройства." : "Черновик останется таким, каким был до открытия.")
        }
        .sheet(isPresented: $isDraftsPresented) {
            AloPostDraftsSheet { open($0) }
                .environmentObject(app)
        }
        .task { await app.loadPostDrafts() }
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
                    if hasContent { confirmsClose = true } else { dismiss() }
                }
                .disabled(app.isCreatingPost || isSavingDraft)
                Text(draftId == nil ? "Новый пост" : "Черновик").font(.system(size: 17, weight: .semibold)).foregroundStyle(AloTheme.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if !app.postDrafts.isEmpty {
                    Button { isDraftsPresented = true } label: {
                        Image(systemName: "doc.text")
                            .font(.system(size: 17, weight: .medium)).foregroundStyle(AloTheme.text)
                            .frame(width: 40, height: 40)
                            .modifier(AloChatGlass(interactive: true, role: .control))
                            .overlay(alignment: .topTrailing) {
                                Text("\(app.postDrafts.count)")
                                    .font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                    .background(AloTheme.accent, in: Capsule())
                                    .offset(x: 4, y: -4)
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(AloControlPressStyle())
                    .disabled(app.isCreatingPost)
                    .accessibilityLabel("Черновики: \(app.postDrafts.count)")
                    .accessibilityIdentifier("alo.post.drafts-button")
                }
                Button {
                    publishRequested = true
                    publishingError = ""
                    isComposerFocused = false
                    app.createPost(localAttachments: attachments, draftMedia: draftMedia, draftId: draftId)
                    AloHaptics.impact(.light)
                } label: {
                    Group {
                        if app.isCreatingPost || isSavingDraft {
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
                app.createPost(localAttachments: attachments, draftMedia: draftMedia, draftId: draftId)
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
        PhotosPicker(selection: $pickedItems, maxSelectionCount: max(1, 10 - draftMedia.count), matching: .any(of: [.images, .videos]),
                     preferredItemEncoding: .compatible, label: label)
            .buttonStyle(AloControlPressStyle())
            .disabled(app.isCreatingPost)
    }

    /// Uploads new media, saves the draft (a new one, or the one being edited) and closes.
    private func saveDraftAndClose() {
        isSavingDraft = true
        importError = ""
        Task {
            defer { isSavingDraft = false }
            do {
                try await app.savePostDraft(id: draftId, body: app.composeText, localAttachments: attachments,
                                            draftMedia: draftMedia)
                app.composeText = ""
                app.notice = "Черновик сохранён"
                AloHaptics.notification(.success)
                dismiss()
            } catch {
                importError = (error as? AloAPIError)?.message ?? "Не удалось сохранить черновик. Проверьте подключение."
            }
        }
    }

    /// Opens a saved draft in place of what is being written.
    private func open(_ draft: AloPostDraft) {
        attachments.forEach(AloDraftAttachmentStore.discard)
        attachments = []
        draftMedia = draft.media
        draftId = draft.id
        app.composeText = draft.body
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isComposerFocused = true }
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
    var showsPlayBadge = true
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
            if attachment.type == "video", showsPlayBadge {
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
            } else if attachment.type == "video" {
                // A real first frame instead of a grey tile, so drawing on a video lines up.
                thumbnail = await AloStoryVideoComposer.posterFrame(of: attachment, maxPixelSize: CGFloat(maxPixelSize))
            }
        }
    }
}

struct AloPostDetailScreen: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deleteCandidate: AloPostComment?
    @State private var reportTarget: AloReportTarget?
    /// Root comments whose replies are open.
    @State private var expandedThreads = Set<Int>()
    @FocusState private var isCommentFocused: Bool
    private var accessibility = AloVisualAccessibility()

    /// Root comments in order; replies whose root is missing are shown as roots.
    private var roots: [AloPostComment] {
        let ids = Set(app.comments.map(\.id))
        return app.comments.filter { $0.parentId == nil || !ids.contains($0.parentId!) }
    }

    private func replies(to root: AloPostComment) -> [AloPostComment] {
        app.comments.filter { $0.parentId == root.id }
    }

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
                                        onNotice: { app.notice = $0 },
                                        onReaderAction: { action in
                                            switch action {
                                            case .report: reportTarget = .post(post.id)
                                            case .hide, .notInterested:
                                                app.hideFeedPost(post, reason: action == .hide ? .hide : .notInterested)
                                                dismiss()
                                            case .whyShown: break
                                            }
                                        }) {
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
                                ForEach(roots) { root in
                                    commentRow(root)
                                    let thread = replies(to: root)
                                    if !thread.isEmpty {
                                        if expandedThreads.contains(root.id) {
                                            ForEach(thread) { reply in
                                                commentRow(reply).padding(.leading, 52)
                                            }
                                        }
                                        threadToggle(root: root, count: thread.count)
                                    }
                                    Divider().background(AloTheme.border).padding(.leading, 52)
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
                    // A new reply opens its thread, so it is visible.
                    if let parent = app.comments.first(where: { $0.id == id })?.parentId { expandedThreads.insert(parent) }
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
        } message: {
            if let deleteCandidate, deleteCandidate.parentId == nil, app.comments.contains(where: { $0.parentId == deleteCandidate.id }) {
                Text("Ответы на него тоже удалятся.")
            }
        }
        .sheet(item: $reportTarget) { target in
            AloReportSheet(target: target) { reason, details in
                try await app.report(target, reason: reason, details: details)
            }
        }
    }

    private func commentRow(_ comment: AloPostComment) -> some View {
        CommentRow(
            comment: comment,
            isReply: comment.parentId != nil,
            isMine: comment.author.id == app.bootstrap?.me.id,
            onLike: { app.toggleCommentLike(comment) },
            onReply: { reply(to: comment) },
            onAuthor: {
                dismiss()
                app.openProfile(comment.author)
            },
            onDelete: { deleteCandidate = comment },
            onReport: { reportTarget = .comment(comment.id) }
        )
        .id(comment.id)
    }

    /// Instagram's "Посмотреть ещё N ответов" / "Скрыть ответы" under a root comment.
    private func threadToggle(root: AloPostComment, count: Int) -> some View {
        let open = expandedThreads.contains(root.id)
        return Button {
            withAnimation(accessibility.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88)) {
                if open { expandedThreads.remove(root.id) } else { expandedThreads.insert(root.id) }
            }
        } label: {
            HStack(spacing: 10) {
                Rectangle().fill(AloTheme.muted.opacity(0.5)).frame(width: 24, height: 1)
                Text(open ? "Скрыть ответы" : "Посмотреть ответы (\(count))")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(AloTheme.muted)
                Spacer(minLength: 0)
            }
            .padding(.leading, 52).frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("alo.comments.thread.\(root.id)")
    }

    /// Starts a reply: the composer names the person and begins with their handle.
    private func reply(to comment: AloPostComment) {
        app.commentReplyTarget = comment
        let handle = comment.author.username.isEmpty ? "" : "@\(comment.author.username) "
        if !handle.isEmpty, !app.commentText.hasPrefix(handle) {
            app.commentText = handle + app.commentText.trimmingCharacters(in: .whitespaces)
        }
        if let root = comment.parentId { expandedThreads.insert(root) }
        isCommentFocused = true
    }

    private var commentComposer: some View {
        VStack(spacing: 8) {
            if let query = AloMentionQuery.current(in: app.commentText) {
                AloMentionSuggestions(query: query) { person in
                    app.commentText = AloMentionQuery.insert(person.username, into: app.commentText)
                }
            }
            if let target = app.commentReplyTarget {
                HStack(spacing: 8) {
                    Text("Ответ для \(target.author.username.isEmpty ? target.author.name : target.author.username.withAtPrefix)")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(AloTheme.muted).lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        let handle = "@\(target.author.username) "
                        if app.commentText.hasPrefix(handle) { app.commentText.removeFirst(handle.count) }
                        app.commentReplyTarget = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(AloTheme.muted)
                            .frame(width: 32, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Отменить ответ")
                    .accessibilityIdentifier("alo.comments.reply-cancel")
                }
                .padding(.horizontal, 4)
                .accessibilityIdentifier("alo.comments.reply-bar")
            }
            commentInputRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, AloInputMetrics.verticalPadding)
        .background(AloTheme.background.opacity(0.98))
        .animation(accessibility.reduceMotion ? nil : .easeOut(duration: 0.18), value: app.commentReplyTarget?.id)
    }

    private var commentInputRow: some View {
        HStack(spacing: 10) {
            TextField(app.commentReplyTarget == nil ? "Ваш комментарий…" : "Ваш ответ…", text: $app.commentText, axis: .vertical)
                .foregroundStyle(AloTheme.text)
                .font(.body)
                .lineLimit(1...5)
                .focused($isCommentFocused)
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
    var isReply = false
    let isMine: Bool
    let onLike: () -> Void
    let onReply: () -> Void
    let onAuthor: () -> Void
    let onDelete: () -> Void
    let onReport: () -> Void
    @EnvironmentObject private var app: AloAppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onAuthor) {
                AloAvatar(
                    name: comment.author.name,
                    url: comment.author.avatarUrl,
                    size: isReply ? 30 : 42,
                    colorSeed: String(comment.author.id)
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Button(action: onAuthor) {
                    HStack(spacing: 5) {
                        Text(comment.author.name)
                            .font(.system(size: isReply ? 15 : 16, weight: .bold))
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
                    let markup = AloMessageMarkup.parse(comment.body)
                    AloRichMessageText(body: markup.body, entities: markup.entities, fontSize: isReply ? 15 : 16)
                        .accessibilityIdentifier("alo.comments.body.\(comment.id)")
                }
                if !comment.media.isEmpty { AloPostMediaGrid(media: comment.media, timeline: true) }

                HStack(spacing: 14) {
                    Text(comment.editedAt.isEmpty ? shortDate(comment.createdAt) : "\(shortDate(comment.createdAt)) · изменено")
                        .foregroundStyle(AloTheme.muted)
                    Button("Ответить", action: onReply)
                        .foregroundStyle(AloTheme.muted)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("alo.comments.reply.\(comment.id)")
                    if isMine {
                        Button("Удалить", role: .destructive, action: onDelete).frame(minHeight: 44)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                // The 44 pt touch targets stay, but they no longer stretch the gap between comments.
                .padding(.vertical, -9)
            }
            Spacer(minLength: 4)
            Button(action: onLike) {
                VStack(spacing: 2) {
                    Image(systemName: comment.viewerLiked ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .semibold))
                    if comment.likeCount > 0 {
                        Text(AloCompactCount.string(comment.likeCount)).font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                }
                .foregroundStyle(comment.viewerLiked ? Color(red: 1, green: 0.32, blue: 0.42) : AloTheme.muted)
                .frame(minWidth: 36, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(AloFeedPressStyle())
            .disabled(app.pendingCommentLikeIds.contains(comment.id))
            .accessibilityLabel(comment.viewerLiked ? "Убрать лайк комментария" : "Лайк комментария")
            .accessibilityValue("\(comment.likeCount)")
            .sensoryFeedback(.selection, trigger: comment.viewerLiked)
        }
        .padding(.vertical, isReply ? 6 : 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button { onReply() } label: { Label("Ответить", systemImage: "arrowshape.turn.up.left") }
            if !comment.body.isEmpty {
                Button { UIPasteboard.general.string = comment.body } label: { Label("Скопировать", systemImage: "doc.on.doc") }
            }
            if isMine {
                Button(role: .destructive, action: onDelete) { Label("Удалить", systemImage: "trash") }
            } else {
                Button(role: .destructive, action: onReport) { Label("Пожаловаться", systemImage: "exclamationmark.bubble") }
            }
        }
    }

    private func shortDate(_ raw: String) -> String {
        AloPostTimestamp.string(raw)
    }
}
