import XCTest
import WebRTC
@testable import AloiOS

final class AloVideoRendererRegistryTests: XCTestCase {
    private final class Renderer: NSObject, RTCVideoRenderer {
        func setSize(_ size: CGSize) {}
        func renderFrame(_ frame: RTCVideoFrame?) {}
    }

    func testClosingSourcePickerKeepsCallPreviewBound() {
        let registry = AloVideoRendererRegistry()
        let call = Renderer()
        let picker = Renderer()
        XCTAssertTrue(registry.insert(call))
        XCTAssertTrue(registry.insert(picker))
        XCTAssertFalse(registry.insert(call))
        XCTAssertEqual(registry.all.count, 2)
        registry.remove(picker)
        XCTAssertEqual(registry.all.count, 1)
        XCTAssertTrue((registry.all.first as AnyObject?) === call)
    }

    func testRegistryDoesNotRetainDismissedSurfaces() {
        let registry = AloVideoRendererRegistry()
        autoreleasepool {
            let renderer = Renderer()
            registry.insert(renderer)
            XCTAssertEqual(registry.all.count, 1)
        }
        XCTAssertTrue(registry.all.isEmpty)
    }
}
