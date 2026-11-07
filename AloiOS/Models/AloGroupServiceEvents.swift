import Foundation

/// «Иван вступил(а) в группу», «Анна добавила Олега», «Пётр покинул(а) группу»: the joins and leaves a group shows
/// among its messages, as Telegram does. The server keeps them as group events
/// (`GET /api/group-chats/:id/service-events`); the site and Android word them the same way.
struct AloGroupServiceEvent: Identifiable, Equatable {
    let id: Int
    let action: String
    let createdAt: String
    let actorId: Int
    let actorName: String
    let targetId: Int
    let targetName: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        action = json.string("action")
        createdAt = json.string("createdAt")
        let actor = json.object("actor")
        actorId = actor.int("id")
        actorName = actor.string("name")
        let target = json.object("target")
        targetId = target.int("id")
        targetName = target.string("name")
    }

    var date: Date? { AloGroupServiceEvent.parse(createdAt) }

    func text(meId: Int) -> String {
        func name(_ id: Int, _ value: String) -> String { id == meId ? "Вы" : value.ifBlank("Участник") }
        let selfAction = actorId == targetId
        let youActor = actorId == meId
        let targetIsMe = targetId == meId
        switch action {
        case "member_joined":
            return targetIsMe ? "Вы вступили в группу" : "\(name(targetId, targetName)) вступил(а) в группу"
        case "member_left":
            return targetIsMe ? "Вы покинули группу" : "\(name(targetId, targetName)) покинул(а) группу"
        case "member_added":
            if selfAction { return targetIsMe ? "Вы вступили в группу" : "\(name(targetId, targetName)) вступил(а) в группу" }
            return "\(name(actorId, actorName)) \(youActor ? "добавили" : "добавил(а)") \(targetIsMe ? "вас" : name(targetId, targetName))"
        case "member_removed":
            if selfAction { return targetIsMe ? "Вы покинули группу" : "\(name(targetId, targetName)) покинул(а) группу" }
            return "\(name(actorId, actorName)) \(youActor ? "удалили" : "удалил(а)") \(targetIsMe ? "вас" : name(targetId, targetName))"
        default:
            return ""
        }
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ raw: String) -> Date? {
        fractional.date(from: raw) ?? plain.date(from: raw)
    }

    /// Lines to show before each message (by message id) and after the last one: every event goes before the first
    /// message written after it. Events older than the loaded part of the history are left out while more can load.
    static func placement(_ events: [AloGroupServiceEvent], messages: [AloChatMessage], hasOlder: Bool,
                          meId: Int) -> (before: [Int: [(id: Int, text: String)]], after: [(id: Int, text: String)]) {
        var before = [Int: [(id: Int, text: String)]]()
        var after = [(id: Int, text: String)]()
        guard !events.isEmpty else { return (before, after) }
        let dated = messages.map { ($0.id, parse($0.createdAt)) }
        let oldest = hasOlder ? dated.first?.1 : nil
        for event in events {
            let text = event.text(meId: meId)
            guard !text.isEmpty, let when = event.date else { continue }
            if let oldest, when < oldest { continue }
            if let next = dated.first(where: { ($0.1 ?? .distantPast) >= when }) {
                before[next.0, default: []].append((event.id, text))
            } else {
                after.append((event.id, text))
            }
        }
        return (before, after)
    }
}
