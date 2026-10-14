import Foundation
import Testing
import Vision
@testable import AloiOS

private let qrTestID = "testQRRequest_0123456789abcdefABCD"
private let qrTestSecret = "testQRSecret_0123456789abcdefghijklmnopqrstuvwxyz"
private let qrTestPayload = "alo://login/qr/\(qrTestID)/\(qrTestSecret)"
private func qrRequest(expires: Date = Date().addingTimeInterval(120)) -> AloQRCodeLoginRequest {
    let date = ISO8601DateFormatter()
    date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return AloQRCodeLoginRequest(["requestId": qrTestID, "qrPayload": qrTestPayload, "expiresAt": date.string(from: expires)])
}
private func qrStatus(_ value: String) -> AloQRCodeLoginStatus { AloQRCodeLoginStatus(["status": value]) }

struct AloQRCodePayloadTests {
    @Test func canonicalServerPayloadAndExplicitLegacyFormatsDecode() throws {
        let payload = try #require(AloQRCodeLoginPayload(requestID: qrTestID, rawPayload: qrTestPayload))
        #expect(payload.requestID == qrTestID && payload.secret == qrTestSecret)
        #expect(AloQRCodeLoginPayload(rawPayload: "alo://login/qr?requestId=\(qrTestID)&secret=\(qrTestSecret)") == payload)
        let json = try JSONSerialization.data(withJSONObject: ["requestId": qrTestID, "secret": qrTestSecret])
        #expect(AloQRCodeLoginPayload(rawPayload: String(decoding: json, as: UTF8.self)) == payload)
        #expect(AloQRCodeLoginPayload(requestID: "another-request-id", rawPayload: qrTestPayload) == nil)
    }

    @Test(arguments: [
        "https://attacker.invalid/qr?requestId=\(qrTestID)&secret=\(qrTestSecret)",
        "other://login/qr/\(qrTestID)/\(qrTestSecret)",
        "alo://other/qr/\(qrTestID)/\(qrTestSecret)",
        "alo://user:password@login/qr/\(qrTestID)/\(qrTestSecret)",
        "alo://login:3000/qr/\(qrTestID)/\(qrTestSecret)",
        qrTestPayload + "/extra", qrTestPayload + "/", qrTestPayload + "?extra=1", qrTestPayload + "#fragment",
        "alo://login/qr/short/short", "alo://login/qr/../\(qrTestSecret)",
        "alo://login/qr/\(qrTestID)/%2F\(qrTestSecret)",
        "alo://login/qr?requestId=\(qrTestID)&secret=\(qrTestSecret)&secret=another",
        "alo://login/qr?requestId=\(qrTestID)&secret=\(qrTestSecret)&extra=1",
        "", "not a QR", String(repeating: "x", count: 1_025)
    ])
    func malformedAndForeignCodesAreRejected(_ raw: String) {
        #expect(AloQRCodeLoginPayload(rawPayload: raw) == nil)
    }

    @Test @MainActor func generatedQRIsActuallyReadableByVision() throws {
        let image = try #require(AloQRCodeImage.makeImage(payload: qrTestPayload)?.cgImage)
        let detect = VNDetectBarcodesRequest()
#if targetEnvironment(simulator)
        // The simulated runtime cannot initialize the newer ML inference
        // context. Revision 1 still verifies the generated static QR pixels.
        detect.revision = VNDetectBarcodesRequestRevision1
        detect.usesCPUOnly = true
#endif
        detect.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([detect])
        #expect(detect.results?.first?.payloadStringValue == qrTestPayload)
    }

    @Test func consumedIsTerminalAndCompletionAliasesDoNotTriggerAnotherLogin() {
        #expect(qrStatus("consumed").isTerminalFailure)
        #expect(!qrStatus("consumed").isApproved)
        #expect(!qrStatus("completed").isApproved)
        #expect(qrStatus("approved").isApproved)
    }
}

@Suite(.serialized) @MainActor
struct AloQRCodeFlowTests {
    @Test func pendingThenApprovedCompletesOnlyOnce() async {
        let flow = AloQRCodeLoginFlow()
        var polls = 0
        var completions = 0
        await flow.run(start: { qrRequest() }, status: { payload in
            #expect(payload.requestID == qrTestID && payload.secret == qrTestSecret)
            guard case .waiting = flow.state else { Issue.record("Polling must show the QR waiting state"); return qrStatus("rejected") }
            polls += 1
            return qrStatus(polls == 1 ? "pending" : "approved")
        }, complete: { _ in
            #expect(flow.state == .completing)
            completions += 1
        }, pause: {})
        #expect(polls == 2 && completions == 1)
        #expect(flow.state == .signedIn)
    }

