import Foundation

/// Immutable render data. Scrolling, recording meters and playback ticks must
/// not decode the same poll events or parse all history dates again.
@MainActor
final class AloChatHistorySnapshot {
    let messages: [AloChatMessage]
    let ids: [Int]
    let byID: [Int: AloChatMessage]
    let dayKeys: [String]
    let dateLabels: [Int: String]
    let dateHeaderIDs: [Int: Int]
    let dateHeaderLabels: [Int: String]
    let polls: [String: AloPollViewState]
    let pollIDsByMessage: [Int: String]

    init(messages: [AloChatMessage], polls: [String: AloPollViewState], pollIDsByMessage: [Int: String]) {
        self.messages = messages
        self.polls = polls
        self.pollIDsByMessage = pollIDsByMessage
        ids = messages.map(\.id)
        byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var keysByTimestamp = [String: String]()
        dayKeys = messages.map { message in
            if let key = keysByTimestamp[message.createdAt] { return key }
            let key = AloFormatters.messageDayKey(message.createdAt)
            keysByTimestamp[message.createdAt] = key
            return key
        }
        // "Сегодня / вчера / 9 октября" is a DAY label, not a per-message
        // calculation. Calendar/DateFormatter work once per distinct day.
        var labelsByDay = [String: String]()
        var labelsByID = [Int: String]()
        for (message, day) in zip(messages, dayKeys) {
            let label: String
            if let known = labelsByDay[day] { label = known }
            else {
                label = AloFormatters.messageDateLabel(message.createdAt)
                labelsByDay[day] = label
            }
            if labelsByID[message.id] == nil { labelsByID[message.id] = label }
        }
        dateLabels = labelsByID
        var headerIDs = [Int: Int]()
        var headerLabels = [Int: String]()
        var previousDay: String?
        var headerID = 0
        for (message, day) in zip(messages, dayKeys) {
            if day != previousDay {
                headerID = message.id
                headerLabels[headerID] = labelsByID[message.id]
                previousDay = day
            }
            headerIDs[message.id] = headerID
        }
        dateHeaderIDs = headerIDs
        dateHeaderLabels = headerLabels
    }
}

/// A single-entry, conversation-local memo (not a global account cache).
/// Full value equality includes edits, reactions, media and canonical poll
/// lifecycle changes; an ID/count-only key would leave those updates stale.
@MainActor
final class AloChatHistoryProjectionCache {
    private struct Input: Equatable {
        let messages: [AloChatMessage]
        let canonical: [String: AloCanonicalPollState]
        let userID: Int
        let topicID: Int?
        let generalTopicID: Int
        let query: String
        let localDay: Date
        let timeZone: String
        let locale: String
    }
    private var input: Input?
    private var value: AloChatHistorySnapshot?
    private(set) var rebuildCount = 0

    func snapshot(messages: [AloChatMessage], canonical: [String: AloCanonicalPollState] = [:],
                  userID: Int, topicID: Int? = nil, generalTopicID: Int = 0,
                  query: String = "", now: Date = Date()) -> AloChatHistorySnapshot {
        let next = Input(messages: messages, canonical: canonical, userID: userID,
            topicID: topicID, generalTopicID: generalTopicID,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            localDay: Calendar.current.startOfDay(for: now),
            timeZone: TimeZone.current.identifier, locale: Locale.current.identifier)
        if input == next, let value { return value }

        let scoped = messages.filter { message in
            guard let topicID else { return true }
            return (message.topicId > 0 ? message.topicId : generalTopicID) == topicID
        }
        let polls = AloPollProjection.applyingCanonical(canonical,
            to: AloPollProjection.states(messages: scoped, currentUserId: userID))
        var pollIDs = [Int: String]()
        let visible = scoped.filter { message in
            switch AloPollCodec.decode(message.body) {
            case .vote?, .reveal?: return false
            case let .create(definition)?: pollIDs[message.id] = definition.id
            case nil: break
            }
            guard !next.query.isEmpty else { return true }
            let poll = pollIDs[message.id].flatMap { polls[$0] }
            return poll?.definition.question.localizedCaseInsensitiveContains(next.query) == true ||
                poll?.definition.options.contains { $0.text.localizedCaseInsensitiveContains(next.query) } == true ||
                message.body.localizedCaseInsensitiveContains(next.query) ||
                message.attachmentName.localizedCaseInsensitiveContains(next.query) ||
                message.attachments.contains { $0.name.localizedCaseInsensitiveContains(next.query) }
        }
        let result = AloChatHistorySnapshot(messages: visible, polls: polls, pollIDsByMessage: pollIDs)
        input = next
        value = result
        rebuildCount += 1
        return result
    }
}
