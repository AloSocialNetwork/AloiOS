import SwiftUI

struct AloDataStorageSettings: View {
    @State private var settings = AloMediaCacheSettings.current
    @State private var usage = AloMediaDiskCache.Usage()
    @State private var isCleaning = false
    @State private var confirmsCleaning = false
    @State private var refresh = 0
    @State private var cacheNotice = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Использование памяти") {
                valueRow("Скачанные медиа", value: ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("alo.storage.usage")
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Максимальный размер").font(.subheadline).foregroundStyle(AloTheme.muted)
                    Picker("Максимальный размер", selection: $settings.maximumBytes) {
                        ForEach(AloMediaCacheSettings.sizeChoicesGB, id: \.self) { gb in
                            Text("\(gb) ГБ").tag(Int64(gb) * 1_024 * 1_024 * 1_024)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("alo.storage.limit")
                }
                .padding(.vertical, 8)
                Divider()
                Button(role: .destructive) { confirmsCleaning = true } label: {
                    HStack {
                        Text("Очистить кеш медиа")
                        Spacer()
                        if isCleaning { ProgressView() }
                    }.frame(minHeight: 44).contentShape(Rectangle()).multilineTextAlignment(.leading)
                }
                .foregroundStyle(.red)
                .disabled(isCleaning || usage.count == 0)
                .accessibilityIdentifier("alo.storage.clear")
            }
            if !cacheNotice.isEmpty { Text(cacheNotice).font(.footnote).foregroundStyle(AloTheme.muted) }
            Text("При заполнении лимита удаляются давно неиспользуемые файлы. Сообщения, ключи, черновики и неотправленные вложения не удаляются. Медиа можно скачать снова.")
                .font(.footnote).foregroundStyle(AloTheme.muted)

            section("Автозагрузка медиа") {
                presetPicker("Через Wi‑Fi", selection: $settings.wifi)
                Divider()
                presetPicker("Через мобильную сеть", selection: $settings.cellular)
            }
            Text("Загружается только медиа у видимых сообщений, с учётом размера. Большие и неизвестные по размеру файлы — по нажатию. Экономия данных отключает автозагрузку; уже скачанное доступно без сети.")
                .font(.footnote).foregroundStyle(AloTheme.muted)
            section("Автоудаление из кеша") {
                valueRow("Личные чаты", value: "По лимиту места").frame(minHeight: 44)
                Divider()
                valueRow("Группы", value: "Через 1 месяц").frame(minHeight: 44)
                Divider()
                valueRow("Каналы", value: "Через 1 неделю").frame(minHeight: 44)
                Divider()
                valueRow("Аватары и изображения", value: "Через 1 неделю").frame(minHeight: 44)
            }
            Text("Срок отсчитывается от последнего использования. Открытые плеером файлы защищены от очистки.")
                .font(.footnote).foregroundStyle(AloTheme.muted)
        }
        .font(.body)
        .tint(AloTheme.accent)
        .onChange(of: settings) { _, value in value.save(); refresh += 1 }
        .task(id: refresh) {
            usage = await AloMediaDiskCache.shared.clean(settings: settings)
        }
        .confirmationDialog("Очистить скачанные медиа?", isPresented: $confirmsCleaning, titleVisibility: .visible) {
            Button("Очистить кеш", role: .destructive) {
                isCleaning = true
                Task {
                    usage = await AloMediaDiskCache.shared.clean(settings: settings, all: true)
                    AloImageCache.removeAll()
                    await AloMediaPreviewCache.shared.removeAll()
                    cacheNotice = usage.count == 0 ? "Кеш медиа очищен." : "Кеш очищен. Используемые сейчас файлы сохранены."
                    isCleaning = false
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будут удалены только скачанные копии медиа с этого устройства. Переписки, черновики, неотправленные и используемые сейчас файлы останутся.")
        }
    }

    private func presetPicker(_ title: String, selection: Binding<AloMediaDownloadPreset>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(AloTheme.muted)
            Picker(title, selection: selection) {
                ForEach(AloMediaDownloadPreset.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).labelsHidden().frame(minHeight: 44)
        }.padding(.vertical, 8)
    }

    @ViewBuilder private func valueRow(_ title: String, value: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(value).foregroundStyle(AloTheme.muted)
            }.padding(.vertical, 8)
        } else {
            LabeledContent(title, value: value)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AloTheme.muted)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 14).aloCard(radius: 18)
        }
    }
}
