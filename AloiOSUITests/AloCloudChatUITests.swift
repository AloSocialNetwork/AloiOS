import XCTest

/// Signs in to a real Alo server on a throwaway database (`DIRECT_MESSAGES_E2EE_REQUIRED=0`), reads a plain message and
/// sends one with formatting. Skipped unless `ALO_CLOUD_UI_EMAIL` and `ALO_CLOUD_UI_PASSWORD` are set
/// (`TEST_RUNNER_ALO_CLOUD_UI_EMAIL=… xcodebuild test`); the debug app of the simulator talks to 127.0.0.1:3000.
final class AloCloudChatUITests: XCTestCase {
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testPlainMessageIsReadAndSentWithFormattingInACloudChat() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let email = environment["ALO_CLOUD_UI_EMAIL"], let password = environment["ALO_CLOUD_UI_PASSWORD"] else {
            throw XCTSkip("ALO_CLOUD_UI_EMAIL and ALO_CLOUD_UI_PASSWORD are not set")
        }
        let peer = environment["ALO_CLOUD_UI_PEER"] ?? "Борис"
        let incoming = environment["ALO_CLOUD_UI_INCOMING"] ?? "облачного чата"
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for title in ["Не разрешать", "Don’t Allow", "Не сейчас", "Позже"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        let app = XCUIApplication()
        app.launch()

        let emailField = app.textFields.firstMatch
        // A session kept by an earlier run goes straight to the app.
        if emailField.waitForExistence(timeout: 12), emailField.isHittable, app.buttons["Продолжить"].exists {
            emailField.tap()
            emailField.typeText(email)
            app.buttons["Продолжить"].tap()
            let passwordField = app.secureTextFields.firstMatch
            XCTAssertTrue(passwordField.waitForExistence(timeout: 20))
            passwordField.tap()
            passwordField.typeText(password)
            app.buttons["Войти"].tap()
            sleep(3)
            let code = app.textFields.allElementsBoundByIndex.last ?? emailField
            code.tap()
            code.typeText(environment["ALO_CLOUD_UI_CODE"] ?? "123456")
            capture("1-code")
            app.buttons["Продолжить"].tap()
        }
        let chatsTab = app.buttons["Чаты"]
        XCTAssertTrue(chatsTab.waitForExistence(timeout: 30))
        chatsTab.tap()

        // The chat list shows the preview of the plain message that arrived while the person was away.
        let row = element(containing: peer, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The chat with \(peer) is in the list")
        XCTAssertTrue(element(containing: incoming, in: app).waitForExistence(timeout: 10), "The list shows the plain text of the last message")
        capture("2-chat-list")
        row.tap()

        XCTAssertTrue(element(containing: incoming, in: app).waitForExistence(timeout: 20), "The plain message is readable in the chat")
        let field = app.descendants(matching: .any)["alo.chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("**Привет** с iPhone, __курсив__")
        capture("3-typed")
        app.buttons["Отправить"].firstMatch.tap()
        XCTAssertTrue(element(containing: "Привет с iPhone, курсив", in: app).waitForExistence(timeout: 20),
                      "The sent message shows the text without markers")
        sleep(3)
        capture("4-sent")
    }
}
