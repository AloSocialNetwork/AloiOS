import XCTest
@testable import AloiOS

/// Expected frames are worked out by hand from Telegram's `chatMessageBubbleMosaicLayout`
/// (commit 6e370e0) for the compact 300 × 380 media box and 1 pt gaps.
final class AloChatMosaicTests: XCTestCase {
    private func dims(_ width: Double, _ height: Double) -> AloMediaDimensions? {
        AloMediaDimensions(width: width, height: height)
    }

    func testTwoPortraitPhotosSitSideBySide() {
        let result = AloChatMosaic.layout(dimensions: [dims(1080, 1440), dims(1080, 1440)], availableWidth: 351)
        // "nn": unequal branch. second = floor(min(149.5, round(299 / 0.75 / (2 / 0.75)))) = 149.
        XCTAssertEqual(result.frames[0], CGRect(x: 0, y: 0, width: 150, height: 199))
        XCTAssertEqual(result.frames[1], CGRect(x: 151, y: 0, width: 149, height: 199))
        XCTAssertEqual(result.size, CGSize(width: 300, height: 199))
    }

    func testTwoLandscapePhotosStack() {
        let result = AloChatMosaic.layout(dimensions: [dims(1920, 1080), dims(1920, 1080)], availableWidth: 351)
        // "ww", average 1.78 > 1.4 × 300/380: stacked, height = floor(min(300 / 1.78, 189.5)) = 168.
        XCTAssertEqual(result.frames[0], CGRect(x: 0, y: 0, width: 300, height: 168))
        XCTAssertEqual(result.frames[1], CGRect(x: 0, y: 169, width: 300, height: 168))
        XCTAssertEqual(result.size, CGSize(width: 300, height: 337))
    }

    func testTwoSquaresShareTheWidth() {
        let result = AloChatMosaic.layout(dimensions: [dims(1000, 1000), dims(1000, 1000)], availableWidth: 351)
        XCTAssertEqual(result.frames[0], CGRect(x: 0, y: 0, width: 149.5, height: 149))
        XCTAssertEqual(result.frames[1], CGRect(x: 150.5, y: 0, width: 149.5, height: 149))
    }

    func testThreeWithPortraitFirstUseALeftColumn() {
        let result = AloChatMosaic.layout(dimensions: [dims(1080, 1920), dims(1000, 1000), dims(1000, 1000)],
                                          availableWidth: 351)
        // third = min(189.5, round(1 × 299 / 2)) = 150 (149.5 rounds up); second = 380 − 150 − 1 = 229.
        // right = max(68, min(149.5, round(min(150, 229)))) = 149.5; left = round(min(213.75, 149.5)) = 150.
        XCTAssertEqual(result.frames[0], CGRect(x: 0, y: 0, width: 150, height: 380))
        XCTAssertEqual(result.frames[1], CGRect(x: 151, y: 0, width: 149.5, height: 229))
        XCTAssertEqual(result.frames[2], CGRect(x: 151, y: 230, width: 149.5, height: 150))
    }

    func testFourWithWideFirstPutThreeBelow() {
        let result = AloChatMosaic.layout(dimensions: [dims(1920, 1080), dims(1000, 1000), dims(1000, 1000), dims(1000, 1000)],
                                          availableWidth: 351)
        // h0 = round(min(168.75, 250.14)) = 169; h = round(298 / 3) = 99.
        XCTAssertEqual(result.frames[0].height, 169)
        XCTAssertEqual(result.frames[1].minY, 170)
        XCTAssertEqual(result.frames[1].height, 99)
        XCTAssertEqual(result.frames[3].maxX, 300, accuracy: 0.01)
    }

    func testFiveSquaresUseTelegramsRowSearch() {
        let result = AloChatMosaic.layout(dimensions: Array(repeating: dims(1000, 1000), count: 5), availableWidth: 351)
        // Rows of 2 then 3 are closest to 4/3 of the width (diff 151); heights are ceil(149.5) and ceil(99.3).
        XCTAssertEqual(result.frames.count, 5)
        XCTAssertEqual(result.frames[0].height, 150)
        XCTAssertEqual(result.frames[2].minY, 151)
        XCTAssertEqual(result.frames[2].height, 100)
        XCTAssertEqual(result.frames[1].maxX, result.frames[4].maxX, "rows end on one right edge")
        XCTAssertEqual(result.size.height, 251)
    }

    func testTenItemsAllGetATileAndAPanoramaUsesTheSearchToo() {
        let ten = AloChatMosaic.layout(dimensions: (0..<10).map { dims($0.isMultiple(of: 2) ? 1080 : 1920, 1440) },
                                       availableWidth: 351)
        XCTAssertEqual(ten.frames.count, 10)
        XCTAssertTrue(ten.frames.allSatisfy { $0.width > 0 && $0.height > 0 })
        let panorama = AloChatMosaic.layout(dimensions: [dims(4000, 1000), dims(1000, 1000)], availableWidth: 351)
        XCTAssertEqual(panorama.frames.count, 2)
        XCTAssertLessThanOrEqual(panorama.size.width, 302)
    }

    func testNarrowScreenShrinksTheBox() {
        let result = AloChatMosaic.layout(dimensions: [dims(1080, 1440), dims(1080, 1440)], availableWidth: 240)
        XCTAssertLessThanOrEqual(result.size.width, 240)
    }

    func testUnknownSizeIsSquareNotALandscapeStrip() {
        let size = AloChatMediaSizing.single(dimensions: nil, video: false, availableWidth: 351)
        XCTAssertEqual(size, CGSize(width: 300, height: 300))
    }

    func testRegistryRemembersSizesAcrossInstancesWithoutStoringTheKey() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sizes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = AloMediaSizeRegistry(fileURL: file)
        first.record(width: 1080, height: 1440, forKey: "/uploads/chat/secret-name.jpg")
        XCTAssertEqual(first.dimensions(forKey: "/uploads/chat/secret-name.jpg"), dims(1080, 1440))
        // The write is batched; wait for it, then read the file from a fresh instance.
        let written = expectation(description: "saved")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { written.fulfill() }
        wait(for: [written], timeout: 5)
        first.flush()
        let second = AloMediaSizeRegistry(fileURL: file)
        XCTAssertEqual(second.dimensions(forKey: "/uploads/chat/secret-name.jpg"), dims(1080, 1440))
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains("secret-name"), "only hashes of the keys are stored")
    }
}
