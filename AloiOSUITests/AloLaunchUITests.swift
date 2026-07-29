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

        let avatar = app.descendants(matching: .any)[
            "alo.call-peer-avatar"
        ]
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

        let avatar = app.descendants(matching: .any)[
            "alo.call-peer-avatar"
        ]
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
        let screenShare = app.buttons["alo.call-screen-share"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        XCTAssertTrue(screenShare.waitForExistence(timeout: 5))
        let frameBefore = identity.frame

        screenShare.tap()

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
            app.buttons["alo.call-microphone"],
            app.buttons["alo.call-speaker"],
            app.buttons["alo.call-camera"],
            app.buttons["alo.call-screen-share"],
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
        for spacing in spacings.dropFirst() {
            XCTAssertEqual(spacing, spacings[0], accuracy: 2)
        }

        let windowFrame = app.windows.firstMatch.frame
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
        XCTAssertGreaterThan(safety.frame.minY, windowFrame.minY + 50)

        let identityFrame = identity.frame
        safety.tap()
        XCTAssertEqual(identity.frame.midX, identityFrame.midX, accuracy: 1)
        XCTAssertEqual(identity.frame.midY, identityFrame.midY, accuracy: 1)
    }

    func testVideoButtonPresentsThreeSourcePreviewWithoutFloatingFlip() {
        let app = XCUIApplication()
        app.launchArguments += ["-ALO_UI_CALL_PREVIEW", "1"]
        app.launch()

        let compactBar = app.buttons["alo.compact-call-bar"]
        XCTAssertTrue(compactBar.waitForExistence(timeout: 10))
        compactBar.tap()

        let camera = app.buttons["alo.call-camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
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
