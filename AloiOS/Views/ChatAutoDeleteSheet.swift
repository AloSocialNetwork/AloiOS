import SwiftUI

struct ChatAutoDeleteSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let conversation: AloConversationDetail
    @State private var selected = 0
    @State private var original: Int?
    @State private var isSaving = false
    @State private var errorMessage: String?
    private let choices: [(Int, String)] = [
        (0, "Выключено"), (86_400, "1 день"), (604_800, "1 неделя"),
        (2_592_000, "1 месяц"), (7_776_000, "3 месяца"), (31_536_000, "1 год")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(choices, id: \.0) { seconds, title in
                        Button { selected = seconds } label: {
                            HStack {
                                Text(title).foregroundStyle(AloTheme.text)
                                Spacer()
                                if selected == seconds {
                                    Image(systemName: "checkmark").foregroundStyle(AloTheme.accent)
                                }
                            }
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .disabled(original == nil || isSaving)
                        .accessibilityAddTraits(selected == seconds ? .isSelected : [])
                        .listRowBackground(AloTheme.surface)
                    }
                } footer: {
                    Text("Новые сообщения будут удаляться у всех участников по истечении выбранного срока. Уже отправленная история не изменится.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        if original == nil { Button("Повторить") { Task { await load() } } }
                    }.listRowBackground(AloTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AloTheme.background)
            .overlay { if original == nil && errorMessage == nil { ProgressView() } }
            .navigationTitle("Автоудаление")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Отмена")
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if isSaving { ProgressView() } else { Image(systemName: "checkmark") }
                    }
                    .accessibilityLabel("Сохранить")
                    .disabled(original == nil || selected == original || isSaving)
                }
            }
        }
        .tint(AloTheme.accent)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSaving)
        .task { await load() }
    }

    @MainActor private func load() async {
        errorMessage = nil
        do {
            let value: Int
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") {
                selected = 0; original = 0
                return
            }
            #endif
            if conversation.kind == "direct" {
                value = try await app.api.directChatAutoDeleteSeconds(peerId: conversation.peerId)
            } else if let policy = conversation.groupPolicy {
                value = policy.autoDeleteSeconds
            } else {
                throw AloAPIError(status: -1, code: "GROUP_POLICY_MISSING",
                                  message: "Настройки группы ещё не загружены.", payload: [:])
            }
            selected = value
            original = value
        } catch { errorMessage = "Не удалось загрузить срок автоудаления. Повторите попытку." }
    }

    @MainActor private func save() async {
        guard original != nil, !isSaving,
              conversation.entityType != "saved",
              conversation.kind == "direct" || conversation.canManageGroup else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") {
            errorMessage = "В дизайн-превью настройки сервера не изменяются."
            return
        }
        #endif
        do {
            if conversation.kind == "direct" {
                _ = try await app.api.setDirectChatAutoDeleteSeconds(peerId: conversation.peerId, seconds: selected)
            } else {
                guard var policy = conversation.groupPolicy else { return }
                policy.autoDeleteSeconds = selected
                _ = try await app.api.updateGroupSettings(roomId: conversation.roomId, policy: policy)
            }
            dismiss()
        } catch let error as AloAPIError { errorMessage = error.message }
        catch { errorMessage = "Не удалось сохранить. Повторите попытку." }
    }
}
