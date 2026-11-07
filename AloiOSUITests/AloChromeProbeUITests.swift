import XCTest

/// Measures where the shared chrome of every screen sits, and writes the numbers to
/// /private/tmp/alo-chrome-probe.txt. A development probe: the asserting twin is AloScreenChromeUITests.
final class AloChromeProbeUITests: XCTestCase {
    private let path = "/private/tmp/alo-chrome-probe.txt"

    private func launch(_ content: String, extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_UI_MESSENGER_PREVIEW", "1", "-ALO_UI_MESSENGER_CONTENT", content,
            "-ALO_UI_MESSENGER_ACCESSIBILITY", "0", "-ALO_UI_REDUCE_MOTION", "1",
            "-ALO_UI_REDUCE_TRANSPARENCY", "0", "-ALO_UI_INCREASE_CONTRAST", "0", "-ALO_UI_LEGACY_GLASS", "0",
            "-ALO_UI_SEARCH_INCOMING", "0"] + extra
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func log(_ line: String) {
        let data = (line + "\n").data(using: .utf8)!
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    private func frame(_ app: XCUIApplication, _ screen: String, _ id: String, wait: TimeInterval = 3) {
        let element = any(app, id)
        if element.waitForExistence(timeout: wait) {
            let f = element.frame
            log(String(format: "%@ | %@ | x=%.1f y=%.1f w=%.1f h=%.1f (maxX=%.1f maxY=%.1f)", screen, id, f.minX, f.minY, f.width, f.height, f.maxX, f.maxY))
        } else {
            log("\(screen) | \(id) | MISSING")
        }
    }

    func testProbeTabScreens() {
        try? FileManager.default.removeItem(atPath: path)
        let app = launch("social-overview")
        _ = app.buttons["alo.feed.tab.popular"].waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.0)
        log("window \(app.windows.firstMatch.frame)")
        for id in ["alo.feed.header", "alo.feed.title", "alo.feed.refresh", "alo.feed.tab.popular", "alo.feed.tab.friends", "alo.feed.tab.following", "alo.feed.create-post"] { frame(app, "feed", id) }
        for tab in ["Поиск", "Чаты", "Уведы", "Профиль"] {
            app.buttons[tab].firstMatch.tap()
            Thread.sleep(forTimeInterval: 1.0)
            switch tab {
            case "Поиск": for id in ["alo.search.title", "alo.search.settings", "alo.search.field"] { frame(app, "search", id) }
            case "Чаты": for id in ["alo.chats.title", "alo.chats.search.field", "alo.chats.calls", "alo.chats.select.begin"] { frame(app, "chats", id) }
            case "Уведы": for id in ["alo.alerts.title", "alo.alerts.settings", "alo.alerts.filter.all", "alo.alerts.filter.unread"] { frame(app, "alerts", id) }
            default: for id in ["alo.profile.settings", "alo.profile.relation", "alo.profile.message"] { frame(app, "profile", id) }
            }
        }
        // Settings pushed from the profile.
        app.buttons["alo.profile.settings"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        frame(app, "settings-root", "alo.settings.back")
        app.buttons["Приватность"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.8)
        frame(app, "settings-privacy", "alo.settings.back")
    }

    func testProbeChatAndPeer() {
        let app = launch("group-info")
        _ = any(app, "alo.chat.back").waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1.0)
        for id in ["alo.chat.back", "alo.chat.info", "alo.chat.title"] { frame(app, "chat", id) }
        app.buttons["alo.chat.info"].tap()
        Thread.sleep(forTimeInterval: 1.2)
        for id in ["alo.peer.back", "alo.peer.title", "alo.peer.search"] { frame(app, "group-info", id) }
    }

    func testProbeCalls() {
        let app = launch("chat-list")
        app.buttons["Чаты"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.buttons["alo.chats.calls"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        for id in ["alo.calls.back", "alo.calls.title", "alo.calls.filter.missed", "alo.calls.filter.all"] { frame(app, "calls", id) }
    }
}