    @Test func expiryFailsWithoutPollingAndRetryCanSucceed() async {
        let flow = AloQRCodeLoginFlow()
        var calls = 0
        await flow.run(start: { qrRequest(expires: .distantPast) }, status: { _ in
            calls += 1; return qrStatus("approved")
        }, complete: { _ in calls += 1 })
        #expect(calls == 0)
        #expect(flow.state == .failed(AloQRCodeLoginFailure.message(for: AloQRCodeLoginFailure.expired)))
        await flow.run(start: { qrRequest() }, status: { _ in qrStatus("approved") }, complete: { _ in calls += 1 })
        #expect(calls == 1 && flow.state == .signedIn)
    }

    @Test(arguments: ["consumed", "expired", "rejected", "unknown", "completed"])
    func terminalAndUnknownStatusesNeverConsumeAgain(_ status: String) async {
        let flow = AloQRCodeLoginFlow()
        var completed = false
        await flow.run(start: { qrRequest() }, status: { _ in qrStatus(status) }, complete: { _ in completed = true })
        #expect(!completed)
        guard case .failed = flow.state else { Issue.record("Must show a retryable error, not an endless spinner"); return }
    }

    @Test func expired404IsNotMistakenForOldServerAndNetworkFailureHasRecovery() async {
        let flow = AloQRCodeLoginFlow()
        await flow.run(start: { qrRequest() }, status: { _ in
            throw AloAPIError(status: 404, code: "QR_LOGIN_EXPIRED", message: "expired", payload: [:])
        }, complete: { _ in Issue.record("An expired QR must not complete") })
        #expect(flow.state == .failed(AloQRCodeLoginFailure.message(for: AloQRCodeLoginFailure.expired)))
        await flow.run(start: { throw URLError(.notConnectedToInternet) }, status: { _ in qrStatus("pending") }, complete: { _ in })
        guard case .failed(let message) = flow.state else { Issue.record("Network error must be visible"); return }
        #expect(message.contains("соединение"))
    }

    @Test func closingSheetBeforeLateApprovalDoesNotCompleteLogin() async {
        let flow = AloQRCodeLoginFlow()
        var pending: CheckedContinuation<AloQRCodeLoginStatus, Never>?
        var completed = false
        let task = Task {
            await flow.run(start: { qrRequest() }, status: { _ in
                await withCheckedContinuation { pending = $0 }
            }, complete: { _ in completed = true })
        }
        while pending == nil { await Task.yield() }
        task.cancel()
        pending?.resume(returning: qrStatus("approved"))
        await task.value
        #expect(!completed)
        guard case .waiting = flow.state else { Issue.record("Cancelled flow must not mutate visible state"); return }
    }

    @Test func scanningRequiresExplicitConfirmationAndCannotApproveTwice() async throws {
        let flow = AloQRCodeApprovalFlow()
        var calls = 0
        await flow.confirm { _ in calls += 1 }
        #expect(calls == 0)
        flow.scanned(qrTestPayload)
        #expect(flow.state == .confirming(try #require(AloQRCodeLoginPayload(rawPayload: qrTestPayload))))
        flow.scannerFailed("Late camera callback after a successful scan")
        #expect(flow.state == .confirming(try #require(AloQRCodeLoginPayload(rawPayload: qrTestPayload))))
        #expect(calls == 0)
        await flow.confirm { _ in calls += 1 }
        await flow.confirm { _ in calls += 1 }
        #expect(calls == 1 && flow.state == .approved)
    }

    @Test func invalidScanAndExpiredApprovalAllowAnotherScan() async {
        let flow = AloQRCodeApprovalFlow()
        flow.scanned("not a QR")
        guard case .failed = flow.state else { Issue.record("Invalid scan must show error"); return }
        flow.reset()
        flow.scanned(qrTestPayload)
        await flow.confirm { _ in
            throw AloAPIError(status: 409, code: "QR_LOGIN_NOT_PENDING", message: "not pending", payload: [:])
        }
        #expect(flow.state == .failed(AloQRCodeLoginFailure.message(for: AloQRCodeLoginFailure.expired)))
        flow.reset()
        flow.scanned(qrTestPayload)
        await flow.confirm { _ in }
        #expect(flow.state == .approved)
    }
}

