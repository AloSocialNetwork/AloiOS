import XCTest
@testable import AloiOS

/// CPU-only benchmark of the history projection, NOT an FPS measurement.
/// Same input and iteration count for the old render path and the new memo.
@MainActor
final class AloChatHistoryPerformanceTests: XCTestCase {
    private func messages() -> [AloChatMessage] {
        let definition = AloPollDefinition(id: "performance-poll", question: "Планы на выходные?",
            options: [AloPollOption(id: "park", text: "Парк"), AloPollOption(id: "lake", text: "Озеро")],
            allowsMultipleAnswers: false, isQuiz: false, correctOptionIds: [], isAnonymous: true, allowsRevoting: true)
        let poll = AloPollCodec.encodeCreate(definition) ?? ""
        return (0..<1_000).map { index in
            AloChatMessage(["id": index, "senderId": 2,
                "body": index.isMultiple(of: 10) ? poll : "Сообщение номер \(index)",
                "createdAt": String(format: "2026-10-09T10:%02d:%02dZ", index / 60, index % 60)])
        }
    }

    func testUncachedHistoryRenderBaseline() {
        let items = messages()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            for _ in 0..<30 {
                let visible = AloPollProjection.visibleMessages(items)
                let polls = AloPollProjection.states(messages: items, currentUserId: 1)
                let days = visible.map { AloFormatters.messageDayKey($0.createdAt) }
                let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                XCTAssertEqual(visible.count + days.count + byID.count + polls.count, 3_001)
            }
        }
    }

    func testCachedHistoryRender() {
        let items = messages()
        let cache = AloChatHistoryProjectionCache()
        _ = cache.snapshot(messages: items, userID: 1) // Initial load is not a render tick.
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            for _ in 0..<30 {
                let snapshot = cache.snapshot(messages: items, userID: 1)
                XCTAssertEqual(snapshot.messages.count + snapshot.dayKeys.count + snapshot.byID.count + snapshot.polls.count, 3_001)
            }
        }
        XCTAssertEqual(cache.rebuildCount, 1)
    }

    func testCopiedButUnchangedHistoryRender() {
        let items = messages()
        // Refresh can return equal values in DIFFERENT array storage. Include
        // the full equality cost; don't benchmark only Array's shared-buffer fast path.
        let copies = (0..<30).map { _ in items.map { $0 } }
        let cache = AloChatHistoryProjectionCache()
        _ = cache.snapshot(messages: items, userID: 1)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            for copy in copies {
                let snapshot = cache.snapshot(messages: copy, userID: 1)
                XCTAssertEqual(snapshot.messages.count, 1_000)
            }
        }
        XCTAssertEqual(cache.rebuildCount, 1)
    }

    func testColdHistorySnapshot() {
        let items = messages()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            let cache = AloChatHistoryProjectionCache()
            let snapshot = cache.snapshot(messages: items, userID: 1)
            XCTAssertEqual(snapshot.messages.count, 1_000)
        }
    }
}
