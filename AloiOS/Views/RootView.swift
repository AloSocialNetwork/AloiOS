import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundCallID: Int?
    @State private var backgroundGroupCallID: Int?
    @State private var chatContextPresented = false

    /// UI fixtures can hold the launch placeholder on screen to review it.
    private var displayedPhase: AloAppModel.Phase {
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_LOADING_SKELETON") { return .loading }
#endif
        return app.phase
    }

    var body: some View {
        ZStack {
            AloTheme.background.ignoresSafeArea(.container)
            switch displayedPhase {
            case .loading:
                AloAppLoadingSkeleton(
                    errorMessage: app.errorMessage,
                    onRetry: app.retryInitialBootstrap
                )
            case .auth:
                AuthView()
            case .app:
#if DEBUG
                if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"),
                   UserDefaults.standard.string(forKey: "ALO_UI_MESSENGER_CONTENT") == "feed" {
                    AloFeedDesignFixture()
                } else {
                    AloMainTabCallContainer(coordinator: app.calls)
                }
#else
                AloMainTabCallContainer(coordinator: app.calls)
#endif
            }

            if let challenge = app.humanChallenge {
                HumanChallengeView(
                    challenge: challenge,
                    onToken: app.completeChallenge,
                    onClose: app.closeChallenge
                )
                .zIndex(10)
            }

            AloCallOverlay(coordinator: app.calls)
                .zIndex(50)

            AloGroupCallOverlay(coordinator: app.calls.groupCall)
                .zIndex(49)

            AloGroupCallCompactHost(coordinator: app.calls.groupCall)
                .zIndex(48)
#if DEBUG
            if UserDefaults.standard.bool(forKey: "ALO_UI_LOADING_SKELETON") {
                ZStack {
                    AloTheme.background.ignoresSafeArea()
                    AloAppLoadingSkeleton(errorMessage: "", onRetry: {})
                }
                .zIndex(1000)
            }
#endif
        }
        // A story link opens over whatever is on screen.
        .fullScreenCover(item: $app.linkedStory) { group in
            AloStoryViewer(groups: [group], startGroupID: group.id)
                .environmentObject(app)
        }
        .sheet(item: $app.expiredStory) { notice in
            AloStoryExpiredSheet(notice: notice)
                .environmentObject(app)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: app.phaseKey)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: app.humanChallenge?.id)
        // A connection notice must never reserve layout space. In particular it
        // used to move a conversation (and its date separators) below the
        // navigation chrome. Conversations express the state in their own
        // subtitle; this small overlay is for the other top-level screens.
        .overlay(alignment: .top) {
            if app.phase == .app, app.activeTab != .feed, app.activeTab != .alerts, app.activeTab != .search, app.commentsPost == nil, app.activeConversation == nil, !chatContextPresented, app.connectionState != .connected {
                connectionStatusOverlay
                    .padding(.top, 6)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onPreferenceChange(AloChatPreviewPresentedKey.self) { chatContextPresented = $0 }
        .task {
            app.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                app.suspendConnectionRefresh()
                backgroundCallID = app.calls.activeCall?.id
                backgroundGroupCallID = app.calls.groupCall.activeCall?.id
            } else if phase == .active {
                app.refreshConnectionIfNeeded()
                // Returning via the system's ongoing-call indicator should
                // show that same call, not leave it hidden in the inbox.
                if let id = backgroundCallID, app.calls.activeCall?.id == id {
                    withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                        app.calls.isMinimized = false
                    }
                }
                if let id = backgroundGroupCallID, app.calls.groupCall.activeCall?.id == id {
                    withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                        app.calls.groupCall.isMinimized = false
                    }
                }
                backgroundCallID = nil
                backgroundGroupCallID = nil
            }
        }
#if DEBUG
        .modifier(AloMessengerAccessibilityPreviewModifier())
