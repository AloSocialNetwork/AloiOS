import XCTest
@testable import AloiOS

final class AloPostEditTests: XCTestCase {
    private func post(_ extra: [String: Any] = [:]) -> AloPost {
        var json: [String: Any] = ["id": 7, "creatorId": 3, "body": "Привет", "createdAt": "2026-10-24T08:00:00Z",
                                   "author": ["id": 3, "name": "Автор", "username": "author"]]
        for (key, value) in extra { json[key] = value }
        return AloPost(json)
    }

    func testAPostNeverEditedHasNoEditTime() {
        XCTAssertEqual(post().editedAt, "")
    }

    func testAnEditedPostKeepsItsEditTimeAndSurvivesAnEngagementPatch() {
        let edited = post(["editedAt": "2026-10-24T09:00:00Z"])
        XCTAssertEqual(edited.editedAt, "2026-10-24T09:00:00Z")
        XCTAssertEqual(edited.withEngagement(likeCount: 5, viewerLiked: true).editedAt, "2026-10-24T09:00:00Z")
    }

    func testAPageKnowsWhereTheNextOneStarts() {
        let page = AloPage(items: [post(), post(["id": 8])], hasMore: true, nextOffset: 2)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextOffset, 2)
    }
}
