import Combine
import SwiftUI

/// What a chat row needs to offer «Aa» and «Перевести» for one message.
struct AloContentToolsContext {
    let store: AloContentToolsStore
    let message: AloChatMessage
    let conversation: AloConversationDetail
}

/// Three dots that breathe while a request is out (Telegram's transcription button does the same).
struct AloLoadingDots: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = reduceMotion ? 0.7 : (sin(time * 5.4 - Double(index) * 0.95) + 1) / 2
                    Circle()
                        .fill(color)
                        .frame(width: 4, height: 4)
                        .opacity(0.35 + 0.65 * wave)
                        .scaleEffect(0.78 + 0.32 * wave)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The «Aa» pill on a voice message or a video circle: tap to turn the sound into text, tap again to fold the text away.
struct AloTranscribeAccessory: View {
    @ObservedObject var store: AloContentToolsStore
    let context: AloContentToolsContext
    let attachment: AloMessageAttachment
    var tint: Color = .white
    var fill: Color = Color.white.opacity(0.2)

    var body: some View {
        if store.canTranscribe(context.message, in: context.conversation) {
            let id = context.message.id
            let phase = store.transcriptPhase(id)
            let expanded = store.isTranscriptExpanded(id)
            Button {
                store.toggleTranscript(message: context.message, attachment: attachment, conversation: context.conversation)
            } label: {
                ZStack {
                    if case .loading? = phase {
                        AloLoadingDots(color: tint).transition(.opacity)
                    } else if expanded {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .bold))
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    } else {
                        Text("Aa")
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    }
                }
                .foregroundStyle(tint)
                .frame(width: 30, height: 22)
                .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle().inset(by: -8))
                .animation(.easeInOut(duration: 0.18), value: phaseKey(phase, expanded))
            }
            .buttonStyle(AloChatPressStyle())
            .accessibilityLabel(expanded ? "Скрыть расшифровку" : "Расшифровать")
            .accessibilityIdentifier("alo.transcribe.\(id)")
        }
    }

    private func phaseKey(_ phase: AloContentToolPhase<AloContentToolsStore.Transcript>?, _ expanded: Bool) -> Int {
        switch phase {
        case .loading?: return 1
        case .ready?: return expanded ? 2 : 3
        case .failed?: return 4
        case nil: return 0
        }
    }
}

/// The text of a voice message, under its waveform; it grows into place and, when it has just arrived, is written out.
struct AloTranscriptAccessory: View {
    @ObservedObject var store: AloContentToolsStore
    let messageId: Int
    var foreground: Color = .white
    var secondary: Color = Color.white.opacity(0.62)
    /// A circle has no bubble of its own: its text sits in one of this colour.
    var bubbleFill: Color?

