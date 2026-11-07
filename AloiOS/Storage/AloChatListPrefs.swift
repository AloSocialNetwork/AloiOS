import Foundation

/// Pinned and archived chats per account.
///
/// Pins belong to the account, as in Telegram: the server keeps their order (`/api/chat/pins`) and
/// this list is the device's copy of it, replaced by what the server sends. The archive stays on the device.
final class AloChatListPrefs {
    struct State: Codable, Equatable {
        var pinned: [String] = []
        var archived: [String] = []
    }

    static let maximumPinned = 5
    private let defaults: UserDefaults
    private let storageKey = "alo.chatlist.prefs.v1"
    private var states: [String: State]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: State].self, from: data) {
            states = decoded
        } else {
            states = [:]
        }
    }

    static func key(for conversation: AloConversationSummary) -> String {
        "\(conversation.kind):\(conversation.kind == "direct" ? conversation.peerId : conversation.roomId)"
    }

    func state(owner: Int) -> State { states["\(owner)"] ?? State() }

    func isPinned(owner: Int, key: String) -> Bool { state(owner: owner).pinned.contains(key) }
    func isArchived(owner: Int, key: String) -> Bool { state(owner: owner).archived.contains(key) }

    /// Returns false when the pin limit would be exceeded.
    @discardableResult
    func setPinned(owner: Int, keys: [String], pinned: Bool) -> Bool {
        var state = state(owner: owner)
        if pinned {
            let fresh = keys.filter { !state.pinned.contains($0) }
            guard state.pinned.count + fresh.count <= Self.maximumPinned else { return false }
            // A new pin goes on top, as in Telegram.
            state.pinned.insert(contentsOf: fresh, at: 0)
            state.archived.removeAll { keys.contains($0) }
        } else {
            state.pinned.removeAll { keys.contains($0) }
        }
        save(state, owner: owner)
        return true
    }

    func setArchived(owner: Int, keys: [String], archived: Bool) {
        var state = state(owner: owner)
        if archived {
            state.archived.append(contentsOf: keys.filter { !state.archived.contains($0) })
            state.pinned.removeAll { keys.contains($0) }
        } else {
            state.archived.removeAll { keys.contains($0) }
        }
        save(state, owner: owner)
    }

    /// The account's pins as the server sent them; a pinned chat leaves the archive.
    func replacePinned(owner: Int, pinned: [String]) {
        var state = state(owner: owner)
        guard state.pinned != pinned else { return }
        state.pinned = pinned
        state.archived.removeAll { pinned.contains($0) }
        save(state, owner: owner)
    }

    /// Pins made before the server kept them are sent once (`/api/chat/pins/import`); this remembers that it happened.
    func pinsImported(owner: Int) -> Bool { defaults.bool(forKey: "alo.chatlist.pinsImported.\(owner)") }
    func markPinsImported(owner: Int) { defaults.set(true, forKey: "alo.chatlist.pinsImported.\(owner)") }

    /// `pinned` of /api/chat/pins or of a `chat_pins_updated` update; nil when the field is missing.
    static func pins(from json: [String: Any]) -> [String]? {
        guard let list = json["pinned"] as? [Any] else { return nil }
        var seen = Set<String>()
        return list.compactMap { $0 as? String }.filter { key in
            key.range(of: #"^(direct|group):\d+$"#, options: .regularExpression) != nil && seen.insert(key).inserted
        }
    }

    #if DEBUG
    func replace(owner: Int, pinned: [String], archived: [String]) {
        save(State(pinned: pinned, archived: archived), owner: owner)
    }
    #endif

    private func save(_ state: State, owner: Int) {
        states["\(owner)"] = state
        if let data = try? JSONEncoder().encode(states) { defaults.set(data, forKey: storageKey) }
    }
}
