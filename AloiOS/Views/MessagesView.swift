import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation
import AVKit
import Combine
import CoreImage.CIFilterBuiltins

private enum AloKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct MessagesView: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var chatDragOffset: CGFloat = 0
    @State private var chatDragActive = false
    @State private var chatDragRejected = false
    @State private var chatSwipeBlocked = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                inbox
                    .opacity(
                        app.activeConversation == nil
                            ? 1
                            : min(
                                1,
                                chatDragOffset
                                    / max(proxy.size.width * 0.62, 1)
                            )
                    )
                    .allowsHitTesting(app.activeConversation == nil)

                if let conversation = app.activeConversation {
                    ConversationView(conversation: conversation, blocksParentSwipe: $chatSwipeBlocked)
                        .offset(x: max(0, chatDragOffset))
                        .shadow(color: Color.black.opacity(chatDragOffset > 0 ? 0.30 : 0), radius: 18, x: -8, y: 0)
                        .simultaneousGesture(chatSwipeGesture(width: proxy.size.width))
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                        .zIndex(2)
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: app.activeConversation?.peerId)
        .onChange(of: app.activeConversation?.peerId) { _, _ in
            chatDragOffset = 0
        }
    }

    private func chatSwipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard !chatSwipeBlocked, !chatDragRejected else { return }

                if !chatDragActive {
                    let horizontal = value.translation.width
                    let vertical = abs(value.translation.height)
                    if vertical > 6, vertical > abs(horizontal) {
                        chatDragRejected = true
                        return
                    }
                    guard horizontal > 3,
                          abs(horizontal) > vertical * 1.08 else { return }
                    chatDragActive = true
                    AloKeyboard.dismiss()
                }

                chatDragOffset = min(width, max(0, value.translation.width))
            }
            .onEnded { value in
                guard chatDragActive else {
                    chatDragRejected = false
                    chatDragOffset = 0
                    return
                }
                chatDragActive = false
                chatDragRejected = false
                let threshold = max(110, width * 0.28)
                let shouldClose = value.translation.width > threshold || value.predictedEndTranslation.width > width * 0.52
                if shouldClose {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) {
                        chatDragOffset = width
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        AloKeyboard.dismiss()
                        app.closeConversation()
                        chatDragOffset = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        chatDragOffset = 0
                    }
                }
            }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Чаты")
                .font(.largeTitle.bold())
                .foregroundStyle(AloTheme.text)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(app.bootstrap?.conversations ?? []) { conversation in
                        Button {
                            app.openConversation(conversation)
                        } label: {
                            ConversationRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                        Divider().background(AloTheme.border).padding(.leading, 80)
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .refreshable { await app.loadBootstrap() }
    }
}

private struct ConversationRow: View {
    let conversation: AloConversationSummary

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if conversation.peer.entityType == "saved" {
                SavedMessagesAvatar(size: 52)
            } else {
                AloAvatar(
                    name: conversation.peer.name,
                    url: conversation.peer.avatarUrl,
                    size: 52,
                    colorSeed: String(conversation.peer.id)
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.peer.entityType == "saved" ? "Избранное" : conversation.peer.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AloTheme.text)
                    .lineLimit(1)
                Text(conversation.lastBody.ifBlank("Сообщение"))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(AloTheme.muted)
            }
            .padding(.top, 2)
            Spacer()
            Text(AloFormatters.messageTime(conversation.lastAt))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AloTheme.muted)
                .padding(.top, 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct SavedMessagesAvatar: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(SavedMessagesStyle.gradient)
            SavedBookmarkGlyph()
                .fill(Color.white)
                .frame(width: size * 0.52, height: size * 0.52)
                .shadow(color: Color.black.opacity(0.10), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

private struct SavedBookmarkGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x / 30,
                y: rect.minY + rect.height * y / 30
            )
        }

        var path = Path()
        path.move(to: point(8, 2))
        path.addLine(to: point(22, 2))
        path.addCurve(
            to: point(26, 6),
            control1: point(24.210_938, 2),
            control2: point(26, 3.789_062)
        )
        path.addLine(to: point(26, 27.378_906))
        path.addCurve(
            to: point(24.5, 28.878_906),
            control1: point(26, 28.207_031),
            control2: point(25.328_125, 28.878_906)
        )
        path.addCurve(
            to: point(23.437_5, 28.437_5),
            control1: point(24.101_562, 28.878_906),
            control2: point(23.718_75, 28.718_75)
        )
        path.addLine(to: point(15.707_031, 20.707_031))
        path.addCurve(
            to: point(14.292_969, 20.707_031),
            control1: point(15.316_406, 20.316_406),
            control2: point(14.683_594, 20.316_406)
        )
        path.addLine(to: point(6.562_5, 28.437_5))
        path.addCurve(
            to: point(4.437_5, 28.437_5),
            control1: point(5.976_562, 29.023_438),
            control2: point(5.023_438, 29.023_438)
        )
        path.addCurve(
            to: point(4, 27.378_906),
            control1: point(4.156_25, 28.156_25),
            control2: point(4, 27.777_344)
        )
        path.addLine(to: point(4, 6))
        path.addCurve(
            to: point(8, 2),
            control1: point(4, 3.789_062),
            control2: point(5.789_062, 2)
        )
        path.closeSubpath()
        return path
    }
}

private enum SavedMessagesStyle {
    static let gradient = LinearGradient(
        colors: [
            Color(red: 114.0 / 255, green: 213.0 / 255, blue: 253.0 / 255),
            Color(red: 42.0 / 255, green: 158.0 / 255, blue: 241.0 / 255)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

private struct SavedMessagesIntroIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(SavedMessagesStyle.gradient)
            SavedBookmarkGlyph()
                .fill(Color.white)
                .frame(width: size * 0.52, height: size * 0.52)
                .shadow(color: Color.black.opacity(0.12), radius: 1.5, y: 1)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: AloTheme.accent.opacity(0.20), radius: 16, y: 8)
    }
}

private struct ActiveVoicePlayback: Equatable {
    let attachmentId: String
    let title: String
    let isPlaying: Bool
    var speed: Double
}

private struct ChatCallLogMeta: Equatable {
    let callType: String
    let status: String
    let durationSec: Int
    let scope: String
}

struct AloChatAppearance: Codable, Equatable {
    var preset = "classic"
    var wallpaperHue = 211.0
    var outgoingHue = 211.0
    var incomingHue = 226.0
    var wallpaperBrightness = 0.02
    var outgoingBrightness = 0.98
    var incomingBrightness = 0.18
    var patternIntensity = 0.11
    var compactSpacing = false

    var wallpaperTop: Color {
        if usesNeutralDarkWallpaper {
            let base = max(0.012, min(0.10, wallpaperBrightness))
            return Color(white: base)
        }
        return Color(hue: wallpaperHue / 360, saturation: 0.72, brightness: wallpaperBrightness)
    }

    var wallpaperBottom: Color {
        if usesNeutralDarkWallpaper {
            let base = max(0.018, min(0.13, wallpaperBrightness + 0.028))
            return Color(white: base)
        }
        return Color(
            hue: ((wallpaperHue + 12).truncatingRemainder(dividingBy: 360)) / 360,
            saturation: 0.70,
            brightness: min(1, wallpaperBrightness + 0.11)
        )
    }

    var outgoingColor: Color {
        Color(hue: outgoingHue / 360, saturation: 0.88, brightness: outgoingBrightness)
    }

    var incomingColor: Color {
        Color(hue: incomingHue / 360, saturation: 0.24, brightness: incomingBrightness)
    }

    private var usesNeutralDarkWallpaper: Bool {
        ["classic", "black", "graphite"].contains(preset.lowercased()) && wallpaperBrightness <= 0.12
    }

    static let presets: [(id: String, title: String, value: AloChatAppearance)] = [
        ("classic", "Классическая", AloChatAppearance(wallpaperHue: 220, wallpaperBrightness: 0.02, patternIntensity: 0.09)),
        ("black", "Чёрная", AloChatAppearance(
            preset: "black",
            wallpaperHue: 220,
            outgoingHue: 214,
            incomingHue: 220,
            wallpaperBrightness: 0.025,
            outgoingBrightness: 0.86,
            incomingBrightness: 0.10,
            patternIntensity: 0.055
        )),
        ("ocean", "Океан", AloChatAppearance(preset: "ocean", wallpaperHue: 196, outgoingHue: 204, incomingHue: 214, patternIntensity: 0.12)),
        ("night", "Ночь", AloChatAppearance(preset: "night", wallpaperHue: 238, outgoingHue: 224, incomingHue: 238, patternIntensity: 0.09)),
        ("graphite", "Графит", AloChatAppearance(preset: "graphite", wallpaperHue: 205, outgoingHue: 198, incomingHue: 215, patternIntensity: 0.08)),
        ("emerald", "Изумруд", AloChatAppearance(preset: "emerald", wallpaperHue: 164, outgoingHue: 158, incomingHue: 174, patternIntensity: 0.10))
    ]

    private enum CodingKeys: String, CodingKey {
        case preset
        case wallpaperHue
        case outgoingHue
        case incomingHue
        case wallpaperBrightness
        case outgoingBrightness
        case incomingBrightness
        case patternIntensity
        case compactSpacing
    }

    init(
        preset: String = "classic",
        wallpaperHue: Double = 220,
        outgoingHue: Double = 211,
        incomingHue: Double = 226,
        wallpaperBrightness: Double = 0.02,
        outgoingBrightness: Double = 0.98,
        incomingBrightness: Double = 0.18,
        patternIntensity: Double = 0.09,
        compactSpacing: Bool = false
    ) {
        self.preset = preset
        self.wallpaperHue = wallpaperHue
        self.outgoingHue = outgoingHue
        self.incomingHue = incomingHue
        self.wallpaperBrightness = wallpaperBrightness
        self.outgoingBrightness = outgoingBrightness
        self.incomingBrightness = incomingBrightness
        self.patternIntensity = patternIntensity
        self.compactSpacing = compactSpacing
    }

    init(from decoder: Decoder) throws {
        let defaults = AloChatAppearance()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = try container.decodeIfPresent(String.self, forKey: .preset) ?? defaults.preset
        wallpaperHue = try container.decodeIfPresent(Double.self, forKey: .wallpaperHue) ?? defaults.wallpaperHue
        outgoingHue = try container.decodeIfPresent(Double.self, forKey: .outgoingHue) ?? defaults.outgoingHue
        incomingHue = try container.decodeIfPresent(Double.self, forKey: .incomingHue) ?? defaults.incomingHue
        wallpaperBrightness = try container.decodeIfPresent(Double.self, forKey: .wallpaperBrightness) ?? defaults.wallpaperBrightness
        outgoingBrightness = try container.decodeIfPresent(Double.self, forKey: .outgoingBrightness) ?? defaults.outgoingBrightness
        incomingBrightness = try container.decodeIfPresent(Double.self, forKey: .incomingBrightness) ?? defaults.incomingBrightness
        patternIntensity = try container.decodeIfPresent(Double.self, forKey: .patternIntensity) ?? defaults.patternIntensity
        compactSpacing = try container.decodeIfPresent(Bool.self, forKey: .compactSpacing) ?? defaults.compactSpacing
    }
}

enum AloChatAppearanceStore {
    private static let globalKey = "alo.chat.appearance.global"

    static func read(for conversation: AloConversationDetail) -> AloChatAppearance {
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: globalKey) ?? defaults.data(forKey: legacyKey(for: conversation))
        guard let data,
              var value = try? JSONDecoder().decode(AloChatAppearance.self, from: data) else {
            return AloChatAppearance()
        }

        let legacyClassicId = ["tele", "gram"].joined()
        if value.preset.lowercased() == legacyClassicId {
            value.preset = "classic"
        }
        if value.preset == "classic", abs(value.wallpaperBrightness - 0.22) < 0.001 {
            value.wallpaperBrightness = 0.02
        }
        save(value, for: conversation)
        return value
    }

    static func readGlobal() -> AloChatAppearance {
        guard let data = UserDefaults.standard.data(forKey: globalKey),
              var value = try? JSONDecoder().decode(AloChatAppearance.self, from: data) else {
            return AloChatAppearance()
        }
        let legacyClassicId = ["tele", "gram"].joined()
        if value.preset.lowercased() == legacyClassicId {
            value.preset = "classic"
        }
        if value.preset == "classic", abs(value.wallpaperBrightness - 0.22) < 0.001 {
            value.wallpaperBrightness = 0.02
        }
        return value
    }

    static func saveGlobal(_ appearance: AloChatAppearance) {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        UserDefaults.standard.set(data, forKey: globalKey)
    }

    static func save(_ appearance: AloChatAppearance, for conversation: AloConversationDetail) {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        UserDefaults.standard.set(data, forKey: globalKey)
    }

    private static func legacyKey(for conversation: AloConversationDetail) -> String {
        let target = conversation.kind == "group" ? conversation.roomId : conversation.peerId
        return "alo.chat.appearance.\(conversation.kind).\(target)"
    }
}

struct ConversationView: View {
    @EnvironmentObject private var app: AloAppModel
    let conversation: AloConversationDetail
    @Binding var blocksParentSwipe: Bool

    @State private var localAttachments = [AloLocalAttachment]()
    @State private var isAttachmentSheetPresented = false
    @State private var localPreviewAttachment: AloLocalAttachment?
    @State private var selectedMessageIds = Set<Int>()
    @State private var selectionMode = false
    @State private var actionMessage: AloChatMessage?
    @State private var actionMessageFrame: CGRect?
    @State private var activeMediaViewer: ChatMediaViewerState?
    @State private var editingMessage: AloChatMessage?
    @State private var deleteCandidateIds = [Int]()
    @State private var forwardPickerMessage: AloChatMessage?
    @State private var recordingMode: ChatRecordingMode = .voice
    @State private var activeRecordingMode: ChatRecordingMode?
    @State private var isRecordingLocked = false
    @State private var recordingStartedAt = Date()
    @State private var recordedDurations = [UUID: TimeInterval]()
    @State private var recordedWaveforms = [UUID: [CGFloat]]()
    @State private var activeVoicePlayback: ActiveVoicePlayback?
    @State private var isChatDetailsPresented = false
    @State private var isChatAppearancePresented = false
    @State private var chatAppearance: AloChatAppearance
    @State private var activeCallKind: ChatCallKind?
    @State private var isCallMinimized = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var composerChromeHeight: CGFloat = ChatComposerMetrics.collapsedChromeHeight
    @State private var keyboardAnimationDuration: TimeInterval = 0.25
    @State private var keyboardAnimationCurveRaw = UIView.AnimationCurve.easeInOut.rawValue
    @State private var previousMessageCount: Int
    @State private var measuredMessageFrames = [Int: CGRect]()
    @State private var bottomAnchorFrame: CGRect = .zero
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var shouldFollowKeyboardToBottom = false
    @State private var hasUserScrolledConversation = false
    @State private var didInitialScrollToBottom = false
    @State private var hasInitialMessageFrameSnapshot = false
    @State private var floatingDateLabel = ""
    @State private var isFloatingDateVisible = false
    @State private var floatingDateHideWorkItem: DispatchWorkItem?
    @State private var preservesComposerFocusForReaction = false
    @StateObject private var audioRecorder = ChatAudioRecorder()
    @StateObject private var circleRecorder = ChatCircleRecorder()
    @FocusState private var composerFocused: Bool

    init(conversation: AloConversationDetail, blocksParentSwipe: Binding<Bool>) {
        self.conversation = conversation
        _blocksParentSwipe = blocksParentSwipe
        _chatAppearance = State(initialValue: AloChatAppearanceStore.read(for: conversation))
        _previousMessageCount = State(initialValue: conversation.items.count)
    }

