import SwiftUI
import LiveKit
import WebRTC

struct AloGroupCallOverlay: View {
    @ObservedObject var coordinator: AloGroupCallCoordinator
    @State private var dragOffset: CGFloat = 0
    @State private var isCameraPickerVisible = false
    @State private var selectedCamera: AloGroupCameraSource = .front

    var body: some View {
        Group {
            if let call = coordinator.activeCall, !coordinator.isMinimized {
                GeometryReader { geometry in
                    callRoom(call, safeArea: AloCallSafeArea.resolved(geometry.safeAreaInsets))
                        .offset(y: max(0, dragOffset))
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { dragOffset = max(0, $0.translation.height) }
                                .onEnded {
                                    if $0.translation.height > 90 || $0.predictedEndTranslation.height > 180 {
                                        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                                            coordinator.isMinimized = true
                                            dragOffset = 0
                                        }
                                    } else {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                            dragOffset = 0
                                        }
                                    }
                                }
                        )
                }
                .ignoresSafeArea()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: coordinator.activeCall?.id)
    }

    private func callRoom(_ call: AloGroupCallState, safeArea: EdgeInsets) -> some View {
        let remoteVideoPeer = coordinator.sfuRoom == nil ? call.participants.first {
            $0.id != coordinator.localUserId && call.videoParticipantIds.contains($0.id)
        } : nil
        let hasSFUVideo = coordinator.sfuRoom.map {
            $0.localVideoTrack != nil || !$0.remoteVideoTracks.isEmpty
        } ?? false
        let showsVideo = hasSFUVideo || remoteVideoPeer != nil

        return ZStack {
            AloGroupCallTheme.background

            if let sfuRoom = coordinator.sfuRoom, hasSFUVideo {
                AloGroupSFUVideoGrid(
                    room: sfuRoom,
                    participants: call.participants,
                    localUserId: coordinator.localUserId
                )
                .ignoresSafeArea()
                .transition(.opacity)
            } else if let remoteVideoPeer {
                AloGroupVideoRenderer(
                    coordinator: coordinator,
                    userId: remoteVideoPeer.id,
                    isLocal: false,
                    mirrored: false
                )
                .ignoresSafeArea()
                .transition(.opacity)
            }

            if showsVideo {
                LinearGradient(colors: [Color.black.opacity(0.5), .clear, Color.black.opacity(0.62)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                header(call)
                    .padding(.top, safeArea.top + 6)
                    .padding(.horizontal, 12)

                if let recording = coordinator.controls.recording {
                    recordingBanner(recording)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if showsVideo {
                    Spacer(minLength: 0)
                } else {
                    participantList(call)
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                }

                if call.isVideoEnabled && coordinator.sfuRoom == nil {
                    HStack {
                        Spacer()
                        AloGroupVideoRenderer(
                            coordinator: coordinator,
                            userId: coordinator.localUserId,
                            isLocal: true,
                            mirrored: call.isFrontCamera
                        )
                        .frame(width: 112, height: 158)
                        .background(Color.black.opacity(0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                controls(call)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, max(18, safeArea.bottom + 6))
            }

            if isCameraPickerVisible {
                cameraPicker(call, safeArea: safeArea)
                    .transition(.opacity)
                    .zIndex(30)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: coordinator.controls)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.group-call-overlay")
    }

    /// Telegram's voice-chat bar: minimise, the title with the count, and the options menu.
    private func header(_ call: AloGroupCallState) -> some View {
        HStack(spacing: 10) {
            headerButton("chevron.down", label: "Свернуть") {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { coordinator.isMinimized = true }
            }
            .accessibilityIdentifier("alo.group-call.minimize")
            Spacer(minLength: 4)
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    if coordinator.controls.recording != nil {
                        Circle().fill(AloGroupCallTheme.recording).frame(width: 8, height: 8)
                            .accessibilityLabel("Идёт запись")
                    }
                    Text(call.roomTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(participantLabel(call.participants.count))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Spacer(minLength: 4)
            Menu {
                if coordinator.controls.canManage {
                    Section("Администратор") {
                        Button {
                            coordinator.muteEveryone(!coordinator.controls.joinMuted)
                        } label: {
                            Label(coordinator.controls.joinMuted ? "Разрешить всем говорить" : "Выключить микрофон всем",
                                  systemImage: coordinator.controls.joinMuted ? "mic" : "mic.slash")
                        }
                        Button(role: coordinator.isRecordingHere ? .destructive : nil) {
                            coordinator.toggleRecording()
                        } label: {
                            Label(coordinator.isRecordingHere ? "Остановить запись" : "Начать запись",
                                  systemImage: coordinator.isRecordingHere ? "stop.circle" : "record.circle")
                        }
                        .disabled(coordinator.controls.recording != nil && !coordinator.isRecordingHere)
                    }
                }
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { coordinator.isMinimized = true }
                } label: {
                    Label("Свернуть", systemImage: "rectangle.compress.vertical")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Настройки видеочата")
            .accessibilityIdentifier("alo.group-call.menu")
        }
    }

    private func headerButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.12), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.9))
        .accessibilityLabel(label)
    }

    private func recordingBanner(_ recording: AloGroupCallControls.Recording) -> some View {
        TimelineView(.periodic(from: recording.startedAt, by: 1)) { context in
            HStack(spacing: 7) {
                Circle().fill(AloGroupCallTheme.recording).frame(width: 8, height: 8)
                    .opacity(Int(context.date.timeIntervalSince(recording.startedAt)) % 2 == 0 ? 1 : 0.35)
                Text(coordinator.isRecordingHere ? "Запись · \(Self.clock(context.date.timeIntervalSince(recording.startedAt)))"
                     : "Идёт запись видеочата")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(AloGroupCallTheme.recording.opacity(0.22), in: Capsule())
        }
        .accessibilityIdentifier("alo.group-call.recording")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Everyone in the call as Telegram lists them: who speaks, who listens, who wants to speak.
    private func participantList(_ call: AloGroupCallState) -> some View {
        let raised = coordinator.controls.raisedHands
        let ordered = call.participants.sorted { left, right in
            // Raised hands first (oldest first), then everyone in join order.
            switch (raised[left.id], raised[right.id]) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return false
            }
        }
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(ordered, id: \.id) { participant in
                    participantRow(participant, call: call)
                    if participant.id != ordered.last?.id {
                        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 70)
                    }
                }
            }
            .background(AloGroupCallTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("alo.group-call.participants")
    }

    private func participantRow(_ participant: AloDirectCallPeer, call: AloGroupCallState) -> some View {
        let isMe = participant.id == coordinator.localUserId
        let speaking = coordinator.sfuRoom?.speakingParticipantIds.contains(participant.id) == true && !(isMe && call.isMuted)
        let muted = isMe ? call.isMuted : (coordinator.sfuRoom?.mutedParticipantIds.contains(participant.id) ?? false)
        let byAdmin = coordinator.controls.mutedByAdmin.contains(participant.id)
        let hand = coordinator.controls.raisedHands[participant.id] != nil
        let status: (text: String, color: Color) = hand ? ("хочет говорить", AloGroupCallTheme.hand)
            : speaking ? ("говорит", AloGroupCallTheme.live)
            : byAdmin ? ("микрофон выключен", Color.white.opacity(0.5))
            : ("слушает", Color.white.opacity(0.5))
        return HStack(spacing: 12) {
            AloAvatar(name: participant.name, url: participant.avatarURL, size: 44, colorSeed: String(participant.id))
                .overlay(Circle().stroke(AloGroupCallTheme.live, lineWidth: speaking ? 2.5 : 0).padding(-3))
                .animation(.easeOut(duration: 0.18), value: speaking)
            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "\(participant.name) (вы)" : participant.name)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 4) {
                    if hand { Image(systemName: "hand.raised.fill").font(.system(size: 11)) }
                    Text(status.text).lineLimit(1)
                }
                .font(.system(size: 13)).foregroundStyle(status.color)
            }
            Spacer(minLength: 6)
            Image(systemName: speaking ? "mic.fill" : (muted || byAdmin) ? "mic.slash.fill" : "mic")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(speaking ? AloGroupCallTheme.live : byAdmin ? AloGroupCallTheme.recording : Color.white.opacity(0.55))
                .frame(width: 30)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            if coordinator.controls.canManage && !isMe {
                if byAdmin || hand {
                    Button { coordinator.setMicrophone(of: participant.id, allowed: true) } label: {
                        Label("Разрешить говорить", systemImage: "mic")
                    }
                }
                if !byAdmin {
                    Button(role: .destructive) { coordinator.setMicrophone(of: participant.id, allowed: false) } label: {
                        Label("Выключить микрофон", systemImage: "mic.slash")
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("alo.group-call.participant.\(participant.id)")
    }

    /// Video and speaker on the left, Telegram's big microphone button in the middle, leave on the right.
    private func controls(_ call: AloGroupCallState) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 14) {
                smallControl(title: "Видео", icon: call.isVideoEnabled ? "video.fill" : "video.slash.fill",
                             selected: call.isVideoEnabled, loading: coordinator.isCameraStarting) {
                    selectedCamera = call.isFrontCamera ? .front : .back
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { isCameraPickerVisible = true }
                }
                smallControl(title: call.isSpeakerOn ? "Динамик" : "Телефон",
                             icon: call.isSpeakerOn ? "speaker.wave.2.fill" : "iphone",
                             selected: call.isSpeakerOn, action: coordinator.toggleSpeaker)
            }
            Spacer(minLength: 8)
            microphoneButton(call)
            Spacer(minLength: 8)
            VStack(spacing: 14) {
                smallControl(title: "Выйти", icon: "xmark", destructive: true, action: coordinator.leave)
                    .accessibilityIdentifier("alo.group-call.leave")
            }
        }
    }

    private func microphoneButton(_ call: AloGroupCallState) -> some View {
        let state = AloGroupCallMicState(call: call, coordinator: coordinator)
        let speaking = coordinator.sfuRoom?.speakingParticipantIds.contains(coordinator.localUserId) == true && !call.isMuted
        return Button(action: coordinator.toggleMute) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: state.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .opacity(0.28)
                        .frame(width: 136, height: 136)
                        .scaleEffect(speaking ? 1.08 : 0.94)
                        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: speaking)
                    Circle()
                        .fill(LinearGradient(colors: state.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 112, height: 112)
                        .shadow(color: state.colors.first!.opacity(0.45), radius: 18)
                    Image(systemName: state.icon)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                VStack(spacing: 2) {
                    Text(state.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    Text(state.subtitle).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center).lineLimit(2)
                }
                .frame(width: 230)
            }
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.94))
        .accessibilityLabel(state.title)
        .accessibilityIdentifier("alo.group-call.microphone")
        .sensoryFeedback(.impact(weight: .medium), trigger: call.isMuted)
    }

    private func smallControl(
        title: String,
        icon: String,
        selected: Bool = false,
        destructive: Bool = false,
        loading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(destructive ? AloGroupCallTheme.leave : selected ? Color.white.opacity(0.28) : Color.white.opacity(0.14))
                    if loading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 54, height: 54)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            }
            .frame(width: 72)
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.90))
    }

    private func cameraPicker(
        _ call: AloGroupCallState,
        safeArea: EdgeInsets
    ) -> some View {
        AloGroupCameraSourcePicker(
            selectedCamera: $selectedCamera,
            isVideoEnabled: call.isVideoEnabled,
            bottomInset: safeArea.bottom,
            dismiss: {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.9)) {
                    isCameraPickerVisible = false
                }
            },
            disableVideo: {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.9)) {
                    isCameraPickerVisible = false
                }
                coordinator.toggleVideo()
            },
            commit: { source in
                withAnimation(.spring(response: 0.30, dampingFraction: 0.9)) {
                    isCameraPickerVisible = false
                }
                coordinator.selectCamera(frontCamera: source == .front)
            }
        )
    }

    private func participantLabel(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        let word = mod10 == 1 && mod100 != 11 ? "участник"
            : (2...4).contains(mod10) && !(12...14).contains(mod100) ? "участника" : "участников"
        return "\(count) \(word)"
    }
}

