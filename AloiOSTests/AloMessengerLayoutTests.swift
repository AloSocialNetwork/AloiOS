import Testing
import CoreGraphics
import UIKit
@testable import AloiOS

struct AloMessengerLayoutTests {
    @Test func darkChatEdgesUseOneBoundedBlackScrim() {
        for edge in [AloChatEdge.top, .bottom] {
            #expect(edge.dimmingOpacity(reduceTransparency: false, increasedContrast: false) == 0.68)
            #expect(edge.dimmingOpacity(reduceTransparency: true, increasedContrast: false) == 1)
            #expect(edge.dimmingOpacity(reduceTransparency: false, increasedContrast: true) == 1)
        }
    }

    @Test func chatEdgeGeometryTracksChromeAndSafeAreas() {
        #expect(AloChatEdge.top.height(chrome: 64, safeArea: 62) == 154)
        #expect(AloChatEdge.top.height(chrome: 115, safeArea: 62) == 205)
        #expect(AloChatEdge.bottom.height(chrome: 52, safeArea: 34) == 102)
        #expect(AloChatEdge.bottom.height(chrome: 52, safeArea: 0) == 100)
        #expect(AloChatEdge.top.height(chrome: -10, safeArea: -20) == 100)
    }

    @Test(arguments: [1.0, 60.0, 100.0, 160.0, 450.0])
    func chatEdgeMaskIsMonotonicAndMirrored(height: Double) {
        let top = AloChatEdge.top.maskStops(height: height)
        #expect(top.first?.location == 0 && top.first?.alpha == 1)
        #expect(top.last?.location == 1 && top.last?.alpha == 0)
        for (a, b) in zip(top, top.dropFirst()) {
            #expect(a.location < b.location)
            #expect(a.alpha >= b.alpha)
            #expect((0...1).contains(a.location) && (0...1).contains(a.alpha))
        }
        let bottom = AloChatEdge.bottom.maskStops(height: height)
        #expect(bottom.first?.location == 0 && bottom.first?.alpha == 0)
        #expect(bottom.last?.location == 1 && bottom.last?.alpha == 1)
        for (a, b) in zip(bottom, bottom.dropFirst()) {
            #expect(a.location < b.location && a.alpha <= b.alpha)
        }
        // The keyboard grows the constant section, never dilutes the 60 pt fade.
        if height > 60 {
            #expect(abs(bottom[bottom.count - 2].location * height - 60) < 0.001)
        }
    }

    @MainActor @Test func modalBackdropKeepsOneBlurAndUsesBlackWithoutHitTargets() {
        let view = AloChatBackdropView(frame: CGRect(x: 0, y: 0, width: 402, height: 160))
        // Modal scrims retain their separate blur. Testing this modal helper
        // is not a visual test of a lightweight chat scroll edge.
        view.configure(darkness: 0.32, opaque: false)
        view.layoutIfNeeded()
        #expect(!view.isUserInteractionEnabled && view.accessibilityElementsHidden)
        let blur = view.subviews.compactMap { $0 as? UIVisualEffectView }.first
        #expect(blur?.effect is UIBlurEffect)
        let dim = view.subviews.last
        #expect(dim?.backgroundColor == .black)
        #expect(abs((dim?.alpha ?? 0) - 0.32) < 0.0001)
        #expect(view.layer.mask == nil)
        for _ in 0..<100 { view.configure(darkness: 0.32, opaque: false) }
        #expect(view.subviews.count == 2 && view.subviews.first === blur)
        view.configure(darkness: 0.32, opaque: true)
        view.layoutIfNeeded()
        #expect(blur?.effect == nil && dim?.alpha == 1)
        #expect(view.subviews.first === blur)
        view.configure(darkness: 0.32, opaque: false)
        #expect(view.layer.mask == nil && blur?.effect is UIBlurEffect)
        #expect(dim?.backgroundColor == .black)
        #expect(abs((dim?.alpha ?? 0) - 0.32) < 0.0001)
    }

