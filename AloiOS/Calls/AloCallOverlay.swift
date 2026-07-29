import SwiftUI
import UIKit
import WebRTC

private enum AloCallVisualPalette {
    static func colors(for call: AloDirectCallState) -> [Color] {
        switch call.phase {
        case .reconnecting, .noAnswer, .interrupted, .busy, .declined:
            return [
                Color(red: 0.54, green: 0.19, blue: 0.72),
                Color(red: 0.34, green: 0.10, blue: 0.56),
                Color(red: 0.25, green: 0.10, blue: 0.39)
            ]
        case .outgoing, .incoming, .connecting, .active:
            if call.isMuted {
                return [
                    Color(red: 0.00, green: 0.50, blue: 1.00),
                    Color(red: 0.00, green: 0.69, blue: 0.94),
                    Color(red: 0.08, green: 0.24, blue: 0.52)
                ]
            }
            return [
                Color(red: 0.13, green: 0.76, blue: 0.35),
                Color(red: 0.02, green: 0.59, blue: 0.48),
                Color(red: 0.08, green: 0.34, blue: 0.27)
            ]
        }
    }
}

private enum AloCallLayoutMetrics {
    static let activeButtonDiameter: CGFloat = 60
    static let incomingButtonDiameter: CGFloat = 72
    static let buttonLabelSize: CGFloat = 13
    static let controlsBottomSpacing: CGFloat = 36
    static let peerAvatarSize: CGFloat = 126
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
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .identity
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: coordinator.activeCall?.id) { _, _ in
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

        return ZStack {
            callStateBackground(call)

            if videoLayout.showsPrimaryVideo {
                AloCallVideoRenderer(
                    coordinator: coordinator,
                    isLocal: videoLayout.primaryIsLocal,
                    mirrored: videoLayout.primaryIsLocal
                        && call.isFrontCamera
                        && !call.isScreenSharing
                )
                .id(
                    "call-primary-\(call.id)-"
                        + (videoLayout.primaryIsLocal ? "local" : "remote")
                )
                .accessibilityIdentifier("alo.call-video-primary")

            }

            if videoLayout.showsPreview {
                callVideoPreview(
                    isLocal: videoLayout.previewIsLocal,
                    mirrored: videoLayout.previewIsLocal
                        && call.isFrontCamera
                        && !call.isScreenSharing,
                    canSwap: call.hasLocalVideo
                        && call.hasRemoteVideo,
                    safeAreaInsets: safeAreaInsets
                )
                .id(
                    "call-preview-\(call.id)-"
                        + (videoLayout.previewIsLocal ? "local" : "remote")
                )
                .accessibilityIdentifier("alo.call-video-preview")
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
                    .padding(.top, safeAreaInsets.top + 18)
                    .padding(.horizontal, 24)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .top
                    )
                    .zIndex(6)
            }

            VStack(spacing: 16) {
                Spacer(minLength: 18)

                if videoLayout.showsIdentity {
                    AloAvatar(
                        name: call.peer.name,
                        url: call.peer.avatarURL,
                        size: AloCallLayoutMetrics.peerAvatarSize,
                        colorSeed: String(call.peer.id)
                    )
                    .accessibilityIdentifier("alo.call-peer-avatar")
                }

                VStack(spacing: 8) {
                    Text(call.peer.name)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    callStatus(call)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                .padding(
                    .horizontal,
                    videoLayout.showsPrimaryVideo ? 118 : 0
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("alo.call-peer-identity")

                Spacer()

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
                    .padding(.bottom, safeAreaInsets.bottom + 142)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottom
                    )
                    .allowsHitTesting(false)
                    .zIndex(5)
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
        .animation(.easeInOut(duration: 0.32), value: call.phase)
        .animation(.easeInOut(duration: 0.32), value: call.isMuted)
        .animation(
            .interactiveSpring(response: 0.34, dampingFraction: 0.86),
            value: isSafetyDetailsPresented
        )
        .animation(.easeInOut(duration: 0.28), value: call.hasRemoteVideo)
        .frame(width: viewportWidth, height: viewportHeight)
        .clipShape(
            RoundedRectangle(
                cornerRadius: surfaceCornerRadius,
                style: .continuous
            )
        )
        .offset(y: callDragOffset)
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
                        .interactiveSpring(
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
                        Text(call.safetyEmojis.joined(separator: "  "))
                            .font(.system(size: 22))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Capsule())
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

    private func callStateBackground(_ call: AloDirectCallState) -> LinearGradient {
        return LinearGradient(
            colors: AloCallVisualPalette.colors(for: call),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func callVideoPreview(
        isLocal: Bool,
        mirrored: Bool,
        canSwap: Bool,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        AloCallVideoRenderer(
            coordinator: coordinator,
            isLocal: isLocal,
            mirrored: mirrored
        )
            .frame(width: 112, height: 164)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 18, y: 8)
            .padding(.trailing, 18)
            .padding(.top, safeAreaInsets.top + 54)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture {
                guard canSwap else { return }
                withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.82)) {
                    isLocalVideoPrimary.toggle()
                }
            }
            .accessibilityAddTraits(canSwap ? .isButton : [])
            .accessibilityLabel(
                canSwap
                    ? "Поменять местами камеры"
                    : (isLocal ? "Ваша камера" : "Камера собеседника")
            )
    }

    private func callStatus(_ call: AloDirectCallState) -> some View {
        Group {
            switch call.phase {
            case .incoming:
                Text(call.isVideo ? "Входящий видеозвонок" : "Входящий звонок")
            case .outgoing:
                Text("Вызов...")
            case .connecting:
                Text("Соединение...")
            case .reconnecting:
                Text("Восстановление связи...")
            case .active:
                TimelineView(.periodic(from: call.startedAt ?? Date(), by: 1)) { context in
                    Text(callDuration(from: call.startedAt, now: context.date))
                        .monospacedDigit()
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
        HStack(spacing: 0) {
            AloCallRoundButton(
                systemName: call.isMuted ? "mic.slash.fill" : "mic.fill",
                title: "Микрофон",
                color: .white,
                foreground: .black,
                diameter: AloCallLayoutMetrics.activeButtonDiameter,
                isEnabled: isEnabled,
                action: coordinator.toggleMute
            )
            .accessibilityIdentifier("alo.call-microphone")
            AloCallRoundButton(
                systemName: call.isSpeakerOn ? "speaker.wave.2.fill" : "iphone",
                title: call.isSpeakerOn ? "Динамик" : "Телефон",
                color: call.isSpeakerOn ? Color.white : Color.white.opacity(0.16),
                foreground: call.isSpeakerOn ? .black : .white,
                diameter: AloCallLayoutMetrics.activeButtonDiameter,
                isTranslucent: !call.isSpeakerOn,
                isEnabled: isEnabled,
                action: coordinator.toggleSpeaker
            )
            .accessibilityIdentifier("alo.call-speaker")
            AloCallRoundButton(
                systemName: coordinator.isCameraStarting
                    ? "hourglass"
                    : (call.isVideoEnabled ? "video.fill" : "video.slash.fill"),
                title: coordinator.isCameraStarting ? "Камера..." : "Камера",
                color: call.isVideoEnabled ? Color.white : Color.white.opacity(0.16),
                foreground: call.isVideoEnabled ? .black : .white,
                diameter: AloCallLayoutMetrics.activeButtonDiameter,
                isTranslucent: !call.isVideoEnabled,
                isEnabled: isEnabled,
                action: {
                    if call.isVideoEnabled && !call.isScreenSharing {
                        coordinator.toggleVideo()
                    } else {
                        videoSourcePickerInitialSource = call.isFrontCamera
                            ? .frontCamera
                            : .backCamera
                        isVideoSourcePickerPresented = true
                    }
                }
            )
            .accessibilityIdentifier("alo.call-camera")
            AloCallRoundButton(
                systemName: coordinator.isScreenShareStarting
                    ? "hourglass"
                    : (call.isScreenSharing ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle"),
                title: "Экран",
                color: call.isScreenSharing ? Color.white : Color.white.opacity(0.16),
                foreground: call.isScreenSharing ? .black : .white,
                diameter: AloCallLayoutMetrics.activeButtonDiameter,
                isTranslucent: !call.isScreenSharing,
                isEnabled: isEnabled,
                action: coordinator.toggleScreenShare
            )
            .accessibilityIdentifier("alo.call-screen-share")
            AloCallRoundButton(
                systemName: "phone.down.fill",
                title: "Завершить",
                color: Color(red: 0.85, green: 0.14, blue: 0.15),
                diameter: AloCallLayoutMetrics.activeButtonDiameter,
                isEnabled: isEnabled,
                action: coordinator.end
            )
            .accessibilityIdentifier("alo.call-end")
        }
        .frame(height: 84)
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
    }

    private func callMinimizeGesture(
        callID: Int,
        viewportHeight: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard !isCallTransitionCompleting,
                      !isVideoSourcePickerPresented else {
                    return
                }
                let vertical = abs(value.translation.height)
                guard vertical > abs(value.translation.width) * 1.08 else { return }
                isCallDragActive = true
                callDragOffset = min(
                    max(value.translation.height, -viewportHeight),
                    viewportHeight
                )
            }
            .onEnded { value in
                guard isCallDragActive, !isCallTransitionCompleting else { return }
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
        withAnimation(
            .spring(response: 0.34, dampingFraction: 1.0),
            completionCriteria: .logicallyComplete
        ) {
            callDragOffset = 0
        } completion: {
            isCallTransitionCompleting = false
        }
    }

    private func minimizeCall(
        callID: Int,
        viewportHeight: CGFloat,
        direction: CGFloat
    ) {
        let targetOffset = max(1, viewportHeight) * direction
        withAnimation(
            .spring(response: 0.38, dampingFraction: 1.0),
            completionCriteria: .logicallyComplete
        ) {
            callDragOffset = targetOffset
        } completion: {
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

    private var isMicrophoneActive: Bool {
        !call.isMuted && !isConnectionInterrupted
    }

    private var isConnectionInterrupted: Bool {
        call.phase == .reconnecting || call.phase.isTerminal
    }

    private var backgroundColors: [Color] {
        Array(AloCallVisualPalette.colors(for: call).prefix(2))
    }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                coordinator.isMinimized = false
            }
        } label: {
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
                        .contentTransition(.symbolEffect(.replace))

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
        .animation(.easeInOut(duration: 0.28), value: call.isMuted)
        .animation(.easeInOut(duration: 0.28), value: call.phase)
        .accessibilityIdentifier("alo.compact-call-bar")
        .accessibilityLabel("Вернуться к звонку с \(call.peer.name)")
        .accessibilityValue(
            call.phase.isTerminal
                ? compactTerminalAccessibilityValue
                : (call.isMuted ? "Микрофон выключен" : "Микрофон включён")
        )
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

private struct AloCallStatusWave: View {
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isActive)) { timeline in
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
        .animation(.easeInOut(duration: 0.24), value: isActive)
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
    let systemName: String
    let title: String
    let color: Color
    var foreground: Color = .white
    var diameter: CGFloat = AloCallLayoutMetrics.activeButtonDiameter
    var isTranslucent = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: diameter < 70 ? 5 : 8) {
                ZStack {
                    if isTranslucent {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Circle()
                                    .fill(Color.white.opacity(0.06))
                            }
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
                        .contentTransition(.symbolEffect(.replace))
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
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(AloCallRoundButtonStyle())
        .disabled(!isEnabled)
        .animation(.easeInOut(duration: 0.24), value: systemName)
        .animation(.easeInOut(duration: 0.24), value: color)
    }
}

private struct AloCallRoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(
                .spring(
                    response: configuration.isPressed ? 0.30 : 0.50,
                    dampingFraction: 0.72
                ),
                value: configuration.isPressed
            )
    }
}

struct AloCallVideoRenderer: UIViewRepresentable {
    let coordinator: AloCallCoordinator
    let isLocal: Bool
    let mirrored: Bool

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
        view.transform = mirrored
            ? CGAffineTransform(scaleX: -1, y: 1)
            : .identity
        if isLocal {
            coordinator.bindLocalRenderer(view)
        } else {
            coordinator.bindRemoteRenderer(view)
        }
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        let target = mirrored
            ? CGAffineTransform(scaleX: -1, y: 1)
            : .identity
        guard uiView.transform != target else { return }
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut]
        ) {
            uiView.transform = target
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator context: Coordinator) {
        if context.isLocal {
            context.callCoordinator?.unbindLocalRenderer(uiView)
        } else {
            context.callCoordinator?.unbindRemoteRenderer(uiView)
        }
    }
}
