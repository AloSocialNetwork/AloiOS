import AVFoundation
import Testing
@testable import AloiOS

struct AloCircleFramingTests {
    @Test(arguments: [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 720, height: 720)])
    func centeredSquareIsFilled(_ size: CGSize) {
        let target = CGRect(origin: .zero, size: size).applying(AloCircleFraming.transform(size: size, orientation: .identity))
        #expect(abs(target.midX - 200) < 0.01)
        #expect(abs(target.midY - 200) < 0.01)
        #expect(target.width >= 399.99 && target.height >= 399.99)
        #expect(abs(min(target.width, target.height) - 400) < 0.01)
    }

    @Test func mirroredPortraitRemainsCentered() {
        let size = CGSize(width: 1920, height: 1080)
        let orientation = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1080, ty: 1920)
        let target = CGRect(origin: .zero, size: size).applying(AloCircleFraming.transform(size: size, orientation: orientation))
        #expect(abs(target.midX - 200) < 0.01)
        #expect(abs(target.midY - 200) < 0.01)
        #expect(abs(target.width - 400) < 0.01)
    }

    @Test @MainActor func exportedVideoIsSquareAndKeepsDuration() async throws {
        let sample = await AloMessengerSampleMedia.make()
        let source = try #require(sample.video)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("alo-square-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await AloCircleVideoExport.square(source, output: output)
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let dimensions = try await track.load(.naturalSize)
        #expect(dimensions == CGSize(width: 400, height: 400))
        let originalDuration = try await AVURLAsset(url: source).load(.duration).seconds
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - originalDuration) < 0.1)
    }
}
