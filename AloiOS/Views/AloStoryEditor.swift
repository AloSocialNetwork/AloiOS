import AVFoundation
import CoreImage
import PencilKit
import PhotosUI
import SwiftUI
import UIKit

/// Something placed on a story page: an emoji or a block of styled text. The position is relative
/// (0…1) so it survives any canvas size; the size is a factor of the base font size.
struct AloStorySticker: Identifiable, Equatable {
    enum Content: Equatable {
        case emoji(String)
        case text(String, AloStoryTextStyle)
    }

    let id = UUID()
    var content: Content
    var position = CGPoint(x: 0.5, y: 0.45)
    var scale: CGFloat = 1
    var rotation: Angle = .zero

    static let scales: ClosedRange<CGFloat> = 0.35...5

    init(emoji: String) {
        content = .emoji(emoji)
        position = CGPoint(x: 0.5, y: 0.56)
    }

    init(text: String, style: AloStoryTextStyle) {
        content = .text(text, style)
        position = CGPoint(x: 0.5, y: 0.4)
    }

    var isText: Bool {
        if case .text = content { return true }
        return false
    }

    var accessibilityLabel: String {
        switch content {
        case .emoji(let emoji): return "Стикер \(emoji)"
        case .text(let text, _): return "Текст: \(text)"
        }
    }

    static func clamped(_ scale: CGFloat) -> CGFloat {
        min(scales.upperBound, max(scales.lowerBound, scale))
    }
}

/// Edits that belong to one page: what was drawn and which stickers sit on it.
struct AloStoryPageEdits: Equatable {
    var drawing = PKDrawing()
    var stickers: [AloStorySticker] = []
    var isEmpty: Bool { drawing.strokes.isEmpty && stickers.isEmpty }
}

/// The look of a text story, chosen with the text tools.
struct AloStoryTextStyle: Equatable {
    enum Typeface: CaseIterable { case bold, serif, typewriter }
    enum Plate: CaseIterable { case none, soft, solid }

    var typeface: Typeface = .bold
    var colorIndex = 0
    var plate: Plate = .none
    var gradientIndex = 0

    static let colors: [Color] = [.white, .black, Color(red: 1, green: 0.27, blue: 0.23), Color(red: 1, green: 0.62, blue: 0.04),
                                  Color(red: 1, green: 0.84, blue: 0.04), Color(red: 0.2, green: 0.78, blue: 0.35),
                                  Color(red: 0.04, green: 0.52, blue: 1), Color(red: 0.69, green: 0.32, blue: 0.87)]
    static let gradients: [[Color]] = [
        [AloTheme.accent, Color(red: 0.42, green: 0.27, blue: 0.93)],
        [Color(red: 1, green: 0.42, blue: 0.4), Color(red: 1, green: 0.66, blue: 0.24)],
        [Color(red: 0.07, green: 0.6, blue: 0.56), Color(red: 0.2, green: 0.82, blue: 0.5)],
        [Color(red: 0.13, green: 0.14, blue: 0.18), Color(red: 0.32, green: 0.33, blue: 0.4)],
        [Color(red: 0.93, green: 0.36, blue: 0.62), Color(red: 0.55, green: 0.32, blue: 0.95)]
    ]

    func font(size: CGFloat) -> Font {
        switch typeface {
        case .bold: return .system(size: size, weight: .bold)
        case .serif: return .system(size: size, weight: .semibold, design: .serif)
        case .typewriter: return .system(size: size * 0.86, weight: .medium, design: .monospaced)
        }
    }

    var textColor: Color {
        let base = Self.colors[colorIndex]
        // On a solid plate the plate takes the colour and the text turns white or black.
        if plate == .solid { return colorIndex == 0 ? .black : .white }
        return base
    }

    var plateColor: Color? {
        switch plate {
        case .none: return nil
        case .soft: return .black.opacity(0.38)
        case .solid: return Self.colors[colorIndex]
        }
    }
}

