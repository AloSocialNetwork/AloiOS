import CryptoKit
import XCTest
@testable import AloiOS

final class AloSecurityTests: XCTestCase {
    func testDeepLinksFollowTheSharedCanonicalContract() throws {
        let host = "links.alo.test"
        XCTAssertEqual(
            AloDeepLinkTarget(url: try XCTUnwrap(URL(string: "https://\(host)/p/42")), configuredWebHost: host),
            .post(42)
        )
        XCTAssertEqual(
            AloDeepLinkTarget(url: try XCTUnwrap(URL(string: "https://\(host)/u/7")), configuredWebHost: host),
            .user(7)
        )
        XCTAssertEqual(
            AloDeepLinkTarget(url: try XCTUnwrap(URL(string: "https://\(host)/ch/9")), configuredWebHost: host),
            .channel(9)
        )
        XCTAssertEqual(
            AloDeepLinkTarget(url: try XCTUnwrap(URL(string: "https://\(host)/t/77/13")), configuredWebHost: host),
            .forumTopic(roomId: 77, topicId: 13)
        )
        XCTAssertEqual(
            AloDeepLinkTarget(url: try XCTUnwrap(URL(string: "https://\(host)/public-name")), configuredWebHost: host),
            .handle("public-name")
        )
        XCTAssertEqual(
            AloDeepLinkTarget(url: try XCTUnwrap(URL(string: "alo://r/public_name")), configuredWebHost: host),
            .handle("public_name")
        )
    }

    func testStoryLinksParseOnlyWellFormedCodes() throws {
        let host = "links.alo.test"
        XCTAssertEqual(AloDeepLinkTarget(url: try XCTUnwrap(URL(string: "https://\(host)/s/AbCdEf123_-x")), configuredWebHost: host),
                       .story("AbCdEf123_-x"))
        XCTAssertEqual(AloDeepLinkTarget(url: try XCTUnwrap(URL(string: "alo://s/AbCdEf123456")), configuredWebHost: host),
                       .story("AbCdEf123456"))
        XCTAssertNil(AloDeepLinkTarget(url: try XCTUnwrap(URL(string: "alo://s/short")), configuredWebHost: host))
        XCTAssertNil(AloDeepLinkTarget(url: try XCTUnwrap(URL(string: "alo://s/bad%2Fcode12")), configuredWebHost: host))
        XCTAssertNil(AloDeepLinkTarget(url: try XCTUnwrap(URL(string: "http://\(host)/s/AbCdEf123456")), configuredWebHost: host))
        XCTAssertNotNil(AloDeepLinkTarget.storyURL(code: "AbCdEf123456"))
        XCTAssertNil(AloDeepLinkTarget.storyURL(code: "../../x"))
    }

    func testDeepLinksRejectForeignInsecureAndAmbiguousURLs() throws {
        let host = "links.alo.test"
        XCTAssertNil(AloDeepLinkTarget(
            url: try XCTUnwrap(URL(string: "https://other.test/p/42")),
            configuredWebHost: host
        ))
        XCTAssertNil(AloDeepLinkTarget(
            url: try XCTUnwrap(URL(string: "http://\(host)/p/42")),
            configuredWebHost: host
        ))
        XCTAssertNil(AloDeepLinkTarget(
            url: try XCTUnwrap(URL(string: "https://\(host)/p/42/extra")),
            configuredWebHost: host
        ))
        XCTAssertNil(AloDeepLinkTarget(
            url: try XCTUnwrap(URL(string: "https://\(host)/t/77/not-a-topic")),
            configuredWebHost: host
        ))
    }

    func testContactCardStoresIdentityOnlyInsideEncryptedAttachmentMetadata() {
        let contact = AloEntitySummary(
            id: 41,
            name: "Алексей",
            username: "alex",
            avatarUrl: "https://cdn.example/avatar.jpg",
            verified: true,
            isChannel: false
        )

        let attachment = AloMessageAttachment.contact(contact)

        XCTAssertTrue(attachment.isVirtualCard)
        XCTAssertTrue(attachment.isContactCard)
        XCTAssertEqual(attachment.url, "")
        XCTAssertEqual(attachment.metadata["userId"], "41")
        XCTAssertEqual(attachment.metadata["displayName"], "Алексей")
        XCTAssertEqual(attachment.metadata["verified"], "1")
        XCTAssertTrue(attachment.mediaEncryption.isEmpty)
    }

