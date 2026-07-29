import Foundation
import Combine
import SwiftUI

@MainActor
final class AloAppModel: ObservableObject {
    enum Phase {
        case loading
        case auth
        case app
    }

    enum AuthMode {
        case login
        case register
        case verifyLogin
        case verifyEmail
    }

    struct HumanChallenge: Identifiable {
        let id = UUID()
        let url: URL
        let message: String
    }

    private struct PendingChatTarget: Equatable {
        let peerId: Int
        let roomId: Int
        let kind: String
    }

    private enum PendingChatOperation {
        case sendText(
            localId: Int,
            target: PendingChatTarget,
            body: String,
            createdAt: String,
            clientMessageId: String,
            encryptedPayload: [String: Any]?
        )
        case sendDraft(
            localId: Int,
            target: PendingChatTarget,
            body: String,
            createdAt: String,
            attachments: [AloLocalAttachment],
            uploadedAttachments: [AloMessageAttachment],
            forwardFrom: AloForwardMeta?,
            clientMessageId: String,
            encryptedPayload: [String: Any]?
        )
        case reaction(target: PendingChatTarget, messageId: Int, emoji: String)
        case edit(
            target: PendingChatTarget,
            messageId: Int,
            originalBody: String,
            body: String,
            attachments: [AloMessageAttachment],
            forwardFrom: AloForwardMeta?,
            encryptedPayload: [String: Any]?
        )
        case delete(target: PendingChatTarget, messageIds: [Int], mode: String)
    }

    @Published var phase: Phase = .loading
    @Published var authMode: AuthMode = .login
    @Published var email = ""
    @Published var password = ""
    @Published var name = ""
    @Published var username = ""
    @Published var code = ""
    @Published var notice = ""
    @Published var errorMessage = ""
    @Published var isBusy = false
    @Published var bootstrap: AloBootstrapData?
    @Published var activeTab: AloAppTab = .feed
    @Published var feedMode: AloFeedMode = .popular
    @Published var composeText = ""
    @Published var searchQuery = ""
    @Published var activeConversation: AloConversationDetail?
    @Published var messageText = ""
    @Published var pendingForwardDraft: AloForwardMeta?
    @Published var pendingForwardTitle = ""
    @Published var humanChallenge: HumanChallenge?
    @Published var selectedProfile: AloUserProfile?
    @Published var isProfileLoading = false
    @Published var commentsPost: AloPost?
    @Published var comments = [AloPostComment]()
    @Published var commentText = ""
    @Published var commentsLoading = false
    @Published private(set) var pendingChatMessageIds = Set<Int>()

    let api = AloAPIClient.shared
    lazy var calls = AloCallCoordinator(api: api, app: self)
    private var challengeToken = ""
    private var loginVerificationRequestId = ""
    private var pendingChallengeRetry: ((String) -> Void)?
    private var conversationRefreshTask: Task<Void, Never>?
    private var chatStreamTask: Task<Void, Never>?
    private var chatStreamRefreshTask: Task<Void, Never>?
    private var chatStreamOwnerUserId = 0
    private var chatStreamNeedsActiveRefresh = false
    private var pendingChatRetryTask: Task<Void, Never>?
    private var pendingChatOperations = [PendingChatOperation]()
    private var pendingChatOperationsOwnerUserId: Int?
    private var isProcessingPendingChatOperations = false
    private var nextLocalMessageId = -1
    private var lastTypingSentAt: Date = .distantPast
    private var lastBootstrapRefreshAt: Date = .distantPast
    private let bootstrapCacheKey = "alo.ios.bootstrap-cache.v1"
    private let bootstrapCacheFileName = "bootstrap-cache-v1.json"

