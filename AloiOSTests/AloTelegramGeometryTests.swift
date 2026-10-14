import Testing
import CoreGraphics
import Foundation
@testable import AloiOS

struct AloTelegramGeometryTests {
    private let rows = [1: CGRect(x: 0, y: 80, width: 200, height: 90),
                        2: CGRect(x: 0, y: 220, width: 200, height: 50)]

    @Test func naturalDateDoesNotHaveAFloatingDuplicate() {
        let headers = [1: CGRect(x: 0, y: 100, width: 200, height: 34)]
        #expect(AloChatDateLayout.placement(anchor: 100, rows: rows, headers: headers,
            headerIDs: [1: 1, 2: 2], labels: [1: "5 сентября", 2: "6 сентября"]) == nil)
    }

    @Test func nextDayPushesThePinnedDateInsteadOfStackingIt() {
        let result = AloChatDateLayout.placement(anchor: 100, rows: rows,
            headers: [1: CGRect(x: 0, y: 30, width: 200, height: 34),
                      2: CGRect(x: 0, y: 118, width: 200, height: 34)],
            headerIDs: [1: 1, 2: 2], labels: [1: "5 сентября", 2: "6 сентября"])
        #expect(result?.headerID == 1)
        #expect(result?.sectionY == 84)
        #expect(result!.sectionY + AloChatDateMetrics.sectionHeight == 118)
    }

    @Test func unrealizedOldDayStillPinsToTheLiveChrome() {
        for anchor: CGFloat in [64, 115] {
            let result = AloChatDateLayout.placement(anchor: anchor, rows: rows, headers: [:],
                headerIDs: [1: 1, 2: 2], labels: [1: "5 сентября", 2: "6 сентября"])
            #expect(result?.sectionY == anchor)
        }
        #expect(AloChatDateLayout.placement(anchor: 100, rows: [:], headers: [:], headerIDs: [:], labels: [:]) == nil)
    }

    @MainActor @Test func dateStaysVisibleThroughScrollingAndCancelsIdleFadeOnResume() async throws {
        let message = AloChatMessage(["id": 1, "senderId": 2, "body": "Test", "createdAt": "2026-09-05T10:08:00Z"])
        let snapshot = AloChatHistorySnapshot(messages: [message], polls: [:], pollIDsByMessage: [:])
        let controller = AloChatDateHeaderController()
        controller.update(anchor: 100, rows: rows, headers: [:], snapshot: snapshot, reduceMotion: true)
        #expect(!controller.isVisible)
        controller.scrollingChanged(true)
        #expect(controller.isVisible)
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.isVisible)
        controller.scrollingChanged(false)
        try await Task.sleep(for: .milliseconds(100))
        controller.scrollingChanged(true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.isVisible)
        controller.scrollingChanged(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!controller.isVisible)
        controller.reset()
        #expect(controller.placement == nil)
    }

    @Test func mediaUsesAspectRatioAndTelegramCompactLimits() {
        let landscape = AloChatMediaSizing.single(dimensions: AloMediaDimensions(width: 1920, height: 1080),
            video: false, availableWidth: 326)
        #expect(landscape.width == 300 && landscape.height == 168.75)
        let square = AloChatMediaSizing.single(dimensions: AloMediaDimensions(width: 1080, height: 1080),
            video: false, availableWidth: 326)
        #expect(square.width == 300 && square.height == 300)
        let portrait = AloChatMediaSizing.single(dimensions: AloMediaDimensions(width: 1080, height: 1920),
            video: false, availableWidth: 326)
        #expect(portrait.width == 213.75 && portrait.height == 380)
        let movie = AloChatMediaSizing.single(dimensions: AloMediaDimensions(width: 1080, height: 1920),
            video: true, availableWidth: 326)
        #expect(movie.width == 202.5 && movie.height == 360)
        #expect(AloMediaDimensions(width: .nan, height: 100) == nil)
        #expect(AloMediaDimensions(width: 0, height: 100) == nil)
    }

    @Test(arguments: [140.0, 230.0, 300.0, 375.0, 402.0])
    func extremeMediaStillFitsAvailableWidth(width: Double) {
        for dimensions in [AloMediaDimensions(width: 1, height: 10000), AloMediaDimensions(width: 10000, height: 1), nil] {
            let size = AloChatMediaSizing.single(dimensions: dimensions, video: false, availableWidth: width)
            #expect(size.width <= width && size.height >= 74 && size.height <= 380)
        }
    }

    @Test func dimensionsSurviveDraftTransformationsAndEncryptedMessageMetadata() {
        let dimensions = AloMediaDimensions(width: 1080, height: 1920)
        let draft = AloLocalAttachment(data: Data(), mime: "video/mp4", type: "video", name: "video.mp4",
            mediaDimensions: dimensions).withDuration(12).replacingWaveform([0.3])
        #expect(draft.mediaDimensions == dimensions)
        #expect(draft.durationMetadata["height"] == "1920.0")
        let attachment = AloMessageAttachment(local: draft, includeInlineData: false)
        #expect(attachment.mediaDimensions == dimensions && attachment.durationSeconds == 12)
    }

    @Test func recordingCameraFitsBetweenChromeAndControls() {
        for (width, height, expected) in [(375.0, 647.0, 351.0), (402.0, 778.0, 378.0), (320.0, 568.0, 216.0)] {
            let viewport = CGSize(width: width, height: height)
            let diameter = AloCircleRecordingLayout.diameter(viewport: viewport, topChrome: 64, bottomChrome: 54)
            let center = AloCircleRecordingLayout.centerY(viewport: viewport, diameter: diameter, topChrome: 64, bottomChrome: 54)
            #expect(abs(diameter - CGFloat(expected)) < 0.001)
            #expect(center - diameter / 2 >= 64)
            #expect(center + diameter / 2 + 57 < height - 54)
        }
        #expect(AloRecordingDrag(translation: CGSize(width: 0, height: -110)).lockProgress == 1)
    }

    @Test func callButtonSpacingMatchesReferenceAndAdaptsToNarrowPhones() {
        #expect(AloCallLayoutMetrics.activeButtonDiameter == 56)
        #expect(AloCallLayoutMetrics.peerAvatarSize == 136)
        #expect(AloCallLayoutMetrics.controlSpacing(availableWidth: 335) == 36)
        #expect(4 * 56 + 3 * AloCallLayoutMetrics.controlSpacing(availableWidth: 280) <= 280)
    }
}
