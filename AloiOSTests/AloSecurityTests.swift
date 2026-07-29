import CryptoKit
import XCTest
@testable import AloiOS

final class AloSecurityTests: XCTestCase {
    func testCertificatePinAcceptsBase64AndHexSHA256() {
        let bytes = Data(0..<32)
        let base64 = "sha256/\(bytes.base64EncodedString())"
        let hex = bytes.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(AloCertificatePinningDelegate.decodePin(base64), bytes)
        XCTAssertEqual(AloCertificatePinningDelegate.decodePin(hex), bytes)
        XCTAssertNil(AloCertificatePinningDelegate.decodePin("sha1/not-a-pin"))
    }

    func testCallSafetyEmojisAreSymmetricForParticipants() {
        let left = AloCallSecurity.emojis(
            callId: 42,
            ownerUserId: 7,
            peerId: 19,
            secret: "test-secret"
        )
        let right = AloCallSecurity.emojis(
            callId: 42,
            ownerUserId: 19,
            peerId: 7,
            secret: "test-secret"
        )

        XCTAssertEqual(left, right)
        XCTAssertEqual(left.count, 4)
    }

    func testCallUUIDIsStableAndUniquePerCall() {
        XCTAssertEqual(
            AloCallSecurity.callUUID(callId: 100),
            AloCallSecurity.callUUID(callId: 100)
        )
        XCTAssertNotEqual(
            AloCallSecurity.callUUID(callId: 100),
            AloCallSecurity.callUUID(callId: 101)
        )
    }