private final class QRContractURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    static func install(_ value: ((URLRequest) throws -> (Int, [String: Any]))?) {
        lock.lock(); defer { lock.unlock() }; handler = value
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler, let url = request.url else { throw URLError(.badURL) }
            let reply = try handler(request)
            guard let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: "HTTP/1.1",
                                                  headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: reply.1))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody {
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let stream = try #require(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite(.serialized) @MainActor
struct AloQRCodeAPIContractTests {
    @Test func nativeClientUsesTheSameStartStatusApproveCompleteContractAsServer() async throws {
        var routes = [String]()
        QRContractURLProtocol.install { request in
            let route = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
            routes.append(route)
            #expect(!(request.value(forHTTPHeaderField: "X-Alo-Device-ID") ?? "").isEmpty)
            switch route {
            case "POST /api/auth/qr-login/start":
                #expect(!(try QRContractURLProtocol.jsonBody(request)["deviceId"] as? String ?? "").isEmpty)
                return (200, ["requestId": qrTestID, "qrPayload": qrTestPayload,
                              "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(120))])
            case "GET /api/auth/qr-login/\(qrTestID)":
                let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
                #expect(query?.first(where: { $0.name == "secret" })?.value == qrTestSecret)
                return (200, ["status": "approved"])
            case "POST /api/auth/qr-login/\(qrTestID)/approve", "POST /api/auth/qr-login/\(qrTestID)/complete":
                #expect(try QRContractURLProtocol.jsonBody(request)["secret"] as? String == qrTestSecret)
                return (200, ["ok": true])
            default: Issue.record("Unexpected QR route"); return (500, [:])
            }
        }
        defer { QRContractURLProtocol.install(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QRContractURLProtocol.self]
        let api = AloAPIClient(baseURLs: [URL(string: "http://qr-contract-test.invalid/")!], configuration: configuration)
        let request = try await api.startQRCodeLogin()
        let payload = try #require(AloQRCodeLoginPayload(requestID: request.requestID, rawPayload: request.payload))
        try await api.approveQRCodeLogin(requestID: payload.requestID, secret: payload.secret)
        #expect(try await api.loadQRCodeLoginStatus(requestID: payload.requestID, secret: payload.secret).isApproved)
        try await api.completeQRCodeLogin(requestID: payload.requestID, secret: payload.secret)
        #expect(routes == ["POST /api/auth/qr-login/start", "POST /api/auth/qr-login/\(qrTestID)/approve",
                           "GET /api/auth/qr-login/\(qrTestID)", "POST /api/auth/qr-login/\(qrTestID)/complete"])
    }
}

private let linkTestPayload = "alo://login/link/\(qrTestID)/\(qrTestSecret)"
private func linkRequest() -> AloQRCodeLoginRequest {
    let date = ISO8601DateFormatter()
    date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return AloQRCodeLoginRequest(["requestId": qrTestID, "qrPayload": linkTestPayload,
                                  "expiresAt": date.string(from: Date().addingTimeInterval(120))])
}

struct AloDeviceLinkTests {
    @Test func linkPayloadDecodesAndIsDistinctFromSignInPayload() throws {
        let payload = try #require(AloQRCodeLoginPayload(deviceLinkPayload: linkTestPayload))
        #expect(payload.requestID == qrTestID && payload.secret == qrTestSecret)
        // A sign-in QR is never accepted as a device link, and the other way round.
        #expect(AloQRCodeLoginPayload(deviceLinkPayload: qrTestPayload) == nil)
        #expect(AloQRCodeLoginPayload(rawPayload: linkTestPayload) == nil)
    }

    @Test(arguments: [
        "https://attacker.invalid/link/\(qrTestID)/\(qrTestSecret)",
        "alo://other/link/\(qrTestID)/\(qrTestSecret)",
        linkTestPayload + "/extra", linkTestPayload + "?x=1", linkTestPayload + "#f",
        "alo://login/link/short/short", "", "not a QR"
    ])
    func malformedLinkCodesAreRejected(_ raw: String) {
        #expect(AloQRCodeLoginPayload(deviceLinkPayload: raw) == nil)
    }

    @MainActor @Test func scanClaimsWaitsForOwnerThenSignsIn() async {
        let flow = AloDeviceLinkScanFlow()
        var polls = 0
        var claimed = false
        var completed = false
        await flow.run(raw: linkTestPayload,
            claim: { _ in claimed = true },
            status: { _ in polls += 1; return qrStatus(polls < 3 ? "pending" : "approved") },
            complete: { _ in completed = true },
            pause: {})
        #expect(claimed && completed && polls == 3)
        #expect(flow.state == .signedIn)
    }

    @MainActor @Test func scanRejectsForeignCodeWithoutCallingTheServer() async {
        let flow = AloDeviceLinkScanFlow()
        var called = false
        await flow.run(raw: qrTestPayload, claim: { _ in called = true },
                       status: { _ in qrStatus("pending") }, complete: { _ in called = true }, pause: {})
        #expect(!called)
        guard case .failed = flow.state else { Issue.record("expected a failure"); return }
    }

    @MainActor @Test func showNoticesScanThenOwnerApproves() async {
        let flow = AloDeviceLinkShowFlow()
        var polls = 0
        let runTask = Task { @MainActor in
            await flow.run(start: { linkRequest() },
                           status: { _ in polls += 1; return AloQRCodeLoginStatus(["status": "pending", "claimed": polls >= 2]) },
                           pause: { try await Task.sleep(nanoseconds: 5_000_000) })
        }
        for _ in 0..<200 { if case .confirming = flow.state { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        guard case .confirming = flow.state else { Issue.record("expected confirming"); runTask.cancel(); return }
        var approved = false
        await flow.approve { _ in approved = true }
        #expect(approved && flow.state == .approved)
        await runTask.value
    }
}
