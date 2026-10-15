import SwiftUI
import UIKit
import WebRTC

enum AloCallLayoutMetrics {
    // Telegram CallScreen/ButtonGroupView's active control diameter.
    static let activeButtonDiameter: CGFloat = 56
    static let incomingButtonDiameter: CGFloat = 72
    static let buttonLabelSize: CGFloat = 13
    // The 84 pt row includes a 56 pt circle + label. This backing inset
    // leaves the circle itself 52 pt above the safe bottom, like ButtonGroupView.
    static let controlsBottomSpacing: CGFloat = 28
    static let activeControlBottomInset: CGFloat = 52
    static let noticeGap: CGFloat = 16
    static let peerAvatarSize: CGFloat = 136
    static let activeButtonSpacing: CGFloat = 36

    static func controlSpacing(availableWidth: CGFloat) -> CGFloat {
        max(0, min(activeButtonSpacing, (availableWidth - 4 * activeButtonDiameter) / 3))
    }
}

private enum AloCallSafeArea {
    static func resolved(_ proposed: EdgeInsets) -> EdgeInsets {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else {
            return proposed
        }

        return EdgeInsets(
            top: max(proposed.top, window.safeAreaInsets.top),
            leading: max(proposed.leading, window.safeAreaInsets.left),
            bottom: max(proposed.bottom, window.safeAreaInsets.bottom),
            trailing: max(proposed.trailing, window.safeAreaInsets.right)
        )
    }
}

struct AloCallOverlay: View {
    @ObservedObject var coordinator: AloCallCoordinator
    @State private var callDragOffset: CGFloat = 0
    @State private var isCallDragActive = false
    @State private var isCallTransitionCompleting = false
    @State private var callTransitionRevision = 0
    @State private var callGestureRejected = false
    @State private var callGestureExclusions: [CGRect] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLocalVideoPrimary = false
    @State private var isSafetyDetailsPresented = false
    @State private var isVideoSourcePickerPresented = false
    @State private var videoSourcePickerInitialSource:
        AloCallVideoSource = .frontCamera

