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

    static func applyingScheduledChanges(
        to messages: [AloChatMessage],
        canceledScheduledMessageIds: Set<Int>,
        scheduledAtByMessageId: [Int: String]
    ) -> [AloChatMessage] {
        messages.compactMap { message in
            let scheduledMessageId = message.scheduledMessageId
            if scheduledMessageId > 0,
               canceledScheduledMessageIds.contains(scheduledMessageId) {
                return nil
            }
            guard scheduledMessageId > 0,
                  let scheduledAt = scheduledAtByMessageId[scheduledMessageId] else {
                return message
            }
            return message.replacingSchedule(scheduledAt)
        }
    }

    // Keeps an acknowledged server snapshot visually consistent with the durable
    // outbox while an edit still waits for a network acknowledgement.
    static func applyingPendingEdits(
        to messages: [AloChatMessage],
        bodyByMessageId: [Int: String],
        editedAt: String
    ) -> [AloChatMessage] {
        guard !bodyByMessageId.isEmpty else { return messages }
        return messages.map { message in
            guard let body = bodyByMessageId[message.id] else { return message }
            return message.replacingBody(body, editedAt: editedAt)
        }
    }

    // Rebuilds the local user's desired reaction from a fresh server snapshot.
    // The server remains authoritative for everyone else's reaction counts.
    /// `me` keeps the avatars on the chips right: the local user joins or leaves the people who reacted.
    static func applyingDesiredReactions(
        to messages: [AloChatMessage],
        desiredEmojiByMessageId: [Int: String],
        me: AloConversationPeer? = nil
    ) -> [AloChatMessage] {
        guard !desiredEmojiByMessageId.isEmpty else { return messages }
        return messages.map { message in
            guard let desiredEmoji = desiredEmojiByMessageId[message.id] else { return message }
            return message.replacingReactions(
                reactions(afterSetting: desiredEmoji, on: message.reactions, me: me)
            )
        }
    }

    private static func reactions(
        afterSetting desiredEmoji: String,
        on reactions: [AloMessageReaction],
        me: AloConversationPeer?
    ) -> [AloMessageReaction] {
        let withoutMe: ([AloConversationPeer]) -> [AloConversationPeer] = { users in
            guard let me else { return users }
            return users.filter { $0.id != me.id }
        }
        let withMe: ([AloConversationPeer]) -> [AloConversationPeer] = { users in
            guard let me, !users.contains(where: { $0.id == me.id }) else { return users }
            return users + [me]
        }
        var updated = reactions.compactMap { reaction -> AloMessageReaction? in
            if reaction.reactedByMe {
                guard !desiredEmoji.isEmpty, reaction.emoji == desiredEmoji else {
                    let count = reaction.count - 1
                    guard count > 0 else { return nil }
                    return AloMessageReaction(
                        emoji: reaction.emoji,
                        count: count,
                        reactedByMe: false,
                        users: withoutMe(reaction.users)
                    )
                }
                return reaction
            }
            if !desiredEmoji.isEmpty, reaction.emoji == desiredEmoji {
                return AloMessageReaction(
                    emoji: reaction.emoji,
                    count: reaction.count + 1,
                    reactedByMe: true,
                    users: withMe(reaction.users)
                )
            }
            return reaction
        }
        if !desiredEmoji.isEmpty,
           !reactions.contains(where: { $0.emoji == desiredEmoji }) {
            updated.append(AloMessageReaction(emoji: desiredEmoji, count: 1, reactedByMe: true, users: withMe([])))
        }
        return updated
    }
}
