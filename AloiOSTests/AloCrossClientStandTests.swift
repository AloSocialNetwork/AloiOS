import Foundation
import Testing
import UIKit
@testable import AloiOS

/// The iPhone side of the cross-client stand (`~/alo/tools/cross-client-check`): the iPhone person sends every kind of
/// message with the app's own upload and send code (the path a tap on «Отправить» takes in a cloud chat), and reads what
/// the website and Android people sent the way the chat does. Skipped unless `ALO_STAND_STATE` (stand-state.json) and
/// `ALO_STAND_MEDIA` (voice.m4a, circle.mp4, video.mp4, photo.jpg, notes.txt) are set; run with `TEST_RUNNER_ALO_STAND_…`.
/// `ALO_STAND_OUT` receives `ios-reads.json`.
private let standEnvironment = ProcessInfo.processInfo.environment

private struct AloStandPerson: Decodable { let id: Int; let token: String; let name: String }
private struct AloStandRoom: Decodable { let id: Int; let peerId: Int }
private struct AloStandGroup: Decodable { let room: AloStandRoom }
private struct AloStandState: Decodable {
    let url: String
    let web: AloStandPerson
    let ios: AloStandPerson
    let android: AloStandPerson
    let group: AloStandGroup
}

@Suite(.serialized, .enabled(if: standEnvironment["ALO_STAND_STATE"] != nil && standEnvironment["ALO_STAND_MEDIA"] != nil))
struct AloCrossClientStandTests {
    private func load() throws -> (AloStandState, URL, AloAPIClient) {
        let data = try Data(contentsOf: URL(fileURLWithPath: try #require(standEnvironment["ALO_STAND_STATE"])))
        let state = try JSONDecoder().decode(AloStandState.self, from: data)
        let url = try #require(URL(string: state.url))
        let client = AloAPIClient(baseURLs: [url])
        client.messagingPolicyCache.forget()
        let cookie = try #require(HTTPCookie(properties: [.domain: url.host ?? "127.0.0.1", .path: "/", .name: "alo_session", .value: state.ios.token]))
        client.replaceSessionCookies([cookie])
        return (state, URL(fileURLWithPath: try #require(standEnvironment["ALO_STAND_MEDIA"])), client)
    }

    @Test @MainActor func iphoneSendsEveryKindToEveryone() async throws {
        let (state, media, client) = try load()
        _ = try await client.loadBootstrap()
        #expect(await client.messagingPolicy(refresh: true).isCloudEverywhere)
        let targets = (standEnvironment["ALO_STAND_TARGETS"] ?? "web,android,group").split(separator: ",").map(String.init)
        let run = String(UUID().uuidString.prefix(6)).lowercased()
        // A recording has a waveform the way the recorder makes it: 0…1 levels.
        let waveform: [CGFloat] = (0..<40).map { 0.15 + 0.8 * abs(sin(CGFloat($0) / 3)) }
        for target in targets {
            let peerId: Int, roomId: Int, kind: String
            switch target {
            case "web": (peerId, roomId, kind) = (state.web.id, 0, "direct")
            case "android": (peerId, roomId, kind) = (state.android.id, 0, "direct")
            default: (peerId, roomId, kind) = (0, state.group.room.id, "group")
            }
            func send(_ body: String, _ attachments: [AloMessageAttachment] = [], _ tag: String) async throws {
                let ack = try await client.sendCloudMessage(AloCloudSendRequest(
                    peerId: peerId, roomId: roomId, kind: kind, body: body, attachments: attachments,
                    clientMessageId: "ios-stand-\(run)-\(target)-\(tag)"))
                #expect(ack.messageId > 0, "\(target) \(tag)")
            }
            try await send("Айфон → \(target): **жирный** __курсив__ и обычный", [], "text")

            let voiceDraft = try await Task.detached {
                try AloDraftAttachmentStore.makeRecordedVoice(sourceURL: media.appendingPathComponent("voice.m4a"), waveform: waveform, durationSeconds: 4)
            }.value
            let circleDraft = try await Task.detached {
                try AloDraftAttachmentStore.makeRecordedCircle(sourceURL: media.appendingPathComponent("circle.mp4"), durationSeconds: 3)
            }.value
            let photoDraft = try await Task.detached {
                try AloDraftAttachmentStore.makePickedMedia(sourceURL: media.appendingPathComponent("photo.jpg"), mime: "image/jpeg", type: "image", name: "photo.jpg")
            }.value
            // The same steps as a video picked in the chat (MessagesView.makeEncryptedDraftAttachment): its size goes with it.
            let videoDraft = try await Task.detached {
                let source = media.appendingPathComponent("video.mp4")
                let dimensions = await AloMediaDimensions.video(sourceURL: source)
                return try AloDraftAttachmentStore.makePickedVideo(sourceURL: source, mime: "video/mp4", name: "video.mp4")
                    .withMediaDimensions(dimensions)
            }.value
            let fileDraft = AloLocalAttachment(data: try Data(contentsOf: media.appendingPathComponent("notes.txt")), mime: "text/plain", type: "file", name: "notes.txt")
            defer { [voiceDraft, circleDraft, photoDraft, videoDraft].forEach(AloDraftAttachmentStore.discard) }
            for (tag, draft) in [("voice", voiceDraft), ("circle", circleDraft), ("photo", photoDraft), ("video", videoDraft), ("file", fileDraft)] {
                let uploaded = try await client.uploadMessageAttachment(draft, cloud: true)
                try await send("", [uploaded], tag)
            }
        }
    }

    /// What the iPhone makes of the other people's messages: the same checks the chat bubble uses.
    @Test @MainActor func iphoneReadsWhatOthersSent() async throws {
        let (state, _, client) = try load()
        _ = try await client.loadBootstrap()
        var report: [String: Any] = [:]
        for (key, peerId) in [("web", state.web.id), ("android", state.android.id), ("group", state.group.room.peerId)] {
            let history = try await client.loadConversation(peerId: peerId)
            report[key] = history.items.filter { $0.senderId != state.ios.id }.map { message -> [String: Any] in
                [
                    "id": message.id,
                    "senderId": message.senderId,
                    "body": String(message.body.prefix(40)),
                    "cloud": message.isCloud,
                    "attachments": message.attachments.map { attachment -> [String: Any] in
                        [
                            "type": attachment.type,
                            "name": attachment.name,
                            "url": String(attachment.url.prefix(80)),
                            "voice": attachment.isVoiceAttachment,
                            "circle": attachment.isCircleAttachment,
                            "waveform": attachment.waveform.count,
                            "duration": attachment.durationSeconds ?? -1
                        ]
                    }
                ]
            }
        }
        if let out = standEnvironment["ALO_STAND_OUT"] {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("ios-reads.json"))
        }
    }
}