    func testStaticLocationCardHasNoServerVisibleMediaURL() {
        let attachment = AloMessageAttachment.location(latitude: 55.755826, longitude: 37.6173)

        XCTAssertTrue(attachment.isVirtualCard)
        XCTAssertTrue(attachment.isLocationCard)
        XCTAssertEqual(attachment.url, "")
        XCTAssertEqual(attachment.metadata["latitude"], "55.75583")
        XCTAssertEqual(attachment.metadata["longitude"], "37.61730")
        XCTAssertTrue(attachment.mediaEncryption.isEmpty)
    }

    func testGroupCallPeerToPeerFallbackSupportsOnlyOneToOneAudio() {
        XCTAssertTrue(AloGroupCallAudioPolicy.canUsePeerToPeerFallback(participantCount: 1))
        XCTAssertTrue(AloGroupCallAudioPolicy.canUsePeerToPeerFallback(participantCount: 2))
        XCTAssertFalse(AloGroupCallAudioPolicy.canUsePeerToPeerFallback(participantCount: 0))
        XCTAssertFalse(AloGroupCallAudioPolicy.canUsePeerToPeerFallback(participantCount: 3))
    }

    func testBlockedUsersDecodeCurrentEndpointPayload() {
        let userIds = AloBlockedUserList.userIds(from: [
            "blocks": [
                ["userId": 17],
                ["user": ["id": 42]],
                ["id": 73]
            ],
            "data": ["blockedUserIds": [NSNumber(value: 91)]]
        ])

        XCTAssertEqual(userIds, Set([17, 42, 73, 91]))
    }

    func testBlockedPeerPolicyOnlyDisablesDirectContact() {
        let blockedUserIds: Set<Int> = [42]

        XCTAssertTrue(AloDirectContactPolicy.isBlockedDirectPeer(
            kind: "direct",
            peerId: 42,
            blockedUserIds: blockedUserIds
        ))
        XCTAssertFalse(AloDirectContactPolicy.isBlockedDirectPeer(
            kind: "group",
            peerId: 42,
            blockedUserIds: blockedUserIds
        ))
        XCTAssertFalse(AloDirectContactPolicy.isBlockedDirectPeer(
            kind: "direct",
            peerId: 99,
            blockedUserIds: blockedUserIds
        ))
    }

    func testCertificatePinAcceptsBase64AndHexSHA256() {
        let bytes = Data(0..<32)
        let base64 = "sha256/\(bytes.base64EncodedString())"
        let hex = bytes.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(AloCertificatePinningDelegate.decodePin(base64), bytes)
        XCTAssertEqual(AloCertificatePinningDelegate.decodePin(hex), bytes)
        XCTAssertNil(AloCertificatePinningDelegate.decodePin("sha1/not-a-pin"))
    }

    func testConfiguredAPIEndpointMatchesActiveBuildEnvironment() {
        XCTAssertEqual(AloServerConfiguration.baseURLs.count, 1)
        #if DEBUG
        XCTAssertEqual(AloServerConfiguration.baseURLs.first?.scheme, "http")
        XCTAssertEqual(
            AloServerConfiguration.baseURLs.first?.host,
            AloServerConfiguration.debugLocalDevelopmentHost
        )
        #else
        XCTAssertEqual(AloServerConfiguration.baseURLs.first?.scheme, "https")
        XCTAssertEqual(AloServerConfiguration.baseURLs.first?.host, "api.xn--80awj.online")
        #endif
        XCTAssertFalse(AloServerConfiguration.requiresCertificatePins)
    }

