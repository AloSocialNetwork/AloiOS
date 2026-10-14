import XCTest

final class AloChatHistoryNavigationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (elementType == %d OR elementType == %d)",
            "alo.chat.composer", XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue
        )).firstMatch
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDownButtonSharesComposerColumnAndRevealsLatestAboveKeyboard() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "unread-navigation"]
        app.launch()
        let input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        let down = app.buttons["alo.chat.scroll-bottom"]
        let record = app.buttons["alo.chat.record-send"]
        XCTAssertFalse(down.exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                   withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(down.waitForExistence(timeout: 4))
        XCTAssertEqual(down.value as? String, "Непрочитанных сообщений: 2")
        XCTAssertEqual(down.frame.midX, record.frame.midX, accuracy: 0.5)
        capture("history-aligned-before-keyboard")

        input.tap()
        input.typeText("Черновик")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(down.isHittable)
        XCTAssertEqual(down.value as? String, "Непрочитанных сообщений: 2",
                       "Opening a keyboard must not mark occluded messages as read")
        XCTAssertEqual(down.frame.midX, record.frame.midX, accuracy: 0.5)
        XCTAssertLessThan(down.frame.maxY, input.frame.minY)
        capture("history-aligned-with-keyboard")

        down.tap()
        let latest = app.staticTexts["Новое тестовое сообщение 2"]
        let revealed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            latest.exists && latest.isHittable && latest.frame.maxY < input.frame.minY
        }, object: latest)
        let result = XCTWaiter.wait(for: [revealed], timeout: 5)
        capture("history-latest-above-keyboard")
        if result != .completed { print(app.debugDescription) }
        XCTAssertEqual(result, .completed, "Latest incoming message must be visible, not underneath the composer/keyboard")
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: down)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 4), .completed)
        XCTAssertTrue((input.value as? String ?? "").contains("Черновик"))
        XCTAssertTrue(app.buttons["alo.chat.attach"].isHittable)
    }
}