    var body: some View {
        ZStack {
            chatBackground
                .ignoresSafeArea(.container)
                .ignoresSafeArea(.keyboard, edges: .bottom)

            messagesList
                .offset(y: -keyboardMessagesLift)

            if conversation.items.isEmpty {
                GeometryReader { proxy in
                    let topInset: CGFloat = activeVoicePlayback == nil ? 104 : 150
                    let bottomInset = emptyStateBottomInset
                    let availableHeight = max(0, proxy.size.height - topInset - bottomInset)

                    ChatConversationEmptyState(isSaved: conversation.entityType == "saved")
                        .padding(.horizontal, 34)
                        .frame(
                            width: proxy.size.width,
                            height: availableHeight,
                            alignment: .center
                        )
                        .offset(y: topInset)
                }
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(2)
            }

            chatChromeBlur
                .ignoresSafeArea(.container, edges: .vertical)
                .allowsHitTesting(false)

            if isFloatingDateVisible && actionMessage == nil {
                VStack(spacing: 0) {
                    ChatDatePill(label: floatingDateLabel)
                        .padding(.top, activeVoicePlayback == nil ? 88 : 136)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(6)
            }

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                if let activeVoicePlayback {
                    VoicePlaybackTopBar(
                        playback: activeVoicePlayback,
                        onToggle: { toggleTopVoicePlayback(activeVoicePlayback.attachmentId) },
                        onSpeed: { cycleVoicePlaybackSpeed(activeVoicePlayback.attachmentId) },
                        onClose: { stopTopVoicePlayback(activeVoicePlayback.attachmentId) }
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 7)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer(minLength: 0)
            }

            if isChatDetailsPresented {
                ChatPeerInfoPanel(
                    conversation: conversation,
                    messages: conversation.items,
                    onClose: { withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { isChatDetailsPresented = false } },
                    onOpenProfile: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { isChatDetailsPresented = false }
                        if conversation.kind != "group" {
                            app.openProfile(userId: conversation.peerId)
                        }
                    },
                    onAudioCall: { startCall(.audio) },
                    onVideoCall: { startCall(.video) },
                    onOpenAppearance: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                            isChatDetailsPresented = false
                        }
                        isChatAppearancePresented = true
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
                .zIndex(30)
            }

            if let activeCallKind {
                if isCallMinimized {
                    ChatCallMinimizedPill(
                        kind: activeCallKind,
                        conversation: conversation,
                        onExpand: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                                isCallMinimized = false
                            }
                        },
                        onEnd: endCall
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(40)
                } else {
                    ChatCallScreen(
                        kind: activeCallKind,
                        conversation: conversation,
                        onMinimize: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                                isCallMinimized = true
                            }
                        },
                        onEnd: endCall
                    )
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(40)
                }
            }

            if activeRecordingMode == .circle {
                CircleRecordingOverlay(
                    startedAt: recordingStartedAt,
                    isLocked: isRecordingLocked,
                    recorder: circleRecorder,
                    accentColor: chatAppearance.outgoingColor,
                    onCancel: cancelRecording,
                    onSend: { finishRecording(sendImmediately: false) }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(18)
            }
        }
        .coordinateSpace(name: "conversationRoot")
        .overlay(alignment: .bottom) {
            bottomSafeAreaChrome
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ChatComposerHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                .offset(y: -keyboardComposerLift)
        }
        .overlay {
            if let actionMessage {
                MessageActionOverlay(
                    message: actionMessage,
                    targetFrame: actionMessageFrame,
                    appearance: chatAppearance,
                    onCopy: {
                        if !actionMessage.body.isEmpty {
                            UIPasteboard.general.string = actionMessage.body
                        }
                        closeMessageActions()
                    },
                    onForward: {
                        beginForward(actionMessage)
                        closeMessageActions()
                    },
                    onEdit: {
                        beginEdit(actionMessage)
                        closeMessageActions()
                    },
                    onReact: { emoji in
                        toggleReactionPreservingComposer(actionMessage, emoji: emoji)
                        closeMessageActions()
                    },
                    onSelect: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            selectionMode = true
                            selectedMessageIds = [actionMessage.id]
                            self.actionMessage = nil
                        }
                    },
                    onDelete: {
                        deleteCandidateIds = [actionMessage.id]
                        closeMessageActions()
                    },
                    onCancel: closeMessageActions
                )
                .transition(.opacity)
            }
        }
        .onPreferenceChange(ChatComposerHeightPreferenceKey.self) { height in
            guard height > 0, abs(height - composerChromeHeight) > 0.5 else { return }
            composerChromeHeight = height
        }
        .sheet(isPresented: $isAttachmentSheetPresented) {
            ChatAttachmentSheet(attachments: $localAttachments, caption: $app.messageText)
        }
        .fullScreenCover(item: $localPreviewAttachment) { attachment in
            LocalAttachmentFullscreenPreview(
                attachment: attachment,
                accentColor: chatAppearance.outgoingColor
            )
        }
        .fullScreenCover(item: $activeMediaViewer) { viewer in
            ChatMediaViewer(
                state: viewer,
                onDismiss: { activeMediaViewer = nil }
            )
            .environmentObject(app)
        }
        .sheet(isPresented: $isChatAppearancePresented) {
            ChatAppearanceSheet(appearance: chatAppearance) { updated in
                chatAppearance = updated
                AloChatAppearanceStore.save(updated, for: conversation)
            }
        }
        .onAppear {
            chatAppearance = AloChatAppearanceStore.read(for: conversation)
            app.startConversationLive(conversation)
        }
        .onChange(of: conversation.peerId) { _, _ in
            chatAppearance = AloChatAppearanceStore.read(for: conversation)
            bottomAnchorFrame = .zero
            measuredMessageFrames = [:]
            shouldFollowKeyboardToBottom = false
            hasUserScrolledConversation = false
            didInitialScrollToBottom = false
            previousMessageCount = conversation.items.count
            hasInitialMessageFrameSnapshot = false
            app.startConversationLive(conversation)
        }
        .onChange(of: app.messageText) { _, _ in
            app.sendTypingIfNeeded()
        }
        .onChange(of: actionMessage?.id) { _, newValue in
            blocksParentSwipe = newValue != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenHeight = keyWindow?.screen.bounds.height ?? UIScreen.main.bounds.height
            let nextHeight = max(0, screenHeight - frame.minY)
            keyboardAnimationDuration = max(
                0.01,
                (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
            )
            keyboardAnimationCurveRaw =
                (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
                ?? UIView.AnimationCurve.easeInOut.rawValue

            if keyboardHeight == 0, nextHeight > 0 {
                shouldFollowKeyboardToBottom = ChatKeyboardFollowPolicy.shouldFollow(
                    hasUserScrolledConversation: hasUserScrolledConversation,
                    isNearBottom: isNearConversationBottom(tolerance: 48),
                    isEmpty: conversation.items.isEmpty
                )
            }

            withAnimation(keyboardTransitionAnimation) {
                keyboardHeight = nextHeight
            }

            if nextHeight == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + keyboardAnimationDuration) {
                    shouldFollowKeyboardToBottom = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackDidStart)) { notification in
            guard let attachmentId = notification.object as? String else { return }
            let title = (notification.userInfo?["title"] as? String)?.ifBlank("Голосовое сообщение") ?? "Голосовое сообщение"
            let speed = notification.userInfo?["speed"] as? Double
            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                activeVoicePlayback = ActiveVoicePlayback(
                    attachmentId: attachmentId,
                    title: title,
                    isPlaying: notification.userInfo?["isPlaying"] as? Bool ?? true,
                    speed: speed ?? activeVoicePlayback?.speed ?? 1
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackDidStop)) { notification in
            guard let attachmentId = notification.object as? String else { return }
            if activeVoicePlayback?.attachmentId == attachmentId {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                    activeVoicePlayback = nil
                }
            }
        }
        .onDisappear {
            floatingDateHideWorkItem?.cancel()
            blocksParentSwipe = false
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: selectionMode)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: activeVoicePlayback)
        .sheet(isPresented: forwardPickerBinding) {
            ForwardTargetSheet(
                conversations: app.bootstrap?.conversations ?? [],
                currentPeerId: conversation.peerId
            ) { target in
                guard let message = forwardPickerMessage else { return }
                applyForward(message, to: target)
            }
        }
        .confirmationDialog("Удалить сообщение", isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button("Удалить у меня", role: .destructive) {
                deleteSelected(mode: "me")
            }
            Button("Удалить у всех", role: .destructive) {
                deleteSelected(mode: "everyone")
            }
            Button("Отмена", role: .cancel) {
                deleteCandidateIds = []
            }
        }
    }

    @ViewBuilder
    private var bottomSafeAreaChrome: some View {
        bottomChrome
        .background {
            if keyboardHeight > 0 || composerFocused {
                chatKeyboardComposerScrim
                    .ignoresSafeArea(.container, edges: .bottom)
                    .offset(y: keyboardScrimDrop)
            }
        }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        if activeCallKind == nil && activeRecordingMode != .circle && !isChatDetailsPresented {
            Group {
                if selectionMode {
                    MessageSelectionToolbar(
                        count: selectedMessageIds.count,
                        onCancel: clearSelection,
                        onForward: beginForwardSelected,
                        onDelete: { deleteCandidateIds = Array(selectedMessageIds) }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    composer
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, ChatComposerMetrics.verticalChromePadding)
            .padding(.bottom, ChatComposerMetrics.verticalChromePadding)
        }
    }

    private var chatKeyboardComposerScrim: some View {
        ZStack {
            DarkChatBlurView(style: .dark)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.34), location: 0.34),
                            .init(color: .black.opacity(0.94), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color.black.opacity(0.28), location: 0.46),
                    .init(color: Color.black.opacity(0.82), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var keyboardComposerLift: CGFloat {
        guard keyboardHeight > 0,
              activeCallKind == nil,
              activeRecordingMode != .circle,
              !isChatDetailsPresented else { return 0 }
        return max(0, keyboardHeight - windowBottomSafeAreaInset + ChatComposerMetrics.keyboardGap)
    }

    private var keyboardScrimLift: CGFloat {
        guard keyboardHeight > 0,
              activeCallKind == nil,
              activeRecordingMode != .circle,
              !isChatDetailsPresented else { return 0 }
        return max(0, keyboardHeight - windowBottomSafeAreaInset - 2)
    }

    private var keyboardScrimDrop: CGFloat {
        max(0, keyboardComposerLift - keyboardScrimLift)
    }

    private var messageListBottomInset: CGFloat {
        guard activeCallKind == nil,
              activeRecordingMode != .circle,
              !isChatDetailsPresented else { return 8 }
        return composerChromeHeight + 8
    }

    private var emptyStateBottomInset: CGFloat {
        messageListBottomInset + keyboardComposerLift
    }

    private var keyboardMessagesLift: CGFloat {
        shouldFollowKeyboardToBottom ? keyboardComposerLift : 0
    }

    private var keyboardTransitionAnimation: Animation {
        let duration = keyboardAnimationDuration
        switch UIView.AnimationCurve(rawValue: keyboardAnimationCurveRaw) {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .linear:
            return .linear(duration: duration)
        case .easeInOut:
            return .easeInOut(duration: duration)
        case .none:
            return .easeOut(duration: duration)
        @unknown default:
            return .easeOut(duration: duration)
        }
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private var windowBottomSafeAreaInset: CGFloat {
        keyWindow?.safeAreaInsets.bottom ?? 0
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { !deleteCandidateIds.isEmpty },
            set: { isPresented in
                if !isPresented { deleteCandidateIds = [] }
            }
        )
    }

    private var forwardPickerBinding: Binding<Bool> {
        Binding(
            get: { forwardPickerMessage != nil },
            set: { isPresented in
                if !isPresented { forwardPickerMessage = nil }
            }
        )
    }

    private var messagesList: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: chatAppearance.compactSpacing ? 3 : 8) {
                        Color.clear.frame(height: 132)
                        ForEach(Array(conversation.items.enumerated()), id: \.element.id) { index, item in
                            if shouldShowDateSeparator(at: index) {
                                ChatDatePill(label: AloFormatters.messageDateLabel(item.createdAt))
                                    .padding(.vertical, 3)
                            }
                            ChatMessageRow(
                                message: item,
                                appearance: chatAppearance,
                                isMine: item.senderId == app.bootstrap?.me.id,
                                isPending: app.isChatMessagePending(item),
                                isSelected: selectedMessageIds.contains(item.id),
                                selectionMode: selectionMode,
                                onTap: { handleMessageTap(item) },
                                onReact: { emoji in
                                    toggleReactionPreservingComposer(item, emoji: emoji)
                                },
                                onOpenMediaGallery: { items, startIndex in
                                    activeMediaViewer = ChatMediaViewerState(items: items, startIndex: startIndex)
                                },
                                onLongPress: { frame in
                                    withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                                        actionMessageFrame = frame
                                        actionMessage = item
                                    }
                                }
                            )
                            .id(item.id)
                            .transition(.scale(scale: 0.86).combined(with: .opacity))
                            .background {
                                GeometryReader { rowProxy in
                                    Color.clear.preference(
                                        key: ChatMessageFramePreferenceKey.self,
                                        value: [item.id: rowProxy.frame(in: .named("conversationScroll"))]
                                    )
                                }
                            }
                        }
                        Color.clear
                            .frame(height: messageListBottomInset)
                            .id(bottomAnchorId)
                            .background {
                                GeometryReader { bottomProxy in
                                    Color.clear.preference(
                                        key: ChatBottomAnchorFramePreferenceKey.self,
                                        value: bottomProxy.frame(in: .named("conversationScroll"))
                                    )
                                }
                            }
                    }
                    .frame(minHeight: viewport.size.height, alignment: .bottom)
                    .padding(.horizontal, 14)
                    .animation(.spring(response: 0.38, dampingFraction: 0.86), value: conversation.items.map(\.id))
                }
                .scrollDismissesKeyboard(.interactively)
                .coordinateSpace(name: "conversationScroll")
                .onPreferenceChange(ChatMessageFramePreferenceKey.self, perform: updateFloatingDate)
                .onPreferenceChange(ChatBottomAnchorFramePreferenceKey.self) { frame in
                    bottomAnchorFrame = frame
                    if isBottomFrameNearViewport(frame, tolerance: 48) {
                        hasUserScrolledConversation = false
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .local)
                        .onChanged { value in
                            guard abs(value.translation.height) > abs(value.translation.width) else { return }
                            hasUserScrolledConversation = true
                        }
                )
                .simultaneousGesture(TapGesture().onEnded {
                    guard !preservesComposerFocusForReaction else { return }
                    composerFocused = false
                    AloKeyboard.dismiss()
                })
                .onAppear {
                    scrollViewportHeight = viewport.size.height
                    guard !didInitialScrollToBottom else { return }
                    didInitialScrollToBottom = true
                    scrollToBottom(proxy, animation: nil)
                }
                .onChange(of: viewport.size.height) { _, height in
                    scrollViewportHeight = height
                }
                .onChange(of: conversation.items.count) { _, newCount in
                    if newCount > previousMessageCount {
                        let lastMessage = conversation.items.last
                        let isOwnMessage = lastMessage?.senderId == app.bootstrap?.me.id
                        let shouldFollow = isOwnMessage || ChatKeyboardFollowPolicy.shouldFollow(
                            hasUserScrolledConversation: hasUserScrolledConversation,
                            isNearBottom: isNearConversationBottom(),
                            isEmpty: conversation.items.isEmpty
                        )
                        if shouldFollow {
                            scrollToBottom(proxy, animation: .easeOut(duration: 0.22))
                        }
                    }
                    previousMessageCount = newCount
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                composerFocused = false
                AloKeyboard.dismiss()
                app.closeConversation()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 42, height: 46)
                    .contentShape(Rectangle())
            }
            Button {
                composerFocused = false
                AloKeyboard.dismiss()
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    isChatDetailsPresented = true
                }
            } label: {
                HStack(spacing: 11) {
                    if conversation.entityType == "saved" {
                        SavedMessagesAvatar(size: 50)
                    } else {
                        AloAvatar(
                            name: conversation.title,
                            url: conversation.avatarUrl,
                            size: 50,
                            colorSeed: String(conversation.peerId)
                        )
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversation.title)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(AloTheme.text)
                            .lineLimit(1)
                        if conversation.isTyping {
                            TypingStatusText()
                        } else {
                            Text(conversation.online ? "в сети" : conversation.subtitle)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AloTheme.muted)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if conversation.entityType != "saved" {
                AloIconButton(systemName: "phone", action: { startCall(.audio) })
                AloIconButton(systemName: "video", action: { startCall(.video) })
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(AloTheme.surface.opacity(0.84))
        }
        .clipShape(Capsule())
        .overlay(Capsule().stroke(AloTheme.border, lineWidth: 1))
        .aloTouchBounce(pressedScale: 0.985)
    }

    private var composer: some View {
        let recordedDraft = localAttachments.first(where: \.isRecordedDraft)
        let visibleAttachments = localAttachments.filter { !$0.isRecordedDraft }
        let composerCornerRadius: CGFloat = app.messageText.count > 40 || app.messageText.contains("\n") ? 16 : 22

        return VStack(spacing: 8) {
            if let editingMessage {
                EditDraftBar(preview: editingMessage.body) {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                        self.editingMessage = nil
                        app.messageText = ""
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if app.pendingForwardDraft != nil {
                ForwardDraftBar(title: app.pendingForwardTitle.ifBlank("Переслать сообщение")) {
                    app.pendingForwardDraft = nil
                    app.pendingForwardTitle = ""
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !visibleAttachments.isEmpty {
                LocalAttachmentStrip(
                    attachments: visibleAttachments,
                    accentColor: chatAppearance.outgoingColor,
                    onAdd: { isAttachmentSheetPresented = true },
                    onOpen: { localPreviewAttachment = $0 }
                ) { attachment in
                    localAttachments.removeAll { $0.id == attachment.id }
                }
            }

            HStack(spacing: 8) {
                if activeRecordingMode == .circle {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: ChatComposerMetrics.controlSize)
                } else if let activeRecordingMode {
                    RecordingComposerPanel(
                        mode: activeRecordingMode,
                        startedAt: recordingStartedAt,
                        isLocked: isRecordingLocked,
                        circleRecorder: circleRecorder,
                        accentColor: chatAppearance.outgoingColor,
                        levels: audioRecorder.levels,
                        onCancel: cancelRecording,
                        onSend: { finishRecording(sendImmediately: true) }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let recordedDraft {
                    RecordedDraftComposerPanel(
                        attachment: recordedDraft,
                        duration: recordedDurations[recordedDraft.id] ?? 0,
                        levels: recordedWaveforms[recordedDraft.id] ?? recordedDraft.waveform,
                        accentColor: chatAppearance.outgoingColor,
                        onRemove: {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                localAttachments.removeAll { $0.id == recordedDraft.id }
                                recordedDurations[recordedDraft.id] = nil
                                recordedWaveforms[recordedDraft.id] = nil
                            }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    ChatComposerButton(systemName: "paperclip") {
                        isAttachmentSheetPresented = true
                    }
                    .transition(.scale(scale: 0.88).combined(with: .opacity))

                    TextField("Сообщение", text: $app.messageText, axis: .vertical)
                        .focused($composerFocused)
                        .foregroundStyle(AloTheme.text)
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .lineLimit(1...4)
                        .frame(minHeight: ChatComposerMetrics.controlSize)
                        .background {
                            RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                                .fill(AloTheme.surface)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                                .stroke(AloTheme.border, lineWidth: 1)
                        )
                        .onTapGesture { composerFocused = true }
                        .aloTouchBounce(pressedScale: 0.975)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if activeRecordingMode == .circle && !isRecordingLocked {
                    ChatRecordSendButton(
                        mode: recordingMode,
                        canSend: !sendDisabled,
                        isRecording: activeRecordingMode != nil,
                        accentColor: chatAppearance.outgoingColor,
                        onSend: sendCurrentDraft,
                        onToggleMode: toggleRecordingMode,
                        onHoldStart: startRecording,
                        onHoldEnd: finishRecording,
                        onLock: lockRecording,
                        onCancel: cancelRecording
                    )
                    .opacity(0.001)
                    .accessibilityHidden(true)
                } else if !isRecordingLocked {
                    ChatRecordSendButton(
                        mode: recordingMode,
                        canSend: !sendDisabled,
                        isRecording: activeRecordingMode != nil,
                        accentColor: chatAppearance.outgoingColor,
                        onSend: sendCurrentDraft,
                        onToggleMode: toggleRecordingMode,
                        onHoldStart: startRecording,
                        onHoldEnd: finishRecording,
                        onLock: lockRecording,
                        onCancel: cancelRecording
                    )
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: localAttachments.count)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: app.pendingForwardDraft != nil)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: editingMessage?.id)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: activeRecordingMode)
    }

    private var sendDisabled: Bool {
        app.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            localAttachments.isEmpty &&
            app.pendingForwardDraft == nil
    }

    private var chatBackground: some View {
        AloChatWallpaper(appearance: chatAppearance)
    }

    private var chatChromeBlur: some View {
        let bottomHeight: CGFloat = keyboardHeight > 0 ? 0 : 84

        return VStack(spacing: 0) {
            chatEdgeBlur(edge: .top, height: 92)
            Spacer(minLength: 0)
            if bottomHeight > 0 {
                chatEdgeBlur(edge: .bottom, height: bottomHeight)
            }
        }
    }

    private func chatEdgeBlur(edge: VerticalEdge, height: CGFloat) -> some View {
        let isTop = edge == .top
        let mask = LinearGradient(
            stops: isTop
                ? [
                    .init(color: .black.opacity(0.96), location: 0),
                    .init(color: .black.opacity(0.58), location: 0.36),
                    .init(color: .black.opacity(0.20), location: 0.72),
                    .init(color: .clear, location: 1)
                ]
                : [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.20), location: 0.28),
                    .init(color: .black.opacity(0.58), location: 0.64),
                    .init(color: .black.opacity(0.96), location: 1)
                ],
            startPoint: .top,
            endPoint: .bottom
        )

        return ZStack {
            DarkChatBlurView(style: .dark)
                .mask(mask)

            LinearGradient(
                stops: isTop
                    ? [
                        .init(color: Color.black.opacity(0.64), location: 0),
                        .init(color: Color.black.opacity(0.24), location: 0.50),
                        .init(color: .clear, location: 1)
                    ]
                    : [
                        .init(color: .clear, location: 0),
                        .init(color: Color.black.opacity(0.24), location: 0.50),
                        .init(color: Color.black.opacity(0.66), location: 1)
                    ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: isTop
                    ? [Color.black.opacity(0.30), Color.clear]
                    : [Color.clear, Color.black.opacity(0.32)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: height)
    }

    private func shouldShowDateSeparator(at index: Int) -> Bool {
        guard conversation.items.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        return AloFormatters.messageDayKey(conversation.items[index - 1].createdAt) !=
            AloFormatters.messageDayKey(conversation.items[index].createdAt)
    }

    private func updateFloatingDate(_ frames: [Int: CGRect]) {
        defer { measuredMessageFrames = frames }
        guard !frames.isEmpty else { return }

        let visibleTop: CGFloat = 108
        guard let topEntry = frames
            .filter({ $0.value.maxY > visibleTop })
            .min(by: { $0.value.minY < $1.value.minY }),
              let message = conversation.items.first(where: { $0.id == topEntry.key }) else {
            return
        }

        guard hasInitialMessageFrameSnapshot else {
            hasInitialMessageFrameSnapshot = true
            floatingDateLabel = AloFormatters.messageDateLabel(message.createdAt)
            return
        }

        let previousY = measuredMessageFrames[topEntry.key]?.minY
        let didMove = previousY.map { abs($0 - topEntry.value.minY) > 0.5 } ?? true
        guard didMove else { return }

        floatingDateHideWorkItem?.cancel()
        floatingDateLabel = AloFormatters.messageDateLabel(message.createdAt)
        withAnimation(.easeOut(duration: 0.15)) {
            isFloatingDateVisible = true
        }

        let workItem = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.15)) {
                isFloatingDateVisible = false
            }
        }
        floatingDateHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func isNearConversationBottom(tolerance: CGFloat = 96) -> Bool {
        if conversation.items.isEmpty { return true }
        return isBottomFrameNearViewport(bottomAnchorFrame, tolerance: tolerance)
    }

    private func isBottomFrameNearViewport(_ frame: CGRect, tolerance: CGFloat) -> Bool {
        guard scrollViewportHeight > 0, frame != .zero else { return false }
        return frame.maxY <= scrollViewportHeight + tolerance
    }

    private func topVisibleMessageId(visibleTop: CGFloat = 108) -> Int? {
        measuredMessageFrames
            .filter { $0.value.maxY > visibleTop }
            .min(by: { $0.value.minY < $1.value.minY })?
            .key
    }

    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animation: Animation?,
        delay: TimeInterval = 0
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let animation {
                withAnimation(animation) {
                    proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        }
    }

    private var bottomAnchorId: String {
        "conversation-bottom-\(conversation.kind)-\(conversation.peerId)-\(conversation.roomId)"
    }

    private func handleMessageTap(_ message: AloChatMessage) {
        guard selectionMode else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            if selectedMessageIds.contains(message.id) {
                selectedMessageIds.remove(message.id)
            } else {
                selectedMessageIds.insert(message.id)
            }
            if selectedMessageIds.isEmpty {
                selectionMode = false
            }
        }
    }

    private func clearSelection() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            selectionMode = false
            selectedMessageIds = []
        }
    }

    private func closeMessageActions() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            actionMessage = nil
            actionMessageFrame = nil
        }
    }

    private func toggleReactionPreservingComposer(_ message: AloChatMessage, emoji: String) {
        let shouldKeepKeyboardVisible = composerFocused || keyboardHeight > 0
        if shouldKeepKeyboardVisible {
            preservesComposerFocusForReaction = true
        }

        app.toggleMessageReaction(message, emoji: emoji)

        guard shouldKeepKeyboardVisible else { return }
        composerFocused = true
        DispatchQueue.main.async {
            composerFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                preservesComposerFocusForReaction = false
            }
        }
    }

    private func toggleTopVoicePlayback(_ attachmentId: String) {
        NotificationCenter.default.post(name: .aloVoicePlaybackToggleRequested, object: attachmentId)
    }

    private func cycleVoicePlaybackSpeed(_ attachmentId: String) {
        guard let playback = activeVoicePlayback else { return }
        let nextSpeed: Double
        switch playback.speed {
        case ..<1.25:
            nextSpeed = 1.5
        case ..<1.75:
            nextSpeed = 2.0
        default:
            nextSpeed = 1.0
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            activeVoicePlayback = ActiveVoicePlayback(
                attachmentId: attachmentId,
                title: playback.title,
                isPlaying: playback.isPlaying,
                speed: nextSpeed
            )
        }
        NotificationCenter.default.post(
            name: .aloVoicePlaybackSpeedChanged,
            object: attachmentId,
            userInfo: ["speed": nextSpeed]
        )
        AloHaptics.selection()
    }

    private func stopTopVoicePlayback(_ attachmentId: String) {
        NotificationCenter.default.post(name: .aloVoicePlaybackStopRequested, object: attachmentId)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            activeVoicePlayback = nil
        }
    }

    private func beginForward(_ message: AloChatMessage) {
        forwardPickerMessage = message
    }

    private func beginEdit(_ message: AloChatMessage) {
        guard message.senderId == app.bootstrap?.me.id, !message.body.isEmpty else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            editingMessage = message
            app.pendingForwardDraft = nil
            app.pendingForwardTitle = ""
            localAttachments = []
            app.messageText = message.body
        }
    }

    private func beginForwardSelected() {
        guard let firstId = selectedMessageIds.first,
              let message = conversation.items.first(where: { $0.id == firstId }) else { return }
        beginForward(message)
    }

    private func applyForward(_ message: AloChatMessage, to target: AloConversationSummary) {
        app.pendingForwardDraft = AloForwardMeta(userId: message.senderId, messageId: message.id, user: nil)
        app.pendingForwardTitle = "Переслать сообщение"
        forwardPickerMessage = nil
        clearSelection()
        if target.peerId != conversation.peerId {
            app.openConversation(target)
        }
    }

    private func deleteSelected(mode: String) {
        let ids = deleteCandidateIds
        deleteCandidateIds = []
        app.deleteMessages(ids, mode: mode) {
            clearSelection()
        }
    }

    private func sendCurrentDraft() {
        if let editingMessage {
            app.editMessage(editingMessage, body: app.messageText) {
                self.editingMessage = nil
                self.app.messageText = ""
            }
            return
        }

        app.sendMessage(
            localAttachments: localAttachments,
            forwardFrom: app.pendingForwardDraft
        ) {
            localAttachments = []
            recordedDurations = [:]
            recordedWaveforms = [:]
            app.pendingForwardDraft = nil
            app.pendingForwardTitle = ""
        }
    }

    private func toggleRecordingMode() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            recordingMode = recordingMode == .voice ? .circle : .voice
        }
        AloHaptics.selection()
    }

    private func startRecording() {
        guard sendDisabled, activeRecordingMode == nil else { return }
        recordingStartedAt = Date()
        isRecordingLocked = false
        activeRecordingMode = recordingMode
        AloHaptics.impact(.medium)
        switch recordingMode {
        case .voice:
            audioRecorder.start()
        case .circle:
            circleRecorder.start()
        }
    }

    private func lockRecording() {
        guard activeRecordingMode != nil, !isRecordingLocked else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            isRecordingLocked = true
        }
        AloHaptics.notification(.success)
    }

    private func finishRecording() {
        finishRecording(sendImmediately: false)
    }

    private func finishRecording(sendImmediately: Bool) {
        guard let mode = activeRecordingMode else { return }
        let duration = Date().timeIntervalSince(recordingStartedAt)
        activeRecordingMode = nil
        isRecordingLocked = false
        guard duration > 0.55 else {
            audioRecorder.cancel()
            circleRecorder.cancel()
            return
        }
        AloHaptics.impact(.light)
        switch mode {
        case .voice:
            let waveform = audioRecorder.levels
            audioRecorder.stop { attachment, extractedWaveform in
                guard let attachment else { return }
                let finalWaveform = extractedWaveform.isEmpty ? waveform : extractedWaveform
                handleRecordedAttachment(
                    attachment.replacingWaveform(finalWaveform),
                    duration: duration,
                    waveform: finalWaveform,
                    sendImmediately: sendImmediately
                )
            }
        case .circle:
            circleRecorder.stop { attachment in
                guard let attachment else { return }
                handleRecordedAttachment(attachment, duration: duration, waveform: [], sendImmediately: sendImmediately)
            }
        }
    }

    private func cancelRecording() {
        guard activeRecordingMode != nil else { return }
        activeRecordingMode = nil
        isRecordingLocked = false
        audioRecorder.cancel()
        circleRecorder.cancel()
        AloHaptics.notification(.warning)
    }

    private func handleRecordedAttachment(_ attachment: AloLocalAttachment, duration: TimeInterval, waveform: [CGFloat], sendImmediately: Bool) {
        if sendImmediately {
            app.sendMessage(localAttachments: [attachment], forwardFrom: nil)
            return
        }
        let storedWaveform = waveform.isEmpty ? attachment.waveform : waveform
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            localAttachments.removeAll { $0.isRecordedDraft }
            recordedDurations = recordedDurations.filter { key, _ in
                localAttachments.contains { $0.id == key }
            }
            recordedWaveforms = recordedWaveforms.filter { key, _ in
                localAttachments.contains { $0.id == key }
            }
            localAttachments.append(attachment)
            recordedDurations[attachment.id] = duration
            recordedWaveforms[attachment.id] = storedWaveform
        }
    }

    private func startCall(_ kind: ChatCallKind) {
        Task {
            await app.calls.startCall(
                conversation: conversation,
                video: kind == .video
            )
        }
    }

    private func endCall() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            activeCallKind = nil
            isCallMinimized = false
        }
    }
}

