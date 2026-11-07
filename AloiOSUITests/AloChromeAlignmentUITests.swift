import XCTest

final class AloChromeAlignmentUITests: XCTestCase {
    private func launch(_ content: String, largeText: Bool = false, moderation: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content,
            "-ALO_UI_MESSENGER_ACCESSIBILITY", largeText ? "1" : "0",
            "-ALO_UI_LEGACY_GLASS", "0", "-ALO_UI_REDUCE_MOTION", largeText ? "1" : "0",
            "-ALO_UI_REDUCE_TRANSPARENCY", "0", "-ALO_UI_INCREASE_CONTRAST", "0",
            "-ALO_UI_ADMIN", moderation ? "1" : "0"]
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
    }

    func testPhotoCloseUsesChatBackPositionIncludingLargeText() {
        for largeText in [false, true] {
            checkMedia(content: "media-landscape", messageID: 990200, largeText: largeText)
        }
    }

    func testVideoCloseUsesChatBackPosition() {
        checkMedia(content: "media", messageID: 990201, largeText: false)
    }

    private func checkMedia(content: String, messageID: Int, largeText: Bool) {
        let app = launch(content, largeText: largeText)
        let back = app.buttons["alo.chat.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        let originalFrame = back.frame
        let media = app.descendants(matching: .any).matching(identifier: "alo.message.media.\(messageID)").firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 4))
        XCTAssertTrue(media.isHittable)
        media.tap()
        let close = app.buttons["alo.media.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        assertSameFrame(close.frame, originalFrame)
        XCTAssertTrue(close.isHittable)
        capture("aligned-\(content)-\(largeText ? "large-text" : "regular")")
        close.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        assertSameFrame(back.frame, originalFrame)
        app.terminate()
    }

    func testSettingsUseCircleBackAndPreserveNavigationHistory() {
        let app = launch("social-overview")
        app.buttons["Профиль"].firstMatch.tap()
        XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 4))
        app.buttons["alo.profile.settings"].tap()
        let back = app.buttons["alo.settings.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        XCTAssertEqual(back.label, "Назад")
        // The glass back circle of every full screen (Android, the web), not «‹ Назад».
        XCTAssertEqual(back.frame.width, back.frame.height, accuracy: 1)
        capture("settings-text-back-root")
        for title in ["Приватность", "Уведомления", "Бизнес-профиль", "Безопасность"] {
            app.buttons[title].firstMatch.tap()
            XCTAssertTrue(back.waitForExistence(timeout: 4))
            XCTAssertTrue(back.isHittable)
            XCTAssertGreaterThanOrEqual(back.frame.height, 44 - 0.01)
            // The glass back circle of every full screen (Android, the web), not «‹ Назад».
        XCTAssertEqual(back.frame.width, back.frame.height, accuracy: 1)
            if title == "Приватность" || title == "Уведомления" {
                XCTAssertTrue(app.buttons["Сохранить"].exists)
                XCTAssertFalse(app.buttons["Сохранить"].isEnabled)
            }
            if title == "Безопасность" {
                let passwordRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Сменить пароль")).firstMatch
                XCTAssertTrue(passwordRow.waitForExistence(timeout: 4))
                passwordRow.tap()
                XCTAssertTrue(back.waitForExistence(timeout: 4))
                capture("settings-text-back-password")
                back.tap()
                XCTAssertTrue(passwordRow.waitForExistence(timeout: 4))
            }
            capture("settings-text-back-\(title)")
            back.tap()
            XCTAssertTrue(app.buttons["Приватность"].firstMatch.waitForExistence(timeout: 4))
        }
        // This window already used native text Back; do not restyle it or
        // replace its label with the parent section's title.
        app.buttons["alo.settings.creator-stats"].tap()
        let existingBack = app.navigationBars.buttons["Назад"].firstMatch
        XCTAssertTrue(existingBack.waitForExistence(timeout: 4))
        XCTAssertFalse(back.exists)
        capture("settings-existing-native-back-creator")
        existingBack.tap()
        XCTAssertTrue(app.buttons["Приватность"].firstMatch.waitForExistence(timeout: 4))
        back.tap()
        XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 4))
    }

    func testSettingsBackUsesTheModerationNavigationBarHeight() {
        for largeText in [false, true] {
            let app = launch("social-overview", largeText: largeText, moderation: true)
            app.buttons["Профиль"].firstMatch.tap()
            XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 5))
            app.buttons["alo.profile.settings"].tap()
            let back = app.buttons["alo.settings.back"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            // The native bar owns the scroll-edge blur; only the button's
            // shared capsule is explicitly hidden and reviewed in screenshots.
            XCTAssertTrue(app.navigationBars.buttons["alo.settings.back"].exists)
            let settingsBackCenter = back.frame.midY
            app.buttons["alo.settings.moderation"].tap()
            let moderationBack = app.navigationBars.buttons["Назад"].firstMatch
            XCTAssertTrue(moderationBack.waitForExistence(timeout: 5))
            let referenceCenter = moderationBack.frame.midY
            capture("settings-back-reference-moderation-\(largeText ? "large" : "regular")")
            XCTAssertEqual(settingsBackCenter, referenceCenter, accuracy: 0.5)
            moderationBack.tap()

            for title in ["Безопасность", "Приватность", "Уведомления", "Бизнес-профиль", "Данные и память"] {
                app.buttons[title].firstMatch.tap()
                XCTAssertTrue(back.waitForExistence(timeout: 5))
                XCTAssertTrue(app.navigationBars.buttons["alo.settings.back"].exists)
                XCTAssertEqual(back.frame.midY, referenceCenter, accuracy: 0.5, title)
                // UIKit may return 43.99999999999999 after a screen-scale conversion.
                XCTAssertGreaterThanOrEqual(back.frame.height, 44 - 0.01)
                if title == "Безопасность" {
                    let password = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Сменить пароль")).firstMatch
                    password.tap()
                    XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 5))
                    XCTAssertEqual(back.frame.midY, referenceCenter, accuracy: 0.5, "Смена пароля")
                    back.tap()
                    XCTAssertTrue(password.waitForExistence(timeout: 5))
                }
                if title == "Приватность" || title == "Уведомления" {
                    let save = app.buttons["Сохранить"]
                    XCTAssertTrue(save.exists)
                    XCTAssertEqual(save.frame.midY, referenceCenter, accuracy: 0.5)
                }
                capture("settings-back-aligned-\(title)-\(largeText ? "large" : "regular")")
                back.tap()
                XCTAssertTrue(app.buttons["alo.settings.moderation"].waitForExistence(timeout: 5))
            }
            back.tap()
            XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testDataStorageSettingsAtNormalAndAccessibilityTextSizes() {
        for largeText in [false, true] {
            let app = launch("social-overview", largeText: largeText)
            app.buttons["Профиль"].firstMatch.tap()
            XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 5))
            app.buttons["alo.profile.settings"].tap()
            let storage = app.buttons["alo.settings.storage"]
            XCTAssertTrue(storage.waitForExistence(timeout: 5))
            if !storage.isHittable { app.swipeUp() }
            storage.tap()
            XCTAssertTrue(app.staticTexts["Использование памяти"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Максимальный размер"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["alo.storage.limit"].firstMatch.exists)
            let back = app.buttons["alo.settings.back"]
            XCTAssertTrue(back.isHittable)
            capture("media-cache-settings-\(largeText ? "large-text" : "regular")")
            let retention = app.staticTexts["Автоудаление из кеша"]
            for _ in 0..<12 {
                if retention.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(retention.isHittable)
            capture("media-cache-retention-\(largeText ? "large-text" : "regular")")
            back.tap()
            XCTAssertTrue(storage.waitForExistence(timeout: 4))
            app.terminate()
        }
    }

    func testSettingsKeepNativeScrollEdgeAndTextButtonsWhenScrolling() {
        let app = launch("social-overview", moderation: true)
        app.buttons["Профиль"].firstMatch.tap()
        XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 5))
        app.buttons["alo.profile.settings"].tap()
        let rootBar = app.navigationBars.firstMatch
        XCTAssertTrue(rootBar.buttons["alo.settings.back"].waitForExistence(timeout: 5))
        let rootFrame = rootBar.frame
        capture("settings-native-blur-root-top")
        app.buttons["alo.settings.moderation"].tap()
        let referenceBar = app.navigationBars.firstMatch
        XCTAssertTrue(referenceBar.waitForExistence(timeout: 5))
        let referenceFrame = referenceBar.frame
        assertSameFrame(rootFrame, referenceFrame)
        capture("settings-native-blur-reference-moderation-top")
        app.scrollViews.firstMatch.swipeUp()
        capture("settings-native-blur-reference-moderation-scrolled")
        app.navigationBars.buttons["Назад"].firstMatch.tap()

        for title in ["Приватность", "Уведомления", "Данные и память"] {
            app.buttons[title].firstMatch.tap()
            let back = app.navigationBars.buttons["alo.settings.back"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            XCTAssertEqual(back.label, "Назад")
            XCTAssertTrue(back.isHittable)
            assertSameFrame(app.navigationBars.firstMatch.frame, referenceFrame)
            capture("settings-native-blur-\(title)-top")
            let originalCenter = back.frame.midY
            app.scrollViews.firstMatch.swipeUp()
            XCTAssertTrue(back.isHittable)
            XCTAssertEqual(back.frame.midY, originalCenter, accuracy: 0.5)
            capture("settings-native-blur-\(title)-scrolled")
            back.tap()
            XCTAssertTrue(app.buttons["alo.settings.moderation"].waitForExistence(timeout: 5))
        }
    }

    func testSettingsCircleBackWithLargeText() {
        let app = launch("social-overview", largeText: true)
        app.buttons["Профиль"].firstMatch.tap()
        XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 4))
        app.buttons["alo.profile.settings"].tap()
        let back = app.buttons["alo.settings.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        app.buttons["Приватность"].firstMatch.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        XCTAssertTrue(back.isHittable)
        XCTAssertEqual(back.label, "Назад")
        // The glass back circle of every full screen (Android, the web), not «‹ Назад».
        XCTAssertEqual(back.frame.width, back.frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(back.frame.height, 44 - 0.01)
        XCTAssertTrue(app.buttons["Сохранить"].exists)
        capture("settings-text-back-large-text")
        back.tap()
        XCTAssertTrue(app.buttons["Приватность"].firstMatch.waitForExistence(timeout: 4))
    }

    func testFeedAndNotificationOvalsSharePositionAndSize() {
        for largeText in [false, true] {
            let app = launch("social-overview", largeText: largeText)
            let popular = app.buttons["alo.feed.tab.popular"]
            let subscriptions = app.buttons["alo.feed.tab.subscriptions"]
            XCTAssertTrue(popular.waitForExistence(timeout: 15))
            // The identical shared segment component adds 4pt on both outer
            // edges. Comparing the complete button row compares both ovals.
            let feedFrame = popular.frame.union(app.buttons["alo.feed.tab.top"].frame)
            capture("aligned-feed-\(largeText ? "large-text" : "regular")")
            app.buttons["Уведы"].firstMatch.tap()
            let all = app.buttons["alo.alerts.filter.all"]
            let reactions = app.buttons["alo.alerts.filter.reactions"]
            XCTAssertTrue(all.waitForExistence(timeout: 4))
            assertSameFrame(all.frame.union(reactions.frame), feedFrame)
            capture("aligned-notifications-\(largeText ? "large-text" : "regular")")
            app.terminate()
        }
    }
}
