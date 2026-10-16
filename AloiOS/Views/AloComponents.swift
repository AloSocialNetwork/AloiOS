import SwiftUI
import UIKit
import AVKit

struct AloPressBounceButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    private var accessibility = AloVisualAccessibility()

    init(pressedScale: CGFloat = 0.96) {
        self.pressedScale = pressedScale
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !accessibility.reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(
                configuration.isPressed || accessibility.reduceMotion ? nil : AloPressFeedback.release,
                value: configuration.isPressed
            )
    }
}

private struct AloTouchBounceModifier: ViewModifier {
    let pressedScale: CGFloat
    @GestureState private var isPressed = false
    private var accessibility = AloVisualAccessibility()

    init(pressedScale: CGFloat) {
        self.pressedScale = pressedScale
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !accessibility.reduceMotion ? pressedScale : 1)
            .opacity(isPressed ? 0.92 : 1)
            .animation(
                isPressed || accessibility.reduceMotion ? nil : AloPressFeedback.release,
                value: isPressed
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in state = true }
            )
    }
}

extension View {
    func aloTouchBounce(pressedScale: CGFloat = 0.97) -> some View {
        modifier(AloTouchBounceModifier(pressedScale: pressedScale))
    }
}

struct AloInteractiveBackGesture: UIViewRepresentable {
    var isEnabled = true
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.recognizer.isEnabled = isEnabled
        uiView.scheduleInstallation()
    }

    static func dismantleUIView(_ uiView: InstallerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            scheduleInstallation()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleInstallation()
        }

        func scheduleInstallation() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let superview else { return }
                coordinator?.attach(to: superview)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: AloInteractiveBackGesture
        weak var attachedView: UIView?

        lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.maximumNumberOfTouches = 1
            // Ordinary controls keep their normal touch lifecycle. The pan becomes
            // exclusive only after UIKit establishes a rightward horizontal drag.
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delegate = self
            return recognizer
        }()

        init(owner: AloInteractiveBackGesture) {
            self.owner = owner
        }

        func attach(to view: UIView) {
            guard attachedView !== view else { return }
            detach()
            attachedView = view
            view.addGestureRecognizer(recognizer)
        }

        func detach() {
            attachedView?.removeGestureRecognizer(recognizer)
            attachedView = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard owner.isEnabled,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            // Start even for a slow, intentional pull, while keeping vertical
            // scrolling as the stronger gesture when the direction is ambiguous.
            return velocity.x > 10 && abs(velocity.x) > abs(velocity.y) * 1.12
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Buttons, text inputs and horizontal carousels own their gestures.
            // The interactive back gesture stays available across the rest of
            // the conversation, including its vertical message list.
            var view = touch.view
            while let current = view {
                if current is UIControl || current is UITextField || current is UITextView {
                    return false
                }
                if let scrollView = current as? UIScrollView,
                   scrollView.contentSize.width > scrollView.bounds.width + 1 {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // The message history owns vertical scrolling. Allow its pan to
            // coexist with our direction-gated recognizer so a rightward
            // back-swipe can begin anywhere in the chat instead of being
            // swallowed by the ScrollView's pan gesture.
            otherGestureRecognizer is UIPanGestureRecognizer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = max(0, recognizer.translation(in: recognizer.view).x)
            switch recognizer.state {
            case .began:
                owner.onBegan()
                owner.onChanged(translation)
            case .changed:
                owner.onChanged(translation)
            case .ended:
                owner.onEnded(translation, recognizer.velocity(in: recognizer.view).x)
            case .cancelled, .failed:
                // Cancellation always returns to the current screen.
                owner.onEnded(0, 0)
            default:
                break
            }
        }
    }
}

/// The API client without the whole app model. Views that only need to resolve media URLs read
/// this, so they are not re-rendered on every app-wide change (avatars and posts are everywhere).
private struct AloAPIClientKey: EnvironmentKey {
    static let defaultValue: AloAPIClient? = nil
}

extension EnvironmentValues {
    var aloAPIClient: AloAPIClient? {
        get { self[AloAPIClientKey.self] }
        set { self[AloAPIClientKey.self] = newValue }
    }
}

struct AloAvatar: View {
    let name: String
    let url: String
    let size: CGFloat
    let colorSeed: String