private struct AloChatWallpaper: View {
    let appearance: AloChatAppearance

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .topLeading) {
                ZStack {
                    LinearGradient(
                        colors: [
                            appearance.wallpaperTop,
                            appearance.wallpaperBottom
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Image("AloChatPattern")
                        .resizable()
                        .scaledToFill()
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .clipped()
                        .opacity(appearance.patternIntensity)
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
            }
            .clipped()
    }

    private var canvasSize: CGSize {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .bounds.size ?? UIScreen.main.bounds.size
    }
}

private struct ChatConversationEmptyState: View {
    let isSaved: Bool

    var body: some View {
        let cornerRadius: CGFloat = isSaved ? 24 : 20

        VStack(spacing: isSaved ? 12 : 11) {
            if isSaved {
                SavedMessagesIntroIcon(size: 72)
            } else {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 62, height: 62)
            }

            Text(isSaved ? "Избранное" : "Сообщений пока нет")
                .font(.system(size: isSaved ? 22 : 19, weight: .bold, design: .rounded))
                .foregroundStyle(AloTheme.text)

            Text(
                isSaved
                    ? "Личное облако для сообщений, фото, видео и файлов. Доступно на всех ваших устройствах."
                    : "Напишите первое сообщение, чтобы начать диалог."
            )
            .font(.system(size: isSaved ? 15 : 14, weight: .medium))
            .foregroundStyle(AloTheme.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, isSaved ? 24 : 20)
        .padding(.vertical, isSaved ? 22 : 18)
        .frame(maxWidth: isSaved ? 286 : 268)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AloTheme.surface.opacity(isSaved ? 0.34 : 0.46))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isSaved ? 0.12 : 0.08),
                            Color.white.opacity(isSaved ? 0.025 : 0),
                            Color.black.opacity(isSaved ? 0.14 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if isSaved {
                ChatGlassGrain(opacity: 0.12)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(isSaved ? 0.16 : 0.11), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isSaved ? 0.26 : 0.18), radius: isSaved ? 24 : 18, y: 10)
    }
}

private struct ChatGlassGrain: View {
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            let dotCount = Int(max(90, min(260, size.width * size.height / 360)))
            for index in 0..<dotCount {
                let x = deterministicUnit(index, salt: 19) * size.width
                let y = deterministicUnit(index, salt: 47) * size.height
                let alpha = 0.18 + deterministicUnit(index, salt: 83) * 0.22
                let radius = 0.42 + deterministicUnit(index, salt: 131) * 0.58
                let color = index.isMultiple(of: 3)
                    ? Color.black.opacity(opacity * alpha)
                    : Color.white.opacity(opacity * alpha)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)),
                    with: .color(color)
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func deterministicUnit(_ index: Int, salt: Int) -> Double {
        let value = sin(Double(index * 12_989 + salt * 78_233)) * 43_758.5453
        return value - floor(value)
    }
}

struct ChatAppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AloChatAppearance
    let onApply: (AloChatAppearance) -> Void

    init(appearance: AloChatAppearance, onApply: @escaping (AloChatAppearance) -> Void) {
        _draft = State(initialValue: appearance)
        self.onApply = onApply
    }

    var body: some View {
        ZStack {
            AloTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sheetHeader
                    preview
                    presets

                    appearanceSection(title: "Фон") {
                        ChatHueControl(title: "Обои", value: $draft.wallpaperHue)
                        ChatLevelControl(title: "Яркость фона", value: $draft.wallpaperBrightness, range: 0.02...0.42)
                        ChatLevelControl(title: "Интенсивность узора", value: $draft.patternIntensity, range: 0.03...0.18)
                    }

                    appearanceSection(title: "Сообщения") {
                        ChatHueControl(title: "Исходящие сообщения", value: $draft.outgoingHue)
                        ChatLevelControl(title: "Яркость исходящих", value: $draft.outgoingBrightness, range: 0.45...1)
                        ChatHueControl(title: "Входящие сообщения", value: $draft.incomingHue)
                        ChatLevelControl(title: "Яркость входящих", value: $draft.incomingBrightness, range: 0.07...0.42)
                    }

                    appearanceSection(title: "Интервалы") {
                        Toggle(isOn: $draft.compactSpacing) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Компактные интервалы")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Уменьшает расстояние между сообщениями")
                                    .font(.system(size: 13))
                                    .foregroundStyle(AloTheme.muted)
                            }
                        }
                        .tint(draft.outgoingColor)
                    }

                    Button {
                        draft = AloChatAppearance()
                    } label: {
                        Label("Сбросить оформление", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(AloTheme.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.98))
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 34)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                onApply(draft)
                dismiss()
            } label: {
                Text("Применить")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(draft.outgoingColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(AloTheme.background.opacity(0.96))
        }
        .preferredColorScheme(.dark)
    }

    private var sheetHeader: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(AloTheme.muted.opacity(0.48))
                .frame(width: 42, height: 5)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Оформление чатов")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("Единые настройки для всех чатов")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AloTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(AloTheme.surfaceRaised)
                        .clipShape(Circle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.90))
            }
        }
    }

    private var preview: some View {
        ZStack {
            AloChatWallpaper(appearance: draft)
            VStack(spacing: draft.compactSpacing ? 5 : 10) {
                Text("Сегодня")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color.black.opacity(0.36))
                    .clipShape(Capsule())
                HStack {
                    Spacer()
                    Text("Встретимся в восемь?")
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(draft.outgoingColor)
                        .clipShape(Capsule())
                }
                HStack {
                    Text("Да, договорились")
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(draft.incomingColor)
                        .clipShape(Capsule())
                    Spacer()
                }
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(18)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AloTheme.border, lineWidth: 1))
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Темы")
                .font(.system(size: 18, weight: .bold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AloChatAppearance.presets, id: \.id) { preset in
                        Button {
                            draft = preset.value
                        } label: {
                            VStack(spacing: 7) {
                                ZStack {
                                    LinearGradient(
                                        colors: [preset.value.wallpaperTop, preset.value.wallpaperBottom],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    VStack(spacing: 7) {
                                        HStack {
                                            Spacer()
                                            Capsule().fill(preset.value.outgoingColor).frame(width: 54, height: 18)
                                        }
                                        HStack {
                                            Capsule().fill(preset.value.incomingColor).frame(width: 46, height: 18)
                                            Spacer()
                                        }
                                    }
                                    .padding(9)
                                }
                                .frame(width: 104, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .stroke(draft.preset == preset.id ? Color.white : Color.white.opacity(0.10), lineWidth: draft.preset == preset.id ? 2 : 1)
                                )
                                Text(preset.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .frame(width: 104)
                        }
                        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.96))
                    }
                }
            }
        }
    }

    private func appearanceSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AloTheme.muted)
            VStack(spacing: 18, content: content)
                .padding(16)
                .background(AloTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AloTheme.border, lineWidth: 1))
        }
    }
}

private struct ChatHueControl: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Circle()
                    .fill(Color(hue: value / 360, saturation: 0.82, brightness: 0.96))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
            }
            Slider(value: $value, in: 0...359)
                .tint(Color(hue: value / 360, saturation: 0.82, brightness: 0.96))
        }
    }
}

private struct ChatLevelControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AloTheme.muted)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct TypingStatusText: View {
    @State private var dotCount = 1
    private let timer = Timer.publish(every: 0.42, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("печатает" + String(repeating: ".", count: dotCount))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AloTheme.accent)
            .lineLimit(1)
            .onReceive(timer) { _ in
                dotCount = dotCount == 3 ? 1 : dotCount + 1
            }
    }
}