    func start() {
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_CALL_PREVIEW") {
            phase = .app
            calls.installDebugPreviewCall()
            return
        }
#endif
        AloSecureOutboxStore.shared.discardLegacyUnscopedData()
        Task {
            await initialBootstrapFlow()
            if phase == .app {
                await processPendingChatOperations()
            }
        }
    }

    func retryInitialBootstrap() {
        Task { await initialBootstrapFlow() }
    }

    func loadBootstrap(showAuthOnUnauthorized: Bool = false, peerId: Int = 0) async {
        isBusy = true
        errorMessage = ""
        do {
            let snapshot = try await api.loadBootstrapSnapshot(peerId: peerId)
            let data = snapshot.data
            saveBootstrapCache(snapshot.raw)
            bootstrap = data
            lastBootstrapRefreshAt = Date()
            activatePendingChatOutbox(ownerUserId: data.me.id)
            if let e2eeWarning = api.latestE2EEWarning {
                notice = e2eeWarning
            }
            if peerId > 0, let summary = data.conversations.first(where: { $0.peerId == peerId }) {
                let detail = AloConversationDetail(summary: summary, items: data.activeMessages)
                let mergedDetail = mergePendingLocalMessages(into: detail)
                activeConversation = mergedDetail
                startConversationLive(mergedDetail)
            }
            phase = .app
            startChatRealtime(ownerUserId: data.me.id)
            AloPushCoordinator.shared.sync(api: api)
            AloVoIPPushCoordinator.shared.sync(api: api)
            calls.startPolling()
        } catch let error as AloAPIError {
            if error.status == 401 && showAuthOnUnauthorized {
                phase = .auth
            } else if error.code == "CONNECTION_FAILED" || error.status == 0 {
                if bootstrap == nil, !restoreBootstrapCache(peerId: peerId) {
                    phase = .loading
                }
            } else {
                errorMessage = error.message
            }
        } catch {
            if bootstrap == nil, !restoreBootstrapCache(peerId: peerId) {
                phase = .loading
            }
        }
        isBusy = false
    }

    func refreshForTabIfNeeded(
        _ tab: AloAppTab,
        minimumInterval: TimeInterval = 45
    ) {
        guard phase == .app,
              !isBusy,
              tab == .feed
                || tab == .profile
                || tab == .search
                || tab == .alerts else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastBootstrapRefreshAt)
                >= minimumInterval else {
            return
        }
        lastBootstrapRefreshAt = now
        Task { await loadBootstrap() }
    }

    func submitAuth() {
        switch authMode {
        case .login:
            submitLogin()
        case .register:
            submitRegister()
        case .verifyLogin:
            verifyLogin()
        case .verifyEmail:
            verifyEmail()
        }
    }

    func submitLogin(captchaToken: String? = nil) {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Введите почту и пароль."
            return
        }
        runAuthTask {
            do {
                let result = try await self.api.login(email: self.email, password: self.password, captchaToken: captchaToken)
                self.challengeToken = result.challengeToken
                self.loginVerificationRequestId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                self.notice = result.message
                self.code = ""
                self.authMode = .verifyLogin
            } catch let error as AloAPIError {
                if self.handleChallenge(error, retry: { token in self.submitLogin(captchaToken: token) }) { return }
                self.errorMessage = error.message
            } catch {
                self.errorMessage = "Не удалось подключиться к серверу."
            }
        }
    }

    func submitRegister(captchaToken: String? = nil) {
        guard !name.isEmpty, !username.isEmpty, !email.isEmpty, !password.isEmpty else {
            errorMessage = "Заполните все поля."
            return
        }
        runAuthTask {
            do {
                self.notice = try await self.api.register(
                    name: self.name,
                    username: self.username,
                    email: self.email,
                    password: self.password,
                    captchaToken: captchaToken
                )
                self.code = ""
                self.authMode = .verifyEmail
            } catch let error as AloAPIError {
                if self.handleChallenge(error, retry: { token in self.submitRegister(captchaToken: token) }) { return }
                self.errorMessage = error.message
            } catch {
                self.errorMessage = "Не удалось подключиться к серверу."
            }
        }
    }

    func verifyLogin() {
        runAuthTask {
            do {
                if self.loginVerificationRequestId.isEmpty {
                    self.loginVerificationRequestId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                }
                try await self.api.verifyLogin(
                    email: self.email,
                    code: self.code,
                    challengeToken: self.challengeToken,
                    verificationRequestId: self.loginVerificationRequestId
                )
                await self.loadBootstrap()
            } catch let error as AloAPIError {
                self.errorMessage = error.message
            } catch {
                self.errorMessage = "Не удалось подключиться к серверу."
            }
        }
    }

    func verifyEmail() {
        runAuthTask {
            do {
                try await self.api.verifyEmail(email: self.email, code: self.code)
                await self.loadBootstrap()
            } catch let error as AloAPIError {
                self.errorMessage = error.message
            } catch {
                self.errorMessage = "Не удалось подключиться к серверу."
            }
        }
    }

    func logout() {
        Task {
            isBusy = true
            await AloPushCoordinator.shared.unregister(api: api)
            _ = try? await api.logout()
            stopChatRealtime()
            calls.stop()
            api.clearCookies()
            clearPendingChatOutboxForLogout()
            clearBootstrapCache()
            bootstrap = nil
            activeConversation = nil
            selectedProfile = nil
            commentsPost = nil
            comments = []
            composeText = ""
            messageText = ""
            commentText = ""
            pendingForwardDraft = nil
            pendingForwardTitle = ""
            code = ""
            password = ""
            notice = "Вы вышли из аккаунта."
            errorMessage = ""
            activeTab = .feed
            authMode = .login
            phase = .auth
            isBusy = false
        }
    }

    func createPost(localAttachments: [AloLocalAttachment] = [], captchaToken: String? = nil) {
        let body = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !localAttachments.isEmpty else { return }
        Task {
            isBusy = true
            do {
                var media = [AloMessageAttachment]()
                for attachment in localAttachments {
                    media.append(try await api.uploadAttachment(attachment, purpose: "post"))
                }
                let post = try await api.createPost(body: body, media: media, captchaToken: captchaToken)
                composeText = ""
                if let data = bootstrap {
                    bootstrap = AloBootstrapDataPatch.prepend(post, to: data)
                }
            } catch let error as AloAPIError {
                if handleChallenge(error, retry: { token in self.createPost(localAttachments: localAttachments, captchaToken: token) }) { return }
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось опубликовать пост."
            }
            isBusy = false
        }
    }

    func toggleLike(_ post: AloPost) {
        Task {
            do {
                let updated = try await api.toggleLike(postId: post.id)
                if let data = bootstrap {
                    bootstrap = AloBootstrapDataPatch.replace(updated, in: data)
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить лайк."
            }
        }
    }

    func deletePost(_ post: AloPost) {
        Task {
            do {
                let deletedId = try await api.deletePost(postId: post.id)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    removePost(id: deletedId)
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось удалить пост."
            }
        }
    }

    func openConversation(_ summary: AloConversationSummary) {
        activeTab = .messages
        let cachedMessages = bootstrap?.activePeerId == summary.peerId ? bootstrap?.activeMessages ?? [] : []
        let fallbackDetail = bootstrap.flatMap {
            api.loadCachedConversation(peerId: summary.peerId, ownerUserId: $0.me.id)
        } ?? AloConversationDetail(summary: summary, items: cachedMessages)
        let projectedFallback = mergePendingLocalMessages(into: fallbackDetail)
        activeConversation = projectedFallback
        startConversationLive(projectedFallback)
        Task {
            do {
                let detail = try await api.loadConversation(peerId: summary.peerId)
                let mergedDetail = mergePendingLocalMessages(into: detail)
                activeConversation = mergedDetail
                startConversationLive(mergedDetail)
            } catch let error as AloAPIError {
                if !shouldQueueForConnectivity(error) {
                    errorMessage = error.message
                }
            } catch {
                // Keep the locally opened conversation visible while connection is unavailable.
            }
        }
    }

    func closeConversation() {
        stopConversationLive()
        activeConversation = nil
    }

    func toggleMessageReaction(_ message: AloChatMessage, emoji: String) {
        guard let conversation = activeConversation else { return }
        guard !message.isCallLogMessage, message.id > 0, !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = pendingTarget(for: conversation)
        let desiredEmoji = message.reactions.contains(where: { $0.reactedByMe && $0.emoji == emoji }) ? "" : emoji
        applyOptimisticReaction(messageId: message.id, emoji: emoji)
        enqueuePendingChatOperation(.reaction(target: target, messageId: message.id, emoji: desiredEmoji))
        Task {
            await processPendingChatOperations()
        }
    }

    func editMessage(_ message: AloChatMessage, body: String, onDone: (() -> Void)? = nil) {
        guard let conversation = activeConversation else { return }
        let nextBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextBody.isEmpty || !message.attachments.isEmpty else { return }
        let target = pendingTarget(for: conversation)
        pendingChatMessageIds.insert(message.id)
        if let activeConversation {
            let updatedMessage = message.replacingBody(nextBody, editedAt: currentTimestamp())
            self.activeConversation = activeConversation.replacingMessage(updatedMessage)
        }
        enqueuePendingChatOperation(
            .edit(
                target: target,
                messageId: message.id,
                originalBody: message.body,
                body: nextBody,
                attachments: message.attachments,
                forwardFrom: message.forwardFrom,
                encryptedPayload: nil
            )
        )
        onDone?()
        Task {
            await processPendingChatOperations()
        }
    }

    func openProfile(_ user: AloEntitySummary) {
        guard !user.isChannel else {
            notice = "Профили пабликов подключу отдельным экраном."
            return
        }
        openProfile(userId: user.id)
    }

    func openProfile(userId: Int) {
        guard userId > 0 else { return }
        Task {
            isProfileLoading = true
            do {
                selectedProfile = try await api.loadUserProfile(userId: userId)
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось открыть профиль."
            }
            isProfileLoading = false
        }
    }

    func closeProfile() {
        selectedProfile = nil
    }

    func openConversation(with profile: AloUserProfile) {
        closeProfile()
        activeTab = .messages
        let emptyFallbackDetail = AloConversationDetail(
            peerId: profile.user.id,
            kind: "direct",
            roomId: 0,
            entityType: "",
            title: profile.user.name,
            subtitle: profile.user.online ? "в сети" : "был(а) недавно",
            avatarUrl: profile.user.avatarUrl,
            online: profile.user.online,
            lastSeenAt: "",
            items: []
        )
        let fallbackDetail = bootstrap.flatMap {
            api.loadCachedConversation(peerId: profile.user.id, ownerUserId: $0.me.id)
        } ?? emptyFallbackDetail
        let projectedFallback = mergePendingLocalMessages(into: fallbackDetail)
        activeConversation = projectedFallback
        startConversationLive(projectedFallback)
        Task {
            do {
                let detail = try await api.loadConversation(peerId: profile.user.id)
                let mergedDetail = mergePendingLocalMessages(into: detail)
                activeConversation = mergedDetail
                startConversationLive(mergedDetail)
            } catch let error as AloAPIError {
                if !shouldQueueForConnectivity(error) {
                    errorMessage = error.message
                }
            } catch {
                // Keep the locally opened conversation visible while connection is unavailable.
            }
        }
    }

    func sendMessage(
        localAttachments: [AloLocalAttachment] = [],
        forwardFrom: AloForwardMeta? = nil,
        captchaToken: String? = nil,
        onSent: (() -> Void)? = nil
    ) {
        guard let conversation = activeConversation else { return }
        let body = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !localAttachments.isEmpty || forwardFrom != nil else { return }
        if captchaToken == nil, (!localAttachments.isEmpty || forwardFrom != nil) {
            sendDraftMessageOptimistically(
                body: body,
                conversation: conversation,
                localAttachments: localAttachments,
                forwardFrom: forwardFrom
            )
            onSent?()
            return
        }
        if !body.isEmpty && localAttachments.isEmpty && forwardFrom == nil && captchaToken == nil {
            sendTextMessageOptimistically(body: body, conversation: conversation)
            onSent?()
            return
        }
        Task {
            isBusy = true
            do {
                var uploadedAttachments = [AloMessageAttachment]()
                for attachment in localAttachments {
                    uploadedAttachments.append(try await api.uploadE2EEAttachment(attachment))
                }
                try await api.sendMessage(
                    peerId: conversation.peerId,
                    roomId: conversation.roomId,
                    kind: conversation.kind,
                    body: body,
                    attachments: uploadedAttachments,
                    forwardFrom: forwardFrom,
                    captchaToken: captchaToken
                )
                messageText = ""
                let updatedConversation = try await api.loadConversation(peerId: conversation.peerId)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    activeConversation = updatedConversation
                }
                await loadBootstrap(peerId: conversation.peerId)
                onSent?()
            } catch let error as AloAPIError {
                if handleChallenge(error, retry: { token in
                    self.sendMessage(
                        localAttachments: localAttachments,
                        forwardFrom: forwardFrom,
                        captchaToken: token,
                        onSent: onSent
                    )
                }) { return }
                if shouldQueueForConnectivity(error), !body.isEmpty, localAttachments.isEmpty, forwardFrom == nil {
                    sendTextMessageOptimistically(body: body, conversation: conversation)
                    onSent?()
                    isBusy = false
                    return
                }
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось отправить сообщение."
            }
            isBusy = false
        }
    }

    func startConversationLive(_ conversation: AloConversationDetail) {
        stopConversationLive(sendPresenceLeave: false)
        conversationRefreshTask = Task { [weak self] in
            await self?.sendChatPresence(for: conversation)
        }
        if let ownerUserId = bootstrap?.me.id {
            startChatRealtime(ownerUserId: ownerUserId)
        }
    }

    func stopConversationLive(sendPresenceLeave: Bool = true) {
        conversationRefreshTask?.cancel()
        conversationRefreshTask = nil
        if sendPresenceLeave {
            Task { try? await api.updateChatPresence(activePeerId: 0) }
        }
    }

    func sendTypingIfNeeded() {
        guard let conversation = activeConversation else { return }
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTypingSentAt) > 1.4 else { return }
        lastTypingSentAt = now
        Task {
            try? await api.sendTyping(conversation: conversation)
        }
    }

    private func sendChatPresence(for conversation: AloConversationDetail) async {
        let activePeerId = conversation.kind == "direct" ? conversation.peerId : 0
        try? await api.updateChatPresence(activePeerId: activePeerId)
    }

    private func refreshActiveConversation(peerId: Int, roomId: Int, kind: String) async {
        guard let current = activeConversation,
              current.peerId == peerId,
              current.roomId == roomId,
              current.kind == kind else { return }
        do {
            let refreshed = try await api.loadConversation(peerId: peerId)
            activeConversation = mergePendingLocalMessages(into: refreshed)
            if !pendingChatOperations.isEmpty {
                schedulePendingChatRetry(after: 250_000_000)
            }
        } catch {
            // Live refresh should be quiet; explicit user actions still surface errors.
        }
    }

    private func startChatRealtime(ownerUserId: Int) {
        guard ownerUserId > 0 else { return }
        if chatStreamOwnerUserId == ownerUserId, chatStreamTask != nil { return }
        stopChatRealtime()
        chatStreamOwnerUserId = ownerUserId

        chatStreamTask = Task { [weak self] in
            guard let self else { return }
            var retryDelay: UInt64 = 500_000_000
            while !Task.isCancelled {
                let cursor = self.chatStreamCursor(ownerUserId: ownerUserId)
                do {
                    for try await event in self.api.chatEventStream(afterCursor: cursor) {
                        if Task.isCancelled { return }
                        self.handleChatStreamEvent(event, ownerUserId: ownerUserId)
                        retryDelay = 500_000_000
                    }
                } catch let error as AloAPIError where error.status == 401 {
                    self.phase = .auth
                    return
                } catch {
                    // Offline cache remains readable; reconnect resumes from the last acknowledged cursor.
                }

                try? await Task.sleep(nanoseconds: retryDelay)
                retryDelay = min(retryDelay * 2, 20_000_000_000)
            }
        }
    }

    private func stopChatRealtime() {
        chatStreamTask?.cancel()
        chatStreamTask = nil
        chatStreamRefreshTask?.cancel()
        chatStreamRefreshTask = nil
        chatStreamOwnerUserId = 0
        chatStreamNeedsActiveRefresh = false
    }

    private func handleChatStreamEvent(_ event: AloChatStreamEvent, ownerUserId: Int) {
        let storedCursor = chatStreamCursor(ownerUserId: ownerUserId)
        if event.name == "chat_ready" {
            let serverCursor = event.payload.int("latestCursor")
            if serverCursor < storedCursor {
                setChatStreamCursor(serverCursor, ownerUserId: ownerUserId)
            }
            return
        }
        if event.name == "chat_resync" {
            setChatStreamCursor(event.payload.int("latestCursor"), ownerUserId: ownerUserId)
            scheduleChatStreamRefresh(refreshActive: activeConversation != nil)
            return
        }
        guard event.name == "chat_update", event.id > storedCursor else { return }
        setChatStreamCursor(event.id, ownerUserId: ownerUserId)
        scheduleChatStreamRefresh(refreshActive: chatEventTouchesActiveConversation(event.payload))
    }

    private func chatEventTouchesActiveConversation(_ payload: [String: Any]) -> Bool {
        guard let conversation = activeConversation else { return false }
        if payload.string("chatKind") == "group" {
            return conversation.kind == "group" && conversation.roomId == payload.int("roomId")
        }
        guard conversation.kind == "direct" else { return false }
        let senderId = payload.int("senderId")
        let recipientId = payload.int("recipientId")
        return senderId == conversation.peerId || recipientId == conversation.peerId
    }

    private func scheduleChatStreamRefresh(refreshActive: Bool) {
        chatStreamNeedsActiveRefresh = chatStreamNeedsActiveRefresh || refreshActive
        guard chatStreamRefreshTask == nil else { return }
        chatStreamRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let self, !Task.isCancelled else { return }
            let shouldRefreshActive = self.chatStreamNeedsActiveRefresh
            self.chatStreamNeedsActiveRefresh = false
            self.chatStreamRefreshTask = nil
            await self.refreshChatStateFromStream(refreshActive: shouldRefreshActive)
        }
    }

    private func refreshChatStateFromStream(refreshActive: Bool) async {
        do {
            let conversations = try await api.loadConversationSummaries()
            if let current = bootstrap {
                bootstrap = replacingConversations(in: current, with: conversations)
            }
        } catch {
            return
        }

        guard refreshActive, let current = activeConversation else { return }
        await refreshActiveConversation(
            peerId: current.peerId,
            roomId: current.roomId,
            kind: current.kind
        )
        if !pendingChatOperations.isEmpty {
            schedulePendingChatRetry(after: 250_000_000)
        }
    }

    private func replacingConversations(
        in data: AloBootstrapData,
        with conversations: [AloConversationSummary]
    ) -> AloBootstrapData {
        AloBootstrapData(
            me: data.me,
            feedPopular: data.feedPopular,
            feedSubscriptions: data.feedSubscriptions,
            notifications: data.notifications,
            notificationSettings: data.notificationSettings,
            searchUsers: data.searchUsers,
            searchChannels: data.searchChannels,
            profileStats: data.profileStats,
            profilePosts: data.profilePosts,
            privacySettings: data.privacySettings,
            conversations: conversations,
            activePeerId: data.activePeerId,
            activeMessages: data.activeMessages
        )
    }

    private func chatStreamCursor(ownerUserId: Int) -> Int {
        UserDefaults.standard.integer(forKey: "alo.ios.chat-stream.cursor.\(ownerUserId)")
    }

    private func setChatStreamCursor(_ cursor: Int, ownerUserId: Int) {
        UserDefaults.standard.set(
            max(0, cursor),
            forKey: "alo.ios.chat-stream.cursor.\(ownerUserId)"
        )
    }

    func deleteMessages(_ ids: [Int], mode: String = "me", onDone: (() -> Void)? = nil) {
        guard let conversation = activeConversation else { return }
        let safeIds = ids.filter { $0 > 0 }
        guard !safeIds.isEmpty else { return }
        let target = pendingTarget(for: conversation)
        pendingChatMessageIds.formUnion(safeIds)
        if let activeConversation {
            self.activeConversation = activeConversation.replacingItems(
                activeConversation.items.filter { !safeIds.contains($0.id) }
            )
        }
        enqueuePendingChatOperation(.delete(target: target, messageIds: safeIds, mode: mode))
        onDone?()
        Task {
            await processPendingChatOperations()
        }
    }

    func isChatMessagePending(_ message: AloChatMessage) -> Bool {
        pendingChatMessageIds.contains(message.id)
    }

    func sendFriendRequest(_ user: AloEntitySummary, captchaToken: String? = nil) {
        sendFriendRequest(userId: user.id, captchaToken: captchaToken)
    }

    func sendFriendRequest(userId: Int, captchaToken: String? = nil) {
        Task {
            do {
                _ = try await api.sendFriendRequest(userId: userId, captchaToken: captchaToken)
                notice = "Заявка отправлена."
                await loadBootstrap()
                if selectedProfile?.id == userId {
                    selectedProfile = try? await api.loadUserProfile(userId: userId)
                }
            } catch let error as AloAPIError {
                if handleChallenge(error, retry: { token in self.sendFriendRequest(userId: userId, captchaToken: token) }) { return }
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось отправить заявку."
            }
        }
    }

    func toggleFollowUser(userId: Int) {
        Task {
            do {
                let following = try await api.toggleFollowUser(userId: userId)
                notice = following ? "Подписка оформлена." : "Подписка отменена."
                await loadBootstrap()
                if selectedProfile?.id == userId {
                    selectedProfile = try? await api.loadUserProfile(userId: userId)
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось изменить подписку."
            }
        }
    }

    func respondFriendRequest(_ item: AloNotificationItem, accept: Bool) {
        guard item.actionableFriendRequestId > 0 else { return }
        respondFriendRequest(requestId: item.actionableFriendRequestId, accept: accept)
    }

    func respondFriendRequest(requestId: Int, accept: Bool) {
        Task {
            do {
                _ = try await api.respondFriendRequest(requestId: requestId, accept: accept)
                await loadBootstrap()
                if let profile = selectedProfile {
                    selectedProfile = try? await api.loadUserProfile(userId: profile.id)
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить заявку."
            }
        }
    }

    func updateProfileCover(style: String) {
        Task {
            do {
                let updated = try await api.updateProfileCover(coverStyle: style)
                if let data = bootstrap {
                    bootstrap = AloBootstrapDataPatch.replaceMe(updated, in: data)
                }
                if selectedProfile?.id == updated.id {
                    selectedProfile = try? await api.loadUserProfile(userId: updated.id)
                }
                await loadBootstrap()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить баннер."
            }
        }
    }

    func updateProfileAvatar(data: Data, mime: String = "image/jpeg") {
        Task {
            do {
                let attachment = AloLocalAttachment(
                    data: data,
                    mime: mime,
                    type: "image",
                    name: "profile-avatar.jpg"
                )
                let uploaded = try await api.uploadAttachment(attachment, purpose: "avatar")
                let updated = try await api.updateProfileAvatar(avatarUrl: uploaded.url)
                if let data = bootstrap {
                    bootstrap = AloBootstrapDataPatch.replaceMe(updated, in: data)
                }
                if selectedProfile?.id == updated.id {
                    selectedProfile = try? await api.loadUserProfile(userId: updated.id)
                }
                await loadBootstrap()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить аватар."
            }
        }
    }

    func updateGroupAvatar(conversation: AloConversationDetail, data: Data, mime: String = "image/jpeg") {
        guard conversation.kind == "group", conversation.roomId > 0 else { return }
        Task {
            do {
                let attachment = AloLocalAttachment(
                    data: data,
                    mime: mime,
                    type: "image",
                    name: "group-avatar-\(conversation.roomId).jpg"
                )
                let uploaded = try await api.uploadAttachment(attachment, purpose: "avatar")
                activeConversation = try await api.updateGroupChatProfile(
                    roomId: conversation.roomId,
                    title: conversation.title,
                    avatarUrl: uploaded.url
                )
                await loadBootstrap(peerId: conversation.peerId)
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить аватарку группы."
            }
        }
    }

    func leaveGroupChat(_ conversation: AloConversationDetail) {
        guard conversation.kind == "group", conversation.roomId > 0 else { return }
        Task {
            do {
                try await api.leaveGroupChat(roomId: conversation.roomId)
                closeConversation()
                await loadBootstrap()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось покинуть группу."
            }
        }
    }

    func deleteGroupChat(_ conversation: AloConversationDetail) {
        guard conversation.kind == "group", conversation.roomId > 0 else { return }
        Task {
            do {
                try await api.deleteGroupChat(roomId: conversation.roomId)
                closeConversation()
                await loadBootstrap()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось удалить группу."
            }
        }
    }

    func updatePrivacy(profileVisibility: String) {
        let current = bootstrap?.privacySettings ?? .default
        updatePrivacy(settings: AloPrivacySettings(
            allowFriendRequests: current.allowFriendRequests,
            messageScope: current.messageScope,
            allowMessageForwards: current.allowMessageForwards,
            callScope: current.callScope,
            profileVisibility: profileVisibility,
            hideActivity: current.hideActivity
        ))
    }

    func updatePrivacy(settings: AloPrivacySettings) {
        Task {
            do {
                _ = try await api.updatePrivacy(settings: settings)
                await loadBootstrap()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить приватность."
            }
        }
    }

    func updateNotificationSettings(_ settings: AloNotificationSettings) {
        Task {
            do {
                _ = try await api.updateNotificationSettings(settings)
                await loadBootstrap()
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить уведомления."
            }
        }
    }

    func clearLocalCache() {
        clearBootstrapCache()
        AloSecureMediaStore.shared.clearCache()
        AloImageCache.removeAll()
        URLCache.shared.removeAllCachedResponses()
        notice = "Локальный кэш очищен."
    }

    func openComments(for post: AloPost) {
        commentsPost = post
        commentText = ""
        Task { await loadComments(for: post.id) }
    }

    func closeComments() {
        commentsPost = nil
        comments = []
        commentText = ""
    }

    func loadComments(for postId: Int) async {
        commentsLoading = true
        do {
            comments = try await api.loadPostComments(postId: postId)
        } catch let error as AloAPIError {
            errorMessage = error.message
        } catch {
            errorMessage = "Не удалось загрузить комментарии."
        }
        commentsLoading = false
    }

    func createComment(captchaToken: String? = nil) {
        guard let post = commentsPost else { return }
        let body = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Task {
            do {
                let result = try await api.createComment(postId: post.id, body: body, captchaToken: captchaToken)
                commentText = ""
                comments.append(result.comment)
                if let updatedPost = result.post {
                    replacePost(updatedPost)
                    commentsPost = updatedPost
                }
            } catch let error as AloAPIError {
                if handleChallenge(error, retry: { token in self.createComment(captchaToken: token) }) { return }
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось отправить комментарий."
            }
        }
    }

    func toggleCommentLike(_ comment: AloPostComment) {
        guard let post = commentsPost else { return }
        Task {
            do {
                let updated = try await api.toggleCommentLike(postId: post.id, commentId: comment.id)
                comments = comments.map { $0.id == updated.id ? updated : $0 }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось обновить лайк."
            }
        }
    }

    func deleteComment(_ comment: AloPostComment) {
        guard let post = commentsPost else { return }
        Task {
            do {
                let updatedPost = try await api.deleteComment(postId: post.id, commentId: comment.id)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    comments.removeAll { $0.id == comment.id }
                }
                if let updatedPost {
                    replacePost(updatedPost)
                    commentsPost = updatedPost
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось удалить комментарий."
            }
        }
    }

    func completeChallenge(token: String) {
        let retry = pendingChallengeRetry
        pendingChallengeRetry = nil
        humanChallenge = nil
        retry?(token)
    }

    func closeChallenge() {
        pendingChallengeRetry = nil
        humanChallenge = nil
    }

    private func runAuthTask(_ operation: @escaping () async -> Void) {
        isBusy = true
        errorMessage = ""
        notice = ""
        Task {
            await operation()
            isBusy = false
        }
    }

    private func replacePost(_ post: AloPost) {
        if let data = bootstrap {
            bootstrap = AloBootstrapDataPatch.replace(post, in: data)
        }
        if selectedProfile?.posts.contains(where: { $0.id == post.id }) == true,
           let profile = selectedProfile {
            selectedProfile = AloUserProfilePatch.replace(post, in: profile)
        }
    }

    private func removePost(id postId: Int) {
        if let data = bootstrap {
            bootstrap = AloBootstrapDataPatch.remove(postId, from: data)
        }
        if let profile = selectedProfile {
            selectedProfile = AloUserProfilePatch.remove(postId, from: profile)
        }
        if commentsPost?.id == postId {
            commentsPost = nil
            comments = []
        }
    }

    private func pendingTarget(for conversation: AloConversationDetail) -> PendingChatTarget {
        PendingChatTarget(peerId: conversation.peerId, roomId: conversation.roomId, kind: conversation.kind)
    }

    private func conversation(for target: PendingChatTarget) -> AloConversationDetail {
        if let activeConversation,
           pendingTarget(for: activeConversation) == target {
            return activeConversation
        }
        return AloConversationDetail(
            peerId: target.peerId,
            kind: target.kind,
            roomId: target.roomId,
            title: "",
            subtitle: "",
            avatarUrl: "",
            online: false,
            lastSeenAt: "",
            items: []
        )
    }

    private func isActiveConversation(_ target: PendingChatTarget) -> Bool {
        guard let activeConversation else { return false }
        return pendingTarget(for: activeConversation) == target
    }

    private func currentTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func shouldQueueForConnectivity(_ error: AloAPIError) -> Bool {
        error.status == 0 || error.code == "CONNECTION_FAILED"
    }

    private func shouldKeepPending(_ error: AloAPIError) -> Bool {
        if shouldQueueForConnectivity(error) { return true }
        return [
            "E2EE_KEYS_MISSING",
            "E2EE_REQUESTER_DEVICE_NOT_REGISTERED",
            "LIBSIGNAL_KEYS_MISSING",
            "LIBSIGNAL_PREKEYS_MISSING",
            "LIBSIGNAL_GROUP_KEYS_MISSING",
            "LIBSIGNAL_REQUESTER_DEVICE_NOT_REGISTERED"
        ].contains(error.code)
    }

    private func retryDelay(for error: AloAPIError) -> UInt64 {
        shouldQueueForConnectivity(error) ? 2_500_000_000 : 15_000_000_000
    }

    private func mergePendingLocalMessages(into refreshed: AloConversationDetail) -> AloConversationDetail {
        let target = pendingTarget(for: refreshed)
        let deletedMessageIds = pendingDeletedMessageIds(for: target)
        let visibleServerItems = AloPendingChatProjection.removingDeletedMessages(
            from: refreshed.items,
            deletedMessageIds: deletedMessageIds
        )
        let projected = refreshed.replacingItems(visibleServerItems)
        let pending = pendingLocalMessages(for: target)
        guard !pending.isEmpty else { return projected }
        return projected.replacingItems(
            AloPendingChatProjection.mergingPendingMessages(
                serverMessages: visibleServerItems,
                pendingMessages: pending
            )
        )
    }

    private func pendingLocalMessages(for target: PendingChatTarget) -> [AloChatMessage] {
        let senderId = bootstrap?.me.id ?? pendingChatOperationsOwnerUserId ?? 0
        return pendingChatOperations.compactMap { operation in
            switch operation {
            case let .sendText(localId, operationTarget, body, createdAt, _, _):
                guard operationTarget == target else { return nil }
                return AloChatMessage(
                    localId: localId,
                    senderId: senderId,
                    recipientId: target.kind == "direct" ? target.peerId : 0,
                    body: body,
                    createdAt: createdAt
                )
            case let .sendDraft(
                localId,
                operationTarget,
                body,
                createdAt,
                attachments,
                _,
                forwardFrom,
                _,
                _
            ):
                guard operationTarget == target else { return nil }
                return AloChatMessage(
                    localId: localId,
                    senderId: senderId,
                    recipientId: target.kind == "direct" ? target.peerId : 0,
                    body: body,
                    createdAt: createdAt,
                    attachments: attachments.map(AloMessageAttachment.init(local:)),
                    forwardFrom: forwardFrom
                )
            default:
                return nil
            }
        }
    }

    private func pendingDeletedMessageIds(for target: PendingChatTarget) -> Set<Int> {
        pendingChatOperations.reduce(into: Set<Int>()) { result, operation in
            guard case let .delete(operationTarget, messageIds, _) = operation,
                  operationTarget == target else { return }
            result.formUnion(messageIds)
        }
    }

    private func enqueuePendingChatOperation(_ operation: PendingChatOperation) {
        if pendingChatOperationsOwnerUserId == nil {
            guard let ownerUserId = bootstrap?.me.id else { return }
            pendingChatOperationsOwnerUserId = ownerUserId
        }
        pendingChatOperations.append(operation)
        persistPendingChatOperations()
        schedulePendingChatRetry()
    }

    private func schedulePendingChatRetry(after delay: UInt64 = 1_500_000_000) {
        guard pendingChatRetryTask == nil else { return }
        pendingChatRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await MainActor.run {
                self?.pendingChatRetryTask = nil
            }
            await self?.processPendingChatOperations()
        }
    }

    private func sendTextMessageOptimistically(body: String, conversation: AloConversationDetail) {
        let localId = nextLocalMessageId
        nextLocalMessageId -= 1
        let target = pendingTarget(for: conversation)
        let createdAt = currentTimestamp()
        let message = AloChatMessage(
            localId: localId,
            senderId: bootstrap?.me.id ?? 0,
            recipientId: conversation.kind == "direct" ? conversation.peerId : 0,
            body: body,
            createdAt: createdAt
        )
        pendingChatMessageIds.insert(localId)
        activeConversation = conversation.replacingItems(conversation.items + [message])
        messageText = ""
        enqueuePendingChatOperation(
            .sendText(
                localId: localId,
                target: target,
                body: body,
                createdAt: createdAt,
                clientMessageId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                encryptedPayload: nil
            )
        )
        Task {
            await processPendingChatOperations()
        }
    }

    private func sendDraftMessageOptimistically(
        body: String,
        conversation: AloConversationDetail,
        localAttachments: [AloLocalAttachment],
        forwardFrom: AloForwardMeta?
    ) {
        let localId = nextLocalMessageId
        nextLocalMessageId -= 1
        let target = pendingTarget(for: conversation)
        let createdAt = currentTimestamp()
        let message = AloChatMessage(
            localId: localId,
            senderId: bootstrap?.me.id ?? 0,
            recipientId: conversation.kind == "direct" ? conversation.peerId : 0,
            body: body,
            createdAt: createdAt,
            attachments: localAttachments.map(AloMessageAttachment.init(local:)),
            forwardFrom: forwardFrom
        )
        pendingChatMessageIds.insert(localId)
        activeConversation = conversation.replacingItems(conversation.items + [message])
        messageText = ""
        enqueuePendingChatOperation(
            .sendDraft(
                localId: localId,
                target: target,
                body: body,
                createdAt: createdAt,
                attachments: localAttachments,
                uploadedAttachments: [],
                forwardFrom: forwardFrom,
                clientMessageId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                encryptedPayload: nil
            )
        )
        Task {
            await processPendingChatOperations()
        }
    }

    private func applyOptimisticReaction(messageId: Int, emoji: String) {
        guard let activeConversation,
              let message = activeConversation.items.first(where: { $0.id == messageId }) else { return }
        let previousMine = message.reactions.first(where: { $0.reactedByMe })
        let hasTargetReaction = message.reactions.contains(where: { $0.emoji == emoji })
        var reactions = message.reactions.compactMap { reaction -> AloMessageReaction? in
            if reaction.emoji == emoji, reaction.reactedByMe {
                let nextCount = reaction.count - 1
                guard nextCount > 0 else { return nil }
                return AloMessageReaction(emoji: reaction.emoji, count: nextCount, reactedByMe: false)
            }
            if reaction.emoji == emoji {
                return AloMessageReaction(emoji: reaction.emoji, count: reaction.count + 1, reactedByMe: true)
            }
            if reaction.reactedByMe {
                let nextCount = reaction.count - 1
                guard nextCount > 0 else { return nil }
                return AloMessageReaction(emoji: reaction.emoji, count: nextCount, reactedByMe: false)
            }
            return reaction
        }
        if previousMine?.emoji != emoji, !hasTargetReaction {
            reactions.append(AloMessageReaction(emoji: emoji, count: 1, reactedByMe: true))
        }
        self.activeConversation = activeConversation.replacingMessage(message.replacingReactions(reactions))
    }

    private func processPendingChatOperations() async {
        pendingChatRetryTask?.cancel()
        pendingChatRetryTask = nil
        guard !isProcessingPendingChatOperations else { return }
        isProcessingPendingChatOperations = true
        defer { isProcessingPendingChatOperations = false }

        var operationsRemainingInPass = pendingChatOperations.count
        var deferredRetryDelay: UInt64?
        while !pendingChatOperations.isEmpty, operationsRemainingInPass > 0 {
            operationsRemainingInPass -= 1
            let operation = pendingChatOperations[0]
            do {
                switch operation {
                case let .sendText(localId, target, body, createdAt, clientMessageId, encryptedPayload):
                    let preparedPayload: [String: Any]
                    if let encryptedPayload, !isSavedTarget(target) {
                        preparedPayload = encryptedPayload
                    } else {
                        preparedPayload = try await api.prepareEncryptedMessagePayload(
                            peerId: target.peerId,
                            roomId: target.roomId,
                            kind: target.kind,
                            body: body,
                            attachments: [],
                            forwardFrom: nil
                        )
                        pendingChatOperations[0] = .sendText(
                            localId: localId,
                            target: target,
                            body: body,
                            createdAt: createdAt,
                            clientMessageId: clientMessageId,
                            encryptedPayload: preparedPayload
                        )
                        persistPendingChatOperations()
                    }
                    let acknowledgement = try await api.sendPreparedMessage(
                        peerId: target.peerId,
                        roomId: target.roomId,
                        kind: target.kind,
                        encryptedPayload: preparedPayload,
                        clientMessageId: clientMessageId
                    )
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    pendingChatMessageIds.remove(localId)
                    acknowledgePendingMessage(
                        localId: localId,
                        target: target,
                        acknowledgement: acknowledgement
                    )
                    await refreshConversationIfCurrent(target, droppingLocalId: localId)

                case let .sendDraft(
                    localId,
                    target,
                    body,
                    createdAt,
                    attachments,
                    existingUploadedAttachments,
                    forwardFrom,
                    clientMessageId,
                    encryptedPayload
                ):
                    var uploadedAttachments = existingUploadedAttachments
                    if uploadedAttachments.count < attachments.count {
                        for index in uploadedAttachments.count..<attachments.count {
                            uploadedAttachments.append(try await api.uploadE2EEAttachment(attachments[index]))
                            pendingChatOperations[0] = .sendDraft(
                                localId: localId,
                                target: target,
                                body: body,
                                createdAt: createdAt,
                                attachments: attachments,
                                uploadedAttachments: uploadedAttachments,
                                forwardFrom: forwardFrom,
                                clientMessageId: clientMessageId,
                                encryptedPayload: nil
                            )
                            persistPendingChatOperations()
                        }
                    }
                    let preparedPayload: [String: Any]
                    if let encryptedPayload, !isSavedTarget(target) {
                        preparedPayload = encryptedPayload
                    } else {
                        preparedPayload = try await api.prepareEncryptedMessagePayload(
                            peerId: target.peerId,
                            roomId: target.roomId,
                            kind: target.kind,
                            body: body,
                            attachments: uploadedAttachments,
                            forwardFrom: forwardFrom
                        )
                        pendingChatOperations[0] = .sendDraft(
                            localId: localId,
                            target: target,
                            body: body,
                            createdAt: createdAt,
                            attachments: attachments,
                            uploadedAttachments: uploadedAttachments,
                            forwardFrom: forwardFrom,
                            clientMessageId: clientMessageId,
                            encryptedPayload: preparedPayload
                        )
                        persistPendingChatOperations()
                    }
                    let acknowledgement = try await api.sendPreparedMessage(
                        peerId: target.peerId,
                        roomId: target.roomId,
                        kind: target.kind,
                        encryptedPayload: preparedPayload,
                        attachments: uploadedAttachments,
                        forwardFrom: forwardFrom,
                        clientMessageId: clientMessageId
                    )
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    deletePersistedAttachments(clientMessageId: clientMessageId, count: attachments.count)
                    pendingChatMessageIds.remove(localId)
                    acknowledgePendingMessage(
                        localId: localId,
                        target: target,
                        acknowledgement: acknowledgement
                    )
                    await refreshConversationIfCurrent(target, droppingLocalId: localId)

                case let .reaction(target, messageId, emoji):
                    guard messageId > 0 else {
                        pendingChatOperations.removeFirst()
                        persistPendingChatOperations()
                        continue
                    }
                    let reactions = try await api.toggleMessageReaction(
                        conversation: conversation(for: target),
                        messageId: messageId,
                        desiredEmoji: emoji
                    )
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    if let activeConversation,
                       isActiveConversation(target),
                       let message = activeConversation.items.first(where: { $0.id == messageId }) {
                        self.activeConversation = activeConversation.replacingMessage(message.replacingReactions(reactions))
                    }

                case let .edit(
                    target,
                    messageId,
                    originalBody,
                    body,
                    attachments,
                    forwardFrom,
                    encryptedPayload
                ):
                    let preparedPayload: [String: Any]
                    if let encryptedPayload {
                        preparedPayload = encryptedPayload
                    } else {
                        preparedPayload = try await api.prepareEncryptedMessagePayload(
                            peerId: target.peerId,
                            roomId: target.roomId,
                            kind: target.kind,
                            body: body,
                            attachments: attachments,
                            forwardFrom: forwardFrom
                        )
                        pendingChatOperations[0] = .edit(
                            target: target,
                            messageId: messageId,
                            originalBody: originalBody,
                            body: body,
                            attachments: attachments,
                            forwardFrom: forwardFrom,
                            encryptedPayload: preparedPayload
                        )
                        persistPendingChatOperations()
                    }
                    let result = try await api.sendPreparedMessageEdit(
                        conversation: conversation(for: target),
                        messageId: messageId,
                        body: body,
                        encryptedPayload: preparedPayload
                    )
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    pendingChatMessageIds.remove(messageId)
                    if let activeConversation,
                       isActiveConversation(target),
                       let message = activeConversation.items.first(where: { $0.id == messageId }) {
                        self.activeConversation = activeConversation.replacingMessage(
                            message.replacingBody(result.body, editedAt: result.editedAt)
                        )
                    }
                    await refreshConversationIfCurrent(target)

                case let .delete(target, messageIds, mode):
                    try await api.deleteMessages(
                        messageIds: messageIds,
                        conversation: conversation(for: target),
                        mode: mode
                    )
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    messageIds.forEach { pendingChatMessageIds.remove($0) }
                    await refreshConversationIfCurrent(target)
                }
            } catch let error as AloAPIError {
                if shouldQueueForConnectivity(error) {
                    schedulePendingChatRetry(after: retryDelay(for: error))
                    return
                }
                if shouldKeepPending(error) {
                    let deferredOperation = pendingChatOperations.removeFirst()
                    pendingChatOperations.append(deferredOperation)
                    persistPendingChatOperations()
                    let delay = retryDelay(for: error)
                    deferredRetryDelay = min(deferredRetryDelay ?? delay, delay)
                    continue
                }
                clearPendingState(for: operation)
                if error.status == 401 {
                    phase = .auth
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    return
                } else {
                    errorMessage = error.message
                }
                pendingChatOperations.removeFirst()
                persistPendingChatOperations()
                continue
            } catch {
                let deferredOperation = pendingChatOperations.removeFirst()
                pendingChatOperations.append(deferredOperation)
                persistPendingChatOperations()
                deferredRetryDelay = min(deferredRetryDelay ?? 1_500_000_000, 1_500_000_000)
            }
        }
        if !pendingChatOperations.isEmpty {
            schedulePendingChatRetry(after: deferredRetryDelay ?? 15_000_000_000)
        }
    }

    private func acknowledgePendingMessage(
        localId: Int,
        target: PendingChatTarget,
        acknowledgement: AloMessageSendAcknowledgement
    ) {
        guard isActiveConversation(target), let activeConversation else { return }
        let serverId = acknowledgement.messageId
        let alreadyContainsServerMessage = serverId > 0 && activeConversation.items.contains { $0.id == serverId }
        let updatedItems = activeConversation.items.compactMap { message -> AloChatMessage? in
            guard message.id == localId else { return message }
            guard !alreadyContainsServerMessage else { return nil }
            return message.acknowledgingDelivery(
                id: serverId,
                createdAt: acknowledgement.createdAt
            )
        }
        self.activeConversation = activeConversation.replacingItems(updatedItems)
    }

    private func isSavedTarget(_ target: PendingChatTarget) -> Bool {
        target.kind != "group" &&
            target.roomId <= 0 &&
            target.peerId == bootstrap?.me.id
    }

    private func clearPendingState(for operation: PendingChatOperation) {
        switch operation {
        case let .sendText(localId, _, _, _, _, _):
            pendingChatMessageIds.remove(localId)
            if let activeConversation {
                self.activeConversation = activeConversation.replacingItems(
                    activeConversation.items.filter { $0.id != localId }
                )
            }
        case let .sendDraft(localId, _, _, _, attachments, _, _, clientMessageId, _):
            deletePersistedAttachments(clientMessageId: clientMessageId, count: attachments.count)
            pendingChatMessageIds.remove(localId)
            if let activeConversation {
                self.activeConversation = activeConversation.replacingItems(
                    activeConversation.items.filter { $0.id != localId }
                )
            }
        case let .reaction(_, messageId, _):
            pendingChatMessageIds.remove(messageId)
        case let .edit(_, messageId, originalBody, _, _, _, _):
            pendingChatMessageIds.remove(messageId)
            if let activeConversation,
               let message = activeConversation.items.first(where: { $0.id == messageId }) {
                self.activeConversation = activeConversation.replacingMessage(
                    message.replacingBody(originalBody, editedAt: message.editedAt)
                )
            }
        case let .delete(_, messageIds, _):
            messageIds.forEach { pendingChatMessageIds.remove($0) }
        }
    }

    private func persistPendingChatOperations() {
        guard let ownerUserId = pendingChatOperationsOwnerUserId else { return }
        let records = pendingChatOperations.compactMap {
            pendingOperationRecord($0, ownerUserId: ownerUserId)
        }
        try? AloSecureOutboxStore.shared.save(records: records, ownerUserId: ownerUserId)
    }

    private func activatePendingChatOutbox(ownerUserId: Int) {
        guard ownerUserId > 0, pendingChatOperationsOwnerUserId != ownerUserId else { return }
        pendingChatOperations.removeAll()
        pendingChatMessageIds.removeAll()
        nextLocalMessageId = -1
        pendingChatOperationsOwnerUserId = ownerUserId
        restorePendingChatOperations(ownerUserId: ownerUserId)
    }

    private func restorePendingChatOperations(ownerUserId: Int) {
        let restored = AloSecureOutboxStore.shared.load(ownerUserId: ownerUserId).compactMap {
            pendingOperation(from: $0, ownerUserId: ownerUserId)
        }
        guard !restored.isEmpty else { return }
        pendingChatOperations = restored
        for operation in restored {
            switch operation {
            case let .sendText(localId, _, _, _, _, _),
                 let .sendDraft(localId, _, _, _, _, _, _, _, _):
                pendingChatMessageIds.insert(localId)
                nextLocalMessageId = min(nextLocalMessageId, localId - 1)
            case let .reaction(_, messageId, _),
                 let .edit(_, messageId, _, _, _, _, _):
                pendingChatMessageIds.insert(messageId)
            case let .delete(_, messageIds, _):
                pendingChatMessageIds.formUnion(messageIds)
            }
        }
    }

    private func clearPendingChatOutboxForLogout() {
        if let ownerUserId = pendingChatOperationsOwnerUserId ?? bootstrap?.me.id {
            AloSecureOutboxStore.shared.clear(ownerUserId: ownerUserId)
        }
        pendingChatOperations.removeAll()
        pendingChatMessageIds.removeAll()
        pendingChatOperationsOwnerUserId = nil
        nextLocalMessageId = -1
    }

    private func pendingOperationRecord(
        _ operation: PendingChatOperation,
        ownerUserId: Int
    ) -> [String: Any]? {
        switch operation {
        case let .sendText(localId, target, body, createdAt, clientMessageId, encryptedPayload):
            var record: [String: Any] = [
                "type": "sendText",
                "localId": localId,
                "target": pendingTargetRecord(target),
                "body": body,
                "createdAt": createdAt,
                "clientMessageId": clientMessageId
            ]
            if let encryptedPayload { record["encryptedPayload"] = encryptedPayload }
            return record

        case let .sendDraft(
            localId,
            target,
            body,
            createdAt,
            attachments,
            uploadedAttachments,
            forwardFrom,
            clientMessageId,
            encryptedPayload
        ):
            var attachmentRecords = [[String: Any]]()
            for (index, attachment) in attachments.enumerated() {
                let fileId = "\(clientMessageId)-\(index)"
                do {
                    try AloSecureOutboxStore.shared.saveAttachment(
                        attachment.data,
                        id: fileId,
                        ownerUserId: ownerUserId
                    )
                } catch {
                    return nil
                }
                attachmentRecords.append([
                    "fileId": fileId,
                    "mime": attachment.mime,
                    "type": attachment.type,
                    "name": attachment.name,
                    "waveform": attachment.waveform.map(Double.init)
                ])
            }
            var record: [String: Any] = [
                "type": "sendDraft",
                "localId": localId,
                "target": pendingTargetRecord(target),
                "body": body,
                "createdAt": createdAt,
                "attachments": attachmentRecords,
                "uploadedAttachments": uploadedAttachments.map(messageAttachmentRecord),
                "clientMessageId": clientMessageId
            ]
            if let forwardFrom {
                record["forwardFrom"] = ["userId": forwardFrom.userId, "messageId": forwardFrom.messageId]
            }
            if let encryptedPayload { record["encryptedPayload"] = encryptedPayload }
            return record

        case let .reaction(target, messageId, emoji):
            return [
                "type": "reaction",
                "target": pendingTargetRecord(target),
                "messageId": messageId,
                "emoji": emoji
            ]

        case let .edit(target, messageId, originalBody, body, attachments, forwardFrom, encryptedPayload):
            var record: [String: Any] = [
                "type": "edit",
                "target": pendingTargetRecord(target),
                "messageId": messageId,
                "originalBody": originalBody,
                "body": body,
                "attachments": attachments.map(messageAttachmentRecord)
            ]
            if let forwardFrom {
                record["forwardFrom"] = ["userId": forwardFrom.userId, "messageId": forwardFrom.messageId]
            }
            if let encryptedPayload { record["encryptedPayload"] = encryptedPayload }
            return record

        case let .delete(target, messageIds, mode):
            return [
                "type": "delete",
                "target": pendingTargetRecord(target),
                "messageIds": messageIds,
                "mode": mode
            ]
        }
    }

    private func pendingOperation(
        from record: [String: Any],
        ownerUserId: Int
    ) -> PendingChatOperation? {
        guard let target = pendingTarget(from: record.object("target")) else { return nil }
        switch record.string("type") {
        case "sendText":
            let localId = record.int("localId")
            let clientMessageId = record.string("clientMessageId")
            guard localId < 0, !clientMessageId.isEmpty else { return nil }
            return .sendText(
                localId: localId,
                target: target,
                body: record.string("body"),
                createdAt: record.string("createdAt").ifBlank(currentTimestamp()),
                clientMessageId: clientMessageId,
                encryptedPayload: record.optionalObject("encryptedPayload")
            )

        case "sendDraft":
            let localId = record.int("localId")
            let clientMessageId = record.string("clientMessageId")
            guard localId < 0, !clientMessageId.isEmpty else { return nil }
            let attachments = record.array("attachments").compactMap { item -> AloLocalAttachment? in
                guard let data = AloSecureOutboxStore.shared.loadAttachment(
                    id: item.string("fileId"),
                    ownerUserId: ownerUserId
                ) else { return nil }
                let waveform = (item["waveform"] as? [NSNumber] ?? []).map { CGFloat($0.doubleValue) }
                return AloLocalAttachment(
                    data: data,
                    mime: item.string("mime"),
                    type: item.string("type"),
                    name: item.string("name"),
                    waveform: waveform
                )
            }
            guard attachments.count == record.array("attachments").count else { return nil }
            let uploaded = record.array("uploadedAttachments").map(AloMessageAttachment.init)
            let forwardFrom = record.optionalObject("forwardFrom").flatMap {
                AloForwardMeta(userId: $0.int("userId"), messageId: $0.int("messageId"), user: nil)
            }
            return .sendDraft(
                localId: localId,
                target: target,
                body: record.string("body"),
                createdAt: record.string("createdAt").ifBlank(currentTimestamp()),
                attachments: attachments,
                uploadedAttachments: uploaded,
                forwardFrom: forwardFrom,
                clientMessageId: clientMessageId,
                encryptedPayload: record.optionalObject("encryptedPayload")
            )

        case "reaction":
            return .reaction(target: target, messageId: record.int("messageId"), emoji: record.string("emoji"))
        case "edit":
            let forwardFrom = record.optionalObject("forwardFrom").flatMap {
                AloForwardMeta(userId: $0.int("userId"), messageId: $0.int("messageId"), user: nil)
            }
            return .edit(
                target: target,
                messageId: record.int("messageId"),
                originalBody: record.string("originalBody"),
                body: record.string("body"),
                attachments: record.array("attachments").map(AloMessageAttachment.init),
                forwardFrom: forwardFrom,
                encryptedPayload: record.optionalObject("encryptedPayload")
            )
        case "delete":
            let ids = (record["messageIds"] as? [NSNumber] ?? []).map(\.intValue)
            return .delete(target: target, messageIds: ids, mode: record.string("mode"))
        default:
            return nil
        }
    }

    private func pendingTargetRecord(_ target: PendingChatTarget) -> [String: Any] {
        ["peerId": target.peerId, "roomId": target.roomId, "kind": target.kind]
    }

    private func pendingTarget(from record: [String: Any]) -> PendingChatTarget? {
        let peerId = record.int("peerId")
        let roomId = record.int("roomId")
        let kind = record.string("kind")
        guard peerId > 0 || roomId > 0, !kind.isEmpty else { return nil }
        return PendingChatTarget(peerId: peerId, roomId: roomId, kind: kind)
    }

    private func messageAttachmentRecord(_ attachment: AloMessageAttachment) -> [String: Any] {
        [
            "type": attachment.type,
            "url": attachment.url,
            "name": attachment.name,
            "waveform": attachment.waveform.map(Double.init),
            "mediaEncryption": attachment.mediaEncryption
        ]
    }

    private func deletePersistedAttachments(clientMessageId: String, count: Int) {
        guard let ownerUserId = pendingChatOperationsOwnerUserId else { return }
        for index in 0..<count {
            AloSecureOutboxStore.shared.deleteAttachment(
                id: "\(clientMessageId)-\(index)",
                ownerUserId: ownerUserId
            )
        }
    }

    private func refreshConversationIfCurrent(_ target: PendingChatTarget, droppingLocalId: Int? = nil) async {
        guard isActiveConversation(target) else { return }
        do {
            let updatedConversation = try await api.loadConversation(peerId: target.peerId)
            activeConversation = mergePendingLocalMessages(into: updatedConversation)
            await loadBootstrap(peerId: target.peerId)
        } catch {
            schedulePendingChatRetry()
        }
    }

    private func initialBootstrapFlow() async {
        phase = .loading
        errorMessage = ""
        isBusy = true

        for attempt in 0..<4 {
            do {
                let snapshot = try await api.loadBootstrapSnapshot()
                let data = snapshot.data
                saveBootstrapCache(snapshot.raw)
                bootstrap = data
                activatePendingChatOutbox(ownerUserId: data.me.id)
                if let e2eeWarning = api.latestE2EEWarning {
                    notice = e2eeWarning
                }
                phase = .app
                startChatRealtime(ownerUserId: data.me.id)
                AloPushCoordinator.shared.sync(api: api)
                AloVoIPPushCoordinator.shared.sync(api: api)
                calls.startPolling()
                isBusy = false
                return
            } catch let error as AloAPIError {
                if error.status == 401 {
                    phase = .auth
                    isBusy = false
                    return
                }

                if attempt == 3 {
                    if restoreBootstrapCache() {
                        isBusy = false
                        return
                    }
                    errorMessage = error.message
                    phase = .loading
                    isBusy = false
                    return
                }
            } catch {
                if attempt == 3 {
                    if restoreBootstrapCache() {
                        isBusy = false
                        return
                    }
                    errorMessage = "Не удалось загрузить Alo. Проверьте подключение и повторите попытку."
                    phase = .loading
                    isBusy = false
                    return
                }
            }

            try? await Task.sleep(nanoseconds: 900_000_000)
        }
    }

    private func saveBootstrapCache(_ raw: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        let ownerUserId = raw.object("data").object("me").int("id")
        do {
            try AloSecureOfflineCacheStore.shared.save(data, ownerUserId: ownerUserId)
            removeLegacyBootstrapCache()
            UserDefaults.standard.removeObject(forKey: bootstrapCacheKey)
        } catch {}
    }

    @discardableResult
    private func restoreBootstrapCache(peerId: Int = 0) -> Bool {
        guard let data = loadBootstrapCacheData(),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let cached = AloBootstrapData(raw)
        bootstrap = cached
        activatePendingChatOutbox(ownerUserId: cached.me.id)
        if peerId > 0, let summary = cached.conversations.first(where: { $0.peerId == peerId }) {
            let messages = cached.activePeerId == peerId ? cached.activeMessages : []
            let detail = AloConversationDetail(summary: summary, items: messages)
            let projected = mergePendingLocalMessages(into: detail)
            activeConversation = projected
            startConversationLive(projected)
        } else if activeConversation == nil,
                  cached.activePeerId > 0,
                  let summary = cached.conversations.first(where: { $0.peerId == cached.activePeerId }) {
            let detail = AloConversationDetail(summary: summary, items: cached.activeMessages)
            let projected = mergePendingLocalMessages(into: detail)
            activeConversation = projected
            startConversationLive(projected)
        }
        phase = .app
        startChatRealtime(ownerUserId: cached.me.id)
        AloPushCoordinator.shared.sync(api: api)
        AloVoIPPushCoordinator.shared.sync(api: api)
        calls.startPolling()
        errorMessage = ""
        return true
    }

    private func clearBootstrapCache() {
        AloSecureOfflineCacheStore.shared.clearCurrentOwner()
        removeLegacyBootstrapCache()
        UserDefaults.standard.removeObject(forKey: bootstrapCacheKey)
    }

    private func loadBootstrapCacheData() -> Data? {
        if let data = AloSecureOfflineCacheStore.shared.load() {
            return data
        }
        let legacyData: Data?
        if let url = try? bootstrapCacheURL(), let fileData = try? Data(contentsOf: url) {
            legacyData = fileData
        } else {
            legacyData = UserDefaults.standard.data(forKey: bootstrapCacheKey)
        }
        guard let legacyData,
              let raw = try? JSONSerialization.jsonObject(with: legacyData) as? [String: Any] else {
            return nil
        }
        let ownerUserId = raw.object("data").object("me").int("id")
        if (try? AloSecureOfflineCacheStore.shared.save(legacyData, ownerUserId: ownerUserId)) != nil {
            removeLegacyBootstrapCache()
            UserDefaults.standard.removeObject(forKey: bootstrapCacheKey)
        }
        return legacyData
    }

    private func removeLegacyBootstrapCache() {
        if let url = try? bootstrapCacheURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func bootstrapCacheURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("AloOffline", isDirectory: true)
            .appendingPathComponent(bootstrapCacheFileName)
    }

    private func handleChallenge(_ error: AloAPIError, retry: @escaping (String) -> Void) -> Bool {
        guard error.code == "CHALLENGE_REQUIRED" else { return false }
        pendingChallengeRetry = retry
        humanChallenge = HumanChallenge(
            url: api.absoluteURL("/auth/turnstile-mobile.html")!,
            message: error.message.ifBlank("Подтвердите, что вы не робот.")
        )
        isBusy = false
        return true
    }
}

