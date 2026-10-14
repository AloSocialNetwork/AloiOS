import SwiftUI

enum AloDeepLinkTarget: Equatable {
    case invite(String)
    case community(String)
    case post(Int)
    case user(Int)
    case channel(Int)
    case forumTopic(roomId: Int, topicId: Int)
    case handle(String)

    init?(url: URL) {
        self.init(url: url, configuredWebHost: Self.configuredWebLinkHost)
    }

    init?(url: URL, configuredWebHost: String) {
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "alo" || scheme == "https" else { return nil }
        if scheme == "https" {
            let expectedHost = configuredWebHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !expectedHost.isEmpty,
                  !expectedHost.hasSuffix(".invalid"),
                  url.host?.lowercased() == expectedHost else {
                return nil
            }
        }
        var components = url.pathComponents.filter { $0 != "/" }
        if scheme == "alo", let host = url.host, !host.isEmpty {
            components.insert(host, at: 0)
        }
        if scheme == "https", components.count == 1 {
            let handle = components[0].removingPercentEncoding?
                .replacingOccurrences(of: "@", with: "")
                .lowercased() ?? ""
            guard handle.range(of: #"^[a-z0-9_][a-z0-9_-]{1,48}[a-z0-9_]$"#, options: .regularExpression) != nil else {
                return nil
            }
            self = .handle(handle)
            return
        }
        if components.count == 3,
           ["t", "topic", "forum"].contains(components[0].lowercased()),
           let roomId = Int(components[1]), roomId > 0,
           let topicId = Int(components[2]), topicId > 0 {
            self = .forumTopic(roomId: roomId, topicId: topicId)
            return
        }
        guard components.count == 2 else { return nil }
        let kind = components[0].lowercased()
        let value = components[1].removingPercentEncoding ?? components[1]
        switch kind {
        case "invite", "join", "+":
            guard value.range(of: #"^[A-Za-z0-9_-]{16,128}$"#, options: .regularExpression) != nil else {
                return nil
            }
            self = .invite(value)
        case "c", "channel", "community":
            let username = value.replacingOccurrences(of: "@", with: "").lowercased()
            guard username.range(of: #"^[a-z0-9_]{5,32}$"#, options: .regularExpression) != nil else {
                return nil
            }
            self = .community(username)
        case "p", "post", "posts":
            guard let postId = Int(value), postId > 0 else { return nil }
            self = .post(postId)
        case "u", "user", "users":
            guard let userId = Int(value), userId > 0 else { return nil }
            self = .user(userId)
        case "ch", "feed-channel":
            guard let channelId = Int(value), channelId > 0 else { return nil }
            self = .channel(channelId)
        case "r", "resolve":
            let handle = value.replacingOccurrences(of: "@", with: "").lowercased()
            guard handle.range(of: #"^[a-z0-9_][a-z0-9_-]{1,48}[a-z0-9_]$"#, options: .regularExpression) != nil else {
                return nil
            }
            self = .handle(handle)
        default:
            return nil
        }
    }

    static func inviteURL(token: String) -> URL? {
        linkURL(kind: "join", value: token)
    }

    static func communityURL(username: String) -> URL? {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .lowercased()
        return linkURL(kind: "c", value: normalized)
    }

    static func postURL(postId: Int) -> URL? {
        linkURL(kind: "p", value: String(postId))
    }

    static func userURL(userId: Int) -> URL? {
        linkURL(kind: "u", value: String(userId))
    }

    static func channelURL(channelId: Int) -> URL? {
        linkURL(kind: "ch", value: String(channelId))
    }

    static func forumTopicURL(roomId: Int, topicId: Int) -> URL? {
        guard roomId > 0, topicId > 0 else { return nil }
        return linkURL(path: "t/\(roomId)/\(topicId)")
    }

    static func handleURL(_ handle: String) -> URL? {
        let normalized = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .lowercased()
        return linkURL(kind: "r", value: normalized)
    }

    private static func linkURL(kind: String, value: String) -> URL? {
        linkURL(path: "\(kind)/\(value)")
    }

    private static func linkURL(path: String) -> URL? {
        if let base = AloServerConfiguration.appLinkURL(path: path),
           base.scheme?.lowercased() == "https",
           base.host?.isEmpty == false {
            return base
        }
        return URL(string: "alo://\(path)")
    }

    private static var configuredWebLinkHost: String {
        guard AloServerConfiguration.appLinkBaseURL.scheme?.lowercased() == "https" else { return "" }
        return AloServerConfiguration.appLinkHost
    }
}

@main
struct AloiOSApp: App {
    @UIApplicationDelegateAdaptor(AloAppDelegate.self) private var appDelegate
    @StateObject private var app = AloAppModel()

    init() {
#if DEBUG
        if ProcessInfo.processInfo.environment["ALO_RUN_LIBSIGNAL_SELF_TEST"] == "1" {
            do {
                try AloLibSignalSelfTest.run()
                print("ALO_LIBSIGNAL_SELF_TEST_PASSED")
            } catch {
                fatalError("Alo libsignal self-test failed: \(error)")
            }
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if UserDefaults.standard.bool(forKey: "ALO_UI_QR_PREVIEW") {
                AloQRCodeDesignFixture().preferredColorScheme(.dark)
            } else {
                appContent
            }
#else
            appContent
#endif
        }
    }

    private var appContent: some View {
            RootView()
                .environmentObject(app)
                .environment(\.aloAPIClient, app.api)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: .aloPushReceived)) { _ in
                    Task { await app.loadBootstrap() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .aloPushOpened)) { _ in
                    Task { await app.loadBootstrap() }
                }
                .onOpenURL { url in
                    app.handleDeepLink(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    app.handleDeepLink(url)
                }
    }
}
