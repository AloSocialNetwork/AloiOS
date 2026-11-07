import AVFoundation
import Combine
import PhotosUI
import SwiftUI

/// A secret chat as Telegram shows one (docs/cloud-and-secret-chats.md, stage 2): a lock and a green name, the request
/// to accept or the wait for the other person, then messages sealed for exactly two devices. It is opened from the chat
/// list or from «Начать секретный чат» (`AloSecretChatStore.open`), and lives above the chat list like an ordinary chat.
struct AloSecretChatView: View {
    @EnvironmentObject private var app: AloAppModel
    @ObservedObject var store: AloSecretChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var confirmsDelete = false
    @State private var now = Date()
    @FocusState private var composerFocused: Bool
    // Voice messages and circles are recorded with the ordinary chat's pieces (MessagesView): the same button (a tap
    // switches voice/circle, holding records, up locks, left cancels), the same panels; the clip is sealed like a photo.
    @State private var audioRecorder = ChatAudioRecorder()
    @StateObject private var circleRecorder = ChatCircleRecorder()
    @State private var recordingMode: ChatRecordingMode = .voice
    @State private var activeRecordingMode: ChatRecordingMode?
    @State private var recordingStartedAt = Date()
    @State private var isRecordingLocked = false
    @State private var isRecorderReady = false
    @State private var recordingDrag = AloRecordingDrag()
    @State private var isFinalizingRecording = false
    /// One circle plays at a time, inline while it is on screen and as the floating circle when scrolled away (as in
    /// an ordinary chat: the player needs to know which part of the screen shows the messages).
    @State private var circlePlayback = AloCirclePlayback()
    @State private var scrollToMessageId: Int?

    /// Telegram's green for secret chats: the lock, the name, the request buttons.
    static let green = Color(red: 0.2, green: 0.75, blue: 0.35)
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The wallpaper of ordinary chats (Settings → chat look): a secret chat looks like any other chat but for the green name.
    @State private var chatAppearance = AloChatAppearanceStore.readGlobal()

