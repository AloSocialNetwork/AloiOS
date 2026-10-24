import AVFoundation
import Combine
import Foundation
import SwiftUI

/// What «Перевести» and «Aa» need from the server. The live one is `AloAPIClient`; UI tests run against a fixture that
/// answers without a network (a debug build started with `-ALO_UI_MESSENGER_PREVIEW`).
protocol AloContentToolsTransport {
    /// A fixture needs no audio, so a UI test skips decrypting a file.
    var needsAudio: Bool { get }
    func capabilities() async throws -> AloContentToolsCapabilities
    func translate(conversation: AloConversationDetail, messageId: Int, text: String, target: String) async throws -> AloMessageTranslation
    func transcribe(conversation: AloConversationDetail, messageId: Int, audio: Data, mimeType: String,
                    attachmentId: String) async throws -> AloVoiceTranscription
}

struct AloLiveContentToolsTransport: AloContentToolsTransport {
    let api: AloAPIClient
    var needsAudio: Bool { true }

    func capabilities() async throws -> AloContentToolsCapabilities { try await api.loadContentTools() }

    func translate(conversation: AloConversationDetail, messageId: Int, text: String, target: String) async throws -> AloMessageTranslation {
        try await api.translateMessage(conversation: conversation, messageId: messageId, text: text, targetLanguage: target)
    }

    func transcribe(conversation: AloConversationDetail, messageId: Int, audio: Data, mimeType: String,
                    attachmentId: String) async throws -> AloVoiceTranscription {
        try await api.transcribeVoiceMessage(conversation: conversation, messageId: messageId, audio: audio,
                                             mimeType: mimeType, attachmentId: attachmentId)
    }
}

enum AloContentToolsError: Error, Equatable {
    case audioTooLarge
    case noAudio
    case unreadable
    case textTooLong
    case empty
}

enum AloContentToolPhase<Value: Equatable>: Equatable {
    case loading
    case ready(Value)
    case failed(String)
}

/// The short Russian line a person sees when a content tool did not work.
enum AloContentToolsMessage {
    static func text(for error: Error, translating: Bool) -> String {
        if let local = error as? AloContentToolsError {
            switch local {
            case .audioTooLarge: return "Запись слишком длинная для расшифровки."
            case .noAudio: return "В этом сообщении нет звука."
            case .unreadable: return "Не удалось прочитать запись."
            case .textTooLong: return "Сообщение слишком длинное для перевода."
            case .empty: return translating ? "Сервис не вернул перевод." : "В записи не нашлось речи."
            }
        }
        guard let api = error as? AloAPIError else { return "Не удалось выполнить запрос. Проверьте соединение." }
        switch api.code {
        case "translation_unavailable": return "Перевод не подключён на сервере."
        case "transcription_unavailable": return "Расшифровка не подключена на сервере."
        case "RATE_LIMITED": return "Слишком много запросов. Попробуйте позже."
        case "transcription_audio_too_large": return "Запись слишком длинная для расшифровки."
        case "translation_invalid": return "Это сообщение нельзя перевести на выбранный язык."
        case "translation_provider_failed", "translation_provider_invalid", "message_translation_provider_failed",
             "message_translation_provider_invalid", "transcription_provider_failed", "transcription_provider_invalid",
             "voice_transcription_provider_failed", "voice_transcription_provider_invalid":
            return "Сервис временно недоступен. Попробуйте позже."
        case "CONNECTION_FAILED": return "Нет соединения с сервером."
        default:
            return api.status == 0 ? "Нет соединения с сервером." : api.message
        }
    }
}

/// A stable hash for noticing that a translated message was edited since.
private func aloContentTextDigest(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
}

/// Translations and transcripts this device asked for, with the consent that lets it ask. Results are kept per account in the
/// encrypted offline cache so they are there the next time the chat opens; the server never keeps them.
@MainActor
final class AloContentToolsStore: ObservableObject {
    struct Transcript: Codable, Equatable {
        var text: String
        var language: String
    }

