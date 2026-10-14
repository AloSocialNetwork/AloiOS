import Foundation

/// Which chats have messages the user has not opened yet.
///
/// The server reports each chat's newest message, not read receipts for the viewer, so the
/// device remembers the newest message id it has shown per chat. A chat is unread when its
/// newest message is from someone else and newer than what was last seen. The first time a chat
/// is seen it counts as read, so installing the app does not light up every conversation.
final class AloUnreadTracker {
    private let defaults: UserDefaults
    private let storageKey = "alo.unread.seen.v1"
    private let openedKey = "alo.unread.opened.v1"
    private var seen: [String: Int]
    /// Only chats actually opened here (not the first-launch baseline). Hides a stale server count
    /// between opening a chat and the next list refresh.
    private var opened: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seen = (defaults.dictionary(forKey: storageKey) as? [String: Int]) ?? [:]
        opened = (defaults.dictionary(forKey: openedKey) as? [String: Int]) ?? [:]
    }

    private func key(owner: Int, _ conversation: AloConversationSummary) -> String {
        "\(owner):\(conversation.kind):\(conversation.kind == "direct" ? conversation.peerId : conversation.roomId)"
    }

    /// Chats seen for the first time are treated as read. Returns true when anything changed.
    @discardableResult
    func establishBaseline(owner: Int, conversations: [AloConversationSummary]) -> Bool {
        var changed = false
        for conversation in conversations where conversation.lastMessageId > 0 {
            let id = key(owner: owner, conversation)
            if seen[id] == nil { seen[id] = conversation.lastMessageId; changed = true }
        }
        if changed { persist() }
        return changed
    }

    func isUnread(owner: Int, _ conversation: AloConversationSummary) -> Bool {
        guard conversation.lastMessageId > 0, conversation.lastSenderId != owner,
              let last = seen[key(owner: owner, conversation)] else { return false }
        return conversation.lastMessageId > last
    }

    /// True when this device has already shown the chat's newest message.
    func hasSeen(owner: Int, _ conversation: AloConversationSummary) -> Bool {
        guard conversation.lastMessageId > 0, let last = opened[key(owner: owner, conversation)] else { return false }
        return last >= conversation.lastMessageId
    }

    func markRead(owner: Int, _ conversation: AloConversationSummary) {
        guard conversation.lastMessageId > 0 else { return }
        let id = key(owner: owner, conversation)
        if (opened[id] ?? 0) < conversation.lastMessageId {
            opened[id] = conversation.lastMessageId
            defaults.set(opened, forKey: openedKey)
        }
        guard (seen[id] ?? 0) < conversation.lastMessageId else { return }
        seen[id] = conversation.lastMessageId
        persist()
    }

    #if DEBUG
    /// UI fixtures only: start from a known set of seen message ids.
    func replaceSeen(_ values: [String: Int]) {
        seen = values
        persist()
    }
    #endif

    private func persist() {
        defaults.set(seen, forKey: storageKey)
    }
}
