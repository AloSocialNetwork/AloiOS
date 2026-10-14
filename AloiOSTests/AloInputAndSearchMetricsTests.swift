import Testing
import CoreGraphics
@testable import AloiOS

struct AloInputAndSearchMetricsTests {
    @Test func telegramRegularComposerGeometry() {
        #expect(AloInputMetrics.height == 40)
        #expect(AloInputMetrics.touchHeight == 44)
        #expect(AloInputMetrics.singleLineRadius * 2 == AloInputMetrics.height)
        #expect(AloInputMetrics.inset == 8)
        #expect(AloInputMetrics.spacing == 6)
    }

    @Test func searchUsesOneFieldAndACompleteRevealRange() {
        #expect(AloChatListSearchMetrics.fieldHeight == AloSocialMetrics.searchHeight)
        #expect(AloChatListSearchMetrics.barHeight == 54)
        #expect(AloChatListSearchMetrics.barHeight(visualHeight: 40) == 54)
        #expect(AloChatListSearchMetrics.barHeight(visualHeight: 100) == 70)
    }

    @Test(arguments: [(CGFloat(-12), CGFloat(-12)), (0, 0), (26, 0), (27, 54), (53, 54), (54, 54), (180, 180)])
    func searchSettlesWithoutChangingNormalScrolling(_ proposed: CGFloat, _ expected: CGFloat) {
        #expect(AloChatListSearchMetrics.settledOffset(proposed, revealHeight: 54) == expected)
    }
}
