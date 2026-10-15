import SwiftUI
import XCTest
@testable import AloiOS

/// The flattened story page draws items exactly as the editor shows them: a stretched text item
/// grows around its centre and keeps its lines.
@MainActor
final class AloStoryRenderTests: XCTestCase {
    func testStretchedTextAndEmojiAreDrawnOnThePage() throws {
        let canvas = CGSize(width: 390, height: 693)
        var style = AloStoryTextStyle()
        style.plate = .solid
        style.colorIndex = 6
        var text = AloStorySticker(text: "Привет", style: style)
        text.scale = 2
        var emoji = AloStorySticker(emoji: "✨")
        emoji.scale = 1.5
        let page = AloStoryRenderedPage(background: nil, gradient: [.black, .black], drawing: nil,
                                        stickers: [text, emoji], size: canvas)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 1_080 / canvas.width
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 1_080)
        XCTAssertEqual(image.height, 1_919, accuracy: 1)

        // The blue plate sits around the text's centre (0.5, 0.4), twice the editor's 28 pt size.
        let scale = 1_080 / canvas.width
        let plateEdge = pixel(image, x: Int((canvas.width / 2 - 95) * scale), y: Int(canvas.height * 0.4 * scale))
        XCTAssertGreaterThan(plateEdge.blue, 200, "the plate reaches ~95 pt left of centre at size 2")
        let outside = pixel(image, x: Int((canvas.width / 2 - 170) * scale), y: Int(canvas.height * 0.4 * scale))
        XCTAssertLessThan(outside.blue, 40, "and stops before the page edge")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alo-story-render.png")
        try UIImage(cgImage: image).pngData()?.write(to: url)
        print("STORYRENDER", url.path)
    }

    func testTurnsSnapStraightNearRightAngles() {
        // Within 3° of a right angle it snaps; a little further it stays where it was put.
        XCTAssertEqual(AloStoryRotation.snapped(.degrees(88)).degrees, 90)
        XCTAssertEqual(AloStoryRotation.snapped(.degrees(87)).degrees, 87, accuracy: 0.001)
        XCTAssertEqual(AloStoryRotation.snapped(.degrees(-2)).degrees, 0)
        XCTAssertEqual(AloStoryRotation.snapped(.degrees(4)).degrees, 4, accuracy: 0.001)
        XCTAssertEqual(AloStoryRotation.snapped(.degrees(182)).degrees, 180)
        XCTAssertEqual(AloStoryRotation.snapped(.degrees(-268)).degrees, 90)
        XCTAssertEqual(AloStoryRotation.snapped(.degrees(40)).degrees, 40, accuracy: 0.001)
        XCTAssertEqual(AloStoryRotation.normalized(370), 10, accuracy: 0.001)
    }

    func testEveryPlateKeepsTheTextReadable() {
        for plate in AloStoryTextStyle.Plate.allCases {
            var style = AloStoryTextStyle()
            style.plate = plate
            style.colorIndex = 0
            if plate == .solid || plate == .light {
                XCTAssertEqual(style.textColor, .black, "white text on a white plate: \(plate)")
            }
            XCTAssertEqual(style.hasPlate, plate != .none)
            XCTAssertFalse(plate.title.isEmpty)
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