/// "Новая история", after Telegram's story editor: a full-screen 9:16 canvas with drawing, emoji
/// stickers, styled text on a gradient (a text story) or a photo/video with a caption, the camera,
/// and the lifetime next to the publish button. Pages with edits are flattened into a 1080 × 1920
/// picture before upload; untouched photos and videos are sent as they are.
struct AloStoryEditorScreen: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTextFocused: Bool
    @State private var text = ""
    @State private var textStyle = AloStoryTextStyle()
    @State private var pickedItems = [PhotosPickerItem]()
    @State private var attachments = [AloLocalAttachment]()
    @State private var page = 0
    @State private var edits: [UUID: AloStoryPageEdits] = [:]
    @State private var mode = Mode.none
    @State private var isStickerSheetPresented = false
    @State private var isCameraPresented = false
    @State private var draggingStickerOverTrash = false
    @State private var isDraggingSticker = false
    @State private var selectedStickerID: UUID?
    @State private var editingTextID: UUID?
    @State private var draftText = ""
    @State private var lifetimeHours = 24
    @State private var publishRequested = false
    @State private var isPreparing = false
    @State private var isImporting = false
    @State private var importError = ""
    @State private var importTask: Task<Void, Never>?
    private var accessibility = AloVisualAccessibility()

    enum Mode: Equatable { case none, draw, text, sticker }

    /// The id the text story's edits are kept under (it has no attachment).
    private static let textPageID = UUID()

    private var currentAttachment: AloLocalAttachment? {
        attachments.indices.contains(page) ? attachments[page] : nil
    }
    private var currentPageID: UUID { currentAttachment?.id ?? Self.textPageID }
    private var currentIsVideo: Bool { currentAttachment?.type == "video" }
    private var isPublishDisabled: Bool {
        let typing = mode == .text && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isImporting || isPreparing || (attachments.isEmpty && (edits[Self.textPageID]?.isEmpty ?? true) && !typing)
    }

    var body: some View {
        GeometryReader { proxy in
            let barHeight: CGFloat = 64
            let available = CGSize(width: proxy.size.width - 16, height: proxy.size.height - barHeight - 8)
            let canvasWidth = min(available.width, available.height * 9 / 16)
            let canvasSize = CGSize(width: canvasWidth, height: canvasWidth * 16 / 9)
            VStack(spacing: 8) {
                canvas(size: canvasSize)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .frame(maxWidth: .infinity)
                bottomBar(canvasSize: canvasSize).frame(height: barHeight)
            }
            .padding(.top, 4)
        }
        // The keyboard covers the lower part of the canvas instead of shrinking it.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(app.isCreatingStory || isPreparing)
        .animation(accessibility.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88), value: mode)
        .onAppear {
            // A new story starts as a text story with the keyboard up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if attachments.isEmpty, mode == .none { startTextEditing(nil) }
            }
        }
        .onChange(of: pickedItems) { _, items in
            importTask?.cancel()
            isImporting = true
            importError = ""
            importTask = Task { await loadPickedItems(items) }
        }
        .onChange(of: app.isCreatingStory) { wasCreating, isCreating in
            guard publishRequested, wasCreating, !isCreating, app.storyPublishingError.isEmpty else { return }
            AloHaptics.notification(.success)
            dismiss()
        }
        .onDisappear {
            importTask?.cancel()
            attachments.forEach(AloDraftAttachmentStore.discard)
        }
        .sheet(isPresented: $isStickerSheetPresented) {
            AloStoryStickerPicker { emoji in
                isStickerSheetPresented = false
                let sticker = AloStorySticker(emoji: emoji)
                edits[currentPageID, default: AloStoryPageEdits()].stickers.append(sticker)
                // Selected straight away: its frame shows it can be moved and stretched.
                selectedStickerID = sticker.id
                mode = .sticker
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            AloStoryCamera { url, isVideo in
                isCameraPresented = false
                guard let url else { return }
                isImporting = true
                Task {
                    defer { isImporting = false }
                    do {
                        let attachment = try await AloFeedMediaImport.prepare(source: url, video: isVideo)
                        attachments.append(attachment)
                        page = attachments.count - 1
                        if attachments.count == 1 { adoptTextPage(into: attachment.id) }
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Canvas

    @ViewBuilder
    private func canvas(size: CGSize) -> some View {
        ZStack {
            if attachments.isEmpty {
                LinearGradient(colors: AloStoryTextStyle.gradients[textStyle.gradientIndex],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                TabView(selection: $page) {
                    ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                        Group {
                            if attachment.type == "video" {
                                AloStoryLoopingVideo(attachment: attachment, isActive: index == page)
                            } else {
                                FeedAttachmentPreview(attachment: attachment, side: nil, maxPixelSize: 1_440)
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: attachments.count > 1 && mode == .none ? .automatic : .never))
                .allowsHitTesting(mode == .none)
            }

            // What was drawn on this page; live and editable only in draw mode.
            AloStoryDrawingCanvas(drawing: Binding(
                get: { edits[currentPageID]?.drawing ?? PKDrawing() },
                set: { edits[currentPageID, default: AloStoryPageEdits()].drawing = $0 }
            ), isActive: mode == .draw)
            .id(currentPageID)
            .allowsHitTesting(mode == .draw)

            // A tap on the empty page drops the selection or, on a text story, starts typing.
            if mode == .sticker || (mode == .none && attachments.isEmpty) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if mode == .sticker { deselect() } else { startTextEditing(nil) }
                    }
            }
            if mode == .none, attachments.isEmpty, !(edits[Self.textPageID]?.stickers.contains(where: \.isText) ?? false) {
                Text("Нажмите, чтобы написать")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .allowsHitTesting(false)
            }

            stickerLayer(size: size)
                .allowsHitTesting(mode == .none || mode == .sticker)

            if !attachments.isEmpty, mode == .none {
                VStack {
                    Spacer()
                    TextField("", text: $text, prompt: Text("Добавить подпись…").foregroundStyle(.white.opacity(0.62)),
                              axis: .vertical)
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                        .lineLimit(1...4)
                        .focused($isTextFocused)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .modifier(AloChatGlass(interactive: false, role: .chrome))
                        .padding(.horizontal, 12).padding(.bottom, attachments.count > 1 ? 34 : 14)
                        .disabled(app.isCreatingStory)
                        .accessibilityLabel("Подпись к истории")
                        .accessibilityIdentifier("alo.story.caption")
                }
            }

            if mode == .text {
                textEditor(canvasSize: size)
            }
            topControls
            if isDraggingSticker {
                VStack {
                    Spacer()
                    Image(systemName: "trash")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(draggingStickerOverTrash ? AloTheme.destructive : Color.black.opacity(0.45), in: Circle())
                        .scaleEffect(draggingStickerOverTrash ? 1.15 : 1)
                        .padding(.bottom, 18)
                }
                .allowsHitTesting(false)
            }
            statusOverlay
        }
    }

    /// Typing a text item: the page dims and the text sits above the keyboard in its style,
    /// wrapping at the same width as the placed item so its lines don't change on "Готово".
    private func textEditor(canvasSize: CGSize) -> some View {
        ZStack {
            Color.black.opacity(attachments.isEmpty ? 0.12 : 0.42)
                .contentShape(Rectangle())
                .onTapGesture { commitText() }
            let wrap = canvasSize.width * AloStoryStickerContent.textWrap
            let placeholder = attachments.isEmpty ? "Что происходит?" : "Текст"
            ZStack {
                // The plate hugs the words, as it will on the placed item.
                if let plate = textStyle.plateColor {
                    AloStoryTextWrap(width: wrap) {
                        Text(draftText.isEmpty ? placeholder : draftText)
                            .font(textStyle.font(size: AloStoryStickerContent.textSize))
                            .multilineTextAlignment(.center)
                            .hidden()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(plate, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                TextField("", text: $draftText,
                          prompt: Text(placeholder).foregroundStyle(textStyle.textColor.opacity(0.6)),
                          axis: .vertical)
                    .font(textStyle.font(size: AloStoryStickerContent.textSize))
                    .foregroundStyle(textStyle.textColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(1...8)
                    .focused($isTextFocused)
                    .frame(width: wrap)
            }
            .offset(y: -canvasSize.height * 0.1)
                .disabled(app.isCreatingStory)
                .accessibilityLabel("Текст истории")
                .accessibilityIdentifier("alo.story.text")
        }
    }

    private func startTextEditing(_ id: UUID?) {
        if let id, let item = edits[currentPageID]?.stickers.first(where: { $0.id == id }),
           case let .text(string, style) = item.content {
            draftText = string
            let gradient = textStyle.gradientIndex
            textStyle = style
            textStyle.gradientIndex = gradient
        } else {
            draftText = ""
        }
        editingTextID = id
        selectedStickerID = nil
        mode = .text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isTextFocused = true }
    }

    /// Places the typed text (or updates the one being edited) and selects it.
    private func commitText() {
        let string = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        isTextFocused = false
        var pageEdits = edits[currentPageID] ?? AloStoryPageEdits()
        var placed: UUID?
        if let id = editingTextID, let index = pageEdits.stickers.firstIndex(where: { $0.id == id }) {
            if string.isEmpty {
                pageEdits.stickers.remove(at: index)
            } else {
                pageEdits.stickers[index].content = .text(string, textStyle)
                placed = id
            }
        } else if !string.isEmpty {
            let item = AloStorySticker(text: string, style: textStyle)
            pageEdits.stickers.append(item)
            placed = item.id
        }
        edits[currentPageID] = pageEdits
        editingTextID = nil
        draftText = ""
        selectedStickerID = placed
        mode = placed == nil ? .none : .sticker
    }

    private func deselect() {
        selectedStickerID = nil
        mode = .none
    }

    private func stickerLayer(size: CGSize) -> some View {
        ZStack {
            ForEach((edits[currentPageID]?.stickers ?? []).filter { $0.id != editingTextID }) { sticker in
                AloStoryStickerView(sticker: sticker, canvasSize: size,
                    isSelected: mode == .sticker && selectedStickerID == sticker.id,
                    onTap: {
                        if sticker.isText, mode == .sticker, selectedStickerID == sticker.id {
                            startTextEditing(sticker.id)
                        } else {
                            isTextFocused = false
                            selectedStickerID = sticker.id
                            mode = .sticker
                        }
                    },
                    onDragChanged: { location in
                        isDraggingSticker = true
                        draggingStickerOverTrash = location.y > size.height - 90 && abs(location.x - size.width / 2) < 60
                    },
                    onCommit: { updated, droppedAt in
                        isDraggingSticker = false
                        let overTrash = droppedAt.map { $0.y > size.height - 90 && abs($0.x - size.width / 2) < 60 } ?? false
                        draggingStickerOverTrash = false
                        guard var pageEdits = edits[currentPageID],
                              let index = pageEdits.stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
                        if overTrash {
                            pageEdits.stickers.remove(at: index)
                            AloHaptics.impact(.medium)
                            if selectedStickerID == sticker.id { deselect() }
                        } else {
                            pageEdits.stickers[index] = updated
                        }
                        edits[currentPageID] = pageEdits
                    })
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var topControls: some View {
        VStack {
            HStack(spacing: 8) {
                switch mode {
                case .none:
                    AloChatCircleButton(systemImage: "xmark", label: "Закрыть редактор истории") { dismiss() }
                        .disabled(app.isCreatingStory)
                    Spacer()
                    AloChatCircleButton(systemImage: "scribble", label: "Рисовать") {
                        isTextFocused = false
                        mode = .draw
                    }
                    .accessibilityIdentifier("alo.story.draw")
                    AloChatCircleButton(systemImage: "face.smiling", label: "Стикеры") {
                        isTextFocused = false
                        isStickerSheetPresented = true
                    }
                    .accessibilityIdentifier("alo.story.stickers")
                    AloChatCircleButton(systemImage: "textformat", label: "Добавить текст") { startTextEditing(nil) }
                        .accessibilityIdentifier("alo.story.add-text")
                    if !attachments.isEmpty {
                        AloChatCircleButton(systemImage: "trash", label: "Убрать это медиа") { removeCurrent() }
                            .disabled(app.isCreatingStory)
                    }
                case .draw:
                    AloChatCircleButton(systemImage: "arrow.uturn.backward", label: "Отменить штрих") {
                        var drawing = edits[currentPageID]?.drawing ?? PKDrawing()
                        guard !drawing.strokes.isEmpty else { return }
                        drawing.strokes.removeLast()
                        edits[currentPageID, default: AloStoryPageEdits()].drawing = drawing
                    }
                    .accessibilityIdentifier("alo.story.undo")
                    Spacer()
                    doneButton { mode = .none }
                case .text:
                    Spacer()
                    doneButton { commitText() }
                case .sticker:
                    AloChatCircleButton(systemImage: "trash", label: "Удалить") {
                        if let id = selectedStickerID {
                            edits[currentPageID]?.stickers.removeAll { $0.id == id }
                        }
                        deselect()
                    }
                    .accessibilityIdentifier("alo.story.item-delete")
                    Spacer()
                    doneButton { deselect() }
                }
            }
            .padding(10)
            if mode == .text {
                textStyleBar
            }
            Spacer()
        }
    }

    private func doneButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Готово").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: 40)
                .background(AloTheme.accent, in: Capsule())
        }
        .buttonStyle(AloControlPressStyle())
        .accessibilityIdentifier("alo.story.tool-done")
    }

    /// Typeface, plate and colour of the text being typed; on a text story also its background.
    private var textStyleBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                styleButton(systemImage: "textformat.alt", label: "Шрифт") {
                    let all = AloStoryTextStyle.Typeface.allCases
                    textStyle.typeface = all[(all.firstIndex(of: textStyle.typeface)! + 1) % all.count]
                }
                styleButton(systemImage: textStyle.plate == .none ? "character" : "character.textbox", label: "Подложка") {
                    let all = AloStoryTextStyle.Plate.allCases
                    textStyle.plate = all[(all.firstIndex(of: textStyle.plate)! + 1) % all.count]
                }
                if attachments.isEmpty {
                    styleButton(systemImage: "paintpalette", label: "Фон") {
                        textStyle.gradientIndex = (textStyle.gradientIndex + 1) % AloStoryTextStyle.gradients.count
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(AloStoryTextStyle.colors.indices, id: \.self) { index in
                    Button { textStyle.colorIndex = index } label: {
                        Circle().fill(AloStoryTextStyle.colors[index])
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(.white, lineWidth: textStyle.colorIndex == index ? 3 : 1.5))
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(AloControlPressStyle())
                    .accessibilityLabel("Цвет \(index + 1)")
                    .accessibilityAddTraits(textStyle.colorIndex == index ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 10)
        .accessibilityIdentifier("alo.story.text-tools")
    }

    private func styleButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 40)
                .modifier(AloChatGlass(interactive: false, role: .chrome))
                // The glass doesn't take touches; without this a tap falls through to the page.
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(AloControlPressStyle())
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        VStack {
            Spacer()
            if isImporting || isPreparing {
                ProgressView(isPreparing ? "Готовим историю…" : "Подготовка медиа…").tint(.white).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .modifier(AloChatGlass(interactive: false, role: .chrome))
            }
            if let message = [importError, publishRequested ? app.storyPublishingError : ""].first(where: { !$0.isEmpty }) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AloTheme.destructive.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("alo.story.publish-error")
            }
            Spacer().frame(height: 80)
        }
        .allowsHitTesting(false)
    }

    // MARK: Bottom bar

    private func bottomBar(canvasSize: CGSize) -> some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Срок жизни", selection: $lifetimeHours) {
                    ForEach([6, 12, 24, 48], id: \.self) { hours in Text("\(hours) часов").tag(hours) }
                }
            } label: {
                Label("\(lifetimeHours) ч", systemImage: "clock")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 44)
                    .modifier(AloChatGlass(interactive: false, role: .chrome))
            }
            .accessibilityLabel("История исчезнет через \(lifetimeHours) часов")
            .accessibilityIdentifier("alo.story.lifetime")
            PhotosPicker(selection: $pickedItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]),
                         preferredItemEncoding: .compatible) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 19)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .modifier(AloChatGlass(interactive: false, role: .chrome))
            }
            .buttonStyle(AloControlPressStyle())
            .disabled(app.isCreatingStory)
            .accessibilityLabel("Медиа")
            .accessibilityIdentifier("alo.story.gallery")
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { isCameraPresented = true } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 19)).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .modifier(AloChatGlass(interactive: false, role: .chrome))
                }
                .buttonStyle(AloControlPressStyle())
                .disabled(app.isCreatingStory)
                .accessibilityLabel("Снять на камеру")
            }
            Spacer(minLength: 0)
            Button {
                publish(canvasSize: canvasSize)
            } label: {
                Group {
                    if app.isCreatingStory || isPreparing {
                        ProgressView().tint(.white)
                    } else {
                        Text("Опубликовать").font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundStyle(isPublishDisabled ? AloTheme.muted : .white)
                .padding(.horizontal, 18).frame(height: 44)
                .background(isPublishDisabled ? AloTheme.surfaceRaised : AloTheme.accent, in: Capsule())
            }
            .buttonStyle(AloControlPressStyle())
            .disabled(isPublishDisabled || app.isCreatingStory)
            .accessibilityIdentifier("alo.story.publish")
        }
        .padding(.horizontal, 12)
    }

    // MARK: Publishing

    /// Flattens every page that has drawing, stickers or styled text into a picture, then publishes.
    private func publish(canvasSize: CGSize) {
        if mode == .text { commitText() }
        publishRequested = true
        isTextFocused = false
        selectedStickerID = nil
        mode = .none
        isPreparing = true
        Task { @MainActor in
            defer { isPreparing = false }
            var media: [AloLocalAttachment] = []
            var body = text
            if attachments.isEmpty {
                // A text story is its picture: the text is drawn on the gradient, not repeated below.
                guard let rendered = await render(background: nil, pageID: Self.textPageID, canvasSize: canvasSize) else { return }
                media = [rendered]
                body = ""
            } else {
                for attachment in attachments {
                    let pageEdits = edits[attachment.id] ?? AloStoryPageEdits()
                    if attachment.type == "video", !pageEdits.isEmpty {
                        guard let composed = await composeVideo(attachment, canvasSize: canvasSize) else { return }
                        media.append(composed)
                        continue
                    }
                    if attachment.type == "image", !pageEdits.isEmpty,
                       let image = try? await AloImageCache.draftImage(attachment, maxPixelSize: 2_048),
                       let rendered = await render(background: image, pageID: attachment.id, canvasSize: canvasSize) {
                        media.append(rendered)
                    } else {
                        media.append(attachment)
                    }
                }
            }
            app.createStory(body: body, localAttachments: media, lifetimeHours: lifetimeHours)
            AloHaptics.impact(.light)
        }
    }

    /// Burns the page's drawing and stickers into its video as a 720 × 1280 story.
    private func composeVideo(_ attachment: AloLocalAttachment, canvasSize: CGSize) async -> AloLocalAttachment? {
        let pageEdits = edits[attachment.id] ?? AloStoryPageEdits()
        let renderSize = CGSize(width: 720, height: 1_280)
        let scale = renderSize.width / canvasSize.width
        let drawingImage = pageEdits.drawing.strokes.isEmpty ? nil
            : pageEdits.drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: scale)
        let overlayView = AloStoryRenderedPage(background: nil, gradient: [], drawing: drawingImage,
                                               stickers: pageEdits.stickers, size: canvasSize, transparent: true)
        let renderer = ImageRenderer(content: overlayView)
        renderer.scale = scale
        renderer.isOpaque = false
        guard let overlay = renderer.cgImage else {
            importError = "Не удалось подготовить видео."
            return nil
        }
        do {
            let source = try AloStoryVideoComposer.plaintextCopy(of: attachment)
            defer { try? FileManager.default.removeItem(at: source) }
            let composed = try await AloStoryVideoComposer.compose(videoAt: source, overlay: overlay, renderSize: renderSize)
            defer { try? FileManager.default.removeItem(at: composed) }
            return try await AloFeedMediaImport.prepare(source: composed, video: true)
        } catch {
            importError = "Не удалось подготовить видео: \(error.localizedDescription)"
            return nil
        }
    }

    private func render(background: UIImage?, pageID: UUID, canvasSize: CGSize) async -> AloLocalAttachment? {
        let pageEdits = edits[pageID] ?? AloStoryPageEdits()
        let scale = 1_080 / canvasSize.width
        let drawingImage = pageEdits.drawing.strokes.isEmpty ? nil
            : pageEdits.drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: scale)
        let content = AloStoryRenderedPage(background: background, gradient: AloStoryTextStyle.gradients[textStyle.gradientIndex],
                                           drawing: drawingImage, stickers: pageEdits.stickers, size: canvasSize)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.uiImage, let jpeg = image.jpegData(compressionQuality: 0.9) else {
            importError = "Не удалось подготовить историю."
            return nil
        }
        return AloLocalAttachment(data: jpeg, mime: "image/jpeg", type: "image", name: "story.jpg",
                                  mediaDimensions: AloMediaDimensions(width: 1_080, height: 1_920))
    }

    private func removeCurrent() {
        guard attachments.indices.contains(page) else { return }
        let attachment = attachments.remove(at: page)
        edits[attachment.id] = nil
        AloDraftAttachmentStore.discard(attachment)
        page = max(0, min(page, attachments.count - 1))
    }

    /// When the first photo or video arrives, what was typed, placed or drawn on the text story
    /// moves onto it instead of being lost with the gradient.
    private func adoptTextPage(into id: UUID) {
        if mode == .text { commitText() }
        if mode == .sticker { deselect() }
        if let carried = edits.removeValue(forKey: Self.textPageID), !carried.isEmpty {
            edits[id] = carried
        }
    }

    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        do {
            let next = try await AloFeedMediaImport.load(items)
            attachments.forEach(AloDraftAttachmentStore.discard)
            attachments = next
            edits = edits.filter { $0.key == Self.textPageID }
            page = 0
            if let first = next.first { adoptTextPage(into: first.id) }
        } catch {
            guard !Task.isCancelled else { return }
            importError = error.localizedDescription
        }
        isImporting = false
    }
}

