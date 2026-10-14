import SwiftUI

enum AloCallVideoSource: Int, CaseIterable, Identifiable {
    case screen
    case frontCamera
    case backCamera

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .screen:
            "ЭКРАН ТЕЛЕФОНА"
        case .frontCamera:
            "ПЕРЕДНЯЯ КАМЕРА"
        case .backCamera:
            "ЗАДНЯЯ КАМЕРА"
        }
    }

    var isCamera: Bool {
        self != .screen
    }

    var usesFrontCamera: Bool {
        self == .frontCamera
    }

    static func current(for call: AloDirectCallState) -> AloCallVideoSource {
        if call.isScreenSharing {
            return .screen
        }
        return call.isFrontCamera ? .frontCamera : .backCamera
    }
}

enum AloCallVideoControlAction: Equatable {
    case presentSources
    case disableCamera
    case stopScreenShare

    static func resolve(for call: AloDirectCallState) -> Self {
        if call.isScreenSharing {
            return .stopScreenShare
        }
        if call.isVideoEnabled {
            return .disableCamera
        }
        return .presentSources
    }
}

struct AloCallVideoSourcePicker: View {
    @ObservedObject var coordinator: AloCallCoordinator

    let call: AloDirectCallState
    let initialSource: AloCallVideoSource
    let safeAreaInsets: EdgeInsets
    let cancel: () -> Void
    let commit: (AloCallVideoSource) -> Void

    @State private var selectedSource: AloCallVideoSource
    @State private var isVisible = false
    @GestureState private var dismissTranslation: CGFloat = 0

    init(
        coordinator: AloCallCoordinator,
        call: AloDirectCallState,
        initialSource: AloCallVideoSource,
        safeAreaInsets: EdgeInsets,
        cancel: @escaping () -> Void,
        commit: @escaping (AloCallVideoSource) -> Void
    ) {
        self.coordinator = coordinator
        self.call = call
        self.initialSource = initialSource
        self.safeAreaInsets = safeAreaInsets
        self.cancel = cancel
        self.commit = commit
        _selectedSource = State(initialValue: initialSource)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(
                        isVisible
                            ? 0.5 * (1 - min(dismissTranslation / 420, 0.7))
                            : 0
                    )
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .accessibilityIdentifier(
                        "alo.call-video-source-dimming"
                    )

                sourcePanel(
                    width: geometry.size.width,
                    height: max(
                        1,
                        geometry.size.height - safeAreaInsets.top - 8
                    )
                )
                .offset(
                    y: isVisible
                        ? max(0, dismissTranslation)
                        : geometry.size.height
                )
                .simultaneousGesture(horizontalSourceGesture)
                .simultaneousGesture(verticalDismissGesture)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.call-video-source-picker")
        .onAppear {
            withAnimation(
                .interpolatingSpring(
                    mass: 1,
                    stiffness: 240,
                    damping: 30,
                    initialVelocity: 0
                )
            ) {
                isVisible = true
            }
            coordinator.beginVideoSourcePreview(
                frontCamera: initialSource != .backCamera
            )
        }
        .onChange(of: selectedSource) { _, source in
            guard source.isCamera else { return }
            coordinator.previewVideoSource(frontCamera: source.usesFrontCamera)
        }
    }

