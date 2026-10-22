import Foundation

/// Written by the notification delegate, not by a view subscriber. In
/// particular, a cold-launch tap must outlive authentication/bootstrap.
final class AloPushOpenStore {
    static let shared = AloPushOpenStore()
    struct Entry: Codable, Equatable {
        let requestID: String
        let token: String?
        let createdAt: Date
    }
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key = "alo.push.pending-opens.v2"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func token(in payload: [AnyHashable: Any]) -> String? {
        let nested = payload["alo"] as? [String: Any] ?? [:]
        guard let value = (nested["openToken"] ?? payload["openToken"]) as? String,
              value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }

    func enqueue(requestID: String, payload: [AnyHashable: Any]) {
        lock.lock(); defer { lock.unlock() }
        var entries = read()
        guard !entries.contains(where: { $0.requestID == requestID }) else { return }
        entries.append(Entry(requestID: requestID, token: Self.token(in: payload), createdAt: Date()))
        save(Array(entries.suffix(16)))
    }

    func first() -> Entry? { lock.lock(); defer { lock.unlock() }; return read().first }
    func remove(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        save(read().filter { $0.requestID != entry.requestID })
    }
    private func read() -> [Entry] {
        guard let data = defaults.data(forKey: key), let values = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return values.filter { Date().timeIntervalSince($0.createdAt) < 90 * 86_400 }
    }
    private func save(_ entries: [Entry]) { defaults.set(try? JSONEncoder().encode(entries), forKey: key) }
}

enum AloPushDestination {
    case chat(peerId: Int, roomId: Int)
    case post(postId: Int, commentId: Int)
    case friendRequest(AloNotificationItem)
    case notifications

    init?(_ json: [String: Any]) {
        switch json.string("kind") {
        case "chat" where json.int("peerId") > 0:
            self = .chat(peerId: json.int("peerId"), roomId: max(0, json.int("roomId")))
        case "post" where json.int("postId") > 0:
            self = .post(postId: json.int("postId"), commentId: max(0, json.int("commentId")))
        case "friendRequest":
            let item = AloNotificationItem(json.object("notification"))
            guard item.id > 0, item.actionableFriendRequestId > 0 else { return nil }
            self = .friendRequest(item)
        case "notifications": self = .notifications
        default: return nil
        }
    }
}
