import Foundation

enum AloPendingChatProjection {
    static func removingDeletedMessages(
        from messages: [AloChatMessage],
        deletedMessageIds: Set<Int>
    ) -> [AloChatMessage] {
        guard !deletedMessageIds.isEmpty else { return messages }
        return messages.filter { !deletedMessageIds.contains($0.id) }
    }

    static func mergingPendingMessages(
        serverMessages: [AloChatMessage],
        pendingMessages: [AloChatMessage]
    ) -> [AloChatMessage] {
        guard !pendingMessages.isEmpty else { return serverMessages }
        let serverIds = Set(serverMessages.map(\.id))
        return serverMessages + pendingMessages.filter { !serverIds.contains($0.id) }
    }
}