/// Telegram's voice-chat colours.
enum AloGroupCallTheme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let panel = Color(red: 0.14, green: 0.14, blue: 0.17)
    static let live = Color(red: 0.20, green: 0.80, blue: 0.47)
    static let hand = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let recording = Color(red: 1.0, green: 0.27, blue: 0.27)
    static let leave = Color(red: 1.0, green: 0.23, blue: 0.19).opacity(0.9)
    static let muted = [Color(red: 0.23, green: 0.55, blue: 0.96), Color(red: 0.35, green: 0.35, blue: 0.85)]
    static let speaking = [Color(red: 0.20, green: 0.80, blue: 0.47), Color(red: 0.19, green: 0.69, blue: 0.78)]
    static let raiseHand = [Color(red: 0.61, green: 0.35, blue: 0.96), Color(red: 0.96, green: 0.42, blue: 0.61)]
}

/// What the big button says: muted, live, or (muted by an admin) raise / lower your hand.
struct AloGroupCallMicState {
    let colors: [Color]
    let icon: String
    let title: String
    let subtitle: String

    @MainActor init(call: AloGroupCallState, coordinator: AloGroupCallCoordinator) {
        if coordinator.isMutedByAdmin && call.isMuted {
            colors = AloGroupCallTheme.raiseHand
            if coordinator.isHandRaised {
                icon = "hand.raised.fill"
                title = "Вы подняли руку"
                subtitle = "Ждём разрешения администратора"
            } else {
                icon = "hand.raised"
                title = "Поднять руку"
                subtitle = "Микрофон выключен администратором"
            }
        } else if call.isMuted {
            colors = AloGroupCallTheme.muted
            icon = "mic.slash.fill"
            title = "Микрофон выключен"
            subtitle = "Нажмите, чтобы говорить"
        } else {
            colors = AloGroupCallTheme.speaking
            icon = "mic.fill"
            title = "Вы в эфире"
            subtitle = "Нажмите, чтобы выключить микрофон"
        }
    }
}