    var body: some View {
        Group {
            if let call = coordinator.activeCall, !coordinator.isMinimized {
                GeometryReader { geometry in
                    let safeAreaInsets = AloCallSafeArea.resolved(
                        geometry.safeAreaInsets
                    )
                    callScreen(
                        call,
                        safeAreaInsets: safeAreaInsets,
                        viewportWidth: geometry.size.width,
                        viewportHeight: geometry.size.height
                    )
                }
                .ignoresSafeArea()
                .transition(
                    .asymmetric(
                        insertion: reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity),
                        removal: .identity
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: coordinator.activeCall?.id) { _, _ in
            callTransitionRevision += 1
            callDragOffset = 0
            isCallDragActive = false
            isCallTransitionCompleting = false
            isLocalVideoPrimary = false
            isSafetyDetailsPresented = false
            isVideoSourcePickerPresented = false
            coordinator.cancelVideoSourcePreview()
        }
        .onChange(of: coordinator.activeCall?.hasRemoteVideo) { _, hasRemoteVideo in
            if hasRemoteVideo != true {
                isLocalVideoPrimary = false
            }
        }
        .onChange(of: coordinator.activeCall?.hasLocalVideo) { _, hasLocalVideo in
            if hasLocalVideo != true {
                isLocalVideoPrimary = false
            }
        }
        .onChange(of: coordinator.isMinimized) { _, minimized in
            if !minimized {
                callTransitionRevision += 1
                callDragOffset = 0
                isCallDragActive = false
                isCallTransitionCompleting = false
            } else if isVideoSourcePickerPresented {
                isVideoSourcePickerPresented = false
                coordinator.cancelVideoSourcePreview()
            }
        }
    }

    private func callScreen(
        _ call: AloDirectCallState,
        safeAreaInsets: EdgeInsets,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat
    ) -> some View {
        let surfaceCornerRadius: CGFloat = isCallDragActive
            || isCallTransitionCompleting ? 48 : 0
        let videoLayout = AloCallVideoLayout.resolve(
            phase: call.phase,
            hasLocalVideo: call.hasLocalPreviewVideo,
            hasRemoteVideo: call.hasRemoteVideo,
            prefersLocalPrimary: isLocalVideoPrimary
        )

        // Telegram's layout: the avatar's top sits 39 + 136 pt above 49 % of the height, the name
        // 39 pt under it, the status 4 pt under the name.
        let avatarTop = max(safeAreaInsets.top + 8,
                            floor(viewportHeight * 0.49) - 39 - AloCallLayoutMetrics.peerAvatarSize)

        return ZStack {
            AloCallLiveBackdrop(meter: coordinator.meter, phase: call.phase,
                                animated: !reduceMotion && !videoLayout.showsPrimaryVideo)

            // Identity follows the track, not its primary/preview role. A swap
            // changes geometry without allocating/rebinding two Metal renderers.
            ForEach([true, false], id: \.self) { isLocal in
                if videoLayout.renders(isLocal: isLocal) {
                    callVideoSurface(call, isLocal: isLocal,
                        isPrimary: videoLayout.isPrimary(isLocal: isLocal),
                        safeAreaInsets: safeAreaInsets,
                        viewport: CGSize(width: viewportWidth, height: viewportHeight))
                }
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(
                        videoLayout.showsPrimaryVideo ? 0.46 : 0.08
                    ),
                    Color.clear,
                    Color.black.opacity(
                        videoLayout.showsPrimaryVideo ? 0.68 : 0.22
                    )
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if call.isSecurityConfirmed, !call.safetyEmojis.isEmpty {
                safetyVerification(call)
                    // The expanded card sits below the minimize button, not over it.
                    .padding(.top, safeAreaInsets.top + (isSafetyDetailsPresented ? 60 : 18))
                    .padding(.horizontal, 24)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .top
                    )
                    .zIndex(6)
            }

            VStack(spacing: 0) {
                if videoLayout.showsIdentity {
                    Color.clear.frame(height: max(0, avatarTop - safeAreaInsets.top - 8))
                    AloCallLiveAvatar(
                        meter: coordinator.meter,
                        call: call,
                        animated: !reduceMotion
                    )
                    .padding(.bottom, 39)
                }

                VStack(spacing: 4) {
                    Text(call.peer.name)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    AloCallLiveStatus(meter: coordinator.meter, content: statusContent(call),
                                      animated: !reduceMotion)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.white)
                        .id(call.phase)
                        .transition(.opacity)
                }
                .padding(
                    .horizontal,
                    videoLayout.showsPrimaryVideo ? 118 : 0
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("alo.call-peer-identity")

                Spacer(minLength: 16)

                if call.phase.isTerminal {
                    activeControls(call, isEnabled: false)
                } else if call.phase == .incoming {
                    incomingControls
                } else {
                    activeControls(call)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, safeAreaInsets.top + 8)
            .padding(
                .bottom,
                safeAreaInsets.bottom
                    + AloCallLayoutMetrics.controlsBottomSpacing
            )

            if call.phase != .incoming, !call.phase.isTerminal {
                callNotices(call)
                    .padding(.bottom, safeAreaInsets.bottom + AloCallLayoutMetrics.activeControlBottomInset
                        + AloCallLayoutMetrics.activeButtonDiameter + AloCallLayoutMetrics.noticeGap)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottom
                    )
                    .allowsHitTesting(false)
                    .zIndex(5)
            }

            if !isVideoSourcePickerPresented {
                Button {
                    minimizeCall(callID: call.id, viewportHeight: viewportHeight, direction: -1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .modifier(AloChatGlass(interactive: false, role: .chrome))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AloControlPressStyle())
                .accessibilityLabel("Свернуть звонок")
                .accessibilityIdentifier("alo.call.minimize")
                .padding(.top, safeAreaInsets.top + 8)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(7)
            }

            if isVideoSourcePickerPresented {
                AloCallVideoSourcePicker(
                    coordinator: coordinator,
                    call: call,
                    initialSource: videoSourcePickerInitialSource,
                    safeAreaInsets: safeAreaInsets,
                    cancel: {
                        isVideoSourcePickerPresented = false
                    },
                    commit: { source in
                        isVideoSourcePickerPresented = false
                        coordinator.commitVideoSource(source)
                    }
                )
                .zIndex(20)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 1), value: call.phase)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: call.isMuted)
        .animation(
            reduceMotion ? nil : .interactiveSpring(response: 0.34, dampingFraction: 0.86),
            value: isSafetyDetailsPresented
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: call.hasRemoteVideo)
        .frame(width: viewportWidth, height: viewportHeight)
        .clipShape(
            RoundedRectangle(
                cornerRadius: surfaceCornerRadius,
                style: .continuous
            )
        )
        .offset(y: callDragOffset)
        .onPreferenceChange(AloBackSwipeExclusionKey.self) { callGestureExclusions = $0 }
        .simultaneousGesture(
            callMinimizeGesture(
                callID: call.id,
                viewportHeight: viewportHeight
            )
        )
        .zIndex(100)
    }

    @ViewBuilder
    private func callNotices(_ call: AloDirectCallState) -> some View {
        VStack(spacing: 8) {
            if call.isScreenSharing || call.isRemoteScreenSharing {
                Label(
                    call.isScreenSharing
                        ? "Вы показываете экран"
                        : "Демонстрация экрана",
                    systemImage: "rectangle.on.rectangle"
                )
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(
                    .move(edge: .bottom)
                        .combined(with: .opacity)
                )
                .accessibilityIdentifier("alo.call-screen-share-notice")
            }

            if call.isMuted {
                Label("Вы выключили микрофон", systemImage: "mic.slash.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                    )
                    .accessibilityIdentifier("alo.call-muted-notice")
            }
        }
    }

    private func safetyVerification(_ call: AloDirectCallState) -> some View {
        Group {
            if call.isSecurityConfirmed, !call.safetyEmojis.isEmpty {
                Button {
                    withAnimation(
                        reduceMotion ? nil : .interactiveSpring(
                            response: 0.38,
                            dampingFraction: 0.82
                        )
                    ) {
                        isSafetyDetailsPresented.toggle()
                    }
                } label: {
                    if isSafetyDetailsPresented {
                        VStack(spacing: 13) {
                            Text(call.safetyEmojis.joined(separator: "  "))
                                .font(.system(size: 32))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            Text("Звонок защищён сквозным шифрованием")
                                .font(.system(size: 16, weight: .bold))
                                .multilineTextAlignment(.center)

                            Text(
                                "Если \(call.peer.name) видит те же эмодзи, "
                                    + "звонок защищён."
                            )
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.76))
                            .multilineTextAlignment(.center)

                            Divider()
                                .overlay(Color.white.opacity(0.14))

                            Text("ОК")
                                .font(.system(size: 16, weight: .bold))
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 330)
                        .background(.ultraThinMaterial)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 24,
                                style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: 24,
                                style: .continuous
                            )
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        }
                        .transition(
                            .scale(scale: 0.86, anchor: .top)
                                .combined(with: .opacity)
                        )
                    } else {
                        AloCallEmojiKey(emojis: call.safetyEmojis, reduceMotion: reduceMotion)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .modifier(AloChatGlass(interactive: false, role: .chrome))
                            .contentShape(Capsule())
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Код безопасности звонка")
                            .transition(
                                .scale(scale: 0.9)
                                    .combined(with: .opacity)
                            )
                    }
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))
                .accessibilityIdentifier("alo.call-safety-verification")
                .accessibilityLabel(
                    isSafetyDetailsPresented
                        ? "Закрыть проверку шифрования"
                        : "Проверить шифрование звонка"
                )
            }
        }
    }

    private func callVideoSurface(
        _ call: AloDirectCallState,
        isLocal: Bool,
        isPrimary: Bool,
        safeAreaInsets: EdgeInsets,
        viewport: CGSize
    ) -> some View {
        let canSwap = call.hasLocalPreviewVideo && call.hasRemoteVideo
        let size = isPrimary ? viewport : CGSize(width: 112, height: 164)
        let radius: CGFloat = isPrimary ? 0 : 22
        let center = isPrimary ? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
            : CGPoint(x: viewport.width - 18 - size.width / 2,
                      y: safeAreaInsets.top + 54 + size.height / 2)

        return AloCallVideoRenderer(
            coordinator: coordinator,
            isLocal: isLocal,
            mirrored: isLocal && call.isFrontCamera && !call.isScreenSharing,
            transitioning: isLocal
                && (coordinator.isCameraStarting || coordinator.isCameraSwitching)
        )
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(isPrimary ? 0 : 0.18), lineWidth: 1)
            )
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.black).shadow(color: .black.opacity(isPrimary ? 0 : 0.35), radius: 18, y: 8)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .aloBackSwipeExclusion(enabled: !isPrimary)
            .onTapGesture {
                guard !isPrimary else { return }
                if canSwap {
                    withAnimation(
                        reduceMotion ? nil : .easeInOut(duration: 0.25)
                    ) {
                        isLocalVideoPrimary.toggle()
                    }
                } else if isLocal {
                    presentVideoSourcePicker(for: call)
                }
            }
            .onLongPressGesture(minimumDuration: 0.32) {
                guard isLocal, !isPrimary else { return }
                presentVideoSourcePicker(for: call)
            }
            .accessibilityAddTraits(!isPrimary && (canSwap || isLocal) ? .isButton : [])
            .accessibilityLabel(
                !isPrimary && canSwap
                    ? "Поменять местами камеры"
                    : (isLocal ? "Ваша камера" : "Камера собеседника")
            )
            .accessibilityIdentifier(isPrimary ? "alo.call-video-primary" : "alo.call-video-preview")
            .accessibilityValue(isLocal ? "local" : "remote")
            .position(center)
            .zIndex(isPrimary ? 0 : 4)
    }

    private func statusContent(_ call: AloDirectCallState) -> AloCallStatusLine.Content {
        switch call.phase {
        case .incoming: return .waiting(call.isVideo ? "Входящий видеозвонок" : "Входящий звонок")
        case .outgoing: return .waiting("Вызов")
        case .connecting: return .waiting("Соединение")
        case .reconnecting: return .waiting("Восстановление связи")
        case .active: return .talking(since: call.startedAt, quality: nil)
        case .noAnswer: return .final("Нет ответа")
        case .interrupted: return .final("Связь прервана")
        case .busy: return .final("Занято")
        case .declined: return .final("Вызов отклонён")
        }
    }

    private var incomingControls: some View {
        HStack(spacing: 115) {
            AloCallRoundButton(
                systemName: "phone.down.fill",
                title: "Отклонить",
                color: Color(red: 0.85, green: 0.14, blue: 0.15),
                diameter: AloCallLayoutMetrics.incomingButtonDiameter
            ) {
                Task { await coordinator.decline() }
            }
            AloCallRoundButton(
                systemName: "phone.fill",
                title: "Ответить",
                color: Color(red: 0.45, green: 0.86, blue: 0.35),
                diameter: AloCallLayoutMetrics.incomingButtonDiameter
            ) {
                coordinator.accept()
            }
        }
        .frame(height: 98)
        .frame(maxWidth: .infinity)
    }

    private func activeControls(
        _ call: AloDirectCallState,
        isEnabled: Bool = true
    ) -> some View {
        GeometryReader { geometry in
        HStack(spacing: AloCallLayoutMetrics.controlSpacing(availableWidth: geometry.size.width)) {
            AloCallRoundButton(
                systemName: call.isSpeakerOn ? "speaker.wave.2.fill" : "iphone",
                title: call.isSpeakerOn ? "Динамик" : "Телефон",
                color: call.isSpeakerOn ? Color.white : Color.white.opacity(0.16),
                foreground: call.isSpeakerOn ? .black : .white,
                diameter: AloCallLayoutMetrics.activeButtonDiameter,
                slotWidth: AloCallLayoutMetrics.activeButtonDiameter,
                isTranslucent: !call.isSpeakerOn,
                isEnabled: isEnabled,
                action: coordinator.toggleSpeaker
            )
            .accessibilityIdentifier("alo.call-speaker")
            AloCallRoundButton(
                systemName: coordinator.isCameraStarting
                    || coordinator.isScreenShareStarting
                    ? "hourglass"
                    : (
                        call.isScreenSharing
                            ? "rectangle.on.rectangle.fill"
                            : (call.isVideoEnabled ? "video.fill" : "video.slash.fill")
                    ),
                title: coordinator.isCameraStarting
                    || coordinator.isScreenShareStarting
                    ? "Подготовка..."
                    : (call.isScreenSharing ? "Экран" : "Видео"),
                color: call.hasLocalVideo
                    ? Color.white
                    : Color.white.opacity(0.16),
                foreground: call.hasLocalVideo ? .black : .white,
                diameter: AloCallLayoutMetrics.activeButtonDiameter,
                slotWidth: AloCallLayoutMetrics.activeButtonDiameter,
                isTranslucent: !call.hasLocalVideo,
                isEnabled: isEnabled,
                action: {
                    switch AloCallVideoControlAction.resolve(for: call) {
                    case .presentSources:
                        presentVideoSourcePicker(for: call)
                    case .disableCamera:
                        coordinator.toggleVideo()
                    case .stopScreenShare:
                        coordinator.toggleScreenShare()
                    }
                }
            )
            .accessibilityIdentifier("alo.call-camera")
            AloCallRoundButton(
                systemName: call.isMuted ? "mic.slash.fill" : "mic.fill",
                title: call.isMuted ? "Включить звук" : "Убрать звук",
                color: call.isMuted ? .white : Color.white.opacity(0.16),
                foreground: call.isMuted ? .black : .white,
                diameter: AloCallLayoutMetrics.activeButtonDiameter,
                slotWidth: AloCallLayoutMetrics.activeButtonDiameter,
                isTranslucent: !call.isMuted,
                isEnabled: isEnabled,
                action: coordinator.toggleMute
            )
            .accessibilityIdentifier("alo.call-microphone")
            AloCallRoundButton(
                systemName: "phone.down.fill",
                title: "Завершить",
                color: Color(red: 0.85, green: 0.14, blue: 0.15),
                diameter: AloCallLayoutMetrics.activeButtonDiameter,
                slotWidth: AloCallLayoutMetrics.activeButtonDiameter,
                isEnabled: isEnabled,
                action: coordinator.end
            )
            .accessibilityIdentifier("alo.call-end")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 84)
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
    }

    private func presentVideoSourcePicker(for call: AloDirectCallState) {
        guard !isVideoSourcePickerPresented else { return }
        videoSourcePickerInitialSource = .current(for: call)
        isVideoSourcePickerPresented = true
    }

    private func callMinimizeGesture(
        callID: Int,
        viewportHeight: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard !callGestureRejected, !isVideoSourcePickerPresented else {
                    return
                }
                let vertical = abs(value.translation.height)
                if !isCallDragActive {
                    guard !callGestureExclusions.contains(where: { $0.contains(value.startLocation) }),
                          vertical > abs(value.translation.width) * 1.4 else {
                        callGestureRejected = true
                        return
                    }
                    callTransitionRevision += 1
                    isCallTransitionCompleting = false
                    isCallDragActive = true
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    callDragOffset = min(max(value.translation.height, -viewportHeight), viewportHeight)
                }
            }
            .onEnded { value in
                callGestureRejected = false
                guard isCallDragActive else { return }
                isCallDragActive = false
                let predicted = value.predictedEndTranslation.height
                let shouldMinimize = AloCallMinimizePolicy.shouldMinimize(
                    translation: value.translation.height,
                    predictedTranslation: predicted,
                    viewportHeight: viewportHeight
                )
                if shouldMinimize {
                    isCallTransitionCompleting = true
                    minimizeCall(
                        callID: callID,
                        viewportHeight: viewportHeight,
                        direction: AloCallMinimizePolicy.direction(
                            translation: value.translation.height,
                            predictedTranslation: predicted
                        )
                    )
                } else {
                    restoreCallSurface()
                }
            }
    }

    private func restoreCallSurface() {
        isCallTransitionCompleting = true
        let revision = callTransitionRevision
        withAnimation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 1.0),
            completionCriteria: .logicallyComplete
        ) {
            callDragOffset = 0
        } completion: {
            guard revision == callTransitionRevision else { return }
            isCallTransitionCompleting = false
        }
    }

    private func minimizeCall(
        callID: Int,
        viewportHeight: CGFloat,
        direction: CGFloat
    ) {
        callTransitionRevision += 1
        let revision = callTransitionRevision
        isCallTransitionCompleting = true
        let targetOffset = max(1, viewportHeight) * direction
        withAnimation(
            reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 1.0),
            completionCriteria: .logicallyComplete
        ) {
            callDragOffset = targetOffset
        } completion: {
            guard revision == callTransitionRevision else { return }
            guard coordinator.activeCall?.id == callID else {
                isCallTransitionCompleting = false
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                coordinator.isMinimized = true
                callDragOffset = 0
                isCallTransitionCompleting = false
            }
        }
    }

    private func callDuration(from startedAt: Date?, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt ?? now)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct AloCallCompactBar: View {
    let call: AloDirectCallState
    @ObservedObject var coordinator: AloCallCoordinator
    let statusBarHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isMicrophoneActive: Bool {
        !call.isMuted && !isConnectionInterrupted
    }

    private var isConnectionInterrupted: Bool {
        call.phase == .reconnecting || call.phase.isTerminal
    }

    private var backgroundColors: [Color] {
        AloCallBackdropPalette.resolve(phase: call.phase, quality: nil).barColors
    }

    var body: some View {
        Button(action: expand) {
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: backgroundColors,
                    startPoint: .leading,
                    endPoint: .trailing
                )

                AloCallStatusWave(
                    isActive: isMicrophoneActive && coordinator.isMinimized
                )

                HStack(spacing: 5) {
                    Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 11, weight: .bold))
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))

                    Text(call.peer.name)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)

                    Group {
                        if call.phase == .active {
                            HStack(spacing: 3) {
                                Text(call.isMuted ? "Микрофон выключен" : "·")
                                    .contentTransition(.opacity)
                                compactStatus
                                    .monospacedDigit()
                            }
                        } else {
                            compactStatus
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                }
                .frame(height: 24)
                .padding(.horizontal, 72)
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: statusBarHeight)
            .clipped()
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.12))
                    .frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: call.isMuted)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: call.phase)
        // The top of the bar is the status bar, whose taps iOS keeps for itself.
        .background {
            if coordinator.isMinimized { AloStatusBarTapCatcher(action: expand) }
        }
        .accessibilityIdentifier("alo.compact-call-bar")
        .accessibilityLabel("Вернуться к звонку с \(call.peer.name)")
        .accessibilityValue(
            call.phase.isTerminal
                ? compactTerminalAccessibilityValue
                : (call.isMuted ? "Микрофон выключен" : "Микрофон включён")
        )
    }

    private func expand() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            coordinator.isMinimized = false
        }
    }

    @ViewBuilder
    private var compactStatus: some View {
        switch call.phase {
        case .incoming:
            Text("Входящий")
        case .outgoing:
            Text("Вызов...")
        case .connecting:
            Text("Соединение...")
        case .reconnecting:
            Text("Восстановление связи...")
        case .active:
            TimelineView(.periodic(from: call.startedAt ?? Date(), by: 1)) { context in
                Text(callDuration(now: context.date))
            }
        case .noAnswer:
            Text("Нет ответа")
        case .interrupted:
            Text("Связь прервана")
        case .busy:
            Text("Занято")
        case .declined:
            Text("Вызов отклонён")
        }
    }

    private var compactTerminalAccessibilityValue: String {
        switch call.phase {
        case .noAnswer:
            "Нет ответа"
        case .interrupted:
            "Связь прервана"
        case .busy:
            "Занято"
        case .declined:
            "Вызов отклонён"
        case .incoming, .outgoing, .connecting, .reconnecting, .active:
            ""
        }
    }

    private func callDuration(now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(call.startedAt ?? now)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// Telegram reveals the encryption key one emoji at a time: each drops in with a spring,
/// 0.3 s after the previous one.
private struct AloCallEmojiKey: View {
    let emojis: [String]
    let reduceMotion: Bool
    @State private var shown = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(emojis.enumerated()), id: \.offset) { index, emoji in
                Text(emoji).font(.system(size: 22))
                    .offset(y: shown || reduceMotion ? 0 : -26)
                    .opacity(shown || reduceMotion ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.78).delay(0.2 + 0.3 * Double(index)), value: shown)
            }
        }
        .onAppear { shown = true }
    }
}

