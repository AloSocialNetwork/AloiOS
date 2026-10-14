import Foundation

/// The only client-side source of truth for Alo network and universal-link endpoints.
///
/// Values are injected by the `ALO_*` build settings into `Support/Info.plist`.
/// Keep API and app-link changes here rather than introducing endpoint literals in
/// feature code. Production hosts must remain HTTPS; a raw IP is appropriate only
/// for a local debug build and cannot provide universal links or certificate trust.
final class AloServerConfiguration {
    private init() {}

    #if DEBUG
    /// A simulator can use 127.0.0.1; a physical iPhone needs the development
    /// Mac's current LAN address. An explicit host:port is accepted in both cases.
    #if targetEnvironment(simulator)
    static let debugLocalDevelopmentHost = "127.0.0.1"
    #else
    /// Current Wi-Fi address of the development Mac. Do not use 198.18.0.1:
    /// it is a local VPN tunnel, not an address reachable by the iPhone.
    /// Run `ifconfig en0 | grep 'inet '` after changing networks, update this
    /// value, then rebuild the Debug app.
    static let debugLocalDevelopmentHost = "192.168.0.19"
    #endif
    private static let localDevelopmentPort = 3000
    private static let localDevelopmentBaseURL = developmentURL(from: debugLocalDevelopmentHost)
        ?? URL(string: "http://192.168.0.26:3000/")!

    /// Accept either a bare LAN host, host:port, or an explicit development URL.
    /// Never append a second port, and never force-unwrap user-edited input.
    static func developmentURL(from address: String) -> URL? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
              var components = URLComponents(string: address.contains("://") ? address : "http://" + address),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              !host.contains(where: \.isWhitespace),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        if components.port == nil, components.scheme == "http" { components.port = localDevelopmentPort }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }
    #endif

    private static let appLinkBaseURLValue = stringValue(for: "AloAppLinkBaseURL")
    private static let apiBaseURLValue = stringValue(for: "AloAPIBaseURL")
    private static let defaultAppLinkBaseURL = URL(string: "https://xn--80awj.online/")!

    static let appLinkBaseURL: URL = {
        URL(string: appLinkBaseURLValue) ?? defaultAppLinkBaseURL
    }()

    static let appLinkHost = appLinkBaseURL.host?.lowercased() ?? ""

    /// The app-link host as people read it: `ало.online`, not its DNS form `xn--80awj.online`.
    static var appLinkDisplayHost: String { AloPunycode.displayHost(appLinkHost) }

    static let baseURLs: [URL] = {
        let configured = apiBaseURLValue
            .split(separator: ",")
            .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }

        #if DEBUG
        return configured.isEmpty ? [localDevelopmentBaseURL] : configured
        #else
        return configured
        #endif
    }()

    static let certificatePins: [String] = stringValue(for: "AloCertificatePins")
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    // Cloudflare rotates edge certificates, so pins are opt-in and must only be
    // enabled for a deployment with stable, intentionally managed pin values.
    static let requiresCertificatePins = !certificatePins.isEmpty

    static func normalizedBaseURLs(_ configured: [URL]) -> [URL] {
        #if DEBUG
        return configured.isEmpty ? [localDevelopmentBaseURL] : configured
        #else
        let secure = configured.filter { $0.scheme?.lowercased() == "https" }
        precondition(!secure.isEmpty, "ALO_API_BASE_URL must contain an HTTPS URL in Release builds.")
        return secure
        #endif
    }

    static func appLinkURL(path: String) -> URL? {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else { return appLinkBaseURL }
        return URL(string: normalizedPath, relativeTo: appLinkBaseURL)?.absoluteURL
    }

    private static func stringValue(for key: String) -> String {
        String(describing: Bundle.main.object(forInfoDictionaryKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// RFC 3492 decoding for showing internationalised domain names to people.
enum AloPunycode {
    static func displayHost(_ host: String) -> String {
        host.split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            let label = String(label)
            guard label.lowercased().hasPrefix("xn--"), let decoded = decode(String(label.dropFirst(4))) else { return label }
            return decoded
        }.joined(separator: ".")
    }

    static func decode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        var output: [Unicode.Scalar] = []
        let characters = Array(input.unicodeScalars)
        var index = 0
        if let delimiter = characters.lastIndex(of: "-") {
            output = Array(characters[..<delimiter])
            guard output.allSatisfy(\.isASCII) else { return nil }
            index = delimiter + 1
        }
        func digit(_ scalar: Unicode.Scalar) -> Int? {
            switch scalar.value {
            case 48...57: return Int(scalar.value) - 22      // 0-9 → 26-35
            case 65...90: return Int(scalar.value) - 65      // A-Z → 0-25
            case 97...122: return Int(scalar.value) - 97     // a-z → 0-25
            default: return nil
            }
        }
        func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / points
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        var n = 128, i = 0, bias = 72
        while index < characters.count {
            let oldI = i
            var weight = 1
            var k = base
            while true {
                guard index < characters.count, let value = digit(characters[index]) else { return nil }
                index += 1
                i += value * weight
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if value < t { break }
                weight *= base - t
                k += base
            }
            bias = adapt(i - oldI, output.count + 1, oldI == 0)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard let scalar = Unicode.Scalar(n) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        return String(String.UnicodeScalarView(output))
    }
}