private enum AloGroupCameraSource: Int, CaseIterable, Identifiable {
    case front
    case back

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .front: "Передняя"
        case .back: "Задняя"
        }
    }

    var icon: String {
        switch self {
        case .front: "person.crop.rectangle"
        case .back: "camera.fill"
        }
    }
}

private struct AloGroupCameraSourcePicker: View {
    @Binding var selectedCamera: AloGroupCameraSource
    let isVideoEnabled: Bool
    let bottomInset: CGFloat
    let dismiss: () -> Void
    let disableVideo: () -> Void
    let commit: (AloGroupCameraSource) -> Void

    @GestureState private var dismissOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.46)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 16) {
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 42, height: 5)

                HStack {
                    Text("Выберите камеру")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    if isVideoEnabled {
                        Button("Выключить", action: disableVideo)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.red)
                    }
                }

                HStack(spacing: 10) {
                    ForEach(AloGroupCameraSource.allCases) { source in
                        Button {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                                selectedCamera = source
                            }
                        } label: {
                            VStack(spacing: 10) {
                                Image(systemName: source.icon)
                                    .font(.system(size: 25, weight: .semibold))
                                Text(source.title)
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 98)
                            .background(
                                Color.white.opacity(selectedCamera == source ? 0.16 : 0.07)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(
                                        Color.white.opacity(selectedCamera == source ? 0.28 : 0.08),
                                        lineWidth: 1
                                    )
                            }
                            .scaleEffect(selectedCamera == source ? 1 : 0.94)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 14)
                        .onEnded { value in
                            if value.translation.width < -48 {
                                selectedCamera = .back
                            } else if value.translation.width > 48 {
                                selectedCamera = .front
                            }
                        }
                )

                Button {
                    commit(selectedCamera)
                } label: {
                    Text("Продолжить")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.96))
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, max(18, bottomInset + 8))
            .background(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.97))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 30,
                    topTrailingRadius: 30
                )
            )
            .offset(y: max(0, dismissOffset))
            .gesture(
                DragGesture(minimumDistance: 8)
                    .updating($dismissOffset) { value, state, _ in
                        state = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        if value.translation.height > 90 ||
                            value.predictedEndTranslation.height > 170 {
                            dismiss()
                        }
                    }
            )
        }
        .ignoresSafeArea()
    }
}

