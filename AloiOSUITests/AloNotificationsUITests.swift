import XCTest

final class AloNotificationsUITests: XCTestCase {
    func testApprovedNotificationsFilterAndSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "notifications"]
        app.launch()
        let comment = app.buttons["alo.alerts.item.990900"]
        XCTAssertTrue(comment.waitForExistence(timeout: 15))
        XCTAssertEqual(comment.value as? String, "Непрочитанное")
        XCTAssertTrue(app.buttons["Принять"].exists)
        XCTAssertGreaterThanOrEqual(app.buttons["Принять"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["Отклонить"].frame.height, 44)
        for filter in ["all", "replies", "reactions"] {
            XCTAssertGreaterThanOrEqual(app.buttons["alo.alerts.filter.\(filter)"].frame.height, 44)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "notifications-approved-native"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["alo.alerts.filter.reactions"].tap()
        XCTAssertTrue(app.buttons["alo.alerts.filter.reactions"].isSelected)
        XCTAssertTrue(app.buttons["alo.alerts.item.990901"].exists)
        let removedComment = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: comment)
        wait(for: [removedComment], timeout: 3)
        XCTAssertFalse(app.buttons["Принять"].exists)
        app.buttons["alo.alerts.filter.replies"].tap()
        XCTAssertTrue(comment.exists)
        let removedLike = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["alo.alerts.item.990901"])
        wait(for: [removedLike], timeout: 3)
        app.buttons["alo.alerts.settings"].tap()
        XCTAssertTrue(app.staticTexts["Основные"].waitForExistence(timeout: 4))
        app.buttons["Назад к настройкам"].tap()
        app.buttons["Закрыть настройки"].tap()
        XCTAssertTrue(comment.waitForExistence(timeout: 4))
    }
}