    @Environment(\.aloAPIClient) private var api

    init(name: String, url: String, size: CGFloat = 46, colorSeed: String? = nil) {
        self.name = name
        self.url = url
        self.size = size
        self.colorSeed = colorSeed ?? name
    }

    var body: some View {
        ZStack {
            Circle().fill(placeholderGradient)
            if let imageUrl = api?.absoluteURL(url), !url.isEmpty {
                AloAsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholderLetter
                    }
                }
                .clipShape(Circle())
            } else {
                placeholderLetter
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    private var placeholderLetter: some View {
        Text(initial)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(Color.white)
    }

    private var placeholderGradient: LinearGradient {
        LinearGradient(
            colors: AloAvatarPalette.colors(for: colorSeed),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased().ifBlank("A")
    }
}

private enum AloAvatarPalette {
    // The original letter-avatar palette is deliberately bright and distinct.
    // It keeps inbox rows identifiable without adding color to the page chrome.
    private static let pairs: [(UInt32, UInt32)] = [
        (0xff516a, 0xff885e),
        (0xffa85c, 0xffcd6a),
        (0x665fff, 0x82b1ff),
        (0x54cb68, 0xa0de7e),
        (0x4acccd, 0x00fcfd),
        (0x2a9ef1, 0x72d5fd),
        (0xd669ed, 0xe0a2f3)
    ]

    static func colors(for seed: String) -> [Color] {
        let pair = pairs[stableIndex(for: seed)]
        return [color(pair.1), color(pair.0)]
    }

    private static func stableIndex(for seed: String) -> Int {
        let value = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let numericValue = Int64(value) {
            return Int(numericValue.magnitude % UInt64(pairs.count))
        }

        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash % UInt64(pairs.count))
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }
}

struct AloIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AloTheme.text)
                .frame(width: 46, height: 46)
                .background {
                    Circle().fill(AloTheme.surfaceRaised)
                }
                .clipShape(Circle())
                .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
        }
        .buttonStyle(AloPressBounceButtonStyle())
    }
}

struct AloPrimaryButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(disabled ? AloTheme.surfaceRaised : AloTheme.accent)
                .clipShape(Capsule())
        }
        .disabled(disabled)
        .buttonStyle(.plain)
    }
}

struct AloTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .foregroundStyle(AloTheme.text)
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(AloTheme.surfaceRaised)
        .clipShape(Capsule())
    }
}

struct AloPostCard: View {
    let post: AloPost
    let onLike: () -> Void
    var onComment: () -> Void = {}
    var onRepost: () -> Void = {}
    var onAuthor: () -> Void = {}

    @EnvironmentObject private var app: AloAppModel
    @State private var isDeleteConfirmationPresented = false

    private var canDelete: Bool {
        guard let currentUserId = app.bootstrap?.me.id else { return false }
        return post.creatorId == currentUserId || post.author.id == currentUserId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button(action: onAuthor) {
                        HStack(spacing: 10) {
                            AloAvatar(
                                name: post.author.name,
                                url: post.author.avatarUrl,
                                size: 40,
                                colorSeed: String(post.author.id)
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(post.author.name)
                                        .font(.system(size: 17, weight: .bold))
                                    if post.author.verified {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(AloTheme.accent)
                                    }
                                }
                                Text(postMeta)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AloTheme.muted)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        isDeleteConfirmationPresented = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AloTheme.muted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Действия с постом")
                }

                if !post.body.isEmpty {
                    let markup = AloMessageMarkup.parse(post.body)
                    AloRichMessageText(body: markup.body, entities: markup.entities)
                        .accessibilityIdentifier("alo.post.body.\(post.id)")
                }

                if !post.media.isEmpty {
                    AloPostMediaGrid(media: post.media)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("alo.post.media.\(post.id)")
                }

                if !post.authorSignature.isEmpty {
                    Text(post.authorSignature)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                }
            }

