import XCTest

/// «Aa» on voice messages and circles, «Перевести» in the message menu, the one-time consent and its switch in settings.
/// The debug fixture answers these requests itself (no server): see `AloContentToolsFixtureTransport`.
final class AloContentToolsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ content: String, tools: Bool = true, consent: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content,
                                "-ALO_UI_CONTENT_TOOLS", tools ? "1" : "0", "-ALO_UI_CONTENT_CONSENT", consent ? "1" : "0"] + extra
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func transcribe(_ content: String, message: Int, name: String) {
        let app = launch(content)
        XCTAssertTrue(app.buttons["alo.chat.attach"].waitForExistence(timeout: 15))
        let pill = app.buttons["alo.transcribe.\(message)"]
        XCTAssertTrue(pill.waitForExistence(timeout: 8), "a voice message and a circle offer «Aa»")
        XCTAssertEqual(pill.label, "Расшифровать")
        capture("\(name)-1-aa")

        pill.tap()
        let consent = app.alerts["Расшифровать запись?"]
        XCTAssertTrue(consent.waitForExistence(timeout: 4), "the first request asks")
        XCTAssertFalse(app.staticTexts["alo.transcript.\(message)"].exists, "nothing is sent before the answer")
        capture("\(name)-2-consent")
        consent.buttons["Отмена"].tap()
        XCTAssertTrue(consent.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["alo.transcript.\(message)"].exists)

        pill.tap()
        XCTAssertTrue(consent.waitForExistence(timeout: 4))
        consent.buttons["Разрешить"].tap()
        // The fixture takes a moment, long enough to see the dots.
        usleep(350_000)
        capture("\(name)-3-loading")
        let transcript = app.staticTexts["alo.transcript.\(message)"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 6), "the text appears under the message")
        XCTAssertTrue(transcript.label.contains("пример расшифровки"), transcript.label)
        usleep(1_200_000)
        capture("\(name)-4-text")

        XCTAssertEqual(pill.label, "Скрыть расшифровку")
        pill.tap()
        XCTAssertTrue(transcript.waitForNonExistence(timeout: 4), "a second tap folds the text away")
        XCTAssertEqual(pill.label, "Расшифровать")
        pill.tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 4), "and a third brings it back without asking again")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testVoiceMessageTurnsIntoText() { transcribe("voice", message: 990200, name: "tools-voice") }

    func testVideoCircleTurnsIntoText() { transcribe("circle", message: 990200, name: "tools-circle") }

    func testTranslatingAMessageFromItsMenu() {
        let app = launch("chat")
        XCTAssertTrue(app.buttons["alo.chat.attach"].waitForExistence(timeout: 15))
        let body = app.staticTexts["alo.message.body.990100"]
        XCTAssertTrue(body.waitForExistence(timeout: 8))
        body.press(forDuration: 0.6)
        let menu = app.scrollViews["alo.message.actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 4))
        let translate = app.buttons["alo.message.action.translate"]
        XCTAssertTrue(translate.waitForExistence(timeout: 3), "«Перевести» is in the menu")
        capture("tools-translate-1-menu")
        translate.tap()

        XCTAssertTrue(app.otherElements["alo.translate.sheet"].waitForExistence(timeout: 4), "a list of languages")
        XCTAssertTrue(app.buttons["alo.translate.language.en"].waitForExistence(timeout: 3))
        capture("tools-translate-2-languages")
        app.buttons["alo.translate.language.en"].tap()

        let consent = app.alerts["Отправить текст на перевод?"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5), "the first translation asks, once the list is gone")
        capture("tools-translate-3-consent")
        consent.buttons["Разрешить"].tap()

        let translation = app.staticTexts["alo.translation.990100"]
        XCTAssertTrue(translation.waitForExistence(timeout: 6))
        XCTAssertEqual(translation.label, "Hi! Did you look at the photos from the trip?")
        XCTAssertTrue(app.staticTexts["Перевод · English"].exists, "the translation says what language it is in")
        XCTAssertTrue(body.exists, "the original stays")
        capture("tools-translate-4-shown")

        app.staticTexts["alo.message.body.990100"].press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["alo.message.action.hide-translation"].waitForExistence(timeout: 4), "the menu now offers to hide it")
        capture("tools-translate-5-hide")
        app.buttons["alo.message.action.hide-translation"].tap()
        XCTAssertTrue(translation.waitForNonExistence(timeout: 4))
        XCTAssertTrue(body.exists)
    }

    func testNothingIsOfferedWhenTheServerHasNoProvider() {
        let app = launch("voice", tools: false)
        XCTAssertTrue(app.buttons["alo.chat.attach"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["alo.voice.play"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["alo.transcribe.990200"].exists, "no «Aa» without a transcription service")
        app.buttons["alo.voice.play"].press(forDuration: 0.6)
        // The voice bubble's menu has no «Расшифровать» either.
        if app.scrollViews["alo.message.actions"].waitForExistence(timeout: 3) {
            XCTAssertFalse(app.buttons["alo.message.action.transcribe"].exists)
            XCTAssertFalse(app.buttons["alo.message.action.translate"].exists)
        }
        capture("tools-off-voice")
    }

    func testSharedMediaTabsSpellOutTheVoiceTab() {
        let app = launch("media")
        XCTAssertTrue(app.buttons["alo.chat.attach"].waitForExistence(timeout: 15))
        app.buttons["alo.chat.info"].tap()
        XCTAssertTrue(app.buttons["alo.peer.back"].waitForExistence(timeout: 4))
        app.scrollViews["alo.peer.scroll"].swipeUp()
        app.scrollViews["alo.peer.scroll"].swipeUp()
        let voices = app.buttons["alo.peer.tab.voices"]
        XCTAssertTrue(voices.waitForExistence(timeout: 4))
        XCTAssertEqual(voices.label, "Голосовые", "the tab no longer says «ГС»")
        XCTAssertTrue(voices.isHittable)
        capture("tools-media-tabs")
    }

    func testSettingsHoldTheConsentSwitch() {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "own-profile",
            "-ALO_UI_MESSENGER_ACCESSIBILITY", "0", "-ALO_UI_REDUCE_MOTION", "0", "-ALO_UI_SEARCH_INCOMING", "0",
            "-ALO_UI_CONTENT_TOOLS", "1", "-ALO_UI_CONTENT_CONSENT", "1"]
        app.launch()
        let settings = app.buttons["alo.profile.settings"]
        if settings.waitForExistence(timeout: 15) { settings.tap() } else { app.buttons["Настройки"].firstMatch.tap() }
        let row = app.buttons["alo.settings.content-tools"]
        XCTAssertTrue(row.waitForExistence(timeout: 6), "settings list «Перевод и расшифровка»")
        row.tap()
        let toggle = app.switches["alo.settings.content-tools.consent"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        XCTAssertEqual(toggle.value as? String, "1", "consent was given")
        capture("tools-settings-1-on")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.buttons["alo.settings.content-tools.clear"].exists)
        capture("tools-settings-2-off")
    }
}