    var body: some View {
        let chat = store.activeChat
        content(chat)
                .environment(\.aloCirclePlayback, circlePlayback)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    circlePlayback.viewport = frame
                }
                .overlay {
                    AloFloatingCircle(playback: circlePlayback, accent: AloTheme.accent) { scrollToMessageId = $0 }
                        .padding(.vertical, 12)
                }
                .overlay {
                    // The camera of a circle being recorded, over the messages; the composer below stays usable.
                    if activeRecordingMode == .circle {
                        CircleRecordingOverlay(
                            startedAt: recordingStartedAt,
                            ready: isRecorderReady,
                            recorder: circleRecorder,
                            accentColor: AloTheme.accent,
                            topChrome: 0,
                            bottomChrome: 0,
                            onSend: { finishRecording() }
                        )
                        .transition(.opacity)
                    }
                }
            // As in an ordinary chat (MessagesView `conversationLayers`), the messages scroll under the header and the
            // composer, and the wallpaper fades in over them at both edges.
            .safeAreaInset(edge: .top, spacing: 0) {
                header(chat)
                    .background(alignment: .top) { edgeBackdrop(.top) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let chat, chat.isActive, !store.isGone {
                    composer
                        .background(alignment: .bottom) { edgeBackdrop(.bottom) }
                }
            }
        .background(AloChatWallpaper(appearance: chatAppearance).ignoresSafeArea())
        .onDisappear {
            discardRecording()
            circlePlayback.stop()
        }
        .onChange(of: store.activeId) { _, _ in
            discardRecording()
            circlePlayback.stop()
        }
        .onChange(of: store.messages) { _, _ in updateCircleQueue() }
        .onAppear(perform: updateCircleQueue)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("aloMediaPlaybackDidStart"))) { note in
            if let id = note.object as? String, circlePlayback.item?.id != id { circlePlayback.stop() }
        }
        .onReceive(ticker) { now = $0 }
        .onChange(of: pickerItems) { _, items in importPicked(items) }
        .confirmationDialog(deleteTitle(chat), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(chat?.isIncomingRequest == true ? "Отклонить" : "Удалить у обоих", role: .destructive) {
                Task { await store.delete() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все сообщения и файлы этого чата исчезнут на обоих устройствах и на сервере.")
        }
        .alert("Секретный чат", isPresented: Binding(
            get: { !store.errorMessage.isEmpty }, set: { if !$0 { store.errorMessage = "" } }
        )) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(store.errorMessage)
        }
        // A container: its own name must not replace the names of the buttons inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.secret.screen")
    }

    // MARK: Header

    /// The header of an ordinary chat (MessagesView `header`): Back in a glass circle, the name in a glass oval and the
    /// person's photo on the right. A secret chat has no details screen, so the oval and the photo open its menu.
    private func header(_ chat: AloSecretChat?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AloChatCircleButton(systemImage: "chevron.left", label: "Назад") {
                composerFocused = false
                withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9)) { store.close() }
            }
            .accessibilityIdentifier("alo.secret.back")
            .frame(height: AloChatMetrics.headerHeight)

            Menu { menuItems(chat) } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold))
                        Text(chat?.peerName ?? "Секретный чат")
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Self.green)
                    Text(subtitle(chat))
                        .font(.caption)
                        .foregroundStyle(AloTheme.muted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: AloChatMetrics.headerHeight)
                .modifier(AloChatGlass())
                .contentShape(Capsule())
            }
            .buttonStyle(AloControlPressStyle())
            .disabled(chat == nil || store.isGone)
            .accessibilityLabel("\(chat?.peerName ?? "Секретный чат"), \(subtitle(chat))")
            .accessibilityHint("Меню чата")
            .accessibilityIdentifier("alo.secret.more")

            Menu { menuItems(chat) } label: {
                AloAvatar(
                    name: chat?.peerName ?? "Секретный чат",
                    url: chat?.peerAvatarUrl ?? "",
                    size: AloChatMetrics.control,
                    colorSeed: String(chat?.peerUserId ?? 0)
                )
                .overlay(Circle().stroke(AloTheme.border, lineWidth: 0.5))
                .contentShape(Circle())
            }
            .buttonStyle(AloChatPressStyle())
            .disabled(chat == nil || store.isGone)
            .frame(height: AloChatMetrics.headerHeight)
            .accessibilityLabel("Меню секретного чата")
            .accessibilityIdentifier("alo.secret.avatar")
        }
        .padding(.horizontal, AloChatMetrics.headerHorizontalInset)
        .padding(.top, AloChatMetrics.headerTopInset)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func menuItems(_ chat: AloSecretChat?) -> some View {
        if let chat, chat.isActive {
            Menu {
                ForEach(AloSecretChatCodec.timerChoices, id: \.seconds) { choice in
                    Button {
                        Task { await store.setTimer(seconds: choice.seconds) }
                    } label: {
                        if choice.seconds == chat.ttlSeconds {
                            Label(choice.title, systemImage: "checkmark")
                        } else {
                            Text(choice.title)
                        }
                    }
                }
            } label: {
                Label("Таймер самоуничтожения", systemImage: "timer")
            }
        }
        Button(role: .destructive) { confirmsDelete = true } label: {
            Label(chat?.isIncomingRequest == true ? "Отклонить запрос" : "Удалить чат", systemImage: "trash")
        }
    }

    /// The wallpaper copy that fades the messages out under the header and the composer (AloChatEdgeBackdrop), reaching
    /// into the status bar and the home indicator area.
    private func edgeBackdrop(_ edge: AloChatEdge) -> some View {
        let chrome = edge == .top
            ? AloChatMetrics.headerHeight + AloChatMetrics.headerTopInset + 8
            : AloInputMetrics.touchHeight + AloInputMetrics.verticalPadding * 2
        return AloChatEdgeBackdrop(edge: edge, wallpaper: chatAppearance)
            .frame(height: chrome + edge.inwardExtension)
            .ignoresSafeArea(.container, edges: edge == .top ? .top : .bottom)
            .allowsHitTesting(false)
    }

    private func subtitle(_ chat: AloSecretChat?) -> String {
        guard let chat, !store.isGone else { return "чат закрыт" }
        if chat.isIncomingRequest { return "запрос секретного чата" }
        if chat.isWaiting { return "ожидание собеседника" }
        if chat.ttlSeconds > 0 { return "таймер: \(AloSecretChatCodec.timerLabel(chat.ttlSeconds).lowercased())" }
        return "секретный чат"
    }

    private func deleteTitle(_ chat: AloSecretChat?) -> String {
        chat?.isIncomingRequest == true ? "Отклонить секретный чат?" : "Удалить секретный чат?"
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ chat: AloSecretChat?) -> some View {
        if store.isGone {
            placeholder(systemImage: "lock.slash", title: "Секретный чат закрыт",
                        text: "Собеседник удалил его, или его открыли на другом устройстве.")
        } else if let chat {
            if chat.isIncomingRequest {
                requestCard(chat)
            } else {
                messageList(chat)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(systemImage: String, title: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 44, weight: .regular)).foregroundStyle(AloTheme.muted)
            Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(AloTheme.text)
            Text(text).font(.system(size: 15)).foregroundStyle(AloTheme.muted).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What a secret chat is, in Telegram's words: shown at the top of the chat and on a request.
    private func introCard(title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(Self.green)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.text)
            }
            Text("Секретные чаты:").font(.system(size: 14, weight: .semibold)).foregroundStyle(AloTheme.text)
            ForEach(Self.properties, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(Self.green)
                    Text(line).font(.system(size: 14)).foregroundStyle(AloTheme.text.opacity(0.85))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 320, alignment: .leading)
        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("alo.secret.intro")
    }

    static let properties = [
        "шифруются между двумя устройствами",
        "видны только на этом устройстве",
        "исчезают по таймеру самоуничтожения",
        "не пересылаются и удаляются с сервера вместе с чатом"
    ]

    private func requestCard(_ chat: AloSecretChat) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            AloAvatar(name: chat.peerName, url: chat.peerAvatarUrl, size: 84, colorSeed: String(chat.peerUserId))
            Text("\(chat.peerName) приглашает вас в секретный чат")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(AloTheme.text)
                .multilineTextAlignment(.center)
            introCard(title: "Чат откроется только на этом устройстве")
            HStack(spacing: 12) {
                Button { confirmsDelete = true } label: {
                    Text("Отклонить").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .accessibilityIdentifier("alo.secret.decline")
                Button { Task { await store.accept() } } label: {
                    Text("Принять").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Self.green, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .accessibilityIdentifier("alo.secret.accept")
            }
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageList(_ chat: AloSecretChat) -> some View {
        let visible = AloSecretTimers.visible(store.messages, nowMillis: now.timeIntervalSince1970 * 1000)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    VStack(spacing: 10) {
                        if chat.isWaiting {
                            Text("Ждём, пока \(chat.peerName) зайдёт в сеть…")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(AloTheme.muted)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("alo.secret.waiting")
                        }
                        // Names are not declined in Russian here, so the wording never needs a case: «Приглашение: Софья».
                        introCard(title: chat.role == "started"
                                  ? "Приглашение в секретный чат: \(chat.peerName)"
                                  : "Вы в секретном чате")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)

                    if store.isLoading && visible.isEmpty && chat.isActive {
                        ProgressView().padding(.top, 20)
                    }
                    ForEach(visible) { message in
                        bubble(message).id(message.id)
                    }
                    Color.clear.frame(height: 4).id("alo.secret.bottom")
                }
                .padding(.horizontal, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("alo.secret.bottom", anchor: .bottom) }
            .onChange(of: visible.last?.id) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo("alo.secret.bottom", anchor: .bottom)
                }
            }
            .onChange(of: scrollToMessageId) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                scrollToMessageId = nil
            }
        }
    }

    // MARK: Messages

    private func bubble(_ message: AloSecretMessage) -> some View {
        let mine = message.senderUserId == (app.bootstrap?.me.id ?? 0)
        let circles = message.attachments.filter(\.isCircleAttachment)
        let voices = message.attachments.filter { $0.isVoiceAttachment && !$0.isCircleAttachment }
        let images = message.attachments.filter { $0.type.lowercased() == "image" }
        let files = message.attachments.filter {
            $0.type.lowercased() != "image" && !$0.isVoiceAttachment && !$0.isCircleAttachment
        }
        return HStack(spacing: 0) {
            if mine { Spacer(minLength: 52) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                // A circle has no bubble: a round video with its first frame, the time on a pill (as in an ordinary chat).
                ForEach(circles) { attachment in
                    CircleMessageAttachmentView(
                        attachment: attachment,
                        accentColor: AloTheme.accent,
                        messageID: message.id,
                        senderName: mine ? "Вы" : (store.activeChat?.peerName ?? "Видеосообщение")
                    )
                    .frame(width: 212, height: 212)
                    .accessibilityIdentifier("alo.secret.circle")
                }
                if circles.isEmpty || !(voices.isEmpty && images.isEmpty && files.isEmpty && message.body.isEmpty) {
                    bubbleBody(message, mine: mine, voices: voices, images: images, files: files)
                } else {
                    meta(message, mine: mine)
                        .fixedSize()
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.46), in: Capsule())
                }
            }
            if !mine { Spacer(minLength: 52) }
        }
    }

    private func bubbleBody(_ message: AloSecretMessage, mine: Bool, voices: [AloMessageAttachment],
                            images: [AloMessageAttachment], files: [AloMessageAttachment]) -> some View {
        // A voice message alone carries the time and ticks on its own row, as in an ordinary chat: a separate line under
        // it made the bubble taller at the bottom than at the top and the side.
        let voiceOnly = !voices.isEmpty && images.isEmpty && files.isEmpty && message.body.isEmpty
        let timed = !message.expiresAt.isEmpty || message.selfDestructSeconds > 0
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                // The voice bubble of an ordinary chat: play, the recorded bars (tap or drag to seek), the length.
                ForEach(voices) { attachment in
                    VoiceMessageAttachmentView(
                        attachment: attachment,
                        senderName: mine ? "Вы" : (store.activeChat?.peerName ?? "Голосовое сообщение"),
                        isMine: mine,
                        accentColor: AloTheme.accent,
                        showMessageMeta: voiceOnly && attachment.id == voices.last?.id,
                        createdAt: message.createdAt,
                        isRead: !message.readAt.isEmpty,
                        onLongPress: {}
                    )
                    .frame(width: 230)
                    .accessibilityIdentifier("alo.secret.voice")
                }
                ForEach(images) { attachment in
                    AloAsyncImage(url: URL(string: attachment.url), downloadIntent: .userInitiated) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            ZStack {
                                Rectangle().fill(AloTheme.text.opacity(0.08))
                                ProgressView()
                            }
                        }
                    }
                    .frame(width: 230, height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Фото")
                }
                ForEach(files) { attachment in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill")
                        Text(attachment.name.ifBlank("Файл")).lineLimit(1)
                    }
                    .font(.system(size: 15))
                }
                if !message.body.isEmpty {
                    if message.unreadable {
                        Text(message.body).font(.system(size: 15).italic()).opacity(0.7)
                    } else {
                        AloRichMessageText(body: message.body, entities: message.entities, fontSize: 16)
                    }
                }
                if !voiceOnly || timed {
                    meta(message, mine: mine)
                }
            }
            .foregroundStyle(mine ? Color.white : AloTheme.text)
            // The voice bubble of an ordinary chat is 9 × 8; text keeps 12 × 8.
            .padding(.horizontal, voiceOnly ? 9 : 12)
            .padding(.vertical, 8)
            .modifier(AloMessageBubbleSurface(color: mine ? Color(red: 23 / 255, green: 125 / 255, blue: 1)
                                                         : Color(red: 30 / 255, green: 33 / 255, blue: 40 / 255),
                                              isMine: mine, startsRun: true, endsRun: true))
            // A voice message keeps its play button and waveform reachable; any other bubble reads as one element.
            .accessibilityElement(children: voices.isEmpty ? .combine : .contain)
            .accessibilityIdentifier("alo.secret.message")
        }
    }

    private func meta(_ message: AloSecretMessage, mine: Bool) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if !message.expiresAt.isEmpty {
                let left = AloSecretTime.millis(message.expiresAt) - now.timeIntervalSince1970 * 1000
                Image(systemName: "flame.fill").font(.system(size: 10))
                Text(AloSecretChatCodec.countdownLabel(millisLeft: left))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .accessibilityIdentifier("alo.secret.countdown")
            } else if message.selfDestructSeconds > 0 {
                Image(systemName: "timer").font(.system(size: 10))
            }
            Text(AloFormatters.messageTime(message.createdAt)).font(.system(size: 11))
            if mine {
                Image(systemName: message.readAt.isEmpty ? "checkmark" : "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .opacity(0.7)
    }

    // MARK: Composer

    /// A recorded voice message or circle waiting in the composer (the recorder's own types are `audio` and `circle`).
    static func isRecording(_ draft: AloLocalAttachment) -> Bool {
        ["audio", "voice", "circle"].contains(draft.type.lowercased())
    }

    private var recordedDraft: AloLocalAttachment? { store.drafts.first(where: Self.isRecording) }
    private var otherDrafts: [AloLocalAttachment] { store.drafts.filter { !Self.isRecording($0) } }

    private var composer: some View {
        VStack(spacing: 6) {
            if !otherDrafts.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                    Text("Вложений: \(otherDrafts.count)").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Button("Убрать") { for id in otherDrafts.map(\.id) { store.removeDraft(id: id) } }
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(AloTheme.muted)
                .padding(.horizontal, 16)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if isFinalizingRecording {
                    ProgressView(recordingMode == .circle ? "Подготовка кружка…" : "Подготовка голосового…")
                        .font(.subheadline).tint(AloTheme.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else if let mode = activeRecordingMode {
                    AloRecordingLevelsView(recorder: audioRecorder) { levels in
                        RecordingComposerPanel(
                            mode: mode,
                            startedAt: recordingStartedAt,
                            ready: isRecorderReady,
                            isLocked: isRecordingLocked,
                            drag: recordingDrag,
                            accentColor: AloTheme.accent,
                            levels: levels,
                            onCancel: cancelRecording,
                            onStop: { finishRecording() }
                        )
                    }
                    .transition(.opacity)
                } else if let recorded = recordedDraft {
                    RecordedDraftComposerPanel(
                        attachment: recorded,
                        duration: recorded.durationSeconds ?? 0,
                        levels: recorded.waveform,
                        accentColor: AloTheme.accent,
                        onRemove: { store.removeDraft(id: recorded.id) }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    // The ordinary chat's composer pieces (MessagesView `ChatComposerButton` and the glass field).
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                        Image(systemName: isImporting ? "hourglass" : "paperclip")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(AloTheme.muted)
                            .frame(width: AloInputMetrics.height, height: AloInputMetrics.height)
                            .modifier(AloChatGlass())
                            .frame(width: AloInputMetrics.touchHeight, height: AloInputMetrics.touchHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(AloControlPressStyle())
                    .disabled(isImporting || store.isSending)
                    .accessibilityLabel("Прикрепить фото")
                    .accessibilityIdentifier("alo.secret.attach")

                    TextField("Секретное сообщение", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .font(.body)
                        .foregroundStyle(AloTheme.text)
                        .focused($composerFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(minHeight: AloInputMetrics.height)
                        .modifier(AloChatPanelGlass(
                            radius: text.count > 40 || text.contains("\n") ? AloInputMetrics.multiLineRadius : AloInputMetrics.singleLineRadius,
                            role: .control
                        ))
                        .frame(minHeight: AloInputMetrics.touchHeight)
                        .accessibilityIdentifier("alo.secret.input")
                }
                trailingButton
            }
            .padding(.horizontal, AloInputMetrics.inset)
        }
        .padding(.vertical, AloInputMetrics.verticalPadding)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: store.drafts.count)
    }

    /// Send when there is something to send; otherwise the microphone / camera button of an ordinary chat.
    @ViewBuilder
    private var trailingButton: some View {
        if canSend && activeRecordingMode == nil {
            // The same 44 pt filled circle as the ordinary chat's send button (ChatRecordSendButton), in the secret green.
            Button(action: send) {
                Image(systemName: store.isSending ? "hourglass" : "arrow.up")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: AloInputMetrics.height, height: AloInputMetrics.height)
                    .background(Self.green, in: Circle())
                    .frame(width: AloInputMetrics.touchHeight, height: AloInputMetrics.touchHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityLabel("Отправить")
            .accessibilityIdentifier("alo.secret.send")
        } else if store.isSending || isImporting || isFinalizingRecording {
            Image(systemName: "hourglass")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: AloInputMetrics.height, height: AloInputMetrics.height)
                .background(AloTheme.muted.opacity(0.35), in: Circle())
                .frame(width: AloInputMetrics.touchHeight, height: AloInputMetrics.touchHeight)
                .accessibilityLabel("Отправка")
                .accessibilityIdentifier("alo.secret.send")
        } else {
            ZStack {
                AloRecordingLevelsView(recorder: audioRecorder) { levels in
                    ChatRecordSendButton(
                        mode: recordingMode,
                        canSend: false,
                        isRecording: activeRecordingMode != nil,
                        isLocked: isRecordingLocked,
                        level: activeRecordingMode == .voice ? (levels.last ?? 0) : 0,
                        drag: $recordingDrag,
                        accentColor: AloTheme.accent,
                        allowsSendOptions: false,
                        onSend: {},
                        onShowSendOptions: {},
                        onToggleMode: toggleRecordingMode,
                        onHoldStart: startRecording,
                        onHoldEnd: { finishRecording() },
                        onLock: lockRecording,
                        onCancel: cancelRecording
                    )
                }
                .opacity(isRecordingLocked ? 0 : 1)
                .allowsHitTesting(!isRecordingLocked)
                .accessibilityHidden(isRecordingLocked)
                if isRecordingLocked && activeRecordingMode == .voice {
                    // As the ordinary chat (Telegram): the big circle stays after locking and sends.
                    AloRecordingLevelsView(recorder: audioRecorder) { levels in
                        Button { finishRecording(sendNow: true) } label: {
                            AloRecordingOrb(symbol: "arrow.up", color: AloTheme.accent,
                                            level: levels.last ?? 0, cancelProgress: 0, hitTesting: true)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle().inset(by: -33))
                        }
                        .buttonStyle(AloControlPressStyle())
                        .accessibilityLabel("Отправить запись")
                        .accessibilityIdentifier("alo.secret.record.send")
                        .disabled(!isRecorderReady)
                    }
                    .transition(.opacity)
                } else if isRecordingLocked {
                    Button { finishRecording(sendNow: true) } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(AloTheme.accent, in: Circle())
                    }
                    .buttonStyle(AloControlPressStyle())
                    .accessibilityLabel("Отправить запись")
                    .accessibilityIdentifier("alo.secret.record.send")
                    .disabled(!isRecorderReady)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                // Telegram: the lock 122 pt above the mic centre rises with the finger; once locked,
                // a pause button 102 pt above it stops into a preview.
                let micCentre = AloInputMetrics.touchHeight / 2
                if activeRecordingMode != nil && !isRecordingLocked {
                    AloRecordingLock(progress: recordingDrag.lockProgress, onLock: lockRecording)
                        .offset(y: -(AloRecordingMetrics.lockLift + micCentre - AloRecordingMetrics.lockSize.height / 2)
                                + recordingDrag.offset.height)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                } else if activeRecordingMode == .voice && isRecordingLocked {
                    AloRecordingPauseButton(enabled: isRecorderReady, label: "Завершить и прослушать запись") {
                        finishRecording()
                    }
                    .offset(y: -(AloRecordingMetrics.pauseLift + micCentre - 20))
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
        }
    }

    private var canSend: Bool {
        !store.isSending && !isImporting && !isFinalizingRecording
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.drafts.isEmpty)
    }

    private func send() {
        let body = text
        guard canSend else { return }
        text = ""
        Task {
            let sent = await store.send(text: body)
            // Nothing is lost when sending failed: the words go back into the field.
            if !sent, text.isEmpty { text = body }
        }
    }

    /// The circles of the chat in order: one that ends hands over to the next, as in an ordinary chat.
    private func updateCircleQueue() {
        let peerName = store.activeChat?.peerName ?? "Видеосообщение"
        let me = app.bootstrap?.me.id ?? 0
        if let item = circlePlayback.item, !store.messages.contains(where: { $0.id == item.messageID }) {
            circlePlayback.stop()
        }
        circlePlayback.setQueue(store.messages.flatMap { message in
            message.attachments.filter(\.isCircleAttachment).compactMap { attachment in
                app.api.absoluteURL(attachment.url).map {
                    AloCircleQueueItem(id: attachment.id, messageID: message.id, url: $0,
                                       title: message.senderUserId == me ? "Вы" : peerName)
                }
            }
        })
    }

    // MARK: Recording

    private func toggleRecordingMode() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86)) {
            recordingMode = recordingMode == .voice ? .circle : .voice
        }
        AloHaptics.selection()
    }

    private func startRecording() {
        guard activeRecordingMode == nil, !store.isSending, recordedDraft == nil else { return }
        guard app.calls.activeCall == nil, app.calls.groupCall.activeCall == nil else {
            store.errorMessage = "Запись недоступна во время звонка. Завершите звонок и повторите попытку."
            return
        }
        recordingStartedAt = Date()
        isRecordingLocked = false
        isRecorderReady = false
        recordingDrag = AloRecordingDrag()
        composerFocused = false
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.22)) {
            activeRecordingMode = recordingMode
        }
        AloHaptics.impact(.medium)
        switch recordingMode {
        case .voice:
            audioRecorder.start(onReady: recordingDidStart, onLimitReached: {
                if activeRecordingMode == .voice { finishRecording() }
            })
        case .circle:
            circleRecorder.start(onReady: recordingDidStart, onStopped: {
                if activeRecordingMode == .circle { finishRecording() }
            })
        }
    }

    private func recordingDidStart(_ error: String?) {
        guard activeRecordingMode != nil else { return }
        if let error {
            cancelRecording()
            store.errorMessage = error
        } else {
            recordingStartedAt = Date()
            isRecorderReady = true
        }
    }

    private func lockRecording() {
        guard activeRecordingMode != nil, !isRecordingLocked else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1)) {
            isRecordingLocked = true
            recordingDrag = AloRecordingDrag()
        }
        AloHaptics.notification(.success)
    }

    /// Releasing the button (or «stop» while locked) leaves the clip in the composer to listen to or send; the arrow
    /// of a locked recording sends it at once, as in an ordinary chat.
    private func finishRecording(sendNow: Bool = false) {
        guard let mode = activeRecordingMode else { return }
        let duration = Date().timeIntervalSince(recordingStartedAt)
        let chatId = store.activeId
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.2)) {
            activeRecordingMode = nil
            isRecordingLocked = false
            recordingDrag = AloRecordingDrag()
        }
        guard isRecorderReady, duration > 0.55 else {
            audioRecorder.cancel()
            circleRecorder.cancel()
            return
        }
        AloHaptics.impact(.light)
        isFinalizingRecording = true
        switch mode {
        case .voice:
            let metered = audioRecorder.levels
            audioRecorder.stop { attachment, waveform in
                isFinalizingRecording = false
                guard let attachment else {
                    store.errorMessage = "Не удалось сохранить голосовое сообщение. Попробуйте записать снова."
                    return
                }
                keepRecorded(attachment.replacingWaveform(waveform.isEmpty ? metered : waveform),
                             duration: duration, chatId: chatId, sendNow: sendNow)
            }
        case .circle:
            circleRecorder.stop { attachment in
                isFinalizingRecording = false
                guard let attachment else {
                    store.errorMessage = "Кружок не записан. Проверьте доступ к камере и попробуйте снова."
                    return
                }
                keepRecorded(attachment, duration: duration, chatId: chatId, sendNow: sendNow)
            }
        }
    }

    private func keepRecorded(_ attachment: AloLocalAttachment, duration: TimeInterval, chatId: Int, sendNow: Bool) {
        let recorded = attachment.withDuration(attachment.durationSeconds ?? duration)
        guard store.activeId == chatId, store.activeChat?.isActive == true, !store.isGone else {
            AloDraftAttachmentStore.discard(recorded)
            return
        }
        for old in store.drafts where Self.isRecording(old) { store.removeDraft(id: old.id) }
        store.addDrafts([recorded])
        if sendNow { send() }
    }

    private func cancelRecording() {
        guard activeRecordingMode != nil else { return }
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.2)) {
            activeRecordingMode = nil
            isRecordingLocked = false
            isRecorderReady = false
            recordingDrag = AloRecordingDrag()
        }
        audioRecorder.cancel()
        circleRecorder.cancel()
        AloHaptics.notification(.warning)
    }

    /// Leaving the chat (or another chat opening) throws away a recording that is still going.
    private func discardRecording() {
        guard activeRecordingMode != nil else { return }
        activeRecordingMode = nil
        isRecordingLocked = false
        isRecorderReady = false
        recordingDrag = AloRecordingDrag()
        audioRecorder.cancel()
        circleRecorder.cancel()
    }

    private func importPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isImporting = true
        Task {
            defer {
                isImporting = false
                pickerItems = []
            }
            do {
                store.addDrafts(try await AloFeedMediaImport.load(items))
            } catch {
                store.errorMessage = "Не удалось подготовить фото."
            }
        }
    }
}