#endif
    }

    private var connectionStatusOverlay: some View {
        Button(action: app.retryInitialBootstrap) {
            HStack(spacing: 7) {
                if case .updating = app.connectionState {
                    ProgressView().controlSize(.mini)
                    Text("Обновление…")
                } else {
                    Image(systemName: "wifi.slash")
                    Text("Нет связи · Повторить")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AloTheme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(AloTheme.border.opacity(0.55), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(AloControlPressStyle())
        .accessibilityIdentifier("alo.connection.status")
        .accessibilityValue(connectionStatusAccessibilityValue)
    }

    private var connectionStatusAccessibilityValue: String {
        if case .updating = app.connectionState { return "Обновление" }
        return "Нет связи с сервером"
    }
}

private struct AloGroupCallCompactHost: View {
    @ObservedObject var coordinator: AloGroupCallCoordinator

    var body: some View {
        GeometryReader { geometry in
            if let call = coordinator.activeCall, coordinator.isMinimized {
                AloGroupCallCompactBar(call: call, coordinator: coordinator)
                    .frame(
                        width: geometry.size.width,
                        height: max(40, geometry.safeAreaInsets.top + 12)
                    )
                    .ignoresSafeArea(edges: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .allowsHitTesting(coordinator.activeCall != nil && coordinator.isMinimized)
        .animation(
            .spring(response: 0.32, dampingFraction: 0.88),
            value: coordinator.isMinimized
        )
    }
}

private struct AloMainTabCallContainer: View {
    @ObservedObject var coordinator: AloCallCoordinator

    var body: some View {
        GeometryReader { geometry in
            let statusBarHeight = max(
                40,
                geometry.safeAreaInsets.top + 12
            )

            ZStack(alignment: .top) {
                MainTabView()

                if let call = coordinator.activeCall {
                    AloCallCompactBar(
                        call: call,
                        coordinator: coordinator,
                        statusBarHeight: statusBarHeight
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: statusBarHeight)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(coordinator.isMinimized)
                    .accessibilityHidden(!coordinator.isMinimized)
                    .zIndex(20)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(
                .easeOut(duration: 0.18),
                value: coordinator.activeCall?.id
            )
        }
    }
}

/// Shared shimmer state for every skeleton shape. One band travels across the whole screen, and
/// each shape shows only the slice of it that falls inside that shape, so the light reads as one
/// moving reflection instead of a separate glow in each box.
private struct AloSkeletonShimmerKey: EnvironmentKey {
    static let defaultValue: (phase: Double, screenWidth: CGFloat)? = nil
}

private extension EnvironmentValues {
    var aloSkeletonShimmer: (phase: Double, screenWidth: CGFloat)? {
        get { self[AloSkeletonShimmerKey.self] }
        set { self[AloSkeletonShimmerKey.self] = newValue }
    }
}

/// The launch placeholder mirrors the real feed (flat posts, no cards) so the screen does not
/// change shape when content arrives.
private struct AloAppLoadingSkeleton: View {
    let errorMessage: String
    let onRetry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate / 1.6
                content
                    .environment(\.aloSkeletonShimmer, reduceMotion ? nil : (phase - floor(phase), proxy.size.width))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Загрузка")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                AloSkeletonShape(width: 96, height: 28, radius: 10)
                Spacer()
                AloSkeletonShape(width: 38, height: 38, radius: 19)
            }
            .padding(.horizontal, 16).padding(.top, 14)

            AloSkeletonShape(width: nil, height: 44, radius: 22)
                .padding(.horizontal, 16).padding(.top, 12)

            HStack(spacing: 14) {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(spacing: 6) {
                        AloSkeletonShape(width: 62, height: 62, radius: 31)
                        AloSkeletonShape(width: 40, height: 9, radius: 4.5)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            ForEach(0..<2, id: \.self) { index in
                AloSkeletonPost(seed: index)
                Rectangle().fill(AloTheme.feedDivider).frame(height: 0.5)
            }

            Spacer(minLength: 0)

            if !errorMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 13, weight: .bold))
                    Text("Ждем соединение. Можно пользоваться сохраненными данными.")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AloTheme.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(AloTheme.surface.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
        }
    }
}

private struct AloSkeletonPost: View {
    let seed: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AloSkeletonShape(width: 44, height: 44, radius: 22)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    AloSkeletonShape(width: seed.isMultiple(of: 2) ? 110 : 88, height: 13, radius: 6.5)
                    AloSkeletonShape(width: 70, height: 11, radius: 5.5)
                }
                AloSkeletonShape(width: nil, height: 13, radius: 6.5)
                AloSkeletonShape(width: seed.isMultiple(of: 2) ? 200 : 160, height: 13, radius: 6.5)
                AloSkeletonShape(width: nil, height: seed.isMultiple(of: 2) ? 190 : 150, radius: 14)
                HStack(spacing: 28) {
                    ForEach(0..<3, id: \.self) { _ in AloSkeletonShape(width: 34, height: 11, radius: 5.5) }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

private struct AloSkeletonShape: View {
    let width: CGFloat?
    let height: CGFloat
    let radius: CGFloat
    @Environment(\.aloSkeletonShimmer) private var shimmer

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(AloTheme.surfaceRaised.opacity(0.62))
            .overlay {
                if let shimmer {
                    GeometryReader { proxy in
                        // The band's position is computed in screen space, then shifted into this shape.
                        let band = shimmer.screenWidth * 0.5
                        let center = -band + (shimmer.screenWidth + 2 * band) * shimmer.phase
                        LinearGradient(colors: [.clear, .white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: center - band / 2 - proxy.frame(in: .global).minX)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height)
    }
}

private extension AloAppModel {
    var phaseKey: String {
        switch phase {
        case .loading: return "loading"
        case .auth: return "auth"
        case .app: return "app"
        }
    }
}
