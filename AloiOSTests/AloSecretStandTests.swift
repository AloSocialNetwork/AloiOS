import AVFoundation
import Foundation
import Testing
import UIKit
@testable import AloiOS

/// The iPhone side of voice messages and circles in SECRET chats on the cross-client stand (`~/alo/tools/cross-client-check`,
/// P2 of docs/qa/test-run-2026-10-26.md). It uses the app's own code: the recorder's drafts are sealed for the one device at
/// the other end exactly as «Отправить» in the secret chat does it, and received files are opened the way the voice bubble
/// and the circle open them (the length, the first frame of the circle).
///
/// One step per run, chosen by `ALO_SECRET_STAND_STEP` (run with `TEST_RUNNER_…`):
///   connect  accepts the secret-chat requests waiting for this device, starts one with every person in `ALO_SECRET_STAND_START`
///   send     sends a recorded voice message (voice.m4a) and circle (circle.mp4) to every person in `ALO_SECRET_STAND_PEERS`
///   read     checks what the people in `ALO_SECRET_STAND_PEERS` sent; writes `ios-secret-reads.json` to `ALO_STAND_OUT`
/// Skipped unless `ALO_STAND_STATE`, `ALO_STAND_MEDIA` and `ALO_SECRET_STAND_STEP` are set.
private let standEnvironment = ProcessInfo.processInfo.environment

private struct AloSecretStandPerson: Decodable { let id: Int; let token: String; let name: String }
private struct AloSecretStandState: Decodable {
    let url: String
    let web: AloSecretStandPerson
    let ios: AloSecretStandPerson
    let android: AloSecretStandPerson
}

@Suite(.serialized, .enabled(if: standEnvironment["ALO_STAND_STATE"] != nil && standEnvironment["ALO_STAND_MEDIA"] != nil
    && standEnvironment["ALO_SECRET_STAND_STEP"] != nil))
