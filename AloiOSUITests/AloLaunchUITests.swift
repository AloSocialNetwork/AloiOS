import XCTest

final class AloLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndKeepsAVisibleWindow() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_TEST_MODE", "1"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    func testCallMinimizeButtonAndForegroundReturn() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_CALL_PREVIEW", "1"]
        app.launch()
        let bar = app.buttons["alo.compact-call-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.tap()
        let minimize = app.buttons["alo.call.minimize"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(minimize.frame.minY, 25)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "call-expanded-v33"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        minimize.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(minimize.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["alo.call-end"].exists)
    }

    /// Telegram's call palettes: blue–violet while calling, green while talking (signal bars and
    /// timer), orange–pink on a weak link; the minimized bar takes the same colours.
    func testCaptureTelegramCallStates() {
        let states: [(String, [String])] = [
            ("calling", []),
            ("talking", ["-ALO_UI_CALL_PHASE", "active", "-ALO_UI_CALL_VOICE", "2.5", "-ALO_UI_CALL_QUALITY", "0.8"]),
            ("weak", ["-ALO_UI_CALL_PHASE", "active", "-ALO_UI_CALL_QUALITY", "0.1"]),
            ("incoming", ["-ALO_UI_CALL_PHASE", "incoming"])
        ]
        for (name, arguments) in states {
            let app = XCUIApplication()
            app.launchArguments += ["-ALO_UI_CALL_PREVIEW", "1", "-ALO_UI_CALL_VIDEO_PREVIEW", "0"] + arguments
            app.launch()
            let avatar = app.descendants(matching: .any).matching(identifier: "alo.call-peer-avatar").firstMatch
            if !avatar.waitForExistence(timeout: 4) {
                let bar = app.buttons["alo.compact-call-bar"]
                XCTAssertTrue(bar.waitForExistence(timeout: 6), name)
                bar.tap()
            }
            XCTAssertTrue(avatar.waitForExistence(timeout: 5), name)
            Thread.sleep(forTimeInterval: 1.5)
            attachScreenshot("call-\(name)")
            if name == "talking" || name == "calling" {
                app.buttons["alo.call.minimize"].tap()
                Thread.sleep(forTimeInterval: 1.2)
                attachScreenshot("call-bar-\(name)")
            }
            app.terminate()
        }
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The bar fills the status bar; a tap on the clock or the battery must open the call too.
    func testCompactCallBarOpensFromTheStatusBarArea() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_CALL_PREVIEW", "1"]
        app.launch()
        let bar = app.buttons["alo.compact-call-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "call-compact-bar"
        shot.lifetime = .keepAlways
        add(shot)
        let minimize = app.buttons["alo.call.minimize"]
        for (index, point) in [CGVector(dx: 0.16, dy: 0.5), CGVector(dx: 0.86, dy: 0.5), CGVector(dx: 0.16, dy: 0.15)].enumerated() {
            // Points inside the bar, measured from its top-left corner: clock, battery, the very top.
            bar.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: bar.frame.width * point.dx, dy: bar.frame.height * point.dy * 0.6))
                .tap()
            XCTAssertTrue(minimize.waitForExistence(timeout: 3), "tap \(index) at the top opens the call")
            minimize.tap()
            // The call slides away first; only then does the bar take touches again.
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: minimize)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    func testCompactCallBarIsTopmostAndDismissesWithoutNetwork() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_CALL_PREVIEW", "1"]
        app.launch()

        let compactBar = app.buttons["alo.compact-call-bar"]
        XCTAssertTrue(compactBar.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(compactBar.frame.height, 40)
        XCTAssertLessThan(compactBar.frame.height, 80)
        XCTAssertEqual(compactBar.frame.minY, 0, accuracy: 2)

        compactBar.tap()
        let safetyButton = app.buttons["alo.call-safety-verification"]
        XCTAssertTrue(safetyButton.waitForExistence(timeout: 5))
        safetyButton.tap()
        XCTAssertEqual(
            safetyButton.label,
            "Закрыть проверку шифрования"
        )
        safetyButton.tap()

        let avatar = app.descendants(matching: .any)
            .matching(identifier: "alo.call-peer-avatar").firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let avatarFrameBeforeMute = avatar.frame

        let microphoneButton = app.buttons["alo.call-microphone"]
        XCTAssertTrue(microphoneButton.waitForExistence(timeout: 5))
        microphoneButton.tap()
        let mutedNotice = app.descendants(matching: .any)[
            "alo.call-muted-notice"
        ]
        XCTAssertTrue(mutedNotice.waitForExistence(timeout: 3))
        XCTAssertEqual(
            avatar.frame.midX,
            avatarFrameBeforeMute.midX,
            accuracy: 1
        )
        XCTAssertEqual(
            avatar.frame.midY,
            avatarFrameBeforeMute.midY,
            accuracy: 1
        )

        let endButton = app.buttons["alo.call-end"]
        XCTAssertTrue(endButton.waitForExistence(timeout: 5))
        endButton.tap()

        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: compactBar
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [disappeared], timeout: 3),
            .completed
        )
    }

    func testOutgoingVideoShowsAvatarAndLocalPreviewUntilAnswered() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ALO_UI_CALL_PREVIEW", "1",
            "-ALO_UI_CALL_VIDEO_PREVIEW", "1"
        ]
        app.launch()

        let avatar = app.descendants(matching: .any)
            .matching(identifier: "alo.call-peer-avatar").firstMatch
        let preview = app.descendants(matching: .any)[
            "alo.call-video-preview"
        ]
        let primaryVideo = app.descendants(matching: .any)[
            "alo.call-video-primary"
        ]

        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertFalse(primaryVideo.exists)
    }

    func testAnsweredVideoSwapsWithoutDuplicatingSurfaces() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_CALL_PREVIEW", "1", "-ALO_UI_CALL_VIDEO_PREVIEW", "1",
                                "-ALO_UI_CALL_REMOTE_VIDEO_PREVIEW", "1"]
        app.launch()
        let preview = app.descendants(matching: .any).matching(identifier: "alo.call-video-preview").firstMatch
        let primary = app.descendants(matching: .any).matching(identifier: "alo.call-video-primary").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue(primary.exists)
        let previewFrame = preview.frame
        for expected in ["local", "remote", "local", "remote"] {
            preview.tap()
            let switched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: primary)
            XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 3), .completed)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "alo.call-video-primary").count, 1)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "alo.call-video-preview").count, 1)
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                abs(preview.frame.width - previewFrame.width) < 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 3), .completed)
        }
    }

    func testFullCallSwipeMinimizesIntoStatusBar() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ALO_UI_CALL_PREVIEW", "1",
            "-ALO_UI_CALL_VIDEO_PREVIEW", "1"
        ]
        app.launch()

        let endButton = app.buttons["alo.call-end"]
        XCTAssertTrue(endButton.waitForExistence(timeout: 10))

        let window = app.windows.firstMatch
        let start = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.18)
        )
        let finish = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.82)
        )
        start.press(
            forDuration: 0.05,
            thenDragTo: finish,
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )

        let compactBar = app.buttons["alo.compact-call-bar"]
        XCTAssertTrue(compactBar.waitForExistence(timeout: 5))
        XCTAssertEqual(compactBar.frame.minY, 0, accuracy: 2)
        XCTAssertGreaterThanOrEqual(compactBar.frame.height, 40)
        XCTAssertFalse(endButton.exists)

        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(compactBar.exists)
        XCTAssertFalse(endButton.exists)

        compactBar.tap()
        XCTAssertTrue(endButton.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(endButton.exists)
        XCTAssertFalse(compactBar.isHittable)
    }

    func testShortCallSwipeReturnsTheFiniteSurface() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ALO_UI_CALL_PREVIEW", "1",
            "-ALO_UI_CALL_VIDEO_PREVIEW", "1"
        ]
        app.launch()

        let endButton = app.buttons["alo.call-end"]
        XCTAssertTrue(endButton.waitForExistence(timeout: 10))

        let window = app.windows.firstMatch
        window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.28)
        ).press(
            forDuration: 0.05,
            thenDragTo: window.coordinate(
                withNormalizedOffset: CGVector(dx: 0.50, dy: 0.43)
            ),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )

        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(endButton.exists)
        XCTAssertFalse(app.buttons["alo.compact-call-bar"].isHittable)
    }

    func testScreenShareNoticeDoesNotMoveCallIdentity() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ALO_UI_CALL_PREVIEW", "1",
            "-ALO_UI_CALL_VIDEO_PREVIEW", "1"
        ]
        app.launch()

        let identity = app.descendants(matching: .any)[
            "alo.call-peer-identity"
        ]
        let video = app.buttons["alo.call-camera"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        let frameBefore = identity.frame

        video.tap()
        video.tap()
        let screenSource = app.buttons["alo.call-video-source-0"]
        XCTAssertTrue(screenSource.waitForExistence(timeout: 5))
        screenSource.tap()
        app.buttons["alo.call-video-source-continue"].tap()

        let notice = app.descendants(matching: .any)[
            "alo.call-screen-share-notice"
        ]
        XCTAssertTrue(notice.waitForExistence(timeout: 3))
        XCTAssertEqual(identity.frame.midX, frameBefore.midX, accuracy: 1)
        XCTAssertEqual(identity.frame.midY, frameBefore.midY, accuracy: 1)
    }

    func testCallControlsKeepTelegramStyleLayout() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ALO_UI_CALL_PREVIEW", "1",
            "-ALO_UI_CALL_VIDEO_PREVIEW", "1"
        ]
        app.launch()

        let controls = [
            app.buttons["alo.call-speaker"],
            app.buttons["alo.call-camera"],
            app.buttons["alo.call-microphone"],
            app.buttons["alo.call-end"]
        ]
        for control in controls {
            XCTAssertTrue(control.waitForExistence(timeout: 10))
        }

        let frames = controls.map(\.frame)
        let firstMidY = frames[0].midY
        for frame in frames.dropFirst() {
            XCTAssertEqual(frame.midY, firstMidY, accuracy: 1)
        }
        for index in 1..<frames.count {
            XCTAssertGreaterThan(frames[index].midX, frames[index - 1].midX)
        }

        let spacings = zip(frames, frames.dropFirst()).map {
            $1.midX - $0.midX
        }
        XCTAssertEqual(spacings[0], 92, accuracy: 1, "56 pt control + 36 pt reference gap")
        for spacing in spacings.dropFirst() {
            XCTAssertEqual(spacing, spacings[0], accuracy: 2)
        }

        let windowFrame = app.windows.firstMatch.frame
        let bottomSafeInset: CGFloat = windowFrame.height <= 736 ? 0 : 34
        XCTAssertEqual(windowFrame.maxY - bottomSafeInset - (frames[0].minY + 56), 52, accuracy: 1)
        XCTAssertGreaterThanOrEqual(frames[0].minX, windowFrame.minX)
        XCTAssertLessThanOrEqual(frames.last?.maxX ?? 0, windowFrame.maxX)
        XCTAssertGreaterThanOrEqual(
            windowFrame.maxY - (frames.last?.maxY ?? windowFrame.maxY),
            8
        )

        let identity = app.descendants(matching: .any)[
            "alo.call-peer-identity"
        ]
        let safety = app.buttons["alo.call-safety-verification"]
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        XCTAssertTrue(safety.waitForExistence(timeout: 5))
        // The SE has a 20 pt status region; the notched QA device has >50 pt.
        // Full-screen calls don't expose a native XCUI StatusBar element.
        XCTAssertGreaterThan(safety.frame.minY, windowFrame.minY + (windowFrame.height <= 736 ? 20 : 50))

        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "call-reference-controls"
        capture.lifetime = .keepAlways
        add(capture)
        let identityFrame = identity.frame
        safety.tap()
        XCTAssertEqual(identity.frame.midX, identityFrame.midX, accuracy: 1)
        XCTAssertEqual(identity.frame.midY, identityFrame.midY, accuracy: 1)
    }

    func testVideoButtonPresentsThreeSourcePreviewWithoutFloatingFlip() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ALO_UI_CALL_PREVIEW", "1",
            "-ALO_UI_CALL_VIDEO_PREVIEW", "0",
            "-ALO_UI_CALL_REMOTE_VIDEO_PREVIEW", "0"
        ]
        app.launch()

        let compactBar = app.buttons["alo.compact-call-bar"]
        XCTAssertTrue(compactBar.waitForExistence(timeout: 10))
        compactBar.tap()

        let camera = app.buttons["alo.call-camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        let cameraIsHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: camera
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [cameraIsHittable], timeout: 3),
            .completed
        )
        camera.tap()

        let picker = app.descendants(matching: .any)[
            "alo.call-video-source-picker"
        ]
        let dimming = app.descendants(matching: .any)[
            "alo.call-video-source-dimming"
        ]
        let cancel = app.buttons["alo.call-video-source-cancel"]
        let continueButton = app.buttons[
            "alo.call-video-source-continue"
        ]
        let screen = app.buttons["alo.call-video-source-0"]
        let front = app.buttons["alo.call-video-source-1"]
        let back = app.buttons["alo.call-video-source-2"]

        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(dimming.exists)
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(continueButton.exists)
        XCTAssertTrue(screen.exists)
        XCTAssertTrue(front.exists)
        XCTAssertTrue(back.exists)

        let attachment = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        attachment.name = "Alo call video source picker"
        attachment.lifetime = .keepAlways
        add(attachment)

        screen.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "alo.call-video-source-screen-placeholder"
            ].waitForExistence(timeout: 3)
        )

        cancel.tap()
        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: picker
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [disappeared], timeout: 3),
            .completed
        )
    }
}