private struct ChatMessageRow: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var isPressingBubble = false
    @State private var bubbleFrame: CGRect = .zero
    @State private var longPressWorkItem: DispatchWorkItem?
    @State private var didOpenLongPressMenu = false
    @State private var didMoveDuringPress = false
    @State private var suppressMediaOpenUntil = Date.distantPast

    let message: AloChatMessage
    let appearance: AloChatAppearance
    let isMine: Bool
    let isPending: Bool
    let isSelected: Bool
    let selectionMode: Bool
    let onTap: () -> Void
    let onReact: (String) -> Void
    let onOpenMediaGallery: ([AloMediaItem], Int) -> Void
    let onLongPress: (CGRect) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine { Spacer(minLength: 52) }
            if selectionMode && !isMine {
                selectionIndicator
            }
            bubble
                .scaleEffect(isSelected ? 0.985 : (isPressingBubble ? 0.94 : 1))
                .overlay(selectionOverlay)
                .background(bubbleFrameReader)
                .onTapGesture {
                    guard !shouldSuppressMediaOpen else { return }
                    onTap()
                }
                .simultaneousGesture(voiceScrubGuardGesture)
                .onLongPressGesture(
                    minimumDuration: 0.24,
                    maximumDistance: 18,
                    pressing: handleBubblePressing,
                    perform: {
                        openLongPressMenuIfNeeded()
                    }
                )
            if selectionMode && isMine {
                selectionIndicator
            }
            if !isMine { Spacer(minLength: 52) }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isSelected)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: selectionMode)
        .animation(.spring(response: 0.31, dampingFraction: 0.58), value: isPressingBubble)
        .animation(.spring(response: 0.30, dampingFraction: 0.66), value: reactionsAnimationKey)
    }

    private var bubbleFrameReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    updateBubbleFrame(proxy.frame(in: .named("conversationRoot")))
                }
                .onChange(of: proxy.frame(in: .named("conversationRoot"))) { _, newFrame in
                    updateBubbleFrame(newFrame)
                }
        }
    }

    private func updateBubbleFrame(_ newFrame: CGRect) {
        guard newFrame != bubbleFrame else { return }
        DispatchQueue.main.async {
            bubbleFrame = newFrame
        }
    }

    private func handleBubblePressing(_ pressing: Bool) {
        withAnimation(.spring(response: 0.31, dampingFraction: 0.58)) {
            isPressingBubble = pressing
        }
        if pressing {
            didMoveDuringPress = false
            longPressWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                openLongPressMenuIfNeeded()
            }
            longPressWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        } else {
            longPressWorkItem?.cancel()
            longPressWorkItem = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                didOpenLongPressMenu = false
                didMoveDuringPress = false
            }
        }
    }

    private var shouldSuppressMediaOpen: Bool {
        didOpenLongPressMenu || Date() < suppressMediaOpenUntil
    }

    private func openLongPressMenuIfNeeded() {
        guard !didOpenLongPressMenu, !didMoveDuringPress else { return }
        suppressMediaOpenUntil = Date().addingTimeInterval(0.55)
        didOpenLongPressMenu = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            didOpenLongPressMenu = false
            didMoveDuringPress = false
        }
        onLongPress(bubbleFrame)
    }

    private var voiceScrubGuardGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .local)
            .onChanged { value in
                guard voiceOnly else { return }
                if abs(value.translation.width) > abs(value.translation.height) {
                    didMoveDuringPress = true
                    longPressWorkItem?.cancel()
                }
            }
            .onEnded { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    didMoveDuringPress = false
                }
            }
    }

    @ViewBuilder
    private var bubble: some View {
        if circleOnly {
            circleBubble
        } else if voiceOnly {
            voiceBubble
        } else if simpleTextOnly {
            textOnlyBubble
        } else {
            standardBubble
        }
    }

    private var voiceBubble: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            if let forwardFrom = message.forwardFrom {
                Text("Переслано от \(forwardFrom.user?.name ?? "пользователя")")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isMine ? Color.white.opacity(0.86) : AloTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(voiceAttachments) { attachment in
                VoiceMessageAttachmentView(
                    attachment: attachment,
                    isMine: isMine,
                    accentColor: appearance.outgoingColor,
                    showMessageMeta: attachment.id == voiceAttachments.last?.id,
                    createdAt: message.createdAt,
                    editedAt: message.editedAt,
                    isRead: !message.readAt.isEmpty,
                    isPending: isPending,
                    onLongPress: { onLongPress(bubbleFrame) }
                )
            }

            inlineReactionFooter(showMeta: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 252, alignment: isMine ? .trailing : .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
    }

    private var messageTimestamp: some View {
        HStack(spacing: 3) {
            if !message.editedAt.isEmpty {
                Text("изм.")
            }
            Text(AloFormatters.messageTime(message.createdAt))
            if isMine {
                MessageReadStatusChecks(isRead: !message.readAt.isEmpty, isSending: isPending)
            }
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Color.white.opacity(0.72))
    }

    private var standardBubble: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
            if let forwardFrom = message.forwardFrom {
                Text("Переслано от \(forwardFrom.user?.name ?? "пользователя")")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isMine ? Color.white.opacity(0.86) : AloTheme.accent)
            }

            if !mediaAttachments.isEmpty {
                MessageMediaGrid(
                    attachments: mediaAttachments,
                    isTapSuppressed: { shouldSuppressMediaOpen },
                    onOpenAt: { index in
                        openMediaAttachment(at: index)
                    },
                    onLongPress: openLongPressMenuIfNeeded
                )
                    .frame(maxWidth: 310)
            }

            ForEach(voiceAttachments) { attachment in
                VoiceMessageAttachmentView(
                    attachment: attachment,
                    isMine: isMine,
                    accentColor: appearance.outgoingColor,
                    onLongPress: { onLongPress(bubbleFrame) }
                )
                    .frame(maxWidth: 292)
            }

            ForEach(circleAttachments) { attachment in
                CircleMessageAttachmentView(attachment: attachment, accentColor: appearance.outgoingColor)
                    .frame(width: 184, height: 184)
            }

            if let callLogMeta {
                ChatCallLogAttachment(
                    meta: callLogMeta,
                    isMine: isMine,
                    isRead: !message.readAt.isEmpty,
                    createdAt: message.createdAt
                )
            } else if !message.body.isEmpty {
                Text(message.body)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if callLogMeta == nil {
                inlineReactionFooter(showMeta: true)
            }
        }
        .padding(.horizontal, callLogMeta == nil ? bubbleHorizontalPadding : 10)
        .padding(.vertical, callLogMeta == nil ? (attachmentsOnly ? 4 : 10) : 8)
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(RoundedRectangle(cornerRadius: messageBubbleCornerRadius, style: .continuous))
    }

    private var textOnlyBubble: some View {
        Group {
            if message.reactions.isEmpty {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(message.body)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.white)
                        .fixedSize(horizontal: false, vertical: true)

                    messageTimestamp
                        .layoutPriority(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(message.body)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.white)
                        .fixedSize(horizontal: false, vertical: true)

                    inlineReactionFooter(showMeta: true)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(
            RoundedRectangle(
                cornerRadius: messageBubbleCornerRadius,
                style: .continuous
            )
        )
    }

    private var circleBubble: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            if let forwardFrom = message.forwardFrom {
                Text("Переслано от \(forwardFrom.user?.name ?? "пользователя")")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isMine ? Color.white.opacity(0.86) : AloTheme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background((isMine ? appearance.outgoingColor : appearance.incomingColor).opacity(0.9))
                    .clipShape(Capsule())
            }

            ForEach(circleAttachments) { attachment in
                CircleMessageAttachmentView(attachment: attachment, accentColor: appearance.outgoingColor)
                    .frame(width: 196, height: 196)
                    .overlay(alignment: .bottomTrailing) {
                        Text(AloFormatters.messageTime(message.createdAt))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.46))
                            .clipShape(Capsule())
                            .padding(10)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !message.reactions.isEmpty {
                            MessageReactionStrip(
                                reactions: Array(message.reactions.prefix(3)),
                                onTap: { reaction in onReact(reaction.emoji) }
                            )
                            .offset(x: 8, y: 11)
                            .transition(.scale(scale: 0.72).combined(with: .opacity))
                        }
                    }
                    .padding(.bottom, message.reactions.isEmpty ? 0 : 12)
            }
        }
    }

    @ViewBuilder
    private func inlineReactionFooter(showMeta: Bool) -> some View {
        if !message.reactions.isEmpty || showMeta {
            HStack(alignment: .bottom, spacing: 8) {
                if !message.reactions.isEmpty {
                    MessageReactionStrip(
                        reactions: Array(message.reactions.prefix(3)),
                        onTap: { reaction in onReact(reaction.emoji) }
                    )
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                }

                if showMeta {
                    HStack(spacing: 4) {
                        if !message.editedAt.isEmpty {
                            Text("изменено")
                        }
                        Text(AloFormatters.messageTime(message.createdAt))
                        if isMine {
                            MessageReadStatusChecks(isRead: !message.readAt.isEmpty, isSending: isPending)
                        }
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .layoutPriority(1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var callLogMeta: ChatCallLogMeta? {
        message.chatCallLogMeta
    }

    private var simpleTextOnly: Bool {
        callLogMeta == nil &&
        message.forwardFrom == nil &&
        !message.body.isEmpty &&
        mediaAttachments.isEmpty &&
        voiceAttachments.isEmpty &&
        circleAttachments.isEmpty
    }

    private var messageBubbleCornerRadius: CGFloat {
        if message.body.contains("\n") || message.body.count > 34 {
            return 16
        }
        return attachmentsOnly ? 18 : 22
    }

    private var reactionsAnimationKey: String {
        message.reactions
            .map { "\($0.emoji)-\($0.count)-\($0.reactedByMe)" }
            .joined(separator: "|")
    }

    private var attachments: [AloMessageAttachment] {
        if !message.attachments.isEmpty { return message.attachments }
        guard !message.attachmentUrl.isEmpty else { return [] }
        return [
            AloMessageAttachment([
                "type": message.attachmentType,
                "url": message.attachmentUrl,
                "name": message.attachmentName
            ])
        ]
    }

    private var mediaAttachments: [AloMessageAttachment] {
        attachments.filter { !$0.isVoiceLike && !$0.isCircleLike }
    }

    private func openMediaAttachment(at index: Int) {
        guard !shouldSuppressMediaOpen else { return }
        if selectionMode {
            onTap()
            return
        }
        let items = mediaAttachments.map(\.chatMediaItem)
        guard items.indices.contains(index) else { return }
        onOpenMediaGallery(items, index)
    }

    private var voiceAttachments: [AloMessageAttachment] {
        attachments.filter(\.isVoiceLike)
    }

    private var circleAttachments: [AloMessageAttachment] {
        attachments.filter(\.isCircleLike)
    }

    private var attachmentsOnly: Bool {
        !mediaAttachments.isEmpty && voiceAttachments.isEmpty && circleAttachments.isEmpty && message.body.isEmpty
    }

    private var circleOnly: Bool {
        mediaAttachments.isEmpty && voiceAttachments.isEmpty && !circleAttachments.isEmpty && message.body.isEmpty
    }

    private var voiceOnly: Bool {
        mediaAttachments.isEmpty && !voiceAttachments.isEmpty && circleAttachments.isEmpty && message.body.isEmpty
    }

    private var bubbleHorizontalPadding: CGFloat {
        if attachmentsOnly { return 4 }
        if voiceOnly { return 10 }
        return 16
    }

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(isSelected ? AloTheme.accent : AloTheme.muted)
            .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AloTheme.accent, lineWidth: 2)
        }
    }
}

private struct ChatCallLogAttachment: View {
    let meta: ChatCallLogMeta
    let isMine: Bool
    let isRead: Bool
    let createdAt: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: meta.callType == "video" ? "video.fill" : "phone.fill")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(iconColor.opacity(isMine ? 0.18 : 0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(meta.menuTitle(isMine: isMine))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(secondaryText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .monospacedDigit()
            }

            Spacer(minLength: 10)

            HStack(spacing: 3) {
                Text(AloFormatters.messageTime(createdAt))
                if isMine {
                    MessageReadStatusChecks(isRead: isRead)
                }
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.72))
            .offset(y: 9)
        }
        .frame(width: 210, alignment: .leading)
    }

    private var iconColor: Color {
        switch meta.status {
        case "missed", "declined":
            return Color(red: 1.0, green: 0.42, blue: 0.42)
        default:
            return isMine ? Color.white.opacity(0.92) : AloTheme.accent
        }
    }

    private var secondaryText: String {
        if meta.durationSec > 0 {
            let minutes = meta.durationSec / 60
            let seconds = meta.durationSec % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
        return AloFormatters.messageTime(createdAt)
    }
}

private struct MessageReactionStrip: View {
    let reactions: [AloMessageReaction]
    let onTap: (AloMessageReaction) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { reaction in
                Button {
                    AloHaptics.selection()
                    onTap(reaction)
                } label: {
                    HStack(spacing: 3) {
                        Text(reaction.emoji)
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(reaction.reactedByMe ? Color.white.opacity(0.25) : Color.white.opacity(0.13))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(reaction.reactedByMe ? 0.30 : 0.08), lineWidth: 1))
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.84))
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.52).combined(with: .opacity),
                    removal: .scale(scale: 0.72).combined(with: .opacity)
                ))
            }
        }
        .fixedSize()
        .animation(.spring(response: 0.32, dampingFraction: 0.64), value: reactionAnimationKey)
    }

    private var reactionAnimationKey: String {
        reactions.map { "\($0.emoji)-\($0.count)-\($0.reactedByMe)" }.joined(separator: "|")
    }
}

private struct MessageMediaGrid: View {
    let attachments: [AloMessageAttachment]
    var isTapSuppressed: () -> Bool = { false }
    var onOpenAt: ((Int) -> Void)?
    var onLongPress: (() -> Void)?

    var body: some View {
        Group {
            switch attachments.count {
            case 0:
                EmptyView()
            case 1:
                attachmentCell(attachments[0], index: 0)
                    .frame(height: 220)
            case 2:
                HStack(spacing: 2) {
                    attachmentCell(attachments[0], index: 0)
                    attachmentCell(attachments[1], index: 1)
                }
                .frame(height: 190)
            case 3:
                HStack(spacing: 2) {
                    attachmentCell(attachments[0], index: 0)
                    VStack(spacing: 2) {
                        attachmentCell(attachments[1], index: 1)
                        attachmentCell(attachments[2], index: 2)
                    }
                }
                .frame(height: 230)
            default:
                LazyVGrid(columns: gridColumns, spacing: 2) {
                    ForEach(Array(attachments.prefix(4).enumerated()), id: \.element.id) { index, attachment in
                        attachmentCell(
                            attachment,
                            index: index,
                            extraCount: index == 3 ? max(0, attachments.count - 4) : 0
                        )
                            .frame(height: 142)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]
    }

    private func attachmentCell(_ attachment: AloMessageAttachment, index: Int, extraCount: Int = 0) -> some View {
        RemoteAttachmentCell(attachment: attachment, extraCount: extraCount)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isTapSuppressed() else { return }
                onOpenAt?(index)
            }
            .onLongPressGesture(minimumDuration: 0.22, maximumDistance: 18) {
                onLongPress?()
            }
    }
}

private struct VoiceMessageAttachmentView: View {
    @EnvironmentObject private var app: AloAppModel
    let attachment: AloMessageAttachment
    let isMine: Bool
    let accentColor: Color
    var showMessageMeta = false
    var createdAt = ""
    var editedAt = ""
    var isRead = false
    var isPending = false
    let onLongPress: () -> Void

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var endObserver: NSObjectProtocol?
    @State private var isSeeking = false
    @State private var hasStartedScrubbing = false
    @State private var playbackSpeed: Double = 1

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.92))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                GeometryReader { proxy in
                    VoiceScrubberWaveform(
                        progress: progress,
                        levels: attachment.waveform,
                        activeColor: Color.white,
                        inactiveColor: Color.white.opacity(0.34)
                    )
                        .contentShape(Rectangle())
                        .gesture(scrubGesture(width: proxy.size.width))
                }
                .frame(height: 20)

                HStack(alignment: .center, spacing: 6) {
                    Text(voiceTimeLabel)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.76))
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    if showMessageMeta {
                        HStack(alignment: .center, spacing: 3) {
                            if !editedAt.isEmpty {
                                Text("изм.")
                            }
                            Text(AloFormatters.messageTime(createdAt))
                            if isMine {
                                MessageReadStatusChecks(isRead: isRead, isSending: isPending)
                                    .scaleEffect(0.86, anchor: .center)
                            }
                        }
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .monospacedDigit()
                    }
                }
                .frame(height: 12, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 39, alignment: .leading)
        .contentShape(Rectangle())
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackDidStart)) { notification in
            guard let playingAttachmentId = notification.object as? String,
                  playingAttachmentId != attachment.id,
                  isPlaying else {
                return
            }
            player?.pause()
            isPlaying = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackToggleRequested)) { notification in
            guard (notification.object as? String) == attachment.id else { return }
            togglePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackStopRequested)) { notification in
            guard (notification.object as? String) == attachment.id else { return }
            stopPlayback()
            NotificationCenter.default.post(name: .aloVoicePlaybackDidStop, object: attachment.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackSpeedChanged)) { notification in
            guard (notification.object as? String) == attachment.id,
                  let speed = notification.userInfo?["speed"] as? Double else { return }
            playbackSpeed = speed
            if isPlaying {
                player?.rate = Float(speed)
            }
        }
        .onDisappear(perform: stopPlayback)
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, currentTime / duration))
    }

    private var voiceTimeLabel: String {
        isPlaying || currentTime > 0 ? formatTime(currentTime) : formatTime(duration)
    }

    private func togglePlayback() {
        if player == nil {
            preparePlayer()
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            NotificationCenter.default.post(
                name: .aloVoicePlaybackDidStart,
                object: attachment.id,
                userInfo: [
                    "title": attachment.name.ifBlank("Голосовое сообщение"),
                    "speed": playbackSpeed,
                    "isPlaying": false
                ]
            )
        } else {
            NotificationCenter.default.post(
                name: .aloVoicePlaybackDidStart,
                object: attachment.id,
                userInfo: [
                    "title": attachment.name.ifBlank("Голосовое сообщение"),
                    "speed": playbackSpeed,
                    "isPlaying": true
                ]
            )
            player.rate = Float(playbackSpeed)
            isPlaying = true
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
            if !hasStartedScrubbing && distance < 6 {
                    return
                }
                hasStartedScrubbing = true
                isSeeking = true
                let location = max(0, min(width, value.startLocation.x + value.translation.width))
                let normalized = min(1, max(0, location / max(1, width)))
                seek(to: normalized * duration, playAfterSeek: isPlaying)
            }
            .onEnded { _ in
                hasStartedScrubbing = false
                isSeeking = false
            }
    }

    private func seek(to seconds: Double, playAfterSeek: Bool) {
        if player == nil {
            preparePlayer()
        }
        let target = max(0, min(duration, seconds))
        currentTime = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { _ in
            if playAfterSeek {
                player?.rate = Float(playbackSpeed)
            }
        }
    }

    private func preparePlayer() {
        guard let url = app.api.absoluteURL(attachment.url) else { return }
        let player = AloSecureMediaStore.shared.makePlayer(url: url)
        self.player = player
        if let item = player.currentItem {
            Task {
                let loadedDuration = try? await item.asset.load(.duration)
                if let seconds = loadedDuration?.seconds,
                   seconds.isFinite,
                   seconds > 0 {
                    await MainActor.run { duration = seconds }
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600),
            queue: .main
        ) { time in
            if !isSeeking {
                currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            isPlaying = false
            currentTime = 0
            player.seek(to: .zero)
            NotificationCenter.default.post(name: .aloVoicePlaybackDidStop, object: attachment.id)
        }
    }

    private func stopPlayback() {
        let wasPlaying = isPlaying
        player?.pause()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        timeObserver = nil
        player = nil
        isPlaying = false
        if wasPlaying {
            NotificationCenter.default.post(name: .aloVoicePlaybackDidStop, object: attachment.id)
        }
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VoiceScrubberWaveform: View {
    let progress: Double
    var levels: [CGFloat] = []
    var activeColor: Color = .white
    var inactiveColor: Color = Color.white.opacity(0.34)

    private let fallbackLevels: [CGFloat] = [0.20, 0.68, 0.38, 0.92, 0.52, 0.78, 0.24, 0.72, 0.38, 0.88, 0.30, 0.58, 0.82, 0.42, 0.70, 0.35, 0.90, 0.44, 0.62, 0.22, 0.78, 0.50, 0.28, 0.68, 0.36, 0.86, 0.52, 0.64]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(barHeights.enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(barColor(at: index))
                    .frame(width: 2.6, height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var barHeights: [CGFloat] {
        let source = levels.isEmpty ? fallbackLevels : Array(levels.prefix(36))
        return source.map { level in
            6 + max(0.08, min(1, level)) * 15
        }
    }

    private func barColor(at index: Int) -> Color {
        let threshold = Double(index + 1) / Double(max(1, barHeights.count))
        return threshold <= progress ? activeColor : inactiveColor
    }
}

private struct CircleMessageAttachmentView: View {
    @EnvironmentObject private var app: AloAppModel
    let attachment: AloMessageAttachment
    let accentColor: Color

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserver: Any?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(AloTheme.background)

                if let player {
                    CircleVideoPlayerView(player: player)
                        .clipShape(Circle())
                        .allowsHitTesting(false)
                } else {
                    Image(systemName: "video.circle.fill")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(accentColor)
                }

                if !isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 64, height: 64)
                        .background(Color.black.opacity(0.36))
                        .clipShape(Circle())
                        .transition(.scale(scale: 0.75).combined(with: .opacity))
                }

                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: 4)
                    .padding(3)

                Circle()
                    .trim(from: 0, to: max(0.002, progress))
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
            }
            .contentShape(Circle())
            .gesture(playbackGesture(size: proxy.size))
        }
        .clipShape(Circle())
        .onAppear(perform: preparePlayer)
        .onDisappear(perform: stopPlayback)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isPlaying)
    }

    private func playbackGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard isOnProgressRing(value.location, size: size) else { return }
                isScrubbing = true
                seek(to: progressFraction(at: value.location, size: size))
            }
            .onEnded { _ in
                if isScrubbing {
                    isScrubbing = false
                } else {
                    togglePlayback()
                }
            }
    }

    private func preparePlayer() {
        guard player == nil, let url = app.api.absoluteURL(attachment.url) else { return }
        let prepared = AloSecureMediaStore.shared.makePlayer(url: url)
        player = prepared
        prepared.seek(to: CMTime(seconds: 0.08, preferredTimescale: 600))
        timeObserver = prepared.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.08, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !isScrubbing else { return }
            let total = prepared.currentItem?.duration.seconds ?? 0
            guard total.isFinite, total > 0 else { return }
            duration = total
            progress = min(1, max(0, time.seconds / total))
            if progress >= 0.999 {
                prepared.pause()
                prepared.seek(to: .zero)
                progress = 0
                isPlaying = false
            }
        }
    }

    private func togglePlayback() {
        preparePlayer()
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func seek(to fraction: Double) {
        preparePlayer()
        guard let player else { return }
        let total = duration > 0 ? duration : (player.currentItem?.duration.seconds ?? 0)
        guard total.isFinite, total > 0 else { return }
        progress = fraction
        player.seek(
            to: CMTime(seconds: total * fraction, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func isOnProgressRing(_ location: CGPoint, size: CGSize) -> Bool {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let distance = hypot(location.x - center.x, location.y - center.y)
        let radius = min(size.width, size.height) / 2
        return abs(distance - radius) <= 28
    }

    private func progressFraction(at location: CGPoint, size: CGSize) -> Double {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var angle = atan2(location.y - center.y, location.x - center.x) + .pi / 2
        if angle < 0 { angle += .pi * 2 }
        return min(1, max(0, angle / (.pi * 2)))
    }

    private func stopPlayback() {
        player?.pause()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
        isPlaying = false
        progress = 0
    }
}

private struct RemoteAttachmentCell: View {
    @EnvironmentObject private var app: AloAppModel
    let attachment: AloMessageAttachment
    var extraCount = 0

    var body: some View {
        ZStack {
            AloTheme.background
            if let localImage {
                Image(uiImage: localImage)
                    .resizable()
                    .scaledToFill()
            } else if let url = previewURL {
                AloAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        RemoteMediaLoadingPlaceholder(isVideo: isVideo, isFailed: true)
                    case .empty:
                        RemoteMediaLoadingPlaceholder(isVideo: isVideo, isFailed: false)
                    @unknown default:
                        RemoteMediaLoadingPlaceholder(isVideo: isVideo, isFailed: false)
                    }
                }
            } else if isVideo {
                RemoteVideoPosterFallback(title: attachment.name.ifBlank("Видео"))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: isVideo ? "play.rectangle.fill" : "doc.fill")
                        .font(.system(size: 28, weight: .bold))
                    Text(attachment.name.ifBlank(isVideo ? "Видео" : "Файл"))
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(AloTheme.text)
                .padding(12)
            }

            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 50, height: 50)
                    .background(Color.black.opacity(0.46))
                    .clipShape(Circle())
            }

            if extraCount > 0 {
                Color.black.opacity(0.42)
                Text("+\(extraCount)")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white)
            }
        }
        .clipped()
    }

    private var isImage: Bool {
        attachment.type == "image" || attachment.url.lowercased().hasImageExtension
    }

    private var isVideo: Bool {
        attachment.type == "video" || attachment.url.lowercased().hasVideoExtension
    }

    private var previewURL: URL? {
        guard isImage || isVideo else { return nil }
        let source = previewSource
        guard !source.isEmpty else { return nil }
        return app.api.absoluteURL(source)
    }

    private var localImage: UIImage? {
        let value = previewSource
        guard value.hasPrefix("data:image"),
              let commaIndex = value.firstIndex(of: ",") else { return nil }
        let encoded = String(value[value.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return UIImage(data: data)
    }

    private var previewSource: String {
        if !attachment.posterUrl.isEmpty {
            return attachment.posterUrl
        }
        return isImage ? attachment.url : ""
    }
}

private struct RemoteMediaLoadingPlaceholder: View {
    let isVideo: Bool
    let isFailed: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.black.opacity(0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blur(radius: 8)
                .scaleEffect(1.08)

            VStack(spacing: 8) {
                if isFailed {
                    Image(systemName: isVideo ? "play.slash.fill" : "photo.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.78))
                    Text("Нет связи")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.78))
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color.white.opacity(0.86))
                    Text("Загрузка")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
            }
            .padding(12)
            .background(Color.black.opacity(isFailed ? 0.30 : 0.20))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct RemoteVideoPosterFallback: View {
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.38),
                    Color.white.opacity(0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 9) {
                Image(systemName: "play.fill")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 50, height: 50)
                    .background(Color.black.opacity(0.42))
                    .clipShape(Circle())

                Text(title.ifBlank("Видео"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(1)
            }
            .padding(12)
        }
    }
}