/// The flattened page: background, drawing and items at the canvas's own coordinates.
struct AloStoryRenderedPage: View {
    let background: UIImage?
    let gradient: [Color]
    let drawing: UIImage?
    let stickers: [AloStorySticker]
    let size: CGSize
    /// Only the drawing and items, on transparency: the overlay laid over a video.
    var transparent = false

    var body: some View {
        ZStack {
            if let background {
                Image(uiImage: background).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
            } else if !transparent {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if let drawing {
                Image(uiImage: drawing).resizable().frame(width: size.width, height: size.height)
            }
            ForEach(stickers) { sticker in
                AloStoryStickerContent(sticker: sticker, canvasWidth: size.width)
                    .rotationEffect(sticker.rotation)
                    .position(x: sticker.position.x * size.width, y: sticker.position.y * size.height)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// How an item looks, shared by the editor and the flattened page so both match exactly.
/// The size goes into the font rather than a scale transform, so stretched text stays sharp.
struct AloStoryStickerContent: View {
    static let emojiSize: CGFloat = 72
    static let textSize: CGFloat = 28
    /// Text wraps at this share of the page width (times the item's size), so stretching keeps its lines.
    static let textWrap: CGFloat = 0.78
    let sticker: AloStorySticker
    let canvasWidth: CGFloat
    var scale: CGFloat?

    var body: some View {
        let scale = self.scale ?? sticker.scale
        switch sticker.content {
        case .emoji(let emoji):
            Text(emoji).font(.system(size: Self.emojiSize * scale))
        case .text(let string, let style):
            AloStoryTextWrap(width: canvasWidth * Self.textWrap * scale) {
                Text(string)
                    .font(style.font(size: Self.textSize * scale))
                    .foregroundStyle(style.textColor)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, style.plateColor == nil ? 0 : 14 * scale)
            .padding(.vertical, style.plateColor == nil ? 0 : 8 * scale)
            .background(style.plateColor ?? .clear, in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
        }
    }
}

/// Lays text out at a given wrapping width but takes only the width its longest line needs.
private struct AloStoryTextWrap: Layout {
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(width: width, height: nil))
    }
}

/// One item on the page, as in Instagram: drag to move, pinch or pull a corner to stretch, twist to
/// rotate. A tap selects it (a square dashed frame with corner handles); a second tap edits text.
/// Dropped on the trash, it is removed.
private struct AloStoryStickerView: View {
    let sticker: AloStorySticker
    let canvasSize: CGSize
    let isSelected: Bool
    let onTap: () -> Void
    let onDragChanged: (CGPoint) -> Void
    /// The updated item and, for a move, where it was dropped (nil after a resize or rotation).
    let onCommit: (AloStorySticker, CGPoint?) -> Void
    @State private var offset: CGSize = .zero
    @State private var pinch: CGFloat = 1
    @State private var twist: Angle = .zero
    @State private var size: CGSize = .zero
    /// The item's size when a handle was grabbed; the stretch is measured against it.
    @State private var stretchBase: CGSize?

    var body: some View {
        let origin = CGPoint(x: sticker.position.x * canvasSize.width, y: sticker.position.y * canvasSize.height)
        AloStoryStickerContent(sticker: sticker, canvasWidth: canvasSize.width,
                               scale: AloStorySticker.clamped(sticker.scale * pinch))
            .padding(10)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .overlay {
                if isSelected { selectionFrame() }
            }
            .rotationEffect(sticker.rotation + twist)
            .position(x: origin.x + offset.width, y: origin.y + offset.height)
            // The tap goes first, so a quick touch selects instead of starting a move.
            .gesture(TapGesture().onEnded(onTap).exclusively(before:
                DragGesture()
                    .onChanged { value in
                        offset = value.translation
                        onDragChanged(CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height))
                    }
                    .onEnded { value in
                        let location = CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height)
                        var updated = sticker
                        updated.position = CGPoint(x: min(1, max(0, location.x / canvasSize.width)),
                                                   y: min(1, max(0, location.y / canvasSize.height)))
                        offset = .zero
                        onCommit(updated, location)
                    }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { pinch = $0.magnification }
                        .onEnded { value in
                            var updated = sticker
                            updated.scale = AloStorySticker.clamped(sticker.scale * value.magnification)
                            pinch = 1
                            onCommit(updated, nil)
                        })
                    .simultaneously(with: RotateGesture()
                        .onChanged { twist = $0.rotation }
                        .onEnded { value in
                            var updated = sticker
                            updated.rotation = sticker.rotation + value.rotation
                            twist = .zero
                            onCommit(updated, nil)
                        })
            ))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sticker.accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Смахните вверх или вниз, чтобы изменить размер")
            .accessibilityAdjustableAction { direction in
                var updated = sticker
                switch direction {
                case .increment: updated.scale = AloStorySticker.clamped(sticker.scale * 1.15)
                case .decrement: updated.scale = AloStorySticker.clamped(sticker.scale / 1.15)
                @unknown default: return
                }
                onCommit(updated, nil)
            }
            .accessibilityIdentifier(sticker.isText ? "alo.story.text-item" : "alo.story.sticker")
    }

    private func selectionFrame() -> some View {
        Rectangle()
            .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .overlay(alignment: .topLeading) { handle(x: -1, y: -1) }
            .overlay(alignment: .topTrailing) { handle(x: 1, y: -1) }
            .overlay(alignment: .bottomLeading) { handle(x: -1, y: 1) }
            .overlay(alignment: .bottomTrailing) { handle(x: 1, y: 1) }
    }

    /// A corner knob: pulling it away from the centre stretches the item, pushing it in shrinks it.
    /// Measured from the finger's travel, which no transform of the growing item can disturb.
    private func handle(x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
            .offset(x: x * 20, y: y * 20)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    if stretchBase == nil { stretchBase = size }
                    pinch = stretch(drag.translation, x: x, y: y)
                }
                .onEnded { drag in
                    var updated = sticker
                    updated.scale = AloStorySticker.clamped(sticker.scale * stretch(drag.translation, x: x, y: y))
                    pinch = 1
                    stretchBase = nil
                    onCommit(updated, nil)
                })
            .accessibilityHidden(true)
    }

    /// The corner's distance from the centre after the drag, over its distance before.
    private func stretch(_ translation: CGSize, x: CGFloat, y: CGFloat) -> CGFloat {
        let base = stretchBase ?? size
        let angle = CGFloat(sticker.rotation.radians)
        let cx = x * base.width / 2, cy = y * base.height / 2
        // The corner as it sits on screen, turned with the item.
        let corner = CGPoint(x: cx * cos(angle) - cy * sin(angle), y: cx * sin(angle) + cy * cos(angle))
        let start = hypot(corner.x, corner.y)
        guard start > 4 else { return 1 }
        return hypot(corner.x + translation.width, corner.y + translation.height) / start
    }
}

