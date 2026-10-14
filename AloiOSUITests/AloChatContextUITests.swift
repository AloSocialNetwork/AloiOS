import XCTest

final class AloChatContextUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ content: String, accessible: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content]
        if accessible {
            app.launchArguments += ["-ALO_UI_LEGACY_GLASS", "1", "-ALO_UI_REDUCE_MOTION", "1",
                                    "-ALO_UI_REDUCE_TRANSPARENCY", "1"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["alo.chat.attach"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForMenuDismissal(_ app: XCUIApplication) {
        let menu = app.scrollViews["alo.message.actions"]
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 4), .completed)
    }

    func testChatPreviewHasCompactTitleAndRightAlignedActions() {
        let app = launch("forward")
        app.buttons["alo.chat.back"].tap()
        // Let the chat finish closing, otherwise the header title matches before the inbox row.
        XCTAssertTrue(app.buttons["alo.chat.back"].waitForNonExistence(timeout: 5))
        let row = app.staticTexts["Александр"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.press(forDuration: 0.6)
        let preview = app.otherElements["alo.chat.preview"]
        let actions = app.otherElements["alo.chat.preview.actions"]
        XCTAssertTrue(preview.waitForExistence(timeout: 4))
        XCTAssertTrue(actions.waitForExistence(timeout: 4))
        XCTAssertLessThanOrEqual(actions.frame.width, 251)
        XCTAssertEqual(actions.frame.maxX, preview.frame.maxX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(actions.frame.minY - preview.frame.maxY, 7)
        XCTAssertFalse(app.buttons["alo.connection.status"].exists)
        let title = app.descendants(matching: .any).matching(identifier: "alo.chat.preview.header").firstMatch
        XCTAssertTrue(title.exists)
        XCTAssertLessThanOrEqual(title.frame.height, 50)
        capture("context-inbox-title-and-actions")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.65)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 4), .completed)
        XCTAssertTrue(row.isHittable)
    }

    func testExpandedReactionSearchAndInspectionDoNotSend() {
        let app = launch("forward")
        let row = app.otherElements["alo.message.990200"]
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.12)).press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Все реакции"].waitForExistence(timeout: 4))
        capture("context-message-actions-reference")
        app.buttons["Все реакции"].tap()
        let search = app.textFields["alo.reactions.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        XCTAssertFalse(app.scrollViews["alo.message.actions"].exists)
        search.tap()
        search.typeText("огонь\n")
        XCTAssertTrue(app.buttons["Реакция 🔥"].exists)
        XCTAssertTrue(app.buttons["Реакция ❤️‍🔥"].exists)
        XCTAssertFalse(app.buttons["Реакция 👍"].exists)
        XCTAssertGreaterThanOrEqual(app.buttons["Реакция 🔥"].frame.width, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["Реакция 🔥"].frame.height, 44)
        capture("context-expanded-reactions-search")
        app.buttons["Реакция 🔥"].press(forDuration: 0.6)
        XCTAssertTrue(app.staticTexts["Реакций: 24"].waitForExistence(timeout: 4))
        capture("context-reaction-inspection-real-count")
        app.buttons["alo.reactions.inspection.back"].tap()
        XCTAssertTrue(app.buttons["Свернуть реакции"].waitForExistence(timeout: 4))
        app.buttons["Свернуть реакции"].tap()
        XCTAssertTrue(app.buttons["Ответить"].waitForExistence(timeout: 4))
        app.buttons["Ответить"].tap()
        XCTAssertTrue(app.buttons["alo.chat.attach"].waitForExistence(timeout: 4))
        waitForMenuDismissal(app)
    }

    func testReducedMotionAndOpaqueContextRemainOperable() {
        let app = launch("forward", accessible: true)
        let row = app.otherElements["alo.message.990200"]
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.12)).press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Все реакции"].waitForExistence(timeout: 4))
        capture("context-reduced-motion-opaque")
        app.buttons["Все реакции"].tap()
        XCTAssertTrue(app.textFields["alo.reactions.search"].waitForExistence(timeout: 4))
        app.buttons["Свернуть реакции"].tap()
        XCTAssertTrue(app.buttons["Ответить"].waitForExistence(timeout: 4))
        app.buttons["Ответить"].tap()
        waitForMenuDismissal(app)
    }

    func testOutgoingMenuSharesBubbleEdgeAndShortTapReactsOnce() {
        let app = launch("reaction-own")
        let row = app.otherElements["alo.message.990200"]
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        let bubble = (row.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(bubble.count, 4)
        guard bubble.count == 4 else { return }
        row.staticTexts["alo.message.body.990200"].press(forDuration: 0.6)
        let menu = app.scrollViews["alo.message.actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 4))
        XCTAssertEqual(menu.frame.width, 250, accuracy: 1)
        XCTAssertEqual(menu.frame.maxX, bubble[0] + bubble[2], accuracy: 1)
        XCTAssertTrue(app.buttons["Изменить"].exists)
        capture("context-outgoing-aligned-actions")
        app.buttons["Реакция ❤️"].tap()
        waitForMenuDismissal(app)
        XCTAssertTrue(row.buttons["❤️, 1"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "alo.reactions.inspection").firstMatch.exists)
    }
}