    struct Translation: Codable, Equatable {
        var text: String
        var sourceLanguage: String
        var targetLanguage: String
        var digest: String
    }

    enum ConsentTopic { case translation, transcription }

    struct ConsentRequest: Identifiable {
        let id = UUID()
        let topic: ConsentTopic
        let proceed: () -> Void

        var title: String { topic == .translation ? "Отправить текст на перевод?" : "Расшифровать запись?" }
        var message: String {
            switch topic {
            case .translation:
                return "Текст этого сообщения будет отправлен на сервер Alo и сервису перевода. Остальная переписка не передаётся, сервер ничего не хранит."
            case .transcription:
                return "Звук этого сообщения будет отправлен на сервер Alo и сервису расшифровки. Остальная переписка не передаётся, сервер ничего не хранит."
            }
        }
    }

    private struct Persisted: Codable {
        var transcripts: [String: Transcript] = [:]
        var collapsedTranscripts: [Int] = []
        var translations: [String: Translation] = [:]
        var shownTranslations: [String: String] = [:]
    }

    nonisolated static let consentKey = "alo.contentTools.consent.v1"
    nonisolated static let languageKey = "alo.contentTools.language.v1"
    private static let capabilitiesKey = "alo.contentTools.capabilities.v1"
    private static let recordName = "content-tools"
    private static let entryLimit = 500
    static let revealAnimation = Animation.spring(response: 0.34, dampingFraction: 0.86)

    @Published private(set) var capabilities: AloContentToolsCapabilities
    @Published private(set) var transcripts: [Int: AloContentToolPhase<Transcript>] = [:]
    @Published private(set) var expandedTranscripts = Set<Int>()
    @Published private(set) var translations: [Int: [String: AloContentToolPhase<Translation>]] = [:]
    @Published private(set) var shownTranslations: [Int: String] = [:]
    @Published private(set) var hasConsent: Bool
    @Published private(set) var lastTargetLanguage: String
    @Published var consentRequest: ConsentRequest?
    /// Transcripts that have just arrived play their reveal once; cached ones appear at once.
    private(set) var freshTranscripts = Set<Int>()

    var transport: AloContentToolsTransport
    var audioLoader: (AloMessageAttachment, Int) async throws -> (data: Data, mimeType: String) = { _, _ in throw AloContentToolsError.unreadable }
    private(set) var ownerUserId = 0
    private var persistTask: Task<Void, Never>?
    /// A UI-test fixture neither remembers consent nor results between runs, so every run starts the same.
    private var isFixture = false

