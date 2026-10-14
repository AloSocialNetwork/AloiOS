import XCTest
@testable import AloiOS

final class AloPunycodeTests: XCTestCase {
    func testAppDomainIsShownInCyrillic() {
        XCTAssertEqual(AloPunycode.displayHost("xn--80awj.online"), "ало.online")
    }

    func testOrdinaryAndMixedHostsAreKept() {
        XCTAssertEqual(AloPunycode.displayHost("example.com"), "example.com")
        XCTAssertEqual(AloPunycode.displayHost("api.xn--80awj.online"), "api.ало.online")
        XCTAssertEqual(AloPunycode.displayHost("xn--d1acpjx3f.xn--p1ai"), "яндекс.рф")
    }

    func testBrokenLabelFallsBackToItsDNSForm() {
        XCTAssertEqual(AloPunycode.displayHost("xn--!!.online"), "xn--!!.online")
    }
}