private struct ChatMediaViewerState: Identifiable {
    let id = UUID()
    let items: [AloMediaItem]
    let startIndex: Int
}

private struct ChatMediaViewer: View {
    @EnvironmentObject private var app: AloAppModel
    let state: ChatMediaViewerState
    let onDismiss: () -> Void

    @State private var selectedIndex: Int

    init(state: ChatMediaViewerState, onDismiss: @escaping () -> Void) {
        self.state = state
        self.onDismiss = onDismiss
        _selectedIndex = State(initialValue: min(max(0, state.startIndex), max(0, state.items.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedIndex) {
                ForEach(state.items.indices, id: \.self) { index in
                    viewerContent(for: state.items[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: state.items.count > 1 ? .automatic : .never))

            VStack {
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .frame(width: 52, height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)

                Spacer()

                if let caption = currentItem?.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.44))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 18)
                        .padding(.bottom, 24)
                }
            }
        }
    }

    @ViewBuilder
    private func viewerContent(for item: AloMediaItem) -> some View {
        let source = item.posterUrl.ifBlank(item.url)
        if let image = localImage(from: source) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.type.lowercased().contains("video"), let url = app.api.absoluteURL(item.url.ifBlank(item.posterUrl)) {
            ChatMediaVideoPlayer(url: url)
        } else if let url = app.api.absoluteURL(source) {
            AloAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure:
                    RemoteMediaLoadingPlaceholder(isVideo: false, isFailed: true)
                case .empty:
                    RemoteMediaLoadingPlaceholder(isVideo: false, isFailed: false)
                @unknown default:
                    RemoteMediaLoadingPlaceholder(isVideo: false, isFailed: false)
                }
            }
        } else {
            RemoteMediaLoadingPlaceholder(isVideo: false, isFailed: true)
        }
    }

    private func localImage(from value: String) -> UIImage? {
        guard value.hasPrefix("data:image"),
              let commaIndex = value.firstIndex(of: ",") else { return nil }
        let encoded = String(value[value.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return UIImage(data: data)
    }

    private var currentItem: AloMediaItem? {
        guard state.items.indices.contains(selectedIndex) else { return state.items.first }
        return state.items[selectedIndex]
    }
}

private struct ChatMediaVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(AloTheme.accent)
            }
        }
        .onAppear {
            if player == nil {
                player = AloSecureMediaStore.shared.makePlayer(url: url)
            }
        }
        .onDisappear {
            player?.pause()
        }
    }
}

private struct LocalAttachmentFullscreenPreview: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: AloLocalAttachment
    let accentColor: Color

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 44)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.86))
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if attachment.type == "image", let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if attachment.type == "video" {
            LocalDraftVideoPlayer(attachment: attachment)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(accentColor.opacity(0.28), lineWidth: 1)
                )
        } else {
            VStack(spacing: 14) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(accentColor)
                Text(attachment.name.ifBlank("Файл"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct LocalDraftVideoPlayer: View {
    let attachment: AloLocalAttachment
    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(AloTheme.accent)
            }
        }
        .onAppear(perform: preparePlayer)
        .onDisappear(perform: cleanup)
    }

    private func preparePlayer() {
        guard player == nil else { return }
        let fileExtension = attachment.mime.contains("quicktime") ? "mov" : "mp4"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-local-preview-\(attachment.id.uuidString).\(fileExtension)")
        do {
            try attachment.data.write(to: url, options: .atomic)
            temporaryURL = url
            player = AloSecureMediaStore.shared.makePlayer(url: url)
        } catch {
            temporaryURL = nil
        }
    }

    private func cleanup() {
        player?.pause()
        player = nil
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        temporaryURL = nil
    }
}

private struct LocalAttachmentStrip: View {
    let attachments: [AloLocalAttachment]
    let accentColor: Color
    let onAdd: () -> Void
    let onOpen: (AloLocalAttachment) -> Void
    let onRemove: (AloLocalAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(attachmentTitle, systemImage: "photo.on.rectangle.angled")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(AloTheme.text)
                    Text(attachments.count == 1 ? "Отправится с подписью" : "Отправится одним сообщением")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(AloTheme.muted)
                }
                Spacer(minLength: 8)
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 28, height: 28)
                        .background(accentColor)
                        .clipShape(Circle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.84))
            }

            LocalAttachmentPreviewGrid(
                attachments: attachments,
                accentColor: accentColor,
                onOpen: onOpen,
                onRemove: onRemove
            )
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AloTheme.surface.opacity(0.68))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AloTheme.border.opacity(0.50), lineWidth: 1)
        )
    }

    private var attachmentTitle: String {
        let photoCount = attachments.filter { $0.type == "image" }.count
        let videoCount = attachments.filter { $0.type == "video" }.count
        if photoCount > 0 && videoCount > 0 {
            return "\(photoCount) фото, \(videoCount) видео"
        }
        if photoCount > 0 {
            return photoCount == 1 ? "Фото с подписью" : "\(photoCount) фото"
        }
        if videoCount > 0 {
            return videoCount == 1 ? "Видео с подписью" : "\(videoCount) видео"
        }
        return "\(attachments.count) вложений"
    }
}

private struct LocalAttachmentPreviewGrid: View {
    let attachments: [AloLocalAttachment]
    let accentColor: Color
    let onOpen: (AloLocalAttachment) -> Void
    let onRemove: (AloLocalAttachment) -> Void

    var body: some View {
        Group {
            switch attachments.count {
            case 0:
                EmptyView()
            case 1:
                tile(attachments[0], index: 0)
                    .frame(height: 118)
            case 2:
                HStack(spacing: 3) {
                    tile(attachments[0], index: 0)
                    tile(attachments[1], index: 1)
                }
                .frame(height: 112)
            case 3:
                HStack(spacing: 3) {
                    tile(attachments[0], index: 0)
                    VStack(spacing: 3) {
                        tile(attachments[1], index: 1)
                        tile(attachments[2], index: 2)
                    }
                }
                .frame(height: 144)
            default:
                LazyVGrid(columns: gridColumns, spacing: 3) {
                    ForEach(Array(attachments.prefix(4).enumerated()), id: \.element.id) { index, attachment in
                        tile(attachment, index: index, overlayText: index == 3 && attachments.count > 4 ? "+\(attachments.count - 4)" : nil)
                            .frame(height: 72)
                    }
                }
        }
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]
    }

    private func tile(_ attachment: AloLocalAttachment, index: Int, overlayText: String? = nil) -> some View {
        LocalAttachmentPreviewTile(
            attachment: attachment,
            accentColor: accentColor,
            index: index,
            overlayText: overlayText,
            onOpen: { onOpen(attachment) },
            onRemove: { onRemove(attachment) }
        )
    }
}

private struct LocalAttachmentPreviewTile: View {
    let attachment: AloLocalAttachment
    let accentColor: Color
    let index: Int
    let overlayText: String?
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LocalAttachmentVisual(attachment: attachment, accentColor: accentColor)

            if let overlayText {
                Color.black.opacity(0.48)
                Text(overlayText)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack {
                Spacer()
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Color.black.opacity(0.52))
                        .clipShape(Capsule())

                    if attachment.type == "video" {
                        Label("Видео", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Color.black.opacity(0.52))
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 0)
                }
                .padding(7)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.60))
                    .clipShape(Circle())
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.82))
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture(perform: onOpen)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct LocalAttachmentVisual: View {
    let attachment: AloLocalAttachment
    let accentColor: Color

    var body: some View {
        ZStack {
            AloTheme.surfaceRaised
            if attachment.type == "image", let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if attachment.type == "video" {
                LocalVideoAttachmentPreview(attachment: attachment, accentColor: accentColor)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(AloTheme.text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct LocalVideoAttachmentPreview: View {
    let attachment: AloLocalAttachment
    let accentColor: Color
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [AloTheme.background, accentColor.opacity(0.28)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            Image(systemName: "play.fill")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(accentColor)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.92))
                .clipShape(Circle())
        }
        .onAppear(perform: loadThumbnail)
    }

    private func loadThumbnail() {
        guard thumbnail == nil else { return }
        let data = attachment.data
        let mime = attachment.mime
        let id = attachment.id.uuidString
        Task.detached(priority: .userInitiated) {
            let fileExtension = mime.contains("quicktime") ? "mov" : "mp4"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("alo-media-preview-\(id).\(fileExtension)")
            do {
                try data.write(to: url, options: .atomic)
                defer { try? FileManager.default.removeItem(at: url) }
                let asset = AVAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                let cgImage = try generator.copyCGImage(
                    at: CMTime(seconds: 0.10, preferredTimescale: 600),
                    actualTime: nil
                )
                let image = UIImage(cgImage: cgImage)
                await MainActor.run {
                    thumbnail = image
                }
            } catch {
                await MainActor.run {
                    thumbnail = nil
                }
            }
        }
    }
}

private enum ChatRecordingMode: Equatable {
    case voice
    case circle

    var title: String {
        switch self {
        case .voice: return "Голосовое"
        case .circle: return "Кружок"
        }
    }

    var shortTitle: String {
        switch self {
        case .voice: return "ГС"
        case .circle: return "Кружок"
        }
    }

    var systemImage: String {
        switch self {
        case .voice: return "mic.fill"
        case .circle: return "video.circle.fill"
        }
    }

    var tint: Color {
        AloTheme.surface
    }
}

private enum ChatCallKind {
    case audio
    case video

    var title: String {
        switch self {
        case .audio: return "Аудиозвонок"
        case .video: return "Видеозвонок"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: return "phone.fill"
        case .video: return "video.fill"
        }
    }
}

private extension ChatCallLogMeta {
    func menuTitle(isMine: Bool) -> String {
        let isVideo = callType == "video"
        let isGroup = scope == "group"
        switch status {
        case "missed":
            return isMine ? "Звонок без ответа" : "Пропущенный звонок"
        case "declined":
            return isMine ? "Звонок отклонён" : "Отклонённый звонок"
        default:
            if isGroup && isVideo { return "Групповой видеозвонок" }
            if isGroup { return "Групповой звонок" }
            if isVideo { return isMine ? "Исходящий видеозвонок" : "Входящий видеозвонок" }
            return isMine ? "Исходящий звонок" : "Входящий звонок"
        }
    }
}

private extension AloChatMessage {
    var chatCallLogMeta: ChatCallLogMeta? {
        let candidates = [attachmentName, body, attachmentUrl].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for raw in candidates {
            if let meta = ChatCallLogMeta(rawJSON: raw) {
                return meta
            }
        }
        guard attachmentType == "call" else { return nil }
        return ChatCallLogMeta(callType: "voice", status: "ended", durationSec: 0, scope: "")
    }
}

private extension ChatCallLogMeta {
    init?(rawJSON: String) {
        guard rawJSON.contains("call") || rawJSON.contains("callType") else { return nil }
        guard let data = rawJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let kind = json.string("kind")
        let callTypeValue = json.string("callType").ifBlank(json.string("type"))
        guard kind == "call" || !callTypeValue.isEmpty || json["durationSec"] != nil else { return nil }
        callType = callTypeValue.ifBlank("voice")
        status = json.string("status").ifBlank("ended")
        durationSec = json.int("durationSec")
        scope = json.string("scope")
    }
}

private enum ChatComposerMetrics {
    static let controlSize: CGFloat = 42
    static let verticalChromePadding: CGFloat = 5
    static let keyboardGap: CGFloat = 4
    static let collapsedChromeHeight = controlSize + verticalChromePadding * 2
}

enum ChatKeyboardFollowPolicy {
    static func shouldFollow(
        hasUserScrolledConversation: Bool,
        isNearBottom: Bool,
        isEmpty: Bool
    ) -> Bool {
        isEmpty || !hasUserScrolledConversation || isNearBottom
    }
}

private struct ChatRecordSendButton: View {
    let mode: ChatRecordingMode
    let canSend: Bool
    let isRecording: Bool
    let accentColor: Color
    let onSend: () -> Void
    let onToggleMode: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    let onLock: () -> Void
    let onCancel: () -> Void

    @State private var isPressing = false
    @State private var didStartHold = false
    @State private var didLockRecording = false
    @State private var didCancelRecording = false
    @State private var pressToken = UUID()

    var body: some View {
        ZStack {
            Circle()
                .fill(buttonFill)
            if isRecording {
                Circle()
                    .stroke(accentColor.opacity(0.65), lineWidth: 3)
                    .scaleEffect(1.16)
                    .opacity(0.75)
            }
            Image(systemName: canSend ? "arrow.right" : mode.systemImage)
                .font(.system(size: canSend ? 19 : 18, weight: .bold))
                .foregroundStyle(canSend ? Color.white : AloTheme.muted)
        }
        .frame(width: ChatComposerMetrics.controlSize, height: ChatComposerMetrics.controlSize)
        .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
        .scaleEffect(isPressing ? 0.84 : 1)
        .contentShape(Circle())
        .gesture(recordGesture)
        .accessibilityLabel(canSend ? "Отправить" : mode.title)
        .animation(.spring(response: 0.27, dampingFraction: 0.48), value: isPressing)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: mode)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }

    private var buttonFill: Color {
        if canSend { return accentColor }
        return mode.tint
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isPressing {
                    isPressing = true
                    didStartHold = false
                    didLockRecording = false
                    didCancelRecording = false
                    let token = UUID()
                    pressToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        guard isPressing, pressToken == token, !canSend else { return }
                        didStartHold = true
                        onHoldStart()
                    }
                }

                if didStartHold, !didLockRecording, value.translation.height < -44 {
                    didLockRecording = true
                    onLock()
                }

                if didStartHold, !didCancelRecording, !didLockRecording, value.translation.width < -64 {
                    didCancelRecording = true
                    onCancel()
                }
            }
            .onEnded { _ in
                let shouldFinishRecording = didStartHold
                let shouldStayLocked = didLockRecording
                let shouldCancel = didCancelRecording
                isPressing = false
                didStartHold = false
                didLockRecording = false
                didCancelRecording = false
                if canSend {
                    AloHaptics.impact(.light)
                    onSend()
                } else if shouldCancel {
                    return
                } else if shouldFinishRecording && !shouldStayLocked {
                    onHoldEnd()
                } else if shouldStayLocked {
                    return
                } else {
                    onToggleMode()
                }
            }
    }
}