    func testCallToneWaveformsAreValidAndDistinct() {
        let ringback = AloCallToneWaveform.wavData(for: .ringback)
        let noAnswer = AloCallToneWaveform.wavData(for: .noAnswer)
        let failed = AloCallToneWaveform.wavData(for: .failed)

        XCTAssertEqual(String(data: ringback.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: ringback.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        XCTAssertGreaterThan(ringback.count, 44)
        XCTAssertGreaterThan(noAnswer.count, 44)
        XCTAssertNotEqual(ringback, noAnswer)
        XCTAssertNotEqual(ringback, failed)
    }

    func testOnlyCompletedCallPhasesAreTerminal() {
        XCTAssertFalse(AloDirectCallPhase.outgoing.isTerminal)
        XCTAssertFalse(AloDirectCallPhase.reconnecting.isTerminal)
        XCTAssertFalse(AloDirectCallPhase.active.isTerminal)
        XCTAssertTrue(AloDirectCallPhase.noAnswer.isTerminal)
        XCTAssertTrue(AloDirectCallPhase.interrupted.isTerminal)
        XCTAssertTrue(AloDirectCallPhase.busy.isTerminal)
        XCTAssertTrue(AloDirectCallPhase.declined.isTerminal)
    }

    func testCallKitIsDisabledInSimulator() {
#if targetEnvironment(simulator)
        XCTAssertFalse(AloCallKitSupport.isAvailable)
#else
        XCTAssertTrue(AloCallKitSupport.isAvailable)
#endif
    }

    func testDebugBuildDoesNotRequirePushEntitlement() {
#if DEBUG && !ALO_PUSH_NOTIFICATIONS
        XCTAssertFalse(AloPushAvailability.isEnabled)
#else
        XCTAssertTrue(AloPushAvailability.isEnabled)
#endif
    }

    func testPendingDeleteTombstonesHideServerMessagesUntilAcknowledged() {
        let messages = [
            AloChatMessage(
                localId: 101,
                senderId: 1,
                recipientId: 2,
                body: "keep",
                createdAt: "2026-07-28T10:00:00Z"
            ),
            AloChatMessage(
                localId: 102,
                senderId: 1,
                recipientId: 2,
                body: "delete offline",
                createdAt: "2026-07-28T10:01:00Z"
            )
        ]

        let visible = AloPendingChatProjection.removingDeletedMessages(
            from: messages,
            deletedMessageIds: [102]
        )

        XCTAssertEqual(visible.map(\.id), [101])
    }

    func testPendingMessageSurvivesConversationReopenBeforeAcknowledgement() {
        let serverMessage = AloChatMessage(
            localId: 101,
            senderId: 2,
            recipientId: 1,
            body: "server",
            createdAt: "2026-07-28T10:00:00Z"
        )
        let pendingMessage = AloChatMessage(
            localId: -1,
            senderId: 1,
            recipientId: 2,
            body: "still sending",
            createdAt: "2026-07-28T10:01:00Z"
        )

        let reopened = AloPendingChatProjection.mergingPendingMessages(
            serverMessages: [serverMessage],
            pendingMessages: [pendingMessage]
        )

        XCTAssertEqual(reopened.map(\.id), [101, -1])
        XCTAssertEqual(reopened.last?.body, "still sending")
    }

    func testSecureMediaRemainsEncryptedOnDiskAndDecryptsInMemory() throws {
        let store = AloSecureMediaStore.shared
        store.clearCache()
        defer { store.clearCache() }

        let plaintext = Data("encrypted media test payload".utf8)
        let keyData = Data((0..<32).map(UInt8.init))
        let nonceData = Data((32..<44).map(UInt8.init))
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: try AES.GCM.Nonce(data: nonceData)
        )
        let encrypted = sealed.ciphertext + sealed.tag
        let encryptedURL = try AloSecureMediaStore.encryptedCacheFileForTesting(
            named: "secure-media-test.bin"
        )
        try encrypted.write(to: encryptedURL, options: .atomic)

        let secureURL = try store.register(
            encryptedURL: encryptedURL,
            encryption: [
                "algorithm": "aes-256-gcm-v1",
                "key": base64URL(keyData),
                "iv": base64URL(nonceData),
                "mime": "application/octet-stream"
            ],
            type: "file",
            name: "payload.bin"
        )
        let payload = try store.payload(for: secureURL)

        XCTAssertEqual(payload.data, plaintext)
        XCTAssertEqual(payload.mime, "application/octet-stream")
        XCTAssertEqual(payload.name, "payload.bin")
        XCTAssertEqual(try Data(contentsOf: encryptedURL), encrypted)
        XCTAssertNotEqual(try Data(contentsOf: encryptedURL), plaintext)
    }

    func testCallMinimizesAfterVerticalSwipeInEitherDirection() {
        XCTAssertTrue(
            AloCallMinimizePolicy.shouldMinimize(
                translation: -560,
                predictedTranslation: -590,
                viewportHeight: 874
            )
        )
        XCTAssertTrue(
            AloCallMinimizePolicy.shouldMinimize(
                translation: 560,
                predictedTranslation: 590,
                viewportHeight: 874
            )
        )
        XCTAssertEqual(
            AloCallMinimizePolicy.direction(
                translation: -96,
                predictedTranslation: -140
            ),
            -1
        )
        XCTAssertEqual(
            AloCallMinimizePolicy.direction(
                translation: 96,
                predictedTranslation: 140
            ),
            1
        )
    }

    func testCallReturnsAfterShortVerticalDrag() {
        XCTAssertFalse(
            AloCallMinimizePolicy.shouldMinimize(
                translation: 42,
                predictedTranslation: 78,
                viewportHeight: 874
            )
        )
    }

    func testCallMinimizesAfterFastShortSwipe() {
        XCTAssertTrue(
            AloCallMinimizePolicy.shouldMinimize(
                translation: 48,
                predictedTranslation: 180,
                viewportHeight: 874
            )
        )
    }

    func testOutgoingVideoKeepsIdentityAndUsesLocalPreview() {
        let layout = AloCallVideoLayout.resolve(
            phase: .outgoing,
            hasLocalVideo: true,
            hasRemoteVideo: false,
            prefersLocalPrimary: false
        )

        XCTAssertFalse(layout.showsPrimaryVideo)
        XCTAssertTrue(layout.showsIdentity)
        XCTAssertTrue(layout.showsPreview)
        XCTAssertTrue(layout.previewIsLocal)
    }

    func testAnsweredVideoUsesRemotePrimaryAndLocalPreview() {
        let layout = AloCallVideoLayout.resolve(
            phase: .active,
            hasLocalVideo: true,
            hasRemoteVideo: true,
            prefersLocalPrimary: false
        )

        XCTAssertTrue(layout.showsPrimaryVideo)
        XCTAssertFalse(layout.primaryIsLocal)
        XCTAssertTrue(layout.showsPreview)
        XCTAssertTrue(layout.previewIsLocal)
    }

    func testVideoPreviewTapCanSwapLocalAndRemoteSurfaces() {
        let layout = AloCallVideoLayout.resolve(
            phase: .active,
            hasLocalVideo: true,
            hasRemoteVideo: true,
            prefersLocalPrimary: true
        )

        XCTAssertTrue(layout.showsPrimaryVideo)
        XCTAssertTrue(layout.primaryIsLocal)
        XCTAssertTrue(layout.showsPreview)
        XCTAssertFalse(layout.previewIsLocal)
    }

    func testLocalScreenShareIsNotRenderedIntoRecursivePreview() {
        let call = AloDirectCallState(
            id: 1,
            uuid: UUID(),
            peer: AloDirectCallPeer(
                id: 2,
                name: "Peer",
                username: "peer",
                avatarURL: "",
                verified: false
            ),
            type: "voice",
            phase: .active,
            isIncoming: false,
            isMuted: false,
            isSpeakerOn: true,
            isVideoEnabled: false,
            isFrontCamera: true,
            isScreenSharing: true,
            startedAt: Date(),
            callSecret: "test",
            safetyEmojis: []
        )
        let layout = AloCallVideoLayout.resolve(
            phase: call.phase,
            hasLocalVideo: call.hasLocalPreviewVideo,
            hasRemoteVideo: call.hasRemoteVideo,
            prefersLocalPrimary: false
        )

        XCTAssertFalse(layout.showsPrimaryVideo)
        XCTAssertFalse(layout.showsPreview)
        XCTAssertTrue(layout.showsIdentity)
    }

    func testKeyboardFollowsFreshlyOpenedConversationBeforeGeometrySettles() {
        XCTAssertTrue(
            ChatKeyboardFollowPolicy.shouldFollow(
                hasUserScrolledConversation: false,
                isNearBottom: false,
                isEmpty: false
            )
        )
    }

    func testKeyboardDoesNotJumpConversationAfterUserScrollsAwayFromBottom() {
        XCTAssertFalse(
            ChatKeyboardFollowPolicy.shouldFollow(
                hasUserScrolledConversation: true,
                isNearBottom: false,
                isEmpty: false
            )
        )
    }

    func testKeyboardResumesFollowingAfterUserReturnsToBottom() {
        XCTAssertTrue(
            ChatKeyboardFollowPolicy.shouldFollow(
                hasUserScrolledConversation: true,
                isNearBottom: true,
                isEmpty: false
            )
        )
    }

    func testCallSecurityV2MatchesCrossPlatformVector() throws {
        let callerPrivate = try AloCallSecurityV2.decode32(
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        )
        let callerPublic = try AloCallSecurityV2.decode32(
            "j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8"
        )
        let callerNonce = try AloCallSecurityV2.decode32(
            "QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8"
        )
        let calleePrivate = try AloCallSecurityV2.decode32(
            "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
        )
        let calleePublic = try AloCallSecurityV2.decode32(
            "NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlQ"
        )
        let calleeNonce = try AloCallSecurityV2.decode32(
            "YGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn8"
        )
        let offerFingerprint =
            "sha-256:000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"
        let answerFingerprint =
            "sha-256:FFFEFDFCFBFAF9F8F7F6F5F4F3F2F1F0EFEEEDECEBEAE9E8E7E6E5E4E3E2E1E0"
        let expectedCommitment = try AloCallSecurityV2.decode32(
            "xbI0QvSBGX95wPCXGfywoYwdZtmqO1DHO-Xp-bclZ0s"
        )
        let expectedSharedKey = try AloCallSecurityV2.decode32(
            "8l9bYSpf_Tgi58t0Y9zBpymN7w1asLa0pzJLCBHOTm0"
        )
        let expectedOfferHash = try AloCallSecurityV2.decode32(
            "6lQ-MOyBdHO-hTLOW7WXL8y3Nuteh_tBIA5sLg5FGRc"
        )
        let expectedTranscript = try AloCallSecurityV2.decode32(
            "KPlidH_3w0qEnZgHzK-_ZVEE1aw76NcqV4lrp0bqsLU"
        )

        let callerSharedKey = try AloCallSecurityV2.sharedKey(
            privateKey: callerPrivate,
            remotePublicKey: calleePublic,
            callId: 4_242,
            callerId: 1_001,
            calleeId: 2_002
        )
        let calleeSharedKey = try AloCallSecurityV2.sharedKey(
            privateKey: calleePrivate,
            remotePublicKey: callerPublic,
            callId: 4_242,
            callerId: 1_001,
            calleeId: 2_002
        )
        XCTAssertEqual(callerSharedKey, expectedSharedKey)
        XCTAssertEqual(calleeSharedKey, expectedSharedKey)

        let commitment = try AloCallSecurityV2.commitment(
            callId: 4_242,
            callerId: 1_001,
            calleeId: 2_002,
            callerPublicKey: callerPublic,
            callerNonce: callerNonce
        )
        XCTAssertEqual(commitment, expectedCommitment)

        let offerHash = try AloCallSecurityV2.offerTranscriptHash(
            callId: 4_242,
            callerId: 1_001,
            calleeId: 2_002,
            callerCommitment: commitment,
            callerPublicKey: callerPublic,
            callerNonce: callerNonce,
            calleePublicKey: calleePublic,
            calleeNonce: calleeNonce,
            offerFingerprint: offerFingerprint
        )
        XCTAssertEqual(offerHash, expectedOfferHash)

        let transcript = try AloCallSecurityV2.transcriptHash(
            callId: 4_242,
            callerId: 1_001,
            calleeId: 2_002,
            callerCommitment: commitment,
            callerPublicKey: callerPublic,
            callerNonce: callerNonce,
            calleePublicKey: calleePublic,
            calleeNonce: calleeNonce,
            offerFingerprint: offerFingerprint,
            answerFingerprint: answerFingerprint
        )
        XCTAssertEqual(transcript, expectedTranscript)
        XCTAssertEqual(
            try AloCallSecurityV2.proof(
                sharedKey: callerSharedKey,
                role: "caller-offer",
                transcriptHash: offerHash
            ),
            try AloCallSecurityV2.decode32("Q5QFKAImnOA2xwhZuvNe1ECV6KVt0XB7C3U-KqmjQic")
        )
        XCTAssertEqual(
            try AloCallSecurityV2.proof(
                sharedKey: callerSharedKey,
                role: "callee-answer",
                transcriptHash: transcript
            ),
            try AloCallSecurityV2.decode32("FrKJVMOqgosWhjaQhQ26OkBfIRGg1BrmjFdv8Ta5wuE")
        )
        XCTAssertEqual(
            try AloCallSecurityV2.proof(
                sharedKey: callerSharedKey,
                role: "caller-confirm",
                transcriptHash: transcript
            ),
            try AloCallSecurityV2.decode32("pAnLZfQVbXyAW70mzRTpO7lR3Y4WLSsw11rkWz5M9_A")
        )
        XCTAssertEqual(
            try AloCallSecurityV2.emojis(
                sharedKey: callerSharedKey,
                transcriptHash: transcript,
                callerPublicKey: callerPublic
            ),
            ["🐟", "🔮", "👭", "🔟"]
        )

        let reconnectOfferSdp =
            "v=0\r\na=fingerprint:sha-256 00:01:02:03:04:05:06:07:08:09:0A:0B:0C:0D:0E:0F:10:11:12:13:14:15:16:17:18:19:1A:1B:1C:1D:1E:1F\r\na=ice-ufrag:restart-a\r\n"
        let reconnectAnswerSdp =
            "v=0\r\na=fingerprint:sha-256 FF:FE:FD:FC:FB:FA:F9:F8:F7:F6:F5:F4:F3:F2:F1:F0:EF:EE:ED:EC:EB:EA:E9:E8:E7:E6:E5:E4:E3:E2:E1:E0\r\na=ice-ufrag:restart-b\r\n"
        let reconnectOfferSdpHash = AloCallSecurityV2.sdpHash(reconnectOfferSdp)
        let reconnectAnswerSdpHash = AloCallSecurityV2.sdpHash(reconnectAnswerSdp)
        XCTAssertEqual(
            reconnectOfferSdpHash,
            try AloCallSecurityV2.decode32("dwxeUu3lzu9NarthkYOSuV2uqdcxYnqFYl_W4EZf8c4")
        )
        XCTAssertEqual(
            reconnectAnswerSdpHash,
            try AloCallSecurityV2.decode32("x56smKHHEFjU-PQV7OzAvn5QiTBatid3gick5IVd2zw")
        )
        let reconnectOfferHash = try AloCallSecurityV2.reconnectTranscriptHash(
            callId: 4_242,
            generation: 3,
            initialTranscriptHash: transcript,
            offerFingerprint: offerFingerprint,
            offerSdpHash: reconnectOfferSdpHash
        )
        XCTAssertEqual(
            reconnectOfferHash,
            try AloCallSecurityV2.decode32("H2jFb_2XmS2bOp7IdoFjlJUBxTo0WPLrn2zPt1FjlYs")
        )
        XCTAssertEqual(
            try AloCallSecurityV2.proof(
                sharedKey: callerSharedKey,
                role: "caller-reconnect-offer",
                transcriptHash: reconnectOfferHash
            ),
            try AloCallSecurityV2.decode32("9fgNPdihS89D1slXcX6aFt58E2NisSdt-XosYIURKSo")
        )
        let reconnectAnswerHash = try AloCallSecurityV2.reconnectTranscriptHash(
            callId: 4_242,
            generation: 3,
            initialTranscriptHash: transcript,
            offerFingerprint: offerFingerprint,
            offerSdpHash: reconnectOfferSdpHash,
            answerFingerprint: answerFingerprint,
            answerSdpHash: reconnectAnswerSdpHash
        )
        XCTAssertEqual(
            reconnectAnswerHash,
            try AloCallSecurityV2.decode32("zGQI93XcERsNX-PLQWX6jN9cMWIfMNP5a-KMR1vQ7mY")
        )
        XCTAssertEqual(
            try AloCallSecurityV2.proof(
                sharedKey: callerSharedKey,
                role: "callee-reconnect-answer",
                transcriptHash: reconnectAnswerHash
            ),
            try AloCallSecurityV2.decode32("HZOTsaSrAdIk9ojsEQ6OEPAeyQilfHLl5GQPL7-42bs")
        )
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
