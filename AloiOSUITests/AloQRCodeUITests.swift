import XCTest

final class AloQRCodeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ scenario: String, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_QR_PREVIEW", "1", "-ALO_UI_QR_SCENARIO", scenario]
        if large { app.launchArguments += ["-ALO_UI_QR_LARGE_TEXT", "1"] }
        app.launch()
        return app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCanonicalQRShowsWaitingAndCanBeClosed() {
        let app = launch("waiting")
        let code = app.descendants(matching: .any)["alo.qr-login.code"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["alo.qr-login.waiting"].firstMatch.exists)
        XCTAssertLessThanOrEqual(code.frame.width, app.windows.firstMatch.frame.width - 48)
        capture("qr-login-readable-white-quiet-zone")
        app.buttons["Закрыть"].tap()
        XCTAssertTrue(app.buttons["alo.qr-fixture.open"].waitForExistence(timeout: 5))
    }

    func testExpiredCodeHasVisibleErrorAndWorkingRetry() {
        let app = launch("expired")
        let error = app.staticTexts["alo.qr-login.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("истёк"))
        let retry = app.buttons["alo.qr-login.retry"]
        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        capture("qr-login-expired-retry")
        retry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["alo.qr-login.waiting"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
    }

    func testScanDoesNotApproveUntilUserConfirms() {
        let app = launch("approval")
        let confirm = app.buttons["alo.qr-approval.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Подключить новое устройство?"].exists)
        XCTAssertFalse(app.staticTexts["Вход подтверждён"].exists)
        capture("qr-approval-explicit-account-permission")
        confirm.doubleTap()
        XCTAssertTrue(app.staticTexts["Вход подтверждён"].waitForExistence(timeout: 5))
    }

    func testLargestTextStillAllowsRetryAndDeviceRotationKeepsCloseAvailable() {
        let app = launch("expired", large: true)
        let retry = app.buttons["alo.qr-login.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(app.staticTexts["alo.qr-login.error"].frame.height, 140,
                             "The sheet must actually inherit the largest Dynamic Type setting")
        for _ in 0..<4 where !retry.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(retry.isHittable)
        capture("qr-accessibility-largest-text-retry")
        retry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["alo.qr-login.code"].firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        // Alo currently locks phone UI to portrait. This checks rotation does
        // not lose the escape route; it does not claim landscape support.
        XCTAssertTrue(app.buttons["Закрыть"].isHittable)
        capture("qr-device-rotation-largest-text-close")
        app.buttons["Закрыть"].tap()
    }
}