    init(transport: AloContentToolsTransport) {
        self.transport = transport
        hasConsent = UserDefaults.standard.bool(forKey: Self.consentKey)
        lastTargetLanguage = UserDefaults.standard.string(forKey: Self.languageKey) ?? "ru"
        if let data = UserDefaults.standard.data(forKey: Self.capabilitiesKey),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            capabilities = AloContentToolsCapabilities(json)
        } else {
            capabilities = .unavailable
        }
    }

    // MARK: Availability

    func refreshCapabilities() async {
        guard let fresh = try? await transport.capabilities() else { return }
        capabilities = fresh
        let json: [String: Any] = [
            "translation": fresh.translation, "transcription": fresh.transcription, "maxAudioBytes": fresh.maxAudioBytes,
            "languages": fresh.languages.map { ["code": $0.code, "name": $0.name, "english": $0.english] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            UserDefaults.standard.set(data, forKey: Self.capabilitiesKey)
        }
    }

    func apply(capabilities: AloContentToolsCapabilities) { self.capabilities = capabilities }

    /// A debug fixture that has no server to ask.
    func installFixture(translation: Bool, transcription: Bool, consent: Bool) {
        isFixture = true
        hasConsent = consent
        transport = AloContentToolsFixtureTransport()
        capabilities = AloContentToolsCapabilities(translation: translation, transcription: transcription,
                                                   languages: AloContentToolsFixtureTransport.languages)
    }

    private func isToolAllowed(in conversation: AloConversationDetail?) -> Bool {
        conversation?.groupPolicy?.protectedContent != true
    }

    func canTranslate(_ message: AloChatMessage, in conversation: AloConversationDetail?) -> Bool {
        capabilities.translation && isToolAllowed(in: conversation) && message.id > 0 &&
            message.selfDestructSeconds <= 0 && !message.isCallLogMessage &&
            AloPollCodec.decode(message.body) == nil &&
            !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func canTranscribe(_ message: AloChatMessage, in conversation: AloConversationDetail?) -> Bool {
        capabilities.transcription && isToolAllowed(in: conversation) && message.id > 0 && message.selfDestructSeconds <= 0
    }

    /// Languages in the order the picker shows them: the last one used first.
    func orderedLanguages() -> [AloContentLanguage] {
        let all = capabilities.languages
        guard let last = all.first(where: { $0.code == lastTargetLanguage }) else { return all }
        return [last] + all.filter { $0.code != last.code }
    }

    func languageName(_ code: String) -> String {
        capabilities.languages.first(where: { $0.code == code })?.name ?? code.uppercased()
    }

    // MARK: Consent

    func setConsent(_ granted: Bool) {
        hasConsent = granted
        if !isFixture { UserDefaults.standard.set(granted, forKey: Self.consentKey) }
    }

    private func authorize(_ topic: ConsentTopic, proceed: @escaping () -> Void) {
        if hasConsent { proceed() } else { consentRequest = ConsentRequest(topic: topic, proceed: proceed) }
    }

    func confirmConsent() {
        guard let request = consentRequest else { return }
        consentRequest = nil
        setConsent(true)
        request.proceed()
    }

    func declineConsent() { consentRequest = nil }

    // MARK: Voice messages and circles

    func transcriptPhase(_ messageId: Int) -> AloContentToolPhase<Transcript>? { transcripts[messageId] }

    func isTranscriptExpanded(_ messageId: Int) -> Bool { expandedTranscripts.contains(messageId) }

    func toggleTranscript(message: AloChatMessage, attachment: AloMessageAttachment, conversation: AloConversationDetail) {
        let id = message.id
        guard id > 0 else { return }
        switch transcripts[id] {
        case .loading:
            return
        case .ready:
            withAnimation(Self.revealAnimation) {
                if expandedTranscripts.contains(id) { expandedTranscripts.remove(id) } else { expandedTranscripts.insert(id) }
            }
            schedulePersist()
        case .failed, nil:
            authorize(.transcription) { [weak self] in
                self?.startTranscription(message: message, attachment: attachment, conversation: conversation)
            }
        }
    }

    private func startTranscription(message: AloChatMessage, attachment: AloMessageAttachment, conversation: AloConversationDetail) {
        let id = message.id
        withAnimation(Self.revealAnimation) { transcripts[id] = .loading }
        Task { @MainActor in
            do {
                let audio: (data: Data, mimeType: String)
                if transport.needsAudio {
                    audio = try await audioLoader(attachment, capabilities.maxAudioBytes)
                } else {
                    audio = (Data(), "audio/mp4")
                }
                let result = try await transport.transcribe(conversation: conversation, messageId: id, audio: audio.data,
                                                            mimeType: audio.mimeType, attachmentId: attachment.id)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw AloContentToolsError.empty }
                freshTranscripts.insert(id)
                withAnimation(Self.revealAnimation) {
                    transcripts[id] = .ready(Transcript(text: text, language: result.language))
                    expandedTranscripts.insert(id)
                }
                schedulePersist()
            } catch {
                withAnimation(Self.revealAnimation) {
                    transcripts[id] = .failed(AloContentToolsMessage.text(for: error, translating: false))
                }
                scheduleFailureDismissal(id: id)
            }
        }
    }

    func markRevealed(_ messageId: Int) { freshTranscripts.remove(messageId) }

    private func scheduleFailureDismissal(id: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, case .failed? = self.transcripts[id] else { return }
            withAnimation(Self.revealAnimation) { self.transcripts[id] = nil }
        }
    }

    // MARK: Translation

    /// The translation shown under a message, with the language it is in.
    func shownTranslation(_ messageId: Int) -> (language: String, phase: AloContentToolPhase<Translation>)? {
        guard let language = shownTranslations[messageId], let phase = translations[messageId]?[language] else { return nil }
        return (language, phase)
    }

    func translate(message: AloChatMessage, conversation: AloConversationDetail, to language: AloContentLanguage) {
        let id = message.id
        let text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id > 0, !text.isEmpty else { return }
        lastTargetLanguage = language.code
        if !isFixture { UserDefaults.standard.set(language.code, forKey: Self.languageKey) }
        if case .ready(let cached)? = translations[id]?[language.code], cached.digest == aloContentTextDigest(text) {
            withAnimation(Self.revealAnimation) { shownTranslations[id] = language.code }
            schedulePersist()
            return
        }
        guard text.count <= 12_000 else {
            withAnimation(Self.revealAnimation) {
                translations[id, default: [:]][language.code] = .failed(AloContentToolsMessage.text(for: AloContentToolsError.textTooLong, translating: true))
                shownTranslations[id] = language.code
            }
            return
        }
        authorize(.translation) { [weak self] in
            self?.startTranslation(id: id, text: text, conversation: conversation, language: language)
        }
    }

    private func startTranslation(id: Int, text: String, conversation: AloConversationDetail, language: AloContentLanguage) {
        withAnimation(Self.revealAnimation) {
            translations[id, default: [:]][language.code] = .loading
            shownTranslations[id] = language.code
        }
        Task { @MainActor in
            do {
                let result = try await transport.translate(conversation: conversation, messageId: id, text: text, target: language.code)
                let translated = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translated.isEmpty else { throw AloContentToolsError.empty }
                withAnimation(Self.revealAnimation) {
                    translations[id, default: [:]][language.code] = .ready(Translation(
                        text: translated, sourceLanguage: result.sourceLanguage.ifBlank("auto"),
                        targetLanguage: language.code, digest: aloContentTextDigest(text)))
                }
                schedulePersist()
            } catch {
                withAnimation(Self.revealAnimation) {
                    translations[id, default: [:]][language.code] = .failed(AloContentToolsMessage.text(for: error, translating: true))
                }
            }
        }
    }

    func hideTranslation(_ messageId: Int) {
        guard let language = shownTranslations[messageId] else { return }
        withAnimation(Self.revealAnimation) {
            shownTranslations[messageId] = nil
            if case .failed? = translations[messageId]?[language] { translations[messageId]?[language] = nil }
            if case .loading? = translations[messageId]?[language] { translations[messageId]?[language] = nil }
        }
        schedulePersist()
    }

    // MARK: Persistence

    /// Called when the signed-in account is known (and again whenever it may have changed).
    func accountChanged(_ userId: Int?) {
        let userId = userId ?? 0
        guard userId != ownerUserId else { return }
        persistTask?.cancel()
        ownerUserId = userId
        transcripts = [:]
        expandedTranscripts = []
        translations = [:]
        shownTranslations = [:]
        freshTranscripts = []
        guard userId > 0, !isFixture,
              let data = AloSecureOfflineCacheStore.shared.loadRecord(named: Self.recordName, ownerUserId: userId),
              let saved = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        let collapsed = Set(saved.collapsedTranscripts)
        for (key, transcript) in saved.transcripts {
            guard let id = Int(key) else { continue }
            transcripts[id] = .ready(transcript)
            if !collapsed.contains(id) { expandedTranscripts.insert(id) }
        }
        for (key, translation) in saved.translations {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = Int(parts[0]) else { continue }
            translations[id, default: [:]][parts[1]] = .ready(translation)
        }
        for (key, language) in saved.shownTranslations {
            if let id = Int(key), translations[id]?[language] != nil { shownTranslations[id] = language }
        }
    }

    func removeSavedResults() {
        persistTask?.cancel()
        transcripts = [:]
        expandedTranscripts = []
        translations = [:]
        shownTranslations = [:]
        freshTranscripts = []
        guard ownerUserId > 0, !isFixture else { return }
        try? AloSecureOfflineCacheStore.shared.saveRecord(Data("{}".utf8), named: Self.recordName, ownerUserId: ownerUserId)
    }

    private func schedulePersist() {
        guard ownerUserId > 0, !isFixture else { return }
        persistTask?.cancel()
        let owner = ownerUserId
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.ownerUserId == owner else { return }
            var saved = Persisted()
            for (id, phase) in self.transcripts {
                guard case .ready(let transcript) = phase else { continue }
                saved.transcripts[String(id)] = transcript
                if !self.expandedTranscripts.contains(id) { saved.collapsedTranscripts.append(id) }
            }
            for (id, byLanguage) in self.translations {
                for (language, phase) in byLanguage {
                    if case .ready(let translation) = phase { saved.translations["\(id)|\(language)"] = translation }
                }
            }
            for (id, language) in self.shownTranslations {
                if case .ready? = self.translations[id]?[language] { saved.shownTranslations[String(id)] = language }
            }
            // The newest messages matter: drop the oldest results beyond the limit.
            if saved.transcripts.count > Self.entryLimit {
                for key in saved.transcripts.keys.compactMap(Int.init).sorted().dropLast(Self.entryLimit) {
                    saved.transcripts[String(key)] = nil
                }
            }
            if saved.translations.count > Self.entryLimit {
                let ordered = saved.translations.keys.sorted { (Int($0.split(separator: "|")[0]) ?? 0) < (Int($1.split(separator: "|")[0]) ?? 0) }
                for key in ordered.dropLast(Self.entryLimit) { saved.translations[key] = nil }
            }
            if let data = try? JSONEncoder().encode(saved) {
                try? AloSecureOfflineCacheStore.shared.saveRecord(data, named: Self.recordName, ownerUserId: owner)
            }
        }
    }
}