/// PencilKit drawing that fills the canvas; the system tool palette shows while drawing.
private struct AloStoryDrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let view = PKCanvasView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.drawingPolicy = .anyInput
        view.tool = PKInkingTool(.pen, color: .white, width: 8)
        view.drawing = drawing
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if view.drawing != drawing { view.drawing = drawing }
        let picker = context.coordinator.picker
        if isActive {
            picker.addObserver(view)
            picker.setVisible(true, forFirstResponder: view)
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if view.isFirstResponder {
            picker.setVisible(false, forFirstResponder: view)
            view.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: AloStoryDrawingCanvas
        let picker = PKToolPicker()

        init(_ parent: AloStoryDrawingCanvas) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if parent.drawing != canvasView.drawing { parent.drawing = canvasView.drawing }
        }
    }
}

/// A curated emoji set; tapping one places it in the middle of the page.
private struct AloStoryStickerPicker: View {
    let onPick: (String) -> Void
    private let emoji = ["😀", "😂", "🥰", "😍", "😎", "🤩", "🥳", "😴", "🤔", "😮", "😢", "😡",
                         "👍", "👏", "🙌", "🙏", "💪", "✌️", "🤝", "👀", "❤️", "🧡", "💛", "💚",
                         "💙", "💜", "🔥", "✨", "⭐️", "🌈", "☀️", "🌙", "⚡️", "❄️", "🎉", "🎂",
                         "🎁", "🎈", "🎵", "📸", "☕️", "🍕", "🍔", "🍦", "🌸", "🌿", "🐶", "🐱"]

