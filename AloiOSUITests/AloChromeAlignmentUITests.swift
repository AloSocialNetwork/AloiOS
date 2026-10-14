import XCTest

final class AloChromeAlignmentUITests: XCTestCase {
    private func launch(_ content: String, largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content,
            "-ALO_UI_MESSENGER_ACCESSIBILITY", largeText ? "1" : "0",
            "-ALO_UI_LEGACY_GLASS", "0", "-ALO_UI_REDUCE_MOTION", largeText ? "1" : "0",
            "-ALO_UI_REDUCE_TRANSPARENCY", "0", "-ALO_UI_INCREASE_CONTRAST", "0"]
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
    }

    func testPhotoCloseUsesChatBackPositionIncludingLargeText() {
        for largeText in [false, true] {
            checkMedia(content: "media-landscape", messageID: 990200, largeText: largeText)
        }
    }

    func testVideoCloseUsesChatBackPosition() {
        checkMedia(content: "media", messageID: 990201, largeText: false)
    }

    private func checkMedia(content: String, messageID: Int, largeText: Bool) {
        let app = launch(content, largeText: largeText)
        let back = app.buttons["alo.chat.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        let originalFrame = back.frame
        let media = app.descendants(matching: .any).matching(identifier: "alo.message.media.\(messageID)").firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 4))
        XCTAssertTrue(media.isHittable)
        media.tap()
        let close = app.buttons["alo.media.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        assertSameFrame(close.frame, originalFrame)
        XCTAssertTrue(close.isHittable)
        capture("aligned-\(content)-\(largeText ? "large-text" : "regular")")
        close.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        assertSameFrame(back.frame, originalFrame)
        app.terminate()
    }

    /// Settings is a pushed screen with the chat's glass Back in the same place, on every page.
    func testSettingsBackUsesChatBackPosition() {
        var app = launch("media-landscape")
        let chatBack = app.buttons["alo.chat.back"]
        XCTAssertTrue(chatBack.waitForExistence(timeout: 15))
        let expected = chatBack.frame
        app.terminate()

        app = launch("social-overview")
        app.buttons["Профиль"].firstMatch.tap()
        XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 4))
        app.buttons["alo.profile.settings"].tap()
        let back = app.buttons["alo.settings.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        assertSameFrame(back.frame, expected)
        app.buttons["Приватность"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Назад к настройкам"].waitForExistence(timeout: 4))
        assertSameFrame(app.buttons["Назад к настройкам"].frame, expected)
        app.buttons["Назад к настройкам"].tap()
        XCTAssertTrue(app.buttons["Закрыть настройки"].waitForExistence(timeout: 4))
        app.buttons["Закрыть настройки"].tap()
        XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 4))
    }

    func testFeedAndNotificationOvalsSharePositionAndSize() {
        for largeText in [false, true] {
            let app = launch("social-overview", largeText: largeText)
            let popular = app.buttons["alo.feed.tab.popular"]
            let subscriptions = app.buttons["alo.feed.tab.subscriptions"]
            XCTAssertTrue(popular.waitForExistence(timeout: 15))
            // The identical shared segment component adds 4pt on both outer
            // edges. Comparing the complete button row compares both ovals.
            let feedFrame = popular.frame.union(subscriptions.frame)
            capture("aligned-feed-\(largeText ? "large-text" : "regular")")
            app.buttons["Уведы"].firstMatch.tap()
            let all = app.buttons["alo.alerts.filter.all"]
            let reactions = app.buttons["alo.alerts.filter.reactions"]
            XCTAssertTrue(all.waitForExistence(timeout: 4))
            assertSameFrame(all.frame.union(reactions.frame), feedFrame)
            capture("aligned-notifications-\(largeText ? "large-text" : "regular")")
            app.terminate()
        }
    }
}
