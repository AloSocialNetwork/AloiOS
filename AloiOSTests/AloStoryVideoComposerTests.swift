import AVFoundation
import XCTest
@testable import AloiOS

/// Drawing and stickers on a video story are burned into a 720 × 1280 frame:
/// the overlay keeps its top-left orientation and the video fills the frame behind it.
final class AloStoryVideoComposerTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryFiles = []
        super.tearDown()
    }

    func testOverlayIsBurnedInUprightOverAFilledFrame() async throws {
        let source = try await makeSolidVideo(size: CGSize(width: 640, height: 480), red: 1, green: 0, blue: 0)
        let composed = try await AloStoryVideoComposer.compose(videoAt: source, overlay: makeOverlay(),
                                                               renderSize: CGSize(width: 720, height: 1_280))
        temporaryFiles.append(composed)

        let asset = AVURLAsset(url: composed)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        XCTAssertEqual(abs(size.width), 720)
        XCTAssertEqual(abs(size.height), 1_280)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let corner = pixel(frame, x: 60, y: 60)
        XCTAssertGreaterThan(corner.blue, 180, "the overlay square drawn top-left stays top-left")
        XCTAssertLessThan(corner.red, 80)
        let middle = pixel(frame, x: 360, y: 640)
        XCTAssertGreaterThan(middle.red, 180, "the landscape video fills the portrait frame behind the overlay")
        let bottom = pixel(frame, x: 60, y: 1_220)
        XCTAssertGreaterThan(bottom.red, 180, "no overlay where nothing was drawn, no letterbox bars")
    }

    func testPortraitRecordingIsComposedUpright() async throws {
        // How the iPhone camera stores a portrait clip: a landscape buffer plus a 90° transform.
        // The buffer's left half is green, so upright the top half must be green.
        let natural = CGSize(width: 640, height: 480)
        let source = try await makeSolidVideo(size: natural, red: 1, green: 0, blue: 0, greenLeftHalf: true,
                                              transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: natural.height, ty: 0))
        let composed = try await AloStoryVideoComposer.compose(videoAt: source, overlay: makeOverlay(),
                                                               renderSize: CGSize(width: 720, height: 1_280))
        temporaryFiles.append(composed)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: composed))
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        XCTAssertEqual(frame.width, 720)
        XCTAssertEqual(frame.height, 1_280)
        let top = pixel(frame, x: 200, y: 300)
        let bottom = pixel(frame, x: 200, y: 1_000)
        XCTAssertGreaterThan(top.green, 180, "top half comes from the buffer's left half")
        XCTAssertLessThan(top.red, 80)
        XCTAssertGreaterThan(bottom.red, 180)
        XCTAssertLessThan(bottom.green, 80)
    }

    func testComposedVideoStaysPortraitAfterImport() async throws {
        let source = try await makeSolidVideo(size: CGSize(width: 480, height: 640), red: 0, green: 1, blue: 0)
        let composed = try await AloStoryVideoComposer.compose(videoAt: source, overlay: makeOverlay(),
                                                               renderSize: CGSize(width: 720, height: 1_280))
        temporaryFiles.append(composed)
        let attachment = try await AloFeedMediaImport.prepare(source: composed, video: true)
        defer { AloDraftAttachmentStore.discard(attachment) }
        let dimensions = try XCTUnwrap(attachment.mediaDimensions)
        XCTAssertEqual(dimensions.width / dimensions.height, 720.0 / 1_280.0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(dimensions.height, 1_000, "not squeezed into a landscape preset box")
    }

    // MARK: Fixtures

    private func makeOverlay() -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 720, height: 1_280), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }.cgImage!
    }

    private func makeSolidVideo(size: CGSize, red: CGFloat, green: CGFloat, blue: CGFloat,
                                greenLeftHalf: Bool = false, transform: CGAffineTransform = .identity) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alo-test-\(UUID().uuidString).mp4")
        temporaryFiles.append(url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        input.transform = transform
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            let buffer = try XCTUnwrap(makeBuffer(size: size, red: red, green: green, blue: blue,
                                                  greenLeftHalf: greenLeftHalf, pool: adaptor.pixelBufferPool))
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func makeBuffer(size: CGSize, red: CGFloat, green: CGFloat, blue: CGFloat,
                            greenLeftHalf: Bool, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context?.fill(CGRect(origin: .zero, size: size))
        if greenLeftHalf {
            context?.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
            context?.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        }
        return buffer
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Shift so that the requested pixel (top-left origin) lands on the single output pixel.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
