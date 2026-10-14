import AVFoundation
import UIKit
import Testing
@testable import AloiOS

struct AloCirclePlaybackTests {
    @Test(arguments: [CGFloat(299), 350, 396])
    func expansionFitsBothPhones(_ available: CGFloat) {
        #expect(AloCirclePresentation.diameter(available: available, expanded: false) == 212)
        #expect(AloCirclePresentation.diameter(available: available, expanded: true) <= available)
        #expect(AloCirclePresentation.diameter(available: available, expanded: true) > 212)
    }

    @Test func visibilityHasHysteresis() {
        let viewport = CGRect(x: 0, y: 100, width: 400, height: 600)
        let half = CGRect(x: 20, y: 0, width: 200, height: 200)
        #expect(AloCirclePresentation.isVisible(half, viewport: viewport, wasVisible: true))
        #expect(!AloCirclePresentation.isVisible(half, viewport: viewport, wasVisible: false))
        #expect(!AloCirclePresentation.isVisible(half.offsetBy(dx: 0, dy: -100), viewport: viewport, wasVisible: true))
        #expect(AloCirclePresentation.isVisible(half.offsetBy(dx: 0, dy: 140), viewport: viewport, wasVisible: false))
    }

    @Test func dockingKeepsMiniatureInsideSafeContainer() {
        let size = CGSize(width: 375, height: 400)
        #expect(AloCirclePresentation.bounded(CGPoint(x: -300, y: -400), size: size, diameter: 150) == CGPoint(x: 79, y: 79))
        #expect(AloCirclePresentation.bounded(CGPoint(x: 600, y: 1000), size: size, diameter: 150) == CGPoint(x: 296, y: 321))
    }

    @Test func floatingSizeUsesTheReferenceThresholdNotPhoneModel() {
        #expect(AloCirclePresentation.floatingDiameter(boundingSize: CGSize(width: 375, height: 600)) == 150)
        #expect(AloCirclePresentation.floatingDiameter(boundingSize: CGSize(width: 402, height: 600)) == 150)
        #expect(AloCirclePresentation.floatingDiameter(boundingSize: CGSize(width: 320, height: 600)) == 120)
        #expect(AloCirclePresentation.floatingDiameter(boundingSize: CGSize(width: 402, height: 300)) == 120)
        #expect(AloCirclePresentation.floatingDiameter(boundingSize: CGSize(width: 100, height: 90)) == 82)
    }

    @Test func slowReleaseDocksWithoutPredictedOvershootOrAccidentalDismissal() {
        let size = CGSize(width: 375, height: 700)
        let release = AloCirclePresentation.floatingRelease(center: CGPoint(x: 180, y: 180),
            velocity: CGPoint(x: 499, y: 0), container: size)
        #expect(release.corner == CGPoint(x: 0, y: 0))
        #expect(!release.dismisses)
        let outside = AloCirclePresentation.floatingRelease(center: CGPoint(x: 420, y: 180),
            velocity: .zero, container: size)
        #expect(outside.corner == CGPoint(x: 1, y: 0))
        #expect(!outside.dismisses)
    }

