import Foundation

/// A QR is a short-lived credential. Accept only Alo's login route, never a
/// random URL that happens to contain a `secret` query parameter.
struct AloQRCodeLoginPayload: Equatable, Identifiable {
    let requestID: String
    let secret: String
    /// The website that showed the code (`https://<host>/qr#…`); empty for the older `alo://login/qr/…` form.
    var webHost: String = ""

    var id: String { requestID }

    /// The website's sign-in QR may be approved only on the Alo server this app talks to (or its public site).
    var isFromTrustedHost: Bool { webHost.isEmpty || Self.isAloWebHost(webHost) }

    static func isAloWebHost(_ host: String) -> Bool {
        let host = host.lowercased()
        guard !host.isEmpty else { return false }
        if host == AloServerConfiguration.appLinkHost { return true }
        return AloServerConfiguration.baseURLs.contains { base in
            let apiHost = base.host?.lowercased() ?? ""
            return apiHost == host || apiHost == "api." + host
        }
    }

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
        var webHost = ""
        if let url = URLComponents(string: rawPayload), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            // The website's code: https://<host>/qr#<id>.<secret> — what the system camera opens as a link.
            guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil,
                  url.percentEncodedPath == "/qr" || url.percentEncodedPath == "/qr/",
                  let fragment = url.percentEncodedFragment else { return nil }
            let parts = fragment.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            requestID = String(parts[0])
            secret = String(parts[1])
            webHost = host.lowercased()
        } else if let url = URLComponents(string: rawPayload), url.scheme != nil {
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
        self.webHost = webHost
    }

    private static func isStableID(_ value: String, length: ClosedRange<Int>) -> Bool {
        length.contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// What the server knows about the device that asks to sign in («Войти на устройстве Chrome · macOS?»).
struct AloQRCodeLoginDevice: Equatable {
    let label: String
    let ip: String
    let deviceType: String

    static let unknown = AloQRCodeLoginDevice(label: "", ip: "", deviceType: "")

    init(label: String, ip: String, deviceType: String) {
        self.label = label
        self.ip = ip
        self.deviceType = deviceType
    }

    init(_ json: [String: Any]) {
        let device = json["device"] as? [String: Any] ?? [:]
        label = (device["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ip = (device["ip"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        deviceType = device["deviceType"] as? String ?? ""
    }
}
