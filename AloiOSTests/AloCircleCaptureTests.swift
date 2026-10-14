import AVFoundation
import CoreVideo
import Testing
@testable import AloiOS

struct AloCircleCaptureTests {
    private func frame(at seconds: Double, red: UInt8) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 320, 480, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) {
            let bytes = address.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<480 {
                for x in 0..<320 {
                    let index = y * rowBytes + x * 4
                    bytes[index] = 20; bytes[index + 1] = 80; bytes[index + 2] = red; bytes[index + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    private func audio(at seconds: Double) throws -> CMSampleBuffer {
        let count = 4_800
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: count * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block) == noErr)
        let buffer = try #require(block)
        let tone = (0..<count).map { Int16(sin(Double($0) / 48_000 * 440 * 2 * .pi) * 3_000) }
        tone.withUnsafeBytes { bytes in
            #expect(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: buffer,
                offsetIntoDestination: 0, dataLength: bytes.count) == noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sampleSize = 2
        var sample: CMSampleBuffer?
        let audioFormat = try #require(format)
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer,
            formatDescription: audioFormat, sampleCount: count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    @Test func microphoneContinuesThroughCameraGapAndSquareExport() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("alo-camera-audio-\(UUID().uuidString).mov")
        let square = source.deletingPathExtension().appendingPathExtension("mp4")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: square)
        }
        let writer = try AloCircleSampleWriter(url: source)
        for step in 0..<10 {
            let time = Double(step) / 10
            if step < 3 || step >= 7 {
                let sample = try frame(at: time, red: step < 3 ? 220 : 30)
                var appended = false
                for _ in 0..<100 {
                    if try writer.appendVideo(sample) { appended = true; break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(appended)
            }
            try writer.appendAudio(audio(at: time))
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await withCheckedContinuation { continuation in
            writer.finish { continuation.resume(returning: $0) }
        })
        let duration = try await AloCircleVideoExport.square(source, output: square)
        #expect(duration >= 0.9)
        let asset = AVURLAsset(url: square)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 400, height: 400))
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let timeRange = try await audioTrack.load(.timeRange)
        #expect(timeRange.duration.seconds >= 0.85, "A camera gap must not terminate the microphone track")
        let draft = try AloDraftAttachmentStore.makeRecordedCircle(sourceURL: square, durationSeconds: duration)
        defer { AloDraftAttachmentStore.discard(draft) }
        #expect(draft.type == "circle" && draft.data.isEmpty && draft.encryptedSourceURL != nil)
        #expect((draft.durationSeconds ?? 0) >= 0.9)
    }

    @Test func cameraGapDoesNotFinishMovieOrResetTimeline() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alo-camera-test-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AloCircleSampleWriter(url: url)
        // Front frames, a camera-switch gap, then rear frames: same writer.
        for time in [0.0, 0.1, 0.2, 0.7, 0.8, 0.9] {
            let sample = try frame(at: time, red: time < 0.7 ? 220 : 30)
            var appended = false
            for _ in 0..<100 {
                if try writer.appendVideo(sample) { appended = true; break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(appended)
        }
        #expect(abs(writer.duration - 0.9) < 0.001)
        #expect(try !writer.appendVideo(frame(at: 0.8, red: 0)), "Reject a stale frame without ending capture")
        let completed = await withCheckedContinuation { continuation in
            writer.finish { continuation.resume(returning: $0) }
        }
        #expect(completed)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds >= 0.9)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try #require(tracks.first),
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        var timestamps: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        #expect(timestamps.count == 6)
        #expect(timestamps.contains { abs($0 - 0.7) < 0.01 }, "Switch gap must not be spliced out")
    }

    @Test func emptyCaptureReturnsFailureInsteadOfSendingEmptyCircle() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alo-empty-camera-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AloCircleSampleWriter(url: url)
        let completed = await withCheckedContinuation { continuation in
            writer.finish { continuation.resume(returning: $0) }
        }
        #expect(!completed)
    }
}