private struct RecordingComposerPanel: View {
    let mode: ChatRecordingMode
    let startedAt: Date
    let isLocked: Bool
    @ObservedObject var circleRecorder: ChatCircleRecorder
    let accentColor: Color
    let levels: [CGFloat]
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            recordingIcon

            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                        Text(isLocked ? "Запись зафиксирована" : recordingTitle)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(recordingTime(context.date.timeIntervalSince(startedAt)))
                            .monospacedDigit()
                    }
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(AloTheme.text)

                    if mode == .voice {
                        VoiceWaveform(levels: levels, activeColor: accentColor)
                            .frame(height: 23)
                    } else {
                        Capsule()
                            .fill(accentColor.opacity(0.18))
                            .frame(height: 6)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(accentColor)
                                    .frame(width: isLocked ? 86 : 54, height: 6)
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            if isLocked {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(AloTheme.muted)
                        .frame(width: 40, height: 40)
                        .background(AloTheme.surfaceRaised)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button(action: onSend) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 44, height: 44)
                        .background(accentColor)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, minHeight: mode == .circle ? 68 : 58, alignment: .leading)
        .padding(.leading, mode == .circle ? 7 : 8)
        .padding(.trailing, isLocked ? 7 : 12)
        .padding(.vertical, 6)
        .background {
            Capsule().fill(AloTheme.surface)
            Capsule().stroke(AloTheme.border, lineWidth: 1)
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: isLocked)
    }

    @ViewBuilder
    private var recordingIcon: some View {
        if mode == .circle {
            CircleCameraPreview(session: circleRecorder.session)
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay(Circle().stroke(accentColor.opacity(0.9), lineWidth: 2))
                .shadow(color: accentColor.opacity(0.22), radius: 12)
        } else {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.18))
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.red)
            }
            .frame(width: 44, height: 44)
        }
    }

    private var recordingTitle: String {
        switch mode {
        case .voice: return "Запись"
        case .circle: return "Кружок"
        }
    }

    private func recordingTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CircleRecordingOverlay: View {
    let startedAt: Date
    let isLocked: Bool
    @ObservedObject var recorder: ChatCircleRecorder
    let accentColor: Color
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .background(Color.black.opacity(0.28))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 54)

                CircleCameraPreview(session: recorder.session)
                    .frame(width: 286, height: 286)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.32), radius: 24, y: 14)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))

                Spacer(minLength: 36)

                HStack(spacing: 10) {
                    CircleIconButton(systemName: "camera.rotate", action: { recorder.switchCamera() })
                    CircleIconButton(systemName: recorder.isTorchEnabled ? "bolt.fill" : "bolt.slash", action: { recorder.toggleTorch() })

                    TimelineView(.periodic(from: startedAt, by: 0.2)) { context in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 7, height: 7)
                            Text(formatTime(context.date.timeIntervalSince(startedAt)))
                                .font(.system(size: 16, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                            Spacer(minLength: 10)
                            Button("Отмена", action: onCancel)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(accentColor)
                        }
                    }
                    .foregroundStyle(AloTheme.text)
                    .padding(.horizontal, 13)
                    .frame(height: 46)
                    .background(Color.black.opacity(0.38))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))

                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 30, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .frame(width: 76, height: 76)
                            .background(accentColor)
                            .clipShape(Circle())
                            .shadow(color: accentColor.opacity(0.40), radius: 14)
                    }
                    .buttonStyle(.plain)
                    .opacity(isLocked ? 1 : 0.72)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isLocked)
        .onAppear { AloHaptics.impact(.medium) }
    }

    private func formatTime(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CircleIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 46, height: 46)
                .background(Color.black.opacity(0.38))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.84))
    }
}

private struct VoicePlaybackTopBar: View {
    let playback: ActiveVoicePlayback
    let onToggle: () -> Void
    let onSpeed: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(AloTheme.text)
                    .frame(width: 30, height: 30)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(playback.title)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(AloTheme.text)
                    .lineLimit(1)
                Text("Голосовое сообщение")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(AloTheme.muted)
            }

            Spacer(minLength: 8)

            Button(action: onSpeed) {
                Text(speedTitle)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(AloTheme.text)
                    .frame(minWidth: 34, minHeight: 30)
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AloTheme.surface.opacity(0.80))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AloTheme.border.opacity(0.45), lineWidth: 1)
        )
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: playback.isPlaying)
    }

    private var speedTitle: String {
        playback.speed == 1 ? "1x" : String(format: "%.1fx", playback.speed)
    }
}

private struct VoiceWaveform: View {
    var levels: [CGFloat] = []
    var activeColor: Color = AloTheme.accent
    private let bars: [CGFloat] = [0.28, 0.68, 0.42, 0.88, 0.56, 0.74, 0.34, 0.92, 0.48, 0.78, 0.36, 0.66]

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(Array(renderedBars.enumerated()), id: \.offset) { index, value in
                    Capsule()
                        .fill(activeColor)
                        .frame(width: 4, height: 26 * animatedHeight(value, index: index, phase: phase))
                }
            }
        }
    }

    private var renderedBars: [CGFloat] {
        let cleaned = levels.suffix(18).map { max(0.12, min(1, $0)) }
        guard !cleaned.isEmpty else { return bars }
        return Array(cleaned)
    }

    private func animatedHeight(_ base: CGFloat, index: Int, phase: TimeInterval) -> CGFloat {
        if !levels.isEmpty { return max(0.18, min(1, base)) }
        let wave = CGFloat((sin(phase * 5 + Double(index) * 0.65) + 1) / 2)
        return max(0.22, min(1, base * 0.62 + wave * 0.46))
    }
}

private struct ChatComposerButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AloTheme.muted)
                .frame(width: ChatComposerMetrics.controlSize, height: ChatComposerMetrics.controlSize)
                .background(AloTheme.surface)
                .clipShape(Circle())
                .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.90))
    }
}

private struct LocalAttachmentThumb: View {
    let attachment: AloLocalAttachment

    var body: some View {
        ZStack {
            AloTheme.surfaceRaised
            if attachment.type == "image", let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: attachment.type == "video" ? "play.rectangle.fill" : "doc.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AloTheme.text)
            }
        }
        .frame(width: 74, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }
}

private struct RecordedDraftComposerPanel: View {
    let attachment: AloLocalAttachment
    let duration: TimeInterval
    let levels: [CGFloat]
    let accentColor: Color
    let onRemove: () -> Void

    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        HStack(spacing: 12) {
            if attachment.isLocalCircleLike {
                LocalCircleDraftPreview(attachment: attachment, accentColor: accentColor)
                    .frame(width: 46, height: 46)
            } else {
                Button(action: togglePlayback) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.92))
                        Image(systemName: buttonIcon)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(accentColor)
                    }
                    .frame(width: 42, height: 42)
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.86))
            }

            VStack(alignment: .leading, spacing: 5) {
                if attachment.isLocalVoiceLike {
                    VoiceWaveform(levels: levels, activeColor: accentColor)
                        .frame(height: 26)
                } else {
                    Text("Кружок готов к отправке")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AloTheme.text)
                }

                Text(formatTime(duration))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AloTheme.muted)
                    .monospacedDigit()
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 38, height: 38)
                    .background(AloTheme.surfaceRaised)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .background(AloTheme.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(AloTheme.border, lineWidth: 1))
        .onDisappear(perform: stopPlayback)
    }

    private var buttonIcon: String {
        if attachment.isLocalCircleLike { return "video.circle.fill" }
        return isPlaying ? "pause.fill" : "play.fill"
    }

    private func togglePlayback() {
        guard attachment.isLocalVoiceLike else { return }
        if audioPlayer == nil {
            audioPlayer = try? AVAudioPlayer(data: attachment.data)
            audioPlayer?.prepareToPlay()
        }
        guard let audioPlayer else { return }
        if isPlaying {
            audioPlayer.pause()
            isPlaying = false
        } else {
            audioPlayer.play()
            isPlaying = true
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
    }

    private func formatTime(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.isFinite ? value.rounded() : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct LocalCircleDraftPreview: View {
    let attachment: AloLocalAttachment
    let accentColor: Color

    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            Circle().fill(AloTheme.background)
            if let player {
                CircleVideoPlayerView(player: player)
                    .clipShape(Circle())
                    .allowsHitTesting(false)
            }
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(Color.black.opacity(0.42))
                .clipShape(Circle())
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(accentColor.opacity(0.72), lineWidth: 2))
        .contentShape(Circle())
        .onTapGesture(perform: togglePlayback)
        .onAppear(perform: preparePlayer)
        .onDisappear(perform: cleanup)
    }

    private func preparePlayer() {
        guard player == nil else { return }
        let fileExtension = attachment.mime.contains("quicktime") ? "mov" : "mp4"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-circle-preview-\(attachment.id.uuidString).\(fileExtension)")
        do {
            try attachment.data.write(to: url, options: .atomic)
            temporaryURL = url
            let prepared = AVPlayer(url: url)
            prepared.seek(to: CMTime(seconds: 0.08, preferredTimescale: 600))
            player = prepared
        } catch {
            temporaryURL = nil
        }
    }

    private func togglePlayback() {
        preparePlayer()
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func cleanup() {
        player?.pause()
        player = nil
        isPlaying = false
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        temporaryURL = nil
    }
}

private struct MessageReadStatusChecks: View {
    let isRead: Bool
    var isSending = false

    var body: some View {
        Group {
            if isSending {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color.white.opacity(0.78))
                    .scaleEffect(0.48)
                    .frame(width: 13, height: 13)
            } else {
                ZStack {
                    Image(systemName: "checkmark")
                        .offset(x: isRead ? -3.2 : 0)
                    if isRead {
                        Image(systemName: "checkmark")
                            .offset(x: 3.2)
                    }
                }
                .font(.system(size: 11.5, weight: .heavy))
                .foregroundStyle(Color.white.opacity(isRead ? 0.86 : 0.68))
                .frame(width: isRead ? 16 : 9, height: 10)
            }
        }
        .accessibilityLabel(isSending ? "Отправляется" : (isRead ? "Прочитано" : "Отправлено"))
    }
}

private let aloMessageReactionEmojis = [
    "❤️", "🔥", "😂", "😮", "👏", "👍", "👎", "🥰",
    "😁", "🤩", "🤔", "🤯", "😱", "😢", "😭", "😡", "🎉",
    "💯", "🤝", "🙏", "👌", "😎", "👀", "🤗", "🫡",
    "🤪", "😴", "🤓", "👻", "🎃", "💔", "⚡", "🏆"
]

private struct MessageActionOverlay: View {
    @EnvironmentObject private var app: AloAppModel
    let message: AloChatMessage
    let targetFrame: CGRect?
    let appearance: AloChatAppearance
    let onCopy: () -> Void
    let onForward: () -> Void
    let onEdit: () -> Void
    let onReact: (String) -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var showsAllReactions = false

    private let reactionEmojis = aloMessageReactionEmojis

    var body: some View {
        GeometryReader { proxy in
            let layout = overlayLayout(in: proxy.size)

            ZStack(alignment: .topLeading) {
                ZStack {
                    DarkChatBlurView()
                    Color.black.opacity(0.28)
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

                if showsReactions {
                    reactionsPanel
                        .frame(width: layout.reactionFrame.width, height: layout.reactionFrame.height)
                        .position(x: layout.reactionFrame.midX, y: layout.reactionFrame.midY)
                        .zIndex(3)
                        .transition(.scale(scale: 0.98).combined(with: .opacity))
                }

                MessageActionPreviewBubble(message: message, previewText: previewText, appearance: appearance)
                    .frame(
                        width: layout.previewFrame.width,
                        height: layout.previewFrame.height,
                        alignment: isMine ? .trailing : .leading
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .position(x: layout.previewFrame.midX, y: layout.previewFrame.midY)
                    .zIndex(2)
                    .transition(.opacity)

                actionMenu
                    .frame(
                        width: layout.menuFrame.width,
                        height: layout.menuFrame.height,
                        alignment: .topLeading
                    )
                    .position(x: layout.menuFrame.midX, y: layout.menuFrame.midY)
                    .zIndex(1)
                    .transition(.scale(scale: 0.985, anchor: .center).combined(with: .opacity))
            }
        }
    }

    private var reactionsPanel: some View {
        let selectedEmoji = message.reactions.first(where: \.reactedByMe)?.emoji
        return VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(reactionEmojis.prefix(6)), id: \.self) { emoji in
                    reactionButton(emoji, selectedEmoji: selectedEmoji)
                }

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        showsAllReactions.toggle()
                    }
                } label: {
                    Image(systemName: showsAllReactions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .frame(width: 38, height: 42)
                        .background(Color.white.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.84))
            }

            if showsAllReactions {
                Divider()
                    .overlay(Color.white.opacity(0.08))

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7),
                        spacing: 5
                    ) {
                        ForEach(reactionEmojis, id: \.self) { emoji in
                            reactionButton(emoji, selectedEmoji: selectedEmoji, size: 38, fontSize: 23)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
                }
                .frame(height: 130)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(7)
        .background {
            RoundedRectangle(cornerRadius: showsAllReactions ? 22 : 28, style: .continuous)
                .fill(Color(red: 0.045, green: 0.048, blue: 0.060).opacity(0.95))
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: showsAllReactions ? 22 : 28, style: .continuous)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: showsAllReactions ? 22 : 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: showsAllReactions ? 22 : 28, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.34), radius: 18, y: 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: showsAllReactions)
    }

    private func reactionButton(
        _ emoji: String,
        selectedEmoji: String?,
        size: CGFloat = 42,
        fontSize: CGFloat = 25
    ) -> some View {
        Button {
            AloHaptics.selection()
            onReact(emoji)
        } label: {
            ZStack {
                Circle()
                    .fill(selectedEmoji == emoji ? appearance.outgoingColor.opacity(0.92) : Color.white.opacity(0.045))
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(selectedEmoji == emoji ? 0.24 : 0.07), lineWidth: 1)
                    )
                Text(emoji)
                    .font(.system(size: fontSize))
                    .scaleEffect(selectedEmoji == emoji ? 1.08 : 1)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.82))
    }

    private var actionMenu: some View {
            VStack(spacing: 0) {
            if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MessageActionButton(title: "Скопировать", systemName: "doc.on.doc", action: onCopy)
            }
            if canEdit {
                MessageActionButton(title: "Изменить", systemName: "square.and.pencil", action: onEdit)
            }
            if message.chatCallLogMeta == nil {
                MessageActionButton(title: "Переслать", systemName: "arrowshape.turn.up.right", action: onForward)
            }
            MessageActionButton(title: "Удалить", systemName: "trash", tint: .red, action: onDelete)

            Divider()
                .background(AloTheme.border.opacity(0.8))
                .padding(.vertical, 6)
                .padding(.horizontal, 16)

            MessageActionButton(title: "Выбрать", systemName: "checkmark.circle", action: onSelect)
        }
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.045, green: 0.047, blue: 0.058).opacity(0.90))
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AloTheme.border.opacity(0.55), lineWidth: 1)
        )
    }

    private func menuWidth(in size: CGSize) -> CGFloat {
        min(330, max(252, size.width - 52))
    }

    private func sourceFrame(in size: CGSize) -> CGRect {
        targetFrame ?? CGRect(x: size.width / 2 - 80, y: size.height / 2 - 28, width: 160, height: 56)
    }

    private func overlayLayout(in size: CGSize) -> MessageActionOverlayLayout {
        let margin: CGFloat = 24
        let gap: CGFloat = 6
        let source = sourceFrame(in: size)
        let reactionSize = CGSize(
            width: min(344, size.width - margin * 2),
            height: showsReactions ? (showsAllReactions ? 200 : 56) : 0
        )
        let menuSize = CGSize(width: menuWidth(in: size), height: estimatedActionMenuHeight)
        let previewWidth = min(max(source.width, 42), max(120, size.width - margin * 2))
        let fixedHeight = reactionSize.height + menuSize.height + gap * (showsReactions ? 2 : 1)
        let availablePreviewHeight = max(42, size.height - margin * 2 - fixedHeight)
        let previewHeight = min(max(source.height, 42), min(286, availablePreviewHeight))
        let blockHeight = fixedHeight + previewHeight
        let maximumTop = max(margin, size.height - margin - blockHeight)
        let preferredTop = showsReactions ? source.minY - reactionSize.height - gap : source.minY
        let top = min(max(preferredTop, margin), maximumTop)

        func alignedX(for width: CGFloat) -> CGFloat {
            let preferred = isMine ? source.maxX - width / 2 : source.minX + width / 2
            return min(max(preferred, margin + width / 2), size.width - margin - width / 2)
        }

        let reactionFrame = CGRect(
            x: alignedX(for: reactionSize.width) - reactionSize.width / 2,
            y: top,
            width: reactionSize.width,
            height: reactionSize.height
        )
        let previewFrame = CGRect(
            x: alignedX(for: previewWidth) - previewWidth / 2,
            y: showsReactions ? reactionFrame.maxY + gap : top,
            width: previewWidth,
            height: previewHeight
        )
        let menuFrame = CGRect(
            x: alignedX(for: menuSize.width) - menuSize.width / 2,
            y: previewFrame.maxY + gap,
            width: menuSize.width,
            height: menuSize.height
        )
        return MessageActionOverlayLayout(
            reactionFrame: reactionFrame,
            previewFrame: previewFrame,
            menuFrame: menuFrame
        )
    }

    private var estimatedActionMenuHeight: CGFloat {
        var rows = 2
        if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows += 1
        }
        if canEdit {
            rows += 1
        }
        if message.chatCallLogMeta == nil {
            rows += 1
        }
        return CGFloat(rows) * 44 + 13
    }

    private var isMine: Bool {
        message.senderId == app.bootstrap?.me.id
    }

    private var showsReactions: Bool {
        message.chatCallLogMeta == nil
    }

    private var previewText: String {
        if let callLogMeta = message.chatCallLogMeta {
            return callLogMeta.menuTitle(isMine: message.senderId == app.bootstrap?.me.id)
        }
        if !message.body.isEmpty {
            return message.body
        }
        let attachments = !message.attachments.isEmpty ? message.attachments : legacyAttachments
        if attachments.contains(where: \.isVoiceLike) {
            return "Голосовое сообщение"
        }
        if attachments.contains(where: \.isCircleLike) {
            return "Кружок"
        }
        let imageCount = attachments.filter { $0.type == "image" || $0.url.lowercased().hasImageExtension }.count
        let videoCount = attachments.filter { $0.type == "video" || $0.url.lowercased().hasVideoExtension }.count
        if imageCount > 0 && videoCount > 0 {
            return "\(imageCount) фото, \(videoCount) видео"
        }
        if imageCount > 1 {
            return "\(imageCount) фото"
        }
        if videoCount > 1 {
            return "\(videoCount) видео"
        }
        if imageCount == 1 {
            return "Фотография"
        }
        if videoCount == 1 {
            return "Видео"
        }
        if !attachments.isEmpty {
            return attachments.first?.name.ifBlank("Файл") ?? "Файл"
        }
        if message.forwardFrom != nil {
            return "Пересланное сообщение"
        }
        return "Без текста"
    }

    private var canEdit: Bool {
        message.senderId == app.bootstrap?.me.id && !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var legacyAttachments: [AloMessageAttachment] {
        guard !message.attachmentUrl.isEmpty else { return [] }
        return [
            AloMessageAttachment([
                "type": message.attachmentType,
                "url": message.attachmentUrl,
                "name": message.attachmentName
            ])
        ]
    }
}

private struct MessageActionOverlayLayout {
    let reactionFrame: CGRect
    let previewFrame: CGRect
    let menuFrame: CGRect
}

private struct MessageActionPreviewBubble: View {
    @EnvironmentObject private var app: AloAppModel
    let message: AloChatMessage
    let previewText: String
    let appearance: AloChatAppearance

    var body: some View {
        let isMine = message.senderId == app.bootstrap?.me.id
        previewContent(isMine: isMine)
            .shadow(color: Color.black.opacity(0.24), radius: 12, y: 6)
    }

    @ViewBuilder
    private func previewContent(isMine: Bool) -> some View {
        if let callLogMeta = message.chatCallLogMeta {
            callPreview(callLogMeta, isMine: isMine)
        } else if let attachment = firstAttachment, attachment.isVoiceLike {
            voicePreview(attachment, isMine: isMine)
        } else if let attachment = firstAttachment, attachment.isCircleLike {
            circlePreview(attachment, isMine: isMine)
        } else if mediaAttachments.count > 1 {
            attachmentGroupPreview(mediaAttachments, isMine: isMine)
        } else if let attachment = firstAttachment {
            attachmentPreview(attachment, isMine: isMine)
        } else {
            textPreview(isMine: isMine)
        }
    }