            HStack(spacing: 8) {
                Button(action: onLike) {
                    AloPostActionLabel(count: post.likeCount, icon: post.viewerLiked ? "heart.fill" : "heart",
                        selected: post.viewerLiked, tint: Color(red: 1, green: 0.32, blue: 0.42))
                }
                .accessibilityLabel(post.viewerLiked ? "Убрать лайк" : "Поставить лайк")
                .accessibilityValue("\(post.likeCount)")
                .accessibilityIdentifier("alo.post.like.\(post.id)")
                Button(action: onComment) {
                    AloPostActionLabel(count: post.commentCount, icon: post.commentsEnabled ? "bubble.left" : "lock.fill")
                }
                .disabled(!post.commentsEnabled)
                .accessibilityLabel(post.commentsEnabled ? "Комментарии" : "Комментарии отключены")
                .accessibilityValue("\(post.commentCount)")
                .accessibilityIdentifier("alo.post.comments.\(post.id)")
                Button(action: onRepost) {
                    AloPostActionLabel(count: post.repostCount, icon: "arrow.2.squarepath", selected: post.viewerReposted)
                }
                .disabled(app.isRepostPending(post.id))
                .accessibilityLabel(post.viewerReposted ? "Убрать репост" : "Сделать репост")
                .accessibilityValue("\(post.repostCount)")
                .accessibilityIdentifier("alo.post.repost.\(post.id)")
                AloPostActionLabel(count: post.viewCount, icon: "eye", alignment: .trailing)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Просмотры")
                    .accessibilityValue("\(post.viewCount)")
            }
            .buttonStyle(AloChatPressStyle())
        }
        .padding(.top, AloTheme.spacingMedium)
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AloTheme.feedDivider)
                .frame(height: 1)
        }
        .confirmationDialog(
            "Пост",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Скопировать ссылку") {
                copyPostLink()
            }
            if canDelete {
                Button("Удалить пост", role: .destructive) {
                    app.deletePost(post)
                }
            }
            Button("Отмена", role: .cancel) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.post.card.\(post.id)")
    }

    private func copyPostLink() {
        UIPasteboard.general.string = AloDeepLinkTarget.postURL(postId: post.id)?.absoluteString
        app.notice = "Ссылка на пост скопирована."
    }

    private func shortDate(_ raw: String) -> String {
        let value = String(raw.prefix(10))
        guard value.count == 10 else { return value }
        return String(value.suffix(5))
    }

    private var postMeta: String {
        let username = post.author.username.withAtPrefix
        let date = shortDate(post.createdAt)
        if username.isEmpty { return date }
        if date.isEmpty { return username }
        return "\(username) · \(date)"
    }
}

/// Equal action columns isolate count updates from post and neighbour geometry.
struct AloPostActionLabel: View {
    private var accessibility = AloVisualAccessibility()
    let count: Int
    let icon: String
    var selected = false
    var tint: Color = AloTheme.accent
    var alignment: Alignment = .leading
    var iconSize: CGFloat = 15

    init(count: Int, icon: String, selected: Bool = false, tint: Color = AloTheme.accent,
         alignment: Alignment = .leading, iconSize: CGFloat = 15) {
        self.count = count; self.icon = icon; self.selected = selected
        self.tint = tint; self.alignment = alignment; self.iconSize = iconSize
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: selected ? .semibold : .regular))
                .frame(width: max(20, iconSize + 2))
                .symbolEffect(.bounce, options: .nonRepeating, value: accessibility.reduceMotion ? false : selected)
            Text(AloCompactCount.string(count))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .contentTransition(accessibility.reduceMotion ? .identity : .numericText())
                .animation(accessibility.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: count)
        }
        .foregroundStyle(selected ? tint : AloTheme.muted)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: alignment)
        .contentShape(Rectangle())
    }
}

struct AloPostMediaGrid: View {
    let media: [AloMediaItem]
    var timeline = false

    // Only the API client: a grid is in every post, it must not follow every app change.
    @Environment(\.aloAPIClient) private var api
    @State private var selectedMedia: AloMediaItem?
    /// Bumped when a photo without a server size finishes loading, so the layout takes its real
    /// proportions instead of the 4:5 guess.
    @State private var sizeRevision = 0

