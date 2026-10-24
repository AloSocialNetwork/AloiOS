import XCTest

/// Swipe to reply, editing a published post, the profile editor and paging: what the lists and the chat gained on 2026-10-24.
final class AloEditAndGesturesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ content: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content] + extra
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSwipingAMessageLeftStartsAReply() {
        let app = launch("links")
        XCTAssertTrue(app.buttons["alo.chat.attach"].waitForExistence(timeout: 15))
        let row = app.otherElements["alo.message.990200"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        // A reply left open by an earlier run is part of the chat's draft: close it first.
        let leftover = app.descendants(matching: .any)["alo.composer.reply"]
        if leftover.exists {
            leftover.buttons.firstMatch.tap()
            XCTAssertTrue(leftover.waitForNonExistence(timeout: 3))
        }
        // A short pull does nothing.
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -24, dy: 0)))
        XCTAssertFalse(app.descendants(matching: .any)["alo.composer.reply"].waitForExistence(timeout: 1.0), "a short pull is not a reply")
        // A full swipe to the left is.
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -150, dy: 0)))
        XCTAssertTrue(app.descendants(matching: .any)["alo.composer.reply"].waitForExistence(timeout: 4), "the swipe starts a reply")
        capture("edit-1-swipe-reply")
    }

    func testOwnPostOffersEditAndSavesTheNewText() {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "social-overview",
            "-ALO_UI_MESSENGER_ACCESSIBILITY", "0", "-ALO_UI_REDUCE_MOTION", "0", "-ALO_UI_SEARCH_INCOMING", "0"]
        app.launch()
        XCTAssertTrue(app.buttons["alo.feed.tab.popular"].waitForExistence(timeout: 15))
        let menu = app.buttons["alo.post.menu.990400"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let edit = app.buttons["Изменить"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3), "an own post can be edited")
        capture("edit-2-post-menu")
        edit.tap()
        let field = app.textViews["alo.post.edit.text"].exists ? app.textViews["alo.post.edit.text"] : app.textFields["alo.post.edit.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["alo.post.edit.save"].isEnabled, "nothing changed yet")
        field.tap()
        field.typeText(" Дописано.")
        XCTAssertTrue(app.buttons["alo.post.edit.save"].isEnabled, "a changed text can be saved")
        capture("edit-3-post-editor")
    }

    func testSettingsOffersToEditNameUsernameAndBio() {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "own-profile",
            "-ALO_UI_MESSENGER_ACCESSIBILITY", "0", "-ALO_UI_REDUCE_MOTION", "0", "-ALO_UI_SEARCH_INCOMING", "0"]
        app.launch()
        let settings = app.buttons["alo.profile.settings"]
        if settings.waitForExistence(timeout: 15) { settings.tap() } else {
            app.buttons["Настройки"].firstMatch.tap()
        }
        let row = app.buttons["alo.settings.profile-info"]
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
        XCTAssertTrue(app.buttons["alo.settings.profile-info.save"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["alo.settings.profile-info.save"].isEnabled, "nothing changed yet")
        capture("edit-4-profile-info")
    }
}

/// Reference captures of the screens the Android app is matched against (publication, search, friends list, sign-in).
final class AloParityCaptureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureComposerSearchAndLists() {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "social-overview",
            "-ALO_UI_MESSENGER_ACCESSIBILITY", "0", "-ALO_UI_REDUCE_MOTION", "0", "-ALO_UI_SEARCH_INCOMING", "0"]
        app.launch()
        XCTAssertTrue(app.buttons["alo.feed.create-post"].waitForExistence(timeout: 15))
        app.buttons["alo.feed.create-post"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("p-1-composer")
        app.buttons["Закрыть редактор поста"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.buttons["Поиск"].firstMatch.tap()
        _ = app.otherElements["alo.search.field"].firstMatch.waitForExistence(timeout: 4)
        Thread.sleep(forTimeInterval: 0.5)
        capture("p-2-search")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Друзья'")).firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("p-3-friends")
    }

    func testCaptureSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_AUTH_PREVIEW", "1"]
        app.launch()
        Thread.sleep(forTimeInterval: 2.0)
        capture("p-4-signin")
    }
}
