import XCTest

/// Secret chats on screen with the design fixture (`-ALO_UI_SECRET_PREVIEW`, no server): the row in the chat list, the
/// open chat with a timer, an incoming request, a chat that waits for the other person, and «Новый секретный чат» in
/// «Новое сообщение». The screenshots are kept in the result bundle.
final class AloSecretChatUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "chat-list",
                               "-ALO_UI_SECRET_PREVIEW", mode]
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testSecretChatScreens() {
        // The list: the secret chats among the others, with their lock and their own lines.
        var app = launch("list")
        let row = element("alo.chats.secret.501", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(element("alo.chats.secret.502", in: app).exists)
        sleep(1)
        capture("1-chat-list")
        row.tap()
        XCTAssertTrue(element("alo.secret.screen", in: app).waitForExistence(timeout: 5))
        element("alo.secret.back", in: app).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // «Новое сообщение» offers «Новый секретный чат», as in Telegram.
        app.buttons["Новое сообщение"].tap()
        let secretEntry = element("alo.compose.secret", in: app)
        XCTAssertTrue(secretEntry.waitForExistence(timeout: 5))
        capture("2-new-message")
        secretEntry.tap()
        XCTAssertTrue(app.staticTexts["Новый секретный чат"].waitForExistence(timeout: 5))
        capture("3-new-secret-chat")
        app.terminate()

        // An open chat: messages, formatting, a message counting down after it was read.
        app = launch("chat")
        XCTAssertTrue(element("alo.secret.screen", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(element("alo.secret.countdown", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("alo.secret.input", in: app).exists)
        sleep(1)
        capture("4-chat")
        element("alo.secret.more", in: app).tap()
        XCTAssertTrue(app.buttons["Таймер самоуничтожения"].waitForExistence(timeout: 5))
        capture("5-menu")
        app.terminate()

        // A request from someone: accept or decline, nothing to type yet.
        app = launch("request")
        XCTAssertTrue(element("alo.secret.accept", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(element("alo.secret.decline", in: app).exists)
        XCTAssertFalse(element("alo.secret.input", in: app).exists)
        capture("6-request")
        app.terminate()

        // Waiting for the other person to accept.
        app = launch("waiting")
        XCTAssertTrue(element("alo.secret.waiting", in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(element("alo.secret.input", in: app).exists)
        capture("7-waiting")
    }
}
