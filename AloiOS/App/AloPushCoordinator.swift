import Foundation
import PushKit
import UIKit
import UserNotifications

extension Notification.Name {
    static let aloPushReceived = Notification.Name("alo.push.received")
    static let aloPushOpened = Notification.Name("alo.push.opened")
}

enum AloPushAvailability {
    static var isEnabled: Bool {
#if ALO_PUSH_NOTIFICATIONS
        true
#else
        false
#endif
    }
}

@MainActor
final class AloPushCoordinator {
    static let shared = AloPushCoordinator()

    private let tokenKey = "alo.ios.push.apns-token.v1"
    private let deviceIdKey = "alo.ios.push.device-id.v1"
    private var syncTask: Task<Void, Never>?

    private init() {}

    var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: deviceIdKey)
        return created
    }

    func updateDeviceToken(_ data: Data, api: AloAPIClient = .shared) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { return }
        UserDefaults.standard.set(token, forKey: tokenKey)
        sync(api: api)
    }

    func sync(api: AloAPIClient = .shared) {
        guard AloPushAvailability.isEnabled else { return }
        guard let token = UserDefaults.standard.string(forKey: tokenKey), !token.isEmpty else { return }
        syncTask?.cancel()
        syncTask = Task {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            try? await api.registerPushToken(
                platform: "ios",
                token: token,
                deviceId: deviceId,
                appVersion: version
            )
        }
    }

    func unregister(api: AloAPIClient = .shared) async {
        syncTask?.cancel()
        syncTask = nil
        await AloVoIPPushCoordinator.shared.unregister(api: api)
        guard let token = UserDefaults.standard.string(forKey: tokenKey), !token.isEmpty else { return }
        try? await api.unregisterPushToken(
            platform: "ios",
            token: token,
            deviceId: deviceId
        )
    }
}

final class AloVoIPPushCoordinator: NSObject, PKPushRegistryDelegate {
    typealias IncomingHandler = @MainActor ([AnyHashable: Any]) async -> Void

    static let shared = AloVoIPPushCoordinator()

    private let tokenKey = "alo.ios.push.voip-token.v1"
    private var registry: PKPushRegistry?
    private var incomingHandler: IncomingHandler?
    private var bufferedPayloads = [[AnyHashable: Any]]()
    private var didStart = false

    private override init() {
        super.init()
    }

    @MainActor
    func start() {
        guard AloPushAvailability.isEnabled else { return }
        guard !didStart else { return }
        didStart = true
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    @MainActor
    func setIncomingHandler(_ handler: @escaping IncomingHandler) {
        incomingHandler = handler
        let pending = bufferedPayloads
        bufferedPayloads.removeAll()
        for payload in pending {
            Task { await handler(payload) }
        }
    }

    @MainActor
    func sync(api: AloAPIClient = .shared) {
        guard AloPushAvailability.isEnabled else { return }
        guard let token = UserDefaults.standard.string(forKey: tokenKey), !token.isEmpty else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        Task {
            try? await api.registerVoIPPushToken(
                token: token,
                deviceId: AloPushCoordinator.shared.deviceId,
                appVersion: version
            )
        }
    }

    @MainActor
    func unregister(api: AloAPIClient = .shared) async {
        guard let token = UserDefaults.standard.string(forKey: tokenKey), !token.isEmpty else { return }
        try? await api.unregisterVoIPPushToken(
            token: token,
            deviceId: AloPushCoordinator.shared.deviceId
        )
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { return }
        UserDefaults.standard.set(token, forKey: tokenKey)
        Task { @MainActor in sync() }
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }
        let dictionary = payload.dictionaryPayload
        Task { @MainActor in
            if let incomingHandler {
                await incomingHandler(dictionary)
            } else {
                bufferedPayloads.append(dictionary)
            }
            completion()
        }
    }
}

final class AloAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard AloPushAvailability.isEnabled else { return true }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
        Task { @MainActor in
            AloVoIPPushCoordinator.shared.start()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            AloPushCoordinator.shared.updateDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("APNs registration failed: \(error.localizedDescription)")
        #endif
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NotificationCenter.default.post(name: .aloPushReceived, object: nil, userInfo: userInfo)
        completionHandler(.newData)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        NotificationCenter.default.post(
            name: .aloPushReceived,
            object: nil,
            userInfo: notification.request.content.userInfo
        )
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        NotificationCenter.default.post(
            name: .aloPushOpened,
            object: nil,
            userInfo: response.notification.request.content.userInfo
        )
    }
}
