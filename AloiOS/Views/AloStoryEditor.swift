import PencilKit
import PhotosUI
import SwiftUI
import UIKit

/// An emoji placed on a story page. Position is relative (0…1) so it survives any canvas size.
struct AloStorySticker: Identifiable, Equatable {
    let id = UUID()
    var emoji: String
    var position = CGPoint(x: 0.5, y: 0.45)
    var scale: CGFloat = 1
    var rotation: Angle = .zero
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
    @State private var lifetimeHours = 24
    @State private var publishRequested = false
    @State private var isPreparing = false
    @State private var isImporting = false
    @State private var importError = ""
    @State private var importTask: Task<Void, Never>?
    private var accessibility = AloVisualAccessibility()

    enum Mode: Equatable { case none, draw, text }

    /// The id the text story's edits are kept under (it has no attachment).
    private static let textPageID = UUID()

    private var currentAttachment: AloLocalAttachment? {
        attachments.indices.contains(page) ? attachments[page] : nil
    }
    private var currentPageID: UUID { currentAttachment?.id ?? Self.textPageID }
    private var currentIsVideo: Bool { currentAttachment?.type == "video" }
    private var isPublishDisabled: Bool {
        isImporting || isPreparing
            || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
                && (edits[Self.textPageID]?.isEmpty ?? true))
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { isTextFocused = true }
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
                edits[currentPageID, default: AloStoryPageEdits()].stickers.append(AloStorySticker(emoji: emoji))
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
                textStoryField
            } else {
                TabView(selection: $page) {
                    ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                        FeedAttachmentPreview(attachment: attachment, side: nil, maxPixelSize: 1_440)
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

            stickerLayer(size: size)
                .allowsHitTesting(mode == .none)

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
                        .accessibilityIdentifier("alo.story.text")
                }
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

    private var textStoryField: some View {
        TextField("", text: $text, prompt: Text("Что происходит?").foregroundStyle(textStyle.textColor.opacity(0.6)),
                  axis: .vertical)
            .font(textStyle.font(size: 28))
            .foregroundStyle(textStyle.textColor)
            .multilineTextAlignment(.center)
            .lineLimit(1...8)
            .focused($isTextFocused)
            .padding(.horizontal, textStyle.plateColor == nil ? 0 : 14)
            .padding(.vertical, textStyle.plateColor == nil ? 0 : 8)
            .background(textStyle.plateColor ?? .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 28)
            .disabled(app.isCreatingStory || mode == .draw)
            .onTapGesture { mode = .text; isTextFocused = true }
            .accessibilityLabel("Текст истории")
            .accessibilityIdentifier("alo.story.text")
    }

    private func stickerLayer(size: CGSize) -> some View {
        ZStack {
            ForEach(edits[currentPageID]?.stickers ?? []) { sticker in
                AloStoryStickerView(sticker: sticker, canvasSize: size,
                    onDragChanged: { location in
                        isDraggingSticker = true
                        draggingStickerOverTrash = location.y > size.height - 90 && abs(location.x - size.width / 2) < 60
                    },
                    onCommit: { updated, location in
                        isDraggingSticker = false
                        let overTrash = location.y > size.height - 90 && abs(location.x - size.width / 2) < 60
                        draggingStickerOverTrash = false
                        guard var pageEdits = edits[currentPageID],
                              let index = pageEdits.stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
                        if overTrash {
                            pageEdits.stickers.remove(at: index)
                            AloHaptics.impact(.medium)
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
                if mode == .none {
                    AloChatCircleButton(systemImage: "xmark", label: "Закрыть редактор истории") { dismiss() }
                        .disabled(app.isCreatingStory)
                    Spacer()
                    if !currentIsVideo {
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
                    }
                    if attachments.isEmpty {
                        AloChatCircleButton(systemImage: "textformat", label: "Стиль текста") {
                            mode = .text
                            isTextFocused = true
                        }
                        .accessibilityIdentifier("alo.story.text-style")
                    } else {
                        AloChatCircleButton(systemImage: "trash", label: "Убрать это медиа") { removeCurrent() }
                            .disabled(app.isCreatingStory)
                    }
                } else {
                    if mode == .draw {
                        AloChatCircleButton(systemImage: "arrow.uturn.backward", label: "Отменить штрих") {
                            var drawing = edits[currentPageID]?.drawing ?? PKDrawing()
                            guard !drawing.strokes.isEmpty else { return }
                            drawing.strokes.removeLast()
                            edits[currentPageID, default: AloStoryPageEdits()].drawing = drawing
                        }
                        .accessibilityIdentifier("alo.story.undo")
                    }
                    Spacer()
                    Button {
                        isTextFocused = false
                        mode = .none
                    } label: {
                        Text("Готово").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 40)
                            .background(AloTheme.accent, in: Capsule())
                    }
                    .buttonStyle(AloControlPressStyle())
                    .accessibilityIdentifier("alo.story.tool-done")
                }
            }
            .padding(10)
            if mode == .text {
                textStyleBar
            }
            Spacer()
        }
    }

    /// Typeface, plate and colour for the text story, and its background gradient.
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
                styleButton(systemImage: "paintpalette", label: "Фон") {
                    textStyle.gradientIndex = (textStyle.gradientIndex + 1) % AloStoryTextStyle.gradients.count
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
        publishRequested = true
        isTextFocused = false
        mode = .none
        isPreparing = true
        Task { @MainActor in
            defer { isPreparing = false }
            var media: [AloLocalAttachment] = []
            var body = text
            if attachments.isEmpty {
                // A text story is its picture: the text is drawn on the gradient, not repeated below.
                guard let rendered = await render(background: nil, pageID: Self.textPageID, canvasSize: canvasSize,
                                                  includeText: true) else { return }
                media = [rendered]
                body = ""
            } else {
                for attachment in attachments {
                    let pageEdits = edits[attachment.id] ?? AloStoryPageEdits()
                    if attachment.type == "image", !pageEdits.isEmpty,
                       let image = try? await AloImageCache.draftImage(attachment, maxPixelSize: 2_048),
                       let rendered = await render(background: image, pageID: attachment.id, canvasSize: canvasSize,
                                                   includeText: false) {
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

    private func render(background: UIImage?, pageID: UUID, canvasSize: CGSize, includeText: Bool) async -> AloLocalAttachment? {
        let pageEdits = edits[pageID] ?? AloStoryPageEdits()
        let scale = 1_080 / canvasSize.width
        let drawingImage = pageEdits.drawing.strokes.isEmpty ? nil
            : pageEdits.drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: scale)
        let content = AloStoryRenderedPage(background: background, gradient: AloStoryTextStyle.gradients[textStyle.gradientIndex],
                                           text: includeText ? text : "", textStyle: textStyle,
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

    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        do {
            let next = try await AloFeedMediaImport.load(items)
            attachments.forEach(AloDraftAttachmentStore.discard)
            attachments = next
            edits = edits.filter { $0.key == Self.textPageID }
            page = 0
        } catch {
            guard !Task.isCancelled else { return }
            importError = error.localizedDescription
        }
        isImporting = false
    }
}

/// The flattened page: background, text, drawing and stickers at the canvas's own coordinates.
private struct AloStoryRenderedPage: View {
    let background: UIImage?
    let gradient: [Color]
    let text: String
    let textStyle: AloStoryTextStyle
    let drawing: UIImage?
    let stickers: [AloStorySticker]
    let size: CGSize

    var body: some View {
        ZStack {
            if let background {
                Image(uiImage: background).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
            } else {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if !text.isEmpty {
                Text(text)
                    .font(textStyle.font(size: 28))
                    .foregroundStyle(textStyle.textColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, textStyle.plateColor == nil ? 0 : 14)
                    .padding(.vertical, textStyle.plateColor == nil ? 0 : 8)
                    .background(textStyle.plateColor ?? .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 28)
            }
            if let drawing {
                Image(uiImage: drawing).resizable().frame(width: size.width, height: size.height)
            }
            ForEach(stickers) { sticker in
                Text(sticker.emoji)
                    .font(.system(size: AloStoryStickerView.baseSize))
                    .scaleEffect(sticker.scale)
                    .rotationEffect(sticker.rotation)
                    .position(x: sticker.position.x * size.width, y: sticker.position.y * size.height)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// One sticker: drag to move, pinch to resize, twist to rotate. Dropped on the trash, it is removed.
private struct AloStoryStickerView: View {
    static let baseSize: CGFloat = 72
    let sticker: AloStorySticker
    let canvasSize: CGSize
    let onDragChanged: (CGPoint) -> Void
    let onCommit: (AloStorySticker, CGPoint) -> Void
    @State private var offset: CGSize = .zero
    @State private var pinch: CGFloat = 1
    @State private var twist: Angle = .zero

    var body: some View {
        let origin = CGPoint(x: sticker.position.x * canvasSize.width, y: sticker.position.y * canvasSize.height)
        Text(sticker.emoji)
            .font(.system(size: Self.baseSize))
            .scaleEffect(sticker.scale * pinch)
            .rotationEffect(sticker.rotation + twist)
            .position(x: origin.x + offset.width, y: origin.y + offset.height)
            .gesture(
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
                            updated.scale = min(4, max(0.4, sticker.scale * value.magnification))
                            pinch = 1
                            onCommit(updated, origin)
                        })
                    .simultaneously(with: RotateGesture()
                        .onChanged { twist = $0.rotation }
                        .onEnded { value in
                            var updated = sticker
                            updated.rotation = sticker.rotation + value.rotation
                            twist = .zero
                            onCommit(updated, origin)
                        })
            )
            .accessibilityLabel("Стикер \(sticker.emoji)")
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