    var body: some View {
        VStack(spacing: 12) {
            Text("Стикеры").font(.system(size: 17, weight: .semibold)).foregroundStyle(AloTheme.text)
                .padding(.top, 18)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(emoji, id: \.self) { item in
                        Button { onPick(item) } label: {
                            Text(item).font(.system(size: 38)).frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(AloControlPressStyle())
                        .accessibilityLabel(item)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .background(AloTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("alo.story.sticker-picker")
    }
}

/// The system camera for a story: one photo or a short video.
private struct AloStoryCamera: UIViewControllerRepresentable {
    let onFinish: (URL?, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.videoMaximumDuration = 60
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (URL?, Bool) -> Void
        init(onFinish: @escaping (URL?, Bool) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let movie = info[.mediaURL] as? URL {
                onFinish(movie, true)
            } else if let image = info[.originalImage] as? UIImage, let jpeg = image.jpegData(compressionQuality: 0.92) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("alo-story-\(UUID().uuidString).jpg")
                onFinish((try? jpeg.write(to: url)) != nil ? url : nil, false)
            } else {
                onFinish(nil, false)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil, false) }
    }
}

/// A video page in the editor plays silently on a loop under the drawing; its first frame shows
/// until the player has one.
private struct AloStoryLoopingVideo: View {
    let attachment: AloLocalAttachment
    let isActive: Bool
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?

    var body: some View {
        ZStack {
            FeedAttachmentPreview(attachment: attachment, side: nil, maxPixelSize: 1_440, showsPlayBadge: false)
            if looper != nil {
                AloPlayerLayerView(player: player) { layer in
                    layer.videoGravity = .resizeAspectFill
                    layer.backgroundColor = UIColor.clear.cgColor
                }
            }
        }
        .task(id: isActive) {
            guard isActive, let url = attachment.localPlaybackURL else {
                player.pause()
                return
            }
            if looper == nil {
                player.isMuted = true
                looper = AVPlayerLooper(player: player,
                                        templateItem: AVPlayerItem(asset: AloSecureMediaStore.shared.makeAsset(url: url)))
            }
            player.play()
        }
        .onDisappear { player.pause() }
        .accessibilityHidden(true)
    }
}

/// Video work for stories: a protected plaintext copy of an encrypted draft, a poster frame, and
/// the overlay burned in over an aspect-filled 9:16 frame (what the editor showed).
enum AloStoryVideoComposer {
    enum Failure: LocalizedError {
        case noVideoTrack, exportFailed
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "в файле нет видео"
            case .exportFailed: return "экспорт не удался"
            }
        }
    }

    /// Decrypts a draft to a temporary file protected until first unlock. The caller deletes it.
    static func plaintextCopy(of attachment: AloLocalAttachment) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alo-story-\(UUID().uuidString).mp4")
        let data: Data
        if let playback = attachment.localPlaybackURL {
            data = try AloSecureMediaStore.shared.payload(for: playback).data
        } else {
            data = attachment.data
        }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    /// Read through the secure resource loader, so no plaintext copy touches the disk.
    static func posterFrame(of attachment: AloLocalAttachment, maxPixelSize: CGFloat) async -> UIImage? {
        guard let playback = attachment.localPlaybackURL else { return nil }
        let generator = AVAssetImageGenerator(asset: AloSecureMediaStore.shared.makeAsset(url: playback))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard let image = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: image)
    }

