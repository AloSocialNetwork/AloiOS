import Combine
import Foundation
import UIKit

/// What the store needs from the server. `AloAPIClient` is the real one; tests use a fake.
protocol AloSecretChatTransport: AnyObject {
    func secretChatsAvailable() async -> Bool
    func loadSecretChats() async throws -> [AloSecretChat]
    func loadSecretMessages(id: Int, beforeId: Int, limit: Int) async throws -> AloSecretConversation
    func startSecretChat(peerUserId: Int) async throws -> AloSecretChat
    func acceptSecretChat(id: Int) async throws -> AloSecretChat
    func markSecretChatRead(id: Int, upToMessageId: Int) async throws
    func setSecretChatTimer(id: Int, seconds: Int) async throws
    func deleteSecretChat(id: Int) async throws
    func sendSecretMessage(chat: AloSecretChat, text: String, drafts: [AloLocalAttachment], selfDestructSeconds: Int,
                           clientMessageId: String) async throws -> AloSecretMessage
    func forgetSecretMessageData(_ messages: [AloSecretMessage])
}

extension AloAPIClient: AloSecretChatTransport {}

/// Secret chats of this device (docs/cloud-and-secret-chats.md, stage 2): the list, the open chat, sending, read marks,
/// timers and the chat being deleted. The id of a secret chat lives in its own space; it is never a `peerId`.
@MainActor
final class AloSecretChatStore: ObservableObject {
    @Published private(set) var available = false { didSet { if available != oldValue { listDidChange.send() } } }
    @Published private(set) var chats = [AloSecretChat]() { didSet { if chats != oldValue { listDidChange.send() } } }
    @Published private(set) var activeId = 0 { didSet { if activeId != oldValue { listDidChange.send() } } }
    @Published private(set) var messages = [AloSecretMessage]()
    @Published private(set) var isLoading = false
    /// The server says the chat is gone (deleted, or open on another device): «Секретный чат закрыт».
    @Published private(set) var isGone = false
    @Published private(set) var isSending = false
    @Published var drafts = [AloLocalAttachment]()
    @Published var errorMessage = ""

    /// Something the chat list shows changed: the chats, whether they exist at all, whether one is open.
    let listDidChange = PassthroughSubject<Void, Never>()
    /// The person was signed out by the server.
    var onSessionExpired: () -> Void = {}
    /// A secret chat is about to open: the app closes whatever else is open and goes to the chats.
    var onWillOpen: () -> Void = {}

    private let transport: AloSecretChatTransport
    private let currentUserId: () -> Int
    private let now: () -> Double
    private let isForeground: () -> Bool
    private var ticker: Task<Void, Never>?
    private var readinessRetry: Task<Void, Never>?
    private var readinessAttempts = 0
    private var ownerUserId = 0
    private static let maxDrafts = 10
#if DEBUG
    /// The UI fixture is on screen: nothing is read from a server.
    private var isPreview = false
#endif

    init(
        transport: AloSecretChatTransport,
        currentUserId: @escaping () -> Int,
        now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
        isForeground: @escaping () -> Bool = { UIApplication.shared.applicationState != .background }
    ) {
        self.transport = transport
        self.currentUserId = currentUserId
        self.now = now
        self.isForeground = isForeground
    }

    var activeChat: AloSecretChat? { chats.first { $0.id == activeId } }
    var isOpen: Bool { activeId > 0 }

    /// Rows for the chat list: the secret chats as summaries.
    func rows(merging arranged: [AloConversationSummary], isPinned: (AloConversationSummary) -> Bool) -> [AloConversationSummary] {
        AloSecretChatList.merge(arranged: arranged, isPinned: isPinned, secrets: chats, now: now())
    }

    // MARK: List

    /// At start, when the app returns to the front and on every `secret_chats` event: the list, and the open chat.
    func refreshAll() async {
#if DEBUG
        if isPreview { return }
#endif
        let me = currentUserId()
        guard me > 0 else { return }
        if ownerUserId != me { accountChanged(to: me) }
        guard await transport.secretChatsAvailable() else {
            available = false
            scheduleReadinessRetry()
            return
        }
        readinessRetry?.cancel()
        readinessRetry = nil
        readinessAttempts = 0
        do {
            let fresh = try await transport.loadSecretChats()
            guard currentUserId() == me else { return }
            available = true
            // A message whose time ran out while this device was away is gone for good, text and files.
            purgeExpired(in: fresh.compactMap(\.lastMessage))
            chats = fresh
            if activeId > 0 {
                if fresh.contains(where: { $0.id == activeId }) {
                    await loadActive()
                } else {
                    markGone(activeId)
                }
            }
        } catch let error as AloAPIError {
            if error.status == 401 { onSessionExpired() }
        } catch {
            // The list stays as it was; the next event or the next start reads it again.
        }
    }

