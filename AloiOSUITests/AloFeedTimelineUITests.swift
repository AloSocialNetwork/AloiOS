import XCTest

final class AloFeedTimelineUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-timeline"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["alo.post.like.990400"].waitForExistence(timeout: 15))
        return app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testApprovedTimelineGeometryAndEngagement() {
        let app = launch()
        let body = app.staticTexts["alo.post.body.990400"]
        let media = app.otherElements["alo.post.media.990400"].firstMatch
        let like = app.buttons["alo.post.like.990400"]
        let repost = app.buttons["alo.post.repost.990400"]
        let comments = app.buttons["alo.post.comments.990400"]
        XCTAssertEqual(body.frame.minX, 70, accuracy: 1)
        XCTAssertEqual(media.frame.minX, body.frame.minX, accuracy: 1)
        // Post media follows its real proportions (the fixture image is 4:3), not a fixed 16:9 strip.
        XCTAssertEqual(media.frame.width / media.frame.height, 4.0 / 3.0, accuracy: 0.02)
        // Like comes first, then comment, then repost.
        XCTAssertLessThan(like.frame.minX, comments.frame.minX)
        XCTAssertLessThan(comments.frame.minX, repost.frame.minX)
        for button in [comments, repost, like] { XCTAssertGreaterThanOrEqual(button.frame.height + 0.001, 44) }
        let original = like.frame, originalBody = body.frame
        capture("feed-approved-timeline")
        XCTAssertEqual(like.value as? String, "42")
        like.tap()
        XCTAssertEqual(like.value as? String, "41")
        like.tap()
        XCTAssertEqual(like.value as? String, "42")
        repost.tap()
        XCTAssertEqual(repost.value as? String, "4")
        repost.tap()
        XCTAssertEqual(repost.value as? String, "3")
        XCTAssertEqual(like.frame, original)
        XCTAssertEqual(body.frame, originalBody)
        let picker = app.buttons["alo.feed.tab.popular"]
        let pickerFrame = picker.frame
        app.scrollViews["alo.feed.scroll"].swipeUp()
        XCTAssertEqual(picker.frame, pickerFrame)
        XCTAssertTrue(app.buttons["alo.feed.create-post"].isHittable)
        XCTAssertTrue(app.buttons["Лента"].firstMatch.isHittable)
    }
    func testCommentsOpenSendDismissAndReopen() {
        let app = launch()
        app.buttons["alo.post.comments.990400"].tap()
        let close = app.navigationBars["Публикация"].buttons.firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        let input = app.textFields["alo.comments.input"].firstMatch.exists
            ? app.textFields["alo.comments.input"].firstMatch : app.textViews["alo.comments.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 4))
        let media = app.otherElements["alo.post.media.990400"].firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 3))
        XCTAssertEqual(media.frame.minX, 16, accuracy: 1)
        XCTAssertEqual(media.frame.width, app.windows.firstMatch.frame.width - 32, accuracy: 1)
        XCTAssertGreaterThan(media.frame.height, 150)
        XCTAssertFalse(app.buttons["alo.feed.create-post"].isHittable)
        XCTAssertFalse(app.buttons["alo.comments.send"].isEnabled)
        capture("feed-full-post-and-comments")
        input.tap(); input.typeText("Красивый кадр!")
        let send = app.buttons["alo.comments.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let visible = app.staticTexts["Красивый кадр!"]
        if !visible.isHittable { app.scrollViews["alo.comments.scroll"].swipeUp() }
        XCTAssertTrue(visible.waitForExistence(timeout: 3))
        capture("feed-comments-keyboard-and-send")
        close.tap()
        XCTAssertTrue(app.buttons["alo.feed.create-post"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.buttons["alo.post.comments.990400"].value as? String, "9")
        app.buttons["alo.post.comments.990400"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        close.tap()
    }
    func testPostDetailMediaAndNativeBackSwipeRestoreFeed() {
        let app = launch()
        let bodyFrame = app.staticTexts["alo.post.body.990400"].frame
        app.buttons["alo.post.comments.990400"].tap()
        XCTAssertTrue(app.navigationBars["Публикация"].waitForExistence(timeout: 4))
        app.otherElements["alo.post.media.990400"].firstMatch.tap()
        let closeMedia = app.buttons["alo.post.viewer.close"]
        XCTAssertTrue(closeMedia.waitForExistence(timeout: 4))
        closeMedia.tap()
        XCTAssertTrue(app.navigationBars["Публикация"].waitForExistence(timeout: 4))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
            .press(forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["alo.feed.create-post"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["alo.feed.create-post"].isHittable)
        XCTAssertEqual(app.staticTexts["alo.post.body.990400"].frame, bodyFrame)
        app.buttons["alo.post.comments.990400"].tap()
        XCTAssertTrue(app.navigationBars["Публикация"].waitForExistence(timeout: 4))
        app.navigationBars["Публикация"].buttons.firstMatch.tap()
    }
    func testNativePostMenuAndMediaViewer() {
        let app = launch()
        app.buttons["alo.post.menu.990400"].tap()
        XCTAssertTrue(app.buttons["Скопировать ссылку"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Поделиться"].exists)
        capture("feed-native-post-menu")
        app.buttons["Скопировать ссылку"].tap()
        let media = app.otherElements["alo.post.media.990400"].firstMatch
        media.tap()
        XCTAssertTrue(app.buttons["alo.post.viewer.close"].waitForExistence(timeout: 4))
        capture("feed-media-viewer")
        app.buttons["alo.post.viewer.close"].tap()
    }
    func testReducedMotionAndLegacyGlassKeepTimelineUsable() {
        let app = launch(["-ALO_UI_LEGACY_GLASS", "1", "-ALO_UI_REDUCE_MOTION", "1",
                          "-ALO_UI_REDUCE_TRANSPARENCY", "1", "-ALO_UI_INCREASE_CONTRAST", "1"])
        app.buttons["alo.post.like.990400"].tap()
        app.buttons["alo.post.repost.990400"].tap()
        app.buttons["alo.feed.tab.subscriptions"].tap()
        XCTAssertTrue(app.buttons["alo.feed.tab.subscriptions"].isSelected)
        app.buttons["alo.feed.tab.popular"].tap()
        XCTAssertTrue(app.buttons["alo.feed.create-story"].isHittable)
        capture("feed-legacy-accessible-material")
    }
    func testVideoOpensAPlayerAndClosesBackToTimeline() {
        let app = launch(["-ALO_UI_MESSENGER_CONTENT", "feed-video"])
        app.otherElements["alo.post.media.990400"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["alo.post.viewer.video"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["alo.post.viewer.close"].isHittable)
        capture("feed-native-video-player")
        app.buttons["alo.post.viewer.close"].tap()
        XCTAssertTrue(app.buttons["alo.feed.create-post"].waitForExistence(timeout: 3))
    }
    func testLargeTextDoesNotCoverNavigationOrActions() {
        let app = launch(["-ALO_UI_MESSENGER_ACCESSIBILITY", "1"])
        XCTAssertTrue(app.buttons["alo.feed.tab.popular"].isHittable)
        XCTAssertTrue(app.buttons["alo.feed.create-post"].isHittable)
        let like = app.buttons["alo.post.like.990400"]
        if !like.isHittable {
            // A full inertial swipe on SE skips this very tall accessible row.
            // Use a short, slow drag and release at rest, like a reader would.
            let scroll = app.scrollViews["alo.feed.scroll"]
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.75))
                .press(forDuration: 0.02, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.55)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(like.isHittable)
        XCTAssertGreaterThanOrEqual(like.frame.height + 0.001, 44)
        capture("feed-large-text")
    }
}
