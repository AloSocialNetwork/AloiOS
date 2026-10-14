import Testing
@testable import AloiOS

struct AloNotificationContractTests {
    @Test func friendRequestUsesEntityIDNotNotificationID() {
        let item = AloNotificationItem(["id": 70, "type": "friend_request", "entityType": "friend_request",
            "entityId": 12, "friendRequestActionable": true])
        #expect(item.id == 70)
        #expect(item.actionableFriendRequestId == 12)
        #expect(item.withRead(true).actionableFriendRequestId == 12)
    }
    @Test func readingPreservesNavigationTarget() {
        let item = AloNotificationItem(["id": 8, "type": "like", "entityType": "post", "entityId": 32])
        let read = item.withRead(true)
        #expect(read.isRead)
        #expect(read.entityType == "post")
        #expect(read.entityId == 32)
    }
    @Test func missingOrInactiveRequestIsNotActionable() {
        #expect(AloNotificationItem(["id": 70, "friendRequestActionable": true]).actionableFriendRequestId == 0)
        #expect(AloNotificationItem(["entityId": 12, "friendRequestActionable": false]).actionableFriendRequestId == 0)
    }
    @Test @MainActor func filtersAndGroupingPreserveChronology() {
        let items = [
            AloNotificationItem(["id": 1, "type": "like", "createdAt": "2026-10-12T11:00:00Z"]),
            AloNotificationItem(["id": 2, "type": "comment", "createdAt": "2026-10-13T10:00:00Z"]),
            AloNotificationItem(["id": 3, "type": "friend_request", "createdAt": "2026-10-13T11:00:00Z"])]
        let all = AloNotificationSection.grouped(items, filter: .all)
        #expect(all.count == 2)
        #expect(all[0].items.map(\.id) == [3, 2])
        #expect(AloNotificationSection.grouped(items, filter: .replies).flatMap(\.items).map(\.id) == [2])
        #expect(AloNotificationSection.grouped(items, filter: .reactions).flatMap(\.items).map(\.id) == [1])
    }
}