    /// At launch the list is asked for while this install may still be registering its libsignal device (when another
    /// request is already registering it, the start-up one does not wait), so the chats stayed hidden until the app went
    /// to the background and back. «Not ready yet» is asked again a few times, 2 to 8 seconds apart.
    private func scheduleReadinessRetry() {
        guard readinessRetry == nil, readinessAttempts < 6, currentUserId() > 0 else { return }
        readinessAttempts += 1
        let delay = UInt64(min(8, readinessAttempts * 2)) * 1_000_000_000
        readinessRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.readinessRetry = nil
            await self.refreshAll()
        }
    }

    /// A `secret_chats` event: a deleted chat disappears at once, anything else is read again.
    func handleUpdate(type: String, secretChatId: Int) async {
        if type == "secret_chat_closed", secretChatId > 0 {
            removeEverywhere(secretChatId)
            return
        }
        await refreshAll()
    }

    /// A different person signed in: nothing of the last one stays in view.
    func accountChanged(to userId: Int) {
        guard ownerUserId != userId else { return }
        ownerUserId = userId
        ticker?.cancel()
        ticker = nil
        readinessRetry?.cancel()
        readinessRetry = nil
        readinessAttempts = 0
        drafts.forEach(AloDraftAttachmentStore.discard)
        drafts = []
        chats = []
        messages = []
        activeId = 0
        isGone = false
        isLoading = false
        isSending = false
        available = false
    }

    private func removeEverywhere(_ id: Int) {
        if activeId == id {
            transport.forgetSecretMessageData(messages)
            chats = AloSecretChatList.removing(chats, id: id)
            messages = []
            isGone = true
            isLoading = false
        } else {
            if let last = chats.first(where: { $0.id == id })?.lastMessage { transport.forgetSecretMessageData([last]) }
            chats = AloSecretChatList.removing(chats, id: id)
        }
    }

    private func markGone(_ id: Int) {
        guard activeId == id else { return }
        isGone = true
        isLoading = false
        messages = []
    }

    // MARK: Open chat

    func open(id: Int) {
        guard id > 0 else { return }
        onWillOpen()
        activeId = id
        messages = []
        isLoading = true
        isGone = false
        isSending = false
        errorMessage = ""
        drafts.forEach(AloDraftAttachmentStore.discard)
        drafts = []
        startTicker()
        Task { await loadActive() }
    }

    func close() {
        ticker?.cancel()
        ticker = nil
        // Leaving the screen keeps the messages: their text exists nowhere else on this device but the local copy.
        drafts.forEach(AloDraftAttachmentStore.discard)
        drafts = []
        activeId = 0
        messages = []
        isLoading = false
        isGone = false
        isSending = false
    }

    func loadActive() async {
        let id = activeId
        guard id > 0 else { return }
        // A request nobody has accepted has no messages for this device to read.
        if let chat = chats.first(where: { $0.id == id }), chat.isIncomingRequest {
            isLoading = false
            return
        }
        do {
            let conversation = try await transport.loadSecretMessages(id: id, beforeId: 0, limit: 100)
            guard activeId == id else { return }
            let visible = AloSecretTimers.visible(conversation.messages, nowMillis: now())
            purgeExpired(in: conversation.messages)
            messages = visible
            isLoading = false
            isGone = false
            if let fresh = conversation.chat { chats = AloSecretChatList.upserting(chats, fresh) }
            markRead()
        } catch let error as AloAPIError {
            guard activeId == id else { return }
            if error.status == 401 {
                onSessionExpired()
            } else if error.status == 404 {
                removeEverywhere(id)
            } else {
                isLoading = false
                errorMessage = error.message
            }
        } catch {
            isLoading = false
        }
    }

    /// Opening a chat reads what the other person sent: their timers start now, and they are told.
    func markRead() {
        let id = activeId
        guard id > 0, isForeground() else { return }
        let result = AloSecretTimers.applyRead(messages, myUserId: currentUserId(), nowMillis: now())
        guard result.upToMessageId > 0 else { return }
        messages = result.messages
        chats = chats.map { chat in
            var copy = chat
            if chat.id == id { copy.unreadCount = 0 }
            return copy
        }
        let upTo = result.upToMessageId
        Task { [transport] in
            // The server marks them at the next open if this fails; the local timer already runs.
            try? await transport.markSecretChatRead(id: id, upToMessageId: upTo)
        }
    }

    // MARK: Start, accept, delete

    /// Starts (or reopens) a secret chat with this person and opens it. Returns what went wrong, for the screen that
    /// asked (a profile, the chat details, «Новое сообщение»), or nil when the chat is open.
    @discardableResult
    func start(userId: Int) async -> String? {
        guard userId > 0 else { return "Не удалось начать секретный чат." }
        guard await transport.secretChatsAvailable() else {
            return "Секретные чаты пока недоступны на этом устройстве. Подождите секунду, ключи создаются."
        }
        do {
            let chat = try await transport.startSecretChat(peerUserId: userId)
            available = true
            chats = AloSecretChatList.upserting(chats, chat)
            open(id: chat.id)
            return nil
        } catch let error as AloAPIError {
            if error.status == 401 { onSessionExpired() }
            return error.message
        } catch {
            return "Не удалось начать секретный чат."
        }
    }

    func accept() async {
        let id = activeId
        guard id > 0 else { return }
        do {
            let chat = try await transport.acceptSecretChat(id: id)
            chats = AloSecretChatList.upserting(chats, chat)
            await loadActive()
        } catch let error as AloAPIError {
            if error.status == 401 {
                onSessionExpired()
            } else if error.code == "secret_chat_taken" {
                // Another device of this account took the request first: it is not ours any more.
                removeEverywhere(id)
                errorMessage = error.message
            } else {
                errorMessage = error.message
            }
        } catch {
            errorMessage = "Не удалось принять секретный чат."
        }
    }

    /// Deletes the chat for both people, or declines a request. Local copies of its messages go with it.
    func delete(id: Int? = nil) async {
        let target = id ?? activeId
        guard target > 0 else { return }
        // Collect what this device holds before the server forgets the chat: the history is read, then wiped.
        let history = await collectHistory(of: target)
        do {
            try await transport.deleteSecretChat(id: target)
        } catch let error as AloAPIError {
            if error.status == 401 { onSessionExpired(); return }
            // 404: it is gone already, which is what was asked.
            if error.status != 404 {
                errorMessage = error.message
                return
            }
        } catch {
            errorMessage = "Не удалось удалить секретный чат."
            return
        }
        transport.forgetSecretMessageData(history)
        chats = AloSecretChatList.removing(chats, id: target)
        if activeId == target { close() }
    }

    private func collectHistory(of id: Int) async -> [AloSecretMessage] {
        var collected = activeId == id ? messages : []
        if let last = chats.first(where: { $0.id == id })?.lastMessage { collected.append(last) }
        var beforeId = collected.map(\.id).min() ?? 0
        for _ in 0..<5 {
            guard let page = try? await transport.loadSecretMessages(id: id, beforeId: beforeId, limit: 200) else { break }
            collected += page.messages
            guard page.hasMore, let oldest = page.messages.map(\.id).min() else { break }
            beforeId = oldest
        }
        return collected
    }

    // MARK: Timer

    func setTimer(seconds: Int) async {
        let id = activeId
        guard id > 0 else { return }
        do {
            try await transport.setSecretChatTimer(id: id, seconds: seconds)
            chats = chats.map { chat in
                var copy = chat
                if chat.id == id { copy.ttlSeconds = seconds }
                return copy
            }
        } catch let error as AloAPIError {
            if error.status == 401 { onSessionExpired() } else { errorMessage = error.message }
        } catch {
            errorMessage = "Не удалось сменить таймер."
        }
    }

    /// Messages whose time is up disappear from the screen without waiting for the server; their files go with them.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.activeId <= 0 { return }
                self.dropExpired()
            }
        }
    }

    /// Removes the messages whose end has come; returns how many went.
    @discardableResult
    func dropExpired() -> Int {
        let visible = AloSecretTimers.visible(messages, nowMillis: now())
        guard visible.count != messages.count else { return 0 }
        let gone = messages.filter { message in !visible.contains { $0.id == message.id } }
        transport.forgetSecretMessageData(gone)
        messages = visible
        return gone.count
    }

    private func purgeExpired(in list: [AloSecretMessage]) {
        let expired = list.filter { AloSecretTimers.isExpired($0, nowMillis: now()) }
        if !expired.isEmpty { transport.forgetSecretMessageData(expired) }
    }

    // MARK: Sending

    func addDrafts(_ added: [AloLocalAttachment]) {
        let room = max(0, Self.maxDrafts - drafts.count)
        drafts += added.prefix(room)
        added.dropFirst(room).forEach(AloDraftAttachmentStore.discard)
    }

    func removeDraft(id: UUID) {
        guard let removed = drafts.first(where: { $0.id == id }) else { return }
        AloDraftAttachmentStore.discard(removed)
        drafts.removeAll { $0.id == id }
    }

    /// Sends the text and the files of the composer. Returns true when the server took the message.
    @discardableResult
    func send(text: String) async -> Bool {
        let id = activeId
        guard let chat = activeChat, chat.isActive, !isSending else { return false }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = drafts
        guard !body.isEmpty || !files.isEmpty else { return false }
        isSending = true
        errorMessage = ""
        defer { if activeId == id { isSending = false } }
        do {
            let message = try await transport.sendSecretMessage(
                chat: chat, text: body, drafts: files,
                selfDestructSeconds: AloSecretTimers.secondsForNewMessage(chat),
                clientMessageId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
            files.forEach(AloDraftAttachmentStore.discard)
            guard activeId == id else { return true }
            drafts.removeAll { draft in files.contains { $0.id == draft.id } }
            messages = (messages.filter { $0.id != message.id } + [message]).sorted { $0.id < $1.id }
            chats = chats.map { item in
                var copy = item
                if item.id == id { copy.lastMessage = message }
                return copy
            }
            return true
        } catch let error as AloAPIError {
            if error.status == 401 {
                onSessionExpired()
            } else if error.status == 404 || error.status == 410 {
                removeEverywhere(id)
            }
            errorMessage = error.message
            return false
        } catch {
            errorMessage = "Не удалось отправить секретное сообщение."
            return false
        }
    }

#if DEBUG
    /// UI-test fixture (`-ALO_UI_SECRET_PREVIEW list|chat|request|waiting`, with `-ALO_UI_MESSENGER_PREVIEW 1`): three
    /// secret chats on screen without a server, one of them open.
    func installDebugPreview(mode: String, meId: Int) {
        isPreview = true
        ownerUserId = meId
        let now = Date()
        func iso(_ offset: TimeInterval) -> String { AloSecretTime.iso(millis: now.addingTimeInterval(offset).timeIntervalSince1970 * 1000) }
        func peer(_ id: Int, _ name: String) -> [String: Any] { ["id": id, "name": name, "username": "ui_fixture_\(id)"] }
        func message(_ id: Int, from sender: Int, _ body: String, at offset: TimeInterval, seconds: Int = 0,
                     read: Bool = true, expires: TimeInterval? = nil, bold: (Int, Int)? = nil) -> AloSecretMessage {
            AloSecretChatCodec.parseMessage([
                "id": id, "secretChatId": 501, "senderUserId": sender, "body": body, "selfDestructSeconds": seconds,
                "entities": bold.map { [["type": "bold", "offset": $0.0, "length": $0.1]] } ?? [],
                "createdAt": iso(offset), "readAt": read ? iso(offset + 20) : "", "expiresAt": expires.map { iso($0) } ?? ""
            ])
        }
        let sample = [
            message(9001, from: 990003, "Привет! Давай договорим здесь, тут всё шифруется 🔒", at: -600),
            message(9002, from: meId, "Давай. Здесь можно спокойно обсудить подарок для Саши", at: -540),
            message(9003, from: 990003, "Я нашла тот самый фотоаппарат, который он хотел", at: -300, bold: (18, 11)),
            message(9004, from: 990003, "Код от посылки: 4815. Сообщение исчезнет через полминуты", at: -40, seconds: 30, expires: 25),
            message(9005, from: meId, "Понял, запомнил 👍", at: -20, read: false)
        ]
        let active = AloSecretChatCodec.parseChat([
            "id": 501, "status": "active", "role": "accepted", "peerUserId": 990003, "peerUser": peer(990003, "Мария"),
            "localDeviceId": "ios_fixture", "remoteDeviceId": "web_fixture", "ttlSeconds": 30,
            "createdAt": iso(-900), "acceptedAt": iso(-890), "unreadCount": 0
        ], lastMessage: sample.last)!
        let request = AloSecretChatCodec.parseChat([
            "id": 502, "status": "pending", "role": "incoming", "peerUserId": 990004, "peerUser": peer(990004, "Дмитрий Орлов"),
            "localDeviceId": "", "remoteDeviceId": "", "ttlSeconds": 0, "createdAt": iso(-120), "unreadCount": 1
        ])!
        let waiting = AloSecretChatCodec.parseChat([
            "id": 503, "status": "pending", "role": "started", "peerUserId": 990005, "peerUser": peer(990005, "Софья"),
            "localDeviceId": "ios_fixture", "remoteDeviceId": "", "ttlSeconds": 0, "createdAt": iso(-3600)
        ])!
        available = true
        chats = AloSecretChatList.replacing([active, request, waiting])
        isLoading = false
        isGone = false
        switch mode {
        case "chat":
            messages = sample
            activeId = 501
        case "request":
            activeId = 502
        case "waiting":
            activeId = 503
        default:
            activeId = 0
        }
    }
#endif
}