    private func voicePreview(_ attachment: AloMessageAttachment, isMine: Bool) -> some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            if let forwardFrom = message.forwardFrom {
                Text("Переслано от \(forwardFrom.user?.name ?? "пользователя")")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isMine ? Color.white.opacity(0.86) : AloTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VoiceMessageAttachmentView(
                attachment: attachment,
                isMine: isMine,
                accentColor: appearance.outgoingColor,
                showMessageMeta: true,
                createdAt: message.createdAt,
                editedAt: message.editedAt,
                isRead: !message.readAt.isEmpty,
                onLongPress: {}
            )
            .environmentObject(app)

            previewReactionFooter(showMeta: false, isMine: isMine)
        }
        .frame(width: 220, alignment: isMine ? .trailing : .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
    }

    private func textPreview(isMine: Bool) -> some View {
        Group {
            if message.reactions.isEmpty {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(previewText)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.white)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 3) {
                        Text(AloFormatters.messageTime(message.createdAt))
                        if isMine {
                            MessageReadStatusChecks(isRead: !message.readAt.isEmpty)
                        }
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .layoutPriority(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(previewText)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.white)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)

                    previewReactionFooter(showMeta: true, isMine: isMine)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func callPreview(_ callLogMeta: ChatCallLogMeta, isMine: Bool) -> some View {
        ChatCallLogAttachment(
            meta: callLogMeta,
            isMine: isMine,
            isRead: !message.readAt.isEmpty,
            createdAt: message.createdAt
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func circlePreview(_ attachment: AloMessageAttachment, isMine: Bool) -> some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            CircleMessageAttachmentView(attachment: attachment, accentColor: appearance.outgoingColor)
                .frame(width: 196, height: 196)
                .overlay(alignment: .bottomTrailing) {
                    Text(AloFormatters.messageTime(message.createdAt))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.38))
                        .clipShape(Capsule())
                        .padding(8)
                }
        }
    }

    private func attachmentPreview(_ attachment: AloMessageAttachment, isMine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MessageActionAttachmentPreview(attachment: attachment, isMine: isMine)
                .environmentObject(app)

            if !message.body.isEmpty {
                Text(message.body)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.white)
                    .lineLimit(3)
            }

            previewReactionFooter(showMeta: true, isMine: isMine)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(width: 260, alignment: .leading)
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func attachmentGroupPreview(_ attachments: [AloMessageAttachment], isMine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MessageMediaGrid(attachments: attachments, onOpenAt: nil)
                .environmentObject(app)

            if !message.body.isEmpty {
                Text(message.body)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.white)
                    .lineLimit(3)
            }

            previewReactionFooter(showMeta: true, isMine: isMine)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(width: 270, alignment: .leading)
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var firstAttachment: AloMessageAttachment? {
        let attachments = !message.attachments.isEmpty ? message.attachments : legacyAttachments
        return attachments.first
    }

    private var mediaAttachments: [AloMessageAttachment] {
        let attachments = !message.attachments.isEmpty ? message.attachments : legacyAttachments
        return attachments.filter(\.isVisualMedia)
    }

    @ViewBuilder
    private func previewReactionFooter(showMeta: Bool, isMine: Bool) -> some View {
        if !message.reactions.isEmpty || showMeta {
            HStack(alignment: .bottom, spacing: 8) {
                if !message.reactions.isEmpty {
                    MessageReactionStrip(
                        reactions: Array(message.reactions.prefix(3)),
                        onTap: { _ in }
                    )
                }

                Spacer(minLength: 6)

                if showMeta {
                    HStack(spacing: 3) {
                        Text(AloFormatters.messageTime(message.createdAt))
                        if isMine {
                            MessageReadStatusChecks(isRead: !message.readAt.isEmpty)
                        }
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .layoutPriority(1)
                }
            }
        }
    }

    private var legacyAttachments: [AloMessageAttachment] {
        guard !message.attachmentUrl.isEmpty else { return [] }
        return [
            AloMessageAttachment([
                "type": message.attachmentType,
                "url": message.attachmentUrl,
                "name": message.attachmentName
            ])
        ]
    }
}

private struct MessageActionAttachmentPreview: View {
    @EnvironmentObject private var app: AloAppModel
    let attachment: AloMessageAttachment
    let isMine: Bool

    var body: some View {
        ZStack {
            (isMine ? Color.white.opacity(0.10) : AloTheme.background.opacity(0.86))

            if attachment.isVoiceLike {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(isMine ? AloTheme.outgoing : AloTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.92))
                        .clipShape(Circle())
                    VoiceScrubberWaveform(
                        progress: 0,
                        levels: attachment.waveform,
                        activeColor: isMine ? Color.white : AloTheme.accent,
                        inactiveColor: Color.white.opacity(0.34)
                    )
                        .frame(height: 24)
                }
                .padding(.horizontal, 12)
            } else if let url = previewURL {
                AloAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        RemoteMediaLoadingPlaceholder(isVideo: attachment.type == "video" || attachment.isCircleLike, isFailed: true)
                    case .empty:
                        RemoteMediaLoadingPlaceholder(isVideo: attachment.type == "video" || attachment.isCircleLike, isFailed: false)
                    @unknown default:
                        RemoteMediaLoadingPlaceholder(isVideo: attachment.type == "video" || attachment.isCircleLike, isFailed: false)
                    }
                }
            } else {
                Image(systemName: attachment.isCircleLike ? "video.circle.fill" : "doc.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
            }

            if attachment.type == "video" || attachment.isCircleLike {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.46))
                    .clipShape(Circle())
            }
        }
        .frame(height: attachment.isVoiceLike ? 58 : 132)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var previewURL: URL? {
        app.api.absoluteURL(attachment.posterUrl.ifBlank(attachment.url))
    }
}

private struct MessageActionButton: View {
    let title: String
    let systemName: String
    var tint: Color = AloTheme.text
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button {
            AloHaptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .heavy))
                    .frame(width: 30, height: 30)
                    .background((disabled ? AloTheme.muted.opacity(0.10) : tint.opacity(0.13)))
                    .clipShape(Circle())
                Text(title)
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                Spacer()
            }
            .foregroundStyle(disabled ? AloTheme.muted.opacity(0.45) : tint)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .padding(.horizontal, 10)
            .background(Color.white.opacity(0.001))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.965))
        .disabled(disabled)
    }
}

private struct ChatAttachmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var attachments: [AloLocalAttachment]
    @Binding var caption: String
    @State private var pickedItems = [PhotosPickerItem]()
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(AloTheme.muted.opacity(0.55))
                .frame(width: 54, height: 5)
                .frame(maxWidth: .infinity)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Вложения")
                        .font(.system(size: 24, weight: .bold))
                    Text("Можно выбрать несколько фото или видео.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                }
                Spacer()
                Button("Готово") {
                    dismiss()
                }
                .font(.system(size: 16, weight: .bold))
            }

            PhotosPicker(
                selection: $pickedItems,
                maxSelectionCount: 10,
                matching: .any(of: [.images, .videos])
            ) {
                Label("Выбрать из галереи", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(AloTheme.accent)
                    .clipShape(Capsule())
            }

            if !mediaAttachments.isEmpty {
                TextField("Добавить подпись", text: $caption, axis: .vertical)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AloTheme.text)
                    .lineLimit(1...4)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 12)
                    .background(AloTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AloTheme.border, lineWidth: 1)
                    )
            }

            if isLoading {
                HStack {
                    ProgressView().tint(AloTheme.accent)
                    Text("Загружаем предпросмотр...")
                        .foregroundStyle(AloTheme.muted)
                }
                .font(.system(size: 15, weight: .semibold))
            }

            if mediaAttachments.isEmpty {
                ContentUnavailableView(
                    "Медиа не выбраны",
                    systemImage: "photo",
                    description: Text("Выбери фото или видео, и они появятся здесь перед отправкой.")
                )
                .foregroundStyle(AloTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                    ForEach(mediaAttachments) { attachment in
                        LocalAttachmentThumb(attachment: attachment)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onChange(of: pickedItems) { _, newItems in
            Task { await loadPickedItems(newItems) }
        }
    }

    private var mediaAttachments: [AloLocalAttachment] {
        attachments.filter { !$0.isRecordedDraft }
    }

    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        isLoading = true
        var next = [AloLocalAttachment]()
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let contentType = item.supportedContentTypes.first
            let isVideo = contentType?.conforms(to: .movie) == true || contentType?.conforms(to: .video) == true
            let mime = contentType?.preferredMIMEType ?? (isVideo ? "video/mp4" : "image/jpeg")
            let ext = contentType?.preferredFilenameExtension ?? (isVideo ? "mp4" : "jpg")
            next.append(
                AloLocalAttachment(
                    data: data,
                    mime: mime,
                    type: isVideo ? "video" : "image",
                    name: "media-\(index + 1).\(ext)"
                )
            )
        }
        let recordedDrafts = attachments.filter(\.isRecordedDraft)
        let existingMedia = attachments.filter { !$0.isRecordedDraft }
        attachments = recordedDrafts + Array((existingMedia + next).prefix(10))
        isLoading = false
    }
}

private struct ForwardTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversations: [AloConversationSummary]
    let currentPeerId: Int
    let onPick: (AloConversationSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(AloTheme.muted.opacity(0.55))
                .frame(width: 54, height: 5)
                .frame(maxWidth: .infinity)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Кому переслать")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Выбери чат, сообщение появится в поле ввода.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AloTheme.muted)
                        .frame(width: 40, height: 40)
                        .background(AloTheme.surfaceRaised)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(conversations) { conversation in
                        Button {
                            onPick(conversation)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                if conversation.peer.entityType == "saved" {
                                    SavedMessagesAvatar(size: 52)
                                } else {
                                    AloAvatar(
                                        name: conversation.peer.name,
                                        url: conversation.peer.avatarUrl,
                                        size: 52,
                                        colorSeed: String(conversation.peer.id)
                                    )
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(conversation.peer.name)
                                            .font(.system(size: 17, weight: .bold))
                                            .foregroundStyle(AloTheme.text)
                                            .lineLimit(1)
                                        if conversation.peerId == currentPeerId {
                                            Text("текущий")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(AloTheme.accent)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(AloTheme.accent.opacity(0.14))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(conversation.lastBody.ifBlank("Чат"))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AloTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(AloTheme.accent)
                            }
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                            .background(AloTheme.border)
                            .padding(.leading, 64)
                    }
                }
            }
        }
        .padding(18)
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

private struct MessageSelectionToolbar: View {
    let count: Int
    let onCancel: () -> Void
    let onForward: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Выбрано: \(count)")
                    .font(.system(size: 16, weight: .bold))
                Text("Можно переслать или удалить")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
            }
            Spacer()
            Button(action: onForward) {
                Image(systemName: "arrowshape.turn.up.right.fill")
                    .frame(width: 44, height: 44)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash.fill")
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(AloTheme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AloTheme.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(AloTheme.border, lineWidth: 1))
    }
}

private struct ForwardDraftBar: View {
    let title: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(AloTheme.accent)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                Text("Отправь в этот чат или отмени")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(12)
        .background(AloTheme.surface.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }
}

