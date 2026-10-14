#if DEBUG
import Foundation
import SwiftUI

/// Offline UI fixture: every request is intercepted, no account is created,
/// no cookie is issued, and neither the camera nor the user's server is used.
struct AloQRCodeDesignFixture: View {
    @StateObject private var app: AloAppModel
    @StateObject private var approval = AloQRCodeApprovalFlow()
    @State private var presented = true
    private let scenario = UserDefaults.standard.string(forKey: "ALO_UI_QR_SCENARIO") ?? "waiting"

    init() {
        AloQRFixtureProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AloQRFixtureProtocol.self]
        _app = StateObject(wrappedValue: AloAppModel(api: AloAPIClient(
            baseURLs: [URL(string: "http://qr-ui-fixture.invalid/")!], configuration: configuration)))
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Изолированный тест QR-входа").font(.headline)
            Button("Открыть QR-вход") { presented = true }
                .accessibilityIdentifier("alo.qr-fixture.open")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AloTheme.background)
        .sheet(isPresented: $presented) {
            Group {
                if scenario == "approval" {
                    AloQRCodeApprovalSheet(flow: approval)
                } else {
                    AloQRCodeLoginSheet()
                }
            }
            .environment(\.dynamicTypeSize, UserDefaults.standard.bool(forKey: "ALO_UI_QR_LARGE_TEXT") ? .accessibility5 : .large)
        }
        .environmentObject(app)
        .environment(\.dynamicTypeSize, UserDefaults.standard.bool(forKey: "ALO_UI_QR_LARGE_TEXT") ? .accessibility5 : .large)
        .task {
            if scenario == "approval" { approval.scanned(AloQRFixtureProtocol.payload) }
        }
    }
}

private final class AloQRFixtureProtocol: URLProtocol {
    static let requestID = "uiQRRequest_0123456789abcdefghijklm"
    static let secret = "uiQRSecret_0123456789abcdefghijklmnopqrstuvwxyz"
    static let payload = "alo://login/qr/\(requestID)/\(secret)"
    private static let lock = NSLock()
    private static var starts = 0
    static func reset() { lock.lock(); defer { lock.unlock() }; starts = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url?.path ?? ""
        let scenario = UserDefaults.standard.string(forKey: "ALO_UI_QR_SCENARIO") ?? "waiting"
        let status: Int
        let json: [String: Any]
        if path.hasSuffix("/start") {
            Self.lock.lock(); Self.starts += 1; Self.lock.unlock()
            status = 200
            json = ["requestId": Self.requestID, "qrPayload": Self.payload,
                    "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(120))]
        } else if path.hasSuffix("/approve") {
            status = 200; json = ["ok": true]
        } else if path == "/api/auth/qr-login/\(Self.requestID)" {
            Self.lock.lock(); let firstAttempt = Self.starts == 1; Self.lock.unlock()
            if scenario == "expired", firstAttempt {
                status = 404; json = ["code": "QR_LOGIN_EXPIRED", "error": "QR-код истёк."]
            } else {
                status = 200; json = ["status": "pending"]
            }
        } else {
            status = 503; json = ["error": "Isolated QR UI test cannot create an account or session"]
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                              headerFields: ["Content-Type": "application/json"]),
              let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
