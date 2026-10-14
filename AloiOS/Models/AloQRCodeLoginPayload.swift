import Foundation

/// A QR is a short-lived credential. Accept only Alo's login route, never a
/// random URL that happens to contain a `secret` query parameter.
struct AloQRCodeLoginPayload: Equatable {
    let requestID: String
    let secret: String

    init?(requestID: String, rawPayload: String) {
        guard let parsed = Self(rawPayload: rawPayload), parsed.requestID == requestID else { return nil }
        self = parsed
    }

    /// `alo://login/link/<id>/<secret>`: a QR shown by an already signed-in device. Only this exact form.
    init?(deviceLinkPayload raw: String) {
        guard raw.utf8.count <= 1_024, let url = URLComponents(string: raw),
              url.scheme?.lowercased() == "alo", url.host?.lowercased() == "login",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil, url.query == nil else { return nil }
        let parts = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "link",
              Self.isStableID(String(parts[2]), length: 16...160),
              Self.isStableID(String(parts[3]), length: 32...256) else { return nil }
        requestID = String(parts[2])
        secret = String(parts[3])
    }

    init?(rawPayload: String) {
        guard rawPayload.utf8.count <= 1_024 else { return nil }
        let requestID: String
        let secret: String
        if let url = URLComponents(string: rawPayload), url.scheme != nil {
            guard url.scheme?.lowercased() == "alo", url.host?.lowercased() == "login",
                  url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else { return nil }
            let parts = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            if url.query == nil, parts.count == 4, parts[0].isEmpty, parts[1] == "qr" {
                requestID = String(parts[2])
                secret = String(parts[3])
            } else if url.percentEncodedPath == "/qr", let query = url.queryItems, query.count == 2,
                      let id = query.first(where: { ["requestId", "requestID", "id"].contains($0.name) })?.value,
                      let token = query.first(where: { $0.name == "secret" })?.value {
                // Compatibility with the older, explicit Alo query payload.
                requestID = id
                secret = token
            } else { return nil }
        } else if let data = rawPayload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (json["requestId"] ?? json["id"]) as? String,
                  let token = json["secret"] as? String {
            requestID = id
            secret = token
        } else { return nil }
        guard Self.isStableID(requestID, length: 16...160),
              Self.isStableID(secret, length: 32...256) else { return nil }
        self.requestID = requestID
        self.secret = secret
    }

    private static func isStableID(_ value: String, length: ClosedRange<Int>) -> Bool {
        length.contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
