import Foundation

/// Metadata and ciphertext are kept separately; a snapshot never contains a
/// base64 movie or a plaintext path. The same codec is used by drafts and jobs.
enum AloDurableAttachment {
    static func fileID(_ attachment: AloLocalAttachment, prefix: String) -> String {
        "\(prefix)-\(attachment.id.uuidString)"
    }

    static func record(_ attachment: AloLocalAttachment, prefix: String) -> [String: Any] {
        var value: [String: Any] = ["id": attachment.id.uuidString,
            "fileId": fileID(attachment, prefix: prefix), "mime": attachment.mime,
            "type": attachment.type, "name": attachment.name,
            "waveform": attachment.waveform.map(Double.init)]
        value["durationSeconds"] = attachment.durationSeconds
        value["mediaDimensions"] = attachment.mediaDimensions?.metadata
        if attachment.encryptedSourceURL != nil {
            value["chunked"] = true
            value["encryption"] = attachment.mediaEncryption
            value["checksum"] = attachment.encryptedChecksum
        }
        return value
    }

    static func restore(_ record: [String: Any], owner: Int) -> AloLocalAttachment? {
        guard let id = UUID(uuidString: record.string("id")) else { return nil }
        let store = AloSecureOutboxStore.shared
        let chunked = record.bool("chunked")
        let source = chunked ? store.loadChunkedAttachmentURL(id: record.string("fileId"), ownerUserId: owner) : nil
        let data = chunked ? Data() : store.loadAttachment(id: record.string("fileId"), ownerUserId: owner)
        guard let data, !chunked || source != nil else { return nil }
        let encryption = record.object("encryption").compactMapValues { $0 as? String }
        if chunked, AloChunkedMediaCrypto.Metadata(encryption) == nil { return nil }
        return AloLocalAttachment(data: data, mime: record.string("mime"), type: record.string("type"),
            name: record.string("name"), waveform: (record["waveform"] as? [NSNumber] ?? []).map { CGFloat($0.doubleValue) },
            encryptedSourceURL: source, mediaEncryption: encryption, encryptedChecksum: record.string("checksum"),
            durationSeconds: (record["durationSeconds"] as? NSNumber)?.doubleValue,
            mediaDimensions: AloMediaDimensions(record.object("mediaDimensions").compactMapValues { $0 as? String }), id: id)
    }

    static func preparingPreview(_ attachment: AloLocalAttachment) -> AloLocalAttachment {
        guard attachment.encryptedSourceURL != nil, attachment.localPlaybackURL == nil else { return attachment }
        // Only the opened chat prepares a resource-loader preview, never every
        // draft/video in the account during startup.
        let playback = try? AloSecureMediaStore.shared.registerDraft(attachment)
        return AloLocalAttachment(data: attachment.data, mime: attachment.mime, type: attachment.type, name: attachment.name,
            waveform: attachment.waveform, encryptedSourceURL: attachment.encryptedSourceURL,
            mediaEncryption: attachment.mediaEncryption, encryptedChecksum: attachment.encryptedChecksum,
            localPlaybackURL: playback, durationSeconds: attachment.durationSeconds,
            mediaDimensions: attachment.mediaDimensions, id: attachment.id)
    }
}

struct AloChatDraft: Equatable {
    var text = ""
    var reply: AloChatMessage?
    var forward: AloForwardMeta?
    var forwardTitle = ""
    var attachments = [AloLocalAttachment]()
    var selfDestructSeconds = 0
    var missingAttachments = false

    var isEmpty: Bool { text.isEmpty && reply == nil && forward == nil && attachments.isEmpty && !missingAttachments }

    func record(key: String) -> [String: Any] {
        var value: [String: Any] = ["key": key, "text": text, "forwardTitle": forwardTitle,
            "attachments": attachments.map { AloDurableAttachment.record($0, prefix: "draft") },
            "selfDestructSeconds": selfDestructSeconds, "missingAttachments": missingAttachments]
        if let reply {
            var snapshot: [String: Any] = ["id": reply.id, "senderId": reply.senderId,
                "body": reply.markupSource, "attachmentType": reply.attachmentType,
                "attachmentName": reply.attachmentName]
            if let sender = reply.sender {
                snapshot["sender"] = ["id": sender.id, "name": sender.name, "username": sender.username]
            }
            // Preview only; reply IDs, not a stale copy, are sent to the server.
            snapshot["attachments"] = reply.attachments.map { ["type": $0.type, "url": $0.url, "name": $0.name] }
            value["reply"] = snapshot
        }
        if let forward { value["forward"] = ["userId": forward.userId, "messageId": forward.messageId] }
        return value
    }

    init() {}
    init(record: [String: Any], owner: Int) {
        text = record.string("text")
        reply = record.optionalObject("reply").map(AloChatMessage.init)
        forward = record.optionalObject("forward").flatMap(AloForwardMeta.init)
        forwardTitle = record.string("forwardTitle")
        let files = record.array("attachments")
        attachments = files.compactMap { AloDurableAttachment.restore($0, owner: owner) }
        missingAttachments = record.bool("missingAttachments") || attachments.count != files.count
        selfDestructSeconds = max(0, record.int("selfDestructSeconds"))
    }
}