private enum AloUserProfilePatch {
    static func replace(_ post: AloPost, in profile: AloUserProfile) -> AloUserProfile {
        AloUserProfile(
            id: profile.id,
            user: profile.user,
            stats: profile.stats,
            posts: profile.posts.map { $0.id == post.id ? post : $0 },
            likes: profile.likes,
            relation: profile.relation,
            permissions: profile.permissions
        )
    }

    static func remove(_ postId: Int, from profile: AloUserProfile) -> AloUserProfile {
        AloUserProfile(
            id: profile.id,
            user: profile.user,
            stats: profile.stats,
            posts: profile.posts.filter { $0.id != postId },
            likes: profile.likes.filter { $0.id != postId },
            relation: profile.relation,
            permissions: profile.permissions
        )
    }
}

private enum AloBootstrapDataPatch {
    static func prepend(_ post: AloPost, to data: AloBootstrapData) -> AloBootstrapData {
        build(
            from: data,
            feedPopular: [post] + data.feedPopular.filter { $0.id != post.id },
            feedSubscriptions: [post] + data.feedSubscriptions.filter { $0.id != post.id },
            profilePosts: [post] + data.profilePosts.filter { $0.id != post.id }
        )
    }

    static func replace(_ post: AloPost, in data: AloBootstrapData) -> AloBootstrapData {
        build(
            from: data,
            feedPopular: data.feedPopular.map { $0.id == post.id ? post : $0 },
            feedSubscriptions: data.feedSubscriptions.map { $0.id == post.id ? post : $0 },
            profilePosts: data.profilePosts.map { $0.id == post.id ? post : $0 }
        )
    }