    func testInteractiveDismissRequiresARealSwipeOrFling() {
        XCTAssertFalse(AloInteractiveDismissPolicy.shouldDismiss(translation: 70, velocity: 0, width: 390))
        XCTAssertTrue(AloInteractiveDismissPolicy.shouldDismiss(translation: 130, velocity: 0, width: 390))
        // The full-screen gesture now has a 24 pt accident guard, including flings.
        XCTAssertFalse(AloInteractiveDismissPolicy.shouldDismiss(translation: 12, velocity: 1_100, width: 390))
        XCTAssertTrue(AloInteractiveDismissPolicy.shouldDismiss(translation: 24, velocity: 1_100, width: 390))
    }

    func testChannelPolicyRejectsGroupOnlyPresentationState() {
        let policy = AloGroupPolicy([
            "kind": "channel",
            "isForum": true,
            "historyVisible": false,
            "slowModeSeconds": 300
        ])

        XCTAssertTrue(policy.isChannel)
        XCTAssertFalse(policy.isForumGroup)
        XCTAssertFalse(policy.isForum)
        XCTAssertTrue(policy.historyVisible)
        XCTAssertEqual(policy.slowModeSeconds, 0)
        XCTAssertNil(policy.requestBody["kind"])
        XCTAssertEqual(policy.requestBody["isForum"] as? Bool, false)
        XCTAssertEqual(policy.requestBody["historyVisible"] as? Bool, true)
        XCTAssertEqual(policy.requestBody["slowModeSeconds"] as? Int, 0)
    }

