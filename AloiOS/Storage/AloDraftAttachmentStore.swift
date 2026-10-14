import Foundation

/// Stores compose drafts as chunk-encrypted files before an upload starts.
/// This keeps an offline draft private without retaining a multi-gigabyte
/// plaintext `Data` value in memory.
enum AloDraftAttachmentStore {
    /// Run on the capture worker. Both upload and playback stay file-backed;
    /// the main actor only receives lightweight metadata, not the whole movie.
    static func makeRecordedCircle(sourceURL: URL, durationSeconds: Double? = nil) throws -> AloLocalAttachment {
        try makeRecordedMedia(sourceURL: sourceURL, mime: "video/mp4", type: "circle",
            name: "circle-\(UUID().uuidString).mp4", waveform: [], durationSeconds: durationSeconds)
    }

    static func makeRecordedVoice(sourceURL: URL, waveform: [CGFloat], durationSeconds: Double?) throws -> AloLocalAttachment {
        try makeRecordedMedia(sourceURL: sourceURL, mime: "audio/mp4", type: "audio",
            name: "voice-\(UUID().uuidString).m4a", waveform: waveform, durationSeconds: durationSeconds)
    }

    static func makePickedVideo(sourceURL: URL, mime: String, name: String) throws -> AloLocalAttachment {
        try makeRecordedMedia(sourceURL: sourceURL, mime: mime, type: "video",
            name: name, waveform: [], durationSeconds: nil)
    }

    static func makePickedMedia(sourceURL: URL, mime: String, type: String, name: String) throws -> AloLocalAttachment {
        try makeRecordedMedia(sourceURL: sourceURL, mime: mime, type: type,
            name: name, waveform: [], durationSeconds: nil)
    }

    /// Compatibility for Photos providers without a file representation. The
    /// transient plaintext source is protected and removed on the same worker.
    static func makePickedMedia(data: Data, mime: String, type: String, name: String) throws -> AloLocalAttachment {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("alo-import-\(UUID().uuidString)")
        try data.write(to: source, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: source) }
        return try makePickedMedia(sourceURL: source, mime: mime, type: type, name: name)
    }

    private static func makeRecordedMedia(sourceURL: URL, mime: String, type: String,
        name: String, waveform: [CGFloat], durationSeconds: Double?) throws -> AloLocalAttachment {
        let draft = try makeEncryptedAttachment(sourceURL: sourceURL,
            mime: mime, type: type, name: name, waveform: waveform)
        do {
            let playbackURL = try AloSecureMediaStore.shared.registerDraft(draft)
            return AloLocalAttachment(data: Data(), mime: draft.mime, type: draft.type, name: draft.name, waveform: waveform,
                encryptedSourceURL: draft.encryptedSourceURL, mediaEncryption: draft.mediaEncryption,
                encryptedChecksum: draft.encryptedChecksum, localPlaybackURL: playbackURL, durationSeconds: durationSeconds,
                mediaDimensions: type == "image" ? AloMediaDimensions.image(sourceURL: sourceURL) : nil)
        } catch {
            remove(draft)
            throw error
        }
    }

    static func makeEncryptedAttachment(
        sourceURL: URL,
        mime: String,
        type: String,
        name: String,
        waveform: [CGFloat] = [],
        previewData: Data = Data()
    ) throws -> AloLocalAttachment {
        let root = try draftRoot()
        let destination = root.appendingPathComponent("\(UUID().uuidString).bin")
        let sealed = try AloChunkedMediaCrypto.encrypt(
            sourceURL: sourceURL,
            destinationURL: destination,
            mime: mime
        )
        try markPrivate(destination)
        return AloLocalAttachment(
            data: previewData,
            mime: mime,
            type: type,
            name: name,
            waveform: waveform,
            encryptedSourceURL: sealed.encryptedURL,
            mediaEncryption: sealed.metadata.dictionary.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = String(describing: pair.value)
            },
            encryptedChecksum: sealed.sha256
        )
    }

    static func remove(_ attachment: AloLocalAttachment) {
        guard let url = attachment.encryptedSourceURL else { return }
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let root = try? draftRoot() else { return }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard canonicalURL.path.hasPrefix(prefix) else { return }
        try? FileManager.default.removeItem(at: canonicalURL)
    }

    /// Only for an abandoned, unsent draft. Sent/pending messages may still use
    /// their cached playback URL, so normal upload cleanup calls `remove` instead.
    static func discard(_ attachment: AloLocalAttachment) {
        remove(attachment)
        if let playback = attachment.localPlaybackURL {
            AloSecureMediaStore.shared.remove(urls: [playback])
        }
    }

    static func cleanupExpiredDrafts(now: Date = Date()) {
        guard let root = try? draftRoot(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
              ) else { return }
        let deadline = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified < deadline else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func draftRoot() throws -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? FileManager.default.temporaryDirectory
        let root = applicationSupport
            .appendingPathComponent("AloE2EEMedia", isDirectory: true)
            .appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try markPrivate(root)
        return root
    }

    private static func markPrivate(_ url: URL) throws {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedURL.setResourceValues(values)
    }
}