/// The call's live layers, each watching the meter on its own so its seven updates a second
/// redraw only them.
private struct AloCallLiveBackdrop: View {
    @ObservedObject var meter: AloCallMeter
    let phase: AloDirectCallPhase
    let animated: Bool

    var body: some View {
        AloCallBackdrop(palette: .resolve(phase: phase, quality: meter.quality), animated: animated)
    }
}

/// The avatar breathes with the other person's voice, the blobs behind it twice as much; they
/// hide once the call is over.
private struct AloCallLiveAvatar: View {
    @ObservedObject var meter: AloCallMeter
    let call: AloDirectCallState
    let animated: Bool

    var body: some View {
        let size = AloCallLayoutMetrics.peerAvatarSize
        AloAvatar(name: call.peer.name, url: call.peer.avatarURL, size: size, colorSeed: String(call.peer.id))
            .scaleEffect(1 + min(5, meter.level) * 0.05)
            .animation(.easeOut(duration: 0.15), value: meter.level)
            .background {
                if !call.phase.isTerminal {
                    AloCallSpeakingBlobs(avatarSize: size, level: meter.level, animated: animated)
                }
            }
            .accessibilityIdentifier("alo.call-peer-avatar")
    }
}

private struct AloCallLiveStatus: View {
    @ObservedObject var meter: AloCallMeter
    let content: AloCallStatusLine.Content
    let animated: Bool

