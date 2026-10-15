import PhotosUI
import SwiftUI

/// A profile banner: the person's own photo, or one of the server's ten gradients.
enum AloProfileBanner {
    /// Width over height, as the banner sits on the profile (full width, 154 pt tall).
    static let aspect: CGFloat = 2.4
    static let height: CGFloat = 154
    /// The server's PROFILE_COVER_STYLES, in the order they are offered.
    static let styles = ["default", "azure", "ocean", "violet", "rose", "sunset", "amber", "emerald", "forest", "graphite"]

    static func title(_ style: String) -> String {
        switch style {
        case "azure": return "Лазурь"
        case "ocean": return "Океан"
        case "violet": return "Фиалка"
        case "rose": return "Роза"
        case "sunset": return "Закат"
        case "amber": return "Янтарь"
        case "emerald": return "Изумруд"
        case "forest": return "Лес"
        case "graphite": return "Графит"
        default: return "Ало"
        }
    }
}

/// The banner surface: a photo filling the frame (with the gradient underneath while it loads),
/// or just the gradient.
struct AloProfileBannerSurface: View {
    @Environment(\.aloAPIClient) private var api
    let style: String
    var imageURL: String = ""
    /// A photo just cropped in the editor, before it is uploaded.
    var pendingImage: UIImage?
    var cornerRadius: CGFloat = AloTheme.radiusLarge

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(aloProfileGradient(style))
            if let pendingImage {
                Image(uiImage: pendingImage).resizable().scaledToFill()
            } else if !imageURL.isEmpty, let url = api?.absoluteURL(imageURL) {
                AloAsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        // Something must be on screen for the image's loading task to run;
                        // the gradient shows through meanwhile.
                        Color.clear
                    }
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.06), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// What happens to the banner photo on save.
enum AloBannerPhotoChange: Equatable {
    case keep
    case remove
    case replace(Data)
}

/// "Оформление профиля": a live preview of the profile header, then either one of ten colours
/// or your own photo, cropped to the banner's shape. Nothing changes until "Готово".
struct AloProfileBannerEditor: View {
    @Environment(\.dismiss) private var dismiss
    let user: AloCurrentUser
    let onSave: (_ style: String, _ photo: AloBannerPhotoChange) -> Void

    private enum Tab: Hashable { case color, photo }

    @State private var tab: Tab
    @State private var style: String
    @State private var keepsCurrentPhoto: Bool
    @State private var pendingJPEG: Data?
    @State private var pendingImage: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPickerPresented = false
    @State private var crop: AloAvatarCropRequest?
    @State private var errorText = ""

    init(user: AloCurrentUser, onSave: @escaping (_ style: String, _ photo: AloBannerPhotoChange) -> Void) {
        self.user = user
        self.onSave = onSave
        let style = AloProfileBanner.styles.contains(user.coverStyle) ? user.coverStyle : "default"
        _style = State(initialValue: style)
        _keepsCurrentPhoto = State(initialValue: !user.coverImageUrl.isEmpty)
        _tab = State(initialValue: user.coverImageUrl.isEmpty ? .color : .photo)
    }