    @MainActor @Test func onlyActualScrollPanMayCoexistWithBackNavigation() {
        let scroll = UIScrollView()
        let child = UIView()
        scroll.addSubview(child)
        let scrub = UIPanGestureRecognizer()
        child.addGestureRecognizer(scrub)
        let tap = UITapGestureRecognizer()
        scroll.addGestureRecognizer(tap)
        #expect(scroll.panGestureRecognizer.isScrollPanGesture)
        #expect(!scrub.isScrollPanGesture)
        #expect(!tap.isScrollPanGesture)
    }

    @Test func swappingCallVideoKeepsOneSurfacePerTrack() {
        for preferred in [false, true] {
            let layout = AloCallVideoLayout.resolve(phase: .active, hasLocalVideo: true,
                hasRemoteVideo: true, prefersLocalPrimary: preferred)
            #expect(layout.renders(isLocal: true) && layout.renders(isLocal: false))
            #expect(layout.isPrimary(isLocal: true) == preferred)
            #expect(layout.isPrimary(isLocal: false) != preferred)
        }
        let outgoing = AloCallVideoLayout.resolve(phase: .outgoing, hasLocalVideo: true,
            hasRemoteVideo: false, prefersLocalPrimary: false)
        #expect(outgoing.renders(isLocal: true) && !outgoing.renders(isLocal: false))
        let terminal = AloCallVideoLayout.resolve(phase: .interrupted, hasLocalVideo: true,
            hasRemoteVideo: true, prefersLocalPrimary: true)
        #expect(!terminal.renders(isLocal: true) && !terminal.renders(isLocal: false))
    }
    @Test func glassFallbackRespectsOSAndAccessibility() {
        #expect(AloGlassRendering.resolve(nativeAvailable: false, reduceTransparency: false, increasedContrast: false) == .legacy)
        #expect(AloGlassRendering.resolve(nativeAvailable: true, reduceTransparency: false, increasedContrast: false) == .native)
        #expect(AloGlassRendering.resolve(nativeAvailable: true, reduceTransparency: false, increasedContrast: false, forceLegacy: true) == .legacy)
        for nativeAvailable in [false, true] {
            for forceLegacy in [false, true] {
                #expect(AloGlassRendering.resolve(nativeAvailable: nativeAvailable, reduceTransparency: true,
                                                  increasedContrast: false, forceLegacy: forceLegacy) == .opaque)
                #expect(AloGlassRendering.resolve(nativeAvailable: nativeAvailable, reduceTransparency: false,
                                                  increasedContrast: true, forceLegacy: forceLegacy) == .opaque)
            }
        }
    }

    @Test func recordingDragRequiresDeliberateDirection() {
        #expect(!AloRecordingDrag(translation: CGSize(width: -30, height: -10)).shouldCancel)
        #expect(!AloRecordingDrag(translation: CGSize(width: -100, height: 10)).shouldCancel)
        #expect(AloRecordingDrag(translation: CGSize(width: -151, height: 10)).shouldCancel)
        #expect(!AloRecordingDrag(translation: CGSize(width: -20, height: -90)).shouldLock)
        #expect(AloRecordingDrag(translation: CGSize(width: -20, height: -111)).shouldLock)
        #expect(!AloRecordingDrag(translation: CGSize(width: -90, height: -90)).shouldLock)
        let reversed = AloRecordingDrag(translation: CGSize(width: 20, height: 10))
        #expect(reversed.cancelProgress == 0 && reversed.lockProgress == 0)
        #expect(reversed.offset == .zero)
    }

    @Test func recordingReleaseResolvesDirectionAndVelocity() {
        #expect(AloRecordingDrag(translation: CGSize(width: -105, height: -10)).releaseIntent(velocity: .zero) == .cancel)
        #expect(AloRecordingDrag(translation: CGSize(width: -20, height: -65)).releaseIntent(velocity: .zero) == .lock)
        #expect(AloRecordingDrag(translation: CGSize(width: -20, height: -20)).releaseIntent(velocity: .zero) == .finish)
        #expect(AloRecordingDrag(translation: CGSize(width: -40, height: 0)).releaseIntent(velocity: CGSize(width: -450, height: 0)) == .cancel)
        #expect(AloRecordingDrag(translation: CGSize(width: 0, height: -40)).releaseIntent(velocity: CGSize(width: 0, height: -450)) == .lock)
        #expect(AloRecordingDrag(translation: CGSize(width: -70, height: -85)).releaseIntent(velocity: .zero) == .lock)
    }

    @MainActor @Test func statusMeasurementUsesRenderedFontRuns() {
        let text = "Широкий текст"
        let normal = AloRichMessageText.attributedBody(text, entities: [])
        let bold = AloRichMessageText.attributedBody(text, entities: [
            AloMessageTextEntity(type: "bold", offset: 0, length: (text as NSString).length)
        ])
        #expect(AloTextStatusLayout.lastLineWidth(bold, width: 300) > AloTextStatusLayout.lastLineWidth(normal, width: 300))
    }
    @Test func compactCountsPreserveBoundaries() {
        #expect(AloCompactCount.string(-1) == "0")
        #expect(AloCompactCount.string(999) == "999")
        #expect(AloCompactCount.string(1_000) == "1K")
        #expect(AloCompactCount.string(12_400) == "12.4K")
        #expect(AloCompactCount.string(999_999) == "999K")
        #expect(AloCompactCount.string(1_200_000) == "1.2M")
        #expect(AloCompactCount.string(1_000_000_000) == "1B")
    }
    @Test(arguments: [320.0, 375.0, 390.0, 402.0, 430.0])
    func messageAndSelectionFitPhone(width: Double) {
        let available = CGFloat(width) - 28
        let normal = AloChatMetrics.messageWidth(availableWidth: available, selecting: false)
        let selected = AloChatMetrics.messageWidth(availableWidth: available, selecting: true)
        #expect(normal + 40 + 8 <= available)
        #expect(selected + 16 + 8 + 36 <= available)
        #expect(selected > 0 && selected < normal)
    }

    @Test func reversingSwipeCancelsDismissal() {
        #expect(!AloInteractiveDismissPolicy.shouldDismiss(translation: 200, velocity: -600, width: 375))
        #expect(!AloInteractiveDismissPolicy.shouldDismiss(translation: 0, velocity: 0, width: 375))
        #expect(AloInteractiveDismissPolicy.shouldDismiss(translation: 120, velocity: 100, width: 375))
    }

    @Test func navigationSettleUsesReleaseSpeedWithoutOvershoot() {
        #expect(AloChatNavigationTiming.completionDuration(distance: 200, velocity: 200) == 0.2)
        #expect(AloChatNavigationTiming.completionDuration(distance: 50, velocity: 2000) == 0.05)
        #expect(abs(AloChatNavigationTiming.completionDuration(distance: 150, velocity: 1000) - 0.15) < 0.001)
        #expect(AloChatNavigationTiming.completionDuration(distance: 200, velocity: 0) == 0.2)
    }

    @Test func waveformUsesFullWidthWithoutInventingLevels() {
        let samples = AloVoiceWaveform.samples([0.2, 0.8, 0.4], width: 185)
        #expect(samples.count == 37)
        #expect(samples.first == 0.2 && samples.last == 0.4)
        #expect(samples.allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect(AloVoiceWaveform.samples([], width: 185).allSatisfy { $0 == 0 })
        #expect(AloVoiceWaveform.samples([.nan, .infinity], width: 185).allSatisfy { $0 == 0 })
        #expect(AloVoiceWaveform.samples([1], width: 0).isEmpty)
        let downsampled = AloVoiceWaveform.samples(Array(repeating: 0, count: 63) + [1], width: 100)
        #expect(downsampled.last == 1)
        #expect(downsampled.count * 3 + (downsampled.count - 1) * 2 <= 100)
    }

    @Test func backIntentProtectsScrollAndWorksFromRight() {
        #expect(AloChatBackIntent.accepts(x: 20, y: 2, startX: 320))
        #expect(!AloChatBackIntent.accepts(x: 10, y: 16, startX: 200))
        #expect(!AloChatBackIntent.accepts(x: -30, y: 0, startX: 200))
        #expect(!AloInteractiveDismissPolicy.shouldDismiss(translation: 4, velocity: 2000, width: 440))
        let runway = AloChatBackIntent.dismissalWidth(viewport: 440, startX: 320)
        #expect(AloInteractiveDismissPolicy.shouldDismiss(translation: 80, velocity: 0, width: runway))
        #expect(!AloInteractiveDismissPolicy.shouldDismiss(translation: 30, velocity: 0, width: runway))
    }

    @Test func rightmostRunwayStillAllowsDeliberateBackSwipe() {
        for width: CGFloat in [375, 440] {
            let runway = AloChatBackIntent.dismissalWidth(viewport: width, startX: width * 0.9)
            #expect(AloInteractiveDismissPolicy.shouldDismiss(translation: width * 0.1 - 3, velocity: 0, width: runway))
            #expect(!AloInteractiveDismissPolicy.shouldDismiss(translation: 18, velocity: 1200, width: runway))
        }
    }

    @Test func backDirectionRejectsScrollBeforeChildPansStart() {
        #expect(AloChatBackDirection.resolve(x: 2, y: 1) == .pending)
        #expect(AloChatBackDirection.resolve(x: 3, y: 1) == .accepted)
        #expect(AloChatBackDirection.resolve(x: 8, y: 3) == .accepted)
        #expect(AloChatBackDirection.resolve(x: 8, y: 12) == .rejected)
        #expect(AloChatBackDirection.resolve(x: -8, y: 1) == .rejected)
        #expect(AloChatBackDirection.resolve(x: 13, y: 12) == .accepted)
    }

    @Test func leftwardSwipeNeverNavigatesBack() {
        #expect(AloChatBackDirection.resolve(x: -8, y: 1) == .rejected)
        #expect(AloChatBackDirection.resolve(x: -3, y: 12) == .rejected)
        #expect(AloChatBackDirection.resolve(x: -1, y: 0) == .pending)
        #expect(!AloInteractiveDismissPolicy.shouldDismiss(translation: 20, velocity: 1500, width: 440))
        #expect(!AloInteractiveDismissPolicy.shouldDismiss(translation: 150, velocity: -600, width: 440))
    }

    @Test func elasticFeedbackIsLocalSizeAwareAndBounded() {
        let resting = AloElasticTransform.resolve(size: CGSize(width: 44, height: 44), translation: nil)
        #expect(resting.scale == CGSize(width: 1, height: 1))
        #expect(resting.offset == .zero)
        let field = AloElasticTransform.resolve(size: CGSize(width: 300, height: 44), translation: .zero)
        #expect(field.scale.width > 1 && field.scale.width < 1.1)
        #expect(field.scale.width == field.scale.height)
        let stretch = AloElasticTransform.resolve(size: CGSize(width: 300, height: 44),
            translation: CGSize(width: 1000, height: 0))
        #expect(stretch.scale.width > field.scale.width)
        #expect(stretch.scale.height < field.scale.height)
        #expect(abs(stretch.offset.width) < 24)
    }

    @Test func callDismissalRejectsTinyFlingAndReversal() {
        #expect(!AloCallMinimizePolicy.shouldMinimize(translation: 6, predictedTranslation: 300, viewportHeight: 900))
        #expect(!AloCallMinimizePolicy.shouldMinimize(translation: 450, predictedTranslation: 200, viewportHeight: 900))
        #expect(!AloCallMinimizePolicy.shouldMinimize(translation: 90, predictedTranslation: -200, viewportHeight: 900))
        #expect(AloCallMinimizePolicy.shouldMinimize(translation: 420, predictedTranslation: 430, viewportHeight: 900))
    }
}
