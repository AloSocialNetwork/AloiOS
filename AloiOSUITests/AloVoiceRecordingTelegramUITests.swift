import XCTest

/// Screenshots of every voice-recording state, laid out as Telegram iOS (05.11.2026).
/// Held states come from the `-ALO_UI_VOICE_RECORDING` fixture (no microphone); lock, pause
/// and preview are real gestures on the simulator.
final class AloVoiceRecordingTelegramUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(_ state: String? = nil, content: String = "") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content]
        if let state { app.launchArguments += ["-ALO_UI_VOICE_RECORDING", state] }
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFixtureStates() {
        for state in ["held", "slide", "lift", "locked"] {
            let app = launch(state, content: "reaction-short")
            let panel = app.descendants(matching: .any)["alo.recording.panel"]
            XCTAssertTrue(panel.waitForExistence(timeout: 15), state)
            if state == "locked" {
                XCTAssertTrue(app.buttons["Завершить и прослушать запись"].exists)
                XCTAssertTrue(app.buttons["alo.recording.send"].exists)
            } else {
                XCTAssertTrue(app.buttons["alo.recording.lock"].exists)
            }
            capture("voice-\(state)")
            app.terminate()
        }
    }

    func testRealLockPauseAndPreview() {
        let app = launch(content: "reaction-short")
        let record = app.buttons["alo.chat.record-send"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        let origin = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.7, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -115)),
                     withVelocity: .slow, thenHoldForDuration: 0.15)
        let pause = app.buttons["Завершить и прослушать запись"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        capture("voice-real-locked")
        pause.tap()
        let play = app.buttons["alo.recording.preview-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        XCTAssertEqual(record.label, "Отправить")
        capture("voice-preview")
        play.tap()
        Thread.sleep(forTimeInterval: 0.5)
        capture("voice-preview-playing")
        app.buttons["Удалить черновик записи"].tap()
        XCTAssertTrue(record.waitForExistence(timeout: 4))
    }

    /// The secret chat reuses the same recording parts: lock, pause, preview.
    func testSecretChatLockPauseAndPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "chat-list",
                               "-ALO_UI_SECRET_PREVIEW", "chat"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["alo.secret.screen"].waitForExistence(timeout: 15))
        let record = app.buttons["alo.chat.record-send"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        let origin = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.7, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -115)),
                     withVelocity: .slow, thenHoldForDuration: 0.15)
        let pause = app.buttons["Завершить и прослушать запись"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["alo.secret.record.send"].exists)
        Thread.sleep(forTimeInterval: 1.5)
        capture("secret-locked")
        pause.tap()
        let play = app.buttons["alo.recording.preview-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        capture("secret-preview")
        app.buttons["Удалить черновик записи"].tap()
        XCTAssertTrue(record.waitForExistence(timeout: 4))
        capture("secret-after-delete")
    }
}