// MARK: - Audio

/// Gets the sound of one voice message or circle in a form the server accepts, decrypting it on this device.
enum AloContentAudio {
    static func load(_ attachment: AloMessageAttachment, api: AloAPIClient, maxBytes: Int) async throws -> (data: Data, mimeType: String) {
        guard let url = api.absoluteURL(attachment.url) else { throw AloContentToolsError.unreadable }
        var data: Data
        var mime: String
        if AloSecureMediaStore.shared.isSecureURL(url) {
            try await AloSecureMediaStore.shared.ensureAvailable(url, intent: .userInitiated)
            let payload = try AloSecureMediaStore.shared.payload(for: url)
            data = payload.data
            mime = payload.mime
        } else if url.isFileURL {
            data = try Data(contentsOf: url)
            mime = ""
        } else {
            let downloaded = try await api.downloadData(from: url)
            data = downloaded.data
            mime = downloaded.mimeType
        }
        guard !data.isEmpty else { throw AloContentToolsError.unreadable }
        let name = attachment.name.isEmpty ? url.lastPathComponent : attachment.name
        mime = Self.mimeType(mime, name: name, isCircle: attachment.isCircleAttachment)
        // A circle is a video: send only its sound, which is a fraction of the size.
        if mime.hasPrefix("video/") {
            guard let sound = await extractSound(from: data, fileExtension: mime == "video/quicktime" ? "mov" : "mp4") else {
                if data.count > maxBytes { throw AloContentToolsError.audioTooLarge }
                throw AloContentToolsError.noAudio
            }
            data = sound
            mime = "audio/mp4"
        }
        guard data.count <= maxBytes else { throw AloContentToolsError.audioTooLarge }
        return (data, mime)
    }

