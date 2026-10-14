import Foundation

/// Pinned and archived chats, kept on this device per account.
///
/// The server only pins *messages*, not whole chats, and has no archive, so these two lists live
/// locally and do not follow the account to another device.
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
            state.pinned.append(contentsOf: fresh)
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