    static func remove(_ postId: Int, from data: AloBootstrapData) -> AloBootstrapData {
        build(
            from: data,
            feedPopular: data.feedPopular.filter { $0.id != postId },
            feedSubscriptions: data.feedSubscriptions.filter { $0.id != postId },
            profilePosts: data.profilePosts.filter { $0.id != postId }
        )
    }

    private static func build(
        from data: AloBootstrapData,
        feedPopular: [AloPost],
        feedSubscriptions: [AloPost],
        profilePosts: [AloPost]
    ) -> AloBootstrapData {
        AloBootstrapData(
            me: data.me,
            feedPopular: feedPopular,
            feedSubscriptions: feedSubscriptions,
            notifications: data.notifications,
            notificationSettings: data.notificationSettings,
            searchUsers: data.searchUsers,
            searchChannels: data.searchChannels,
            profileStats: data.profileStats,
            profilePosts: profilePosts,
            privacySettings: data.privacySettings,
            conversations: data.conversations,
            activePeerId: data.activePeerId,
            activeMessages: data.activeMessages
        )
    }

    static func replaceMe(_ user: AloCurrentUser, in data: AloBootstrapData) -> AloBootstrapData {
        AloBootstrapData(
            me: user,
            feedPopular: data.feedPopular,
            feedSubscriptions: data.feedSubscriptions,
            notifications: data.notifications,
            notificationSettings: data.notificationSettings,
            searchUsers: data.searchUsers,
            searchChannels: data.searchChannels,
            profileStats: data.profileStats,
            profilePosts: data.profilePosts,
            privacySettings: data.privacySettings,
            conversations: data.conversations,
            activePeerId: data.activePeerId,
            activeMessages: data.activeMessages
        )
    }
}