    func testChannelConversationDropsStaleForumTopicsFromPayload() {
        let detail = AloConversationDetail(peerId: 1_000_000_123, json: [
            "peer": [
                "id": 1_000_000_123,
                "name": "Новости",
                "entityType": "channel"
            ],
            "room": [
                "id": 123,
                "title": "Новости",
                "memberCount": 4,
                "policy": [
                    "kind": "channel",
                    "isForum": true,
                    "historyVisible": false,
                    "slowModeSeconds": 60
                ],
                "topics": [[
                    "id": 9,
                    "title": "Устаревшая тема",
                    "iconEmoji": "💬"
                ]],
                "topicStates": [[
                    "topicId": 9,
                    "unreadCount": 3
                ]]
            ],
            "items": []
        ])

        XCTAssertEqual(detail.entityType, "channel")
        XCTAssertTrue(detail.groupPolicy?.isChannel == true)
        XCTAssertTrue(detail.forumTopics.isEmpty)
        XCTAssertTrue(detail.forumTopicStates.isEmpty)
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

    func testPendingEditSurvivesConversationReopenBeforeAcknowledgement() {
        let serverMessage = AloChatMessage(
            localId: 201,
            senderId: 1,
            recipientId: 2,
            body: "before edit",
            createdAt: "2026-07-28T10:00:00Z"
        )

        let projected = AloPendingChatProjection.applyingPendingEdits(
            to: [serverMessage],
            bodyByMessageId: [201: "after offline edit"],
            editedAt: "2026-07-28T10:01:00Z"
        )

        XCTAssertEqual(projected.first?.body, "after offline edit")
        XCTAssertEqual(projected.first?.editedAt, "2026-07-28T10:01:00Z")
    }

    func testPendingReactionSurvivesConversationReopenBeforeAcknowledgement() {
        let serverMessage = AloChatMessage([
            "id": 202,
            "senderId": 1,
            "recipientId": 2,
            "body": "reaction target",
            "createdAt": "2026-07-28T10:00:00Z",
            "reactions": [
                ["emoji": "❤️", "count": 2, "reactedByMe": false],
                ["emoji": "👍", "count": 1, "reactedByMe": true]
            ]
        ])

        let projected = AloPendingChatProjection.applyingDesiredReactions(
            to: [serverMessage],
            desiredEmojiByMessageId: [202: "🔥"]
        )

        XCTAssertEqual(projected.first?.reactions, [
            AloMessageReaction(emoji: "❤️", count: 2, reactedByMe: false),
            AloMessageReaction(emoji: "🔥", count: 1, reactedByMe: true)
        ])
    }

    func testPendingRescheduleSurvivesConversationReopen() {
        let message = scheduledMessage(
            id: 103,
            body: "later",
            scheduledMessageId: 501,
            scheduledAt: "2026-07-28T11:00:00Z"
        )

        let projected = AloPendingChatProjection.applyingScheduledChanges(
            to: [message],
            canceledScheduledMessageIds: [],
            scheduledAtByMessageId: [501: "2026-07-29T15:30:00Z"]
        )

        XCTAssertEqual(projected.first?.scheduledAt, "2026-07-29T15:30:00Z")
    }

    func testSendWhenOnlineMessageRemainsScheduledUntilDelivery() {
        let localMessage = AloChatMessage(
            localId: -7,
            senderId: 1,
            recipientId: 2,
            body: "when you are online",
            createdAt: "2026-08-26T10:00:00Z",
            sendWhenOnline: true
        )
        let serverMessage = AloChatMessage([
            "id": 701,
            "senderId": 1,
            "recipientId": 2,
            "body": "when you are online",
            "createdAt": "2026-08-26T10:00:00Z",
            "scheduledMessageId": 801,
            "sendWhenOnline": true,
            "deliveryState": "scheduled"
        ])

        XCTAssertEqual(localMessage.deliveryState, "scheduled")
        XCTAssertTrue(localMessage.isScheduled)
        XCTAssertTrue(serverMessage.isScheduled)
        XCTAssertTrue(serverMessage.sendWhenOnline)
    }

    func testPendingScheduledCancelSurvivesConversationReopen() {
        let canceled = scheduledMessage(
            id: 104,
            body: "cancel",
            scheduledMessageId: 502,
            scheduledAt: "2026-07-28T11:00:00Z"
        )
        let kept = AloChatMessage(
            localId: 105,
            senderId: 1,
            recipientId: 2,
            body: "keep",
            createdAt: "2026-07-28T10:01:00Z"
        )

        let projected = AloPendingChatProjection.applyingScheduledChanges(
            to: [canceled, kept],
            canceledScheduledMessageIds: [502],
            scheduledAtByMessageId: [:]
        )

        XCTAssertEqual(projected.map { $0.id }, [105])
    }

    private func scheduledMessage(
        id: Int,
        body: String,
        scheduledMessageId: Int,
        scheduledAt: String
    ) -> AloChatMessage {
        AloChatMessage([
            "id": id,
            "senderId": 1,
            "recipientId": 2,
            "body": body,
            "createdAt": "2026-07-28T10:00:00Z",
            "scheduledMessageId": scheduledMessageId,
            "scheduledAt": scheduledAt,
            "deliveryState": "scheduled"
        ])
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

    func testExpiredSecureMediaIsPurgedAfterApplicationRestart() throws {
        let store = AloSecureMediaStore.shared
        store.clearCache()
        defer { store.clearCache() }

        let plaintext = Data("expired encrypted media".utf8)
        let keyData = Data((44..<76).map(UInt8.init))
        let nonceData = Data((76..<88).map(UInt8.init))
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            nonce: try AES.GCM.Nonce(data: nonceData)
        )
        let encryptedURL = try AloSecureMediaStore.encryptedCacheFileForTesting(
            named: "expired-secure-media-test.bin"
        )
        try (sealed.ciphertext + sealed.tag).write(to: encryptedURL, options: .atomic)

        let secureURL = try store.register(
            encryptedURL: encryptedURL,
            encryption: [
                "algorithm": "aes-256-gcm-v1",
                "key": base64URL(keyData),
                "iv": base64URL(nonceData)
            ],
            type: "file",
            name: "expired.bin",
            expiresAt: "2020-01-01T00:00:00.000Z"
        )

        store.purgeExpired()

        XCTAssertFalse(FileManager.default.fileExists(atPath: encryptedURL.path))
        XCTAssertThrowsError(try store.payload(for: secureURL))
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

    func testCallVideoSourcePickerHasThreeStableSources() {
        XCTAssertEqual(
            AloCallVideoSource.allCases,
            [.screen, .frontCamera, .backCamera]
        )
        XCTAssertEqual(AloCallVideoSource.screen.title, "ЭКРАН ТЕЛЕФОНА")
        XCTAssertEqual(AloCallVideoSource.frontCamera.title, "ПЕРЕДНЯЯ КАМЕРА")
        XCTAssertEqual(AloCallVideoSource.backCamera.title, "ЗАДНЯЯ КАМЕРА")
    }

    func testCallVideoControlUsesOneSourcePickerForCameraAndScreen() {
        let base = AloDirectCallState(
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
            isSpeakerOn: false,
            isVideoEnabled: false,
            isFrontCamera: true,
            startedAt: Date(),
            callSecret: "test",
            safetyEmojis: []
        )

        XCTAssertEqual(
            AloCallVideoControlAction.resolve(for: base),
            .presentSources
        )
        XCTAssertEqual(
            AloCallVideoControlAction.resolve(
                for: base.updating(isVideoEnabled: true)
            ),
            .disableCamera
        )
        XCTAssertEqual(
            AloCallVideoControlAction.resolve(
                for: base.updating(isScreenSharing: true)
            ),
            .stopScreenShare
        )
        XCTAssertEqual(AloCallVideoSource.current(for: base), .frontCamera)
        XCTAssertEqual(
            AloCallVideoSource.current(
                for: base.updating(isFrontCamera: false)
            ),
            .backCamera
        )
        XCTAssertEqual(
            AloCallVideoSource.current(
                for: base.updating(isScreenSharing: true)
            ),
            .screen
        )
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

    func testMessageMarkupProducesEncryptedTextEntities() {
        let result = AloMessageMarkup.parse(
            "😀 **bold** __italic__ ||secret|| https://alo.example"
        )

        XCTAssertEqual(result.body, "😀 bold italic secret https://alo.example")
        XCTAssertEqual(
            result.entities.map(\.type),
            ["bold", "italic", "spoiler", "link"]
        )
        XCTAssertEqual(result.entities.first?.offset, 3)
        XCTAssertEqual(result.entities.first?.length, 4)
        XCTAssertEqual(result.entities.last?.url, "https://alo.example")
    }

    func testMessageMarkupCanBeRestoredForEditing() {
        let initial = AloMessageMarkup.parse(
            "**bold** __italic__ ++under++ ~~strike~~ ||secret|| `code`"
        )
        let restored = AloMessageMarkup.source(
            body: initial.body,
            entities: initial.entities
        )
        let reparsed = AloMessageMarkup.parse(restored)

        XCTAssertEqual(reparsed.body, initial.body)
        XCTAssertEqual(reparsed.entities, initial.entities)
    }

    func testQuotesAndCodeBlocksBecomeBlockEntities() {
        let result = AloMessageMarkup.parse(
            "Смотри:\n> первая **строка**\n> вторая\nдальше\n```swift\nlet x = **1**\n```\nконец"
        )

        XCTAssertEqual(result.body, "Смотри:\nпервая строка\nвторая\nдальше\nlet x = **1**\nконец")
        let body = result.body as NSString
        let quote = result.entities.first { $0.type == "blockquote" }
        XCTAssertEqual(quote.map { body.substring(with: NSRange(location: $0.offset, length: $0.length)) }, "первая строка\nвторая")
        let bold = result.entities.first { $0.type == "bold" }
        XCTAssertEqual(bold.map { body.substring(with: NSRange(location: $0.offset, length: $0.length)) }, "строка")
        let code = result.entities.first { $0.type == "pre" }
        XCTAssertEqual(code?.url, "swift")
        XCTAssertEqual(code.map { body.substring(with: NSRange(location: $0.offset, length: $0.length)) }, "let x = **1**",
                       "markers inside code stay literal")
        XCTAssertFalse(result.entities.contains { $0.type == "bold" && $0.offset >= code!.offset })

        let restored = AloMessageMarkup.source(body: result.body, entities: result.entities)
        let reparsed = AloMessageMarkup.parse(restored)
        XCTAssertEqual(reparsed.body, result.body)
        XCTAssertEqual(reparsed.entities, result.entities)
    }

    func testTextThatOnlyLooksLikeBlocksStaysPlain() {
        XCTAssertEqual(AloMessageMarkup.parse("5 >3 и a>b").entities, [])
        XCTAssertEqual(AloMessageMarkup.parse("```не закрыто").body, "```не закрыто")
        let blocks = AloRichMessageText.blocks("Цитата\nпосле", entities: [
            AloMessageTextEntity(type: "blockquote", offset: 0, length: 6)
        ])
        XCTAssertEqual(blocks?.map(\.range.length), [6, 5])
    }

    func testUsernameMentionStaysInsideEncryptedEntityPayload() {
        let result = AloMessageMarkup.parse("😀 привет @Alo_User")

        let mention = result.entities.first(where: { $0.type == "mention" })
        XCTAssertEqual(mention?.offset, 10)
        XCTAssertEqual(mention?.length, ("@Alo_User" as NSString).length)
        XCTAssertEqual(mention?.url, AloDeepLinkTarget.handleURL("alo_user")?.absoluteString)
    }

    func testEncryptedPollCodecAndProjectionUseLatestAuthenticatedVote() throws {
        let poll = AloPollDefinition(
            id: "poll_42",
            question: "Куда пойдём?",
            options: [
                AloPollOption(id: "a", text: "Парк"),
                AloPollOption(id: "b", text: "Кино")
            ],
            allowsMultipleAnswers: false,
            isQuiz: false,
            correctOptionIds: [],
            isAnonymous: true,
            allowsRevoting: true,
            closesAt: "2026-09-01T12:00:00Z"
        )
        let createBody = try XCTUnwrap(AloPollCodec.encodeCreate(poll))
        let firstVote = try XCTUnwrap(AloPollCodec.encodeVote(pollId: poll.id, optionIds: ["a"]))
        let changedVote = try XCTUnwrap(AloPollCodec.encodeVote(pollId: poll.id, optionIds: ["b"]))
        XCTAssertEqual(AloPollCodec.decode(createBody), .create(poll))
        XCTAssertEqual(AloPollCodec.previewText(for: createBody), "Опрос: Куда пойдём?")

        let messages = [
            AloChatMessage(localId: -1, senderId: 7, recipientId: 8, body: createBody, createdAt: "1"),
            AloChatMessage(localId: -2, senderId: 7, recipientId: 8, body: firstVote, createdAt: "2"),
            AloChatMessage(localId: -3, senderId: 7, recipientId: 8, body: changedVote, createdAt: "3")
        ]
        let state = try XCTUnwrap(AloPollProjection.states(messages: messages, currentUserId: 7)[poll.id])
        XCTAssertEqual(state.voteCounts["a"], 0)
        XCTAssertEqual(state.voteCounts["b"], 1)
        XCTAssertEqual(state.selectedOptionIds, ["b"])
        XCTAssertEqual(state.closesAt, "2026-09-01T12:00:00Z")
        XCTAssertEqual(AloPollProjection.visibleMessages(messages).map(\.id), [-1])
    }

    func testEncryptedPollCanClearTheLastVote() throws {
        let body = try XCTUnwrap(AloPollCodec.encodeVote(pollId: "poll_clear", optionIds: []))
        XCTAssertEqual(
            AloPollCodec.decode(body),
            .vote(pollId: "poll_clear", optionIds: [])
        )
    }

    func testAnonymousPollKeepsE2EEProjectionWhenCanonicalStateDiffers() throws {
        let definition = AloPollDefinition(
            id: "private_poll",
            question: "Анонимно?",
            options: [AloPollOption(id: "yes", text: "Да"), AloPollOption(id: "no", text: "Нет")],
            allowsMultipleAnswers: false,
            isQuiz: false,
            correctOptionIds: [],
            isAnonymous: true,
            allowsRevoting: true
        )
        let create = try XCTUnwrap(AloPollCodec.encodeCreate(definition))
        let vote = try XCTUnwrap(AloPollCodec.encodeVote(pollId: definition.id, optionIds: ["yes"]))
        let projected = AloPollProjection.states(
            messages: [
                AloChatMessage(localId: -1, senderId: 7, recipientId: 8, body: create, createdAt: "1"),
                AloChatMessage(localId: -2, senderId: 7, recipientId: 8, body: vote, createdAt: "2")
            ],
            currentUserId: 7
        )
        let canonical = AloCanonicalPollState([
            "id": definition.id,
            "messageId": 41,
            "voteCounts": ["yes": 99, "no": 1],
            "selectedOptionIds": ["no"],
            "totalVoters": 100,
            "isClosed": false,
            "allowsRevoting": true,
            "correctOptionIds": [],
            "publicVoters": [],
            "closesAt": "",
            "closedAt": ""
        ])

        let state = try XCTUnwrap(
            AloPollProjection.applyingCanonical([definition.id: canonical], to: projected)[definition.id]
        )
        XCTAssertEqual(state.voteCounts, ["yes": 1, "no": 0])
        XCTAssertEqual(state.selectedOptionIds, ["yes"])
        XCTAssertEqual(state.totalVoters, 1)
        XCTAssertTrue(state.publicVoters.isEmpty)
    }

    func testEncryptedQuizPayloadDoesNotRevealTheCorrectAnswer() throws {
        let quiz = AloPollDefinition(
            id: "quiz_secret",
            question: "Выберите ответ",
            options: [
                AloPollOption(id: "a", text: "Первый"),
                AloPollOption(id: "b", text: "Второй")
            ],
            allowsMultipleAnswers: false,
            isQuiz: true,
            correctOptionIds: ["b"],
            explanation: "Верный вариант объясняется после ответа.",
            isAnonymous: false,
            allowsRevoting: false
        )

        let prepared = try XCTUnwrap(AloPollQuizCommitment.prepare(quiz))
        let body = try XCTUnwrap(AloPollCodec.encodeCreate(prepared.definition))
        guard case let .create(decoded) = AloPollCodec.decode(body) else {
            return XCTFail("Не удалось декодировать викторину")
        }

        XCTAssertTrue(decoded.correctOptionIds.isEmpty)
        XCTAssertEqual(decoded.quizAnswerCommitment, prepared.definition.quizAnswerCommitment)
        XCTAssertTrue(
            AloPollQuizCommitment.verifies(
                pollId: quiz.id,
                correctOptionIds: quiz.correctOptionIds,
                salt: prepared.salt,
                commitment: decoded.quizAnswerCommitment
            )
        )
        XCTAssertTrue(
            AloPollQuizCommitment.verifies(
                pollId: "quiz_vector",
                correctOptionIds: ["answer_b"],
                salt: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldY",
                commitment: "15ed66537e2f5d394deb9f0e2f04e0fca43595638d139382f62e0b6938fac691"
            )
        )
        XCTAssertEqual(decoded.explanation, "Верный вариант объясняется после ответа.")
        XCTAssertFalse(body.contains("correctOptionIds"))
    }

    func testQuizAcceptsOnlyTheCreatorRevealMatchingItsCommitment() throws {
        let original = AloPollDefinition(
            id: "quiz_reveal",
            question: "Выберите ответ",
            options: [AloPollOption(id: "a", text: "Первый"), AloPollOption(id: "b", text: "Второй")],
            allowsMultipleAnswers: false,
            isQuiz: true,
            correctOptionIds: ["b"],
            isAnonymous: true,
            allowsRevoting: false
        )
        let prepared = try XCTUnwrap(AloPollQuizCommitment.prepare(original))
        let create = try XCTUnwrap(AloPollCodec.encodeCreate(prepared.definition))
        let reveal = try XCTUnwrap(
            AloPollCodec.encodeReveal(pollId: original.id, correctOptionIds: original.correctOptionIds, salt: prepared.salt)
        )
        let canonical = AloCanonicalPollState([
            "id": original.id,
            "messageId": 1,
            "voteCounts": ["a": 0, "b": 0],
            "selectedOptionIds": [],
            "totalVoters": 0,
            "isClosed": true,
            "allowsRevoting": false,
            "correctOptionIds": [],
            "publicVoters": [],
            "closesAt": "",
            "closedAt": "2026-08-27T00:00:00Z"
        ])
        let forged = AloPollProjection.applyingCanonical(
            [original.id: canonical],
            to: AloPollProjection.states(
                messages: [
                    AloChatMessage(localId: -1, senderId: 7, recipientId: 8, body: create, createdAt: "1"),
                    AloChatMessage(localId: -2, senderId: 8, recipientId: 7, body: reveal, createdAt: "2")
                ],
                currentUserId: 8
            )
        )
        XCTAssertEqual(forged[original.id]?.correctOptionIds, [])

        let verifiedMessages = [
            AloChatMessage(localId: -1, senderId: 7, recipientId: 8, body: create, createdAt: "1"),
            AloChatMessage(localId: -2, senderId: 7, recipientId: 8, body: reveal, createdAt: "2")
        ]
        let verified = AloPollProjection.applyingCanonical(
            [original.id: canonical],
            to: AloPollProjection.states(messages: verifiedMessages, currentUserId: 8)
        )
        XCTAssertEqual(verified[original.id]?.correctOptionIds, ["b"])
        XCTAssertEqual(AloPollProjection.visibleMessages(verifiedMessages).map(\.id), [-1])
    }

    func testProtectedMediaScreenshotEventHasAStableOpaqueCodec() {
        let body = AloChatSystemEventCodec.encode(.protectedMediaScreenshot)

        XCTAssertEqual(AloChatSystemEventCodec.decode(body), .protectedMediaScreenshot)
        XCTAssertEqual(
            AloChatSystemEventCodec.previewText(for: body),
            "Сделан снимок исчезающего медиа"
        )
        XCTAssertEqual(
            AloChatSystemEventCodec.previewText(for: body, isMine: true),
            "Вы сделали снимок исчезающего медиа"
        )
        XCTAssertNil(AloChatSystemEventCodec.decode("alo.system.v1:unknown"))
    }

    func testForumTopicLifecycleDeltaPreservesVisibilityAndRemoval() {
        let topic: [String: Any] = [
            "id": 12,
            "roomId": 8,
            "title": "Архив",
            "iconEmoji": "📦",
            "isGeneral": false,
            "isClosed": true,
            "isHidden": true,
            "createdAt": "2026-08-01T09:00:00.000Z",
            "updatedAt": "2026-08-01T10:01:00.000Z"
        ]
        let delta = AloGroupManagementDelta(
            [
                "version": 1,
                "members": [],
                "requests": [],
                "bans": [],
                "invites": [],
                "topics": [
                    ["operation": "upsert", "value": topic],
                    ["operation": "remove", "id": 13]
                ]
            ],
            revision: 44
        )

        XCTAssertEqual(delta?.revision, 44)
        XCTAssertEqual(delta?.topicsUpserted.first?.isHidden, true)
        XCTAssertEqual(delta?.topicsUpserted.first?.isClosed, true)
        XCTAssertEqual(delta?.topicIdsRemoved, [13])
    }

    func testSecurityEventMapsServerAuditPayload() {
        let event = AloSecurityEvent([
            "id": 17,
            "eventType": "sessions_revoked_others",
            "riskLevel": "low",
            "ip": "203.0.113.10",
            "createdAt": "2026-08-18T12:00:00.000Z"
        ])

        XCTAssertEqual(event.id, 17)
        XCTAssertEqual(event.eventType, "sessions_revoked_others")
        XCTAssertEqual(event.riskLevel, "low")
        XCTAssertEqual(event.ip, "203.0.113.10")
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