    var body: some View {
        if case .talking(let since, _) = content {
            AloCallStatusLine(content: .talking(since: since, quality: meter.quality), animated: animated)
        } else {
            AloCallStatusLine(content: content, animated: animated)
        }
    }
}

private struct AloCallStatusWave: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isActive || reduceMotion || scenePhase != .active)) { timeline in
            Canvas { context, size in
                guard isActive, size.width > 0, size.height > 0 else { return }
                let phase = timeline.date.timeIntervalSinceReferenceDate * 2.2
                context.fill(
                    wavePath(size: size, phase: phase, layer: 0),
                    with: .color(Color.white.opacity(0.11))
                )
                context.fill(
                    wavePath(size: size, phase: phase, layer: 1),
                    with: .color(Color.white.opacity(0.07))
                )
            }
        }
        .opacity(isActive ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: isActive)
        .allowsHitTesting(false)
    }

    private func wavePath(
        size: CGSize,
        phase: Double,
        layer: Int
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        let baseline = size.height * (layer == 0 ? 0.58 : 0.72)
        let amplitude = size.height * (layer == 0 ? 0.17 : 0.10)
        let frequency = layer == 0 ? 2.1 : 2.8

        for step in 0...32 {
            let progress = CGFloat(step) / 32.0
            let angle = Double(progress) * .pi * 2.0 * frequency
                + phase
                + Double(layer)
            let x = size.width * progress
            let y = baseline + CGFloat(sin(angle)) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }
}

