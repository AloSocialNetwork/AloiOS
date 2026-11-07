import XCTest

/// The media viewer against a running cross-client stand (tools/cross-client-check/stand.js): the chat with «Сайт»
/// holds a tall video, a wide video and a photo. Screenshots of the player while it loads (shape, one centre for the
/// button and the ring) and of the photo's zoom: a pinch, a double tap in and out, a drag down closes.
///   TEST_RUNNER_ALO_STAND_URL=http://127.0.0.1:3953/ TEST_RUNNER_ALO_STAND_TOKEN=<ios token>
///   xcodebuild … -only-testing:AloiOSUITests/AloMediaViewerStandUITests test
final class AloMediaViewerStandUITests: XCTestCase {
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func openChat() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["ALO_STAND_URL"], let token = env["ALO_STAND_TOKEN"] else { throw XCTSkip("no stand") }
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-ALO_DEBUG_API_BASE_URL", url, "-ALO_DEBUG_SESSION_TOKEN", token]
        app.launch()
        let ok = app.buttons["Ок"]
        if ok.waitForExistence(timeout: 4) { ok.tap() }
        app.buttons["Чаты"].firstMatch.tap()
        let chat = app.staticTexts["Сайт"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        return app
    }

    private func media(_ app: XCUIApplication) -> [XCUIElement] {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'alo.message.media.'"))
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        return query.allElementsBoundByIndex.filter { $0.frame.height > 40 }.sorted { $0.frame.minY < $1.frame.minY }
    }

    func testVideosOpenInTheirShape() throws {
        let app = try openChat()
        let items = media(app)
        XCTAssertGreaterThanOrEqual(items.count, 3)
        for (index, item) in items.suffix(3).prefix(2).enumerated() {
            item.tap()
            let play = app.buttons["alo.video.play"]
            XCTAssertTrue(play.waitForExistence(timeout: 15), "the player opens")
            // The button sits in the middle of the screen (where the picture is), not above the bottom bar.
            // Its controls hide by themselves, so a tap brings them back if they have gone already.
            if !play.exists { app.windows.firstMatch.tap() }
            let frame = play.frame
            let screen = app.windows.firstMatch.frame
            XCTAssertEqual(frame.midY, screen.midY, accuracy: 3, "play button centre \(frame) vs screen \(screen)")
            XCTAssertEqual(frame.midX, screen.midX, accuracy: 3)
            capture("video-\(index)-opened")
            sleep(2)
            capture("video-\(index)-3s")
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            sleep(1)
        }
    }

    func testPhotoZooms() throws {
        let app = try openChat()
        guard let photo = media(app).last else { return XCTFail("no photo") }
        photo.tap()
        let image = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Фото. Дважды'")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 6))
        capture("photo-opened")
        image.pinch(withScale: 3, velocity: 3)
        sleep(1)
        capture("photo-pinched")
        image.doubleTap()
        sleep(1)
        capture("photo-double-tap-out")
        image.doubleTap()
        sleep(1)
        capture("photo-double-tap-in")
        image.doubleTap()
        sleep(1)
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        sleep(1)
        capture("photo-after-swipe-down")
        XCTAssertFalse(image.exists, "a drag down closes the viewer")
    }
}
