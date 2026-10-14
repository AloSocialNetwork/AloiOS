import UIKit
import XCTest
@testable import AloiOS

@MainActor
final class AloAvatarCropTests: XCTestCase {
    /// 200×100: red left half, blue right half, drawn at scale 1.
    private func halves() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.blue.setFill(); context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
    }

    private func centreColour(_ data: Data) throws -> (red: CGFloat, blue: CGFloat, size: CGSize) {
        let image = try XCTUnwrap(UIImage(data: data))
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2,
                                    width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[2]) / 255, CGSize(width: cg.width, height: cg.height))
    }

    func testCropKeepsOnlyTheSquareUnderTheCircle() throws {
        let data = try XCTUnwrap(AloAvatarImage.jpeg(cropping: halves(), to: CGRect(x: 100, y: 0, width: 100, height: 100)))
        let sample = try centreColour(data)
        XCTAssertEqual(sample.size, CGSize(width: 100, height: 100), "never upscales past the source pixels")
        XCTAssertGreaterThan(sample.blue, 0.8)
        XCTAssertLessThan(sample.red, 0.2)
    }

    func testCropperStartsCentredAndFillingTheCircle() throws {
        let view = AloAvatarCropUIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.image = halves()
        view.layoutIfNeeded()
        let rect = view.cropRectInImage
        // A wide photo fills the circle with its full height, centred horizontally.
        XCTAssertEqual(rect.height, 100, accuracy: 0.5)
        XCTAssertEqual(rect.width, 100, accuracy: 0.5)
        XCTAssertEqual(rect.midX, 100, accuracy: 0.5)
        XCTAssertEqual(rect.midY, 50, accuracy: 0.5)
    }

    func testRotationTurnsLeftAQuarter() throws {
        let rotated = halves().aloRotatedCounterClockwise()
        XCTAssertEqual(rotated.size, CGSize(width: 100, height: 200))
        // Turned left, the right (blue) half ends up on top.
        let top = try XCTUnwrap(AloAvatarImage.jpeg(cropping: rotated, to: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertGreaterThan(try centreColour(top).blue, 0.8)
    }
}