struct AloSecretStandTests {
    private func load() async throws -> (AloSecretStandState, URL, AloAPIClient) {
        let data = try Data(contentsOf: URL(fileURLWithPath: try #require(standEnvironment["ALO_STAND_STATE"])))
        let state = try JSONDecoder().decode(AloSecretStandState.self, from: data)
        let url = try #require(URL(string: state.url))
        let client = AloAPIClient(baseURLs: [url])
        client.messagingPolicyCache.forget()
        let cookie = try #require(HTTPCookie(properties: [.domain: url.host ?? "127.0.0.1", .path: "/", .name: "alo_session", .value: state.ios.token]))
        client.replaceSessionCookies([cookie])
        _ = try await client.loadBootstrap()
        _ = await client.messagingPolicy(refresh: true)
        // The libsignal device registers itself at sign-in; give it a moment on a fresh simulator.
        for _ in 0..<40 where !(await client.secretChatsAvailable()) {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        #expect(await client.secretChatsAvailable())
        return (state, URL(fileURLWithPath: try #require(standEnvironment["ALO_STAND_MEDIA"])), client)
    }

    private func people(_ key: String, _ state: AloSecretStandState) -> [(key: String, id: Int)] {
        (standEnvironment[key] ?? "").split(separator: ",").map(String.init).compactMap { name in
            switch name {
            case "web": return (name, state.web.id)
            case "android": return (name, state.android.id)
            default: return nil
            }
        }
    }

    @Test @MainActor func secretVoiceAndCircleStep() async throws {
        let (state, media, client) = try await load()
        let chats = try await client.loadSecretChats()
        func active(with peer: Int) -> AloSecretChat? {
            chats.first { $0.peerUserId == peer && $0.isActive }
        }
        switch standEnvironment["ALO_SECRET_STAND_STEP"] ?? "" {
        case "connect":
            for request in chats where request.isIncomingRequest {
                let accepted = try await client.acceptSecretChat(id: request.id)
                #expect(accepted.isActive)
            }
            for (_, peer) in people("ALO_SECRET_STAND_START", state) where active(with: peer) == nil {
                let started = try await client.startSecretChat(peerUserId: peer)
                #expect(started.isWaiting || started.isActive)
            }
        case "send":
            let waveform: [CGFloat] = (0..<28).map { 0.15 + 0.8 * abs(sin(CGFloat($0) / 2.5)) }
            for (key, peer) in people("ALO_SECRET_STAND_PEERS", state) {
                let chat = try #require(active(with: peer), "an active secret chat with \(key)")
                // The recorder's drafts, as ChatAudioRecorder and ChatCircleRecorder leave them.
                let voice = try await Task.detached {
                    try AloDraftAttachmentStore.makeRecordedVoice(sourceURL: media.appendingPathComponent("voice.m4a"), waveform: waveform, durationSeconds: 4)
                }.value
                let circle = try await Task.detached {
                    try AloDraftAttachmentStore.makeRecordedCircle(sourceURL: media.appendingPathComponent("circle.mp4"), durationSeconds: 3)
                }.value
                defer { [voice, circle].forEach(AloDraftAttachmentStore.discard) }
                #expect(AloSecretChatView.isRecording(voice) && AloSecretChatView.isRecording(circle))
                for draft in [voice, circle] {
                    let sent = try await client.sendSecretMessage(chat: chat, text: "", drafts: [draft],
                                                                  selfDestructSeconds: AloSecretTimers.secondsForNewMessage(chat))
                    // The sender reads its own message back from its sealed copy, with the same description.
                    let attachment = try #require(sent.attachments.first)
                    #expect(draft.type == "circle" ? attachment.type == "circle" : attachment.type == "voice")
                    #expect(attachment.durationSeconds != nil)
                }
            }
        case "read":
            var report: [String: Any] = [:]
            for (key, peer) in people("ALO_SECRET_STAND_PEERS", state) {
                let chat = try #require(active(with: peer), "an active secret chat with \(key)")
                let messages = try await client.loadSecretMessages(id: chat.id).messages.filter { $0.senderUserId == peer }
                var rows = [[String: Any]]()
                for message in messages {
                    for attachment in message.attachments {
                        var row: [String: Any] = [
                            "messageId": message.id, "type": attachment.type, "name": attachment.name,
                            "voice": attachment.isVoiceAttachment, "circle": attachment.isCircleAttachment,
                            "waveform": attachment.waveform.count, "metadataDuration": attachment.metadata["durationSeconds"] ?? "",
                            "mime": attachment.mediaEncryption["mime"] ?? ""
                        ]
                        // Opened the way the bubbles open it: decrypted on demand from the sealed file.
                        row["urlScheme"] = URL(string: attachment.url)?.scheme ?? ""
                        row["encryption"] = attachment.mediaEncryption.keys.sorted().joined(separator: ",")
                        if let url = client.absoluteURL(attachment.url) {
                            do {
                                try await AloSecureMediaStore.shared.ensureAvailable(url, intent: .userInitiated)
                            } catch {
                                row["fetchError"] = String(describing: error)
                            }
                            let asset = AloSecureMediaStore.shared.makeAsset(url: url, intent: .userInitiated)
                            row["playable"] = (try? await asset.load(.isPlayable)) ?? false
                            row["assetDuration"] = (try? await asset.load(.duration))?.seconds ?? 0
                            if attachment.isCircleAttachment {
                                let preview = await AloMediaPreviewCache.shared.preview(url: url, video: true)
                                row["firstFrame"] = preview.image != nil
                                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                                   let size = try? await track.load(.naturalSize) {
                                    row["width"] = Int(size.width)
                                    row["height"] = Int(size.height)
                                }
                            }
                        }
                        rows.append(row)
                    }
                }
                report[key] = rows
                let voices = rows.filter { $0["voice"] as? Bool == true && $0["circle"] as? Bool != true }
                let circles = rows.filter { $0["circle"] as? Bool == true }
                #expect(!voices.isEmpty, "a voice message from \(key)")
                #expect(!circles.isEmpty, "a circle from \(key)")
                for voice in voices {
                    #expect(voice["type"] as? String == "voice", "\(key) voice type")
                    #expect((voice["waveform"] as? Int ?? 0) > 0, "\(key) voice bars")
                    #expect(Double(voice["metadataDuration"] as? String ?? "") ?? 0 > 0, "\(key) voice length")
                    #expect(voice["playable"] as? Bool == true, "\(key) voice plays")
                }
                for circle in circles {
                    #expect(circle["type"] as? String == "circle", "\(key) circle type")
                    #expect(Double(circle["metadataDuration"] as? String ?? "") ?? 0 > 0, "\(key) circle length")
                    #expect(circle["firstFrame"] as? Bool == true, "\(key) circle first frame")
                    #expect(circle["playable"] as? Bool == true, "\(key) circle plays")
                    #expect(circle["width"] as? Int == circle["height"] as? Int, "\(key) circle is square")
                }
            }
            if let out = standEnvironment["ALO_STAND_OUT"] {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("ios-secret-reads.json"))
            }
        default:
            Issue.record("unknown ALO_SECRET_STAND_STEP")
        }
    }
}
