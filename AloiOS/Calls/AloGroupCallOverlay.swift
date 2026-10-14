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
                    callRoom(call, safeArea: geometry.safeAreaInsets)
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

        return ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.12, blue: 0.15),
                    Color(red: 0.04, green: 0.27, blue: 0.24),
                    Color(red: 0.02, green: 0.10, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

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

            LinearGradient(
                colors: [
                    Color.black.opacity(remoteVideoPeer == nil ? 0.08 : 0.42),
                    Color.clear,
                    Color.black.opacity(0.58)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header(call)
                    .padding(.top, safeArea.top + 10)
                    .padding(.horizontal, 18)

                if remoteVideoPeer == nil && !hasSFUVideo {
                    participantGrid(call)
                        .padding(.top, 34)
                } else {
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 18)

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
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                controls(call)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, max(22, safeArea.bottom + 12))
            }

            if isCameraPickerVisible {
                cameraPicker(call, safeArea: safeArea)
                    .transition(.opacity)
                    .zIndex(30)
            }
        }
        .accessibilityIdentifier("alo.group-call-overlay")
    }

    private func header(_ call: AloGroupCallState) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(call.roomTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(participantLabel(call.participants.count))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("Видеочат")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.82))
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.ultraThinMaterial.opacity(0.72))
            .clipShape(Capsule())
        }
    }

    private func participantGrid(_ call: AloGroupCallState) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 18),
            count: min(3, max(1, call.participants.count))
        )
        return LazyVGrid(columns: columns, spacing: 24) {
            ForEach(call.participants, id: \.id) { participant in
                VStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        AloAvatar(
                            name: participant.name,
                            url: participant.avatarURL,
                            size: call.participants.count > 6 ? 68 : 82,
                            colorSeed: String(participant.id)
                        )
                        Circle()
                            .fill(participant.id == coordinator.localUserId && call.isMuted
                                  ? Color(red: 0.12, green: 0.48, blue: 0.94)
                                  : Color(red: 0.13, green: 0.70, blue: 0.36))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: participant.id == coordinator.localUserId && call.isMuted
                                      ? "mic.slash.fill"
                                      : "mic.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 2))
                    }
                    Text(participant.id == coordinator.localUserId ? "Вы" : participant.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func controls(_ call: AloGroupCallState) -> some View {
        HStack(spacing: 12) {
            groupControl(
                title: call.isSpeakerOn ? "Динамик" : "Телефон",
                icon: call.isSpeakerOn ? "speaker.wave.2.fill" : "iphone",
                selected: call.isSpeakerOn,
                action: coordinator.toggleSpeaker
            )
            groupControl(
                title: "Видео",
                icon: call.isVideoEnabled ? "video.fill" : "video.slash.fill",
                selected: call.isVideoEnabled,
                loading: coordinator.isCameraStarting,
                action: {
                    selectedCamera = call.isFrontCamera ? .front : .back
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        isCameraPickerVisible = true
                    }
                }
            )
            groupControl(
                title: call.isMuted ? "Включить" : "Микрофон",
                icon: call.isMuted ? "mic.slash.fill" : "mic.fill",
                selected: !call.isMuted,
                action: coordinator.toggleMute
            )
            groupControl(
                title: "Выйти",
                icon: "phone.down.fill",
                destructive: true,
                action: coordinator.leave
            )
        }
    }

    private func groupControl(
        title: String,
        icon: String,
        selected: Bool = false,
        destructive: Bool = false,
        loading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(
                            destructive
                                ? Color(red: 1.0, green: 0.20, blue: 0.22)
                                : selected
                                    ? Color.white
                                    : Color.white.opacity(0.17)
                        )
                    if loading {
                        ProgressView()
                            .tint(selected ? .black : .white)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(selected && !destructive ? Color.black : Color.white)
                    }
                }
                .frame(width: 58, height: 58)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
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
        count == 1 ? "1 участник" : "\(count) участников"
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
