import AuthenticationServices
import Foundation
import UIKit

enum AloPasskeySystemCredential {
    case registration(
        credentialID: Data,
        clientDataJSON: Data,
        attestationObject: Data
    )
    case assertion(
        credentialID: Data,
        clientDataJSON: Data,
        authenticatorData: Data,
        signature: Data,
        userID: Data
    )
}

enum AloPasskeyCoordinatorError: LocalizedError {
    case malformedServerOptions
    case anotherRequestInProgress
    case unexpectedCredential
    case presentationUnavailable

    var errorDescription: String? {
        switch self {
        case .malformedServerOptions:
            return "Сервер вернул неполные параметры ключа доступа."
        case .anotherRequestInProgress:
            return "Подтверждение ключом доступа уже открыто."
        case .unexpectedCredential:
            return "Система вернула неподдерживаемый ключ доступа."
        case .presentationUnavailable:
            return "Не удалось открыть системное подтверждение ключом доступа."
        }
    }
}

/// The app never creates, exports, or stores private passkey material. This
/// coordinator only forwards a single, server-issued WebAuthn challenge to the
/// system AuthenticationServices UI and returns the signed response.
@MainActor
final class AloPasskeyCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    static let shared = AloPasskeyCoordinator()

    private var activeController: ASAuthorizationController?
    private var continuation: CheckedContinuation<AloPasskeySystemCredential, Error>?

    static var isSystemAvailable: Bool {
        if #available(iOS 15.0, *) {
            return true
        }
        return false
    }

    func register(
        options: AloPasskeyRegistrationOptions
    ) async throws -> AloPasskeySystemCredential {
        guard Self.isSystemAvailable,
              let challenge = Data(aloBase64URLEncoded: options.challenge),
              let userID = Data(aloBase64URLEncoded: options.userID),
              !options.relyingPartyID.isEmpty,
              !options.userName.isEmpty else {
            throw AloPasskeyCoordinatorError.malformedServerOptions
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: options.relyingPartyID
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge,
            name: options.userName,
            userID: userID
        )
        request.displayName = options.userDisplayName
        request.userVerificationPreference = verificationPreference(options.userVerification)
        if #available(iOS 17.4, *) {
            request.excludedCredentials = options.excludedCredentialIDs.compactMap { encodedID in
                guard let credentialID = Data(aloBase64URLEncoded: encodedID) else { return nil }
                return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: credentialID)
            }
        }
        return try await perform(request)
    }

    func assert(
        options: AloPasskeyAssertionOptions
    ) async throws -> AloPasskeySystemCredential {
        guard Self.isSystemAvailable,
              let challenge = Data(aloBase64URLEncoded: options.challenge),
              !options.relyingPartyID.isEmpty else {
            throw AloPasskeyCoordinatorError.malformedServerOptions
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: options.relyingPartyID
        )
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = verificationPreference(options.userVerification)
        request.allowedCredentials = options.allowedCredentialIDs.compactMap { encodedID in
            guard let credentialID = Data(aloBase64URLEncoded: encodedID) else { return nil }
            return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: credentialID)
        }
        return try await perform(request)
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> AloPasskeySystemCredential {
        guard continuation == nil else {
            throw AloPasskeyCoordinatorError.anotherRequestInProgress
        }
        guard presentationAnchor(for: ASAuthorizationController(authorizationRequests: [request])).windowScene != nil else {
            throw AloPasskeyCoordinatorError.presentationUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            activeController = controller
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let result: AloPasskeySystemCredential?
        switch authorization.credential {
        case let credential as ASAuthorizationPlatformPublicKeyCredentialRegistration:
            guard let attestationObject = credential.rawAttestationObject else {
                finish(with: .failure(AloPasskeyCoordinatorError.unexpectedCredential))
                return
            }
            result = .registration(
                credentialID: credential.credentialID,
                clientDataJSON: credential.rawClientDataJSON,
                attestationObject: attestationObject
            )
        case let credential as ASAuthorizationPlatformPublicKeyCredentialAssertion:
            result = .assertion(
                credentialID: credential.credentialID,
                clientDataJSON: credential.rawClientDataJSON,
                authenticatorData: credential.rawAuthenticatorData,
                signature: credential.signature,
                userID: credential.userID
            )
        default:
            result = nil
        }
        guard let result else {
            finish(with: .failure(AloPasskeyCoordinatorError.unexpectedCredential))
            return
        }
        finish(with: .success(result))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<AloPasskeySystemCredential, Error>) {
        let continuation = continuation
        self.continuation = nil
        activeController = nil
        continuation?.resume(with: result)
    }

    private func verificationPreference(
        _ rawValue: String
    ) -> ASAuthorizationPublicKeyCredentialUserVerificationPreference {
        switch rawValue.lowercased() {
        case "required":
            return .required
        case "discouraged":
            return .discouraged
        default:
            return .preferred
        }
    }
}

private extension Data {
    init?(aloBase64URLEncoded value: String) {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: normalized)
    }
}
