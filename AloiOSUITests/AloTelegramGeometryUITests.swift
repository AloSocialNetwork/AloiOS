import XCTest

final class AloTelegramGeometryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ content: String, reduced: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content]
        if reduced { app.launchArguments += ["-ALO_UI_MESSENGER_ACCESSIBILITY", "1"] }
        app.launch()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 15))
        return app
    }

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

    func testSingleMediaUsesReferenceAspectRatioNotFixedHeight() {
        for (mode, width, height) in [("media-landscape", 300.0, 168.75),
                                     ("media-square", 300.0, 300.0), ("media-portrait", 213.75, 380.0)] {
            let app = launch(mode)
            let media = app.descendants(matching: .any).matching(identifier: "alo.message.media.990200").firstMatch
            XCTAssertTrue(media.waitForExistence(timeout: 4))
            XCTAssertEqual(media.frame.width, width, accuracy: 1)
            XCTAssertEqual(media.frame.height, height, accuracy: 1)
            XCTAssertTrue(app.buttons["alo.chat.attach"].isHittable)
            capture(mode)
        }
    }

    func testPhotoWithoutCaptionCanBeEditedAndKeepsItsMedia() {
        let app = launch("media-edit-empty")
        let media = app.descendants(matching: .any).matching(identifier: "alo.message.media.990200").firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 4))
        media.press(forDuration: 0.65)
        // The chat list behind the chat has its own "Изменить"; this is the message menu's.
        let edit = app.buttons.matching(NSPredicate(format: "label == 'Изменить' AND identifier != 'alo.chats.select.begin'")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 4))
        edit.tap()
        let accessory = app.descendants(matching: .any).matching(identifier: "alo.composer.accessory.edit").firstMatch
        XCTAssertTrue(accessory.waitForExistence(timeout: 4))
        XCTAssertEqual(accessory.frame.height, 45, accuracy: 1)
        let save = app.buttons["alo.chat.record-send"]
        XCTAssertEqual(save.label, "Сохранить изменения")
        composer(app).tap()
        composer(app).typeText("Добавленная подпись")
        capture("media-caption-edit")
        save.tap()
        XCTAssertTrue(app.staticTexts["Добавленная подпись"].waitForExistence(timeout: 4))
        XCTAssertTrue(media.exists)
        XCTAssertEqual(save.label, "Голосовое")
        capture("media-caption-edited")
    }

    func testIdleDateNeverCoversChromeAndLeavesNaturalDatesVisible() {
        for reduced in [false, true] {
            let app = launch("date-scroll", reduced: reduced)
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "alo.chat.floating-date").firstMatch.exists)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
                .press(forDuration: 0.01,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78)),
                    withVelocity: .slow, thenHoldForDuration: 0)
            let floating = app.descendants(matching: .any).matching(identifier: "alo.chat.floating-date").firstMatch
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: floating)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 4), .completed)
            let dates = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'alo.chat.date.[0-9]+'"))
            XCTAssertGreaterThan(dates.count, 0)
            XCTAssertTrue(app.buttons["alo.chat.back"].isHittable)
            XCTAssertTrue(app.buttons["alo.chat.attach"].isHittable)
            capture(reduced ? "date-scroll-reduced-motion" : "date-scroll-idle")
        }
    }
}
