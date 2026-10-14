import Foundation
import Combine

/// New device: scans a QR shown by a signed-in device, then waits for that device's owner to confirm.
@MainActor
final class AloDeviceLinkScanFlow: ObservableObject {
    enum State: Equatable {
        case scanning
        case claiming
        case waitingForOwner
        case completing
        case signedIn
        case failed(String)
    }

    @Published private(set) var state: State = .scanning

    func reset() { state = .scanning }

    func scannerFailed(_ message: String) {
        guard state == .scanning else { return }
        state = .failed(message)
    }

    func run(
        raw: String,
        claim: (AloQRCodeLoginPayload) async throws -> Void,
        status: (AloQRCodeLoginPayload) async throws -> AloQRCodeLoginStatus,
        complete: (AloQRCodeLoginPayload) async throws -> Void,
        now: () -> Date = Date.init,
        pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }
    ) async {
        guard state == .scanning else { return }
        guard let payload = AloQRCodeLoginPayload(deviceLinkPayload: raw) else {
            state = .failed("Это не QR-код для входа в Alo. На устройстве, где вы уже вошли, откройте «Показать QR для входа».")
            return
        }
        state = .claiming
        do {
            try await claim(payload)
            try Task.checkCancellation()
            state = .waitingForOwner
            let deadline = now().addingTimeInterval(125)
            while true {
                try Task.checkCancellation()
                guard now() < deadline else { throw AloQRCodeLoginFailure.expired }
                let result = try await status(payload)
                try Task.checkCancellation()
                if result.isApproved {
                    state = .completing
                    try await complete(payload)
                    try Task.checkCancellation()
                    state = .signedIn
                    return
                }
                if result.isTerminalFailure {
                    throw result.status == "consumed" ? AloQRCodeLoginFailure.alreadyUsed : AloQRCodeLoginFailure.expired
                }
                try await pause()
            }
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(AloQRCodeLoginFailure.message(for: error))
        }
    }
}

/// Signed-in device: shows a QR, notices the scan, and asks its owner to confirm or refuse.
@MainActor
final class AloDeviceLinkShowFlow: ObservableObject {
    enum State: Equatable {
        case loading
        case showing(AloQRCodeLoginRequest)
        case confirming(AloQRCodeLoginRequest)
        case approving
        case approved
        case denied
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    private var payload: AloQRCodeLoginPayload?

    func run(
        start: () async throws -> AloQRCodeLoginRequest,
        status: (AloQRCodeLoginPayload) async throws -> AloQRCodeLoginStatus,
        now: () -> Date = Date.init,
        pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }
    ) async {
        state = .loading
        payload = nil
        do {
            let request = try await start()
            try Task.checkCancellation()
            guard let parsed = AloQRCodeLoginPayload(deviceLinkPayload: request.payload),
                  parsed.requestID == request.requestID,
                  let expiresAt = Self.expiration(request.expiresAt) else { throw AloQRCodeLoginFailure.invalidCode }
            payload = parsed
            state = .showing(request)
            while true {
                try Task.checkCancellation()
                guard now() < expiresAt else { throw AloQRCodeLoginFailure.expired }
                switch state {
                case .approving, .approved, .denied: return
                default: break
                }
                let result = try await status(parsed)
                try Task.checkCancellation()
                if result.isTerminalFailure { throw AloQRCodeLoginFailure.expired }
                if result.claimed, case .showing(let current) = state { state = .confirming(current) }
                try await pause()
            }
        } catch {
            guard !Task.isCancelled else { return }
            switch state {
            case .approving, .approved, .denied: return
            default: state = .failed(AloQRCodeLoginFailure.message(for: error))
            }
        }
    }

    func approve(using approve: (AloQRCodeLoginPayload) async throws -> Void) async {
        guard case .confirming = state, let payload else { return }
        state = .approving
        do {
            try await approve(payload)
            state = .approved
        } catch {
            state = .failed(AloQRCodeLoginFailure.message(for: error))
        }
    }

    func deny(using deny: (AloQRCodeLoginPayload) async throws -> Void) async {
        guard let payload else { return }
        state = .denied
        try? await deny(payload)
    }

    private static func expiration(_ value: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: value) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: value)
    }
}