    var body: some View {
        switch store.transcriptPhase(messageId) {
        case .ready(let transcript)? where store.isTranscriptExpanded(messageId):
            boxed {
                AloRevealedText(text: transcript.text, color: foreground, animated: store.freshTranscripts.contains(messageId)) {
                    store.markRevealed(messageId)
                }
                .accessibilityIdentifier("alo.transcript.\(messageId)")
            }
        case .failed(let message)?:
            boxed {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondary)
                    .accessibilityIdentifier("alo.transcript.error.\(messageId)")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func boxed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let bubbleFill {
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bubbleFill)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            content()
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Text that is laid out at its final size at once and then inked in letter by letter, so nothing reflows while it arrives.
struct AloRevealedText: View {
    let text: String
    let color: Color
    let animated: Bool
    var fontSize: CGFloat = 16
    var onFinished: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = 0

    var body: some View {
        Text(attributed)
            .font(.system(size: fontSize))
            .fixedSize(horizontal: false, vertical: true)
            .task(id: text) {
                let total = text.count
                guard animated, !reduceMotion, total > 0 else {
                    revealed = total
                    onFinished()
                    return
                }
                revealed = 0
                let step = max(1, total / 42)
                while revealed < total {
                    try? await Task.sleep(for: .milliseconds(16))
                    if Task.isCancelled { return }
                    revealed = min(total, revealed + step)
                }
                onFinished()
            }
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        let done = min(revealed, text.count)
        guard done < text.count else {
            result.foregroundColor = color
            return result
        }
        result.foregroundColor = .clear
        let boundary = result.index(result.startIndex, offsetByCharacters: done)
        result[result.startIndex..<boundary].foregroundColor = color
        return result
    }
}

/// «Перевод · English» and the translated text, under the original message; a hairline separates the two.
struct AloTranslationAccessory: View {
    @ObservedObject var store: AloContentToolsStore
    let messageId: Int
    var foreground: Color = .white
    var secondary: Color = Color.white.opacity(0.62)

    var body: some View {
        if let shown = store.shownTranslation(messageId) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "translate").font(.system(size: 11, weight: .semibold))
                    Text("Перевод · \(store.languageName(shown.language))")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(secondary)
                switch shown.phase {
                case .loading:
                    AloLoadingDots(color: secondary).frame(height: 20, alignment: .leading)
                case .ready(let translation):
                    Text(translation.text)
                        .font(.system(size: 17))
                        .foregroundStyle(foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("alo.translation.\(messageId)")
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(secondary)
                        .accessibilityIdentifier("alo.translation.error.\(messageId)")
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(foreground.opacity(0.18)).frame(height: 0.5)
            }
            .padding(.top, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Asks once per device before the first text or sound leaves for the server.
struct AloContentConsentAlert: ViewModifier {
    @ObservedObject var store: AloContentToolsStore

    func body(content: Content) -> some View {
        content.alert(
            store.consentRequest?.title ?? "",
            isPresented: Binding(
                get: { store.consentRequest != nil },
                set: { if !$0 { store.declineConsent() } }
            ),
            presenting: store.consentRequest
        ) { _ in
            Button("Разрешить") { store.confirmConsent() }
            Button("Отмена", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }
}

/// «Перевести на…»: the languages the server offers, the last one used first.
struct ChatTranslationLanguageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let languages: [AloContentLanguage]
    let lastLanguage: String
    let onPick: (AloContentLanguage) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(languages) { language in
                        Button {
                            onPick(language)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(language.name)
                                        .font(.system(size: 17))
                                        .foregroundStyle(AloTheme.text)
                                    if language.english != language.name {
                                        Text(language.english)
                                            .font(.system(size: 13))
                                            .foregroundStyle(AloTheme.muted)
                                    }
                                }
                                Spacer(minLength: 8)
                                if language.code == lastLanguage {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AloTheme.accent)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(AloChatPressStyle())
                        .accessibilityIdentifier("alo.translate.language.\(language.code)")
                        if language.id != languages.last?.id {
                            Divider().overlay(AloTheme.separator).padding(.leading, 16)
                        }
                    }
                }
                .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Перевести на")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("alo.translate.sheet")
    }
}

/// The settings page behind «Перевод и расшифровка»: the consent switch and a way to forget what was saved.
struct AloContentToolsSettingsView: View {
    @ObservedObject var store: AloContentToolsStore
    @State private var didClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { store.hasConsent }, set: { store.setConsent($0) })) {
                    Text("Отправлять на перевод и расшифровку")
                        .font(.system(size: 17))
                        .foregroundStyle(AloTheme.text)
                }
                .tint(AloTheme.accent)
                .accessibilityIdentifier("alo.settings.content-tools.consent")
                Text("Когда вы выбираете «Перевести» или «Aa», текст или звук одного этого сообщения отправляется на сервер Alo и сервису перевода или расшифровки. Остальная переписка не передаётся, сервер ничего не хранит. Если выключить, приложение снова спросит перед первым запросом.")
                    .font(.system(size: 13))
                    .foregroundStyle(AloTheme.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Button(role: .destructive) {
                    store.removeSavedResults()
                    didClear = true
                } label: {
                    Text("Удалить сохранённые переводы и расшифровки")
                        .font(.system(size: 17))
                        .foregroundStyle(AloTheme.destructive)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("alo.settings.content-tools.clear")
                Text(didClear ? "Готово: на этом устройстве ничего не осталось." : "Тексты хранятся только на этом устройстве, в зашифрованном виде.")
                    .font(.system(size: 13))
                    .foregroundStyle(AloTheme.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if !store.capabilities.translation && !store.capabilities.transcription {
                Text("Сервер пока не подключил перевод и расшифровку, поэтому кнопки в чатах скрыты.")
                    .font(.system(size: 13))
                    .foregroundStyle(AloTheme.muted)
            }
        }
    }
}
