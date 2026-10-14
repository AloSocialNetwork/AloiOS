import Testing
import CoreGraphics
@testable import AloiOS

@Suite("Chat context geometry and supported reaction search")
struct AloChatContextTests {
    @Test(arguments: [CGSize(width: 375, height: 580), CGSize(width: 402, height: 760),
                      CGSize(width: 744, height: 940), CGSize(width: 740, height: 320)])
    func layoutKeepsControlsInsideViewport(_ size: CGSize) {
        for outgoing in [false, true] {
            for expanded in [false, true] {
                let source = CGRect(x: outgoing ? size.width - 202 : 12, y: size.height - 90, width: 190, height: 420)
                let layout = AloChatContextLayout.make(size: size, source: source, previewHeight: 420,
                    menuHeight: 480, reactionHeight: expanded ? min(340, size.height * 0.4) : 46,
                    outgoing: outgoing, expanded: expanded)
                for frame in [layout.previewFrame, layout.reactionFrame] {
                    #expect(frame.minX >= 12)
                    #expect(frame.maxX <= size.width - 12)
                    #expect(frame.minY >= 12)
                    #expect(frame.maxY <= size.height - 12)
                }
                if expanded {
                    #expect(layout.menuFrame.height == 0)
                } else {
                    #expect(layout.menuFrame.width <= 250)
                    #expect(layout.menuFrame.maxY <= size.height - 12)
                    #expect(layout.menuFrame.minY - layout.previewFrame.maxY == 8)
                }
                #expect(layout.previewFrame.minY - layout.reactionFrame.maxY == 8)
                #expect(outgoing ? layout.previewFrame.maxX == source.maxX : layout.previewFrame.minX == source.minX)
            }
        }
    }

    @Test func supportedReactionSearchDoesNotInventPacks() {
        #expect(AloReactionCatalog.search(" огонь ").map(\.emoji) == ["❤️‍🔥", "🔥"])
        #expect(AloReactionCatalog.search("HEART").contains { $0.emoji == "❤️" })
        #expect(AloReactionCatalog.search("😭").map(\.emoji) == ["😭"])
        #expect(AloReactionCatalog.search("несуществующий набор").isEmpty)
        #expect(Set(AloReactionCatalog.choices.map(\.emoji)).count == AloReactionCatalog.choices.count)
    }
}
