import XCTest

/// Visual review only: walks the design fixture screen by screen and attaches a screenshot of each,
/// so the iPhone can be compared with the Android and web screens side by side. A missing control is
/// logged and skipped, never fatal, so one moved button doesn't hide the rest of the tour.
final class AloDesignTourUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(_ content: String = "social-overview", _ extra: [String] = []) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content,
            "-ALO_UI_MESSENGER_ACCESSIBILITY", "0", "-ALO_UI_REDUCE_MOTION", "0",
            "-ALO_UI_REDUCE_TRANSPARENCY", "0", "-ALO_UI_INCREASE_CONTRAST", "0", "-ALO_UI_LEGACY_GLASS", "0",
            "-ALO_UI_SEARCH_INCOMING", "0"] + extra
        app.launch()
        _ = app.buttons["Профиль"].firstMatch.waitForExistence(timeout: 15)
        settle(1.2)
    }

    private func settle(_ seconds: TimeInterval = 0.9) { Thread.sleep(forTimeInterval: seconds) }

    private func capture(_ name: String) {
        settle()
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    private func dump(_ name: String) {
        let text = XCTAttachment(string: app.debugDescription)
        text.name = "tree-" + name; text.lifetime = .keepAlways; add(text)
    }

    @discardableResult
    private func tap(_ element: XCUIElement, _ label: String, wait: TimeInterval = 2) -> Bool {
        guard element.waitForExistence(timeout: wait) else {
            print("TOUR: no \(label)"); return false
        }
        element.tap(); settle(); return true
    }

    private func button(_ key: String) -> XCUIElement { app.buttons[key].firstMatch }

    private func back() {
        for key in ["Закрыть редактор поста", "Назад к чатам", "alo.chat.back", "alo.peer.back", "alo.profile.back", "Назад", "Закрыть", "Готово"] {
            let candidate = app.buttons[key].firstMatch
            if candidate.exists && candidate.isHittable { candidate.tap(); settle(); return }
        }
        app.swipeRight(); settle()
    }

    func testTourMainScreens() {
        launch()
        capture("01-feed")
        if tap(button("alo.post.comments.990400"), "post comments") {
            capture("02-post-detail"); back()
        }
        if tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'alo.post.menu.'")).firstMatch, "post menu") {
            capture("03-post-menu"); app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap(); settle()
        }
        if tap(button("alo.feed.create-post"), "create post") { capture("04-post-composer"); back() }

        tap(button("Поиск"), "search tab")
        capture("05-search")
        let input = app.textFields["alo.search.input"]
        if tap(input, "search input") { input.typeText("Ал"); capture("06-search-results") }

        tap(button("Уведы"), "alerts tab")
        capture("07-notifications")

        tap(button("Профиль"), "profile tab")
        capture("08-own-profile")
        app.swipeUp(); capture("09-own-profile-scrolled")
    }

    func testTourChats() {
        launch()
        tap(button("Чаты"), "chats tab")
        capture("10-chat-list")
        dump("chat-list")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'alo.chats.row.' OR identifier BEGINSWITH 'alo.conversation.'")).firstMatch
        if !tap(row, "chat row") { tap(app.staticTexts["Александр"].firstMatch, "chat title") }
        capture("11-chat")
        dump("chat")
        if tap(button("alo.chat.attach"), "attach") { capture("12-chat-attach"); back() }
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'alo.message.body.'")).firstMatch
        if message.waitForExistence(timeout: 2) { message.press(forDuration: 0.8); capture("13-message-menu"); app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap(); settle() }
        if tap(button("Профиль собеседника"), "peer avatar") { capture("14-peer-profile"); back() }
        back()
        if tap(button("alo.chats.calls"), "calls") { capture("15-calls"); back() }
        if tap(button("alo.chats.archive.entry"), "archive") { capture("16-archive"); back() }
    }

    func testTourSettings() {
        launch()
        tap(button("Профиль"), "profile tab")
        guard tap(button("alo.profile.settings"), "settings") else { dump("no-settings"); return }
        capture("20-settings")
        dump("settings")
        for (index, title) in ["alo.settings.profile-info", "Безопасность", "Приватность", "Уведомления", "Оформление",
                               "Данные и память", "Бизнес-профиль", "Панель автора"].enumerated() {
            let row = app.buttons[title].firstMatch.exists ? app.buttons[title].firstMatch : app.staticTexts[title].firstMatch
            if tap(row, title) {
                capture(String(format: "%02d-settings-%@", 21 + index, title))
                back()
                if !button("Закрыть настройки").exists && !app.staticTexts["Настройки"].exists {
                    tap(button("alo.profile.settings"), "settings again")
                }
            }
        }
    }

    func testTourGroupsAndViewedProfile() {
        launch("group-owner")
        capture("30-group-chat")
        launch("social-overview", ["-ALO_UI_CHANNEL_PROFILE", "1"])
        capture("31-channel-profile")
        launch()
        tap(button("Поиск"), "search tab")
        let person = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Профиль: Александр'")).firstMatch
        if tap(person, "search person") { capture("32-viewed-profile") } else { dump("search") }
    }
}
