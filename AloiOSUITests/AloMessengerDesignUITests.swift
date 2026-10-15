import XCTest
import UIKit

final class AloMessengerDesignUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchChat(accessibility: Bool = false, content: String = "", arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1"]
        app.launchArguments += ["-ALO_UI_MESSENGER_CONTENT", content]
        app.launchArguments += arguments
        if accessibility {
            app.launchArguments += ["-ALO_UI_MESSENGER_ACCESSIBILITY", "1"]
        }
        app.launch()
        let readyElement = content == "circle-draft" ? app.buttons["alo.circle.draft-play"] : field(app, "alo.chat.composer")
        let ready = readyElement.waitForExistence(timeout: 15)
        if !ready { print(app.debugDescription) }
        XCTAssertTrue(ready)
        return app
    }

    private func field(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (elementType == %d OR elementType == %d)",
            identifier, XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue
        )).firstMatch
    }

    private func capture(_ name: String) {
        // Let the 240 ms tab transition settle before snapshotting remote Photos UI.
        Thread.sleep(forTimeInterval: 0.4)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertCompactBlackDimming(_ app: XCUIApplication, opaque: Bool = false,
        file: StaticString = #filePath, line: UInt = #line) {
        // On a deliberately bright wallpaper, verify BOTH black dimming near
        // chrome and recovery in the history. A no-scrim renderer and an overly
        // dark/double-material band must not pass only geometry checks.
        guard let image = XCUIScreen.main.screenshot().image.cgImage else {
            return XCTFail("Missing screenshot", file: file, line: line)
        }
        func blue(atY y: CGFloat) -> Double {
            let rect = CGRect(x: CGFloat(image.width) * 0.02,
                y: CGFloat(image.height) * y / app.frame.height, width: 1, height: 1)
            guard let sample = image.cropping(to: rect) else {
                XCTFail("Missing edge sample", file: file, line: line)
                return 0
            }
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return Double(pixel[2])
        }
        let wallpaper = blue(atY: app.frame.height * 0.5)
        XCTAssertGreaterThan(wallpaper, 90, "Bright diagnostic wallpaper must remain visible in history", file: file, line: line)
        for y in [app.frame.height * 0.025, app.frame.height * 0.98] {
            let edge = blue(atY: y)
            if opaque {
                XCTAssertLessThanOrEqual(edge, 2, "Reduce Transparency uses black at the chrome edge", file: file, line: line)
            } else {
                XCTAssertGreaterThan(edge, wallpaper * 0.08, "Do not stack an opaque material over the black scrim", file: file, line: line)
                XCTAssertLessThan(edge, wallpaper * 0.45, "The chrome edge must be dimmed, not merely redraw wallpaper", file: file, line: line)
            }
        }
        let playerEnds = ["alo.circle.close", "alo.voice.close"].compactMap { identifier -> CGFloat? in
            let close = app.buttons[identifier]
            return close.exists ? close.frame.maxY : nil
        }
        let headerEnd = max(app.buttons["alo.chat.back"].frame.maxY, playerEnds.max() ?? 0)
        let historyTop = blue(atY: headerEnd + 50)
        let historyBottom = blue(atY: field(app, "alo.chat.composer").frame.minY - 40)
        XCTAssertGreaterThan(historyTop, wallpaper * 0.6, "Top fade must end close to the header", file: file, line: line)
        XCTAssertGreaterThan(historyBottom, wallpaper * 0.6, "Bottom fade must end close to the composer", file: file, line: line)
    }

    private func measuredBubble(_ row: XCUIElement) -> CGRect {
        let values = (row.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(values.count, 4, "Missing real message GeometryReader measurement")
        guard values.count == 4 else { return .zero }
        XCTAssertGreaterThan(values[2], 0)
        // The geometry probe uses conversationRoot, while XCTest frames are in
        // screen coordinates (20 pt / 62 pt safe-area origins differ by device).
        // Rows bottom-align their bubble with 2 pt of outer vertical padding.
        return CGRect(x: values[0], y: row.frame.maxY - 2 - values[3], width: values[2], height: values[3])
    }

    private func selectMessage(_ app: XCUIApplication) {
        let select = app.buttons["Выбрать"]
        let menu = app.scrollViews["alo.message.actions"]
        // Very short viewports scroll the action list, keeping the preview whole.
        if menu.exists, !select.isHittable || select.frame.maxY > menu.frame.maxY {
            menu.swipeUp()
        }
        XCTAssertTrue(select.isHittable)
        select.tap()
    }

    func testChatReferenceCapture() {
        _ = launchChat()
        capture("chat-offline-fixture")
    }

    func testHistoryDownButtonAndUnreadBadge() {
        let app = launchChat(content: "unread-navigation")
        let down = app.buttons["alo.chat.scroll-bottom"]
        XCTAssertFalse(down.exists, "No button over the latest messages")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                   withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(down.waitForExistence(timeout: 4))
        XCTAssertTrue(down.isHittable)
        XCTAssertEqual(down.value as? String, "Непрочитанных сообщений: 2")
        XCTAssertGreaterThanOrEqual(down.frame.height, 44)
        XCTAssertLessThan(down.frame.maxY, field(app, "alo.chat.composer").frame.minY)
        capture("history-down-unread-badge")
        down.tap()
        XCTAssertTrue(app.staticTexts["Новое тестовое сообщение 2"].waitForExistence(timeout: 4))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: down)
        waitForExpectations(timeout: 4)
        XCTAssertTrue(app.buttons["alo.chat.attach"].isHittable)
        capture("history-down-reached-latest")
    }

    func testBlackChatEdgesStayBehindControlsAndKeyboard() {
        for legacy in [false, true] {
            let mode = legacy ? "legacy" : "native"
            let app = launchChat(content: "circle-flow", arguments: ["-ALO_UI_MESSENGER_SURFACE", "1",
                "-ALO_UI_LEGACY_GLASS", legacy ? "1" : "0"])
            let back = app.buttons["alo.chat.back"]
            let attach = app.buttons["alo.chat.attach"]
            let composer = field(app, "alo.chat.composer")
            let header = back.frame
            let avatar = app.buttons["Профиль собеседника"]
            let avatarFrame = avatar.frame
            XCTAssertLessThanOrEqual(avatarFrame.maxX, app.frame.maxX)
            XCTAssertTrue(back.isHittable && attach.isHittable && composer.isHittable)
            capture("black-chat-edges-" + mode)
            assertCompactBlackDimming(app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.3))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.75)),
                       withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertEqual(back.frame, header)
            XCTAssertEqual(avatar.frame, avatarFrame)
            XCTAssertTrue(back.isHittable && attach.isHittable)
            capture("black-chat-edges-scroll-" + mode)
            assertCompactBlackDimming(app)
            composer.tap()
            composer.typeText("Черновик проверки краёв")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
            XCTAssertEqual(back.frame, header)
            XCTAssertEqual(avatar.frame, avatarFrame)
            XCTAssertTrue(attach.isHittable && app.buttons["alo.chat.record-send"].isHittable)
            XCTAssertLessThanOrEqual(attach.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
            capture("black-chat-edges-keyboard-" + mode)
            XCTAssertTrue((composer.value as? String ?? "").contains("Черновик"))
            app.terminate()
        }
    }

    func testBlackChatEdgeExpandsWithPlaybackHeader() {
        for content in ["voice", "circle-flow"] {
            let app = launchChat(content: content, arguments: ["-ALO_UI_MESSENGER_SURFACE", "1", "-ALO_UI_LEGACY_GLASS", "1"])
            let circle = content == "circle-flow"
            let play = circle ? app.otherElements["alo.message.990223"].buttons["alo.circle.play"] : app.buttons["alo.voice.play"]
            play.tap()
            let close = app.buttons[circle ? "alo.circle.close" : "alo.voice.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 4))
            let pause = circle ? app.buttons["Приостановить кружок"] : app.buttons["alo.voice.toggle"]
            XCTAssertTrue(pause.waitForExistence(timeout: 4))
            pause.tap()
            let back = app.buttons["alo.chat.back"]
            XCTAssertGreaterThanOrEqual(close.frame.minY, back.frame.maxY)
            XCTAssertTrue(back.isHittable && close.isHittable)
            capture("black-chat-edges-player-" + content)
            assertCompactBlackDimming(app)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 4))
            XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
            capture("black-chat-edges-player-dismissed-" + content)
            app.terminate()
        }
    }

    func testChatEdgeWallpaperWithReducedTransparency() {
        let app = launchChat(content: "circle-flow", arguments: ["-ALO_UI_MESSENGER_SURFACE", "1",
            "-ALO_UI_REDUCE_TRANSPARENCY", "1", "-ALO_UI_REDUCE_MOTION", "1"])
        assertCompactBlackDimming(app, opaque: true)
        XCTAssertTrue(app.buttons["alo.chat.back"].isHittable)
        XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
        capture("wallpaper-edges-reduced-transparency")
    }

    func testDarkChatEdgeReferenceCapture() {
        for legacy in [false, true] {
            let app = launchChat(content: "circle-flow", arguments: ["-ALO_UI_MESSENGER_APPEARANCE", "nightAccent",
                "-ALO_UI_LEGACY_GLASS", legacy ? "1" : "0", "-ALO_UI_REDUCE_MOTION", "1"])
            XCTAssertTrue(app.buttons["alo.chat.back"].isHittable)
            XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
            capture("dark-chat-dimming-" + (legacy ? "legacy" : "native"))
            app.terminate()
        }
    }

    func testCircleExpandsFloatsAndReturnsToMessage() {
        let app = launchChat(content: "circle-flow")
        let row = app.otherElements["alo.message.990223"]
        let circle = row.buttons["alo.circle.play"]
        XCTAssertTrue(circle.waitForExistence(timeout: 5))
        let originalWidth = circle.frame.width
        circle.tap()
        let pause = app.buttons["Приостановить кружок"]
        XCTAssertTrue(pause.waitForExistence(timeout: 4))
        pause.tap()
        capture("circle-after-pause")
        XCTAssertTrue(app.buttons["Продолжить кружок"].waitForExistence(timeout: 3))
        XCTAssertGreaterThan(circle.frame.width, originalWidth + 50)
        capture("circle-expanded")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.82))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        let floating = app.descendants(matching: .any).matching(identifier: "alo.circle.floating").firstMatch
        XCTAssertTrue(floating.waitForExistence(timeout: 4))
        capture("circle-floating")
        floating.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(floating.waitForNonExistence(timeout: 4))
        XCTAssertTrue(circle.isHittable)
        capture("circle-returned")
        app.buttons["Остановить кружок"].tap()
        XCTAssertTrue(app.buttons["Остановить кружок"].waitForNonExistence(timeout: 4))
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(circle.frame.width - originalWidth) < 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 4), .completed)
    }

    func testAppearancePreviewAndCancel() {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "appearance", "-ALO_UI_LEGACY_GLASS", "1"]
        app.launch()
        let apply = app.buttons["alo.appearance.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 15))
        capture("appearance-themes")
        app.buttons["alo.appearance.section.1"].tap()
        app.buttons["Зелёный"].tap()
        XCTAssertTrue(app.otherElements["alo.appearance.preview"].exists)
        capture("appearance-wallpaper")
        app.buttons["alo.appearance.section.2"].tap()
        app.buttons["Фиолетовый"].tap()
        capture("appearance-messages")
        app.buttons["alo.appearance.cancel"].tap()
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 5))
    }

    func testElasticComposerPreservesTypingAndSelection() {
        let app = launchChat(arguments: ["-ALO_UI_LEGACY_GLASS", "1", "-ALO_UI_MESSENGER_SURFACE", "1"])
        let composer = field(app, "alo.chat.composer")
        composer.tap()
        composer.typeText("Проверяем ввод текста")
        XCTAssertTrue((composer.value as? String ?? "").contains("Проверяем"))
        composer.press(forDuration: 1)
        capture("elastic-composer-held")
        XCTAssertTrue((composer.value as? String ?? "").contains("Проверяем"))
    }

    func testLegacyGlassControlsAndMenu() {
        let app = launchChat(content: "forward", arguments: ["-ALO_UI_LEGACY_GLASS", "1", "-ALO_UI_MESSENGER_SURFACE", "1"])
        let attach = app.buttons["alo.chat.attach"]
        let record = app.buttons["alo.chat.record-send"]
        let original = record.frame
        XCTAssertEqual(original.width, 48, accuracy: 1)
        XCTAssertEqual(original.midY, attach.frame.midY, accuracy: 1)
        capture("legacy-glass-composer")
        record.tap()
        XCTAssertEqual(record.label, "Кружок")
        XCTAssertEqual(record.frame, original)
        record.tap()
        app.staticTexts["alo.message.body.990200"].press(forDuration: 0.6)
        let menu = app.scrollViews["alo.message.actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 4))
        XCTAssertGreaterThanOrEqual(menu.frame.minX, 0)
        XCTAssertLessThanOrEqual(menu.frame.maxX, app.frame.width)
        capture("legacy-glass-message-menu")
        app.buttons["Ответить"].tap()
        XCTAssertTrue(menu.waitForNonExistence(timeout: 4))
        XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
    }

    func testReplyAccessoryHasBoundedHeightAndCanCancel() {
        let app = launchChat(content: "forward", arguments: ["-ALO_UI_LEGACY_GLASS", "1"])
        app.staticTexts["alo.message.body.990200"].press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Ответить"].waitForExistence(timeout: 4))
        app.buttons["Ответить"].tap()
        let accessory = app.otherElements["alo.composer.accessory.reply"]
        XCTAssertTrue(accessory.waitForExistence(timeout: 4))
        XCTAssertEqual(accessory.frame.height, 45, accuracy: 1)
        XCTAssertLessThan(accessory.frame.maxY, field(app, "alo.chat.composer").frame.midY)
        let cancel = app.buttons["alo.composer.reply.cancel"]
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44 - 0.01)
        XCTAssertLessThanOrEqual(accessory.frame.maxX, app.frame.maxX)
        capture("reply-accessory-bounded-legacy")
        cancel.tap()
        XCTAssertTrue(accessory.waitForNonExistence(timeout: 4))
        XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
    }

    func testReplyQuoteDoesNotGrowWithLongAuthorAndCanOpenOriginal() {
        let app = launchChat(content: "reply-layout")
        let quote = app.buttons["alo.message.reply.990200"]
        XCTAssertTrue(quote.waitForExistence(timeout: 5))
        XCTAssertEqual(quote.frame.height, 44, accuracy: 1)
        XCTAssertLessThanOrEqual(quote.frame.maxX, app.frame.maxX - 10)
        let row = app.otherElements["alo.message.990200"]
        XCTAssertLessThan(measuredBubble(row).height, 110)
        capture("reply-quote-long-author")
        quote.tap()
        XCTAssertTrue(app.otherElements["alo.message.990100"].isHittable)
        XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
    }

    func testReplyToMediaHasReadableTypeAndBoundedQuote() {
        for content in ["reply-photo", "reply-voice"] {
            let app = launchChat(content: content)
            let quote = app.buttons["alo.message.reply.990200"]
            XCTAssertTrue(quote.waitForExistence(timeout: 5))
            XCTAssertEqual(quote.frame.height, 44, accuracy: 1)
            XCTAssertFalse(quote.label.contains("opaque-attachment"))
            XCTAssertTrue(quote.label.contains("Александр"))
            XCTAssertTrue(quote.label.contains(content == "reply-photo" ? "Фото" : "Голосовое сообщение"))
            XCTAssertLessThanOrEqual(quote.frame.maxX, app.frame.maxX - 10)
            capture(content + "-quote")
            quote.tap()
            XCTAssertTrue(app.otherElements["alo.message.990100"].isHittable)
            app.terminate()
        }
    }

    func testSharedContactFitsMessageAndSelection() {
        let app = launchChat(content: "contact")
        let contact = app.buttons["alo.contact.card"]
        XCTAssertTrue(contact.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(contact.frame.maxX, app.frame.maxX - 10)
        XCTAssertGreaterThanOrEqual(contact.frame.height, 44)
        capture("contact-bounded-card")
        contact.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Выбрать"].waitForExistence(timeout: 4))
        selectMessage(app)
        XCTAssertTrue(contact.exists)
        XCTAssertLessThanOrEqual(contact.frame.maxX, app.frame.maxX - 10)
        capture("contact-selection")
    }

    func testClosingPollLivesInContextMenuAndRequiresConfirmation() {
        let app = launchChat(content: "poll-own")
        XCTAssertFalse(app.buttons["Завершить"].exists)
        app.staticTexts["Куда отправимся в выходные?"].press(forDuration: 0.6)
        let close = app.buttons["alo.poll.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        let menu = app.scrollViews["alo.message.actions"]
        if !close.isHittable { menu.swipeUp() }
        close.tap()
        let confirmation = app.alerts["Завершить опрос?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4))
        confirmation.buttons["Отмена"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 3))
        capture("poll-close-context-confirmation-cancelled")
    }

    func testInboxBottomBarKeepsItsFrameAfterBackAndCancellation() {
        let app = launchChat()
        app.buttons["alo.chat.back"].tap()
        let tab = app.buttons["Лента"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 4))
        let frame = tab.frame
        app.staticTexts["Александр"].firstMatch.tap()
        XCTAssertTrue(app.buttons["alo.chat.back"].waitForExistence(timeout: 4))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4))
        start.press(forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.49, dy: 0.4)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["alo.chat.back"].exists)
        start.press(forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.4)),
                    withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(tab.waitForExistence(timeout: 4))
        XCTAssertEqual(tab.frame, frame)
        XCTAssertTrue(tab.isHittable)
        capture("bottom-bar-persistent-after-pop")
    }

    func testLegacyGlassFeedAndProfile() {
        let app = XCUIApplication()
        let arguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_LEGACY_GLASS", "1"]
        app.launchArguments = arguments + ["-ALO_UI_MESSENGER_CONTENT", "feed-surface"]
        app.launch()
        let popular = app.buttons["alo.feed.tab.popular"]
        XCTAssertTrue(popular.waitForExistence(timeout: 15))
        let frame = popular.frame
        app.scrollViews["alo.feed.scroll"].swipeUp()
        XCTAssertEqual(popular.frame, frame)
        app.buttons["alo.feed.tab.subscriptions"].tap()
        XCTAssertTrue(app.buttons["alo.feed.tab.subscriptions"].isSelected)
        capture("legacy-glass-feed")
        app.terminate()
        app.launchArguments = arguments + ["-ALO_UI_MESSENGER_CONTENT", "own-profile"]
        app.launch()
        let likes = app.buttons["alo.profile.tab.likes"]
        XCTAssertTrue(likes.waitForExistence(timeout: 15))
        likes.tap()
        XCTAssertTrue(likes.isSelected)
        app.buttons["alo.profile.tab.posts"].tap()
        app.swipeUp()
        capture("legacy-glass-profile")
    }

    func testFeedPlusAndStoryOpenDifferentEditors() {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-surface"]
        app.launch()
        let post = app.buttons["alo.feed.create-post"]
        XCTAssertTrue(post.waitForExistence(timeout: 15))
        XCTAssertTrue(post.isHittable)
        post.tap()
        XCTAssertTrue(app.buttons["alo.post.publish"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["alo.story.publish"].exists)
        capture("feed-post-editor")
        app.buttons["Закрыть редактор поста"].tap()
        let story = app.buttons["alo.feed.create-story"]
        XCTAssertTrue(story.waitForExistence(timeout: 4))
        story.tap()
        XCTAssertTrue(app.buttons["alo.story.publish"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["alo.post.publish"].exists)
        capture("feed-story-editor")
        // A text story opens straight into typing; "Готово" brings back the close button.
        let textDone = app.buttons["alo.story.tool-done"]
        if textDone.exists { textDone.tap() }
        app.buttons["Закрыть редактор истории"].tap()
        XCTAssertTrue(post.waitForExistence(timeout: 4))
        capture("feed-creation-actions")
    }

    func testOpaqueGlassAndReducedMotionKeepControlsUsable() {
        let app = launchChat(content: "forward", arguments: ["-ALO_UI_LEGACY_GLASS", "1",
            "-ALO_UI_REDUCE_MOTION", "1", "-ALO_UI_REDUCE_TRANSPARENCY", "1", "-ALO_UI_INCREASE_CONTRAST", "1"])
        let record = app.buttons["alo.chat.record-send"]
        let frame = record.frame
        record.tap()
        XCTAssertEqual(record.label, "Кружок")
        XCTAssertEqual(record.frame, frame)
        capture("opaque-glass-reduced-motion")
        app.staticTexts["alo.message.body.990200"].press(forDuration: 0.6)
        XCTAssertTrue(app.scrollViews["alo.message.actions"].waitForExistence(timeout: 4))
        app.buttons["Ответить"].tap()
        XCTAssertTrue(app.scrollViews["alo.message.actions"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
    }

    func testChatBackSwipeFromCenterAndRight() {
        for startX in [0.46, 0.76] {
            let app = launchChat()
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.4))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.4))
            start.press(forDuration: 0.02, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
            XCTAssertTrue(app.buttons["Новое сообщение"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["alo.chat.back"].waitForNonExistence(timeout: 4))
            app.terminate()
        }
    }

    func testLeftwardSwipeDoesNotCloseChat() {
        for mode in ["forward", "circle"] {
            let app = launchChat(content: mode)
            let row = app.otherElements["alo.message.990200"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            let frame = mode == "circle" ? app.buttons["alo.circle.play"].frame : measuredBubble(row)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY)).press(forDuration: 0.02,
                thenDragTo: origin.withOffset(CGVector(dx: 3, dy: frame.midY + 8)),
                withVelocity: .slow, thenHoldForDuration: 0.05)
            XCTAssertTrue(app.buttons["alo.chat.back"].exists, mode)
            XCTAssertFalse(app.buttons["Новое сообщение"].isHittable, mode)
            app.terminate()
        }
    }

    func testBackSwipeWhileMediaIsPlaying() {
        for mode in ["voice", "circle-flow"] {
            let app = launchChat(content: mode)
            let play = mode == "voice" ? app.buttons["alo.voice.play"].firstMatch : app.otherElements["alo.message.990223"].buttons["alo.circle.play"]
            XCTAssertTrue(play.waitForExistence(timeout: 5))
            play.tap()
            if mode == "circle-flow" { XCTAssertTrue(app.buttons["alo.circle.close"].waitForExistence(timeout: 4)) }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.45))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.45))
            start.press(forDuration: 0.02, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.03)
            XCTAssertTrue(app.buttons["Новое сообщение"].waitForExistence(timeout: 5), mode)
            XCTAssertTrue(app.buttons["Новое сообщение"].isHittable, mode)
            XCTAssertFalse(app.buttons["alo.chat.back"].exists, mode)
            app.terminate()
        }
    }

    func testFloatingCircleDragAndHeaderClose() {
        let app = launchChat(content: "circle-flow")
        let circle = app.otherElements["alo.message.990223"].buttons["alo.circle.play"]
        XCTAssertTrue(circle.waitForExistence(timeout: 5))
        circle.tap()
        XCTAssertTrue(app.buttons["alo.circle.close"].waitForExistence(timeout: 4))
        app.scrollViews["alo.chat.history"].swipeDown()
        let floating = app.descendants(matching: .any).matching(identifier: "alo.circle.floating").firstMatch
        capture("circle-after-scroll")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "circle-scroll-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(floating.waitForExistence(timeout: 4))
        XCTAssertEqual(floating.frame.width, 150, accuracy: 1,
            "Both tested phone containers exceed the reference's 320 pt threshold")
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.60))
        floating.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.02, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["alo.chat.back"].exists)
        XCTAssertTrue(floating.exists)
        XCTAssertLessThan(floating.frame.midX, app.frame.width * 0.5)
        XCTAssertEqual(floating.frame.minX, app.frame.minX + 4, accuracy: 1,
            "Docking uses the reference's inset inside the safe container")
        capture("circle-docked-left")
        app.buttons["alo.circle.close"].tap()
        XCTAssertTrue(floating.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.buttons["alo.circle.close"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
    }

    func testFloatingCircleSurvivesRepeatedTransfersAndCancelledBackSwipe() {
        let app = launchChat(content: "circle-flow")
        app.otherElements["alo.message.990223"].buttons["alo.circle.play"].tap()
        let pause = app.buttons["Приостановить кружок"]
        XCTAssertTrue(pause.waitForExistence(timeout: 4))
        pause.tap() // No fixture auto-advance during the repeated gesture audit.
        let floating = app.descendants(matching: .any).matching(identifier: "alo.circle.floating").firstMatch
        for index in 0..<3 {
            app.scrollViews["alo.chat.history"].swipeDown()
            XCTAssertTrue(floating.waitForExistence(timeout: 4))
            floating.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.01,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: index.isMultiple(of: 2) ? 0.2 : 0.8, dy: 0.6)),
                    withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertTrue(floating.exists)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "alo.circle.floating").count, 1)
            let down = app.buttons["alo.chat.scroll-bottom"]
            XCTAssertTrue(down.waitForExistence(timeout: 4))
            XCTAssertLessThanOrEqual(floating.frame.maxY, down.frame.minY - 4,
                "Docked video must leave the history-navigation button accessible")
            XCTAssertTrue(down.isHittable)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.35))
            start.press(forDuration: 0.01,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.49, dy: 0.35)),
                withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertTrue(app.buttons["alo.chat.back"].isHittable)
            XCTAssertTrue(floating.exists)
            capture("circle-stable-transfer-\(index)")
            floating.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(floating.waitForNonExistence(timeout: 4))
            XCTAssertTrue(app.otherElements["alo.message.990223"].buttons["alo.circle.play"].isHittable)
        }
        app.buttons["alo.circle.close"].tap()
        XCTAssertTrue(app.buttons["alo.circle.close"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
    }

    func testHistoryScrollWhileCirclePlays() {
        let app = launchChat(content: "circle-flow")
        let circle = app.otherElements["alo.message.990223"].buttons["alo.circle.play"]
        XCTAssertTrue(circle.waitForExistence(timeout: 5))
        circle.tap()
        XCTAssertTrue(app.buttons["alo.circle.close"].waitForExistence(timeout: 4))
        let row = app.otherElements["alo.message.990215"]
        let before = row.frame.minY
        app.scrollViews["alo.chat.history"].swipeDown()
        capture("circle-scroll-with-active-back-recognizer")
        XCTAssertGreaterThan(row.frame.minY, before + 100)
    }

    func testMiniatureDismissesBySwipeNotByClosingTheChat() {
        let app = launchChat(content: "circle-flow")
        app.otherElements["alo.message.990223"].buttons["alo.circle.play"].tap()
        XCTAssertTrue(app.buttons["alo.circle.close"].waitForExistence(timeout: 4))
        app.scrollViews["alo.chat.history"].swipeDown()
        let miniature = app.descendants(matching: .any).matching(identifier: "alo.circle.floating").firstMatch
        XCTAssertTrue(miniature.waitForExistence(timeout: 4))
        let start = miniature.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let edge = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.maxX - 1, dy: miniature.frame.midY))
        start.press(forDuration: 0.01, thenDragTo: edge, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["alo.circle.close"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(miniature.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.buttons["alo.chat.back"].isHittable)
        XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
    }

    func testVoiceDurationAppearsWithoutPressingPlay() {
        let app = launchChat(content: "voice")
        let duration = app.staticTexts["alo.voice.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "0:03"), object: duration)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        XCTAssertEqual(app.buttons["alo.voice.play"].label, "Воспроизвести голосовое")
    }

    func testVoiceHeaderPauseSpeedAndClose() {
        let app = launchChat(content: "voice")
        app.buttons["alo.voice.play"].tap()
        let toggle = app.buttons["alo.voice.toggle"]
        toggle.tap()
        XCTAssertEqual(toggle.label, "Продолжить голосовое")
        XCTAssertGreaterThanOrEqual(toggle.frame.width, 44)
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
        app.buttons["alo.voice.speed"].tap()
        XCTAssertTrue(app.buttons["alo.voice.speed"].label.contains("1.5"))
        app.buttons["alo.voice.close"].tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["alo.voice.play"].label.hasPrefix("Воспроизвести"))
    }

    func testMixedMediaScrollPerformance() {
        let app = launchChat(content: "media-stress")
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.36))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.77))
            from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
            to.press(forDuration: 0.01, thenDragTo: from, withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertTrue(app.buttons["alo.chat.back"].isHittable)
        XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
    }

    func testDiagonalBackSwipeAfterRecorderCancel() {
        let app = launchChat(content: "reaction-short")
        let record = app.buttons["alo.chat.record-send"]
        let origin = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.65, thenDragTo: origin.withOffset(CGVector(dx: -140, dy: 0)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 4))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.46, dy: 0.35))
        start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 160, dy: 145)),
                    withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.buttons["Новое сообщение"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["alo.chat.back"].exists)
    }

    func testBackSwipeStartsOnMessageAfterVerticalScroll() {
        let app = launchChat(content: "forward")
        let row = app.otherElements["alo.message.990200"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let bubble = measuredBubble(row)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: app.frame.width * 0.46, dy: bubble.midY))
        // Exercise the actual bubble's press guard and scroll recognizer first,
        // not the empty wallpaper used by the older navigation smoke test.
        start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 8, dy: -65)),
                    withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.buttons["alo.chat.back"].exists)
        let fresh = measuredBubble(row)
        let horizontal = origin.withOffset(CGVector(dx: app.frame.width * 0.46, dy: fresh.midY))
        horizontal.press(forDuration: 0.02,
            thenDragTo: origin.withOffset(CGVector(dx: app.frame.width - 5, dy: fresh.midY + 18)),
            withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.buttons["Новое сообщение"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["alo.chat.back"].exists)
        capture("back-from-message-after-scroll")
    }

    func testBackSwipeFromFarRightOfMessageRow() {
        let app = launchChat(content: "forward")
        let row = app.otherElements["alo.message.990200"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let bubble = measuredBubble(row)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: app.frame.width * 0.90, dy: bubble.midY)).press(
            forDuration: 0.02,
            thenDragTo: origin.withOffset(CGVector(dx: app.frame.width - 3, dy: bubble.midY + 2)),
            withVelocity: .slow, thenHoldForDuration: 0.12)
        XCTAssertTrue(app.buttons["Новое сообщение"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["alo.chat.back"].exists)
        capture("back-from-rightmost-message-row")
    }

    func testBackSwipeAcrossInteractiveMessageContent() {
        for mode in ["forward", "media", "poll", "links"] {
            let app = launchChat(content: mode)
            let row = app.otherElements["alo.message.990200"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), mode)
            let bubble = measuredBubble(row)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let y = mode == "poll" ? bubble.minY + 18 : bubble.midY
            let x = min(app.frame.width * 0.46, bubble.midX)
            origin.withOffset(CGVector(dx: x, dy: y)).press(forDuration: 0.02,
                thenDragTo: origin.withOffset(CGVector(dx: app.frame.width - 5, dy: y + 15)),
                withVelocity: .slow, thenHoldForDuration: 0.05)
            XCTAssertTrue(app.buttons["Новое сообщение"].waitForExistence(timeout: 5), mode)
            XCTAssertFalse(app.buttons["alo.chat.back"].exists, mode)
            app.terminate()
        }
    }

    func testScrubbingOwnsHorizontalTouch() {
        for mode in ["voice", "circle"] {
            let app = launchChat(content: mode)
            let play = app.buttons["alo.\(mode).play"]
            XCTAssertTrue(play.waitForExistence(timeout: 5))
            let origin = app.coordinate(withNormalizedOffset: .zero)
            if mode == "voice" {
                let waveform = app.otherElements["alo.voice.scrubber"]
                XCTAssertTrue(waveform.waitForExistence(timeout: 3))
                let frame = waveform.frame
                origin.withOffset(CGVector(dx: frame.minX + 5, dy: frame.midY)).press(forDuration: 0.02,
                    thenDragTo: origin.withOffset(CGVector(dx: frame.maxX - 5, dy: frame.midY)),
                    withVelocity: .slow, thenHoldForDuration: 0.05)
            } else {
                let frame = play.frame
                origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + 6)).press(forDuration: 0.02,
                    thenDragTo: origin.withOffset(CGVector(dx: frame.maxX - 6, dy: frame.midY)),
                    withVelocity: .slow, thenHoldForDuration: 0.05)
            }
            XCTAssertTrue(app.buttons["alo.chat.back"].isHittable, mode)
            XCTAssertTrue(play.exists, mode)
            app.terminate()
        }
    }

    func testComposerGlassAndModesKeepGeometry() {
        let app = launchChat(arguments: ["-ALO_UI_MESSENGER_SURFACE", "1"])
        let record = app.buttons["alo.chat.record-send"]
        let attach = app.buttons["alo.chat.attach"]
        let original = record.frame
        XCTAssertEqual(original.width, 48, accuracy: 1)
        XCTAssertEqual(original.height, 48, accuracy: 1)
        XCTAssertEqual(original.midY, attach.frame.midY, accuracy: 1)
        capture("composer-glass-voice")
        record.tap()
        XCTAssertEqual(record.label, "Кружок")
        XCTAssertEqual(record.frame, original)
        capture("composer-glass-circle")
        record.tap()
        XCTAssertEqual(record.label, "Голосовое")
        let composer = field(app, "alo.chat.composer")
        composer.tap()
        composer.typeText("Черновик без отправки")
        XCTAssertEqual(record.label, "Отправить")
        XCTAssertEqual(record.frame.width, original.width, accuracy: 1)
        XCTAssertEqual(record.frame.midY, attach.frame.midY, accuracy: 1)
        capture("composer-glass-keyboard-send")
    }

    func testLegacyBackBridgeAndModalIsolation() {
        let app = launchChat(content: "forward", arguments: ["-ALO_UI_LEGACY_BACK", "1"])
        app.buttons["alo.chat.attach"].tap()
        let close = app.buttons["Закрыть вложения"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4)).press(forDuration: 0.02,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.4)),
            withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(app.buttons["alo.chat.back"].isHittable)
        let row = app.otherElements["alo.message.990200"]
        let bubble = measuredBubble(row)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: app.frame.width * 0.46, dy: bubble.midY)).press(forDuration: 0.02,
            thenDragTo: origin.withOffset(CGVector(dx: app.frame.width - 5, dy: bubble.midY)),
            withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.buttons["Новое сообщение"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["alo.chat.back"].exists)
    }

    func testShortCenterSwipeAndComposerDragDoNotCloseChat() {
        let app = launchChat()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4))
        start.press(forDuration: 0.02,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.4)),
                    withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.buttons["alo.chat.back"].exists)
        let input = field(app, "alo.chat.composer")
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).press(forDuration: 0.02,
            thenDragTo: input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(app.buttons["alo.chat.back"].exists)
    }

    func testAutoDeleteLivesInChatMenuNotPeerProfile() {
        let app = launchChat()
        app.buttons["alo.chat.info"].press(forDuration: 0.6)
        let action = app.buttons["Автоудаление сообщений"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
        XCTAssertTrue(app.navigationBars["Автоудаление"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["1 неделя"].exists)
        XCTAssertFalse(app.buttons["Сохранить"].isEnabled)
        capture("auto-delete-chat-menu")
        app.buttons["Отмена"].tap()
        app.buttons["alo.chat.info"].tap()
        XCTAssertTrue(app.buttons["alo.peer.more"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Автоудаление сообщений"].exists)
        capture("peer-without-auto-delete-card")
    }

    func testVoiceHoldLockAndCancelRestoresComposer() {
        let app = launchChat()
        let record = app.buttons["alo.chat.record-send"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        let origin = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.65, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -110)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        let stop = app.buttons["Завершить и прослушать запись"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        capture("voice-recording-locked")
        app.buttons["Удалить запись"].tap()
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 5))
        XCTAssertTrue(record.exists)
        XCTAssertFalse(stop.exists)
    }

    func testVoiceStopPreviewsWithoutSending() {
        let app = launchChat(content: "reaction-short")
        let record = app.buttons["alo.chat.record-send"]
        let origin = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.7, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -115)),
                     withVelocity: .slow, thenHoldForDuration: 0.15)
        let stop = app.buttons["Завершить и прослушать запись"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        capture("voice-locked-controls")
        stop.tap()
        XCTAssertTrue(app.buttons["alo.recording.preview-play"].waitForExistence(timeout: 8))
        XCTAssertEqual(record.label, "Отправить")
        XCTAssertEqual(app.otherElements.matching(NSPredicate(format: "identifier MATCHES 'alo.message.[0-9]+' ")).count, 1)
        capture("voice-stop-preview-not-sent")
        app.buttons["alo.recording.preview-play"].tap()
        XCTAssertTrue(app.buttons["Приостановить предпросмотр"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Прослушать запись"].waitForExistence(timeout: 8), "Playback must reset after reaching the end")
        app.buttons["Удалить черновик записи"].tap()
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 4))
    }

    func testRecordingSlideCancelAndCircleLock() {
        let app = launchChat(arguments: ["-ALO_UI_RECORDING_FIXTURE", "1", "-ALO_UI_MESSENGER_SURFACE", "1"])
        let record = app.buttons["alo.chat.record-send"]
        var origin = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.65, thenDragTo: origin.withOffset(CGVector(dx: -140, dy: 0)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 4))
        XCTAssertEqual(record.label, "Голосовое")
        record.tap()
        XCTAssertEqual(record.label, "Кружок")
        origin = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.65, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -115)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["Завершить и просмотреть кружок"].waitForExistence(timeout: 4))
        let camera = app.descendants(matching: .any).matching(identifier: "alo.circle.recording.camera").firstMatch
        XCTAssertTrue(camera.exists)
        XCTAssertEqual(camera.frame.width, min(404, app.frame.width - 24), accuracy: 1)
        XCTAssertEqual(camera.frame.width, camera.frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(camera.frame.minY, app.buttons["alo.chat.back"].frame.maxY)
        XCTAssertLessThan(camera.frame.maxY, app.buttons["alo.circle.recording.flip"].frame.minY)
        XCTAssertTrue(app.buttons["Переключить камеру"].isHittable)
        app.buttons["alo.circle.recording.flip"].tap()
        XCTAssertTrue(app.buttons["Завершить и просмотреть кружок"].exists, "Camera toggle must never send/finish a locked recording")
        capture("circle-recording-locked-layout")
        app.buttons["Удалить запись"].tap()
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 4))
        XCTAssertEqual(record.label, "Кружок")
    }

    func testEncryptedCircleDraftPlaybackAndDelete() {
        let app = launchChat(content: "circle-draft")
        let play = app.buttons["alo.circle.draft-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        let count = app.otherElements.matching(NSPredicate(format: "identifier MATCHES 'alo.message.[0-9]+' ")).count
        XCTAssertEqual(app.buttons["alo.chat.record-send"].label, "Отправить")
        let label = app.staticTexts["Кружок готов к отправке"]
        XCTAssertTrue(label.exists)
        XCTAssertLessThanOrEqual(label.frame.maxY, app.buttons["Удалить черновик записи"].frame.maxY)
        play.tap()
        XCTAssertTrue(app.buttons["Приостановить предпросмотр кружка"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Посмотреть кружок"].waitForExistence(timeout: 8), "End of movie must restore Play")
        XCTAssertEqual(app.otherElements.matching(NSPredicate(format: "identifier MATCHES 'alo.message.[0-9]+' ")).count, count)
        capture("encrypted-circle-draft-preview")
        app.buttons["Удалить черновик записи"].tap()
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 4))
        XCTAssertFalse(play.exists)
    }

    func testTimestampAnchorsForPlainAndRichText() {
        let app = launchChat(content: "time-layout")
        for id in 990200...990204 {
            let row = app.otherElements["alo.message.\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 4))
            let bubble = measuredBubble(row)
            let time = row.descendants(matching: .any).matching(identifier: "alo.message.time.\(id)").firstMatch
            XCTAssertTrue(time.exists)
            // AX reports the stroked path, not its 15 pt layout slot. A single
            // sent tick ends at x=12 + half its 1.25 pt stroke (2.375 pt inset).
            let tickInkInset: CGFloat = id == 990202 ? 15 - 12 - 1.25 / 2 : 0
            // Telegram: own checks run 5 pt into the 11 pt side inset; the time sits 1 pt below the
            // last line; a single line is centred in the 35 pt minimum bubble.
            let isMine = id == 990202 || id == 990204
            XCTAssertEqual(bubble.maxX - time.frame.maxX, (isMine ? 6 : 11) + tickInkInset, accuracy: 1)
            let singleLine = bubble.height < 40
            if singleLine { XCTAssertEqual(bubble.height, 35, accuracy: 0.5) }
            XCTAssertEqual(bubble.maxY - time.frame.maxY, singleLine ? 6 + 1 / 3 : 5, accuracy: 1)
        }
        let plain = measuredBubble(app.otherElements["alo.message.990200"])
        let rich = measuredBubble(app.otherElements["alo.message.990201"])
        XCTAssertEqual(plain.height, rich.height, accuracy: 1, "Formatting alone must not add a status row")
        capture("timestamps-plain-rich-multiline")
    }

    func testPeerActionsRespondAndSearchFocuses() {
        let app = launchChat()
        app.buttons["alo.chat.info"].tap()
        XCTAssertTrue(app.buttons["alo.peer.back"].waitForExistence(timeout: 4))
        capture("peer-actions")
        for kind in ["audio", "video"] {
            let call = app.buttons["alo.peer.call.\(kind)"]
            XCTAssertTrue(call.isHittable)
            call.tap()
            let message = kind == "audio" ? "UI-тест: аудиозвонок. Сеть не используется." : "UI-тест: видеозвонок. Сеть не используется."
            XCTAssertTrue(app.alerts.staticTexts[message].waitForExistence(timeout: 4))
            app.alerts.buttons["Ок"].tap()
        }
        app.buttons["Звук"].tap()
        XCTAssertTrue(app.buttons["Со звуком"].waitForExistence(timeout: 3))
        app.buttons["Со звуком"].tap()
        XCTAssertTrue(app.buttons["Звук"].waitForExistence(timeout: 3))
        app.buttons["alo.peer.more"].tap()
        XCTAssertTrue(app.buttons["Медиа"].waitForExistence(timeout: 3))
        app.buttons["Медиа"].tap()
        XCTAssertTrue(app.buttons["alo.peer.tab.photos"].isHittable)
        app.scrollViews["alo.peer.scroll"].swipeDown()
        // The tab bar's "Поиск" stays in the XCUI tree behind the chat, so use the peer action's id.
        app.buttons["alo.peer.action.search"].firstMatch.tap()
        let search = field(app, "alo.peer.search")
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        search.typeText("Привет")
        XCTAssertTrue(app.buttons["alo.peer.search-result.990100"].waitForExistence(timeout: 4))
        capture("peer-search-focused")
        app.buttons["alo.peer.search-result.990100"].tap()
        XCTAssertTrue(app.buttons["alo.peer.back"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
    }

    func testPollVotingKeepsWidthAndShowsResults() {
        let app = launchChat(content: "poll")
        let row = app.otherElements["alo.message.990200"]
        let initial = measuredBubble(row)
        let first = app.buttons["alo.poll.option.park"]
        let second = app.buttons["alo.poll.option.lake"]
        capture("poll-before-vote")
        first.tap()
        XCTAssertTrue(first.isSelected)
        XCTAssertTrue(first.staticTexts["100%"].exists)
        XCTAssertLessThan(first.staticTexts["100%"].frame.height, 22, "Percentage must stay on one line")
        let fullPercentageWidth = ("100%" as NSString).size(withAttributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
        ]).width
        XCTAssertGreaterThanOrEqual(first.staticTexts["100%"].frame.width, fullPercentageWidth - 1,
                                    "A readable AX label does not prove that its glyphs fit without truncation")
        XCTAssertEqual(measuredBubble(row).width, initial.width, accuracy: 1)
        capture("poll-after-vote")
        second.tap()
        XCTAssertTrue(second.isSelected)
        XCTAssertFalse(first.isSelected)
        XCTAssertEqual(measuredBubble(row).width, initial.width, accuracy: 1)
        capture("poll-changed-vote")
    }

    func testPollFullPercentageAtAccessibilitySize() {
        let app = launchChat(accessibility: true, content: "poll")
        let first = app.buttons["alo.poll.option.park"]
        first.tap()
        let percentage = first.staticTexts["100%"]
        XCTAssertTrue(percentage.waitForExistence(timeout: 4))
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 12.5, weight: .bold), compatibleWith: traits)
        let width = ("100%" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThanOrEqual(percentage.frame.width, width - 2)
        XCTAssertLessThanOrEqual(first.frame.maxX, app.frame.maxX)
        capture("poll-full-percentage-accessibility")
    }

    func testPeerMediaSwipesBothWaysAndKeepsBack() {
        let app = launchChat(content: "profile")
        app.buttons["alo.chat.info"].tap()
        app.buttons["alo.peer.more"].tap()
        app.buttons["Медиа"].tap()
        let photos = app.buttons["alo.peer.tab.photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 4))
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let pinnedY = photos.frame.minY
        func swipe(_ left: Bool) {
            let y = photos.frame.maxY + 95
            origin.withOffset(CGVector(dx: app.frame.width * (left ? 0.8 : 0.2), dy: y))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * (left ? 0.2 : 0.8), dy: y)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        for tab in ["videos", "voices", "files"] {
            swipe(true)
            XCTAssertTrue(app.buttons["alo.peer.tab.\(tab)"].isSelected, tab)
            XCTAssertTrue(app.buttons["alo.peer.back"].isHittable, "A swipe must not open a photo")
            XCTAssertEqual(photos.frame.minY, pinnedY, accuracy: 1, "Empty tabs must not move the profile")
            capture("peer-swipe-\(tab)")
        }
        swipe(true)
        XCTAssertTrue(app.buttons["alo.peer.tab.files"].isSelected)
        for tab in ["voices", "videos", "photos"] {
            swipe(false)
            XCTAssertTrue(app.buttons["alo.peer.tab.\(tab)"].isSelected, tab)
        }
        XCTAssertTrue(app.buttons["alo.peer.media.0"].isHittable)
        XCTAssertTrue(app.buttons["alo.peer.back"].isHittable)
        capture("peer-swipe-returned-photos")
        let y = photos.frame.midY
        origin.withOffset(CGVector(dx: app.frame.width * 0.8, dy: y))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * 0.2, dy: y)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["alo.peer.tab.videos"].isSelected, "The tab bar itself is swipeable too")
    }

    func testFloatingFeedAndRoundedProfileTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-surface"]
        app.launch()
        let popular = app.buttons["alo.feed.tab.popular"]
        let subscriptions = app.buttons["alo.feed.tab.subscriptions"]
        XCTAssertTrue(popular.waitForExistence(timeout: 15))
        XCTAssertTrue(popular.isSelected)
        // Layout can land a hair under 44 pt (43.99999…); that is still a 44 pt target.
        XCTAssertGreaterThanOrEqual(popular.frame.height, 44 - 0.01)
        XCTAssertEqual(subscriptions.frame.minX - popular.frame.maxX, 0, accuracy: 1)
        XCTAssertEqual(popular.frame.width, subscriptions.frame.width, accuracy: 1)
        XCTAssertGreaterThan(popular.frame.width * 2, app.frame.width * 0.8)
        let frame = popular.frame
        app.scrollViews["alo.feed.scroll"].swipeUp()
        XCTAssertEqual(popular.frame, frame)
        capture("feed-floating-over-posts")
        subscriptions.tap()
        XCTAssertTrue(subscriptions.isSelected)
        popular.tap()
        XCTAssertTrue(popular.isSelected)
        app.terminate()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "own-profile"]
        app.launch()
        let likes = app.buttons["alo.profile.tab.likes"]
        XCTAssertTrue(likes.waitForExistence(timeout: 15))
        likes.tap()
        XCTAssertTrue(likes.isSelected)
        capture("profile-rounded-tabs")
        XCTAssertGreaterThanOrEqual(likes.frame.height, 44 - 0.01)
        app.buttons["alo.profile.tab.posts"].tap()
        app.swipeUp()
        capture("profile-tabs-over-scrolled-posts")
    }

    func testReactionMutationPreservesMessageGeometry() {
        for mode in ["reaction-short", "reaction-own", "reaction-long", "forward", "media"] {
            let app = launchChat(content: mode)
            let body = app.staticTexts["alo.message.body.990200"]
            let row = app.otherElements["alo.message.990200"]
            XCTAssertTrue(body.waitForExistence(timeout: 4), mode)
            let originalText = body.frame
            let originalBubble = measuredBubble(row)
            let offset = originalText.minX - originalBubble.minX
            capture("\(mode)-before")

            func assertStable() {
                XCTAssertEqual(body.frame.width, originalText.width, accuracy: 1, mode)
                XCTAssertEqual(body.frame.height, originalText.height, accuracy: 1, mode)
                XCTAssertEqual(measuredBubble(row).width, originalBubble.width, accuracy: 1, mode)
                XCTAssertEqual(body.frame.minX - measuredBubble(row).minX, offset, accuracy: 1, mode)
            }
            func choose(_ emoji: String) {
                body.press(forDuration: 0.6)
                let choice = app.buttons["Реакция \(emoji)"]
                XCTAssertTrue(choice.waitForExistence(timeout: 4), mode)
                choice.tap()
                XCTAssertTrue(choice.waitForNonExistence(timeout: 4), mode)
            }

            // Quick reactions come from the strip shown first (❤️ 🥰 …), not the expanded catalogue.
            choose("❤️")
            assertStable()
            capture("\(mode)-after-reaction")
            choose("🥰")
            assertStable()
            let chip = row.buttons["🥰, 1"]
            XCTAssertTrue(chip.waitForExistence(timeout: 3), mode)
            // AX converts the frame through animated ancestors: a 44 pt
            // target can be reported as 43.99999999999994, not a smaller control.
            XCTAssertGreaterThanOrEqual(chip.frame.height, 44 - 0.01)
            chip.tap()
            assertStable()
            XCTAssertEqual(measuredBubble(row).height, originalBubble.height, accuracy: 1, mode)
            capture("\(mode)-removed-reaction")
            app.terminate()
        }
    }

    func testContextHoldOnlyTargetsTheVisibleBubble() {
        let app = launchChat(content: "reaction-short")
        let row = app.otherElements["alo.message.990200"]
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        let frame = measuredBubble(row)
        XCTAssertLessThan(frame.maxX + 24, app.frame.maxX)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.maxX + 24, dy: frame.midY))
            .press(forDuration: 0.6)
        XCTAssertFalse(app.scrollViews["alo.message.actions"].exists)
        app.staticTexts["alo.message.body.990200"].press(forDuration: 0.6)
        XCTAssertTrue(app.scrollViews["alo.message.actions"].waitForExistence(timeout: 4))
    }

    func testReactionCountsWrapInsideBubble() {
        let app = launchChat(content: "reaction-counts")
        let row = app.otherElements["alo.message.990200"]
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        let original = measuredBubble(row)
        let heart = row.buttons["❤️, 999"]
        XCTAssertTrue(heart.isHittable)
        heart.tap()
        let selectedHeart = row.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "❤️,")).firstMatch
        XCTAssertEqual(selectedHeart.label.filter(\.isNumber), "1000")
        XCTAssertEqual(measuredBubble(row).width, original.width, accuracy: 1)
        for chip in row.buttons.allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(chip.frame.minX, measuredBubble(row).minX)
            XCTAssertLessThanOrEqual(chip.frame.maxX, measuredBubble(row).maxX + 1)
            XCTAssertLessThanOrEqual(chip.frame.maxY, row.frame.maxY + 1)
        }
        capture("reaction-many-counts-selected")
        selectedHeart.tap()
        XCTAssertTrue(row.buttons["❤️, 999"].waitForExistence(timeout: 3))
        XCTAssertEqual(measuredBubble(row).height, original.height, accuracy: 1)
    }

    func testFeedCountsDoNotMoveActionsOrText() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed"]
        app.launch()
        XCTAssertTrue(app.scrollViews["alo.feed.fixture"].waitForExistence(timeout: 15))
        let body = app.staticTexts["alo.post.body.990400"]
        let originalBody = body.frame
        let ids = ["like", "comments", "repost"]
        let buttons = ids.map { app.buttons["alo.post.\($0).990400"] }
        let original = buttons.map(\.frame)
        XCTAssertEqual(buttons[0].frame.minY - body.frame.maxY, 2, accuracy: 1)
        let card = app.otherElements["alo.post.card.990400"]
        XCTAssertTrue(card.exists)
        XCTAssertEqual(card.frame.maxY - buttons[0].frame.maxY, 2, accuracy: 1)
        capture("feed-cards-before")
        buttons[0].tap()
        XCTAssertEqual((buttons[0].value as? String)?.filter(\.isNumber), "1000")
        buttons[2].tap()
        XCTAssertEqual(buttons[2].value as? String, "10")
        for (index, button) in buttons.enumerated() {
            XCTAssertEqual(button.frame.minX, original[index].minX, accuracy: 1)
            XCTAssertEqual(button.frame.width, original[index].width, accuracy: 1)
            // AX can return 43.99999999999997 for a 44-pt frame on 3x devices.
            XCTAssertGreaterThanOrEqual(button.frame.height + 0.001, 44)
        }
        XCTAssertEqual(body.frame, originalBody)
        capture("feed-cards-liked-reposted")
        buttons[0].tap()
        buttons[2].tap()
        XCTAssertEqual(buttons[0].value as? String, "999")
        XCTAssertEqual(buttons[2].value as? String, "9")
        for postID in [990400, 990401] {
            for id in ids {
                let button = app.buttons["alo.post.\(id).\(postID)"]
                XCTAssertGreaterThanOrEqual(button.frame.width, 44)
                XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
                XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
            }
        }
        let media = app.descendants(matching: .any).matching(identifier: "alo.post.media.990402").firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 10))
        app.scrollViews["alo.feed.fixture"].swipeUp()
        let mediaLike = app.buttons["alo.post.like.990402"]
        XCTAssertTrue(mediaLike.isHittable)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "alo.post.media.loaded").firstMatch.waitForExistence(timeout: 5), "Capture loaded media, not an empty loading placeholder")
        XCTAssertEqual(mediaLike.frame.minY - media.frame.maxY, 2, accuracy: 1)
        XCTAssertEqual(app.otherElements["alo.post.card.990402"].frame.maxY - mediaLike.frame.maxY, 2, accuracy: 1)
        capture("compact-media-post-actions")
    }

    func testReactionChipsUseAvailableWidth() {
        let app = launchChat(content: "forward")
        let row = app.otherElements["alo.message.990200"]
        let chips = ["❤️, 12", "👍, 128", "🔥, 24", "🎉, 3"].map { row.buttons[$0] }
        for chip in chips {
            XCTAssertTrue(chip.waitForExistence(timeout: 3))
            XCTAssertGreaterThanOrEqual(chip.frame.height, 44)
            XCTAssertGreaterThanOrEqual(chip.frame.width, 44)
            XCTAssertLessThanOrEqual(chip.frame.maxX, row.frame.maxX)
        }
        if app.windows.firstMatch.frame.width >= 375 {
            let tops = chips.map { $0.frame.minY }
            XCTAssertLessThan((tops.max() ?? 0) - (tops.min() ?? 0), 1, "Metadata must not force four reactions onto two rows at 375 pt.")
        }
        capture("reaction-width-offline-fixture")
    }

    func testReactionRowPitchAndTimestampInset() {
        let app = launchChat(content: "reaction-counts")
        let row = app.otherElements["alo.message.990200"]
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        let chips = row.buttons.allElementsBoundByIndex.filter { $0.label.contains(",") }
        let tops = Array(Set(chips.map { Int($0.frame.minY.rounded()) })).sorted()
        XCTAssertGreaterThan(tops.count, 1, "Fixture must exercise wrapping")
        for (first, second) in zip(tops, tops.dropFirst()) {
            XCTAssertLessThanOrEqual(second - first, 40, "No second-row vertical drift")
            XCTAssertGreaterThanOrEqual(second - first, 36)
        }
        let time = row.descendants(matching: .any).matching(identifier: "alo.message.time.990200").firstMatch
        XCTAssertTrue(time.exists)
        XCTAssertEqual(measuredBubble(row).maxX - time.frame.maxX, 10, accuracy: 1)
        capture("compact-reaction-rows")
        app.terminate()
        let chat = launchChat()
        let first = chat.otherElements["alo.message.990100"]
        let firstTime = first.descendants(matching: .any).matching(identifier: "alo.message.time.990100").firstMatch
        XCTAssertTrue(firstTime.exists)
        XCTAssertEqual(measuredBubble(first).maxX - firstTime.frame.maxX, 10, accuracy: 1)
        capture("text-trailing-time")
    }

    func testMediaEdgesAndContextMenuBreathingRoom() {
        let app = launchChat(content: "media")
        let row = app.otherElements["alo.message.990200"]
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        let media = row.descendants(matching: .any).matching(identifier: "alo.message.media.990200").firstMatch
        XCTAssertTrue(media.exists)
        XCTAssertEqual(media.frame.minX, measuredBubble(row).minX, accuracy: 1)
        XCTAssertEqual(media.frame.maxX, measuredBubble(row).maxX, accuracy: 1)
        capture("media-edge-to-edge")
        row.staticTexts["alo.message.body.990200"].press(forDuration: 0.6)
        let menu = app.scrollViews["alo.message.actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 4))
        let copy = app.buttons["Скопировать"]
        XCTAssertGreaterThanOrEqual(copy.frame.minY - menu.frame.minY, 12)
        let select = app.buttons["Выбрать"]
        if select.isHittable, select.frame.maxY < menu.frame.maxY {
            XCTAssertGreaterThanOrEqual(menu.frame.maxY - select.frame.maxY, 12)
        }
        capture("context-padded-media")
    }

    func testChannelCommentsFollowMediaAndReactions() {
        let app = launchChat(content: "channel-media")
        let row = app.otherElements["alo.message.990200"]
        let comments = row.buttons["alo.message.comments.990200"]
        XCTAssertTrue(comments.waitForExistence(timeout: 4))
        let reaction = row.buttons["❤️, 190"]
        XCTAssertTrue(reaction.exists)
        XCTAssertGreaterThanOrEqual(comments.frame.minY, reaction.frame.maxY - 1)
        let time = row.descendants(matching: .any).matching(identifier: "alo.message.time.990200").firstMatch
        XCTAssertLessThan(time.frame.maxY, comments.frame.minY)
        XCTAssertEqual(measuredBubble(row).maxX - time.frame.maxX, 11, accuracy: 1)
        XCTAssertEqual(reaction.frame.minX - measuredBubble(row).minX, 11, accuracy: 1)
        capture("channel-media-comments")
    }

    func testInboxPreviewShowsConversationAndOpens() {
        let app = launchChat(content: "forward")
        app.buttons["alo.chat.back"].tap()
        // Let the chat finish closing, otherwise the header title matches before the inbox row.
        XCTAssertTrue(app.buttons["alo.chat.back"].waitForNonExistence(timeout: 5))
        let row = app.staticTexts["Александр"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.press(forDuration: 0.6)
        let preview = app.otherElements["alo.chat.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Пересланное сообщение с ответом и реакциями."].exists)
        XCTAssertFalse(app.buttons["Лента"].isHittable, "Tab bar must stay behind the modal preview")
        capture("inbox-chat-preview")
        app.buttons["Открыть чат"].tap()
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 4))
        XCTAssertFalse(preview.exists)
        app.buttons["alo.chat.back"].tap()
        XCTAssertTrue(app.buttons["alo.chat.back"].waitForNonExistence(timeout: 5))
        let inboxRow = app.staticTexts["Александр"].firstMatch
        XCTAssertTrue(inboxRow.waitForExistence(timeout: 4))
        inboxRow.tap()
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 4), "A short tap must still open the chat directly")
    }

    func testContentFitsAndSelectionOwnsTaps() {
        for mode in ["poll", "voice", "circle", "forward", "links", "media"] {
            let app = launchChat(content: mode)
            let row = app.otherElements["alo.message.990200"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), mode)
            let screen = app.windows.firstMatch.frame
            XCTAssertGreaterThanOrEqual(row.frame.minX, 0, mode)
            XCTAssertLessThanOrEqual(row.frame.maxX, screen.maxX + 1, mode)
            for child in row.descendants(matching: .any).allElementsBoundByIndex
            where [.button, .image, .staticText].contains(child.elementType) && child.frame.width > 0 {
                XCTAssertGreaterThanOrEqual(child.frame.minX, -1, "\(mode): \(child.label)")
                XCTAssertLessThanOrEqual(child.frame.maxX, screen.maxX + 1, "\(mode): \(child.label)")
            }
            capture("content-\(mode)-offline-fixture")
            // Press the message itself, not an embedded play/vote control.
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.12)).press(forDuration: 0.6)
            XCTAssertTrue(app.buttons["Выбрать"].waitForExistence(timeout: 4), mode)
            capture("context-\(mode)-offline-fixture")
            selectMessage(app)
            let selected = app.buttons["alo.message.select.990200"]
            XCTAssertTrue(selected.waitForExistence(timeout: 3), mode)
            XCTAssertLessThanOrEqual(selected.frame.maxX, screen.maxX + 1, mode)
            capture("selected-\(mode)-offline-fixture")
            selected.tap()
            XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 3), mode)
            app.terminate()
        }
    }

    func testPeerMediaAndPersistentBack() {
        let app = launchChat(content: "media")
        app.buttons["alo.chat.info"].tap()
        let back = app.buttons["alo.peer.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        capture("peer-profile-offline-fixture")
        app.swipeUp()
        XCTAssertTrue(back.isHittable)
        let photo = app.buttons["alo.peer.media.0"]
        XCTAssertTrue(photo.waitForExistence(timeout: 3))
        photo.tap()
        capture("peer-media-viewer-offline-fixture")
        XCTAssertTrue(app.buttons["alo.media.close"].waitForExistence(timeout: 3))
        app.buttons["alo.media.close"].tap()
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 3))
    }

    func testPeerStickyTabsAndMediaReturn() {
        let app = launchChat(content: "profile")
        app.buttons["alo.chat.info"].tap()
        let back = app.buttons["alo.peer.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        capture("peer-expanded-header-offline-fixture")
        let scroll = app.scrollViews["alo.peer.scroll"]
        scroll.swipeUp()
        scroll.swipeUp()
        let photos = app.buttons["alo.peer.tab.photos"]
        XCTAssertTrue(photos.isHittable)
        let pinnedY = photos.frame.minY
        XCTAssertGreaterThanOrEqual(pinnedY, back.frame.maxY)
        XCTAssertLessThan(pinnedY - back.frame.maxY, 30)
        scroll.swipeUp()
        XCTAssertEqual(photos.frame.minY, pinnedY, accuracy: 1)
        XCTAssertTrue(back.isHittable)
        capture("peer-pinned-media-offline-fixture")

        // Open an actual visible tile, not a lazy off-screen accessibility node.
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "alo.peer.media."))
            .allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.minY > photos.frame.maxY && $0.frame.maxY < app.frame.maxY
            }
        XCTAssertNotNil(tile)
        guard let tile else { return }
        let tileFrame = tile.frame
        let minimumCloseY = back.frame.minY
        tile.tap()
        let close = app.buttons["alo.media.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(close.frame.minY, minimumCloseY)
        let position = app.staticTexts["alo.media.position"]
        let oldPosition = position.label
        app.swipeLeft()
        XCTAssertNotEqual(position.label, oldPosition)
        capture("peer-media-paging-offline-fixture")
        close.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        XCTAssertEqual(tile.frame.minY, tileFrame.minY, accuracy: 2)
        XCTAssertEqual(photos.frame.minY, pinnedY, accuracy: 1)

        app.buttons["alo.peer.tab.files"].tap()
        XCTAssertTrue(app.staticTexts["Файлов пока нет"].waitForExistence(timeout: 3))
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 3))
    }

    func testPeerSwipeCancellationAndReturn() {
        let app = launchChat(content: "media")
        app.buttons["alo.chat.info"].tap()
        let back = app.buttons["alo.peer.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 4))
        let original = back.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 6, dy: original.maxY + 24))
        start.press(forDuration: 0.1,
                    thenDragTo: origin.withOffset(CGVector(dx: 45, dy: original.maxY + 24)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(back.isHittable)
        XCTAssertEqual(back.frame.minX, original.minX, accuracy: 1)
        capture("peer-cancelled-back-swipe-offline-fixture")
        start.press(forDuration: 0.1,
                    thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * 0.8, dy: original.maxY + 24)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(back.waitForNonExistence(timeout: 3))
        XCTAssertTrue(field(app, "alo.chat.composer").isHittable)
        XCTAssertTrue(app.buttons["alo.chat.info"].isHittable, "Profile swipe must not also close the conversation.")
    }

    func testDeviceRotationPreservesPortraitChat() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchChat()
        XCTAssertLessThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        XCTAssertTrue(app.buttons["alo.chat.back"].isHittable)
        XCTAssertTrue(app.buttons["alo.chat.attach"].isHittable)
        capture("chat-portrait-lock-offline-fixture")
        field(app, "alo.chat.composer").tap()
        field(app, "alo.chat.composer").typeText("Landscape")
        XCTAssertTrue(app.buttons["alo.chat.attach"].isHittable)
        capture("chat-portrait-lock-keyboard-offline-fixture")
    }

    func testLargeTextPoll() {
        let app = launchChat(accessibility: true)
        XCTAssertTrue(app.buttons["alo.chat.back"].isHittable)
        capture("chat-large-text-offline-fixture")
        app.buttons["alo.chat.attach"].tap()
        let poll = app.buttons["alo.attachments.poll"]
        XCTAssertTrue(poll.waitForExistence(timeout: 5))
        poll.tap()
        let question = field(app, "alo.poll.question")
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.tap()
        question.typeText("Accessible poll")
        capture("poll-large-text-offline-fixture")
        XCTAssertTrue(app.buttons["Отмена"].isHittable)
        app.buttons["Отмена"].tap()
        app.buttons["Удалить черновик"].tap()
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 5))
    }

    func testVoiceAndCirclePlaybackControls() {
        for mode in ["voice", "circle"] {
            let app = launchChat(content: mode)
            let control = app.buttons["alo.\(mode).play"]
            XCTAssertTrue(control.waitForExistence(timeout: 4))
            control.tap()
            let playing = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label BEGINSWITH %@", "Приостановить"), object: control)
            XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 3), .completed, mode)
            if mode == "voice" {
                let title = app.staticTexts["alo.voice.sender-title"]
                XCTAssertTrue(title.waitForExistence(timeout: 2))
                XCTAssertFalse(title.label.contains(".m4a"))
                XCTAssertFalse(title.label.hasPrefix("voice-"))
            }
            capture("playing-\(mode)-offline-fixture")
            control.tap()
            XCTAssertTrue(control.label.hasPrefix("Воспроизвести"), mode)
            app.terminate()
        }
    }

    func testLongPressPlaybackDoesNotStart() {
        for mode in ["voice", "circle"] {
            let app = launchChat(content: mode)
            // The context preview has its own play control; inspect the real row.
            let control = app.otherElements["alo.message.990200"].buttons["alo.\(mode).play"]
            XCTAssertTrue(control.waitForExistence(timeout: 4))
            // Hold beyond the transition cooldown: a menu that remains open
            // must still suppress playback when the finger finally lifts.
            control.press(forDuration: 1.2)
            let select = app.buttons["Выбрать"]
            XCTAssertTrue(select.waitForExistence(timeout: 4), mode)
            XCTAssertTrue(control.label.hasPrefix("Воспроизвести"), mode)
            capture("long-press-\(mode)-offline-fixture")
            selectMessage(app)
            let selected = app.buttons["alo.message.select.990200"]
            XCTAssertTrue(selected.waitForExistence(timeout: 3), mode)
            selected.tap()
            XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 3), mode)
            app.terminate()
        }
    }

    func testExpandedReactionsKeepMenuReachable() {
        let app = launchChat(content: "forward")
        let row = app.otherElements["alo.message.990200"]
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.12)).press(forDuration: 0.6)
        let expand = app.buttons["Все реакции"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        expand.tap()
        let collapse = app.buttons["Свернуть реакции"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 3))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(collapse.frame.minY, 20)
        XCTAssertLessThanOrEqual(collapse.frame.maxX, window.maxX)
        capture("expanded-reactions-offline-fixture")
        collapse.tap()
        let select = app.buttons["Выбрать"]
        XCTAssertTrue(select.exists)
        selectMessage(app)
        XCTAssertTrue(app.buttons["alo.message.select.990200"].waitForExistence(timeout: 3))
    }

    func testComposerKeepsWidthAndDraftAcrossAttachments() {
        let app = launchChat()
        let composer = field(app, "alo.chat.composer")
        let attach = app.buttons["alo.chat.attach"]
        XCTAssertGreaterThanOrEqual(attach.frame.width, 44)
        XCTAssertGreaterThanOrEqual(attach.frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["alo.chat.back"].frame.height, 44)
        composer.tap()
        // The field stretches slightly while the finger is down; measure it at rest.
        Thread.sleep(forTimeInterval: 0.5)
        let initialWidth = composer.frame.width
        composer.typeText("Hello, Alo")
        XCTAssertEqual(composer.value as? String, "Hello, Alo")
        XCTAssertEqual(composer.frame.width, initialWidth, accuracy: 1)
        composer.typeText("\nSecond line")
        XCTAssertTrue((composer.value as? String ?? "").contains("Second line"))
        capture("chat-keyboard-offline-fixture")

        attach.tap()
        let close = app.buttons["alo.attachments.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        let photoNotice = app.buttons.matching(NSPredicate(format: "label IN %@", ["OK", "ОК"])).firstMatch
        if photoNotice.waitForExistence(timeout: 5) { photoNotice.tap() }
        let photosReady = photo.waitForExistence(timeout: 15)
        if !photosReady { print(app.debugDescription) }
        XCTAssertTrue(photosReady)
        capture("attachments-gallery-offline-fixture")
        app.buttons["alo.attachments.file"].tap()
        XCTAssertTrue(app.buttons["Выбрать из файлов"].waitForExistence(timeout: 3))
        capture("attachments-files-offline-fixture")
        close.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertTrue((composer.value as? String ?? "").contains("Hello, Alo"))
        XCTAssertTrue((composer.value as? String ?? "").contains("Second line"))
    }

    func testGallerySelectionReturnsToDraft() {
        let app = launchChat()
        // The chat back control already sits below this window's actual safe area.
        // iOS 26 does not expose its system status bar in the app's AX hierarchy.
        let safeControlTop = app.buttons["alo.chat.back"].frame.minY
        app.buttons["alo.chat.attach"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        let photoNotice = app.buttons.matching(NSPredicate(format: "label IN %@", ["OK", "ОК"])).firstMatch
        if photoNotice.waitForExistence(timeout: 5) { photoNotice.tap() }
        let photosReady = photo.waitForExistence(timeout: 15)
        if !photosReady { print(app.debugDescription) }
        XCTAssertTrue(photosReady)
        let close = app.buttons["alo.attachments.close"]
        capture("gallery-panel-safe-area-offline-fixture")
        XCTAssertGreaterThanOrEqual(close.frame.minY, safeControlTop)
        let viewport = app.otherElements["alo.attachments.photos"]
        XCTAssertTrue(viewport.exists)
        XCTAssertGreaterThan(viewport.frame.minY, close.frame.maxY)
        XCTAssertLessThan(viewport.frame.minY - close.frame.maxY, 32)
        let collapsedHeaderTop = close.frame.minY
        let title = app.staticTexts["Галерея"].firstMatch
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.windows.firstMatch.frame.midX, dy: safeControlTop + 5)))
        capture("gallery-expanded-safe-area-offline-fixture")
        XCTAssertGreaterThanOrEqual(close.frame.minY, safeControlTop)
        if collapsedHeaderTop > safeControlTop + 100 {
            XCTAssertLessThan(close.frame.minY, collapsedHeaderTop - 100)
        }
        XCTAssertGreaterThan(viewport.frame.minY, close.frame.maxY)
        XCTAssertLessThan(viewport.frame.minY - close.frame.maxY, 32)
        // Photos exposes remote image elements without a hittable accessibility point.
        // Use their visible frame, then verify that selection actually changed.
        // Embedded Photos exposes AX frames in its own remote coordinate space.
        // Tap the first loaded cell through the host's screen-space viewport.
        viewport.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: viewport.frame.width / 6, dy: viewport.frame.width / 6 + 10)).tap()
        let done = app.buttons["Добавить выбранные вложения"]
        XCTAssertTrue(done.isEnabled)
        capture("gallery-selected-offline-fixture")
        done.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 15), .completed)
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["alo.attachments.close"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "alo.local.image.loaded").firstMatch.waitForExistence(timeout: 5),
                      "A file-backed photo draft must keep its visible preview")
        capture("chat-photo-draft-offline-fixture")
    }

    func testAttachmentToPollAndValidation() {
        let app = launchChat()
        app.buttons["alo.chat.attach"].tap()
        let poll = app.buttons["alo.attachments.poll"]
        XCTAssertTrue(poll.waitForExistence(timeout: 5))
        poll.tap()
        let create = app.buttons["alo.poll.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled)
        capture("poll-empty-offline-fixture")
        let question = field(app, "alo.poll.question")
        question.tap()
        question.typeText("Where next?")
        let first = app.textFields["alo.poll.option.0"]
        first.tap()
        first.typeText("Park")
        let second = app.textFields["alo.poll.option.1"]
        second.tap()
        second.typeText("Park")
        XCTAssertFalse(create.isEnabled)
        XCTAssertTrue(app.staticTexts["Варианты ответа должны отличаться."].exists)
        second.typeText(XCUIKeyboardKey.delete.rawValue + "is")
        XCTAssertTrue(create.isEnabled)
        capture("poll-editing-offline-fixture")
        app.buttons["Отмена"].tap()
        let discard = app.buttons["Удалить черновик"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        discard.tap()
        XCTAssertTrue(field(app, "alo.chat.composer").waitForExistence(timeout: 5))
    }
}