private struct AloCallRoundButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let systemName: String
    let title: String
    let color: Color
    var foreground: Color = .white
    var diameter: CGFloat = AloCallLayoutMetrics.activeButtonDiameter
    var slotWidth: CGFloat? = nil
    var isTranslucent = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: diameter < 70 ? 5 : 8) {
                ZStack {
                    if isTranslucent {
                        // Telegram's unfilled call button: blur with a 20% white veil.
                        Color.clear
                            .frame(width: diameter, height: diameter)
                            .modifier(AloChatGlass(interactive: false, role: .chrome))
                            .overlay { Circle().fill(Color.white.opacity(0.16)) }
                    } else {
                        Circle().fill(color)
                    }

                    Image(systemName: systemName)
                        .font(
                            .system(
                                size: diameter >= 70 ? 27 : 23,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(foreground)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .frame(width: diameter, height: diameter)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                }

                Text(title)
                    .font(
                        .system(
                            size: AloCallLayoutMetrics.buttonLabelSize,
                            weight: .regular
                        )
                    )
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: slotWidth ?? .infinity)
        }
        .buttonStyle(AloCallRoundButtonStyle())
        .disabled(!isEnabled)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: systemName)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: color)
    }
}

private struct AloCallRoundButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}

struct AloCallVideoRenderer: UIViewRepresentable {
    let coordinator: AloCallCoordinator
    let isLocal: Bool
    let mirrored: Bool
    var transitioning = false