    /// Core Image per-frame composition: unlike `AVVideoCompositionCoreAnimationTool` it also renders
    /// in the Simulator, and the export session carries the audio over by itself.
    static func compose(videoAt source: URL, overlay: CGImage, renderSize: CGSize) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw Failure.noVideoTrack }
        let frame = CGRect(origin: .zero, size: renderSize)
        // CIImage(cgImage:) keeps the picture upright in Core Image's bottom-left space, so the
        // overlay's top-left corner lands on the frame's top-left corner.
        let overlayImage = CIImage(cgImage: overlay).transformed(by: CGAffineTransform(
            scaleX: renderSize.width / CGFloat(overlay.width), y: renderSize.height / CGFloat(overlay.height)))
        let videoComposition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            // The source frame arrives upright (the track's preferred transform already applied).
            let source = request.sourceImage
            let extent = source.extent
            let scale = max(renderSize.width / extent.width, renderSize.height / extent.height)
            let filled = source
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (renderSize.width - extent.width * scale) / 2,
                                                   y: (renderSize.height - extent.height * scale) / 2))
            request.finish(with: overlayImage.composited(over: filled).cropped(to: frame), context: nil)
        }
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("alo-story-composed-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed
        }
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true
        do {
            try await session.export(to: output, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }
}