    private var hasPhoto: Bool { pendingImage != nil || keepsCurrentPhoto }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    Picker("Обложка", selection: $tab) {
                        Text("Цвет").tag(Tab.color)
                        Text("Фото").tag(Tab.photo)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("alo.banner.tab")
                    if tab == .color { colorGrid } else { photoControls }
                    if !errorText.isEmpty {
                        Text(errorText).font(.system(size: 14)).foregroundStyle(AloTheme.destructive)
                    }
                }
                .padding(.horizontal, AloSocialMetrics.inset)
                .padding(.bottom, 32)
            }
        }
        .background(AloTheme.background.ignoresSafeArea())
        .photosPicker(isPresented: $isPickerPresented, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                pickerItem = nil
                guard let data, let image = await AloAvatarImage.decoded(from: data, maxSide: 3000) else {
                    errorText = "Не удалось открыть это фото. Выберите другое."
                    return
                }
                errorText = ""
                crop = AloAvatarCropRequest(image: image)
            }
        }
        .fullScreenCover(item: $crop) { request in
            AloAvatarCropView(image: request.image, shape: .banner(aspect: AloProfileBanner.aspect),
                              onCancel: { crop = nil }) { jpeg in
                crop = nil
                pendingJPEG = jpeg
                pendingImage = UIImage(data: jpeg)
                tab = .photo
            }
        }
        // A container, so its own identifier does not replace its buttons' identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.banner.editor")
    }

    private var header: some View {
        HStack(spacing: 12) {
            AloChatCircleButton(systemImage: "xmark", label: "Закрыть") { dismiss() }
            Text("Оформление профиля")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(AloTheme.text)
                .frame(maxWidth: .infinity)
            Button(action: save) {
                Text("Готово").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 40)
                    .background(AloTheme.accent, in: Capsule())
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityIdentifier("alo.banner.save")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The header exactly as others will see it: banner, avatar over its edge, name.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            AloProfileBannerSurface(style: style,
                                    imageURL: keepsCurrentPhoto && pendingImage == nil ? user.coverImageUrl : "",
                                    pendingImage: pendingImage)
                .frame(height: AloProfileBanner.height)
            HStack(alignment: .top, spacing: 10) {
                AloAvatar(name: user.name, url: user.avatarUrl, size: 84, colorSeed: String(user.id))
                    .overlay(Circle().stroke(AloTheme.background, lineWidth: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(AloTheme.text)
                        .lineLimit(1)
                    Text(user.username.withAtPrefix).font(.subheadline.weight(.semibold)).foregroundStyle(AloTheme.muted)
                }
                .padding(.top, 46)
            }
            .padding(.leading, 18)
            .padding(.top, -42)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasPhoto ? "Предпросмотр: обложка с фото" : "Предпросмотр: обложка «\(AloProfileBanner.title(style))»")
        .accessibilityIdentifier("alo.banner.preview")
    }

    private var colorGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasPhoto ? "Цвет заменит фото на обложке" : "Цвет обложки")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(AloTheme.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                ForEach(AloProfileBanner.styles, id: \.self) { item in
                    let chosen = item == style && !hasPhoto
                    Button {
                        style = item
                        // Picking a colour makes it the banner: the photo goes.
                        pendingImage = nil
                        pendingJPEG = nil
                        keepsCurrentPhoto = false
                    } label: {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(aloProfileGradient(item))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if chosen {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(chosen ? Color.white : Color.white.opacity(0.08), lineWidth: chosen ? 2.5 : 1))
                    }
                    .buttonStyle(AloControlPressStyle())
                    .accessibilityLabel(AloProfileBanner.title(item))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityIdentifier("alo.banner.style.\(item)")
                }
            }
        }
    }

    private var photoControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasPhoto {
                Button { isPickerPresented = true } label: {
                    Label("Выбрать другое фото", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(AloControlPressStyle())
                .foregroundStyle(AloTheme.text)
                .background(AloTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityIdentifier("alo.banner.pick")
                Button(role: .destructive) {
                    pendingImage = nil
                    pendingJPEG = nil
                    keepsCurrentPhoto = false
                    tab = .color
                } label: {
                    Label("Убрать фото", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(AloControlPressStyle())
                .foregroundStyle(AloTheme.destructive)
                .background(AloTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityIdentifier("alo.banner.remove-photo")
            } else {
                Button { isPickerPresented = true } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 30, weight: .regular))
                        Text("Выбрать фото").font(.system(size: 16, weight: .semibold))
                        Text("Потом его можно подвинуть и приблизить").font(.system(size: 13))
                            .foregroundStyle(AloTheme.muted)
                    }
                    .foregroundStyle(AloTheme.text)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(AloTheme.surfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AloTheme.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(AloControlPressStyle())
                .accessibilityIdentifier("alo.banner.pick")
            }
        }
    }

    private func save() {
        let change: AloBannerPhotoChange
        if let pendingJPEG {
            change = .replace(pendingJPEG)
        } else if keepsCurrentPhoto {
            change = .keep
        } else {
            change = user.coverImageUrl.isEmpty ? .keep : .remove
        }
        onSave(style, change)
        dismiss()
    }
}
