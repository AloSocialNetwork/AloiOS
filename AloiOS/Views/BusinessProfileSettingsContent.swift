import SwiftUI

private enum BusinessChatLabelColor: String, CaseIterable, Identifiable {
    case blue
    case green
    case orange
    case purple
    case pink
    case gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: Color(red: 0.04, green: 0.52, blue: 1)
        case .green: Color(red: 0.19, green: 0.82, blue: 0.35)
        case .orange: Color(red: 1, green: 0.62, blue: 0.04)
        case .purple: Color(red: 0.75, green: 0.35, blue: 0.95)
        case .pink: Color(red: 1, green: 0.22, blue: 0.37)
        case .gray: Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }
}

/// Account-level business tools live in settings rather than the conversation
/// list. That keeps personal messaging visually calm while still making the
/// configuration available on every signed-in device.
struct BusinessProfileSettingsContent: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var didLoadDraft = false
    @State private var enabled = false
    @State private var businessName = ""
    @State private var category = ""
    @State private var hoursSummary = ""
    @State private var greeting = ""
    @State private var autoReplyEnabled = false
    @State private var autoReply = ""
    @State private var quickReplyShortcut = ""
    @State private var quickReplyText = ""
    @State private var chatLabelTargetKey = ""
    @State private var chatLabelText = ""
    @State private var chatLabelColor = BusinessChatLabelColor.blue

    private var conversations: [AloConversationSummary] {
        app.bootstrap?.conversations ?? []
    }

    private var selectedChatLabelConversation: AloConversationSummary? {
        conversations.first { chatLabelTargetKey == targetKey(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            businessCard {
                Toggle("Включить бизнес-профиль", isOn: $enabled)
                    .tint(AloTheme.accent)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AloTheme.text)
                Text("Покажите клиентам актуальные часы, приветствие и ответы без изменения личных чатов.")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(AloTheme.muted)
            }

            Text("ПРОФИЛЬ")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AloTheme.muted)
                .padding(.horizontal, 4)
            businessCard {
                businessField("Название", text: $businessName, placeholder: "Например, Alo Studio")
                divider
                businessField("Категория", text: $category, placeholder: "Услуги, магазин, кафе…")
                divider
                businessField("Часы работы", text: $hoursSummary, placeholder: "Пн–Пт 10:00–19:00")
            }

            Text("СООБЩЕНИЯ")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AloTheme.muted)
                .padding(.horizontal, 4)
            businessCard {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Приветствие")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AloTheme.text)
                    TextField("Здравствуйте! Чем можем помочь?", text: $greeting, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.system(size: 16))
                        .foregroundStyle(AloTheme.text)
                }
                divider
                Toggle("Автоответ", isOn: $autoReplyEnabled)
                    .tint(AloTheme.accent)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AloTheme.text)
                if autoReplyEnabled {
                    TextField("Мы ответим в рабочее время", text: $autoReply, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.system(size: 16))
                        .foregroundStyle(AloTheme.text)
                        .padding(.top, 2)
                }
                Text("Автоответ хранится в профиле. В зашифрованных чатах он отправляется только с авторизованного устройства владельца.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(AloTheme.muted)
            }

            Button {
                app.saveBusinessProfile(
                    enabled: enabled,
                    businessName: businessName,
                    category: category,
                    hours: hoursSummary.isEmpty ? [:] : ["summary": hoursSummary],
                    greetingMessage: greeting,
                    autoReplyEnabled: autoReplyEnabled,
                    autoReplyMessage: autoReply
                )
            } label: {
                Text("Сохранить бизнес-профиль")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(AloTheme.accent, in: Capsule())
            }
            .buttonStyle(AloPressBounceButtonStyle())
            .disabled(autoReplyEnabled && autoReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(autoReplyEnabled && autoReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.46 : 1)

            Text("БЫСТРЫЕ ОТВЕТЫ")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AloTheme.muted)
                .padding(.horizontal, 4)
            businessCard {
                if let quickReplies = app.businessProfileData?.quickReplies, !quickReplies.isEmpty {
                    ForEach(quickReplies) { reply in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("/\(reply.shortcut)")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(AloTheme.accent)
                                Text(reply.body)
                                    .font(.system(size: 14.5))
                                    .foregroundStyle(AloTheme.text)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button(role: .destructive) { app.deleteBusinessQuickReply(reply) } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AloTheme.destructive)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                        if reply.id != quickReplies.last?.id { divider }
                    }
                    divider
                }
                TextField("Команда, например price", text: $quickReplyShortcut)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 16))
                    .foregroundStyle(AloTheme.text)
                divider
                TextField("Текст быстрого ответа", text: $quickReplyText, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(size: 16))
                    .foregroundStyle(AloTheme.text)
                Button {
                    app.addBusinessQuickReply(
                        shortcut: quickReplyShortcut,
                        title: quickReplyShortcut,
                        body: quickReplyText
                    )
                    quickReplyShortcut = ""
                    quickReplyText = ""
                } label: {
                    Label("Добавить быстрый ответ", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AloTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(quickReplyShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || quickReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("МЕТКИ ЧАТОВ")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AloTheme.muted)
                .padding(.horizontal, 4)
            businessCard {
                if let labels = app.businessProfileData?.chatLabels, !labels.isEmpty {
                    ForEach(labels) { chatLabel in
                        HStack(spacing: 11) {
                            Circle()
                                .fill(labelColor(named: chatLabel.color))
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chatLabel.label)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(AloTheme.text)
                                    .lineLimit(1)
                                Text(targetName(for: chatLabel))
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(AloTheme.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button(role: .destructive) {
                                app.deleteBusinessChatLabel(chatLabel)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AloTheme.destructive)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .disabled(app.isBusinessProfileLoading)
                        }
                        if chatLabel.id != labels.last?.id { divider }
                    }
                    divider
                }

                if conversations.isEmpty {
                    Text("Чтобы добавить метку, сначала откройте реальный диалог или группу.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(AloTheme.muted)
                } else {
                    Menu {
                        ForEach(Array(conversations.enumerated()), id: \.offset) { _, conversation in
                            Button {
                                chatLabelTargetKey = targetKey(for: conversation)
                            } label: {
                                if targetKey(for: conversation) == chatLabelTargetKey {
                                    Label(conversation.peer.name.ifBlank("Чат"), systemImage: "checkmark")
                                } else {
                                    Text(conversation.peer.name.ifBlank("Чат"))
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(selectedChatLabelConversation?.peer.name.ifBlank("Выбрать чат") ?? "Выбрать чат")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(AloTheme.text)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AloTheme.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    divider
                    TextField("Название метки", text: $chatLabelText)
                        .font(.system(size: 16))
                        .foregroundStyle(AloTheme.text)
                        .onChange(of: chatLabelText) { _, value in
                            if value.count > 40 { chatLabelText = String(value.prefix(40)) }
                        }

                    HStack(spacing: 12) {
                        ForEach(BusinessChatLabelColor.allCases) { option in
                            Button {
                                chatLabelColor = option
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if chatLabelColor == option {
                                            Circle().stroke(AloTheme.text, lineWidth: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Цвет метки: \(option.rawValue)")
                        }
                    }

                    Button {
                        guard let conversation = selectedChatLabelConversation else { return }
                        app.saveBusinessChatLabel(
                            for: conversation,
                            label: chatLabelText,
                            color: chatLabelColor.rawValue
                        )
                        chatLabelText = ""
                    } label: {
                        if app.isBusinessProfileLoading {
                            ProgressView().tint(AloTheme.accent)
                        } else {
                            Label("Сохранить метку", systemImage: "tag")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AloTheme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        app.isBusinessProfileLoading ||
                            selectedChatLabelConversation == nil ||
                            chatLabelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .task {
            await app.loadBusinessProfile(silently: true)
            loadDraftIfNeeded()
            selectDefaultChatIfNeeded()
        }
        .onChange(of: app.businessProfileData?.profile.updatedAt) { _, _ in
            loadDraftIfNeeded(force: !didLoadDraft)
        }
        .onChange(of: conversations.count) { _, _ in
            selectDefaultChatIfNeeded()
        }
    }

    private func businessField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AloTheme.muted)
            TextField(placeholder, text: text)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(AloTheme.text)
        }
    }

    private var divider: some View {
        Rectangle().fill(AloTheme.border.opacity(0.75)).frame(height: 1)
    }

    private func businessCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func loadDraftIfNeeded(force: Bool = false) {
        guard let profile = app.businessProfileData?.profile, force || !didLoadDraft else { return }
        didLoadDraft = true
        enabled = profile.enabled
        businessName = profile.businessName
        category = profile.category
        hoursSummary = profile.hours["summary"] ?? ""
        greeting = profile.greetingMessage
        autoReplyEnabled = profile.autoReplyEnabled
        autoReply = profile.autoReplyMessage
    }

    private func targetKey(for conversation: AloConversationSummary) -> String {
        "\(conversation.kind):\(conversation.peerId):\(conversation.roomId)"
    }

    private func selectDefaultChatIfNeeded() {
        guard selectedChatLabelConversation == nil, let first = conversations.first else { return }
        chatLabelTargetKey = targetKey(for: first)
    }

    private func targetName(for chatLabel: AloBusinessChatLabel) -> String {
        if let conversation = conversations.first(where: {
            $0.kind == chatLabel.chatKind && $0.peerId == chatLabel.peerId && $0.roomId == chatLabel.roomId
        }) {
            return conversation.peer.name.ifBlank("Чат")
        }
        return chatLabel.chatKind == "group" ? "Группа #\(chatLabel.roomId)" : "Диалог #\(chatLabel.peerId)"
    }

    private func labelColor(named name: String) -> Color {
        BusinessChatLabelColor(rawValue: name)?.color ?? BusinessChatLabelColor.blue.color
    }
}
