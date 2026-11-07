import XCTest

/// One-off probe (2026-10-29): opens a group on a test stand, scrolls it and saves screenshots of the sticky group
/// avatars and the circle labels. Needs TEST_RUNNER_ALO_STAND_URL, _TOKEN, _INVITE and _SHOT_DIR; skips without them.
final class AloStickyAvatarProbeUITests: XCTestCase {
    func testStickyAvatarScreens() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["ALO_STAND_URL"], let token = env["ALO_STAND_TOKEN"],
              let invite = env["ALO_STAND_INVITE"], let dir = env["ALO_SHOT_DIR"] else {
            throw XCTSkip("no stand")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_DEBUG_API_BASE_URL", url, "-ALO_DEBUG_SESSION_TOKEN", token,
                               "-alo.ios.pending-deep-link.v1", "alo://join/\(invite)"]
        app.launch()
        sleep(12)
        save(dir, "ios-group-bottom")
        let history = app.descendants(matching: .any)["alo.chat.history"]
        let target = history.exists ? history : app.windows.firstMatch
        target.swipeDown(velocity: .slow)
        sleep(2)
        save(dir, "ios-group-scrolled-1")
        target.swipeDown(velocity: .slow)
        sleep(2)
        save(dir, "ios-group-scrolled-2")
    }

    private func save(_ dir: String, _ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