struct AloGroupCallCompactBar: View {
    let call: AloGroupCallState
    @ObservedObject var coordinator: AloGroupCallCoordinator

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                    Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.16))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(call.roomTitle)
                            .font(.system(size: 14, weight: .bold))
                        Text("\(call.participants.count) в видеочате")
                            .font(.system(size: 11, weight: .medium))
                            .opacity(0.78)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        coordinator.isMinimized = false
                    }
                }

            Button(action: coordinator.leave) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Color.red)
                    .clipShape(Circle())
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.90))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.64, blue: 0.42),
                    Color(red: 0.04, green: 0.43, blue: 0.50)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .background {
            // Taps on the status bar part of the bar come through this proxy.
            if coordinator.isMinimized {
                AloStatusBarTapCatcher {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        coordinator.isMinimized = false
                    }
                }
            }
        }
        .accessibilityIdentifier("alo.group-call-compact")
    }
}

private struct AloGroupSFUVideoGrid: View {
    @ObservedObject var room: AloGroupSFURoom
    let participants: [AloDirectCallPeer]
    let localUserId: Int

    private var items: [AloGroupSFUVideoItem] {
        var result = room.remoteVideoTracks.map {
            AloGroupSFUVideoItem(userId: $0.key, track: $0.value, isLocal: false)
        }
        if let localTrack = room.localVideoTrack {
            result.append(
                AloGroupSFUVideoItem(
                    userId: localUserId,
                    track: localTrack,
                    isLocal: true
                )
            )
        }
        return result.sorted {
            if $0.isLocal != $1.isLocal { return !$0.isLocal }
            return $0.userId < $1.userId
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let visibleItems = Array(items.prefix(9))
            let columns = gridColumns(for: visibleItems.count)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(visibleItems) { item in
                    ZStack(alignment: .bottomLeading) {
                        SwiftUIVideoView(
                            item.track,
                            layoutMode: .fill,
                            mirrorMode: item.isLocal ? .auto : .off
                        )
                        .clipped()

                        HStack(spacing: 5) {
                            if room.speakingParticipantIds.contains(item.userId) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                            }
                            Text(displayName(for: item.userId, isLocal: item.isLocal))
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(.black.opacity(0.42))
                        .clipShape(Capsule())
                        .padding(8)
                    }
                    .frame(
                        height: tileHeight(
                            availableHeight: geometry.size.height,
                            itemCount: visibleItems.count
                        )
                    )
                    .background(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        if room.speakingParticipantIds.contains(item.userId) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.green.opacity(0.9), lineWidth: 2)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 112)
        }
    }