    private func sourcePanel(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black

            cameraPreview

            LinearGradient(
                colors: [
                    Color.black.opacity(0.34),
                    Color.clear,
                    Color.black.opacity(0.46)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            if selectedSource == .screen {
                screenSharePlaceholder
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                header

                Spacer(minLength: 0)

                AloCallVideoSourceWheel(selection: $selectedSource)
                    .frame(height: 36)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)

                Button {
                    confirm()
                } label: {
                    Text("Продолжить")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(red: 0.31, green: 0.33, blue: 0.32))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))
                .frame(maxWidth: 360)
                .padding(.horizontal, 16)
                .padding(.bottom, max(16, safeAreaInsets.bottom + 8))
                .accessibilityIdentifier(
                    "alo.call-video-source-continue"
                )
            }
        }
        .frame(width: width, height: height)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 16,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 16,
                style: .continuous
            )
        )
    }

    private var cameraPreview: some View {
        AloCallVideoRenderer(
            coordinator: coordinator,
            isLocal: true,
            mirrored: selectedSource != .backCamera,
            transitioning: coordinator.isCameraStarting
                || coordinator.isCameraSwitching
        )
        .scaleEffect(
            selectedSource == .screen
                ? 1.08
                : (coordinator.isCameraSwitching ? 1.015 : 1)
        )
        .blur(
            radius: selectedSource == .screen
                ? 24
                : (coordinator.isCameraSwitching ? 1.5 : 0)
        )
        .overlay {
            if selectedSource == .screen {
                Color.black.opacity(0.22)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: selectedSource)
        .animation(
            .easeInOut(duration: 0.22),
            value: coordinator.isCameraSwitching
        )
        .accessibilityIdentifier("alo.call-video-source-preview")
    }

    private var screenSharePlaceholder: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 58, weight: .medium))

            Text("Транслировать изображение\nс Вашего экрана")
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 40)
        .allowsHitTesting(false)
        .accessibilityIdentifier(
            "alo.call-video-source-screen-placeholder"
        )
    }

    private var header: some View {
        ZStack {
            Text("Предпросмотр видео")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.white)

            HStack {
                Button("Отмена", action: close)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.white)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "alo.call-video-source-cancel"
                    )

                Spacer()
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 18)
    }

    private func close() {
        coordinator.cancelVideoSourcePreview()
        withAnimation(.easeInOut(duration: 0.3)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            cancel()
        }
    }

    private var horizontalSourceGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard abs(value.translation.width) >
                        abs(value.translation.height) * 1.2 else {
                    return
                }
                let projected = value.predictedEndTranslation.width
                if projected < -44 {
                    selectSource(rawValue: selectedSource.rawValue + 1)
                } else if projected > 44 {
                    selectSource(rawValue: selectedSource.rawValue - 1)
                }
            }
    }

    private var verticalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dismissTranslation) { value, state, _ in
                guard value.translation.height > 0,
                      abs(value.translation.height) >
                        abs(value.translation.width) else {
                    return
                }
                state = value.translation.height
            }
            .onEnded { value in
                guard value.translation.height > 0,
                      abs(value.translation.height) >
                        abs(value.translation.width) else {
                    return
                }
                if value.translation.height > 84 ||
                    value.predictedEndTranslation.height > 180 {
                    close()
                }
            }
    }

    private func selectSource(rawValue: Int) {
        guard let source = AloCallVideoSource(rawValue: rawValue) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedSource = source
        }
    }

    private func confirm() {
        let source = selectedSource
        withAnimation(.easeInOut(duration: 0.3)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            commit(source)
        }
    }
}

private struct AloCallVideoSourceWheel: View {
    @Binding var selection: AloCallVideoSource

    private let itemWidth: CGFloat = 174

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(AloCallVideoSource.allCases) { source in
                    Button {
                        selection = source
                    } label: {
                        Text(source.title)
                            .font(
                                .system(
                                    size: 14,
                                    weight: selection == source
                                        ? .semibold
                                        : .regular
                                )
                            )
                            .foregroundStyle(
                                selection == source
                                    ? Color(red: 1, green: 0.84, blue: 0.04)
                                    : Color.white
                            )
                            .lineLimit(1)
                            .shadow(color: Color.black.opacity(0.3), radius: 2)
                            .frame(width: itemWidth, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .rotation3DEffect(
                        .degrees(
                            Double(source.rawValue - selection.rawValue) * 8
                        ),
                        axis: (x: 0, y: 1, z: 0)
                    )
                    .accessibilityIdentifier(
                        "alo.call-video-source-\(source.rawValue)"
                    )
                    .accessibilityAddTraits(
                        selection == source ? .isSelected : []
                    )
                }
            }
            .frame(width: itemWidth * 3, height: 36)
            .position(x: geometry.size.width / 2, y: 18)
            .offset(
                x: -CGFloat(selection.rawValue - 1) * itemWidth
            )
            .animation(.easeInOut(duration: 0.2), value: selection)
            .contentShape(Rectangle())
        }
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.15),
                    .init(color: .white, location: 0.85),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

}
