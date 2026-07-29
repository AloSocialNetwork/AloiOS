import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AloAppModel

    var body: some View {
        ZStack {
            AloTheme.background.ignoresSafeArea(.container)
            switch app.phase {
            case .loading:
                AloAppLoadingSkeleton(
                    errorMessage: app.errorMessage,
                    onRetry: app.retryInitialBootstrap
                )
            case .auth:
                AuthView()
            case .app:
                AloMainTabCallContainer(coordinator: app.calls)
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
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: app.phaseKey)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: app.humanChallenge?.id)
        .task {
            app.start()
        }
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

private struct AloAppLoadingSkeleton: View {
    let errorMessage: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    AloSkeletonShape(width: 112, height: 18, radius: 9)
                    AloSkeletonShape(width: 178, height: 12, radius: 6)
                }
                Spacer()
                Button(action: onRetry) {
                    Image(systemName: errorMessage.isEmpty ? "arrow.triangle.2.circlepath" : "wifi.exclamationmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AloTheme.text)
                        .frame(width: 42, height: 42)
                        .background(AloTheme.surface)
                        .clipShape(Circle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.94))
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)

            VStack(spacing: 12) {
                ForEach(0..<2, id: \.self) { index in
                    AloSkeletonCard(seed: index)
                }
            }
            .padding(.horizontal, 14)

            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 12) {
                        AloSkeletonShape(width: 50, height: 50, radius: 25)
                        VStack(alignment: .leading, spacing: 8) {
                            AloSkeletonShape(width: index.isMultiple(of: 2) ? 160 : 128, height: 15, radius: 8)
                            AloSkeletonShape(width: index.isMultiple(of: 2) ? 210 : 176, height: 12, radius: 6)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 10) {
                            AloSkeletonShape(width: 38, height: 10, radius: 5)
                            AloSkeletonShape(width: 18, height: 18, radius: 9)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    Divider().background(AloTheme.border.opacity(0.45)).padding(.leading, 78)
                }
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

private struct AloSkeletonCard: View {
    let seed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                AloSkeletonShape(width: 42, height: 42, radius: 21)
                VStack(alignment: .leading, spacing: 7) {
                    AloSkeletonShape(width: seed.isMultiple(of: 2) ? 146 : 120, height: 14, radius: 7)
                    AloSkeletonShape(width: 90, height: 10, radius: 5)
                }
                Spacer()
                AloSkeletonShape(width: 38, height: 10, radius: 5)
            }
            AloSkeletonShape(width: nil, height: 15, radius: 8)
            AloSkeletonShape(width: seed.isMultiple(of: 2) ? 260 : 216, height: 15, radius: 8)
            AloSkeletonShape(width: nil, height: seed.isMultiple(of: 2) ? 132 : 104, radius: 20)
        }
        .padding(14)
        .background(AloTheme.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AloTheme.border.opacity(0.7), lineWidth: 1)
        )
    }
}

private struct AloSkeletonShape: View {
    let width: CGFloat?
    let height: CGFloat
    let radius: CGFloat

    init(width: CGFloat?, height: CGFloat, radius: CGFloat) {
        self.width = width
        self.height = height
        self.radius = radius
    }

    init(width: CGFloat, height: CGFloat, radius: CGFloat) {
        self.width = width
        self.height = height
        self.radius = radius
    }

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.25) / 1.25
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(AloTheme.surfaceRaised.opacity(0.76))
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0),
                                Color.white.opacity(0.10),
                                Color.white.opacity(0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.72)
                        .offset(x: -proxy.size.width * 0.72 + proxy.size.width * 1.72 * phase)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
                .frame(width: width, height: height)
        }
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
