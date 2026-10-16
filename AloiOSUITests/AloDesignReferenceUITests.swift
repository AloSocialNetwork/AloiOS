import XCTest

/// Reference screenshots of the offline fixture, compared screen by screen with the Android client.
final class AloDesignReferenceUITests: XCTestCase {
    private func launch(_ content: String, _ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content] + arguments
        app.launch()
        return app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testFeedReference() {
        let app = launch("feed-timeline", ["-ALO_UI_FEED_ADS", "1"])
        XCTAssertTrue(app.buttons["alo.post.like.990400"].waitForExistence(timeout: 15))
        sleep(1)
        capture("ref-feed-top")
        app.scrollViews["alo.feed.scroll"].swipeUp()
        sleep(1)
        capture("ref-feed-scrolled")
        app.scrollViews["alo.feed.scroll"].swipeUp()
        sleep(1)
        capture("ref-feed-scrolled-2")
    }
    func testPostDetailReference() {
        let app = launch("feed-timeline")
        XCTAssertTrue(app.buttons["alo.post.comments.990400"].waitForExistence(timeout: 15))
        app.buttons["alo.post.comments.990400"].tap()
        XCTAssertTrue(app.navigationBars["Публикация"].waitForExistence(timeout: 4))
        sleep(1)
        capture("ref-post-detail")
        app.scrollViews["alo.comments.scroll"].swipeUp()
        sleep(1)
        capture("ref-post-detail-comments")
    }
    func testChatReference() {
        let app = launch("plain")
        sleep(3)
        capture("ref-chat")
        let list = launch("chat-list")
        _ = list.wait(for: .runningForeground, timeout: 10)
        sleep(3)
        capture("ref-chat-list")
    }
    func testAlertsAndSettingsReference() {
        let app = launch("notifications", ["-ALO_UI_ADMIN", "1"])
        let alertsTab = app.buttons["Уведы"].firstMatch
        XCTAssertTrue(alertsTab.waitForExistence(timeout: 15))
        alertsTab.tap()
        XCTAssertTrue(app.buttons["alo.alerts.filter.all"].waitForExistence(timeout: 6))
        sleep(1)
        capture("ref-alerts")
        app.buttons["alo.alerts.filter.replies"].tap()
        sleep(1)
        capture("ref-alerts-replies")
        app.buttons["alo.alerts.filter.all"].tap()

        app.buttons["Профиль"].firstMatch.tap()
        XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 4))
        app.buttons["alo.profile.settings"].tap()
        XCTAssertTrue(app.buttons["Закрыть настройки"].waitForExistence(timeout: 4))
        sleep(1)
        capture("ref-settings-root")
        for (title, name) in [("Безопасность", "security"), ("Приватность", "privacy"), ("Уведомления", "notifications"), ("Бизнес-профиль", "business")] {
            app.buttons[title].firstMatch.tap()
            XCTAssertTrue(app.buttons["Назад к настройкам"].waitForExistence(timeout: 4))
            sleep(1)
            capture("ref-settings-\(name)")
            app.swipeUp()
            sleep(1)
            capture("ref-settings-\(name)-2")
            app.swipeUp()
            sleep(1)
            capture("ref-settings-\(name)-3")
            app.buttons["Назад к настройкам"].tap()
            XCTAssertTrue(app.buttons["Закрыть настройки"].waitForExistence(timeout: 4))
        }
    }
    func testSignInReference() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_AUTH_PREVIEW", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["alo.auth.qr-scan"].waitForExistence(timeout: 20))
        sleep(1)
        capture("ref-auth-login")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Создать")).firstMatch.tap()
        sleep(1)
        capture("ref-auth-register")
    }
    func testSearchAndProfileReference() {
        let app = launch("social-overview")
        let searchTab = app.buttons["Поиск"].firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15))
        searchTab.tap()
        XCTAssertTrue(app.textFields["alo.search.input"].waitForExistence(timeout: 6))
        sleep(1)
        capture("ref-search")
        let input = app.textFields["alo.search.input"]
        input.tap(); input.typeText("Алекс")
        sleep(2)
        capture("ref-search-results")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Александр")).firstMatch
        if result.waitForExistence(timeout: 4) {
            result.tap()
            sleep(2)
            capture("ref-user-profile")
            app.swipeUp()
            sleep(1)
            capture("ref-user-profile-2")
        }
    }
}
