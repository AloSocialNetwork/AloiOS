import SwiftUI

/// "Звонки": finished one-to-one calls, newest first. Missed incoming calls are red; the trailing
/// button calls back with the same kind of call.
struct AloCallHistoryView: View {
    enum Filter: Hashable { case all, missed }

    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AloCallHistoryItem] = []
    @State private var filter: Filter = .all
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var hasMore = false
    @State private var isLoadingMore = false

    private var shown: [AloCallHistoryItem] {
        filter == .all ? items : items.filter(\.isMissed)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            AloSocialSegments(values: [Filter.all, .missed], selected: $filter,
                              title: { $0 == .all ? "Все" : "Пропущенные" },
                              identifier: { $0 == .all ? "alo.calls.filter.all" : "alo.calls.filter.missed" })
                .padding(.horizontal, AloSocialMetrics.inset)
                .padding(.bottom, 6)
            content
        }
        .background(AloTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AloTheme.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Назад к чатам")
            .accessibilityIdentifier("alo.calls.back")
            AloSocialTitle(text: "Звонки").foregroundStyle(AloTheme.text)
            Spacer()
        }
        .frame(minHeight: AloSocialMetrics.controlHeight)
        .padding(.horizontal, AloSocialMetrics.inset - 8)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            ProgressView().tint(AloTheme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText, items.isEmpty {
            VStack(spacing: 12) {
                Text(errorText).font(.system(size: 15)).foregroundStyle(AloTheme.muted).multilineTextAlignment(.center)
                Button("Повторить") { Task { await load() } }.foregroundStyle(AloTheme.accent)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: filter == .missed ? "phone.arrow.down.left" : "phone")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(AloTheme.muted)
                Text(filter == .missed ? "Пропущенных звонков нет" : "Здесь появятся ваши звонки")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                Text("Позвонить можно из профиля собеседника или из чата.")
                    .font(.system(size: 14)).foregroundStyle(AloTheme.muted).multilineTextAlignment(.center)
            }
            .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { item in
                        row(item)
                        Rectangle().fill(AloTheme.separator).frame(height: 1 / UIScreen.main.scale).padding(.leading, 70)
                    }
                    if hasMore && filter == .all {
                        ProgressView().tint(AloTheme.accent).padding(16)
                            .task { await loadMore() }
                    }
                }
                .padding(.bottom, 100)
            }
            .accessibilityIdentifier("alo.calls.list")
        }
    }

    private func row(_ item: AloCallHistoryItem) -> some View {
        HStack(spacing: 12) {
            Button { app.openProfile(userId: item.peer.id) } label: {
                AloAvatar(name: item.peer.name, url: item.peer.avatarUrl, size: 44, colorSeed: String(item.peer.id))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.peer.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(item.isMissed ? Color(red: 1, green: 0.27, blue: 0.23) : AloTheme.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: item.isOutgoing ? "arrow.up.right" : "arrow.down.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(subtitle(item))
                }
                .font(.system(size: 14))
                .foregroundStyle(AloTheme.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(AloPostTimestamp.string(item.createdAt))
                .font(.system(size: 14))
                .foregroundStyle(AloTheme.muted)
            Button { app.callBack(item, video: item.isVideo) } label: {
                Image(systemName: item.isVideo ? "video" : "phone")
                    .font(.system(size: 18))
                    .foregroundStyle(AloTheme.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityLabel(item.isVideo ? "Перезвонить по видео" : "Перезвонить")
        }
        .padding(.leading, 16).padding(.trailing, 6)
        .frame(minHeight: 60)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.calls.item.\(item.id)")
    }

    private func subtitle(_ item: AloCallHistoryItem) -> String {
        // Short like Telegram; the trailing icon already says voice or video.
        switch item.outcome {
        case .completed:
            let base = item.isOutgoing ? "Исходящий" : "Входящий"
            return item.durationSeconds > 0 ? "\(base) · \(Self.duration(item.durationSeconds))" : base
        case .missed: return "Пропущенный"
        case .declined: return item.isOutgoing ? "Отклонён" : "Вы отклонили"
        case .cancelled: return "Отменённый"
        }
    }

    static func duration(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
                        : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func load() async {
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") {
            items = Self.fixture
            isLoading = false
            return
        }
#endif
        isLoading = true
        errorText = nil
        do {
            let page = try await app.api.loadCallHistory()
            items = page.items
            hasMore = page.hasMore
        } catch let error as AloAPIError {
            errorText = error.status == 404 ? "Сервер пока не поддерживает список звонков." : error.message
        } catch {
            errorText = "Не удалось загрузить звонки. Проверьте соединение."
        }
        isLoading = false
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore, let last = items.last else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let page = try? await app.api.loadCallHistory(beforeId: last.id) {
            items += page.items
            hasMore = page.hasMore
        } else {
            hasMore = false
        }
    }

#if DEBUG
    private static var fixture: [AloCallHistoryItem] {
        let now = Date()
        func item(_ id: Int, _ name: String, _ peer: Int, _ dir: String, _ type: String, _ outcome: String, _ ago: Double, _ dur: Int) -> AloCallHistoryItem {
            AloCallHistoryItem(["id": id, "direction": dir, "type": type, "outcome": outcome, "durationSeconds": dur,
                                "createdAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(-ago)),
                                "peer": ["id": peer, "name": name, "username": "u\(peer)"]])
        }
        return [
            item(6, "Мария", 990100, "incoming", "voice", "missed", 600, 0),
            item(5, "Александр", 990002, "outgoing", "video", "completed", 3_600, 754),
            item(4, "Илья", 990103, "incoming", "voice", "completed", 7_200, 63),
            item(3, "Даша", 990104, "outgoing", "voice", "cancelled", 90_000, 0),
            item(2, "Мария", 990100, "incoming", "video", "declined", 180_000, 0),
            item(1, "Анна", 990105, "outgoing", "voice", "completed", 400_000, 1_820)
        ]
    }
#endif
}
