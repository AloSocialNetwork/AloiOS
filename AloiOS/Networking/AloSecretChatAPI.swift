import Foundation

// The requests of secret chats (docs/cloud-and-secret-chats.md, stage 2). Every request carries the libsignal
// `deviceId` of this install: a secret chat belongs to two devices, not to two accounts.
extension AloAPIClient {
    /// `security.secretChats` is on and this install has its libsignal device.
    func secretChatsAvailable() async -> Bool {
        guard secretDeviceId() != nil else { return false }
        return await messagingPolicy().secretChatsEnabled
    }

    private func requireSecretDevice() throws -> String {
        guard let deviceId = secretDeviceId() else {
            throw AloAPIError(status: -1, code: "SECRET_DEVICE_NOT_READY",
                message: "Шифрование на этом устройстве ещё не готово. Подождите секунду и повторите.", payload: [:])
        }
        return deviceId
    }

    private func parseSecretChat(_ json: [String: Any]) async -> AloSecretChat? {
        var last: AloSecretMessage?
        if let raw = json.optionalObject("lastMessage") { last = await openSecretMessage(raw) }
        return AloSecretChatCodec.parseChat(json, lastMessage: last)
    }

    /// The chats of this device and the requests nobody has accepted yet, newest activity first.
    func loadSecretChats() async throws -> [AloSecretChat] {
        let deviceId = try requireSecretDevice()
        let response = try await request("GET", AloSecretChatCodec.listPath(deviceId: deviceId))
        var chats = [AloSecretChat]()
        for item in response.array("items") {
            if let chat = await parseSecretChat(item) { chats.append(chat) }
        }
        return AloSecretChatList.replacing(chats)
    }

    func loadSecretMessages(id: Int, beforeId: Int = 0, limit: Int = 100) async throws -> AloSecretConversation {
        let deviceId = try requireSecretDevice()
        let response = try await request("GET", AloSecretChatCodec.messagesPath(id: id, deviceId: deviceId, limit: limit, beforeId: beforeId))
        var messages = [AloSecretMessage]()
        for item in response.array("items") { messages.append(await openSecretMessage(item)) }
        var chat: AloSecretChat?
        if let json = response.optionalObject("secretChat") { chat = await parseSecretChat(json) }
        return AloSecretConversation(chat: chat, messages: messages, hasMore: response.object("page").bool("hasMore"))
    }

    func startSecretChat(peerUserId: Int) async throws -> AloSecretChat {
        let deviceId = try requireSecretDevice()
        let response = try await request("POST", "/api/secret-chats",
                                         body: AloSecretChatCodec.startBody(peerUserId: peerUserId, deviceId: deviceId))
        guard let json = response.optionalObject("secretChat"), let chat = await parseSecretChat(json) else {
            throw AloAPIError(status: 502, code: "SECRET_CHAT_MISSING", message: "Сервер не вернул секретный чат.", payload: response)
        }
        return chat
    }

    /// The first device of the person that accepts is the other end; another one answers 409 `secret_chat_taken`.
    func acceptSecretChat(id: Int) async throws -> AloSecretChat {
        let deviceId = try requireSecretDevice()
        let response = try await request("POST", AloSecretChatCodec.acceptPath(id: id),
                                         body: AloSecretChatCodec.acceptBody(deviceId: deviceId))
        guard let json = response.optionalObject("secretChat"), let chat = await parseSecretChat(json) else {
            throw AloAPIError(status: 502, code: "SECRET_CHAT_MISSING", message: "Сервер не вернул секретный чат.", payload: response)
        }
        return chat
    }

    func markSecretChatRead(id: Int, upToMessageId: Int) async throws {
        guard upToMessageId > 0 else { return }
        let deviceId = try requireSecretDevice()
        _ = try await request("POST", AloSecretChatCodec.readPath(id: id),
                              body: AloSecretChatCodec.readBody(deviceId: deviceId, upToMessageId: upToMessageId))
    }

    func setSecretChatTimer(id: Int, seconds: Int) async throws {
        let deviceId = try requireSecretDevice()
        _ = try await request("PUT", AloSecretChatCodec.timerPath(id: id),
                              body: AloSecretChatCodec.timerBody(deviceId: deviceId, seconds: seconds))
    }

    /// Deletes the chat for both people (or declines a request): every message and file goes from the server.
    func deleteSecretChat(id: Int) async throws {
        let deviceId = try requireSecretDevice()
        _ = try await request("DELETE", AloSecretChatCodec.deletePath(id: id, deviceId: deviceId))
    }

    /// One secret message: sealed for the ONE device at the other end of the chat. Files are sealed with the chunked
    /// media encryption and uploaded as opaque `e2ee` files, exactly as in the old encrypted chats; their keys stay
    /// inside the envelope.
    func sendSecretMessage(
        chat: AloSecretChat,
        text: String,
        drafts: [AloLocalAttachment],
        selfDestructSeconds: Int,
        clientMessageId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws -> AloSecretMessage {
        let deviceId = try requireSecretDevice()
        guard chat.isActive, !chat.remoteDeviceId.isEmpty else {
            throw AloAPIError(status: 409, code: "secret_chat_not_active", message: "Секретный чат ещё не принят.", payload: [:])
        }
        var attachments = [AloMessageAttachment]()
        for draft in drafts { attachments.append(AloSecretChatCodec.sealedAttachment(try await uploadE2EEAttachment(draft))) }
        let envelope = try await sealSecretMessage(
            peerUserId: chat.peerUserId, remoteDeviceId: chat.remoteDeviceId, body: text, attachments: attachments)
        guard AloSecretChatCodec.isSingleRecipientEnvelope(
            envelope, peerUserId: chat.peerUserId, peerDeviceId: chat.remoteDeviceId, senderDeviceId: deviceId) else {
            throw AloAPIError(status: -1, code: "SECRET_ENVELOPE_INVALID",
                message: "Секретное сообщение должно быть зашифровано только для одного устройства.", payload: [:])
        }
        let response = try await request(
            "POST", AloSecretChatCodec.sendPath(id: chat.id),
            body: AloSecretChatCodec.messageBody(deviceId: deviceId, encrypted: envelope, attachments: attachments,
                                                 clientMessageId: clientMessageId, selfDestructSeconds: selfDestructSeconds),
            timeout: 45
        )
        guard let message = response.optionalObject("message") else {
            throw AloAPIError(status: 502, code: "MESSAGE_ACK_INVALID", message: "Сервер не подтвердил отправку.", payload: response)
        }
        return await openSecretMessage(message)
    }
}
