import XCTest

final class AloSocialConsistencyUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "social-overview",
            "-ALO_UI_MESSENGER_ACCESSIBILITY", "0", "-ALO_UI_REDUCE_MOTION", "0",
            "-ALO_UI_REDUCE_TRANSPARENCY", "0", "-ALO_UI_INCREASE_CONTRAST", "0", "-ALO_UI_LEGACY_GLASS", "0",
            "-ALO_UI_SEARCH_INCOMING", "0"] + arguments
        app.launch()
        XCTAssertTrue((arguments.contains("chat-list") ? app.buttons["Чаты"].firstMatch : app.buttons["alo.feed.tab.popular"]).waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    private func rail(_ app: XCUIApplication, identifiers: [String]) -> CGRect {
        identifiers.reduce(CGRect.null) { $0.union(app.buttons[$1].frame) }
    }

    private func renderedFrame(_ element: XCUIElement) -> CGRect {
        let values = (element.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(values.count, 4, "A rendered geometry probe must be available in the DEBUG fixture")
        guard values.count == 4 else { return .zero }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    func testSharedGeometrySettingsAndAllMenus() {
        let app = launch()
        let feedRail = rail(app, identifiers: ["alo.feed.tab.popular", "alo.feed.tab.subscriptions"])
        XCTAssertEqual(feedRail.height, 44, accuracy: 0.01)
        XCTAssertEqual(feedRail.width + 8, app.windows.firstMatch.frame.width - 32, accuracy: 1)
        let gear = app.buttons["alo.feed.settings"].frame
        XCTAssertEqual(gear.size, CGSize(width: 44, height: 44))
        capture("01-feed")
        app.buttons["alo.feed.settings"].tap()
        XCTAssertTrue(app.buttons["Закрыть настройки"].waitForExistence(timeout: 4))
        capture("06-settings")
        app.buttons["Закрыть настройки"].tap()

        app.buttons["Поиск"].firstMatch.tap()
        let field = app.otherElements["alo.search.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        let fieldSurface = renderedFrame(field)
        XCTAssertEqual(fieldSurface.height, 40, accuracy: 1)
        XCTAssertEqual(fieldSurface.width, feedRail.width + 8, accuracy: 1)
        XCTAssertEqual(fieldSurface.minX, 16, accuracy: 1)
        let title = app.staticTexts["alo.search.title"].frame
        XCTAssertEqual(app.buttons["alo.search.settings"].frame.size, gear.size)
        capture("02-search")
        app.buttons["alo.search.settings"].tap()
        XCTAssertTrue(app.buttons["Закрыть настройки"].waitForExistence(timeout: 4))
        app.buttons["Закрыть настройки"].tap()
        let input = app.textFields["alo.search.input"]
        input.tap(); input.typeText("Александр")
        XCTAssertTrue(app.buttons["Очистить поиск"].waitForExistence(timeout: 3))
        app.buttons["Очистить поиск"].tap()
        let cleared = expectation(for: NSPredicate(format: "value == %@ OR value == %@", "Поиск", ""), evaluatedWith: input)
        wait(for: [cleared], timeout: 4)

        app.buttons["Уведы"].firstMatch.tap()
        XCTAssertTrue(app.buttons["alo.alerts.filter.all"].waitForExistence(timeout: 4))
        let alertsRail = rail(app, identifiers: ["alo.alerts.filter.all", "alo.alerts.filter.replies", "alo.alerts.filter.reactions"])
        XCTAssertEqual(alertsRail.height, feedRail.height, accuracy: 1)
        XCTAssertEqual(alertsRail.width, feedRail.width, accuracy: 1)
        XCTAssertEqual(app.staticTexts["alo.alerts.title"].frame.height, title.height, accuracy: 1)
        XCTAssertEqual(app.buttons["alo.alerts.settings"].frame.size, gear.size)
        for text in ["Принять", "Отклонить"] {
            XCTAssertGreaterThanOrEqual(app.buttons[text].frame.height + 0.01, 44)
            XCTAssertLessThanOrEqual(app.buttons[text].frame.height, 44.01)
        }
        capture("03-notifications")
        app.buttons["alo.alerts.filter.reactions"].tap()
        XCTAssertTrue(app.buttons["alo.alerts.filter.reactions"].isSelected)
        capture("07-notification-reactions")
        app.buttons["alo.alerts.filter.all"].tap()

        app.buttons["Профиль"].firstMatch.tap()
        XCTAssertTrue(app.buttons["alo.profile.tab.posts"].waitForExistence(timeout: 4))
        let profileRail = rail(app, identifiers: ["alo.profile.tab.posts", "alo.profile.tab.likes"])
        XCTAssertEqual(profileRail.height, feedRail.height, accuracy: 1)
        XCTAssertEqual(profileRail.width, feedRail.width, accuracy: 1)
        XCTAssertEqual(app.buttons["alo.profile.settings"].frame.size, gear.size)
        capture("04-profile")
        app.buttons["alo.profile.settings"].tap()
        XCTAssertTrue(app.buttons["Закрыть настройки"].waitForExistence(timeout: 4))
        app.buttons["Закрыть настройки"].tap()
        let lastLike = app.buttons["alo.post.like.990411"]
        let profile = app.scrollViews["alo.profile.scroll"]
        for _ in 0..<16 {
            if lastLike.isHittable && lastLike.frame.maxY <= app.buttons["Профиль"].firstMatch.frame.minY { break }
            profile.swipeUp()
        }
        XCTAssertTrue(lastLike.isHittable)
        XCTAssertLessThanOrEqual(lastLike.frame.maxY, app.buttons["Профиль"].firstMatch.frame.minY)
        capture("08-profile-bottom")
        app.buttons["Чаты"].firstMatch.tap()
        capture("05-chats")
    }

    func testLargeTextReducedMotionAndLegacyMaterials() {
        let app = launch(["-ALO_UI_MESSENGER_ACCESSIBILITY", "1", "-ALO_UI_REDUCE_MOTION", "1",
            "-ALO_UI_REDUCE_TRANSPARENCY", "1", "-ALO_UI_INCREASE_CONTRAST", "1", "-ALO_UI_LEGACY_GLASS", "1"])
        capture("accessibility-feed")
        app.buttons["Поиск"].firstMatch.tap()
        XCTAssertTrue(app.textFields["alo.search.input"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["alo.search.settings"].isHittable)
        capture("accessibility-search")
        app.buttons["Уведы"].firstMatch.tap()
        let reactions = app.buttons["alo.alerts.filter.reactions"]
        XCTAssertTrue(reactions.waitForExistence(timeout: 4))
        XCTAssertGreaterThanOrEqual(reactions.frame.height, 44)
        reactions.tap()
        XCTAssertTrue(reactions.isSelected)
        app.buttons["alo.alerts.filter.all"].tap()
        let request = app.buttons["Принять"]
        for _ in 0..<4 where !request.isHittable { app.scrollViews["alo.alerts.scroll"].swipeUp() }
        XCTAssertTrue(request.isHittable)
        capture("accessibility-notifications")
        app.buttons["Профиль"].firstMatch.tap()
        XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["alo.profile.tab.posts"].exists)
        capture("accessibility-profile")
    }

    func testIncomingSearchRequestOffersResponse() {
        let app = launch(["-ALO_UI_SEARCH_INCOMING", "1"])
        app.buttons["Поиск"].firstMatch.tap()
        let reply = app.buttons["Ответить"]
        XCTAssertTrue(reply.waitForExistence(timeout: 4))
        XCTAssertTrue(reply.isEnabled)
        reply.tap()
        XCTAssertTrue(app.buttons["Принять"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Отклонить"].exists)
        capture("incoming-request-options")
        // Inspect choices only: the fixture must never create real social mutations.
        if app.buttons["Отмена"].exists { app.buttons["Отмена"].tap() }
        else { app.staticTexts["alo.search.title"].tap() } // iOS 26 popovers dismiss outside.
        XCTAssertTrue(reply.isHittable)
    }

    /// Visual review only: no geometry assertions, so it can run before and after chrome changes.
    func testCaptureAllScreensForReview() {
        let app = launch()
        capture("a-feed")
        app.scrollViews["alo.feed.scroll"].swipeUp(velocity: .slow)
        capture("a-feed-scrolled")
        app.buttons["Поиск"].firstMatch.tap()
        _ = app.otherElements["alo.search.field"].firstMatch.waitForExistence(timeout: 4)
        capture("b-search")
        app.buttons["Чаты"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("c-chats")
        app.buttons["Уведы"].firstMatch.tap()
        _ = app.buttons["alo.alerts.filter.all"].waitForExistence(timeout: 4)
        capture("d-notifications")
        let alerts = app.scrollViews["alo.alerts.scroll"]
        if alerts.exists { alerts.swipeUp(velocity: .slow) }
        capture("d-notifications-scrolled")
        app.buttons["Профиль"].firstMatch.tap()
        _ = app.buttons["alo.profile.tab.posts"].waitForExistence(timeout: 4)
        capture("e-profile")
    }

    func testCaptureChatListAndSearch() {
        let app = launch(["-ALO_UI_MESSENGER_CONTENT", "chat-list"])
        app.buttons["Чаты"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("f-chatlist-closed")
        let list = app.scrollViews.firstMatch
        list.swipeDown(velocity: .slow)
        Thread.sleep(forTimeInterval: 0.6)
        capture("f-chatlist-pulled")
        let input = app.textFields["alo.chats.search.input"]
        input.tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("f-chatsearch-empty")
        input.typeText("Ма")
        Thread.sleep(forTimeInterval: 0.8)
        capture("f-chatsearch-results")
        app.buttons["alo.chats.search.cancel"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        capture("f-chatlist-after-cancel")
    }

    /// Same screens through the iOS 18 glass fallback.
    func testCaptureLegacyGlass() {
        var app = launch(["-ALO_UI_LEGACY_GLASS", "1"])
        app.scrollViews["alo.feed.scroll"].swipeUp(velocity: .slow)
        capture("g-feed-scrolled")
        app.buttons["Уведы"].firstMatch.tap()
        _ = app.buttons["alo.alerts.filter.all"].waitForExistence(timeout: 4)
        app.scrollViews["alo.alerts.scroll"].swipeUp(velocity: .slow)
        capture("g-notifications-scrolled")
        app.terminate()
        app = launch(["-ALO_UI_MESSENGER_CONTENT", "chat-list", "-ALO_UI_LEGACY_GLASS", "1"])
        app.buttons["Чаты"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.scrollViews.firstMatch.swipeDown(velocity: .slow)
        Thread.sleep(forTimeInterval: 0.6)
        capture("g-chatlist-pulled")
    }

    func testCaptureCallScreens() {
        var app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_CALL_PREVIEW", "1"]
        app.launch()
        let bar = app.buttons["alo.compact-call-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        capture("h-call-compact")
        bar.tap()
        XCTAssertTrue(app.buttons["alo.call.minimize"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
        capture("h-call-expanded")
        app.buttons["alo.call-safety-verification"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("h-call-safety")
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_CALL_PREVIEW", "1", "-ALO_UI_CALL_VIDEO_PREVIEW", "1", "-ALO_UI_CALL_REMOTE_VIDEO_PREVIEW", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["alo.compact-call-bar"].waitForExistence(timeout: 10))
        app.buttons["alo.compact-call-bar"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("h-call-video")
    }

    func testCaptureChatScreens() {
        for (name, content, extra) in [("i-chat", "", [String]()), ("i-chat-forward", "forward", [String]()),
                                       ("i-chat-legacy", "", ["-ALO_UI_LEGACY_GLASS", "1"])] {
            let app = XCUIApplication()
            app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content] + extra
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["alo.chat.composer"].waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 1.0)
            capture(name)
            app.terminate()
        }
    }

    /// Screens most likely to break on a 375 pt phone: typing, comments, new post.
    func testCaptureSmallScreenRisks() {
        var app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", ""]
        app.launch()
        let composer = app.descendants(matching: .any)["alo.chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("Проверяем высоту поля ввода, когда текст длинный и переходит на несколько строк подряд")
        Thread.sleep(forTimeInterval: 0.8)
        capture("j-chat-typing")
        app.terminate()

        app = launch()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'alo.post.comments.'")).firstMatch.tap()
        let input = app.descendants(matching: .any).matching(identifier: "alo.comments.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
        capture("j-comments")
        if input.isHittable { input.tap(); Thread.sleep(forTimeInterval: 0.8); capture("j-comments-typing") }
        app.terminate()

        app = launch()
        app.buttons["alo.feed.create-post"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("j-post-composer")
    }

    func testCaptureChatFeatures() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "forward"]
        app.launch()
        let composer = app.descendants(matching: .any)["alo.chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1.0)
        let body = app.staticTexts["Привет! Посмотрел фотографии с поездки?"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.press(forDuration: 0.6)
        Thread.sleep(forTimeInterval: 0.8)
        capture("m-menu")
        if app.buttons["Ответить"].exists {
            app.buttons["Ответить"].tap()
            Thread.sleep(forTimeInterval: 0.8)
            capture("m-reply")
            if app.buttons["alo.composer.reply.cancel"].exists { app.buttons["alo.composer.reply.cancel"].tap() }
        } else { app.tap() }
        Thread.sleep(forTimeInterval: 0.5)
        body.press(forDuration: 0.6)
        Thread.sleep(forTimeInterval: 0.8)
        if app.buttons["Выбрать"].exists {
            app.buttons["Выбрать"].tap()
            Thread.sleep(forTimeInterval: 0.8)
            capture("m-select")
        }
        app.terminate()
        let app2 = XCUIApplication()
        app2.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", ""]
        app2.launch()
        XCTAssertTrue(app2.buttons["alo.chat.attach"].waitForExistence(timeout: 15))
        app2.buttons["alo.chat.attach"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("m-attach")
    }

    func testCaptureAppearance() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "appearance"]
        app.launch()
        XCTAssertTrue(app.buttons["alo.appearance.apply"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1.0)
        capture("n-appearance-theme")
        app.buttons["alo.appearance.section.1"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("n-appearance-wallpaper")
        app.buttons["alo.appearance.section.2"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("n-appearance-messages")
    }

    func testCaptureCircleRecording() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "",
                                "-ALO_UI_RECORDING_FIXTURE", "1", "-ALO_UI_MESSENGER_SURFACE", "1"]
        app.launch()
        let record = app.buttons["alo.chat.record-send"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        capture("q-composer-voice")
        record.tap()
        XCTAssertEqual(record.label, "Кружок")
        capture("q-composer-circle")
        let origin = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.65, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -115)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["Завершить и просмотреть кружок"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.8)
        capture("q-circle-recording-locked")
    }

    func testCaptureLoadingSkeleton() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_LOADING_SKELETON", "1"]
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)
        capture("s-skeleton-1")
        Thread.sleep(forTimeInterval: 0.6)
        capture("s-skeleton-2")
    }

    func testCaptureGroupInfo() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "group-info"]
        app.launch()
        XCTAssertTrue(app.buttons["alo.chat.info"].waitForExistence(timeout: 15))
        app.buttons["alo.chat.info"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("t-group-info-top")
        let scroll = app.scrollViews["alo.peer.scroll"]
        if scroll.exists { scroll.swipeUp(velocity: .fast); scroll.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 0.6)
        capture("t-group-info-bottom")
    }

    func testCaptureMediaViewers() {
        var app = launch()
        let media = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'alo.post.media.'")).firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 8))
        media.tap()
        XCTAssertTrue(app.buttons["alo.post.viewer.close"].waitForExistence(timeout: 6))
        Thread.sleep(forTimeInterval: 1.0)
        capture("v-photo-viewer")
        Thread.sleep(forTimeInterval: 3.6)
        capture("v-photo-viewer-autohidden")
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.doubleTap()
        Thread.sleep(forTimeInterval: 0.8)
        capture("v-photo-zoomed")
        center.doubleTap()
        Thread.sleep(forTimeInterval: 0.6)
        app.pinch(withScale: 3, velocity: 2)
        Thread.sleep(forTimeInterval: 0.6)
        capture("v-photo-pinched")
        app.terminate()

        app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-video"]
        app.launch()
        let video = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'alo.post.media.'")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        video.tap()
        Thread.sleep(forTimeInterval: 1.5)
        capture("v-video-after-tap")
        Thread.sleep(forTimeInterval: 1.5)
        capture("v-video-player")
        app.tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("v-video-player-toggled")
    }

    /// "26" is the system glass; "18" is the fallback used on iOS 18 (forced here, no iOS 18 runtime installed).
    func testCaptureOSComparison() {
        for (tag, extra) in [("26", ["-ALO_UI_LEGACY_GLASS", "0"]), ("18", ["-ALO_UI_LEGACY_GLASS", "1"])] {
            var app = launch(extra)
            app.scrollViews["alo.feed.scroll"].swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.5)
            capture("w-feed-\(tag)")
            app.terminate()
            app = launch(["-ALO_UI_MESSENGER_CONTENT", "chat-list"] + extra)
            app.buttons["Чаты"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 1.0)
            app.scrollViews.firstMatch.swipeDown(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.6)
            capture("w-chatlist-\(tag)")
            app.terminate()
            let chat = XCUIApplication()
            chat.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "forward"] + extra
            chat.launch()
            XCTAssertTrue(chat.descendants(matching: .any)["alo.chat.composer"].waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 1.0)
            capture("w-chat-\(tag)")
            chat.terminate()
        }
    }

    func testCapturePinFlow() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", ""]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["alo.chat.composer"].waitForExistence(timeout: 15))
        let body = app.staticTexts["Привет! Посмотрел фотографии с поездки?"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.press(forDuration: 0.6)
        Thread.sleep(forTimeInterval: 0.8)
        capture("x-pin-menu")
        if app.buttons["Закрепить"].exists {
            app.buttons["Закрепить"].tap()
            Thread.sleep(forTimeInterval: 1.2)
            capture("x-pin-after")
        }
    }

    func testCaptureChatListActions() {
        let app = launch(["-ALO_UI_MESSENGER_CONTENT", "chat-list"])
        app.buttons["Чаты"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("y-list")
        let row = app.staticTexts["Илья"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 2.2, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -170, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.8)
        capture("y-swipe-left")
        app.staticTexts["Даша"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.8)
        capture("y-after-close")
        let row2 = app.staticTexts["Анна"].firstMatch
        let s2 = row2.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        s2.press(forDuration: 0.05, thenDragTo: s2.withOffset(CGVector(dx: 120, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.8)
        capture("y-swipe-right")
        app.staticTexts["Даша"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.8)
        app.staticTexts["Мария"].firstMatch.press(forDuration: 0.6)
        Thread.sleep(forTimeInterval: 1.0)
        capture("y-menu")
        if app.buttons["Выбрать"].exists {
            app.buttons["Выбрать"].tap()
            Thread.sleep(forTimeInterval: 0.8)
            app.staticTexts["Даша"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.6)
            capture("y-select")
        }
        app.buttons["alo.chats.select.done"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        if app.buttons["alo.chats.archive.entry"].exists {
            app.buttons["alo.chats.archive.entry"].tap()
            Thread.sleep(forTimeInterval: 0.8)
            capture("y-archive")
        }
    }

    func testCaptureCallsAndDeletion() {
        let app = launch(["-ALO_UI_MESSENGER_CONTENT", "chat-list"])
        app.buttons["Чаты"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("z-list-counts")
        let row = app.staticTexts["Работа"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 2.2, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -200, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.8)
        capture("z-swipe-delete")
        if app.buttons["Удалить"].firstMatch.exists {
            app.buttons["Удалить"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.8)
            capture("z-delete-confirm")
            if app.buttons["Удалить у меня"].exists { app.buttons["Удалить у меня"].tap() }
            Thread.sleep(forTimeInterval: 0.8)
            XCTAssertFalse(app.staticTexts["Работа"].exists, "deleted chat leaves the list")
            capture("z-after-delete")
        }
        // A group can be pinned like any chat.
        let group = app.staticTexts["Семья"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 4))
        let g = group.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        g.press(forDuration: 0.05, thenDragTo: g.withOffset(CGVector(dx: 300, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0.05)
        Thread.sleep(forTimeInterval: 1.0)
        capture("z-group-pinned")
        app.buttons["alo.chats.calls"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("z-calls")
        app.buttons["alo.calls.filter.missed"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("z-calls-missed")
    }

    func testViewerSwipeDownAndPiP() {
        var app = launch()
        let media = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'alo.post.media.'")).firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 8))
        media.tap()
        let close = app.buttons["alo.post.viewer.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 6))
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 50)), withVelocity: .slow, thenHoldForDuration: 0.05)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(app.descendants(matching: .any)["alo.post.viewer.close"].exists, "a short drag springs back")
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 320)), withVelocity: .fast, thenHoldForDuration: 0.0)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(app.buttons["alo.post.viewer.close"].exists, "a long drag closes the photo")
        capture("p-after-swipe-close")
        app.terminate()

        app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-video"]
        app.launch()
        let video = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'alo.post.media.'")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        video.tap()
        Thread.sleep(forTimeInterval: 1.5)
        capture("p-video-controls")
        print("PIPDBG", app.buttons["alo.video.pip"].exists, app.buttons["alo.video.play"].exists)
        if app.buttons["alo.video.pip"].exists {
            app.buttons["alo.video.pip"].tap()
            Thread.sleep(forTimeInterval: 2.0)
            capture("p-pip")
        }
    }


    func testStoryViewerPlaysTapsAndCloses() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-timeline"]
        app.launch()
        let first = app.buttons["История: Маша"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        first.tap()
        let progress = app.descendants(matching: .any)["alo.story.viewer.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 1.5)
        capture("v-1-story")
        XCTAssertTrue(app.staticTexts["Маша"].exists)
        // A tap on the right moves on: each fixture person has one story, so this is the next person.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Александр"].waitForExistence(timeout: 3))
        capture("v-2-next-person")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(progress.waitForNonExistence(timeout: 4), "swipe down closes the viewer")
    }

    func testCaptureStoryTools() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-surface"]
        app.launch()
        let story = app.buttons["alo.feed.create-story"]
        XCTAssertTrue(story.waitForExistence(timeout: 15))
        story.tap()
        XCTAssertTrue(app.buttons["alo.story.publish"].waitForExistence(timeout: 4))
        // A new story opens typing, with the text tools above the keyboard.
        XCTAssertTrue(app.buttons["Шрифт"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)
        app.typeText("Выходные у моря")
        app.buttons["Тёмная подложка"].tap()
        app.buttons["Цвет 1"].tap()
        app.buttons["Фон"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("s-1-text-style")

        // "Готово" places the text as an item and selects it: a square frame with corner handles.
        app.buttons["alo.story.tool-done"].tap()
        let textItem = app.descendants(matching: .any).matching(identifier: "alo.story.text-item").firstMatch
        XCTAssertTrue(textItem.waitForExistence(timeout: 3))
        XCTAssertTrue(textItem.isSelected)
        Thread.sleep(forTimeInterval: 0.5)
        capture("s-2-text-item")
        app.buttons["alo.story.tool-done"].tap()

        // A sticker comes in selected as well.
        app.buttons["alo.story.stickers"].tap()
        XCTAssertTrue(app.buttons["🔥"].waitForExistence(timeout: 3))
        app.buttons["🔥"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        capture("s-3-sticker")
        app.buttons["alo.story.tool-done"].tap()

        // A stroke with the pen.
        app.buttons["alo.story.draw"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.62)),
                    withVelocity: .slow, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 0.6)
        app.buttons["alo.story.tool-done"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("s-4-ready")
        // Publishing flattens the page first; offline, the upload then fails with a visible error.
        app.buttons["alo.story.publish"].tap()
        XCTAssertTrue(app.buttons["alo.story.publish-confirm"].waitForExistence(timeout: 4))
        app.buttons["alo.story.publish-confirm"].tap()
        let error = app.descendants(matching: .any).matching(identifier: "alo.story.publish-error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10), "the page was rendered and the upload attempted")
        capture("s-5-publish-offline")
    }

    /// Text and emoji are stretched like in Instagram: by a corner handle or a pinch; a second tap
    /// on selected text opens it for editing.
    func testStoryItemsStretchAndEdit() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-surface"]
        app.launch()
        let story = app.buttons["alo.feed.create-story"]
        XCTAssertTrue(story.waitForExistence(timeout: 15))
        story.tap()
        XCTAssertTrue(app.buttons["Шрифт"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.6)
        app.typeText("Привет")
        app.buttons["alo.story.tool-done"].tap()

        let text = app.descendants(matching: .any).matching(identifier: "alo.story.text-item").firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        let before = text.frame
        // The element's frame includes the handles, whose knobs sit 20 pt inside its corners.
        // Pull the bottom-right knob away from the centre.
        let corner = text.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: before.width - 20, dy: before.height - 20))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 60, dy: 30)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.6)
        let stretched = text.frame
        XCTAssertGreaterThan(stretched.width, before.width * 1.3, "the corner handle stretches the text")
        XCTAssertEqual(stretched.midX, before.midX, accuracy: 3, "it grows around its centre")
        capture("i-1-text-stretched")

        // Pinching in shrinks it again.
        text.pinch(withScale: 0.6, velocity: -1)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertLessThan(text.frame.width, stretched.width * 0.9, "a pinch shrinks the text")

        // An emoji: added selected, then stretched by its handle.
        app.buttons["alo.story.tool-done"].tap()
        app.buttons["alo.story.stickers"].tap()
        XCTAssertTrue(app.buttons["✨"].waitForExistence(timeout: 3))
        app.buttons["✨"].tap()
        let sticker = app.descendants(matching: .any).matching(identifier: "alo.story.sticker").firstMatch
        XCTAssertTrue(sticker.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)
        let small = sticker.frame
        let stickerCorner = sticker.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: small.width - 20, dy: small.height - 20))
        stickerCorner.press(forDuration: 0.1, thenDragTo: stickerCorner.withOffset(CGVector(dx: 50, dy: 50)),
                            withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThan(sticker.frame.width, small.width * 1.4, "the corner handle stretches the emoji")
        capture("i-2-emoji-stretched")
        // Move it out of the text's way.
        let middle = sticker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 160)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.5)

        // Select the text, tap it again: it opens for editing with its words.
        app.buttons["alo.story.tool-done"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        text.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(text.isSelected, "a tap selects the text")
        capture("i-3-text-selected")
        text.tap()
        let field = app.descendants(matching: .any).matching(identifier: "alo.story.text").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "Привет")
        capture("i-4-text-editing")
    }

    /// Text and emoji turn with one finger on the round handle above the frame or with two
    /// fingers, snapping to right angles; the text plate is picked from a row of samples.
    func testStoryItemsRotateAndPlates() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-surface"]
        app.launch()
        let story = app.buttons["alo.feed.create-story"]
        XCTAssertTrue(story.waitForExistence(timeout: 15))
        story.tap()
        XCTAssertTrue(app.buttons["Без подложки"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.6)
        app.typeText("Поворот")
        for plate in ["Без подложки", "Тёмная подложка", "Цветная подложка", "Светлая подложка", "Подложка-рамка"] {
            let chip = app.buttons[plate]
            XCTAssertTrue(chip.exists, plate)
            chip.tap()
            XCTAssertTrue(chip.isSelected, "\(plate) is the chosen plate")
            if plate == "Светлая подложка" {
                Thread.sleep(forTimeInterval: 0.4)
                capture("r-1-plates")
            }
        }
        app.buttons["alo.story.tool-done"].tap()

        // One finger on the round handle, a quarter turn round the centre: it snaps to 90°.
        let text = app.descendants(matching: .any).matching(identifier: "alo.story.text-item").firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        let frame = text.frame
        // The element spans the knobs: the rotation handle's centre is 20 pt below its top,
        // the frame's bottom edge 20 pt above its bottom, and the frame's top 38 pt below the handle.
        let knobY = frame.minY + 20
        let centerY = ((knobY + 38) + (frame.maxY - 20)) / 2
        let radius = centerY - knobY
        let origin = text.coordinate(withNormalizedOffset: .zero)
        let knob = origin.withOffset(CGVector(dx: frame.width / 2, dy: 20))
        let quarter = origin.withOffset(CGVector(dx: frame.width / 2 + radius * 0.98, dy: centerY - frame.minY + radius * 0.05))
        knob.press(forDuration: 0.1, thenDragTo: quarter, withVelocity: .slow, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 0.6)
        let degrees = Int((text.value as? String ?? "").filter(\.isNumber)) ?? 0
        XCTAssertTrue((75...115).contains(degrees), "about a quarter turn: \(degrees)°")
        XCTAssertGreaterThan(text.frame.height, text.frame.width, "the wide text now stands upright")
        capture("r-2-text-turned")

        // The emoji turns the other way with its own handle. (Two-finger twists drive the same
        // turn; the Simulator's synthesized two-finger rotation is too unreliable to assert here.)
        app.buttons["alo.story.tool-done"].tap()
        app.buttons["alo.story.stickers"].tap()
        XCTAssertTrue(app.buttons["🔥"].waitForExistence(timeout: 3))
        app.buttons["🔥"].tap()
        let sticker = app.descendants(matching: .any).matching(identifier: "alo.story.sticker").firstMatch
        XCTAssertTrue(sticker.waitForExistence(timeout: 3))
        // Move it clear of the text first.
        let middle = sticker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 150)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.5)
        let box = sticker.frame
        let stickerKnobY = box.minY + 20
        let stickerCenterY = ((stickerKnobY + 38) + (box.maxY - 20)) / 2
        let reach = stickerCenterY - stickerKnobY
        let stickerOrigin = sticker.coordinate(withNormalizedOffset: .zero)
        let stickerKnob = stickerOrigin.withOffset(CGVector(dx: box.width / 2, dy: 20))
        let left = stickerOrigin.withOffset(CGVector(dx: box.width / 2 - reach, dy: stickerCenterY - box.minY))
        stickerKnob.press(forDuration: 0.1, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 0.6)
        let turned = Int((sticker.value as? String ?? "").filter { $0.isNumber || $0 == "-" }) ?? 0
        XCTAssertTrue((-115 ... -65).contains(turned), "a quarter turn back: \(turned)°")
        capture("r-3-emoji-turned")
    }

    /// The brush has its own thickness slider on the left, as in Instagram.
    func testStoryBrushSize() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-surface"]
        app.launch()
        let story = app.buttons["alo.feed.create-story"]
        XCTAssertTrue(story.waitForExistence(timeout: 15))
        story.tap()
        let done = app.buttons["alo.story.tool-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 4))
        done.tap()
        app.buttons["alo.story.draw"].tap()
        let slider = app.descendants(matching: .any).matching(identifier: "alo.story.brush-size").firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.8)

        func setBrush(to dy: CGFloat) {
            let knob = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            knob.press(forDuration: 0.05, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        func stroke(atY y: CGFloat) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: y))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: y)),
                        withVelocity: .slow, thenHoldForDuration: 0)
        }
        setBrush(to: 0)
        XCTAssertEqual(slider.value as? String, "100 %", "dragged to the top: the thickest brush")
        stroke(atY: 0.35)
        setBrush(to: 1)
        XCTAssertEqual(slider.value as? String, "0 %", "dragged to the bottom: the thinnest brush")
        stroke(atY: 0.5)
        setBrush(to: 0.55)
        stroke(atY: 0.62)
        Thread.sleep(forTimeInterval: 0.5)
        capture("b-1-brush-sizes")
    }

    /// Telegram's story menus: who has seen your story (search, newest first) and a copyable link;
    /// a link to a story that has gone says so.
    func testStoryViewersAndLink() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-timeline"]
        app.launch()
        let own = app.buttons["История: Тест интерфейса"]
        XCTAssertTrue(own.waitForExistence(timeout: 15))
        own.tap()
        let views = app.buttons["alo.story.viewer.views"]
        XCTAssertTrue(views.waitForExistence(timeout: 5))
        views.tap()
        let rows = app.buttons.matching(identifier: "alo.story.viewers.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(app.staticTexts["4 просмотра"].exists, "the title counts the viewers")
        XCTAssertTrue(app.staticTexts["2 мин назад"].exists)
        Thread.sleep(forTimeInterval: 0.8)
        capture("sv-1-viewers")
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Да")
        XCTAssertEqual(rows.count, 1, "search narrows the list")
        capture("sv-2-viewers-search")
        app.terminate()

        // "⋯" → "Копировать ссылку": a confirmation shows.
        app.launch()
        XCTAssertTrue(own.waitForExistence(timeout: 15))
        own.tap()
        let more = app.buttons["alo.story.viewer.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let copy = app.buttons["Копировать ссылку"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        capture("sv-3-menu")
        copy.tap()
        let toast = app.descendants(matching: .any).matching(identifier: "alo.story.viewer.toast").firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        capture("sv-4-link-copied")
        app.terminate()

        let expiredApp = XCUIApplication()
        expiredApp.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-timeline",
                                       "-ALO_UI_STORY_EXPIRED", "1"]
        expiredApp.launch()
        XCTAssertTrue(expiredApp.staticTexts["История истекла"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 0.8)
        capture("sv-5-expired")
    }

    /// Telegram's story privacy, highlights and archive: publish to close friends chosen from your
    /// friends; your highlights on the profile; pick archived stories into a new highlight.
    func testStoryAudienceArchiveHighlights() {
        let app = launch()
        let story = app.buttons["alo.feed.create-story"]
        XCTAssertTrue(story.waitForExistence(timeout: 15))
        story.tap()
        XCTAssertTrue(app.buttons["alo.story.publish"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.6)
        app.typeText("Только для своих")
        // The keyboard covers the bottom bar: "Готово" first, as a person would.
        app.buttons["alo.story.tool-done"].tap()
        app.buttons["alo.story.tool-done"].tap()
        app.buttons["alo.story.publish"].tap()
        let closeFriends = app.descendants(matching: .any)["alo.story.audience.close_friends"]
        XCTAssertTrue(closeFriends.waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.5)
        capture("au-1-audience")
        closeFriends.tap()
        // No close friends yet: the friend picker opens.
        let rows = app.buttons.matching(identifier: "alo.people.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 4))
        XCTAssertEqual(rows.count, 4)
        rows.matching(NSPredicate(format: "label BEGINSWITH 'Маша'")).firstMatch.tap()
        rows.matching(NSPredicate(format: "label BEGINSWITH 'Даша'")).firstMatch.tap()
        capture("au-2-close-friends")
        app.buttons["alo.people.done"].tap()
        XCTAssertTrue(app.buttons["2 человека · Изменить"].waitForExistence(timeout: 4), "the sheet counts close friends")
        XCTAssertEqual(closeFriends.value as? String, "выбрано")
        capture("au-3-chosen")
        app.buttons["alo.story.publish-confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "alo.story.publish-error").firstMatch
            .waitForExistence(timeout: 10), "published offline: the editor reports the upload")
        app.buttons["Закрыть редактор истории"].tap()

        // Highlights live behind your avatar: its ring opens your stories.
        app.buttons["Профиль"].firstMatch.tap()
        let avatar = app.buttons["alo.profile.stories"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 6))
        avatar.tap()
        let summer = app.buttons["alo.highlight.Лето"]
        XCTAssertTrue(summer.waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["alo.highlights.new"].exists)
        Thread.sleep(forTimeInterval: 0.6)
        capture("au-4-highlights")
        summer.tap()
        XCTAssertTrue(app.staticTexts["Лето"].waitForExistence(timeout: 4), "the highlight's title shows in the viewer")
        app.buttons["alo.story.viewer.more"].tap()
        XCTAssertTrue(app.buttons["Убрать из актуального"].waitForExistence(timeout: 3))
        capture("au-5-highlight-menu")
        // iOS 26 shows the actions without a cancel row: a tap outside closes them.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        let close = app.buttons["alo.story.viewer.close"]
        if close.waitForExistence(timeout: 2) { close.tap() }
        XCTAssertTrue(app.buttons["alo.highlights.archive"].waitForExistence(timeout: 8), "back on your stories")

        // The archive: choose two stories for a new highlight.
        app.buttons["alo.highlights.archive"].tap()
        let cells = app.buttons.matching(identifier: "alo.archive.story")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 4))
        XCTAssertEqual(cells.count, 7)
        Thread.sleep(forTimeInterval: 0.6)
        capture("au-6-archive")
        app.buttons["alo.archive.select"].tap()
        cells.element(boundBy: 2).tap()
        cells.element(boundBy: 4).tap()
        capture("au-7-archive-selected")
        app.buttons["alo.archive.add"].tap()
        let title = app.textFields["alo.highlight.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        title.tap()
        title.typeText("Море")
        app.buttons["alo.highlight.create"].tap()
        XCTAssertTrue(app.buttons["alo.highlight.Море"].waitForExistence(timeout: 6), "the new highlight is among your stories")
        Thread.sleep(forTimeInterval: 0.6)
        capture("au-8-new-highlight")
    }

    /// The reader's tools on a post, comment threads with replies and "@", drafts and the creator panel.
    func testFeedCurationThreadsDraftsAndStats() {
        let app = launch()
        let any = app.descendants(matching: .any)

        // "Почему я это вижу" on a friend's post, then "Не интересно" and "Вернуть".
        let menu = app.buttons["alo.post.menu.990401"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let why = app.buttons["Почему я это вижу"]
        XCTAssertTrue(why.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Пожаловаться"].exists)
        capture("fc-1-post-menu")
        why.tap()
        XCTAssertTrue(any.matching(NSPredicate(format: "label BEGINSWITH 'Вы подписаны на @alex'")).firstMatch
            .waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.5)
        capture("fc-2-why-shown")
        app.buttons["alo.post.why.not-interested"].tap()
        let hidden = any["alo.post.hidden"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["alo.post.menu.990401"].exists, "the post leaves the feed")
        Thread.sleep(forTimeInterval: 0.4)
        capture("fc-3-hidden")
        app.buttons["alo.post.hidden.undo"].tap()
        XCTAssertTrue(app.buttons["alo.post.menu.990401"].waitForExistence(timeout: 4), "Вернуть brings it back")

        // A report on a recommended post.
        app.buttons["alo.post.menu.990402"].tap()
        XCTAssertTrue(app.buttons["Пожаловаться"].waitForExistence(timeout: 3))
        app.buttons["Пожаловаться"].tap()
        let spam = app.buttons["alo.report.reason.spam"]
        XCTAssertTrue(spam.waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.4)
        capture("fc-4-report-reasons")
        spam.tap()
        app.buttons["alo.report.send"].tap()
        XCTAssertTrue(app.staticTexts["Спасибо! Жалоба отправлена"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.6)
        capture("fc-5-report-sent")
        app.buttons["alo.report.done"].tap()
        XCTAssertTrue(hidden.waitForExistence(timeout: 4), "a reported post is hidden too")

        // Comments: a thread with replies, a reply with "@" suggestions.
        app.buttons["alo.post.comments.990401"].tap()
        let thread = app.buttons["alo.comments.thread.990700"]
        XCTAssertTrue(thread.waitForExistence(timeout: 6))
        XCTAssertEqual(thread.label, "Посмотреть ответы (2)")
        Thread.sleep(forTimeInterval: 0.4)
        capture("fc-6-thread-collapsed")
        thread.tap()
        XCTAssertTrue(any["alo.comments.body.990703"].waitForExistence(timeout: 3))
        capture("fc-7-thread-open")
        app.buttons["alo.comments.reply.990703"].tap()
        XCTAssertTrue(any["alo.comments.reply-bar"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["alo.comments.input"].value as? String, "@maria ")
        app.typeText("и @al")
        let alex = app.buttons["alo.mention.alex"]
        XCTAssertTrue(alex.waitForExistence(timeout: 4))
        capture("fc-8-mention-suggestions")
        alex.tap()
        XCTAssertEqual(app.textFields["alo.comments.input"].value as? String, "@maria и @alex ")
        app.typeText("смотрите!")
        app.buttons["alo.comments.send"].tap()
        XCTAssertFalse(any["alo.comments.reply-bar"].waitForExistence(timeout: 2), "sending ends the reply")
        XCTAssertEqual(thread.label, "Скрыть ответы")
        Thread.sleep(forTimeInterval: 0.6)
        capture("fc-9-reply-sent")
        app.navigationBars.buttons.firstMatch.tap()

        // A draft: close a started post, save it, find it again.
        let create = app.buttons["alo.feed.create-post"]
        XCTAssertTrue(create.waitForExistence(timeout: 6))
        create.tap()
        XCTAssertTrue(app.buttons["alo.post.publish"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.6)
        app.typeText("Список мест на выходные")
        app.buttons["Закрыть редактор поста"].tap()
        let save = app.buttons["Сохранить черновик"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        capture("fc-10-save-draft")
        save.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 4))
        create.tap()
        let drafts = app.buttons["alo.post.drafts-button"]
        XCTAssertTrue(drafts.waitForExistence(timeout: 4))
        XCTAssertEqual(drafts.label, "Черновики: 3")
        drafts.tap()
        let first = app.buttons["alo.post.draft.990901"]
        XCTAssertTrue(first.waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.6)
        capture("fc-11-drafts")
        first.tap()
        XCTAssertTrue(app.staticTexts["Черновик"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.8)
        capture("fc-12-draft-opened")
        app.buttons["Закрыть редактор поста"].tap()
        // An opened draft is kept as it was unless you save the changes.
        let keep = app.buttons["Не сохранять"]
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Удалить черновик"].exists)
        capture("fc-12b-close-draft")
        keep.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 4))

        // The creator panel lives in the settings, not on the profile.
        app.buttons["Профиль"].firstMatch.tap()
        XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["alo.profile.creator-stats"].exists)
        app.buttons["alo.profile.settings"].tap()
        let panel = app.buttons["alo.settings.creator-stats"]
        if !panel.waitForExistence(timeout: 6) { capture("fc-debug-settings"); print("SETTINGSDBG", app.debugDescription) }
        XCTAssertTrue(panel.exists)
        Thread.sleep(forTimeInterval: 0.4)
        capture("fc-13-settings-panel")
        panel.tap()
        XCTAssertTrue(any["alo.stats.overview"].waitForExistence(timeout: 6))
        Thread.sleep(forTimeInterval: 0.8)
        capture("fc-14-stats")
        any["alo.stats.screen"].swipeUp()
        Thread.sleep(forTimeInterval: 0.6)
        capture("fc-15-stats-more")
    }

    /// Quotes and code blocks in bubbles, and the composer's formatting menu.
    func testMessageQuoteAndCodeBlocks() {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "formatting"]
        app.launch()
        let quote = app.descendants(matching: .any)["alo.message.body.990200"]
        XCTAssertTrue(quote.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Цитата: Встречаемся'")).firstMatch.exists)
        Thread.sleep(forTimeInterval: 0.8)
        capture("fmt-1-quote-code")
        let composer = app.textFields["alo.chat.composer"].firstMatch.exists
            ? app.textFields["alo.chat.composer"].firstMatch : app.textViews["alo.chat.composer"].firstMatch
        composer.tap()
        composer.typeText("Важная мысль")
        app.buttons["alo.chat.expressions"].press(forDuration: 1.0)
        let quoteAction = app.buttons["Цитата"]
        XCTAssertTrue(quoteAction.waitForExistence(timeout: 3))
        capture("fmt-2-format-menu")
        quoteAction.tap()
        XCTAssertEqual(composer.value as? String, "> Важная мысль")
    }

    /// A large file shows its upload progress and can be paused and resumed.
    func testUploadProgressPauseAndResume() {
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "upload"]
        app.launch()
        let badge = app.buttons["alo.upload.990250"]
        XCTAssertTrue(badge.waitForExistence(timeout: 15))
        XCTAssertEqual(badge.label, "Приостановить загрузку")
        XCTAssertEqual(badge.value as? String, "34 процентов")
        Thread.sleep(forTimeInterval: 0.6)
        capture("up-1-uploading")
        badge.tap()
        XCTAssertEqual(badge.label, "Продолжить загрузку")
        Thread.sleep(forTimeInterval: 0.5)
        capture("up-2-paused")
        badge.tap()
        XCTAssertEqual(badge.label, "Приостановить загрузку")
    }

    /// A channel's admin sees Telegram-style statistics.
    func testChannelStatistics() {
        let app = launch(["-ALO_UI_CHANNEL_PROFILE", "1"])
        let stats = app.buttons["alo.channel.stats-button"]
        XCTAssertTrue(stats.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 0.6)
        capture("ch-1-channel-admin")
        stats.tap()
        XCTAssertTrue(app.staticTexts["Подписчики"].waitForExistence(timeout: 6))
        Thread.sleep(forTimeInterval: 0.8)
        capture("ch-2-stats")
        app.descendants(matching: .any)["alo.channel.stats"].swipeUp()
        Thread.sleep(forTimeInterval: 0.6)
        capture("ch-3-stats-posts")
    }

    /// Alo's own ad in the feed, and the moderation panel: reports, appeals, journal and ads.
    func testFeedAdAndModerationPanel() {
        let app = launch(["-ALO_UI_FEED_ADS", "1", "-ALO_UI_ADMIN", "1"])
        let any = app.descendants(matching: .any)
        let ad = any["alo.ad.1"]
        let scroll = any["alo.feed.scroll"]
        for _ in 0..<6 where !ad.isHittable { scroll.swipeUp(velocity: .slow) }
        XCTAssertTrue(ad.waitForExistence(timeout: 6))
        XCTAssertTrue(any["alo.ad.label"].exists)
        Thread.sleep(forTimeInterval: 0.5)
        capture("ad-1-feed")
        app.buttons["alo.ad.menu.1"].tap()
        app.buttons["Почему я это вижу"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        capture("ad-2-why")
        app.alerts.buttons["Скрыть рекламу"].tap()
        XCTAssertFalse(ad.waitForExistence(timeout: 2), "a hidden ad leaves the feed")

        scroll.swipeDown(velocity: .fast)
        scroll.swipeDown(velocity: .fast)
        app.buttons["alo.feed.settings"].tap()
        let moderation = app.buttons["alo.settings.moderation"]
        XCTAssertTrue(moderation.waitForExistence(timeout: 4))
        moderation.tap()
        XCTAssertTrue(app.buttons["alo.moderation.reports"].waitForExistence(timeout: 6))
        Thread.sleep(forTimeInterval: 0.6)
        capture("mod-0-root")
        let back = { app.navigationBars.buttons.element(boundBy: 0).tap() }

        app.buttons["alo.moderation.reports"].tap()
        let report = app.buttons["alo.moderation.report.14"]
        XCTAssertTrue(report.waitForExistence(timeout: 6))
        Thread.sleep(forTimeInterval: 0.6)
        capture("mod-1-reports")
        report.tap()
        XCTAssertTrue(app.buttons["alo.moderation.approve"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Быстрые деньги"].exists, "the decision shows who posted it")
        Thread.sleep(forTimeInterval: 0.6)
        capture("mod-2-decision")
        app.buttons["Ограничить доступ"].tap()
        XCTAssertTrue(app.segmentedControls["alo.moderation.block-duration"].waitForExistence(timeout: 3))
        app.segmentedControls["alo.moderation.block-duration"].buttons["Неделя"].tap()
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.4)
        capture("mod-2b-decision-measure")
        app.buttons["alo.moderation.approve"].tap()
        XCTAssertFalse(report.waitForExistence(timeout: 2), "a decided report leaves the queue")
        back()

        app.buttons["alo.moderation.appeals"].tap()
        XCTAssertTrue(app.buttons["alo.moderation.appeal.overturn"].waitForExistence(timeout: 4))
        capture("mod-3-appeals")
        back()
        app.buttons["alo.moderation.audit"].tap()
        XCTAssertTrue(app.staticTexts["Жалоба отклонена"].waitForExistence(timeout: 4))
        capture("mod-4-journal")
        back()

        // The team, by level; a lead moderator's rights; a blocked account found by search.
        app.buttons["alo.moderation.team"].tap()
        let masha = app.buttons["alo.team.member.990010"]
        XCTAssertTrue(masha.waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.5)
        capture("mod-7-team")
        masha.tap()
        XCTAssertTrue(any["alo.team.permission.moderation.manage"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.5)
        capture("mod-8-member")
        app.buttons["Закрыть"].tap()
        app.buttons["alo.team.search"].tap()
        let input = app.textFields["alo.team.people.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 4))
        input.tap()
        input.typeText("Быстр")
        let found = app.buttons["alo.team.result.990013"]
        XCTAssertTrue(found.waitForExistence(timeout: 4))
        capture("mod-9-search")
        found.tap()
        XCTAssertTrue(app.buttons["Восстановить доступ"].waitForExistence(timeout: 4), "a blocked account can be restored")
        Thread.sleep(forTimeInterval: 0.5)
        capture("mod-10-blocked")
        back()
        XCTAssertTrue(app.buttons["Готово"].waitForExistence(timeout: 3))
        app.buttons["Готово"].tap()
        back()

        app.buttons["alo.moderation.ads"].tap()
        XCTAssertTrue(app.staticTexts["Запуск историй"].waitForExistence(timeout: 4))
        capture("mod-5-ads")
        app.buttons["alo.ads.new"].tap()
        XCTAssertTrue(any["alo.ads.name"].waitForExistence(timeout: 4))
        any["alo.ads.name"].tap()
        any["alo.ads.name"].typeText("Осенняя кампания")
        Thread.sleep(forTimeInterval: 0.5)
        capture("mod-6-ad-editor")
    }

    /// Telegram's video chat: the participant list, admin tools, recording and a raised hand.
    func testGroupCallControls() {
        let admin = launch(["-ALO_UI_GROUP_CALL_PREVIEW", "1", "-ALO_UI_GROUP_CALL_MEMBER", "0"])
        let any = admin.descendants(matching: .any)
        XCTAssertTrue(any["alo.group-call.participants"].waitForExistence(timeout: 8))
        XCTAssertTrue(any["alo.group-call.recording"].exists, "the recording banner shows")
        Thread.sleep(forTimeInterval: 0.8)
        capture("gc-1-admin")
        admin.buttons["alo.group-call.menu"].tap()
        XCTAssertTrue(admin.buttons["Выключить микрофон всем"].waitForExistence(timeout: 3))
        XCTAssertTrue(admin.buttons["Остановить запись"].exists)
        capture("gc-2-admin-menu")
        admin.buttons["Выключить микрофон всем"].tap()
        let dasha = any["alo.group-call.participant.990012"]
        dasha.press(forDuration: 0.8)
        let allow = admin.buttons["Разрешить говорить"]
        XCTAssertTrue(allow.waitForExistence(timeout: 3))
        capture("gc-3-participant-menu")
        allow.tap()
        XCTAssertFalse(dasha.label.contains("хочет говорить"), "letting her speak lowers her hand")
        admin.terminate()

        let member = launch(["-ALO_UI_GROUP_CALL_PREVIEW", "1", "-ALO_UI_GROUP_CALL_MEMBER", "1"])
        let microphone = member.buttons["alo.group-call.microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 8))
        XCTAssertEqual(microphone.label, "Поднять руку")
        Thread.sleep(forTimeInterval: 0.8)
        capture("gc-4-member-muted")
        microphone.tap()
        XCTAssertEqual(microphone.label, "Вы подняли руку")
        Thread.sleep(forTimeInterval: 0.6)
        capture("gc-5-hand-raised")
    }

    /// Needs a video in the simulator's Photos (`xcrun simctl addmedia <udid> clip.mp4`).
    func testCaptureVideoStoryOverlay() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-surface"]
        app.launch()
        let story = app.buttons["alo.feed.create-story"]
        XCTAssertTrue(story.waitForExistence(timeout: 15))
        story.tap()
        // The editor opens typing; leave that first, as the keyboard covers the bottom bar.
        let done = app.buttons["alo.story.tool-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 4))
        done.tap()
        let gallery = app.buttons["alo.story.gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 4))
        gallery.tap()

        let video = app.descendants(matching: .any).matching(NSPredicate(
            format: "(label BEGINSWITH[c] 'Video' OR label BEGINSWITH[c] 'Видео') AND NOT (label CONTAINS[c] 'Photo' OR label CONTAINS 'Фотография')")).firstMatch
        guard video.waitForExistence(timeout: 10) else {
            print("PICKERDBG", app.debugDescription)
            throw XCTSkip("no video in the simulator's Photos")
        }
        // The picker runs in another process, so its cells report themselves as not hittable.
        Thread.sleep(forTimeInterval: 1.0)
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The picker's confirm button is labelled "Готово" too; its identifier tells it apart.
        let add = app.buttons.matching(identifier: "Add").firstMatch
        if add.waitForExistence(timeout: 3) { add.tap() }

        // The page shows the clip's real first frame and both tools are offered on it.
        let draw = app.buttons["alo.story.draw"]
        XCTAssertTrue(draw.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["alo.story.stickers"].exists)
        // Media pages swap the text-style button for "remove this media".
        XCTAssertTrue(app.buttons["Убрать это медиа"].waitForExistence(timeout: 30), "the video was imported")
        Thread.sleep(forTimeInterval: 2.0)
        capture("v-1-video-page")

        app.buttons["alo.story.stickers"].tap()
        XCTAssertTrue(app.buttons["✨"].waitForExistence(timeout: 3))
        app.buttons["✨"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        // The new sticker is selected; "Готово" leaves selection.
        app.buttons["alo.story.tool-done"].tap()

        // Text on the video, as in Instagram: typed, placed, then stretched by its corner.
        app.buttons["alo.story.add-text"].tap()
        XCTAssertTrue(app.buttons["Тёмная подложка"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        app.typeText("Водопад")
        app.buttons["Тёмная подложка"].tap()
        app.buttons["alo.story.tool-done"].tap()
        let caption = app.descendants(matching: .any).matching(identifier: "alo.story.text-item").firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 3))
        let frame = caption.frame
        let knob = caption.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width - 20, dy: frame.height - 20))
        knob.press(forDuration: 0.1, thenDragTo: knob.withOffset(CGVector(dx: 40, dy: 20)), withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThan(caption.frame.width, frame.width * 1.2)
        capture("v-2-video-text")
        app.buttons["alo.story.tool-done"].tap()

        draw.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.66))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.58)),
                    withVelocity: .slow, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 0.6)
        capture("v-3-video-drawing")
        app.buttons["alo.story.tool-done"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("v-4-video-ready")

        // Publishing burns the overlay into the video first; offline, the upload then fails visibly.
        app.buttons["alo.story.publish"].tap()
        XCTAssertTrue(app.buttons["alo.story.publish-confirm"].waitForExistence(timeout: 4))
        app.buttons["alo.story.publish-confirm"].tap()
        let error = app.descendants(matching: .any).matching(identifier: "alo.story.publish-error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 60), "the video was composed and the upload attempted")
        print("STORYDBG", error.label)
        XCTAssertFalse(error.label.contains("подготовить видео"), "composition itself must not fail: \(error.label)")
        capture("v-5-publish-offline")
    }

    func testCaptureCreationEditors() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "feed-surface"]
        app.launch()
        let post = app.buttons["alo.feed.create-post"]
        XCTAssertTrue(post.waitForExistence(timeout: 15))
        post.tap()
        XCTAssertTrue(app.buttons["alo.post.publish"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 1.0)
        capture("p-post-editor")
        app.typeText("Вечером собираемся в парке, присоединяйтесь!")
        Thread.sleep(forTimeInterval: 0.6)
        capture("p-post-editor-typed")
        app.buttons["Закрыть редактор поста"].tap()
        // Typed text: closing asks about a draft.
        let discard = app.buttons["Удалить"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        discard.tap()
        let story = app.buttons["alo.feed.create-story"]
        XCTAssertTrue(story.waitForExistence(timeout: 4))
        story.tap()
        XCTAssertTrue(app.buttons["alo.story.publish"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 1.0)
        capture("p-story-editor")
        app.typeText("Сегодня в парке!")
        app.buttons["alo.story.tool-done"].tap()
        app.buttons["alo.story.publish"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["alo.story.lifetime"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.8)
        capture("p-story-lifetime")
    }

    func testCaptureCommunityCreation() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "chat-list"]
        app.launch()
        XCTAssertTrue(app.buttons["Новое сообщение"].waitForExistence(timeout: 15))
        app.buttons["Новое сообщение"].tap()
        XCTAssertTrue(app.buttons["alo.compose.group"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.8)
        capture("n-1-new-message")

        // Group: members, then name and photo.
        app.buttons["alo.compose.group"].tap()
        let people = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'alo.compose.person.'"))
        XCTAssertTrue(people.firstMatch.waitForExistence(timeout: 4))
        print("CREATEDBG people", people.count)
        people.element(boundBy: 0).tap()
        if people.count > 1 { people.element(boundBy: 1).tap() }
        Thread.sleep(forTimeInterval: 0.6)
        capture("n-2-group-members")
        app.buttons["alo.compose.action"].tap()
        let title = app.textFields["alo.community.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        title.typeText("Друзья")
        Thread.sleep(forTimeInterval: 0.6)
        capture("n-3-group-info")
        app.buttons["alo.compose.leading"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        app.buttons["alo.compose.leading"].tap()
        XCTAssertTrue(app.buttons["alo.compose.channel"].waitForExistence(timeout: 4))

        // Channel: name and description, type and link, subscribers.
        app.buttons["alo.compose.channel"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        title.typeText("Новости района")
        app.descendants(matching: .any).matching(identifier: "alo.community.description").firstMatch.tap()
        app.typeText("Главное о нашем районе каждый день.")
        Thread.sleep(forTimeInterval: 0.6)
        capture("n-4-channel-info")
        app.buttons["alo.compose.action"].tap()
        let username = app.textFields["alo.community.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 4))
        username.tap()
        username.typeText("raion_news")
        Thread.sleep(forTimeInterval: 0.6)
        capture("n-5-channel-type-public")
        app.buttons["alo.community.private"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("n-6-channel-type-private")
        app.buttons["alo.compose.action"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        capture("n-7-channel-subscribers")
    }

    func testCaptureChatEdges() {
        for (name, extra) in [("light", ["-ALO_UI_MESSENGER_SURFACE", "1"]), ("dark", [])] {
            let app = XCUIApplication()
            app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "bubble-shapes"] + extra
            app.launch()
            XCTAssertTrue(app.buttons["alo.chat.back"].waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 1.5)
            capture("e-edges-\(name)")
            app.terminate()
        }
    }

    func testCaptureCommunityProfiles() {
        for content in ["channel-owner", "group-owner"] {
            let app = XCUIApplication()
            app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content]
            app.launch()
            XCTAssertTrue(app.buttons["alo.chat.info"].waitForExistence(timeout: 15))
            app.buttons["alo.chat.info"].tap()
            Thread.sleep(forTimeInterval: 1.2)
            capture("c-\(content)-profile")
            XCTAssertFalse(app.buttons["alo.group.delete"].exists, "delete is not on the profile page")
            print("COMMDBG", content, "leave:", app.buttons["alo.group.leave"].exists)
            app.buttons["alo.peer.more"].tap()
            XCTAssertTrue(app.buttons["Управление"].waitForExistence(timeout: 3))
            capture("c-\(content)-more")
            app.buttons["Управление"].tap()
            let delete = app.buttons["alo.group.delete"]
            for _ in 0..<8 where !delete.isHittable { app.swipeUp() }
            Thread.sleep(forTimeInterval: 0.6)
            capture("c-\(content)-manage-delete")
            print("COMMDBG", content, "delete in management:", delete.exists, delete.label)
            app.terminate()
        }
    }

    func testCaptureBubbleShapes() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", "bubble-shapes"]
        app.launch()
        XCTAssertTrue(app.buttons["alo.chat.back"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1.5)
        capture("b-bubbles-bottom")
        for id in 990210...990218 {
            let body = app.descendants(matching: .any).matching(identifier: "alo.message.body.\(id)").firstMatch
            let time = app.descendants(matching: .any).matching(identifier: "alo.message.time.\(id)").firstMatch
            let media = app.descendants(matching: .any).matching(identifier: "alo.message.media.\(id)").firstMatch
            print("BUBBLEDBG", id, body.exists ? "\(body.frame)" : "-", time.exists ? "\(time.frame)" : "-", media.exists ? "\(media.frame)" : "-")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)), withVelocity: .slow, thenHoldForDuration: 0.5)
        Thread.sleep(forTimeInterval: 1.0)
        capture("b-bubbles-top")
    }

    /// "Оформление профиля": one of ten colours, or your own photo cropped to the banner's shape;
    /// the profile shows it after "Готово", and the photo can be taken off again.
    func testProfileBannerEditor() {
        let app = launch()
        app.buttons["Профиль"].firstMatch.tap()
        let open = app.buttons["Оформление профиля"]
        XCTAssertTrue(open.waitForExistence(timeout: 6))
        open.tap()
        let editor = app.descendants(matching: .any).matching(identifier: "alo.banner.editor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        app.buttons["Закат"].tap()
        XCTAssertTrue(app.buttons["Закат"].isSelected)
        Thread.sleep(forTimeInterval: 0.5)
        capture("bn-1-colors")

        app.buttons["Фото"].tap()
        app.buttons["alo.banner.pick"].tap()
        Thread.sleep(forTimeInterval: 2.5)
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Фото' OR label BEGINSWITH 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 6))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let choose = app.buttons["alo.banner.crop.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 8), "the banner cropper opens after picking a photo")
        Thread.sleep(forTimeInterval: 0.8)
        capture("bn-2-crop")
        app.descendants(matching: .any)["alo.banner.crop.canvas"].pinch(withScale: 1.6, velocity: 1.2)
        Thread.sleep(forTimeInterval: 0.6)
        choose.tap()
        XCTAssertTrue(choose.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.buttons["alo.banner.remove-photo"].waitForExistence(timeout: 3), "the photo is now the banner")
        XCTAssertEqual(app.descendants(matching: .any)["alo.banner.preview"].label, "Предпросмотр: обложка с фото")
        Thread.sleep(forTimeInterval: 0.6)
        capture("bn-3-preview")

        app.buttons["alo.banner.save"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 1.5)
        capture("bn-4-profile")
        // The profile shows the photo, not the colour: sample its middle (pink flowers, not orange).
        let shot = XCUIScreen.main.screenshot().image
        let probe = shot.cgImage!.cropping(to: CGRect(x: shot.size.width * shot.scale * 0.5, y: 160 * shot.scale, width: 1, height: 1))!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(probe, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertFalse(pixel[1] > 80 && pixel[2] < 60 && pixel[0] > 180, "the banner is the photo, not the orange gradient: \(pixel)")

        // Back to a colour: the photo goes.
        open.tap()
        XCTAssertTrue(app.buttons["alo.banner.remove-photo"].waitForExistence(timeout: 4))
        app.buttons["alo.banner.remove-photo"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["alo.banner.preview"].label, "Предпросмотр: обложка «Закат»")
        app.buttons["alo.banner.save"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 4))
    }

    func testAvatarCropCapture() {
        let app = launch()
        app.buttons["Профиль"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.images["camera.fill"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Загрузить новое фото"].waitForExistence(timeout: 4))
        app.buttons["Загрузить новое фото"].tap()
        Thread.sleep(forTimeInterval: 2.5)
        // The system picker lives out of process but is reachable through the app's tree.
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Фото' OR label BEGINSWITH 'Photo'")).firstMatch
        if !photo.waitForExistence(timeout: 4) {
            print("CROPDBG picker tree", app.debugDescription.prefix(3000))
        }
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let choose = app.buttons["alo.avatar.crop.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 6), "the cropper opens after picking a photo")
        Thread.sleep(forTimeInterval: 0.6)
        capture("u-crop-1-opened")
        let canvas = app.descendants(matching: .any)["alo.avatar.crop.canvas"]
        canvas.pinch(withScale: 2.2, velocity: 1.5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.55)), withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 0.8)
        capture("u-crop-2-zoomed")
        app.buttons["alo.avatar.crop.rotate"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        capture("u-crop-3-rotated")
        choose.tap()
        XCTAssertTrue(choose.waitForNonExistence(timeout: 4), "choosing closes the cropper")
        Thread.sleep(forTimeInterval: 1.5)
        capture("u-crop-4-after")
    }

    func testSettingsChromeCapture() {
        let app = launch()
        app.buttons["Профиль"].firstMatch.tap()
        XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 4))
        app.buttons["alo.profile.settings"].tap()
        Thread.sleep(forTimeInterval: 1.2)
        capture("s-settings-root")
        app.buttons["Приватность"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("s-settings-privacy")
        // The edge swipe walks up one level: privacy → settings → profile.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)), withVelocity: .default, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["Закрыть настройки"].waitForExistence(timeout: 3), "edge swipe returns to the settings list")
        capture("s-settings-swipe-back")
        app.buttons["Закрыть настройки"].tap()
        XCTAssertTrue(app.buttons["alo.profile.settings"].waitForExistence(timeout: 3))
    }

    func testAvatarPickerAndPhotoPaging() {
        var app = launch()
        app.buttons["Профиль"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let avatar = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Тест интерфейса'")).firstMatch
        let camera = app.images["camera.fill"].firstMatch
        if camera.exists { camera.tap() } else { avatar.tap() }
        XCTAssertTrue(app.buttons["Загрузить новое фото"].waitForExistence(timeout: 4), "avatar options appear")
        capture("u-avatar-options")
        app.buttons["Загрузить новое фото"].tap()
        Thread.sleep(forTimeInterval: 2.5)
        capture("u-avatar-picker")
        app.terminate()

        app = launch()
        let gallery = app.otherElements.matching(NSPredicate(format: "identifier == 'alo.post.media.990401'")).firstMatch
        let anyMedia = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'alo.post.media.'"))
        print("MEDIADBG", anyMedia.count, gallery.exists)
        // The first photo of the first two-photo post (990402), so there is a page to swipe to.
        let pair = app.otherElements.matching(NSPredicate(format: "identifier == 'alo.post.media.990402'")).firstMatch
        let target = pair.exists ? pair : (gallery.exists ? gallery : anyMedia.element(boundBy: min(1, anyMedia.count - 1)))
        if !target.isHittable { app.scrollViews["alo.feed.scroll"].swipeUp(velocity: .slow) }
        target.tap()
        Thread.sleep(forTimeInterval: 1.2)
        capture("u-paging-1")
        for e in app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' из '")).allElementsBoundByIndex { print("PAGEDBG start", e.label) }
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.52)), withVelocity: .default, thenHoldForDuration: 0.0)
        Thread.sleep(forTimeInterval: 1.0)
        capture("u-paging-2")
        for e in app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' из '")).allElementsBoundByIndex { print("PAGEDBG", e.label) }
        // Back to the first photo, then zoom: a zoomed photo pans instead of paging.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)), withVelocity: .default, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1.0)
        capture("u-paging-back")
        for e in app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' из '")).allElementsBoundByIndex { print("PAGEDBG back", e.label) }
        app.swipeLeft()
        Thread.sleep(forTimeInterval: 1.0)
        capture("u-paging-forward")
        for e in app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' из '")).allElementsBoundByIndex { print("PAGEDBG swipeLeft", e.label) }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        Thread.sleep(forTimeInterval: 0.8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 0.8)
        capture("u-zoomed-pan")
        // Back to the fitted photo; a vertical drag closes the viewer.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        Thread.sleep(forTimeInterval: 0.8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.85)), withVelocity: .fast, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1.0)
        print("PAGEDBG closed", !app.buttons["alo.post.viewer.close"].exists)
        capture("u-viewer-closed")
    }
}
