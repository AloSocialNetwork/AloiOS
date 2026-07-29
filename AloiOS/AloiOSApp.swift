import SwiftUI

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
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: .aloPushReceived)) { _ in
                    Task { await app.loadBootstrap() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .aloPushOpened)) { _ in
                    Task { await app.loadBootstrap() }
                }
        }
    }
}
