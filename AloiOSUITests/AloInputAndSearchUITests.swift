import XCTest

final class AloInputAndSearchUITests: XCTestCase {
    private func launch(_ content: String, legacy: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content,
            "-ALO_UI_MESSENGER_ACCESSIBILITY", "0", "-ALO_UI_SEARCH_INCOMING", "0",
            "-ALO_UI_LEGACY_GLASS", legacy ? "1" : "0", "-ALO_UI_REDUCE_MOTION", legacy ? "1" : "0",
            "-ALO_UI_REDUCE_TRANSPARENCY", "0", "-ALO_UI_INCREASE_CONTRAST", "0"]
        app.launch()
        return app
    }
    private func measured(_ element: XCUIElement) -> CGRect {
        let values = (element.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(values.count, 4)
        return values.count == 4 ? CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) : .zero
    }
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testCompactComposerAndVoiceCircleSwitch() {
        let app = launch("time-layout")
        let attach = app.buttons["alo.chat.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 15))
        let field = app.otherElements["alo.chat.composer.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(measured(field).height, 40, accuracy: 1)
        let record = app.buttons["alo.chat.record-send"]
        XCTAssertEqual(attach.frame.height, 44, accuracy: 1)
        XCTAssertEqual(record.frame.height, 44, accuracy: 1)
        XCTAssertEqual(attach.frame.midY, record.frame.midY, accuracy: 1)
        capture("composer-40pt-voice")
        let originalLabel = record.label
        record.tap()
        let changed = expectation(for: NSPredicate(format: "label != %@", originalLabel), evaluatedWith: record)
        wait(for: [changed], timeout: 3)
        XCTAssertEqual(record.frame.height, 44, accuracy: 1)
        capture("composer-40pt-circle")
    }
    func testSearchRevealsAndKeepsTheSharedPositionOnFocus() { checkSearch(legacy: false) }
    func testLegacySearchRevealsAndKeepsTheSharedPositionOnFocus() { checkSearch(legacy: true) }

    private func checkSearch(legacy: Bool) {
        let app = launch("social-overview", legacy: legacy)
        XCTAssertTrue(app.buttons["Поиск"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Поиск"].firstMatch.tap()
        let socialField = app.otherElements["alo.search.field"].firstMatch
        XCTAssertTrue(socialField.waitForExistence(timeout: 4))
        let standard = measured(socialField)
        XCTAssertEqual(standard.height, 40, accuracy: 1)
        app.buttons["Чаты"].firstMatch.tap()
        let input = app.textFields["alo.chats.search.input"]
        // A tucked-away lazy row may not have an accessibility element yet.
        if input.exists { XCTAssertFalse(input.isHittable, "Search must initially be tucked above the list") }
        capture(legacy ? "legacy-inbox-search-hidden" : "inbox-search-hidden")
        let list = app.scrollViews["alo.chats.scroll"]
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let to = from.withOffset(CGVector(dx: 0, dy: 72))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
        let revealed = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: input)
        wait(for: [revealed], timeout: 4)
        let field = app.otherElements["alo.chats.search.field"].firstMatch
        let beforeFocus = measured(field)
        XCTAssertEqual(beforeFocus.minX, standard.minX, accuracy: 1)
        XCTAssertEqual(beforeFocus.minY, standard.minY, accuracy: 1)
        XCTAssertEqual(beforeFocus.size.width, standard.size.width, accuracy: 1)
        XCTAssertEqual(beforeFocus.size.height, standard.size.height, accuracy: 1)
        input.tap()
        XCTAssertTrue(app.buttons["alo.chats.search.cancel"].waitForExistence(timeout: 4))
        let focused = measured(field)
        XCTAssertEqual(focused.minY, beforeFocus.minY, accuracy: 1)
        XCTAssertEqual(focused.width, beforeFocus.width, accuracy: 1)
        capture(legacy ? "legacy-inbox-search-focused" : "inbox-search-focused")
        app.buttons["alo.chats.search.cancel"].tap()
        let hidden = expectation(for: NSPredicate(format: "hittable == false"), evaluatedWith: input)
        wait(for: [hidden], timeout: 4)
    }
}
