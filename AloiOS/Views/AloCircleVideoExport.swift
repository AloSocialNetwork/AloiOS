import AVFoundation

/// The same centered aspect-fill crop used by the circular camera preview.
/// Export a square, not a portrait movie that each receiving client crops differently.
enum AloCircleFraming {
    static func transform(size: CGSize, orientation: CGAffineTransform, side: CGFloat = 400) -> CGAffineTransform {
        let upright = CGRect(origin: .zero, size: size).applying(orientation)
        guard upright.width > 0, upright.height > 0 else { return orientation }
        let scale = side / min(upright.width, upright.height)
        return orientation
            .concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (side - upright.width * scale) / 2,
                                           y: (side - upright.height * scale) / 2))
    }
}

enum AloCircleVideoExport {
    @discardableResult static func square(_ input: URL, output: URL) async throws -> Double {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.unavailable }
        let size = try await track.load(.naturalSize)
        let orientation = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(AloCircleFraming.transform(size: size, orientation: orientation), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: 400, height: 400)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        exporter.videoComposition = composition
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: output, as: .mp4)
        return duration.seconds
    }

    private enum ExportError: Error { case unavailable }
}
