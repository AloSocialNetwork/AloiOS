import SwiftUI
import UIKit

struct MainTabView: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chatPreviewPresented = false
    @Namespace private var tabSelection

    var body: some View {
        NavigationStack {
            mainContent
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: commentsPresented) {
                    AloPostDetailScreen().environmentObject(app)
                }
        }
        .alert("Alo", isPresented: errorBinding) {
            if app.shouldOfferAppSettings {
                Button("Настройки") {
                    app.errorMessage = ""
                    app.shouldOfferAppSettings = false
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                Button("Отмена", role: .cancel) {
                    app.errorMessage = ""
                    app.shouldOfferAppSettings = false
                }
            } else {
                Button("Ок") { app.errorMessage = "" }
            }
        } message: {
            Text(app.errorMessage)
        }
        .onChange(of: app.activeTab) { _, tab in app.refreshForTabIfNeeded(tab) }
    }

    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch app.activeTab {
                case .feed:
                    FeedView()
                case .search:
                    SearchView()
                case .messages:
                    MessagesView(bottomBar: AnyView(bottomBar
                        .padding(.horizontal, 16).padding(.bottom, 2)))
                case .alerts:
                    AlertsView()
                case .profile:
                    ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if app.activeTab != .messages {
                AloSocialBottomShade()
                    .frame(height: 110)
                    .opacity(chatPreviewPresented ? 0 : 1)
                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
                    .opacity(chatPreviewPresented ? 0 : 1)
                    .allowsHitTesting(!chatPreviewPresented && !profileCoversTabBar)
                    .modifier(AloCoveredFromAccessibility(covered: chatPreviewPresented || profileCoversTabBar))
                    .animation(.easeOut(duration: 0.16), value: chatPreviewPresented)
            }

            if app.isProfileLoading {
                ProgressView()
                    .tint(AloTheme.accent)
                    .frame(width: 54, height: 54)
                    .background(AloTheme.surface)
                    .clipShape(Circle())
                    .transition(.scale.combined(with: .opacity))
            }

            if let profile = app.selectedProfile {
                ProfileDetailView(profile: profile)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                    .zIndex(20)
            }

            if let channel = app.selectedChannelProfile {
                ChannelProfileDetailView(channel: channel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                    .zIndex(21)
            }
        }
        .ignoresSafeArea(
            app.activeTab == .messages && app.activeConversation != nil ? .keyboard : [],
            edges: .bottom
        )
        .background(AloTheme.background.ignoresSafeArea(.container))
        .onPreferenceChange(AloChatPreviewPresentedKey.self) { chatPreviewPresented = $0 }
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: app.selectedProfile?.id)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: app.selectedChannelProfile?.id)
        .animation(.spring(response: 0.24, dampingFraction: 0.9), value: app.isProfileLoading)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach(AloAppTab.allCases) { tab in
                Button {
                    select(tab)
                } label: {
                    VStack(spacing: 2) {
                        ZStack {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 22, weight: .regular))
                        }
                        .frame(height: 28)

                        Text(tab.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(app.activeTab == tab ? AloTheme.accent : AloTheme.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background {
                        // One highlight travels between tabs, like the segmented controls.
                        if app.activeTab == tab {
                            Capsule().fill(.white.opacity(0.10))
                                .matchedGeometryEffect(id: "tab.selection", in: tabSelection)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(AloControlPressStyle())
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(app.activeTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 60)
        // Glass only: media stays visible under the bar. No opaque fill behind it.
        .modifier(AloChatGlass(interactive: false, role: .chrome))
    }

    /// A profile opened on top covers the tab bar.
    private var profileCoversTabBar: Bool {
        app.selectedProfile != nil || app.selectedChannelProfile != nil
    }

    private func select(_ tab: AloAppTab) {
        guard app.activeTab != tab else { return }

        guard !reduceMotion else {
            app.activeTab = tab
            return
        }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.92, blendDuration: 0.06)) {
            app.activeTab = tab
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { !app.errorMessage.isEmpty && app.phase == .app },
            set: {
                if !$0 {
                    app.errorMessage = ""
                    app.shouldOfferAppSettings = false
                }
            }
        )
    }

    private var commentsPresented: Binding<Bool> {
        Binding(
            get: { app.commentsPost != nil },
            set: { presented in
                if !presented {
                    app.closeComments()
                }
            }
        )
    }
}

/// Hides a control that something opaque currently covers (the tab bar behind a chat or a
/// profile) from VoiceOver.
struct AloCoveredFromAccessibility: ViewModifier {
    let covered: Bool

    func body(content: Content) -> some View {
        content.accessibilityHidden(covered)
    }
}