    /// One of the types the server's provider list knows, from what the file says about itself.
    static func mimeType(_ mime: String, name: String, isCircle: Bool) -> String {
        let declared = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        switch declared {
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac": return "audio/mp4"
        case "audio/ogg", "audio/opus", "application/ogg": return "audio/ogg"
        case "audio/webm": return "audio/webm"
        case "audio/mpeg", "audio/mp3": return "audio/mpeg"
        case "audio/wav", "audio/x-wav": return "audio/wav"
        case "video/quicktime": return "video/quicktime"
        case "video/mp4", "video/x-m4v", "video/webm": return declared == "video/webm" ? "video/webm" : "video/mp4"
        default: break
        }
        switch ext {
        case "m4a", "aac": return "audio/mp4"
        case "ogg", "opus": return "audio/ogg"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "webm": return isCircle ? "video/webm" : "audio/webm"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return isCircle ? "video/mp4" : "audio/mp4"
        default: return isCircle ? "video/mp4" : "audio/mp4"
        }
    }

    static func extractSound(from data: Data, fileExtension: String) async -> Data? {
        let directory = FileManager.default.temporaryDirectory
        let source = directory.appendingPathComponent("alo-sound-\(UUID().uuidString).\(fileExtension)")
        let output = directory.appendingPathComponent("alo-sound-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        do { try data.write(to: source, options: .completeFileProtection) } catch { return nil }
        let asset = AVURLAsset(url: source)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        do { try await session.export(to: output, as: .m4a) } catch { return nil }
        return try? Data(contentsOf: output)
    }
}

// MARK: - Fixture

/// Canned answers for UI tests and screenshots (debug builds with the messenger preview only): they say so in their text and are never
/// reachable in a normal run.
struct AloContentToolsFixtureTransport: AloContentToolsTransport {
    static let transcript = "Привет! Это пример расшифровки голосового сообщения. Встречаемся в шесть у набережной, возьми, пожалуйста, термос."
    static let languages: [AloContentLanguage] = [
        AloContentLanguage(code: "ru", name: "Русский", english: "Russian"),
        AloContentLanguage(code: "en", name: "English", english: "English"),
        AloContentLanguage(code: "de", name: "Deutsch", english: "German"),
        AloContentLanguage(code: "es", name: "Español", english: "Spanish"),
        AloContentLanguage(code: "fr", name: "Français", english: "French")
    ]
    private static let english: [String: String] = [
        "Привет! Посмотрел фотографии с поездки?": "Hi! Did you look at the photos from the trip?",
        "Да, очень красиво. Особенно тот кадр у озера.": "Yes, very beautiful. Especially that shot by the lake.",
        "Договорились. Возьму кофе с собой ☕️": "Agreed. I'll bring coffee ☕️"
    ]

    var needsAudio: Bool { false }
    func capabilities() async throws -> AloContentToolsCapabilities {
        AloContentToolsCapabilities(translation: true, transcription: true, languages: Self.languages)
    }

    func translate(conversation: AloConversationDetail, messageId: Int, text: String, target: String) async throws -> AloMessageTranslation {
        try await Task.sleep(for: .milliseconds(600))
        let translated = target == "en" ? (Self.english[text] ?? "[English] \(text)") : "[\(target.uppercased())] \(text)"
        return AloMessageTranslation(["text": translated, "sourceLanguage": "ru", "targetLanguage": target])
    }

    func transcribe(conversation: AloConversationDetail, messageId: Int, audio: Data, mimeType: String,
                    attachmentId: String) async throws -> AloVoiceTranscription {
        try await Task.sleep(for: .milliseconds(900))
        return AloVoiceTranscription(["text": Self.transcript, "language": "ru"])
    }
}
