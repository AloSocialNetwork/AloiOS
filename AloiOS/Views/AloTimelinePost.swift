import SwiftUI

/// Frequent feed actions use a small local press, not the large glass-panel
/// stretch. No UIKit gesture observer/player is installed in a scrolling row.
struct AloFeedPressStyle: ButtonStyle {
    private var accessibility = AloVisualAccessibility()
    init() {}
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !accessibility.reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(accessibility.reduceMotion ? nil : AloPressFeedback.release, value: configuration.isPressed)
    }
}

/// The approved timeline: avatar at 16, content at 70, no enclosing card.
/// Native menus/sheets retain dismissal, focus and interruption behaviour.
/// Takes plain values, not the app model, and compares equal by them: scrolling and unrelated app
/// updates no longer rebuild every visible post (use it with `.equatable()`).
struct AloTimelinePost: View, Equatable {
    enum Presentation { case timeline, detail }
    let post: AloPost
    var presentation: Presentation = .timeline
    var isMine = false
    var isLikePending = false
    var isRepostPending = false
    var onDelete: () -> Void = {}
    var onNotice: (String) -> Void = { _ in }
    let onLike: () -> Void
    let onComment: () -> Void
    let onRepost: () -> Void
    let onAuthor: () -> Void
    @State private var confirmsDeletion = false

    static func == (lhs: AloTimelinePost, rhs: AloTimelinePost) -> Bool {
        lhs.post == rhs.post && lhs.presentation == rhs.presentation && lhs.isMine == rhs.isMine
            && lhs.isLikePending == rhs.isLikePending && lhs.isRepostPending == rhs.isRepostPending
    }
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .body) private var bodySize = 15
    @ScaledMetric(relativeTo: .body) private var detailBodySize = 17
    @ScaledMetric(relativeTo: .caption) private var metadataSize = 12

    var body: some View {
        Group {
            if presentation == .detail {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        authorAvatar
                        header
                    }
                    postContent
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    authorAvatar
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        postContent
                    }
                }
            }
        }
        // The 44-pt avatar hit target starts at 14; its visible image at 15.
        .padding(.horizontal, presentation == .detail ? 16 : 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AloTheme.feedDivider).frame(height: 0.5)
        }
        .confirmationDialog("Удалить пост?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Удалить пост", role: .destructive) { onDelete() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.post.card.\(post.id)")
    }

    private var authorAvatar: some View {
        Button(action: onAuthor) {
            AloAvatar(name: post.author.name, url: post.author.avatarUrl,
                      size: 42, colorSeed: String(post.author.id)).frame(width: 44, height: 44)
        }
        .buttonStyle(AloFeedPressStyle())
        .accessibilityLabel("Профиль: \(post.author.name)")
    }

    private var postContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !post.body.isEmpty {
                let markup = AloMessageMarkup.parse(post.body)
                AloRichMessageText(body: markup.body, entities: markup.entities,
                                   fontSize: presentation == .detail ? detailBodySize : bodySize)
                    .padding(.top, presentation == .detail ? 6 : 3)
                    .accessibilityIdentifier("alo.post.body.\(post.id)")
            }
            if !post.media.isEmpty {
                AloPostMediaGrid(media: post.media, timeline: true)
                    .padding(.top, 10)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("alo.post.media.\(post.id)")
            }
            if !post.authorSignature.isEmpty {
                Text(post.authorSignature).font(.caption)
                    .foregroundStyle(AloTheme.muted).padding(.top, 6)
            }
            actions.padding(.top, 2)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: onAuthor) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) { authorName; metadata }
                    VStack(alignment: .leading, spacing: 1) { authorName; metadata }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            Menu {
                if let link = AloDeepLinkTarget.postURL(postId: post.id) {
                    ShareLink(item: link) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                    Button {
                        UIPasteboard.general.string = link.absoluteString
                        onNotice("Ссылка на пост скопирована.")
                    } label: { Label("Скопировать ссылку", systemImage: "link") }
                }
                if isMine {
                    Button(role: .destructive) { confirmsDeletion = true } label: {
                        Label("Удалить пост", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloFeedPressStyle())
            .accessibilityLabel("Действия с постом")
            .accessibilityIdentifier("alo.post.menu.\(post.id)")
            // Keep a 44-pt touch area without a 44-pt blank header line.
            .padding(.vertical, -10)
            .padding(.trailing, -10)
        }
    }

    private var authorName: some View {
        HStack(spacing: 4) {
            Text(post.author.name).font(.system(size: presentation == .detail ? detailBodySize : bodySize, weight: .bold))
                .foregroundStyle(AloTheme.text).lineLimit(1)
            if post.author.verified {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AloTheme.accent)
            }
        }
    }

    private var metadata: some View {
        Text([post.author.username.withAtPrefix, AloPostTimestamp.string(post.createdAt)]
            .filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.system(size: metadataSize, weight: .regular))
            .foregroundStyle(AloTheme.muted).lineLimit(dynamicType.isAccessibilitySize ? 2 : 1)
    }

    /// Like first, then comment and repost; views stay on the trailing edge.
    private var actions: some View {
        HStack(spacing: 6) {
            Button(action: onLike) {
                AloPostActionLabel(count: post.likeCount, icon: post.viewerLiked ? "heart.fill" : "heart",
                                   selected: post.viewerLiked, tint: Color(red: 1, green: 0.2, blue: 0.38), iconSize: 19)
            }
            .disabled(isLikePending)
            .accessibilityLabel(post.viewerLiked ? "Убрать лайк" : "Поставить лайк")
            .accessibilityValue("\(post.likeCount)")
            .accessibilityIdentifier("alo.post.like.\(post.id)")
            Button(action: onComment) {
                AloPostActionLabel(count: post.commentCount, icon: post.commentsEnabled ? "bubble.left" : "lock.fill", iconSize: 18)
            }
            .disabled(!post.commentsEnabled)
            .accessibilityLabel(post.commentsEnabled ? "Комментарии" : "Комментарии отключены")
            .accessibilityValue("\(post.commentCount)")
            .accessibilityIdentifier("alo.post.comments.\(post.id)")
            Button(action: onRepost) {
                AloPostActionLabel(count: post.repostCount, icon: "arrow.2.squarepath",
                                   selected: post.viewerReposted, tint: Color(red: 0.2, green: 0.78, blue: 0.45), iconSize: 18)
            }
            .disabled(isRepostPending)
            .accessibilityLabel(post.viewerReposted ? "Убрать репост" : "Сделать репост")
            .accessibilityValue("\(post.repostCount)")
            .accessibilityIdentifier("alo.post.repost.\(post.id)")
            AloPostActionLabel(count: post.viewCount, icon: "eye", alignment: .trailing, iconSize: 17)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Просмотры").accessibilityValue("\(post.viewCount)")
        }
        .buttonStyle(AloFeedPressStyle())
        .sensoryFeedback(.selection, trigger: post.viewerLiked)
        .sensoryFeedback(.selection, trigger: post.viewerReposted)
    }
}

/// No per-row timers: timestamps update on a refresh, not 60 times a second.
@MainActor enum AloPostTimestamp {
    private static let iso = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static func string(_ raw: String, now: Date = Date()) -> String {
        guard let date = fractional.date(from: raw) ?? iso.date(from: raw) else { return String(raw.prefix(10)) }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "сейчас" }
        if seconds < 3600 { return "\(seconds / 60) мин" }
        if seconds < 86400 { return "\(seconds / 3600) ч" }
        if seconds < 604800 { return "\(seconds / 86400) д" }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU")))
    }
}
