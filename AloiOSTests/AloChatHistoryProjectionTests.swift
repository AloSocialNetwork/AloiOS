import Foundation
import Testing
@testable import AloiOS

@MainActor
struct AloChatHistoryProjectionTests {
    private func message(_ id: Int, body: String = "Текст", topic: Int = 0) -> AloChatMessage {
        AloChatMessage(["id": id, "body": body, "senderId": 2, "topicId": topic,
            "createdAt": "2026-10-09T10:00:00Z"])
    }

    @Test func repeatedRenderUsesOneImmutableSnapshot() {
        let messages = (0..<1_000).map { message($0) }
        let cache = AloChatHistoryProjectionCache()
        let first = cache.snapshot(messages: messages, userID: 1)
        for _ in 0..<120 {
            #expect(cache.snapshot(messages: messages, userID: 1) === first)
        }
        #expect(cache.rebuildCount == 1)
        #expect(first.messages == messages)
        #expect(first.ids.count == 1_000 && first.dayKeys.count == 1_000)
        #expect(first.byID[40]?.id == 40)
    }

    @Test func editsReactionsAndCanonicalChangesInvalidateWithoutIDChange() {
        let cache = AloChatHistoryProjectionCache()
        let initial = cache.snapshot(messages: [message(1)], userID: 1)
        let edited = cache.snapshot(messages: [message(1, body: "Исправлено")], userID: 1)
        #expect(edited !== initial && edited.messages[0].body == "Исправлено")
        let reacted = AloChatMessage(["id": 1, "body": "Исправлено", "senderId": 2,
            "reactions": [["emoji": "❤️", "count": 1]]])
        let updated = cache.snapshot(messages: [reacted], userID: 1)
        #expect(updated !== edited && updated.messages[0].reactions.count == 1)
        let poll = AloCanonicalPollState(["id": "poll", "isClosed": true])
        let closed = cache.snapshot(messages: [reacted], canonical: ["poll": poll], userID: 1)
        #expect(closed !== updated)
    }

    @Test func pollEventsStayHiddenAndSearchDoesNotRebuildPollsPerMessage() throws {
        let definition = AloPollDefinition(id: "p", question: "Куда пойдём?",
            options: [AloPollOption(id: "park", text: "Парк"), AloPollOption(id: "lake", text: "Озеро")],
            allowsMultipleAnswers: false, isQuiz: false, correctOptionIds: [], isAnonymous: true, allowsRevoting: true)
        let create = try #require(AloPollCodec.encodeCreate(definition))
        let vote = try #require(AloPollCodec.encodeVote(pollId: "p", optionIds: ["park"]))
        let messages = [message(1, body: create), message(2, body: vote), message(3)]
        let cache = AloChatHistoryProjectionCache()
        let value = cache.snapshot(messages: messages, userID: 2)
        #expect(value.ids == [1, 3])
        #expect(value.polls["p"]?.selectedOptionIds == ["park"])
        #expect(value.pollIDsByMessage[1] == "p")
        #expect(value.byID[2] == nil)
        let searched = cache.snapshot(messages: messages, userID: 2, query: " озеро ")
        #expect(searched.ids == [1])
        #expect(searched.polls == value.polls)
        #expect(cache.snapshot(messages: messages, userID: 2, query: "озеро") === searched)
    }

    @Test func topicsUserSwitchAndDayRolloverDoNotReuseStaleState() {
        let cache = AloChatHistoryProjectionCache()
        let messages = [message(1), message(2, topic: 10), message(3, topic: 20)]
        let now = Date()
        let general = cache.snapshot(messages: messages, userID: 1, topicID: 10, generalTopicID: 10, now: now)
        #expect(general.ids == [1, 2])
        let other = cache.snapshot(messages: messages, userID: 1, topicID: 20, generalTopicID: 10, now: now)
        #expect(other.ids == [3] && other !== general)
        let user = cache.snapshot(messages: messages, userID: 2, topicID: 20, generalTopicID: 10, now: now)
        #expect(user !== other)
        let tomorrow = cache.snapshot(messages: messages, userID: 2, topicID: 20, generalTopicID: 10,
            now: now.addingTimeInterval(172_800))
        #expect(tomorrow !== user)
    }

    @Test func distinctTimestampsKeepLocalDayLabelsAndMessageOrder() {
        let timestamps = ["2025-09-20T10:00:00Z", "2025-09-20T10:00:01Z",
            "2025-09-21T10:00:00Z", "2025-09-21T10:00:01Z"]
        let messages = timestamps.enumerated().map { index, timestamp in
            AloChatMessage(["id": index + 1, "senderId": 2, "body": "Текст", "createdAt": timestamp])
        }
        let value = AloChatHistoryProjectionCache().snapshot(messages: messages, userID: 1)
        #expect(value.ids == [1, 2, 3, 4])
        #expect(value.dayKeys == timestamps.map { AloFormatters.messageDayKey($0) })
        #expect(Set(value.dayKeys).count == 2)
        for message in messages {
            #expect(value.dateLabels[message.id] == AloFormatters.messageDateLabel(message.createdAt))
        }
    }
}
