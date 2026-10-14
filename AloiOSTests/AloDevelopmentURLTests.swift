import Testing
@testable import AloiOS

struct AloDevelopmentURLTests {
    @Test func acceptsHostAndExplicitPortWithoutDuplicatingIt() {
        #expect(AloServerConfiguration.developmentURL(from: "192.168.0.23")?.absoluteString == "http://192.168.0.23:3000/")
        #expect(AloServerConfiguration.developmentURL(from: "192.168.1.40:3000")?.absoluteString == "http://192.168.1.40:3000/")
        #expect(AloServerConfiguration.developmentURL(from: " http://localhost:8080/ ")?.port == 8080)
        #expect(AloServerConfiguration.developmentURL(from: "https://example.test")?.absoluteString == "https://example.test/")
        #expect(AloServerConfiguration.developmentURL(from: "[::1]:3000")?.port == 3000)
    }

    @Test func rejectsMalformedDevelopmentAddresses() {
        for address in ["", "192.168.1.40:3000:3000", "host:99999", "host:0", "file:///tmp/server", "http://user:pass@host", "http://bad host", "http://host?token=x"] {
            #expect(AloServerConfiguration.developmentURL(from: address) == nil, "\(address)")
        }
    }
}