    final class Coordinator {
        weak var callCoordinator: AloCallCoordinator?
        let isLocal: Bool

        init(callCoordinator: AloCallCoordinator, isLocal: Bool) {
            self.callCoordinator = callCoordinator
            self.isLocal = isLocal
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(callCoordinator: coordinator, isLocal: isLocal)
    }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        view.transform = videoTransform
        view.alpha = transitioning ? 0.88 : 1
        if isLocal {
            coordinator.bindLocalRenderer(view)
        } else {
            coordinator.bindRemoteRenderer(view)
        }
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        let target = videoTransform
        let alpha: CGFloat = transitioning ? 0.88 : 1
        // The call timer publishes once a second. Do not restart a renderer
        // animation for an unchanged mirror/transition state on each tick.
        guard uiView.transform != target || abs(uiView.alpha - alpha) > 0.001 else { return }
        // Interpolating -1 to +1 collapses the live image to zero width halfway
        // through a lens switch. Mirror atomically; animate only the feedback.
        if uiView.transform.a * target.a < 0 {
            UIView.performWithoutAnimation { uiView.transform = target }
        }
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : transitioning ? 0.18 : 0.28,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut]
        ) {
            uiView.transform = target
            uiView.alpha = alpha
        }
    }

    private var videoTransform: CGAffineTransform {
        let scale: CGFloat = transitioning ? 1.015 : 1
        return CGAffineTransform(
            scaleX: mirrored ? -scale : scale,
            y: scale
        )
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator context: Coordinator) {
        if context.isLocal {
            context.callCoordinator?.unbindLocalRenderer(uiView)
        } else {
            context.callCoordinator?.unbindRemoteRenderer(uiView)
        }
    }
}