    @Test func directionalFlicksDockOrDismissFromEveryCorner() {
        let size = CGSize(width: 375, height: 700)
        for x: CGFloat in [0, 1] {
            for y: CGFloat in [0, 1] {
                let center = CGPoint(x: x == 0 ? 79 : 296, y: y == 0 ? 79 : 621)
                let inwardX: CGFloat = x == 0 ? 1 : -1
                let inwardY: CGFloat = y == 0 ? 1 : -1
                let horizontal = AloCirclePresentation.floatingRelease(center: center,
                    velocity: CGPoint(x: inwardX * 800, y: 0), container: size)
                #expect(horizontal.corner == CGPoint(x: 1 - x, y: y))
                #expect(!horizontal.dismisses)
                let vertical = AloCirclePresentation.floatingRelease(center: center,
                    velocity: CGPoint(x: 0, y: inwardY * 800), container: size)
                #expect(vertical.corner == CGPoint(x: x, y: 1 - y))
                #expect(!vertical.dismisses)
                let diagonal = AloCirclePresentation.floatingRelease(center: center,
                    velocity: CGPoint(x: inwardX * 800, y: inwardY * 800), container: size)
                #expect(diagonal.corner == CGPoint(x: 1 - x, y: 1 - y))
                #expect(!diagonal.dismisses)
                let outward = CGPoint(x: -inwardX * 800, y: 0)
                #expect(AloCirclePresentation.floatingRelease(center: center,
                    velocity: outward, container: size).dismisses)
                let cancelled = AloCirclePresentation.floatingRelease(center: center,
                    velocity: outward, container: size, cancelled: true)
                #expect(cancelled.corner == CGPoint(x: x, y: y))
                #expect(!cancelled.dismisses)
            }
        }
    }

    @Test func flickSpeedThresholdAndAngularToleranceAreExplicit() {
        let size = CGSize(width: 375, height: 700)
        let center = CGPoint(x: 79, y: 79)
        #expect(AloCirclePresentation.floatingRelease(center: center,
            velocity: CGPoint(x: 500, y: 0), container: size).corner == CGPoint(x: 1, y: 0))
        // 20° above the horizontal stays a cross-screen flick, not a dismissal.
        #expect(!AloCirclePresentation.floatingRelease(center: center,
            velocity: CGPoint(x: 800, y: -290), container: size).dismisses)
        #expect(AloCirclePresentation.floatingRelease(center: center,
            velocity: CGPoint(x: 0, y: -800), container: size).dismisses)
    }

    @Test @MainActor func inlineStartRetainsTheInlinePresentation() async throws {
        let sample = await AloMessengerSampleMedia.make()
        let url = try #require(sample.video)
        let item = AloCircleQueueItem(id: "inline", messageID: 12, url: url, title: "Кружок")
        let playback = AloCirclePlayback()
        defer { playback.stop() }

        playback.toggle(item, startsInline: true)

        #expect(playback.item?.id == item.id)
        #expect(playback.inlineVisible)
        #expect(playback.focusRequest == 0)
    }

    @Test @MainActor func transferRetainsPlayerAndQueueAdvances() async throws {
        let sample = await AloMessengerSampleMedia.make()
        let url = try #require(sample.video)
        let first = AloCircleQueueItem(id: "first", messageID: 1, url: url, title: "Первый")
        let next = AloCircleQueueItem(id: "next", messageID: 2, url: url, title: "Следующий")
        let playback = AloCirclePlayback()
        defer { playback.stop() }
        playback.setQueue([first, next])
        playback.viewport = CGRect(x: 0, y: 100, width: 400, height: 600)
        playback.play(first)
        let player = try #require(playback.player)
        #expect(playback.surfaceOwner == .floating)
        playback.updateVisibility(id: first.id, frame: CGRect(x: 0, y: 150, width: 200, height: 200))
        #expect(playback.inlineVisible)
        await Task.yield()
        #expect(playback.surfaceOwner == .inline)
        let inlineHost = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let floatingHost = UIView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
        playback.attachVideo(to: inlineHost, owner: .inline)
        let video = playback.videoView
        #expect(video.superview === inlineHost)
        playback.leaveInline(id: first.id)
        #expect(!playback.inlineVisible)
        #expect(playback.player === player)
        await Task.yield()
        #expect(playback.surfaceOwner == .floating)
        playback.attachVideo(to: floatingHost, owner: .floating)
        #expect(video.superview === floatingHost)
        #expect(inlineHost.subviews.isEmpty)
        // SwiftUI may dismantle the old host after the new host is attached.
        playback.detachVideo(from: inlineHost)
        #expect(video.superview === floatingHost)
        #expect(video.playerLayer.player === player)
        playback.updateVisibility(id: first.id, frame: CGRect(x: 0, y: 150, width: 200, height: 200))
        #expect(playback.player === player)
        #expect(playback.inlineVisible)
        await Task.yield()
        #expect(playback.surfaceOwner == .inline)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
        #expect(playback.item?.id == next.id)
        #expect(!playback.inlineVisible)
        // A removed player's stale notification cannot skip the next item.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
        #expect(playback.item?.id == next.id)
        playback.stop()
        #expect(playback.player == nil)
        #expect(playback.item == nil)
        #expect(!playback.isPlaying)
        #expect(video.superview == nil)
        #expect(video.playerLayer.player == nil)
    }

    @Test @MainActor func miniatureDoesNotInterceptHeaderOrComposer() async throws {
        let sample = await AloMessengerSampleMedia.make()
        let playback = AloCirclePlayback()
        defer { playback.stop() }
        playback.play(AloCircleQueueItem(id: "hit-test", messageID: 1,
            url: try #require(sample.video), title: "Кружок"))
        let host = AloFloatingCircleContainer(frame: CGRect(x: 0, y: 0, width: 430, height: 600))
        host.configure(playback: playback, accent: .blue, active: true, progress: 0,
            isPlaying: true, reduceMotion: true, onShowMessage: { _ in })
        host.layoutIfNeeded()
        #expect(host.hitTest(CGPoint(x: 10, y: 10), with: nil) == nil)
        #expect(host.hitTest(CGPoint(x: 215, y: 580), with: nil) == nil)
        #expect(host.hitTest(CGPoint(x: 346, y: 84), with: nil) != nil)
        host.configure(playback: playback, accent: .blue, active: false, progress: 0,
            isPlaying: false, reduceMotion: true, onShowMessage: { _ in })
        #expect(host.hitTest(CGPoint(x: 346, y: 84), with: nil) == nil)
    }

    @Test @MainActor func ownershipStaysFloatingUntilInteractionEnds() async throws {
        let sample = await AloMessengerSampleMedia.make()
        let playback = AloCirclePlayback()
        defer { playback.stop() }
        let item = AloCircleQueueItem(id: "settling", messageID: 1,
            url: try #require(sample.video), title: "Кружок")
        playback.viewport = CGRect(x: 0, y: 100, width: 400, height: 600)
        playback.play(item)
        let player = try #require(playback.player)
        playback.beginFloatingInteraction()
        playback.updateVisibility(id: item.id, frame: CGRect(x: 0, y: 150, width: 200, height: 200))
        #expect(playback.surfaceOwner == .floating)
        #expect(!playback.inlineVisible)
        #expect(playback.player === player)
        playback.endFloatingInteraction()
        #expect(playback.surfaceOwner == .inline)
        #expect(playback.inlineVisible)
        #expect(playback.player === player)
    }

    @Test @MainActor func miniatureRestoresItsCornerAfterInlineTransfer() async throws {
        let sample = await AloMessengerSampleMedia.make()
        let playback = AloCirclePlayback()
        defer { playback.stop() }
        playback.play(AloCircleQueueItem(id: "corner", messageID: 1,
            url: try #require(sample.video), title: "Кружок"))
        playback.floatingCorner = CGPoint(x: 0, y: 1)
        let host = AloFloatingCircleContainer(frame: CGRect(x: 0, y: 0, width: 430, height: 600))
        host.configure(playback: playback, accent: .blue, active: true, progress: 0,
            isPlaying: true, reduceMotion: true, onShowMessage: { _ in })
        host.layoutIfNeeded()
        #expect(host.hitTest(CGPoint(x: 84, y: 516), with: nil) != nil)
        #expect(host.hitTest(CGPoint(x: 346, y: 84), with: nil) == nil)
    }
}
