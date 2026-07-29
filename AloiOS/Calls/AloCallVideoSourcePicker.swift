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
                    .opacity(isVisible ? 0.5 : 0)
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
                .offset(y: isVisible ? 0 : geometry.size.height)
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
            mirrored: selectedSource != .backCamera
        )
        .scaleEffect(selectedSource == .screen ? 1.08 : 1)
        .blur(radius: selectedSource == .screen ? 24 : 0)
        .overlay {
            if selectedSource == .screen {
                Color.black.opacity(0.22)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: selectedSource)
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
    @GestureState private var dragOffset: CGFloat = 0

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
                    + dragOffset
            )
            .animation(.easeInOut(duration: 0.2), value: selection)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in
                        let projected = value.predictedEndTranslation.width
                        if projected < -36 {
                            select(rawValue: selection.rawValue + 1)
                        } else if projected > 36 {
                            select(rawValue: selection.rawValue - 1)
                        }
                    }
            )
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

    private func select(rawValue: Int) {
        guard let source = AloCallVideoSource(rawValue: rawValue) else {
            return
        }
        selection = source
    }
}
