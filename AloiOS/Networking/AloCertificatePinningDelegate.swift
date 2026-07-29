import CryptoKit
import Foundation
import Security

final class AloCertificatePinningDelegate: NSObject, URLSessionDelegate {
    private let pinnedHosts: Set<String>
    private let certificatePins: Set<Data>
    private let requiresPins: Bool

    init(baseURLs: [URL], configuredPins: [String], requiresPins: Bool) {
        pinnedHosts = Set(baseURLs.compactMap { $0.host?.lowercased() })
        certificatePins = Set(configuredPins.compactMap(Self.decodePin))
        self.requiresPins = requiresPins
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host.lowercased()
        guard pinnedHosts.contains(host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var trustError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &trustError) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard !certificatePins.isEmpty else {
            if requiresPins {
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            }
            return
        }

        guard let certificateChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let matchesPin = certificateChain.contains { certificate in
            let certificateData = SecCertificateCopyData(certificate) as Data
            let digest = Data(SHA256.hash(data: certificateData))
            return certificatePins.contains(digest)
        }

        if matchesPin {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    static func decodePin(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let payload: String
        if let slash = trimmed.firstIndex(of: "/") {
            let prefix = trimmed[..<slash].lowercased()
            guard prefix == "sha256" || prefix == "cert-sha256" else { return nil }
            payload = String(trimmed[trimmed.index(after: slash)...])
        } else {
            payload = trimmed
        }

        if payload.count == 64,
           payload.allSatisfy({ $0.isHexDigit }) {
            var bytes = [UInt8]()
            bytes.reserveCapacity(32)
            var index = payload.startIndex
            while index < payload.endIndex {
                let next = payload.index(index, offsetBy: 2)
                guard let byte = UInt8(payload[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return Data(bytes)
        }

        guard let decoded = Data(base64Encoded: payload), decoded.count == 32 else { return nil }
        return decoded
    }
}