private struct EditDraftBar: View {
    let preview: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(AloTheme.accent)
                .frame(width: 4)
            Image(systemName: "square.and.pencil")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AloTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Редактировать сообщение")
                    .font(.system(size: 15, weight: .bold))
                Text(preview.ifBlank("Сообщение"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(12)
        .background(AloTheme.surface.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }
}

private struct ChatPeerInfoPanel: View {
    @EnvironmentObject private var app: AloAppModel
    let conversation: AloConversationDetail
    let messages: [AloChatMessage]
    let onClose: () -> Void
    let onOpenProfile: () -> Void
    let onAudioCall: () -> Void
    let onVideoCall: () -> Void
    let onOpenAppearance: () -> Void

    @State private var selectedMediaTab: PeerMediaTab = .photos
    @State private var selectedGroupAvatarItem: PhotosPickerItem?
    @State private var isLeaveGroupConfirmationPresented = false
    @State private var isDeleteGroupConfirmationPresented = false
    @State private var isSearchPresented = false
    @State private var searchText = ""
    @State private var mediaScrollRequest = 0
    @State private var isMuted = false
    @State private var isMuteLoading = false
    @State private var isSafetyPresented = false
    @State private var isSafetyLoading = false
    @State private var safetyVerification: AloSafetyVerification?
    @State private var safetyError = ""

    var body: some View {
        ZStack {
            AloTheme.background.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        hero
                        quickActions
                        if isSearchPresented {
                            searchSection
                        }
                        if conversation.kind == "group" {
                            groupMembersSection
                            groupDangerSection
                        }
                        mediaTabs
                            .id("peer-media")
                        mediaContent
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 26)
                }
                .onChange(of: mediaScrollRequest) { _, _ in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                        proxy.scrollTo("peer-media", anchor: .top)
                    }
                }
            }
        }
        .task(id: "\(conversation.kind):\(conversation.roomId):\(conversation.peerId)") {
            isMuted = (try? await app.api.chatMuteState(conversation: conversation)) ?? false
        }
        .sheet(isPresented: $isSafetyPresented) {
            ChatSafetyNumberSheet(
                verification: safetyVerification,
                isLoading: isSafetyLoading,
                errorMessage: safetyError,
                onToggleVerified: { verified in
                    guard let current = safetyVerification else { return }
                    app.api.setSafetyVerification(
                        peerId: current.peerId,
                        digest: current.digest,
                        verified: verified
                    )
                    safetyVerification = AloSafetyVerification(
                        peerId: current.peerId,
                        decimalCode: current.decimalCode,
                        qrPayload: current.qrPayload,
                        digest: current.digest,
                        localFingerprint: current.localFingerprint,
                        peerDevices: current.peerDevices,
                        isVerified: verified
                    )
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: selectedGroupAvatarItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                await MainActor.run {
                    app.updateGroupAvatar(conversation: conversation, data: data, mime: mime)
                    selectedGroupAvatarItem = nil
                }
            }
        }
        .confirmationDialog(
            "Покинуть группу?",
            isPresented: $isLeaveGroupConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Покинуть", role: .destructive) {
                app.leaveGroupChat(conversation)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(conversation.groupMemberRole == "owner" ? "Если в группе есть участники, владелец будет передан следующему участнику. Если участников нет, группа удалится." : "Вы сможете вернуться только если вас добавят снова.")
        }
        .confirmationDialog(
            "Удалить группу?",
            isPresented: $isDeleteGroupConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Удалить группу", role: .destructive) {
                app.deleteGroupChat(conversation)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Группа, сообщения и список участников будут удалены для всех.")
        }
    }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 10) {
                heroAvatar
                Text(conversation.title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(AloTheme.text)
                    .lineLimit(1)
                Text(conversation.online ? "в сети" : conversation.subtitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)

            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 42, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
            .padding(.top, 7)
        }
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(AloTheme.surface.opacity(conversation.entityType == "saved" ? 0.74 : 0.86))
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var heroAvatar: some View {
        if conversation.entityType == "saved" {
            SavedMessagesAvatar(size: 96)
                .shadow(color: AloTheme.accent.opacity(0.20), radius: 16, y: 8)
        } else {
            AloAvatar(
                name: conversation.title,
                url: conversation.avatarUrl,
                size: 94,
                colorSeed: String(conversation.peerId)
            )
        }
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            if conversation.entityType == "saved" {
                PeerActionButton(title: "Поиск", systemName: "magnifyingglass", action: toggleSearch)
                PeerActionButton(title: "Медиа", systemName: "paperclip", action: scrollToMedia)
                PeerActionButton(title: "Оформление", systemName: "paintpalette", action: onOpenAppearance)
            } else {
                if conversation.kind != "group" {
                    PeerActionButton(title: "Профиль", systemName: "person", action: onOpenProfile)
                }
                PeerActionButton(title: "Поиск", systemName: "magnifyingglass", action: toggleSearch)
                PeerActionButton(
                    title: isMuted ? "Со звуком" : "Тихий",
                    systemName: isMuted ? "bell" : "bell.slash",
                    action: toggleMute
                )
                .disabled(isMuteLoading)
                PeerActionButton(title: "Медиа", systemName: "paperclip", action: scrollToMedia)
                PeerActionButton(title: "Оформление", systemName: "paintpalette", action: onOpenAppearance)
                if conversation.kind == "direct" {
                    PeerActionButton(title: "Шифрование", systemName: "lock.shield", action: openSafetyNumber)
                }
                if conversation.kind == "group", conversation.canManageGroup {
                    PhotosPicker(
                        selection: $selectedGroupAvatarItem,
                        matching: .images
                    ) {
                        PeerActionButtonLabel(title: "Аватарка", systemName: "photo")
                    }
                    .buttonStyle(.plain)
                }
                PeerActionButton(title: "Звонок", systemName: "phone", action: onAudioCall)
                PeerActionButton(title: "Видео", systemName: "video", action: onVideoCall)
            }
        }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AloTheme.muted)
                TextField("Поиск по сообщениям", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AloTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(AloTheme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let results = messages.filter {
                    $0.body.localizedCaseInsensitiveContains(searchText)
                }
                if results.isEmpty {
                    Text("Совпадений не найдено")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                } else {
                    ForEach(results.prefix(20)) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.body)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AloTheme.text)
                                .lineLimit(3)
                            Text(AloFormatters.messageTime(message.createdAt))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(AloTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                }
            }
        }
        .padding(14)
        .background(AloTheme.surface.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func toggleSearch() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            isSearchPresented.toggle()
        }
    }

    private func scrollToMedia() {
        mediaScrollRequest += 1
    }

    private func toggleMute() {
        guard !isMuteLoading else { return }
        isMuteLoading = true
        let next = !isMuted
        Task {
            do {
                isMuted = try await app.api.setChatMuted(next, conversation: conversation)
            } catch let error as AloAPIError {
                app.errorMessage = error.message
            } catch {
                app.errorMessage = "Не удалось изменить уведомления чата."
            }
            isMuteLoading = false
        }
    }

    private func openSafetyNumber() {
        safetyError = ""
        safetyVerification = nil
        isSafetyLoading = true
        isSafetyPresented = true
        Task {
            do {
                safetyVerification = try await app.api.loadSafetyVerification(peerId: conversation.peerId)
            } catch let error as AloAPIError {
                safetyError = error.message
            } catch {
                safetyError = "Не удалось загрузить данные шифрования."
            }
            isSafetyLoading = false
        }
    }

    private var mediaTabs: some View {
        HStack(spacing: 0) {
            ForEach(PeerMediaTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                        selectedMediaTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(selectedMediaTab == tab ? AloTheme.text : AloTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background {
                            if selectedMediaTab == tab {
                                Capsule()
                                    .fill(AloTheme.surfaceRaised)
                                    .matchedGeometryEffect(id: "peerMediaTab", in: tabNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(AloTheme.surface)
        .clipShape(Capsule())
    }

    @Namespace private var tabNamespace

    private var groupMembersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(conversation.groupMembers.count) участников")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(AloTheme.text)

            ForEach(conversation.groupMembers.prefix(16)) { member in
                HStack(spacing: 11) {
                    AloAvatar(
                        name: member.name,
                        url: member.avatarUrl,
                        size: 42,
                        colorSeed: String(member.id)
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(AloTheme.text)
                            .lineLimit(1)
                        Text(member.username.isEmpty ? member.roleLabel : "@\(member.username)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AloTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !member.roleLabel.isEmpty {
                        Text(member.roleLabel)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(AloTheme.muted)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.surface.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var groupDangerSection: some View {
        VStack(spacing: 10) {
            Button(role: .destructive) {
                isLeaveGroupConfirmationPresented = true
            } label: {
                Label("Покинуть группу", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(AloTheme.surface.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)

            if conversation.groupMemberRole == "owner" {
                Button(role: .destructive) {
                    isDeleteGroupConfirmationPresented = true
                } label: {
                    Label("Удалить группу", systemImage: "trash")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(AloTheme.surface.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        let attachments = filteredAttachments
        if attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedMediaTab.emptyTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(AloTheme.text)
                Text(selectedMediaTab.emptySubtitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .frame(minHeight: 170, alignment: .topLeading)
            .background(AloTheme.surface.opacity(0.68))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)], spacing: 3) {
                ForEach(attachments.prefix(24)) { attachment in
                    RemoteAttachmentCell(attachment: attachment)
                        .frame(height: 164)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: selectedMediaTab)
        }
    }

    private var allAttachments: [AloMessageAttachment] {
        messages.flatMap { message in
            if !message.attachments.isEmpty { return message.attachments }
            if message.attachmentUrl.isEmpty { return [] }
            return [
                AloMessageAttachment([
                    "type": message.attachmentType,
                    "url": message.attachmentUrl,
                    "name": message.attachmentName
                ])
            ]
        }
    }

    private var filteredAttachments: [AloMessageAttachment] {
        allAttachments.filter { selectedMediaTab.matches($0) }
    }
}

private struct ChatSafetyNumberSheet: View {
    @Environment(\.dismiss) private var dismiss
    let verification: AloSafetyVerification?
    let isLoading: Bool
    let errorMessage: String
    let onToggleVerified: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if isLoading {
                        ProgressView()
                            .tint(AloTheme.accent)
                            .padding(.top, 80)
                    } else if let verification {
                        Image(uiImage: qrImage(verification.qrPayload))
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 210, height: 210)
                            .padding(14)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(spacing: 8) {
                            Label(
                                verification.isVerified ? "Устройство подтверждено" : "Проверьте код",
                                systemImage: verification.isVerified ? "checkmark.shield.fill" : "lock.shield"
                            )
                            .font(.system(size: 19, weight: .heavy, design: .rounded))
                            .foregroundStyle(verification.isVerified ? Color.green : AloTheme.text)

                            Text("Сравните QR-код или цифры с собеседником по другому защищённому каналу.")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AloTheme.muted)
                                .multilineTextAlignment(.center)
                        }

                        Text(verification.decimalCode)
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundStyle(AloTheme.text)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .background(AloTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Устройства собеседника")
                                .font(.system(size: 17, weight: .heavy, design: .rounded))
                            ForEach(verification.peerDevices) { device in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.label)
                                        .font(.system(size: 14, weight: .bold))
                                    Text(device.fingerprint)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(AloTheme.muted)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(AloTheme.surface.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        Button {
                            onToggleVerified(!verification.isVerified)
                        } label: {
                            Text(verification.isVerified ? "Снять подтверждение" : "Коды совпадают")
                                .font(.system(size: 16, weight: .heavy, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(verification.isVerified ? AloTheme.surfaceRaised : AloTheme.accent)
                    } else {
                        ContentUnavailableView(
                            "Данные недоступны",
                            systemImage: "lock.trianglebadge.exclamationmark",
                            description: Text(errorMessage)
                        )
                        .padding(.top, 60)
                    }
                }
                .padding(20)
            }
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Шифрование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func qrImage(_ value: String) -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)),
              let image = CIContext().createCGImage(output, from: output.extent) else {
            return UIImage()
        }
        return UIImage(cgImage: image)
    }
}

private struct PeerActionButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PeerActionButtonLabel(title: title, systemName: systemName)
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.90))
    }
}

private struct PeerActionButtonLabel: View {
    let title: String
    let systemName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .frame(width: 24)
            Text(title)
                .font(.system(size: 16, weight: .bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(AloTheme.text)
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(AloTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }
}

private enum PeerMediaTab: String, CaseIterable, Identifiable {
    case photos
    case videos
    case voices
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "Фото"
        case .videos: return "Видео"
        case .voices: return "ГС"
        case .files: return "Файлы"
        }
    }

    var emptyTitle: String {
        switch self {
        case .photos: return "Фотографий пока нет"
        case .videos: return "Видео пока нет"
        case .voices: return "Голосовых пока нет"
        case .files: return "Файлов пока нет"
        }
    }

    var emptySubtitle: String {
        switch self {
        case .photos: return "Когда в чате появятся изображения, они будут здесь."
        case .videos: return "Видео из переписки появятся в этом разделе."
        case .voices: return "Голосовые и кружки будут собраны здесь."
        case .files: return "Документы и остальные файлы будут здесь."
        }
    }

    func matches(_ attachment: AloMessageAttachment) -> Bool {
        let type = attachment.type.lowercased()
        let url = attachment.url.lowercased()
        switch self {
        case .photos:
            return type == "image" || url.hasImageExtension
        case .videos:
            return type == "video" || url.hasVideoExtension
        case .voices:
            return type == "audio" || type == "voice" || type == "circle" || url.hasSuffix(".m4a") || url.hasSuffix(".aac") || url.hasSuffix(".mp3")
        case .files:
            return !PeerMediaTab.photos.matches(attachment) &&
                !PeerMediaTab.videos.matches(attachment) &&
                !PeerMediaTab.voices.matches(attachment)
        }
    }
}

private struct ChatCallScreen: View {
    let kind: ChatCallKind
    let conversation: AloConversationDetail
    let onMinimize: () -> Void
    let onEnd: () -> Void

    @State private var isMuted = false
    @State private var isCameraOff = false
    @State private var isSpeakerOn = true
    @State private var startedAt = Date()
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AloTheme.background,
                    Color(red: 0.035, green: 0.07, blue: 0.13),
                    AloTheme.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(height: 18)
                    .accessibilityLabel("Свернуть звонок")
                Spacer(minLength: 22)
                AloAvatar(
                    name: conversation.title,
                    url: conversation.avatarUrl,
                    size: 112,
                    colorSeed: String(conversation.peerId)
                )
                VStack(spacing: 6) {
                    Text(conversation.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(AloTheme.text)
                        .lineLimit(1)
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("\(kind.title) · \(callTime(context.date.timeIntervalSince(startedAt)))")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AloTheme.muted)
                            .monospacedDigit()
                    }
                }

                if kind == .video {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(AloTheme.surface)
                        .overlay {
                            VStack(spacing: 10) {
                                Image(systemName: isCameraOff ? "video.slash.fill" : "video.fill")
                                    .font(.system(size: 36, weight: .bold))
                                Text(isCameraOff ? "Камера выключена" : "Видео готово")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .foregroundStyle(AloTheme.muted)
                        }
                        .frame(height: 240)
                        .padding(.horizontal, 18)
                }

                Spacer()

                HStack(spacing: 16) {
                    CallControlButton(systemName: isMuted ? "mic.slash.fill" : "mic.fill", title: "Микрофон", isActive: !isMuted) {
                        isMuted.toggle()
                    }
                    if kind == .video {
                        CallControlButton(systemName: isCameraOff ? "video.slash.fill" : "video.fill", title: "Камера", isActive: !isCameraOff) {
                            isCameraOff.toggle()
                        }
                    }
                    CallControlButton(systemName: isSpeakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill", title: "Звук", isActive: isSpeakerOn) {
                        isSpeakerOn.toggle()
                    }
                    CallControlButton(systemName: "phone.down.fill", title: "Завершить", isDestructive: true, isActive: true, action: onEnd)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 26)
            }
        }
        .offset(y: dragOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    dragOffset = min(0, value.translation.height)
                }
                .onEnded { value in
                    if value.translation.height < -72 || value.predictedEndTranslation.height < -110 {
                        AloHaptics.impact(.medium)
                        onMinimize()
                    }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        dragOffset = 0
                    }
                }
        )
        .onAppear { startedAt = Date() }
    }

    private func callTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ChatCallMinimizedPill: View {
    let kind: ChatCallKind
    let conversation: AloConversationDetail
    let onExpand: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onExpand) {
                    HStack(spacing: 10) {
                        AloAvatar(
                            name: conversation.title,
                            url: conversation.avatarUrl,
                            size: 38,
                            colorSeed: String(conversation.peerId)
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AloTheme.text)
                                .lineLimit(1)
                            Text("\(kind.title) · нажмите, чтобы открыть")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AloTheme.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))

                Button(action: onEnd) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 38)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.88))
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(AloTheme.border.opacity(0.7), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CallControlButton: View {
    let systemName: String
    let title: String
    var isDestructive = false
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 58, height: 58)
                    .background(isDestructive ? Color.red : (isActive ? AloTheme.surfaceRaised : AloTheme.surface))
                    .foregroundStyle(isDestructive ? Color.white : AloTheme.text)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

private final class ChatAudioRecorder: NSObject, ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var levels: [CGFloat] = []

    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    private var meterTimer: Timer?

    func start() {
        Task { @MainActor in
            let granted = await requestPermission()
            guard granted else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("alo-voice-\(UUID().uuidString).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                outputURL = url
                recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder?.isMeteringEnabled = true
                recorder?.record()
                updateLevels([])
                startMetering()
            } catch {
                stopMetering(clearLevels: true)
                recorder = nil
                outputURL = nil
            }
        }
    }

    func stop(completion: @escaping (AloLocalAttachment?, [CGFloat]) -> Void) {
        stopMetering(clearLevels: false)
        recorder?.stop()
        recorder = nil
        guard let outputURL,
              let data = try? Data(contentsOf: outputURL),
              !data.isEmpty else {
            completion(nil, [])
            return
        }
        let waveform = Self.extractWaveform(from: outputURL, samples: 28)
        try? FileManager.default.removeItem(at: outputURL)
        self.outputURL = nil
        completion(
            AloLocalAttachment(
                data: data,
                mime: "audio/m4a",
                type: "audio",
                name: "voice-\(Int(Date().timeIntervalSince1970)).m4a",
                waveform: waveform
            ),
            waveform
        )
    }

    func cancel() {
        stopMetering(clearLevels: true)
        recorder?.stop()
        recorder = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    private func startMetering() {
        stopMetering(clearLevels: false)
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            recorder.updateMeters()
            let average = recorder.averagePower(forChannel: 0)
            let peak = recorder.peakPower(forChannel: 0)
            let power = max(average, peak - 8)
            let normalized = pow(10, power / 34)
            let level = CGFloat(max(0.10, min(1, normalized)))
            self.updateLevels(Array((self.levels + [level]).suffix(28)))
        }
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMetering(clearLevels: Bool) {
        meterTimer?.invalidate()
        meterTimer = nil
        if clearLevels {
            updateLevels([])
        }
    }

    private func updateLevels(_ nextLevels: [CGFloat]) {
        objectWillChange.send()
        levels = nextLevels
    }

    private static func extractWaveform(from url: URL, samples: Int) -> [CGFloat] {
        guard samples > 0,
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ) else {
            return []
        }

        do {
            try file.read(into: buffer)
        } catch {
            return []
        }

        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }

        let stride = max(1, frameCount / samples)
        return (0..<samples).map { sampleIndex in
            let start = min(sampleIndex * stride, frameCount - 1)
            let end = min(start + stride, frameCount)
            var sum: Float = 0
            var count: Float = 0

            for frame in start..<end {
                let value = channelData[0][frame]
                sum += value * value
                count += 1
            }

            let rms = sqrt(sum / max(count, 1))
            return CGFloat(max(0.10, min(1, sqrt(rms) * 1.6)))
        }
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

private final class ChatCircleRecorder:
    NSObject,
    ObservableObject,
    AVCaptureFileOutputRecordingDelegate,
    @unchecked Sendable {
    let objectWillChange = ObservableObjectPublisher()

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "alo.circle.recorder.session", qos: .userInitiated)
    private let movieOutput = AVCaptureMovieFileOutput()
    private var outputURL: URL?
    private var completion: ((AloLocalAttachment?) -> Void)?
    private var pendingStopCompletion: ((AloLocalAttachment?) -> Void)?
    private var isStartingRecording = false
    private var isConfigured = false
    private var isConfiguring = false
    private var currentVideoInput: AVCaptureDeviceInput?
    private var currentCameraPosition: AVCaptureDevice.Position = .front
    private(set) var isTorchEnabled = false {
        didSet { objectWillChange.send() }
    }

    func start() {
        Task { @MainActor in
            let configured = await configureIfNeeded()
            guard configured else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("alo-circle-\(UUID().uuidString).mov")
            outputURL = url
            isStartingRecording = true
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async {
                    guard self.outputURL == url else { return }
                    self.isStartingRecording = false
                    if let connection = self.movieOutput.connection(with: .video),
                       connection.isVideoMirroringSupported {
                        connection.isVideoMirrored = self.currentCameraPosition == .front
                    }
                    if !self.movieOutput.isRecording {
                        self.movieOutput.startRecording(to: url, recordingDelegate: self)
                    }
                    self.finishPendingStopIfNeeded()
                }
            }
        }
    }

    func stop(completion: @escaping (AloLocalAttachment?) -> Void) {
        guard movieOutput.isRecording else {
            if isStartingRecording {
                pendingStopCompletion = completion
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self else { return }
                if self.movieOutput.isRecording {
                    self.completion = completion
                    self.movieOutput.stopRecording()
                } else {
                    self.cleanupOutputFile()
                    completion(nil)
                }
            }
            return
        }
        self.completion = completion
        movieOutput.stopRecording()
    }

    func cancel() {
        pendingStopCompletion = nil
        isStartingRecording = false
        completion = nil
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        cleanupOutputFile()
    }

    func switchCamera() {
        Task { @MainActor in
            guard isConfigured else { return }
            currentCameraPosition = currentCameraPosition == .front ? .back : .front
            session.beginConfiguration()
            if let currentVideoInput {
                session.removeInput(currentVideoInput)
            }
            if !addVideoInput(position: currentCameraPosition) {
                currentCameraPosition = currentCameraPosition == .front ? .back : .front
                _ = addVideoInput(position: currentCameraPosition)
            }
            session.commitConfiguration()
            applyTorchIfNeeded()
        }
    }

    func toggleTorch() {
        Task { @MainActor in
            isTorchEnabled.toggle()
            applyTorchIfNeeded()
        }
    }

    private func finishPendingStopIfNeeded() {
        guard let pendingStopCompletion else { return }
        self.pendingStopCompletion = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.stop(completion: pendingStopCompletion)
        }
    }

    private func cleanupOutputFile() {
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        guard error == nil,
              let data = try? Data(contentsOf: outputFileURL),
              !data.isEmpty else {
            DispatchQueue.main.async {
                self.cleanupOutputFile()
                self.completion?(nil)
                self.completion = nil
            }
            return
        }
        try? FileManager.default.removeItem(at: outputFileURL)
        DispatchQueue.main.async {
            self.outputURL = nil
            self.completion?(
                AloLocalAttachment(
                    data: data,
                    mime: "video/quicktime",
                    type: "circle",
                    name: "circle-\(Int(Date().timeIntervalSince1970)).mov"
                )
            )
            self.completion = nil
        }
    }

    @MainActor
    private func configureIfNeeded() async -> Bool {
        if isConfigured { return true }
        if isConfiguring { return false }
        isConfiguring = true
        defer { isConfiguring = false }

        let cameraGranted = await requestAccess(for: .video)
        guard cameraGranted else { return false }
        let microphoneGranted = await requestAccess(for: .audio)

        session.beginConfiguration()
        session.sessionPreset = .medium

        currentCameraPosition = .front
        if !addVideoInput(position: currentCameraPosition) {
            session.commitConfiguration()
            return false
        }

        if microphoneGranted,
           let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        session.commitConfiguration()
        isConfigured = true
        return true
    }

    @MainActor
    private func addVideoInput(position: AVCaptureDevice.Position) -> Bool {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let videoInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(videoInput) else {
            return false
        }
        session.addInput(videoInput)
        currentVideoInput = videoInput
        return true
    }

    @MainActor
    private func applyTorchIfNeeded() {
        guard let device = currentVideoInput?.device,
              device.hasTorch else {
            isTorchEnabled = false
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = isTorchEnabled ? .on : .off
            device.unlockForConfiguration()
        } catch {
            isTorchEnabled = false
        }
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }
}

private struct CircleCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

private struct CircleVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = .resizeAspectFill
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
            layer.masksToBounds = true
        }
    }
}

private extension Notification.Name {
    static let aloVoicePlaybackDidStart = Notification.Name("aloVoicePlaybackDidStart")
    static let aloVoicePlaybackDidStop = Notification.Name("aloVoicePlaybackDidStop")
    static let aloVoicePlaybackToggleRequested = Notification.Name("aloVoicePlaybackToggleRequested")
    static let aloVoicePlaybackStopRequested = Notification.Name("aloVoicePlaybackStopRequested")
    static let aloVoicePlaybackSpeedChanged = Notification.Name("aloVoicePlaybackSpeedChanged")
}

private enum AloHaptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

private extension AloLocalAttachment {
    var isLocalVoiceLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "audio" ||
            normalizedType == "voice" ||
            normalizedName.hasPrefix("voice-") ||
            normalizedName.hasSuffix(".m4a") ||
            normalizedName.hasSuffix(".aac") ||
            normalizedName.hasSuffix(".mp3")
    }

    var isLocalCircleLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "circle" || normalizedName.hasPrefix("circle-")
    }

    var isRecordedDraft: Bool {
        isLocalVoiceLike || isLocalCircleLike
    }
}

private extension String {
    var hasImageExtension: Bool {
        hasSuffix(".jpg") || hasSuffix(".jpeg") || hasSuffix(".png") || hasSuffix(".webp") || hasSuffix(".gif") || hasSuffix(".avif")
    }

    var hasVideoExtension: Bool {
        hasSuffix(".mp4") || hasSuffix(".mov") || hasSuffix(".m4v") || hasSuffix(".webm")
    }
}

private extension AloMessageAttachment {
    var isVoiceLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedURL = url.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "audio" ||
            normalizedType == "voice" ||
            normalizedName.hasPrefix("voice-") ||
            normalizedURL.hasSuffix(".m4a") ||
            normalizedURL.hasSuffix(".aac") ||
            normalizedURL.hasSuffix(".mp3") ||
            normalizedURL.hasSuffix(".wav")
    }

    var isCircleLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "circle" ||
            normalizedName.hasPrefix("circle-") ||
            normalizedName.contains("video-circle") ||
            normalizedName.contains("circle-video") ||
            normalizedName.contains("video-note")
    }

    var isVisualMedia: Bool {
        let normalizedType = type.lowercased()
        let normalizedURL = url.lowercased()
        return !isVoiceLike &&
            !isCircleLike &&
            (normalizedType == "image" ||
                normalizedType == "video" ||
                normalizedURL.hasImageExtension ||
                normalizedURL.hasVideoExtension)
    }

    var chatMediaItem: AloMediaItem {
        let normalizedType = type.lowercased()
        let inferredType: String
        if normalizedType == "image" || url.lowercased().hasImageExtension {
            inferredType = "image"
        } else if normalizedType == "video" || url.lowercased().hasVideoExtension {
            inferredType = "video"
        } else {
            inferredType = normalizedType.ifBlank("file")
        }
        return AloMediaItem(
            type: inferredType,
            url: url,
            posterUrl: posterUrl,
            caption: name
        )
    }
}

private struct ChatMessageFramePreferenceKey: PreferenceKey {
    static var defaultValue = [Int: CGRect]()

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct ChatBottomAnchorFramePreferenceKey: PreferenceKey {
    static var defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ChatComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChatDatePill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.94))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                Capsule()
                    .fill(Color.black.opacity(0.44))
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

private struct DarkChatBlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemUltraThinMaterialDark

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
