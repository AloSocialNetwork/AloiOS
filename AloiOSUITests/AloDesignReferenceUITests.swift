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
}
