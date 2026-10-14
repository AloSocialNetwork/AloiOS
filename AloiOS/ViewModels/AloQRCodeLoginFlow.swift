import Foundation
import Combine

enum AloQRCodeLoginFailure: Error {
    case invalidCode
    case expired
    case alreadyUsed
    case completion(String)

    static func message(for error: Error) -> String {
        if let failure = error as? Self {
            switch failure {
            case .invalidCode: return "Сервер вернул некорректный QR-код. Попробуйте создать новый."
            case .expired: return "Срок действия QR-кода истёк. Создайте новый код."
            case .alreadyUsed: return "Этот QR-код уже использован. Создайте новый код."
            case .completion(let message): return message
            }
        }
        if let api = error as? AloAPIError {
            switch api.code {
            case "QR_LOGIN_EXPIRED", "QR_LOGIN_NOT_PENDING": return message(for: Self.expired)
            case "QR_LOGIN_ALREADY_USED": return message(for: Self.alreadyUsed)
            default:
                if api.status == 404 || api.status == 501 {
                    return "Этот сервер не поддерживает QR-вход. Обновите сервер и попробуйте снова."
                }
                return api.message
            }
        }
        return "Не удалось связаться с сервером. Проверьте соединение и попробуйте снова."
    }
}

/// Scanning only prepares a confirmation. It never grants access on its own.
@MainActor
final class AloQRCodeApprovalFlow: ObservableObject {
    enum State: Equatable {
        case scanning
        case confirming(AloQRCodeLoginPayload)
        case approving
        case approved
        case failed(String)
    }

    @Published private(set) var state: State = .scanning

    func scanned(_ raw: String) {
        guard state == .scanning else { return }
        guard let payload = AloQRCodeLoginPayload(rawPayload: raw) else {
            state = .failed("Это не QR-код входа Alo. Отсканируйте код с экрана «Вход по QR».")
            return
        }
        state = .confirming(payload)
    }

    func reset() { state = .scanning }

    func scannerFailed(_ message: String) {
        guard state == .scanning else { return }
        state = .failed(message)
    }

    func confirm(approve: (AloQRCodeLoginPayload) async throws -> Void) async {
        guard case .confirming(let payload) = state, !Task.isCancelled else { return }
        state = .approving
        do {
            try await approve(payload)
            try Task.checkCancellation()
            state = .approved
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(AloQRCodeLoginFailure.message(for: error))
        }
    }
}

/// One structured task owns creation, polling and completion. Leaving the sheet
/// cancels it; a late response must never start another login or mutate its UI.
@MainActor
final class AloQRCodeLoginFlow: ObservableObject {
    enum State: Equatable {
        case loading
        case waiting(AloQRCodeLoginRequest)
        case completing
        case failed(String)
        case signedIn
    }

    @Published private(set) var state: State = .loading
    private var runID: UUID?

    func run(
        start: () async throws -> AloQRCodeLoginRequest,
        status: (AloQRCodeLoginPayload) async throws -> AloQRCodeLoginStatus,
        complete: (AloQRCodeLoginPayload) async throws -> Void,
        now: () -> Date = Date.init,
        pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 2_500_000_000) }
    ) async {
        let id = UUID()
        runID = id
        state = .loading
        defer { if runID == id { runID = nil } }
        do {
            try Task.checkCancellation()
            let request = try await start()
            try checkActive(id)
            guard let payload = AloQRCodeLoginPayload(requestID: request.requestID, rawPayload: request.payload),
                  let expiresAt = Self.expiration(request.expiresAt) else { throw AloQRCodeLoginFailure.invalidCode }
            state = .waiting(request)
            while true {
                try checkActive(id)
                guard now() < expiresAt else { throw AloQRCodeLoginFailure.expired }
                let result = try await status(payload)
                try checkActive(id)
                if result.isApproved {
                    state = .completing
                    try await complete(payload)
                    try checkActive(id)
                    state = .signedIn
                    return
                }
                if result.isTerminalFailure {
                    throw result.status == "consumed" ? AloQRCodeLoginFailure.alreadyUsed : AloQRCodeLoginFailure.expired
                }
                guard result.status == "pending" else { throw AloQRCodeLoginFailure.invalidCode }
                try await pause()
            }
        } catch {
            guard !Task.isCancelled, runID == id else { return }
            state = .failed(AloQRCodeLoginFailure.message(for: error))
        }
    }

    private func checkActive(_ id: UUID) throws {
        try Task.checkCancellation()
        guard runID == id else { throw CancellationError() }
    }

    private static func expiration(_ value: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: value) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: value)
    }
}