    var body: some View {
        let _ = sizeRevision
        Group {
            switch media.count {
            case 0:
                EmptyView()
            case 1:
                mediaCell(media[0])
                    .frame(maxWidth: .infinity)
                    .aspectRatio(AloPostMediaSizing.ratio(for: knownDimensions(media[0])), contentMode: .fit)
            default:
                // Telegram's album mosaic: every photo keeps close to its own proportions.
                let shown = Array(media.prefix(AloChatMosaic.maximumItems))
                AloPostAlbumLayout(dimensions: shown.map(knownDimensions)) {
                    ForEach(shown) { item in
                        mediaCell(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: timeline ? 14 : 18, style: .continuous))
        .fullScreenCover(item: $selectedMedia) { item in
            AloPostMediaViewer(
                media: media,
                startItem: item,
                onDismiss: { selectedMedia = nil }
            )
        }
    }

    /// Server size if present, else the decoded image once it is in memory.
    private func knownDimensions(_ item: AloMediaItem) -> AloMediaDimensions? {
        if let dimensions = item.dimensions { return dimensions }
        guard let url = api?.absoluteURL(item.posterUrl.ifBlank(item.url)) else { return nil }
        return AloCachedImageSize.dimensions(for: url)
    }

    private func mediaCell(_ item: AloMediaItem) -> some View {
        GeometryReader { proxy in
            ZStack {
                AloTheme.background
                if let url = api?.absoluteURL(item.posterUrl.ifBlank(item.url)) {
                    AloAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                                .accessibilityLabel("Изображение в посте")
                                .accessibilityIdentifier("alo.post.media.loaded")
                                .onAppear {
                                    if item.dimensions == nil { sizeRevision &+= 1 }
                                }
                        case .failure:
                            Image(systemName: "photo").foregroundStyle(AloTheme.muted)
                                .accessibilityLabel("Не удалось загрузить изображение")
                        default:
                            ProgressView().tint(AloTheme.accent)
                        }
                    }
                }
                if item.type == "video" {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                selectedMedia = item
            }
        }
        .clipped()
    }
}

/// Places an album's cells on Telegram's mosaic for the offered width.
struct AloPostAlbumLayout: Layout {
    let dimensions: [AloMediaDimensions?]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        AloPostMediaSizing.album(dimensions, width: proposal.replacingUnspecifiedDimensions().width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = AloPostMediaSizing.album(dimensions, width: bounds.width).frames
        for (index, subview) in subviews.enumerated() {
            guard index < frames.count else {
                subview.place(at: bounds.origin, proposal: .zero)
                continue
            }
            let frame = frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

private struct AloPostMediaViewer: View {
    let media: [AloMediaItem]
    let startItem: AloMediaItem
    let onDismiss: () -> Void

    @EnvironmentObject private var app: AloAppModel
    @Environment(\.openURL) private var openURL
    /// Pages are addressed by position: a post may contain the same photo twice, and URL tags then
    /// made the pager snap back to the first copy (the "shaking" swipe that never turned the page).
    @State private var selectedIndex: Int
    @State private var notice: String?
    @State private var isZoomed = false
    @State private var chromeHidden = false
    @State private var chromeToken = 0
    @State private var dismissState = AloViewerDismissState()

    init(media: [AloMediaItem], startItem: AloMediaItem, onDismiss: @escaping () -> Void) {
        self.media = media
        self.startItem = startItem
        self.onDismiss = onDismiss
        _selectedIndex = State(initialValue: media.firstIndex(where: { $0.id == startItem.id })
            ?? media.firstIndex(where: { $0.url == startItem.url }) ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - dismissState.progress).ignoresSafeArea()

            TabView(selection: $selectedIndex) {
                ForEach(media.indices, id: \.self) { index in
                    viewerContent(for: media[index], isActive: index == selectedIndex)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: media.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            .modifier(AloViewerDismissModifier(state: $dismissState))

            // Telegram-style: one quiet top bar (close, position, menu). It hides itself after a few
            // seconds, while zoomed, and on a single tap; a tap brings it back.
            VStack {
                HStack(spacing: 10) {
                    viewerCircle("chevron.left", label: "Закрыть медиа", identifier: "alo.post.viewer.close", action: onDismiss)
                    Spacer(minLength: 0)
                    if media.count > 1 {
                        Text("\(min(selectedIndex, media.count - 1) + 1) из \(media.count)")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).frame(height: 36)
                            .modifier(AloChatGlass(interactive: false, role: .chrome))
                    }
                    Spacer(minLength: 0)
                    Menu {
                        if let url = currentAbsoluteURL {
                            ShareLink(item: url) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                        }
                        Button { copyCurrentLink() } label: { Label("Скопировать ссылку", systemImage: "link") }
                        Button { saveCurrentMedia() } label: { Label("Сохранить", systemImage: "arrow.down.to.line") }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .modifier(AloChatGlass(interactive: false, role: .chrome))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Действия с медиа")
                    .accessibilityIdentifier("alo.post.viewer.menu")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Spacer()
            }
            .opacity(chromeHidden || dismissState.offset != 0 ? 0 : 1)
            .allowsHitTesting(!chromeHidden)

            if let notice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                        .padding(.bottom, 42)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        // The feed shows through while the photo is dragged away.
        .presentationBackground(.clear)
        .task(id: chromeToken) {
            guard !chromeHidden else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = true }
        }
        .onChange(of: isZoomed) { _, zoomed in
            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = zoomed }
            if !zoomed { chromeToken += 1 }
        }
        .onChange(of: selectedIndex) { _, _ in
            chromeHidden = false
            chromeToken += 1
        }
    }

    @ViewBuilder
    private func viewerContent(for item: AloMediaItem, isActive: Bool) -> some View {
        if item.type == "video", let url = app.api.absoluteURL(item.url) {
            AloTimelineVideoPlayer(url: url, isActive: isActive, dismiss: dismissDrag)
        } else if let url = app.api.absoluteURL(item.posterUrl.ifBlank(item.url)) {
            // Pinch, double-tap and pan; a single tap hides or shows the controls.
            AloZoomableImagePage(url: url, isActive: isActive,
                onZoomChanged: { isZoomed = $0 },
                onSingleTap: { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }; chromeToken += 1 },
                dismiss: dismissDrag) { failed in
                if failed {
                    ContentUnavailableView("Не удалось открыть медиа", systemImage: "photo",
                        description: Text("Проверь соединение и открой вложение ещё раз."))
                        .foregroundStyle(AloTheme.muted)
                } else {
                    ProgressView().tint(AloTheme.accent)
                }
            }
        } else {
            ProgressView()
                .tint(AloTheme.accent)
        }
    }

    private var dismissDrag: AloViewerDismissDrag {
        AloViewerDismissDrag(changed: { dismissState.offset = $0 }, ended: { translation, velocity in
            if AloViewerDismissState.shouldDismiss(translation: translation, velocity: velocity) {
                withAnimation(.easeOut(duration: 0.2)) { dismissState.offset = translation >= 0 ? 1_000 : -1_000 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onDismiss() }
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { dismissState.offset = 0 }
            }
        })
    }

    private func viewerCircle(_ systemName: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .modifier(AloChatGlass(interactive: false, role: .chrome))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(AloControlPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var currentItem: AloMediaItem? {
        media.indices.contains(selectedIndex) ? media[selectedIndex] : media.first
    }

    private var currentAbsoluteURL: URL? {
        guard let currentItem else { return nil }
        return app.api.absoluteURL(currentItem.url)
    }

    private func copyCurrentLink() {
        guard let url = currentAbsoluteURL else { return }
        UIPasteboard.general.string = url.absoluteString
        showNotice("Ссылка скопирована")
    }

    private func saveCurrentMedia() {
        guard let item = currentItem, let url = currentAbsoluteURL else { return }
        Task {
            do {
                let downloaded: (data: Data, mimeType: String)
                if url.isFileURL {
                    downloaded = (try Data(contentsOf: url), "")
                } else {
                    downloaded = try await app.api.downloadData(from: url)
                }
                let mime = downloaded.mimeType
                if item.type == "video" || mime.hasPrefix("video/") {
                    let suffix = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
                    let localURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("alo-save-\(UUID().uuidString).\(suffix)")
                    try downloaded.data.write(to: localURL, options: .atomic)
                    UISaveVideoAtPathToSavedPhotosAlbum(localURL.path, nil, nil, nil)
                } else if let image = UIImage(data: downloaded.data) {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                }
                await MainActor.run { showNotice("Сохранено") }
            } catch {
                await MainActor.run { showNotice("Не удалось сохранить") }
            }
        }
    }

    private func showNotice(_ value: String) {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            notice = value
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.16)) {
                if notice == value {
                    notice = nil
                }
            }
        }
    }
}