    private func gridColumns(for count: Int) -> [GridItem] {
        let columnCount = count <= 1 ? 1 : count <= 4 ? 2 : 3
        return Array(
            repeating: GridItem(.flexible(), spacing: 3),
            count: columnCount
        )
    }

    private func tileHeight(availableHeight: CGFloat, itemCount: Int) -> CGFloat {
        let rowCount = itemCount <= 2 ? 1 : itemCount <= 4 ? 2 : 3
        return max(120, (availableHeight - 230) / CGFloat(rowCount))
    }

    private func displayName(for userId: Int, isLocal: Bool) -> String {
        if isLocal { return "Вы" }
        return participants.first(where: { $0.id == userId })?.name ?? "Участник"
    }
}

private struct AloGroupSFUVideoItem: Identifiable {
    let userId: Int
    let track: VideoTrack
    let isLocal: Bool

    var id: Int { userId }
}

private struct AloGroupVideoRenderer: UIViewRepresentable {
    let coordinator: AloGroupCallCoordinator
    let userId: Int
    let isLocal: Bool
    let mirrored: Bool

    final class Coordinator {
        weak var renderer: RTCMTLVideoView?
        weak var owner: AloGroupCallCoordinator?
        var userId = 0
        var isLocal = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        context.coordinator.renderer = view
        context.coordinator.owner = coordinator
        context.coordinator.userId = userId
        context.coordinator.isLocal = isLocal
        bind(view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.transform = mirrored
            ? CGAffineTransform(scaleX: -1, y: 1)
            : .identity
        if context.coordinator.userId != userId || context.coordinator.isLocal != isLocal {
            if context.coordinator.isLocal {
                coordinator.bindLocalRenderer(nil)
            } else {
                coordinator.bindRemoteRenderer(nil, userId: context.coordinator.userId)
            }
            context.coordinator.userId = userId
            context.coordinator.isLocal = isLocal
            bind(uiView)
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator context: Coordinator) {
        if context.isLocal {
            context.owner?.bindLocalRenderer(nil)
        } else {
            context.owner?.bindRemoteRenderer(nil, userId: context.userId)
        }
    }

    private func bind(_ renderer: RTCMTLVideoView) {
        if isLocal {
            coordinator.bindLocalRenderer(renderer)
        } else {
            coordinator.bindRemoteRenderer(renderer, userId: userId)
        }
    }
}
