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

    /// A stream event can only advance the durable cursor one sequence at a
    /// time. If an SSE frame is ever lost, reconnect from the last persisted
    /// cursor instead of silently acknowledging a gap.
    private enum ChatStreamDisposition {
        case continueStreaming
        case reconnectFromStoredCursor
    }

    private enum PendingChatOperation {
        case sendText(
            localId: Int,
            target: PendingChatTarget,
            body: String,
            topicId: Int,
            replyToMessageId: Int,
            createdAt: String,
            clientMessageId: String,
            encryptedPayload: [String: Any]?,
            pollDefinition: AloPollDefinition?,
            silent: Bool,
            scheduledAt: String,
            sendWhenOnline: Bool
        )
        case sendDraft(
            localId: Int,
            target: PendingChatTarget,
            body: String,
            topicId: Int,
            replyToMessageId: Int,
            createdAt: String,
            attachments: [AloLocalAttachment],
            uploadedAttachments: [AloMessageAttachment],
            forwardFrom: AloForwardMeta?,
            clientMessageId: String,
            encryptedPayload: [String: Any]?,
            silent: Bool,
            scheduledAt: String,
            sendWhenOnline: Bool
        )
        case reaction(
            target: PendingChatTarget,
            messageId: Int,
            emoji: String,
            operationId: String
        )
        case edit(
            target: PendingChatTarget,
            messageId: Int,
            originalBody: String,
            body: String,
            attachments: [AloMessageAttachment],
            forwardFrom: AloForwardMeta?,
            encryptedPayload: [String: Any]?,
            operationId: String
        )
        case delete(
            target: PendingChatTarget,
            messageIds: [Int],
            mode: String,
            operationId: String
        )
        case pin(
            target: PendingChatTarget,
            messageId: Int,
            pinned: Bool,
            operationId: String
        )
        case reschedule(
            target: PendingChatTarget,
            messageId: Int,
            scheduledMessageId: Int,
            originalScheduledAt: String,
            scheduledAt: String,
            silent: Bool,
            operationId: String
        )
        case cancelScheduled(
            target: PendingChatTarget,
            messageId: Int,
            scheduledMessageId: Int,
            operationId: String
        )

        var target: PendingChatTarget {
            switch self {
            case let .sendText(_, target, _, _, _, _, _, _, _, _, _, _),
                 let .sendDraft(_, target, _, _, _, _, _, _, _, _, _, _, _, _),
                 let .reaction(target, _, _, _),
                 let .edit(target, _, _, _, _, _, _, _),
                 let .delete(target, _, _, _),
                 let .pin(target, _, _, _),
                 let .reschedule(target, _, _, _, _, _, _),
                 let .cancelScheduled(target, _, _, _):
                target
            }
        }

        var outgoingLocalId: Int? {
            switch self {
            case let .sendText(id, _, _, _, _, _, _, _, _, _, _, _),
                 let .sendDraft(id, _, _, _, _, _, _, _, _, _, _, _, _, _): return id
            default: return nil
            }
        }
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
    @Published var shouldOfferAppSettings = false
    @Published var isBusy = false
    @Published private(set) var connectionState: ConnectionState = .connected
    enum ConnectionState { case connected, updating, unavailable }
    private var didStart = false
    private var initialRefreshTask: Task<Void, Never>?
    private var initialRetryTask: Task<Void, Never>?
    private var initialRefreshRevision = 0
    private var initialRetryDelay: Double = 3
    @Published var bootstrap: AloBootstrapData?
    @Published var activeTab: AloAppTab = .feed
    @Published var feedMode: AloFeedMode = .popular
    @Published var composeText = ""
    @Published private(set) var isCreatingPost = false
    @Published private(set) var postPublishingError = ""
    @Published private(set) var lastPublishedPostId = 0
    @Published private(set) var stories = [AloStoryGroup]()
    @Published private(set) var isStoriesLoading = false
    @Published private(set) var isCreatingStory = false
    @Published private(set) var storyPublishingError = ""
    @Published private(set) var businessProfileData: AloBusinessProfileData?
    @Published private(set) var isBusinessProfileLoading = false
    @Published var searchQuery = ""
    @Published var activeConversation: AloConversationDetail?
    @Published var messageText = ""
    @Published var pendingForwardDraft: AloForwardMeta?
    @Published var pendingForwardTitle = ""
    @Published var humanChallenge: HumanChallenge?
    @Published var selectedProfile: AloUserProfile?
    @Published var selectedChannelProfile: AloChannelProfile?
    @Published var channelAdminEvents = [AloChannelAdminEvent]()
    @Published var isProfileLoading = false
    @Published var commentsPost: AloPost?
    @Published var comments = [AloPostComment]()
    @Published var commentText = ""
    @Published var commentsLoading = false
    @Published private(set) var commentsError = ""
    @Published private(set) var isSendingComment = false
    @Published private(set) var lastCreatedCommentId = 0
    @Published private(set) var pendingLikePostIds = Set<Int>()
    @Published private(set) var pendingCommentLikeIds = Set<Int>()
    @Published private(set) var pendingRepostPostIds = Set<Int>()
    private var commentsSession = UUID()
    private var commentsLoadRequest = UUID()
    private var commentsSendRequest = UUID()
    private var commentsLoadTask: Task<Void, Never>?
    @Published private(set) var pendingChatMessageIds = Set<Int>()
    @Published private(set) var failedChatMessageErrors = [Int: String]()
    @Published private(set) var groupManagementRevisions = [Int: Int]()
    @Published private(set) var groupManagementDeltas = [Int: AloGroupManagementDelta]()
    @Published private(set) var requestedForumTopicRoomId = 0
    @Published private(set) var requestedForumTopicId = 0
    @Published private(set) var blockedUserIds = Set<Int>()
    @Published private(set) var blockingUserIds = Set<Int>()
    @Published private(set) var storedAccounts = AloAccountSessionStore.shared.accounts

    let api: AloAPIClient
    private let startupCacheLoader: (() -> Data?)?
    init(api: AloAPIClient = .shared, startupCacheLoader: (() -> Data?)? = nil) {
        self.api = api
        self.startupCacheLoader = startupCacheLoader
    }
    lazy var calls = AloCallCoordinator(api: api, app: self)
    private var challengeToken = ""
    private var loginVerificationRequestId = ""
    private var isCompletingQRCodeLogin = false
    private var pendingChallengeRetry: ((String) -> Void)?
    private var conversationRefreshTask: Task<Void, Never>?
    private var chatStreamTask: Task<Void, Never>?
    private var chatStreamRefreshTask: Task<Void, Never>?
    private var updatesBootstrapRefreshTask: Task<Void, Never>?
    private var blockedUsersRefreshTask: Task<Void, Never>?
    private var updatesAcknowledgementTask: Task<Void, Never>?
    private var searchIndexBackfillTask: Task<Void, Never>?
    private var pendingUpdatesAcknowledgementCursor = 0
    private var chatStreamOwnerUserId = 0
    private var blockedUserStateOwnerUserId = 0
    private var blockedUsersRefreshToken = 0
    private var blockedUsersStateRevision = 0
    private var chatStreamNeedsActiveRefresh = false
    private var pendingChatRetryTask: Task<Void, Never>?
    private var pendingChatRefreshTask: Task<Void, Never>?
    private var pendingChatRefreshRevision = 0
    private var pausedOutgoingMessageIds = Set<Int>()
    private var forumTopicDraftTasks = [String: Task<Void, Never>]()
    private var pendingChatOperations = [PendingChatOperation]()
    private var pendingChatOperationsOwnerUserId: Int?
    private var pendingOutboxWrite: Task<Void, Error>?
    private var isProcessingPendingChatOperations = false
    private var isProcessingDeepLink = false
    private var nextLocalMessageId = -1
    private var lastTypingSentAt: Date = .distantPast
    private var lastBootstrapRefreshAt: Date = .distantPast
    private let bootstrapCacheKey = "alo.ios.bootstrap-cache.v1"
    private let bootstrapCacheFileName = "bootstrap-cache-v1.json"
    private let pendingDeepLinkKey = "alo.ios.pending-deep-link.v1"

    func start() {
        guard !didStart else { return }
        didStart = true
#if DEBUG
        if startupCacheLoader == nil, UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") {
            Task { await installMessengerDesignFixture() }
            return
        }
        if startupCacheLoader == nil, UserDefaults.standard.bool(forKey: "ALO_UI_CALL_PREVIEW") {
            phase = .app
            calls.installDebugPreviewCall()
            return
        }
#endif
        AloSecureOutboxStore.shared.discardLegacyUnscopedData()
        AloDraftAttachmentStore.cleanupExpiredDrafts()
        // Render local content before starting any network request. A first
        // install has no saved account: show sign-in, not a blocking skeleton.
        if !restoreBootstrapCache(startNetwork: false) { phase = .auth }
        retryInitialBootstrap()
    }

    func handleDeepLink(_ url: URL) {
        guard AloDeepLinkTarget(url: url) != nil else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: pendingDeepLinkKey)
        Task { await processPendingDeepLinkIfPossible() }
    }

    func retryInitialBootstrap() {
        guard initialRefreshTask == nil else { return }
        connectionState = .updating
        initialRetryTask?.cancel()
        initialRetryTask = nil
        let revision = initialRefreshRevision
        initialRefreshTask = Task {
            await initialBootstrapFlow(revision: revision)
            guard revision == initialRefreshRevision else { return }
            initialRefreshTask = nil
        }
    }

    func refreshConnectionIfNeeded() {
        if connectionState == .unavailable { retryInitialBootstrap() }
    }

    func suspendConnectionRefresh() {
        guard connectionState != .connected else { return }
        cancelInitialRefresh()
        connectionState = .unavailable
    }

    private func cancelInitialRefresh() {
        initialRefreshRevision += 1
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
        initialRetryTask?.cancel()
        initialRetryTask = nil
        connectionState = .connected
    }

    func loadBootstrap(showAuthOnUnauthorized: Bool = false, peerId: Int = 0) async {
        cancelInitialRefresh()
        isBusy = true
        errorMessage = ""
        do {
            let snapshot = try await api.loadBootstrapSnapshot(peerId: peerId)
            let data = snapshot.data
            saveBootstrapCache(snapshot.raw)
            bootstrap = data
            persistCurrentAccount(data.me)
            configureBlockedUserState(ownerUserId: data.me.id)
            scheduleBlockedUsersRefresh(ownerUserId: data.me.id)
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
                Task(priority: .utility) {
                    try? await api.backfillConversationSearchHistory(peerId: summary.peerId)
                }
            }
            scheduleLocalSearchIndexBackfill(conversations: data.conversations, ownerUserId: data.me.id)
            phase = .app
            startChatRealtime(ownerUserId: data.me.id)
            AloPushCoordinator.shared.sync(api: api)
            AloVoIPPushCoordinator.shared.sync(api: api)
            calls.startPolling()
            await refreshStories(silently: true)
        } catch let error as AloAPIError {
            if error.status == 401 && showAuthOnUnauthorized {
                phase = .auth
            } else if error.code == "CONNECTION_FAILED" || error.status == 0 {
                connectionState = .unavailable
                scheduleConnectionRetry()
                if bootstrap == nil, !restoreBootstrapCache(peerId: peerId) {
                    phase = .loading
                }
            } else {
                errorMessage = error.message
            }
        } catch {
            connectionState = .unavailable
            scheduleConnectionRetry()
            if bootstrap == nil, !restoreBootstrapCache(peerId: peerId) {
                phase = .loading
            }
        }
        isBusy = false
        if phase == .app, UserDefaults.standard.string(forKey: pendingDeepLinkKey) != nil {
            Task { await processPendingDeepLinkIfPossible() }
        }
    }

    private func processPendingDeepLinkIfPossible() async {
        guard phase == .app,
              !isProcessingDeepLink,
              let raw = UserDefaults.standard.string(forKey: pendingDeepLinkKey),
              let url = URL(string: raw),
              let target = AloDeepLinkTarget(url: url) else {
            return
        }
        isProcessingDeepLink = true
        defer { isProcessingDeepLink = false }
        do {
            switch target {
            case .invite(let token):
                let result = try await api.joinGroupInvite(token: token)
                try await finishCommunityDeepLink(result)
            case .community(let username):
                let result = try await api.joinPublicGroup(username: username)
                try await finishCommunityDeepLink(result)
            case .post(let postId):
                let post = try await api.loadPost(postId: postId)
                UserDefaults.standard.removeObject(forKey: pendingDeepLinkKey)
                activeTab = .feed
                openComments(for: post)
            case .user(let userId):
                UserDefaults.standard.removeObject(forKey: pendingDeepLinkKey)
                activeTab = .profile
                openProfile(userId: userId)
            case .channel(let channelId):
                UserDefaults.standard.removeObject(forKey: pendingDeepLinkKey)
                activeTab = .feed
                openChannelProfile(channelId: channelId)
            case .forumTopic(let roomId, let topicId):
                let target = try await api.resolveForumTopicLink(roomId: roomId, topicId: topicId)
                try await finishForumTopicDeepLink(target)
            case .handle(let handle):
                let target = try await api.resolveAppLink(handle: handle)
                switch target.kind {
                case "user":
                    UserDefaults.standard.removeObject(forKey: pendingDeepLinkKey)
                    activeTab = .profile
                    openProfile(userId: target.id)
                case "channel":
                    UserDefaults.standard.removeObject(forKey: pendingDeepLinkKey)
                    activeTab = .feed
                    openChannelProfile(channelId: target.id)
                case "community", "messenger_channel":
                    let result = try await api.joinPublicGroup(username: target.handle)
                    try await finishCommunityDeepLink(result)
                default:
                    UserDefaults.standard.removeObject(forKey: pendingDeepLinkKey)
                    errorMessage = "Ссылка ведёт на неподдерживаемый объект."
                }
            }
        } catch let error as AloAPIError {
            if error.status != 401 && error.status != 0 && error.code != "CONNECTION_FAILED" {
                UserDefaults.standard.removeObject(forKey: pendingDeepLinkKey)
                errorMessage = error.message
            }
        } catch {
            // Keep the link pending and retry after connectivity is restored.
        }
    }

    private func finishCommunityDeepLink(
        _ result: (peerId: Int, pendingApproval: Bool)
    ) async throws {
        UserDefaults.standard.removeObject(forKey: pendingDeepLinkKey)
        if result.pendingApproval {
            notice = "Заявка на вступление отправлена."
            return
        }
        guard result.peerId > 0 else { return }
        activeTab = .messages
        await loadBootstrap(peerId: result.peerId)
    }

    private func finishForumTopicDeepLink(_ target: AloForumTopicLink) async throws {
        let detail = try await api.loadConversation(peerId: target.peerId)
        guard detail.kind == "group",
              detail.roomId == target.roomId,
              detail.forumTopics.contains(where: { $0.id == target.topicId && !$0.isHidden }) else {
            throw AloAPIError(
                status: 404,
                code: "forum_topic_not_found",
                message: "Тема недоступна.",
                payload: [:]
            )
        }

        UserDefaults.standard.removeObject(forKey: pendingDeepLinkKey)
        requestedForumTopicRoomId = target.roomId
        requestedForumTopicId = target.topicId
        activeTab = .messages
        let merged = mergePendingLocalMessages(into: detail)
        activeConversation = merged
        startConversationLive(merged)
        Task(priority: .utility) {
            try? await api.backfillConversationSearchHistory(peerId: target.peerId)
        }
    }

    func refreshForTabIfNeeded(
        _ tab: AloAppTab,
        minimumInterval: TimeInterval = 45
    ) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") { return }
        #endif
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
        cancelInitialRefresh()
        Task {
            isBusy = true
            let currentUserID = bootstrap?.me.id
            searchIndexBackfillTask?.cancel()
            searchIndexBackfillTask = nil
            await AloPushCoordinator.shared.unregister(api: api)
            _ = try? await api.logout()
            stopChatRealtime()
            calls.stop()
            api.clearCookies()
            if let currentUserID {
                AloAccountSessionStore.shared.remove(userId: currentUserID)
                refreshStoredAccounts()
            }
            clearPendingChatOutboxForLogout()
            clearBootstrapCache()
            clearBlockedUserState()
            bootstrap = nil
            activeConversation = nil
            selectedProfile = nil
            closeComments()
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

    /// Saves the current server session, clears it locally, and opens the
    /// normal login flow for another account. It intentionally does not call
    /// `/logout`: logging in to a second account must not revoke the first one.
    func addAnotherAccount() {
        guard !isBusy, let user = bootstrap?.me else { return }
        do {
            try AloAccountSessionStore.shared.save(user: user, cookies: api.sessionCookies())
            refreshStoredAccounts()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        moveToAccountLogin()
    }

    func switchToStoredAccount(_ account: AloStoredAccount) {
        guard !isBusy, bootstrap?.me.id != account.userId else { return }
        Task { await performStoredAccountSwitch(to: account) }
    }

    func signInWithPasskey() {
        guard !isBusy else { return }
        runAuthTask {
            do {
                let options = try await self.api.requestPasskeyAssertionOptions(
                    email: self.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self.email
                )
                let credential = try await AloPasskeyCoordinator.shared.assert(options: options)
                guard case let .assertion(
                    credentialID,
                    clientDataJSON,
                    authenticatorData,
                    signature,
                    userID
                ) = credential else {
                    throw AloPasskeyCoordinatorError.unexpectedCredential
                }
                try await self.api.verifyPasskeyAssertion(
                    credentialID: credentialID,
                    clientDataJSON: clientDataJSON,
                    authenticatorData: authenticatorData,
                    signature: signature,
                    userID: userID
                )
                await self.loadBootstrap(showAuthOnUnauthorized: true)
                guard self.phase == .app else {
                    self.errorMessage = "Ключ доступа не подтвердил вход."
                    return
                }
                self.notice = "Вход ключом доступа подтверждён."
            } catch let error as AloAPIError {
                self.errorMessage = self.accountSecurityMessage(for: error)
            } catch {
                self.errorMessage = error.localizedDescription.ifBlank("Не удалось войти с ключом доступа.")
            }
        }
    }

    func registerPasskey() async throws -> AloPasskeyStatus {
        let options = try await api.requestPasskeyRegistrationOptions()
        let credential = try await AloPasskeyCoordinator.shared.register(options: options)
        guard case let .registration(credentialID, clientDataJSON, attestationObject) = credential else {
            throw AloPasskeyCoordinatorError.unexpectedCredential
        }
        return try await api.verifyPasskeyRegistration(
            credentialID: credentialID,
            clientDataJSON: clientDataJSON,
            attestationObject: attestationObject
        )
    }

    func completeQRCodeLogin(requestID: String, secret: String) async -> Bool {
        guard !isCompletingQRCodeLogin, !Task.isCancelled else { return false }
        cancelInitialRefresh()
        guard !requestID.isEmpty, !secret.isEmpty else {
            errorMessage = "QR-код не содержит данных для входа."
            return false
        }
        isCompletingQRCodeLogin = true
        defer { isCompletingQRCodeLogin = false }
        do {
            try Task.checkCancellation()
            try await api.completeQRCodeLogin(requestID: requestID, secret: secret)
            try Task.checkCancellation()
            await loadBootstrap(showAuthOnUnauthorized: true)
            // The QR is single-use. Once the cookie has been issued, a temporary
            // bootstrap outage is handled by the normal connection retry, not
            // by attempting to consume the same QR again.
            if phase == .loading, connectionState == .unavailable {
                notice = "Вход подтверждён. Ожидаем соединение для загрузки аккаунта."
                return true
            }
            guard phase == .app else {
                errorMessage = "QR-вход не подтвердился на этом устройстве."
                return false
            }
            notice = "Вход по QR-коду подтверждён."
            return true
        } catch is CancellationError {
            return false
        } catch let error as AloAPIError {
            errorMessage = AloQRCodeLoginFailure.message(for: error)
            return false
        } catch {
            errorMessage = "Не удалось завершить вход по QR-коду."
            return false
        }
    }

    func deleteCurrentAccount(currentPassword: String) async -> Bool {
        guard !isBusy,
              let userID = bootstrap?.me.id,
              !currentPassword.isEmpty else {
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await api.deleteAccount(currentPassword: currentPassword, confirmation: "DELETE")
            AloAccountSessionStore.shared.remove(userId: userID)
            refreshStoredAccounts()
            clearAccountRuntimeState(discardPendingOutbox: true)
            api.clearCookies()
            clearBootstrapCache()
            bootstrap = nil
            notice = "Аккаунт удалён."
            errorMessage = ""
            authMode = .login
            phase = .auth
            return true
        } catch let error as AloAPIError {
            errorMessage = accountSecurityMessage(for: error)
            return false
        } catch {
            errorMessage = "Не удалось удалить аккаунт."
            return false
        }
    }

    private func performStoredAccountSwitch(to account: AloStoredAccount) async {
        let previousUser = bootstrap?.me
        let previousCookies = api.sessionCookies()
        isBusy = true
        errorMessage = ""
        defer { isBusy = false }

        do {
            if let previousUser {
                try AloAccountSessionStore.shared.save(user: previousUser, cookies: previousCookies)
            }
            let targetCookies = try AloAccountSessionStore.shared.cookies(for: account)
            clearAccountRuntimeState()
            clearBootstrapCache()
            api.replaceSessionCookies(targetCookies)
            bootstrap = nil
            phase = .loading
            await loadBootstrap(showAuthOnUnauthorized: true)
            guard phase == .app, bootstrap?.me.id == account.userId else {
                throw AloAccountSessionStoreError.missingSession
            }
            refreshStoredAccounts()
            notice = "Вы вошли как \(bootstrap?.me.name ?? account.name)."
        } catch {
            api.replaceSessionCookies(previousCookies)
            bootstrap = nil
            phase = .loading
            await loadBootstrap(showAuthOnUnauthorized: true)
            errorMessage = error.localizedDescription.ifBlank("Не удалось переключить аккаунт.")
        }
    }

    private func moveToAccountLogin() {
        clearAccountRuntimeState()
        clearBootstrapCache()
        api.replaceSessionCookies([])
        bootstrap = nil
        activeConversation = nil
        selectedProfile = nil
        email = ""
        password = ""
        code = ""
        notice = "Войдите в другой аккаунт. Сохранённые сеансы останутся на этом устройстве."
        errorMessage = ""
        authMode = .login
        phase = .auth
    }

    private func clearAccountRuntimeState(discardPendingOutbox: Bool = false) {
        cancelInitialRefresh()
        searchIndexBackfillTask?.cancel()
        searchIndexBackfillTask = nil
        stopChatRealtime()
        calls.stop()
        if discardPendingOutbox {
            clearPendingChatOutboxForLogout()
        } else {
            // Drafts and queued messages are already encrypted and scoped by
            // owner ID. Keep them on disk for the account they belong to, but
            // never let them bleed into the newly selected account's UI.
            pendingChatOperations.removeAll()
            pendingChatMessageIds.removeAll()
            pendingChatOperationsOwnerUserId = nil
            nextLocalMessageId = -1
        }
        clearBlockedUserState()
        activeConversation = nil
        selectedProfile = nil
        selectedChannelProfile = nil
        closeComments()
        pendingForwardDraft = nil
        pendingForwardTitle = ""
    }

    private func persistCurrentAccount(_ user: AloCurrentUser) {
        guard !api.sessionCookies().isEmpty else { return }
        do {
            try AloAccountSessionStore.shared.save(user: user, cookies: api.sessionCookies())
            refreshStoredAccounts()
        } catch {
            // The account remains usable; the UI will explain that switching is
            // unavailable until a secure session can be saved.
        }
    }

    private func refreshStoredAccounts() {
        storedAccounts = AloAccountSessionStore.shared.accounts
    }

    private func accountSecurityMessage(for error: AloAPIError) -> String {
        if error.status == 404 || error.status == 501 {
            return "Эта функция станет доступна после обновления сервера."
        }
        return error.message
    }

    func createPost(localAttachments: [AloLocalAttachment] = [], captchaToken: String? = nil) {
        let body = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!body.isEmpty || !localAttachments.isEmpty), !isCreatingPost else { return }
        errorMessage = ""
        postPublishingError = ""
        lastPublishedPostId = 0
        isBusy = true
        isCreatingPost = true
        Task {
            defer {
                isBusy = false
                isCreatingPost = false
            }
            do {
                var media = [AloMessageAttachment]()
                for attachment in localAttachments {
                    media.append(try await api.uploadAttachment(attachment, purpose: "post"))
                }
                let post = try await api.createPost(body: body, media: media, captchaToken: captchaToken)
                lastPublishedPostId = post.id
                composeText = ""
                if let data = bootstrap {
                    bootstrap = AloBootstrapDataPatch.prepend(post, to: data)
                }
            } catch let error as AloAPIError {
                if handleChallenge(error, retry: { token in self.createPost(localAttachments: localAttachments, captchaToken: token) }) { return }
                errorMessage = error.message
                postPublishingError = error.message
            } catch {
                errorMessage = "Не удалось опубликовать пост."
                postPublishingError = "Не удалось опубликовать пост. Черновик сохранён — повторите попытку."
            }
        }
    }

    func refreshStories(silently: Bool = false) async {
        guard !isStoriesLoading else { return }
        isStoriesLoading = true
        defer { isStoriesLoading = false }
        do {
            stories = try await api.loadStories()
        } catch let error as AloAPIError {
            if !silently { errorMessage = error.message }
        } catch {
            if !silently { errorMessage = "Не удалось обновить истории." }
        }
    }

    func createStory(
        body: String,
        localAttachments: [AloLocalAttachment] = [],
        lifetimeHours: Int = 24
    ) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !localAttachments.isEmpty), !isCreatingStory else { return }
        isCreatingStory = true
        errorMessage = ""
        storyPublishingError = ""
        Task {
            defer { isCreatingStory = false }
            do {
                var media = [AloMessageAttachment]()
                for attachment in localAttachments {
                    media.append(try await api.uploadAttachment(attachment, purpose: "post"))
                }
                _ = try await api.createStory(
                    body: text,
                    media: media,
                    lifetimeHours: lifetimeHours
                )
                // Publication has already succeeded. Refreshing the tray must
                // not keep the editor's submit button spinning.
                Task { await refreshStories(silently: true) }
            } catch let error as AloAPIError {
                storyPublishingError = error.message
            } catch {
                storyPublishingError = "Не удалось опубликовать историю. Проверьте подключение и повторите попытку."
            }
        }
    }

    func markStoryViewed(_ story: AloStory) {
        guard story.id > 0, !story.viewerHasSeen else { return }
        stories = stories.map { group in
            guard group.stories.contains(where: { $0.id == story.id }) else { return group }
            let updatedStories = group.stories.map { item in
                guard item.id == story.id else { return item }
                return AloStory([
                    "id": item.id,
                    "userId": item.userId,
                    "body": item.body,
                    "media": item.media.map {
                        ["type": $0.type, "url": $0.url, "posterUrl": $0.posterUrl, "caption": $0.caption]
                    },
                    "createdAt": item.createdAt,
                    "expiresAt": item.expiresAt,
                    "viewerHasSeen": true,
                    "viewCount": item.viewCount
                ])
            }
            return AloStoryGroup([
                "user": [
                    "id": group.user.id,
                    "name": group.user.name,
                    "username": group.user.username,
                    "avatarEmoji": group.user.avatarUrl,
                    "verified": group.user.verified,
                    "isChannel": group.user.isChannel
                ],
                "stories": updatedStories.map {
                    [
                        "id": $0.id,
                        "userId": $0.userId,
                        "body": $0.body,
                        "media": $0.media.map {
                            ["type": $0.type, "url": $0.url, "posterUrl": $0.posterUrl, "caption": $0.caption]
                        },
                        "createdAt": $0.createdAt,
                        "expiresAt": $0.expiresAt,
                        "viewerHasSeen": $0.viewerHasSeen,
                        "viewCount": $0.viewCount
                    ]
                },
                "hasUnseen": false
            ])
        }
        Task { try? await api.markStoryViewed(storyId: story.id) }
    }

    func loadBusinessProfile(silently: Bool = false) async {
        guard !isBusinessProfileLoading else { return }
        isBusinessProfileLoading = true
        defer { isBusinessProfileLoading = false }
        do {
            businessProfileData = try await api.loadBusinessProfile()
        } catch let error as AloAPIError {
            if !silently { errorMessage = error.message }
        } catch {
            if !silently { errorMessage = "Не удалось загрузить бизнес-профиль." }
        }
    }

    func saveBusinessProfile(
        enabled: Bool,
        businessName: String,
        category: String,
        hours: [String: String],
        greetingMessage: String,
        autoReplyEnabled: Bool,
        autoReplyMessage: String
    ) {
        Task {
            do {
                let profile = try await api.updateBusinessProfile(
                    enabled: enabled,
                    businessName: businessName,
                    category: category,
                    hours: hours,
                    greetingMessage: greetingMessage,
                    autoReplyEnabled: autoReplyEnabled,
                    autoReplyMessage: autoReplyMessage
                )
                let current = businessProfileData
                businessProfileData = AloBusinessProfileData([
                    "profile": [
                        "userId": profile.userId,
                        "enabled": profile.enabled,
                        "businessName": profile.businessName,
                        "category": profile.category,
                        "hours": profile.hours,
                        "greetingMessage": profile.greetingMessage,
                        "autoReplyEnabled": profile.autoReplyEnabled,
                        "autoReplyMessage": profile.autoReplyMessage,
                        "updatedAt": profile.updatedAt
                    ],
                    "quickReplies": current?.quickReplies.map {
                        ["id": $0.id, "shortcut": $0.shortcut, "title": $0.title, "body": $0.body, "sortOrder": $0.sortOrder]
                    } ?? [],
                    "chatLabels": current?.chatLabels.map {
                        [
                            "id": $0.id,
                            "chatKind": $0.chatKind,
                            "peerId": $0.peerId,
                            "roomId": $0.roomId,
                            "label": $0.label,
                            "color": $0.color
                        ]
                    } ?? []
                ])
                notice = "Бизнес-профиль сохранён."
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось сохранить бизнес-профиль."
            }
        }
    }

    func addBusinessQuickReply(shortcut: String, title: String, body: String) {
        Task {
            do {
                _ = try await api.createBusinessQuickReply(shortcut: shortcut, title: title, body: body)
                await loadBusinessProfile(silently: true)
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось сохранить быстрый ответ."
            }
        }
    }

    func deleteBusinessQuickReply(_ quickReply: AloBusinessQuickReply) {
        Task {
            do {
                try await api.deleteBusinessQuickReply(id: quickReply.id)
                await loadBusinessProfile(silently: true)
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось удалить быстрый ответ."
            }
        }
    }

    func saveBusinessChatLabel(
        for conversation: AloConversationSummary,
        label: String,
        color: String
    ) {
        let normalizedKind = conversation.kind == "group" ? "group" : "direct"
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let peerId = normalizedKind == "direct" ? conversation.peerId : 0
        let roomId = normalizedKind == "group" ? conversation.roomId : 0
        guard !normalizedLabel.isEmpty,
              (normalizedKind == "direct" ? peerId > 0 : roomId > 0),
              !isBusinessProfileLoading else { return }

        isBusinessProfileLoading = true
        Task {
            defer { isBusinessProfileLoading = false }
            do {
                let saved = try await api.saveBusinessChatLabel(
                    chatKind: normalizedKind,
                    peerId: peerId,
                    roomId: roomId,
                    label: normalizedLabel,
                    color: color
                )
                if let current = businessProfileData {
                    let labels = current.chatLabels
                        .filter {
                            $0.id != saved.id && !(
                                $0.chatKind == saved.chatKind &&
                                    $0.peerId == saved.peerId &&
                                    $0.roomId == saved.roomId
                            )
                        }
                        + [saved]
                    businessProfileData = AloBusinessProfileData(
                        profile: current.profile,
                        quickReplies: current.quickReplies,
                        chatLabels: labels
                    )
                } else {
                    businessProfileData = try await api.loadBusinessProfile()
                }
                notice = "Метка чата сохранена."
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось сохранить метку чата."
            }
        }
    }

    func deleteBusinessChatLabel(_ chatLabel: AloBusinessChatLabel) {
        guard chatLabel.id > 0, !isBusinessProfileLoading else { return }
        isBusinessProfileLoading = true
        Task {
            defer { isBusinessProfileLoading = false }
            do {
                try await api.deleteBusinessChatLabel(id: chatLabel.id)
                if let current = businessProfileData {
                    businessProfileData = AloBusinessProfileData(
                        profile: current.profile,
                        quickReplies: current.quickReplies,
                        chatLabels: current.chatLabels.filter { $0.id != chatLabel.id }
                    )
                }
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось удалить метку чата."
            }
        }
    }

    func toggleLike(_ post: AloPost) {
        guard let owner = bootstrap?.me.id, !pendingLikePostIds.contains(post.id) else { return }
        let original = visiblePost(id: post.id) ?? post
        replacePost(original.withEngagement(likeCount: original.likeCount + (original.viewerLiked ? -1 : 1),
                                           viewerLiked: !original.viewerLiked))
        #if DEBUG
        if isFeedInteractionPreview { return }
        #endif
        pendingLikePostIds.insert(post.id)
        Task {
            defer { pendingLikePostIds.remove(post.id) }
            do {
                let updated = try await api.toggleLike(postId: post.id)
                guard bootstrap?.me.id == owner, let current = visiblePost(id: post.id) else { return }
                replacePost(current.withEngagement(likeCount: updated.likeCount, viewerLiked: updated.viewerLiked))
            } catch {
                guard bootstrap?.me.id == owner, let current = visiblePost(id: post.id) else { return }
                replacePost(current.withEngagement(likeCount: original.likeCount, viewerLiked: original.viewerLiked))
                errorMessage = (error as? AloAPIError)?.message ?? "Не удалось обновить лайк."
            }
        }
    }

    func isRepostPending(_ postId: Int) -> Bool {
        pendingRepostPostIds.contains(postId)
    }

    func toggleRepost(_ post: AloPost, captchaToken: String? = nil) {
        guard let owner = bootstrap?.me.id, !pendingRepostPostIds.contains(post.id) else { return }
        let original = visiblePost(id: post.id) ?? post
        replacePost(original.withEngagement(repostCount: original.repostCount + (original.viewerReposted ? -1 : 1),
                                           viewerReposted: !original.viewerReposted))
        #if DEBUG
        if isFeedInteractionPreview { return }
        #endif
        pendingRepostPostIds.insert(post.id)
        errorMessage = ""

        Task {
            defer { pendingRepostPostIds.remove(post.id) }
            do {
                let updated = try await api.toggleRepost(postId: post.id, captchaToken: captchaToken)
                guard bootstrap?.me.id == owner, let current = visiblePost(id: post.id) else { return }
                replacePost(current.withEngagement(repostCount: updated.repostCount, viewerReposted: updated.viewerReposted))
            } catch let error as AloAPIError {
                guard bootstrap?.me.id == owner, let current = visiblePost(id: post.id) else { return }
                replacePost(current.withEngagement(repostCount: original.repostCount, viewerReposted: original.viewerReposted))
                // The retry is invoked synchronously from the human-challenge sheet.
                // Release this post before presenting it; otherwise the retry is
                // rejected by the pending-operation guard above.
                if error.code == "CHALLENGE_REQUIRED" {
                    pendingRepostPostIds.remove(post.id)
                }
                if handleChallenge(error, retry: { token in
                    guard self.bootstrap?.me.id == owner else { return }
                    self.toggleRepost(original, captchaToken: token)
                }) {
                    return
                }
                errorMessage = error.message
            } catch {
                guard bootstrap?.me.id == owner, let current = visiblePost(id: post.id) else { return }
                replacePost(current.withEngagement(repostCount: original.repostCount, viewerReposted: original.viewerReposted))
                errorMessage = "Не удалось обновить репост."
            }
        }
    }

    private func visiblePost(id: Int) -> AloPost? {
        if let post = commentsPost, post.id == id { return post }
        return bootstrap?.feedPopular.first { $0.id == id }
            ?? bootstrap?.feedSubscriptions.first { $0.id == id }
            ?? bootstrap?.profilePosts.first { $0.id == id }
            ?? selectedProfile?.posts.first { $0.id == id }
            ?? selectedChannelProfile?.posts.first { $0.id == id }
    }

    #if DEBUG
    private var isFeedInteractionPreview: Bool {
        UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") && bootstrap?.me.id == 990001
    }

    func installFeedStoryPreview(_ groups: [AloStoryGroup]) {
        guard isFeedInteractionPreview else { return }
        stories = groups
    }
    #endif

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

    // MARK: Pinned and archived chats (on this device)

    let chatPrefs = AloChatListPrefs()
    @Published private(set) var chatPrefsRevision = 0

    func isChatPinned(_ conversation: AloConversationSummary) -> Bool {
        guard let owner = bootstrap?.me.id else { return false }
        return chatPrefs.isPinned(owner: owner, key: AloChatListPrefs.key(for: conversation))
    }

    func isChatArchived(_ conversation: AloConversationSummary) -> Bool {
        guard let owner = bootstrap?.me.id else { return false }
        return chatPrefs.isArchived(owner: owner, key: AloChatListPrefs.key(for: conversation))
    }

    /// Pinned chats first (in pin order), then the rest in server order. Archived chats are separate.
    func arrangedConversations(archived: Bool) -> [AloConversationSummary] {
        _ = chatPrefsRevision
        let all = bootstrap?.conversations ?? []
        guard let owner = bootstrap?.me.id else { return archived ? [] : all }
        let state = chatPrefs.state(owner: owner)
        if archived { return all.filter { state.archived.contains(AloChatListPrefs.key(for: $0)) } }
        let visible = all.filter { !state.archived.contains(AloChatListPrefs.key(for: $0)) }
        let pinned = state.pinned.compactMap { key in visible.first { AloChatListPrefs.key(for: $0) == key } }
        let pinnedKeys = Set(pinned.map(AloChatListPrefs.key(for:)))
        return pinned + visible.filter { !pinnedKeys.contains(AloChatListPrefs.key(for: $0)) }
    }

    func setChatsPinned(_ conversations: [AloConversationSummary], pinned: Bool) {
        guard let owner = bootstrap?.me.id else { return }
        let ok = chatPrefs.setPinned(owner: owner, keys: conversations.map(AloChatListPrefs.key(for:)), pinned: pinned)
        if !ok { notice = "Можно закрепить не больше \(AloChatListPrefs.maximumPinned) чатов." }
        chatPrefsRevision += 1
        AloHaptics.impact(.light)
    }

    func setChatsArchived(_ conversations: [AloConversationSummary], archived: Bool) {
        guard let owner = bootstrap?.me.id else { return }
        chatPrefs.setArchived(owner: owner, keys: conversations.map(AloChatListPrefs.key(for:)), archived: archived)
        chatPrefsRevision += 1
        notice = archived ? "Чат перенесён в архив." : "Чат возвращён из архива."
        AloHaptics.impact(.light)
    }

    func markChatsRead(_ conversations: [AloConversationSummary]) {
        guard let owner = bootstrap?.me.id else { return }
        for conversation in conversations { unreadTracker.markRead(owner: owner, conversation) }
        unreadRevision += 1
    }

    /// Flips the server-side mute for a chat, from the list (no need to open the preview first).
    func toggleChatMuted(_ conversation: AloConversationSummary) {
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") { notice = "Уведомления чата выключены."; return }
#endif
        Task {
            do {
                let detail = try await api.loadConversation(peerId: conversation.peerId)
                let muted = try await api.chatMuteState(conversation: detail)
                let now = try await api.setChatMuted(!muted, conversation: detail)
                notice = now ? "Уведомления чата выключены." : "Уведомления чата включены."
            } catch let error as AloAPIError {
                notice = error.message
            } catch {
                notice = "Не удалось изменить уведомления чата."
            }
        }
    }

    // MARK: Unread dots

    /// Bumped whenever the unread picture changes, so chat rows re-render.
    @Published private(set) var unreadRevision = 0
    let unreadTracker = AloUnreadTracker()

    func isConversationUnread(_ summary: AloConversationSummary) -> Bool {
        unreadCount(for: summary) > 0 || (!summary.hasServerUnreadCount && localUnread(summary))
    }

    private func localUnread(_ summary: AloConversationSummary) -> Bool {
        guard let owner = bootstrap?.me.id else { return false }
        return unreadTracker.isUnread(owner: owner, summary)
    }

    /// The server's count, hidden once the chat was opened on this device and nothing new arrived.
    func unreadCount(for summary: AloConversationSummary) -> Int {
        guard summary.hasServerUnreadCount, summary.unreadCount > 0, let owner = bootstrap?.me.id else { return 0 }
        return unreadTracker.hasSeen(owner: owner, summary) ? 0 : summary.unreadCount
    }

    // MARK: Deleting chats

    /// One-to-one chats are deleted for this account; groups and channels are left.
    func deleteChats(_ summaries: [AloConversationSummary]) {
        guard let data = bootstrap else { return }
        let targets = summaries.filter { $0.peerId != data.me.id }
        guard !targets.isEmpty else { return }
        let removed = Set(targets.map(AloChatListPrefs.key(for:)))
        bootstrap = replacingConversations(in: data, with: data.conversations.filter { !removed.contains(AloChatListPrefs.key(for: $0)) })
        chatPrefs.setPinned(owner: data.me.id, keys: Array(removed), pinned: false)
        chatPrefs.setArchived(owner: data.me.id, keys: Array(removed), archived: false)
        chatPrefsRevision += 1
        notice = targets.count == 1 ? "Чат удалён." : "Чаты удалены."
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") { return }
#endif
        Task {
            var failed = false
            for target in targets {
                do {
                    if target.kind == "group", target.roomId > 0 {
                        try await api.leaveGroupChat(roomId: target.roomId)
                    } else {
                        try await api.deleteDirectChatForMe(peerId: target.peerId)
                    }
                } catch { failed = true }
            }
            if failed {
                notice = "Не все чаты удалось удалить. Проверьте соединение."
                await loadBootstrap()
            }
        }
    }

    // MARK: Calls list

    func callBack(_ item: AloCallHistoryItem, video: Bool) {
        Task {
            do {
                let detail = try await api.loadConversation(peerId: item.peer.id)
                await calls.startCall(conversation: detail, video: video)
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                notice = "Не удалось начать звонок. Проверьте соединение."
            }
        }
    }

    func establishUnreadBaseline() {
        guard let data = bootstrap else { return }
        if unreadTracker.establishBaseline(owner: data.me.id, conversations: data.conversations) { unreadRevision += 1 }
    }

    private func markConversationRead(_ summary: AloConversationSummary) {
        guard let owner = bootstrap?.me.id else { return }
        // Use the newest summary: messages may have arrived while the chat was open.
        let latest = bootstrap?.conversations.first { $0.kind == summary.kind && $0.peerId == summary.peerId } ?? summary
        unreadTracker.markRead(owner: owner, latest)
        unreadRevision += 1
    }

    func openConversation(_ summary: AloConversationSummary) {
        AloChatMediaSession.reset()
        markConversationRead(summary)
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") {
            activeConversation = AloConversationDetail(summary: summary, items: bootstrap?.activeMessages ?? [])
            return
        }
#endif
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
                guard activeConversation?.peerId == summary.peerId,
                      activeConversation?.kind == summary.kind,
                      activeConversation?.roomId == summary.roomId else { return }
                let mergedDetail = mergePendingLocalMessages(into: detail)
                activeConversation = mergedDetail
                startConversationLive(mergedDetail)
                Task(priority: .utility) {
                    try? await api.backfillConversationSearchHistory(peerId: summary.peerId)
                }
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
        AloChatMediaSession.reset()
        if let open = activeConversation,
           let summary = bootstrap?.conversations.first(where: { $0.kind == open.kind && $0.peerId == open.peerId }) {
            markConversationRead(summary)
        }
        stopConversationLive()
        activeConversation = nil
    }

    func toggleMessageReaction(_ message: AloChatMessage, emoji: String) {
        guard let conversation = activeConversation else { return }
        guard !isDirectPeerBlocked(conversation) else { return }
        guard !message.isCallLogMessage, message.id > 0, !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = pendingTarget(for: conversation)
        // A context menu holds a snapshot; use the live reaction state on tap.
        let currentMessage = conversation.items.first(where: { $0.id == message.id }) ?? message
        let desiredEmoji = currentMessage.reactions.contains(where: { $0.reactedByMe && $0.emoji == emoji }) ? "" : emoji
        applyOptimisticReaction(messageId: message.id, desiredEmoji: desiredEmoji)
#if DEBUG
        // Exercise the real optimistic projection in UI tests without queuing,
        // persisting or sending synthetic messages to an actual account.
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"),
           bootstrap?.me.id == 990001, conversation.peerId == 990002 {
            return
        }
#endif
        enqueuePendingChatOperation(.reaction(
            target: target,
            messageId: message.id,
            emoji: desiredEmoji,
            operationId: makeClientOperationId()
        ))
        Task {
            await processPendingChatOperations()
        }
    }

    func toggleMessagePin(_ message: AloChatMessage) {
        guard let conversation = activeConversation, message.id > 0 else { return }
        guard !isDirectPeerBlocked(conversation) else { return }
        let target = pendingTarget(for: conversation)
        let willPin = !conversation.pinnedMessageIds.contains(message.id)
        let pinnedMessageIds = willPin
            ? [message.id] + conversation.pinnedMessageIds.filter { $0 != message.id }
            : conversation.pinnedMessageIds.filter { $0 != message.id }
        activeConversation = conversation.replacingPinnedMessageIds(pinnedMessageIds)
        enqueuePendingChatOperation(.pin(
            target: target,
            messageId: message.id,
            pinned: willPin,
            operationId: makeClientOperationId()
        ))
        Task {
            await processPendingChatOperations()
        }
    }

    func editMessage(_ message: AloChatMessage, body: String, onDone: (() -> Void)? = nil) {
        guard let conversation = activeConversation else { return }
        guard !isDirectPeerBlocked(conversation) else { return }
        let nextBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextBody.isEmpty || !message.attachments.isEmpty else { return }
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"),
           bootstrap?.me.id == 990001, conversation.peerId == 990002 {
            activeConversation = conversation.replacingMessage(message.replacingBody(nextBody, editedAt: currentTimestamp()))
            onDone?()
            return
        }
#endif
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
                encryptedPayload: nil,
                operationId: makeClientOperationId()
            )
        )
        onDone?()
        Task {
            await processPendingChatOperations()
        }
    }

    func openProfile(_ user: AloEntitySummary) {
        if user.isChannel {
            openChannelProfile(channelId: user.id)
            return
        }
        openProfile(userId: user.id)
    }

    func openChannelProfile(channelId: Int) {
        guard channelId > 0 else { return }
        Task {
            isProfileLoading = true
            do {
                selectedChannelProfile = try await api.loadChannelProfile(
                    channelId: channelId
                )
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось открыть сообщество."
            }
            isProfileLoading = false
        }
    }

    func updateChannelSettings(
        commentsEnabled: Bool,
        signMessages: Bool,
        showAuthorProfiles: Bool
    ) {
        guard let channel = selectedChannelProfile else { return }
        Task {
            do {
                selectedChannelProfile = try await api.updateChannelSettings(
                    channelId: channel.id,
                    commentsEnabled: commentsEnabled,
                    signMessages: signMessages,
                    showAuthorProfiles: showAuthorProfiles
                )
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось сохранить настройки сообщества."
            }
        }
    }

    func loadChannelAdminLog(action: String? = nil) {
        guard let channelId = selectedChannelProfile?.id else { return }
        Task {
            do {
                channelAdminEvents = try await api.loadChannelAdminLog(
                    channelId: channelId,
                    action: action
                )
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось загрузить журнал действий."
            }
        }
    }

    func groupManagementRevision(for roomId: Int) -> Int {
        groupManagementRevisions[roomId, default: 0]
    }

    func groupManagementDelta(for roomId: Int) -> AloGroupManagementDelta? {
        groupManagementDeltas[roomId]
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
        selectedChannelProfile = nil
        channelAdminEvents = []
        selectedProfile = nil
    }

    func isUserBlocked(_ userId: Int) -> Bool {
        userId > 0 && blockedUserIds.contains(userId)
    }

    func isBlockActionInFlight(for userId: Int) -> Bool {
        blockingUserIds.contains(userId)
    }

    func isDirectPeerBlocked(_ conversation: AloConversationDetail) -> Bool {
        AloDirectContactPolicy.isBlockedDirectPeer(
            kind: conversation.kind,
            peerId: conversation.peerId,
            blockedUserIds: blockedUserIds
        )
    }

    func setUserBlocked(_ userId: Int, blocked: Bool) {
        guard let ownerUserId = bootstrap?.me.id,
              userId > 0,
              userId != ownerUserId,
              isUserBlocked(userId) != blocked,
              !blockingUserIds.contains(userId) else {
            return
        }

        blockedUsersStateRevision += 1
        blockingUserIds.insert(userId)
        Task { [weak self] in
            guard let self else { return }
            do {
                if blocked {
                    try await api.blockUser(userId: userId)
                } else {
                    try await api.unblockUser(userId: userId)
                }
                guard blockedUserStateOwnerUserId == ownerUserId,
                      bootstrap?.me.id == ownerUserId else {
                    return
                }
                blockingUserIds.remove(userId)
                if blocked {
                    blockedUserIds.insert(userId)
                    discardPendingChatOperations(forBlockedPeerId: userId)
                } else {
                    blockedUserIds.remove(userId)
                }
                scheduleBlockedUsersRefresh(ownerUserId: ownerUserId)
            } catch let error as AloAPIError {
                guard blockedUserStateOwnerUserId == ownerUserId,
                      bootstrap?.me.id == ownerUserId else {
                    return
                }
                blockingUserIds.remove(userId)
                errorMessage = error.message
                scheduleBlockedUsersRefresh(ownerUserId: ownerUserId)
            } catch {
                guard blockedUserStateOwnerUserId == ownerUserId,
                      bootstrap?.me.id == ownerUserId else {
                    return
                }
                blockingUserIds.remove(userId)
                errorMessage = "Не удалось обновить блокировку пользователя."
                scheduleBlockedUsersRefresh(ownerUserId: ownerUserId)
            }
        }
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
        replyToMessageId: Int = 0,
        topicId: Int = 0,
        selfDestructSeconds: Int = 0,
        silent: Bool = false,
        scheduledAt: String = "",
        sendWhenOnline: Bool = false,
        captchaToken: String? = nil,
        onSent: (() -> Void)? = nil
    ) {
        guard let conversation = activeConversation else { return }
        guard !isDirectPeerBlocked(conversation) else { return }
        let body = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !localAttachments.isEmpty || forwardFrom != nil else { return }
        if selfDestructSeconds <= 0, captchaToken == nil, (!localAttachments.isEmpty || forwardFrom != nil) {
            sendDraftMessageOptimistically(
                body: body,
                conversation: conversation,
                localAttachments: localAttachments,
                forwardFrom: forwardFrom,
                replyToMessageId: replyToMessageId,
                topicId: topicId,
                silent: silent,
                scheduledAt: scheduledAt,
                sendWhenOnline: sendWhenOnline
            )
            onSent?()
            return
        }
        if !body.isEmpty && localAttachments.isEmpty && forwardFrom == nil && captchaToken == nil {
            sendTextMessageOptimistically(
                body: body,
                conversation: conversation,
                replyToMessageId: replyToMessageId,
                topicId: topicId,
                silent: silent,
                scheduledAt: scheduledAt,
                sendWhenOnline: sendWhenOnline
            )
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
                    replyToMessageId: replyToMessageId,
                    topicId: topicId,
                    selfDestructSeconds: selfDestructSeconds,
                    silent: silent,
                    scheduledAt: scheduledAt,
                    sendWhenOnline: sendWhenOnline,
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
                        replyToMessageId: replyToMessageId,
                        topicId: topicId,
                        selfDestructSeconds: selfDestructSeconds,
                        silent: silent,
                        scheduledAt: scheduledAt,
                        sendWhenOnline: sendWhenOnline,
                        captchaToken: token,
                        onSent: onSent
                    )
                }) { return }
                if shouldQueueForConnectivity(error), !body.isEmpty, localAttachments.isEmpty, forwardFrom == nil {
                    sendTextMessageOptimistically(
                        body: body,
                        conversation: conversation,
                        replyToMessageId: replyToMessageId,
                        topicId: topicId,
                        silent: silent,
                        scheduledAt: scheduledAt,
                        sendWhenOnline: sendWhenOnline
                    )
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

    func sendChatSystemEvent(
        _ body: String,
        topicId: Int = 0,
        pollDefinition: AloPollDefinition? = nil
    ) {
        guard let conversation = activeConversation else { return }
        guard !isDirectPeerBlocked(conversation) else { return }
        guard AloPollCodec.decode(body) != nil || AloChatSystemEventCodec.decode(body) != nil else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"),
           bootstrap?.me.id == 990001, conversation.peerId == 990002 {
            let event = AloChatMessage([
                "id": (conversation.items.map(\.id).max() ?? 990200) + 1,
                "senderId": 990001, "recipientId": 990002, "topicId": topicId,
                "body": body, "createdAt": ISO8601DateFormatter().string(from: Date())
            ])
            activeConversation = conversation.replacingItems(conversation.items + [event])
            return
        }
        #endif
        sendTextMessageOptimistically(
            body: body,
            conversation: conversation,
            replyToMessageId: 0,
            topicId: topicId,
            preserveComposer: true,
            pollDefinition: pollDefinition
        )
    }

    /// Contact fields remain inside the E2EE payload. Unlike a media upload,
    /// this attachment has no server-visible URL and can be queued offline.
    func shareContact(_ contact: AloEntitySummary, topicId: Int = 0) {
        guard let conversation = activeConversation,
              !contact.isChannel,
              !isDirectPeerBlocked(conversation) else { return }
        sendUploadedAttachmentsOptimistically(
            body: messageText.trimmingCharacters(in: .whitespacesAndNewlines),
            conversation: conversation,
            uploadedAttachments: [.contact(contact)],
            replyToMessageId: 0,
            topicId: topicId
        )
    }

    /// Coordinates are E2EE attachment metadata, never an outer upload field.
    func shareStaticLocation(latitude: Double, longitude: Double, topicId: Int = 0) {
        guard let conversation = activeConversation,
              latitude.isFinite,
              longitude.isFinite,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude),
              !isDirectPeerBlocked(conversation) else { return }
        sendUploadedAttachmentsOptimistically(
            body: messageText.trimmingCharacters(in: .whitespacesAndNewlines),
            conversation: conversation,
            uploadedAttachments: [.location(latitude: latitude, longitude: longitude)],
            replyToMessageId: 0,
            topicId: topicId
        )
    }

    /// Catalog media is already hosted by an authenticated Alo catalog route,
    /// so it is sent as an encrypted attachment reference instead of being
    /// downloaded and re-uploaded. Keeping the current draft intact matches
    /// the expected quick-send behaviour for stickers and GIFs.
    func sendCatalogAttachment(
        _ attachment: AloMessageAttachment,
        topicId: Int = 0,
        replyToMessageId: Int = 0
    ) {
        guard let conversation = activeConversation,
              !attachment.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isDirectPeerBlocked(conversation) else { return }
        sendUploadedAttachmentsOptimistically(
            body: "",
            conversation: conversation,
            uploadedAttachments: [attachment],
            replyToMessageId: max(0, replyToMessageId),
            topicId: topicId,
            preserveComposer: true
        )
    }

    /// A real live-location session must be persisted and updated by the
    /// server. We deliberately do not fall back to a static pin, which would
    /// mislead the sender and recipient about whether tracking is active.
    func shareLiveLocation(
        latitude: Double,
        longitude: Double,
        expiresAt: Date,
        topicId: Int = 0
    ) {
        guard let conversation = activeConversation,
              latitude.isFinite,
              longitude.isFinite,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude),
              expiresAt > Date(),
              !isDirectPeerBlocked(conversation) else { return }
        let expiresAtValue = ISO8601DateFormatter().string(from: expiresAt)
        Task {
            do {
                let initialAttachment = AloMessageAttachment.liveLocation(
                    latitude: latitude,
                    longitude: longitude,
                    expiresAt: expiresAtValue
                )
                let encryptedPayload = try await api.prepareEncryptedMessagePayload(
                    peerId: conversation.peerId,
                    roomId: conversation.roomId,
                    kind: conversation.kind,
                    body: messageText.trimmingCharacters(in: .whitespacesAndNewlines),
                    attachments: [initialAttachment],
                    forwardFrom: nil
                )
                _ = try await api.startLiveLocation(
                    peerId: conversation.peerId,
                    roomId: conversation.roomId,
                    kind: conversation.kind,
                    topicId: topicId,
                    encryptedPayload: encryptedPayload,
                    expiresAt: expiresAtValue
                )
                messageText = ""
                notice = "Живая геопозиция включена до \(AloFormatters.messageTime(expiresAtValue))."
                await refreshActiveConversation(
                    peerId: conversation.peerId,
                    roomId: conversation.roomId,
                    kind: conversation.kind
                )
            } catch let error as AloAPIError where error.status == 404 || error.status == 501 {
                errorMessage = "Живая геопозиция станет доступна после обновления сервера Alo."
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось включить живую геопозицию."
            }
        }
    }

    func createRecurringMessageSchedule(
        rule: AloRecurringScheduleRule,
        startsAt: Date,
        occurrences: Int,
        silent: Bool,
        topicId: Int = 0
    ) {
        guard let conversation = activeConversation,
              !isDirectPeerBlocked(conversation) else { return }
        let body = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            errorMessage = "Для повторной отправки нужен текст сообщения."
            return
        }
        let scheduledAt = ISO8601DateFormatter().string(from: max(startsAt, Date().addingTimeInterval(60)))
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let encryptedPayload = try await api.prepareEncryptedMessagePayload(
                    peerId: conversation.peerId,
                    roomId: conversation.roomId,
                    kind: conversation.kind,
                    body: body,
                    attachments: [],
                    forwardFrom: nil
                )
                _ = try await api.createRecurringMessageSchedule(
                    peerId: conversation.peerId,
                    roomId: conversation.roomId,
                    kind: conversation.kind,
                    encryptedPayload: encryptedPayload,
                    topicId: topicId,
                    startsAt: scheduledAt,
                    rule: rule,
                    occurrences: occurrences,
                    silent: silent
                )
                messageText = ""
                notice = "Повторная отправка запланирована."
            } catch let error as AloAPIError where error.status == 404 || error.status == 501 {
                errorMessage = "Повторная отправка станет доступна после обновления сервера Alo."
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось запланировать повторную отправку."
            }
        }
    }

    func translateMessage(
        _ message: AloChatMessage,
        targetLanguage: String
    ) async throws -> AloMessageTranslation {
        let text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.id > 0, !text.isEmpty else {
            throw AloAPIError(
                status: 0,
                code: "INVALID_MESSAGE",
                message: "Нельзя перевести это сообщение.",
                payload: [:]
            )
        }
        return try await api.translateMessage(
            messageId: message.id,
            text: text,
            targetLanguage: targetLanguage
        )
    }

    func transcribeVoiceMessage(
        _ message: AloChatMessage,
        language: String
    ) async throws -> AloVoiceTranscription {
        let allAttachments = message.attachments.isEmpty
            ? [
                AloMessageAttachment([
                    "type": message.attachmentType,
                    "url": message.attachmentUrl,
                    "name": message.attachmentName
                ])
            ]
            : message.attachments
        guard message.id > 0,
              let attachment = allAttachments.first(where: { attachment in
                  let type = attachment.type.lowercased()
                  let name = attachment.name.lowercased()
                  let url = attachment.url.lowercased()
                  return type == "audio" || type == "voice" || name.hasPrefix("voice-") ||
                      url.hasSuffix(".m4a") || url.hasSuffix(".aac") || url.hasSuffix(".mp3") || url.hasSuffix(".wav")
              }) else {
            throw AloAPIError(
                status: 0,
                code: "VOICE_ATTACHMENT_NOT_FOUND",
                message: "В сообщении не найдено голосовое вложение.",
                payload: [:]
            )
        }
        return try await api.transcribeVoiceMessage(
            messageId: message.id,
            attachmentId: attachment.id,
            language: language
        )
    }

    func voicePlaybackTitle(for message: AloChatMessage) -> String {
        if message.senderIsAnonymous { return "Анонимный участник" }
        if let name = message.sender?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if message.senderId == bootstrap?.me.id { return bootstrap?.me.name.ifBlank("Вы") ?? "Вы" }
        if let conversation = activeConversation, conversation.kind == "direct", conversation.peerId == message.senderId {
            return conversation.title.ifBlank("Голосовое сообщение")
        }
        return bootstrap?.conversations.first(where: { $0.peer.id == message.senderId })?.peer.name
            .ifBlank("Голосовое сообщение") ?? "Голосовое сообщение"
    }

    func closePoll(_ pollId: String) {
        guard let conversation = activeConversation,
              let currentUserId = bootstrap?.me.id else { return }
        let isQuiz = conversation.items.contains {
            guard case let .create(definition)? = AloPollCodec.decode($0.body) else { return false }
            return definition.id == pollId && definition.isQuiz
        }
        let reveal = isQuiz
            ? AloSecureOutboxStore.shared.loadQuizReveal(pollId: pollId, ownerUserId: currentUserId)
            : nil
        if isQuiz && reveal == nil {
            errorMessage = "Закрыть викторину с раскрытием ответа можно только на устройстве автора."
            return
        }
        let peerId = conversation.peerId
        let roomId = conversation.roomId
        let kind = conversation.kind
        Task {
            do {
                _ = try await api.closePoll(pollId: pollId)
                if let reveal,
                   let body = AloPollCodec.encodeReveal(
                    pollId: pollId,
                    correctOptionIds: reveal.correctOptionIds,
                    salt: reveal.salt
                   ) {
                    sendTextMessageOptimistically(
                        body: body,
                        conversation: conversation,
                        replyToMessageId: 0,
                        topicId: 0,
                        preserveComposer: true
                    )
                }
                await refreshActiveConversation(peerId: peerId, roomId: roomId, kind: kind)
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось завершить опрос."
            }
        }
    }

    func sendPoll(
        _ definition: AloPollDefinition,
        topicId: Int = 0,
        scheduledAt: String = ""
    ) {
        guard let conversation = activeConversation,
              !isDirectPeerBlocked(conversation) else { return }
        var outgoingDefinition = definition
        if definition.isQuiz {
            guard let prepared = AloPollQuizCommitment.prepare(definition),
                  let ownerUserId = bootstrap?.me.id else {
                errorMessage = "Не удалось подготовить защищённую викторину."
                return
            }
            do {
                try AloSecureOutboxStore.shared.saveQuizReveal(
                    pollId: definition.id,
                    correctOptionIds: definition.correctOptionIds,
                    salt: prepared.salt,
                    ownerUserId: ownerUserId
                )
                outgoingDefinition = prepared.definition
            } catch {
                errorMessage = "Не удалось безопасно сохранить ответ викторины."
                return
            }
        }
        guard let body = AloPollCodec.encodeCreate(outgoingDefinition) else { return }
        sendTextMessageOptimistically(
            body: body,
            conversation: conversation,
            replyToMessageId: 0,
            topicId: topicId,
            preserveComposer: true,
            pollDefinition: outgoingDefinition,
            scheduledAt: scheduledAt
        )
    }

    func prepareMessageMedia(_ message: AloChatMessage) async -> AloChatMessage? {
        guard message.id > 0, message.selfDestructSeconds > 0 else { return message }
        guard let conversation = activeConversation else { return nil }
        do {
            let prepared = try await api.prepareMessageMediaOpened(
                conversation: conversation,
                message: message
            )
            if let current = activeConversation {
                activeConversation = current.replacingMessage(
                    prepared.message
                )
            }
            scheduleMessageExpiryRefresh(
                prepared.expiry,
                message: prepared.message,
                conversation: conversation
            )
            return prepared.message
        } catch let error as AloAPIError where error.status == 410 || error.code == "media_expired" {
            if let current = activeConversation {
                activeConversation = current.replacingItems(
                    current.items.filter { $0.id != message.id }
                )
            }
            return nil
        } catch {
            errorMessage = "Не удалось открыть исчезающее медиа."
            return nil
        }
    }

    func prepareMessageMediaOpen(_ message: AloChatMessage) async -> Bool {
        await prepareMessageMedia(message) != nil
    }

    private func scheduleMessageExpiryRefresh(
        _ expiry: AloMessageExpiryState,
        message: AloChatMessage,
        conversation: AloConversationDetail
    ) {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = fractionalFormatter.date(from: expiry.expiresAt)
            ?? ISO8601DateFormatter().date(from: expiry.expiresAt)
        guard let expiresAt else { return }
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            AloSecureMediaStore.shared.remove(
                urls: message.attachments.compactMap { URL(string: $0.url) }
            )
            if let current = self.activeConversation,
               current.peerId == conversation.peerId {
                self.activeConversation = current.replacingItems(
                    current.items.filter { $0.id != expiry.messageId }
                )
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let current = self.activeConversation,
                  current.peerId == conversation.peerId else { return }
            if let refreshed = try? await self.api.loadConversation(peerId: current.peerId) {
                self.activeConversation = self.mergePendingLocalMessages(into: refreshed)
            }
        }
    }

    func startConversationLive(_ conversation: AloConversationDetail) {
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") { return }
#endif
        stopConversationLive(sendPresenceLeave: false)
        conversationRefreshTask = Task { [weak self] in
            await self?.sendChatPresence(for: conversation)
        }
        if let ownerUserId = bootstrap?.me.id {
            startChatRealtime(ownerUserId: ownerUserId)
        }
    }

    /// Build the encrypted search index serially. A single task avoids opening
    /// every chat at once and is deliberately canceled on logout/cache reset.
    private func scheduleLocalSearchIndexBackfill(
        conversations: [AloConversationSummary],
        ownerUserId: Int
    ) {
        guard ownerUserId > 0,
              !conversations.isEmpty,
              searchIndexBackfillTask == nil else {
            return
        }

        searchIndexBackfillTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.searchIndexBackfillTask = nil }

            for conversation in conversations {
                guard !Task.isCancelled else { return }
                try? await self.api.backfillConversationSearchHistory(peerId: conversation.peerId)
                try? await Task.sleep(for: .milliseconds(160))
            }
        }
    }

    func stopConversationLive(sendPresenceLeave: Bool = true) {
        conversationRefreshTask?.cancel()
        conversationRefreshTask = nil
        if sendPresenceLeave {
            Task { try? await api.updateChatPresence(activePeerId: 0) }
        }
    }

    func selectForumTopic(
        conversation: AloConversationDetail,
        topicId: Int,
        replaceComposer: Bool
    ) {
        guard conversation.kind == "group", conversation.roomId > 0, topicId > 0 else { return }
        if replaceComposer,
           let state = conversation.forumTopicStates.first(where: { $0.topicId == topicId }) {
            messageText = state.draftText
        }
        let cursor = conversation.forumTopicStates
            .first(where: { $0.topicId == topicId })?
            .cursor
            ?? conversation.items
                .filter { $0.topicId == topicId }
                .map(\.id)
                .max()
            ?? 0
        Task {
            guard let state = try? await api.updateGroupTopicState(
                roomId: conversation.roomId,
                topicId: topicId,
                readThroughMessageId: cursor
            ) else { return }
            applyForumTopicState(state, roomId: conversation.roomId)
        }
    }

    func scheduleForumTopicDraftSync(
        conversation: AloConversationDetail,
        topicId: Int,
        text: String
    ) {
        guard conversation.kind == "group", conversation.roomId > 0, topicId > 0 else { return }
        let key = "\(conversation.roomId):\(topicId)"
        forumTopicDraftTasks[key]?.cancel()
        forumTopicDraftTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.persistForumTopicDraft(
                roomId: conversation.roomId,
                topicId: topicId,
                text: text
            )
            self.forumTopicDraftTasks[key] = nil
        }
    }

    func persistForumTopicDraftNow(
        conversation: AloConversationDetail,
        topicId: Int,
        text: String
    ) {
        guard conversation.kind == "group", conversation.roomId > 0, topicId > 0 else { return }
        let key = "\(conversation.roomId):\(topicId)"
        forumTopicDraftTasks[key]?.cancel()
        forumTopicDraftTasks[key] = Task { [weak self] in
            guard let self else { return }
            await self.persistForumTopicDraft(
                roomId: conversation.roomId,
                topicId: topicId,
                text: text
            )
            self.forumTopicDraftTasks[key] = nil
        }
    }

    func setForumTopicMuted(
        conversation: AloConversationDetail,
        topicId: Int,
        muted: Bool
    ) {
        guard conversation.kind == "group", conversation.roomId > 0, topicId > 0 else { return }
        Task {
            guard let state = try? await api.updateGroupTopicState(
                roomId: conversation.roomId,
                topicId: topicId,
                muted: muted
            ) else { return }
            applyForumTopicState(state, roomId: conversation.roomId)
        }
    }

    private func persistForumTopicDraft(
        roomId: Int,
        topicId: Int,
        text: String
    ) async {
        let baseRevision = activeConversation?
            .forumTopicStates
            .first(where: { $0.topicId == topicId })?
            .draftRevision ?? 0
        do {
            let state = try await api.updateGroupTopicState(
                roomId: roomId,
                topicId: topicId,
                draftText: text,
                updateDraft: true,
                baseDraftRevision: baseRevision
            )
            applyForumTopicState(state, roomId: roomId)
        } catch let error as AloAPIError where error.code == "GROUP_TOPIC_DRAFT_CONFLICT" {
            guard let states = try? await api.loadGroupTopicStates(roomId: roomId),
                  let latest = states.first(where: { $0.topicId == topicId }) else { return }
            applyForumTopicState(latest, roomId: roomId)
            guard let state = try? await api.updateGroupTopicState(
                roomId: roomId,
                topicId: topicId,
                draftText: text,
                updateDraft: true,
                baseDraftRevision: latest.draftRevision
            ) else { return }
            applyForumTopicState(state, roomId: roomId)
        } catch {
            // The local composer remains authoritative until connectivity returns.
        }
    }

    private func applyForumTopicState(_ state: AloForumTopicState, roomId: Int) {
        guard let conversation = activeConversation,
              conversation.kind == "group",
              conversation.roomId == roomId else { return }
        activeConversation = conversation.replacingForumTopicState(state)
    }

    func sendTypingIfNeeded() {
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") { return }
#endif
        guard let conversation = activeConversation else { return }
        guard !isDirectPeerBlocked(conversation) else { return }
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTypingSentAt) > 1.4 else { return }
        lastTypingSentAt = now
        Task {
            try? await api.sendTyping(conversation: conversation)
        }
    }

    /// Tells the other side that a voice or video message is being recorded.
    func sendRecordingActivity(_ action: String) {
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") { return }
#endif
        guard let conversation = activeConversation, !isDirectPeerBlocked(conversation) else { return }
        Task { try? await api.sendTyping(conversation: conversation, action: action) }
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
                var reconnectFromStoredCursor = false
                do {
                    streamEvents: for try await event in self.api.updatesEventStream(afterCursor: cursor) {
                        if Task.isCancelled { return }
                        switch self.handleChatStreamEvent(event, ownerUserId: ownerUserId) {
                        case .continueStreaming:
                            retryDelay = 500_000_000
                        case .reconnectFromStoredCursor:
                            reconnectFromStoredCursor = true
                            break streamEvents
                        }
                    }
                } catch let error as AloAPIError where error.status == 401 {
                    self.phase = .auth
                    return
                } catch {
                    // Offline cache remains readable; reconnect resumes from the last acknowledged cursor.
                }

                let delay = reconnectFromStoredCursor ? 75_000_000 : retryDelay
                try? await Task.sleep(nanoseconds: delay)
                retryDelay = reconnectFromStoredCursor
                    ? 500_000_000
                    : min(retryDelay * 2, 20_000_000_000)
            }
        }
    }

    private func stopChatRealtime() {
        chatStreamTask?.cancel()
        chatStreamTask = nil
        chatStreamRefreshTask?.cancel()
        chatStreamRefreshTask = nil
        updatesBootstrapRefreshTask?.cancel()
        updatesBootstrapRefreshTask = nil
        updatesAcknowledgementTask?.cancel()
        updatesAcknowledgementTask = nil
        pendingUpdatesAcknowledgementCursor = 0
        chatStreamOwnerUserId = 0
        chatStreamNeedsActiveRefresh = false
    }

    private func configureBlockedUserState(ownerUserId: Int) {
        guard ownerUserId > 0 else {
            clearBlockedUserState()
            return
        }
        guard blockedUserStateOwnerUserId != ownerUserId else { return }
        blockedUsersRefreshTask?.cancel()
        blockedUsersRefreshTask = nil
        blockedUsersRefreshToken += 1
        blockedUsersStateRevision = 0
        blockedUserStateOwnerUserId = ownerUserId
        blockedUserIds = []
        blockingUserIds = []
    }

    private func clearBlockedUserState() {
        blockedUsersRefreshTask?.cancel()
        blockedUsersRefreshTask = nil
        blockedUsersRefreshToken += 1
        blockedUsersStateRevision = 0
        blockedUserStateOwnerUserId = 0
        blockedUserIds = []
        blockingUserIds = []
    }

    private func scheduleBlockedUsersRefresh(
        ownerUserId: Int,
        after delay: UInt64 = 0
    ) {
        guard ownerUserId > 0,
              blockedUserStateOwnerUserId == ownerUserId else {
            return
        }
        blockedUsersRefreshTask?.cancel()
        blockedUsersRefreshToken += 1
        let refreshToken = blockedUsersRefreshToken
        let stateRevision = blockedUsersStateRevision
        blockedUsersRefreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard let self,
                  !Task.isCancelled,
                  self.blockedUserStateOwnerUserId == ownerUserId,
                  self.bootstrap?.me.id == ownerUserId,
                  self.blockedUsersRefreshToken == refreshToken else {
                return
            }
            do {
                let userIds = try await self.api.loadBlockedUserIds()
                guard !Task.isCancelled,
                      self.blockedUserStateOwnerUserId == ownerUserId,
                      self.blockedUsersRefreshToken == refreshToken,
                      self.blockedUsersStateRevision == stateRevision else {
                    return
                }
                self.blockedUserIds = userIds
                userIds.forEach { self.discardPendingChatOperations(forBlockedPeerId: $0) }
            } catch {
                // Keep the last known local state until the next refresh succeeds.
            }
            guard self.blockedUsersRefreshToken == refreshToken else { return }
            self.blockedUsersRefreshTask = nil
        }
    }

    private func handleChatStreamEvent(
        _ event: AloChatStreamEvent,
        ownerUserId: Int
    ) -> ChatStreamDisposition {
        let storedCursor = chatStreamCursor(ownerUserId: ownerUserId)
        if event.name == "updates_ready" {
            let serverCursor = event.payload.int("latestCursor")
            if serverCursor != storedCursor {
                setChatStreamCursor(serverCursor, ownerUserId: ownerUserId)
            }
            scheduleUpdatesAcknowledgement(cursor: serverCursor, ownerUserId: ownerUserId)
            return .continueStreaming
        }
        if event.name == "updates_resync" {
            setChatStreamCursor(event.payload.int("latestCursor"), ownerUserId: ownerUserId)
            scheduleUpdatesAcknowledgement(
                cursor: event.payload.int("latestCursor"),
                ownerUserId: ownerUserId
            )
            scheduleChatStreamRefresh(refreshActive: activeConversation != nil)
            scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
            return .continueStreaming
        }
        guard event.name == "update", event.id > storedCursor else {
            return .continueStreaming
        }
        if storedCursor > 0 && event.id - storedCursor > 1 {
            // Do not acknowledge a missing update. A reconnect replays the
            // interval from the last durable cursor, while a refresh keeps the
            // visible state current if the server has already pruned it.
            scheduleChatStreamRefresh(refreshActive: activeConversation != nil)
            scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
            return .reconnectFromStoredCursor
        }
        setChatStreamCursor(event.id, ownerUserId: ownerUserId)
        scheduleUpdatesAcknowledgement(cursor: event.id, ownerUserId: ownerUserId)
        let domain = event.payload.string("domain")
        guard domain == "chat" else {
            if domain == "settings" {
                handleSettingsUpdate(event.payload, ownerUserId: ownerUserId)
            } else if domain == "notifications" {
                handleNotificationUpdate(event.payload, ownerUserId: ownerUserId)
            } else if ["channels", "feed", "groups", "users"].contains(domain) {
                handleResourceUpdate(
                    event.payload,
                    domain: domain,
                    ownerUserId: ownerUserId
                )
            }
            return .continueStreaming
        }
        let chatPayload = event.payload.object("data")
        scheduleChatStreamRefresh(refreshActive: chatEventTouchesActiveConversation(chatPayload))
        return .continueStreaming
    }

    private func handleSettingsUpdate(_ payload: [String: Any], ownerUserId: Int) {
        let type = payload.string("type")
        if type == "chat_mute_changed" {
            return
        }
        guard type == "notification_settings_changed" else {
            scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
            return
        }

        let data = payload.object("data")
        let requiredKeys = [
            "likesEnabled",
            "commentsEnabled",
            "repostsEnabled",
            "followsEnabled",
            "messagesEnabled",
            "friendRequestsEnabled",
            "friendAcceptsEnabled",
            "channelSubscriptionsEnabled",
            "commentLikesEnabled"
        ]
        guard requiredKeys.allSatisfy({ data[$0] is Bool }),
              let current = bootstrap else {
            scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
            return
        }
        bootstrap = replacingNotificationSettings(
            in: current,
            with: AloNotificationSettings(data)
        )
    }

    private func handleNotificationUpdate(_ payload: [String: Any], ownerUserId: Int) {
        guard let current = bootstrap else {
            scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
            return
        }
        let data = payload.object("data")
        switch payload.string("type") {
        case "notification_created":
            guard let notificationData = data.optionalObject("notification"),
                  notificationData.int("id") > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            let notification = AloNotificationItem(notificationData)
            let notifications = [notification] +
                current.notifications.filter { $0.id != notification.id }
            bootstrap = replacingNotifications(
                in: current,
                with: Array(notifications.prefix(50))
            )
        case "notifications_read":
            let throughNotificationId = data.int("throughNotificationId")
            let ids = Set(
                (data["notificationIds"] as? [Any] ?? [])
                    .compactMap { value -> Int? in
                        if let number = value as? NSNumber { return number.intValue }
                        return Int(String(describing: value))
                    }
                    .filter { $0 > 0 }
            )
            guard throughNotificationId > 0 || !ids.isEmpty else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            bootstrap = replacingNotifications(
                in: current,
                with: current.notifications.map { item in
                    item.id <= throughNotificationId || ids.contains(item.id)
                        ? item.withRead(true)
                        : item
                }
            )
        case "notification_deleted":
            let notificationId = data.int("notificationId")
            guard notificationId > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            bootstrap = replacingNotifications(
                in: current,
                with: current.notifications.filter { $0.id != notificationId }
            )
        default:
            scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
        }
    }

    private func handleResourceUpdate(
        _ payload: [String: Any],
        domain: String,
        ownerUserId: Int
    ) {
        if domain == "users" {
            scheduleBlockedUsersRefresh(ownerUserId: ownerUserId, after: 250_000_000)
        }
        guard let current = bootstrap else {
            scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
            return
        }
        let type = payload.string("type")
        let data = payload.object("data")

        switch (domain, type) {
        case ("feed", "post_upsert"):
            let postData = data.object("post")
            guard postData.int("id") > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            let post = AloPost(postData)
            bootstrap = data.bool("isNew")
                ? AloBootstrapDataPatch.prepend(post, to: current)
                : AloBootstrapDataPatch.replace(post, in: current)
            patchVisiblePost(post, prepend: data.bool("isNew"))

        case ("feed", "post_deleted"):
            let postId = data.int("postId")
            guard postId > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            removePost(id: postId)

        case ("feed", "comment_upsert"):
            let postId = data.int("postId")
            let commentData = data.object("comment")
            guard postId > 0, commentData.int("id") > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            let comment = AloPostComment(commentData)
            if commentsPost?.id == postId {
                if data.bool("isNew") && !comments.contains(where: { $0.id == comment.id }) {
                    comments.append(comment)
                } else {
                    comments = comments.map { $0.id == comment.id ? comment : $0 }
                }
            }
            let postData = data.object("post")
            if postData.int("id") == postId {
                let post = AloPost(postData)
                bootstrap = AloBootstrapDataPatch.replace(post, in: current)
                patchVisiblePost(post, prepend: false)
            }

        case ("feed", "comment_deleted"):
            let postId = data.int("postId")
            let commentId = data.int("commentId")
            guard postId > 0, commentId > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            if commentsPost?.id == postId {
                comments.removeAll { $0.id == commentId }
            }
            let postData = data.object("post")
            if postData.int("id") == postId {
                let post = AloPost(postData)
                bootstrap = AloBootstrapDataPatch.replace(post, in: current)
                patchVisiblePost(post, prepend: false)
            }

        case ("users", "user_upsert"):
            var userData = data.object("user")
            guard userData.int("id") == current.me.id else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            if userData.string("email").isEmpty {
                userData["email"] = current.me.email
            }
            let user = AloCurrentUser(userData)
            bootstrap = AloBootstrapDataPatch.replaceMe(user, in: current)
            if let profile = selectedProfile, profile.id == user.id {
                selectedProfile = AloUserProfile(
                    id: profile.id,
                    user: user,
                    stats: profile.stats,
                    posts: profile.posts,
                    likes: profile.likes,
                    relation: profile.relation,
                    permissions: profile.permissions
                )
            }

        case ("users", "user_relation_changed"):
            let userId = data.int("userId")
            let relationData = data.object("relation")
            let statsData = data.object("stats")
            guard userId > 0, !relationData.isEmpty, !statsData.isEmpty else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            let relation = AloProfileRelation(relationData)
            let stats = AloProfileStats(statsData)
            bootstrap = AloBootstrapDataPatch.updateRelation(
                userId: userId,
                relation: relation,
                stats: stats,
                in: current
            )
            if let profile = selectedProfile, profile.id == userId {
                selectedProfile = AloUserProfilePatch.relation(
                    relation,
                    canSendFriendRequest: data.bool("canSendFriendRequest"),
                    in: profile
                )
            }

        case ("channels", "channel_upsert"):
            let profileData = data.object("profile")
            let channelData = profileData.object("channel")
            guard channelData.int("id") > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            let profile = AloChannelProfile(["profile": profileData])
            bootstrap = AloBootstrapDataPatch.upsertChannel(
                profile,
                isNew: data.bool("isNew"),
                in: current
            )
            if selectedChannelProfile?.id == profile.id {
                selectedChannelProfile = profile
            }

        case ("channels", "channel_deleted"):
            let channelId = data.int("channelId")
            guard channelId > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            bootstrap = AloBootstrapDataPatch.removeChannel(channelId, from: current)
            if selectedChannelProfile?.id == channelId {
                selectedChannelProfile = nil
            }

        case ("channels", "channel_subscription_changed"):
            let channelId = data.int("channelId")
            guard channelId > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            if let profile = selectedChannelProfile, profile.id == channelId {
                selectedChannelProfile = AloChannelProfilePatch.subscribers(
                    data.int("subscribersCount"),
                    in: profile
                )
            }

        case ("channels", "channel_subscribers_changed"):
            let channelId = data.int("channelId")
            guard channelId > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            if let profile = selectedChannelProfile, profile.id == channelId {
                selectedChannelProfile = AloChannelProfilePatch.subscribers(
                    data.int("subscribersCount"),
                    in: profile
                )
            }

        case ("channels", "channel_management_changed"):
            let channelId = data.int("channelId")
            guard channelId > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            if let delta = AloChannelManagementDelta(data.object("delta")) {
                if let profile = selectedChannelProfile, profile.id == channelId {
                    if let event = delta.adminEvent {
                        channelAdminEvents.removeAll { $0.id == event.id }
                        channelAdminEvents.insert(event, at: 0)
                        if channelAdminEvents.count > 200 {
                            channelAdminEvents.removeLast(channelAdminEvents.count - 200)
                        }
                    }
                    let kind = data.string("kind")
                    let targetUserId = data.int("targetUserId")
                    var canManage = profile.canManage
                    if targetUserId == current.me.id && !profile.isOwner {
                        if kind == "moderator_added" { canManage = true }
                        if kind == "moderator_removed" { canManage = false }
                    }
                    selectedChannelProfile = AloChannelProfilePatch.management(
                        delta,
                        canManage: canManage,
                        in: profile
                    )
                }
            } else if selectedChannelProfile?.id == channelId {
                Task { [weak self] in
                    guard let self else { return }
                    async let profile = try? self.api.loadChannelProfile(channelId: channelId)
                    async let events = try? self.api.loadChannelAdminLog(channelId: channelId)
                    let (updatedProfile, updatedEvents) = await (profile, events)
                    guard self.selectedChannelProfile?.id == channelId else { return }
                    if let updatedProfile {
                        self.selectedChannelProfile = updatedProfile
                    }
                    if let updatedEvents {
                        self.channelAdminEvents = updatedEvents
                    }
                }
            }

        case ("groups", "group_upsert"):
            let room = data.object("room")
            guard room.int("id") > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            bootstrap = AloBootstrapDataPatch.upsertGroup(
                room,
                isNew: data.bool("isNew"),
                in: current
            )

        case ("groups", "group_deleted"):
            let roomId = data.int("roomId")
            guard roomId > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            bootstrap = AloBootstrapDataPatch.removeGroup(roomId, from: current)
            if activeConversation?.kind == "group" && activeConversation?.roomId == roomId {
                stopConversationLive()
                activeConversation = nil
            }

        case ("groups", "group_policy_updated"):
            let roomId = data.int("roomId")
            let policyData = data.object("policy")
            guard roomId > 0, !policyData.isEmpty else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            let policy = AloGroupPolicy(policyData)
            if let conversation = activeConversation,
               conversation.kind == "group",
               conversation.roomId == roomId {
                activeConversation = conversation.replacingGroupState(policy: policy)
            }

        case ("groups", "group_members_updated"):
            let roomId = data.int("roomId")
            let members = data.array("members").map(AloGroupMember.init)
            guard roomId > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            bootstrap = AloBootstrapDataPatch.updateGroupMemberCount(
                roomId,
                memberCount: members.count,
                in: current
            )
            if let conversation = activeConversation,
               conversation.kind == "group",
               conversation.roomId == roomId {
                activeConversation = conversation.replacingGroupState(members: members)
            }

        case ("groups", "group_member_count_changed"):
            let roomId = data.int("roomId")
            let memberCount = max(0, data.int("memberCount"))
            guard roomId > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            bootstrap = AloBootstrapDataPatch.updateGroupMemberCount(
                roomId,
                memberCount: memberCount,
                in: current
            )
            if let conversation = activeConversation,
               conversation.kind == "group",
               conversation.roomId == roomId {
                activeConversation = conversation.replacingGroupMemberCount(memberCount)
            }

        case ("groups", "group_membership_changed"):
            let roomId = data.int("roomId")
            let status = data.string("status")
            guard roomId > 0, !status.isEmpty else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            if ["removed", "banned", "left"].contains(status) {
                bootstrap = AloBootstrapDataPatch.removeGroup(roomId, from: current)
                if activeConversation?.kind == "group" && activeConversation?.roomId == roomId {
                    stopConversationLive()
                    activeConversation = nil
                }
            } else if status == "joined" {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
            } else if status == "membership_updated" {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                if activeConversation?.kind == "group" && activeConversation?.roomId == roomId {
                    scheduleChatStreamRefresh(refreshActive: true)
                }
            }

        case ("groups", "group_management_changed"):
            let roomId = data.int("roomId")
            guard roomId > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            let revision = max(1, payload.int("sequence"))
            if let delta = AloGroupManagementDelta(
                data.object("delta"),
                revision: revision
            ) {
                groupManagementDeltas[roomId] = delta
            } else {
                groupManagementRevisions[roomId, default: 0] += 1
            }

        case ("groups", "group_topic_state_changed"):
            let roomId = data.int("roomId")
            guard roomId > 0,
                  let rawState = data.optionalObject("state"),
                  rawState.int("topicId") > 0 else {
                scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
                return
            }
            Task { [weak self] in
                guard let self else { return }
                let state = await self.api.decodeForumTopicState(rawState)
                self.applyForumTopicState(state, roomId: roomId)
            }

        default:
            scheduleBootstrapRefreshFromUpdates(ownerUserId: ownerUserId)
        }
    }

    private func patchVisiblePost(_ post: AloPost, prepend: Bool) {
        if let profile = selectedProfile {
            if prepend && profile.id == post.creatorId {
                selectedProfile = AloUserProfilePatch.prepend(post, to: profile)
            } else if profile.posts.contains(where: { $0.id == post.id }) {
                selectedProfile = AloUserProfilePatch.replace(post, in: profile)
            }
        }
        if let channel = selectedChannelProfile {
            if prepend && post.author.isChannel && post.author.id == channel.id {
                selectedChannelProfile = AloChannelProfilePatch.prepend(post, to: channel)
            } else if channel.posts.contains(where: { $0.id == post.id }) {
                selectedChannelProfile = AloChannelProfilePatch.replace(post, in: channel)
            }
        }
        if commentsPost?.id == post.id {
            commentsPost = post
        }
    }

    private func scheduleBootstrapRefreshFromUpdates(ownerUserId: Int) {
        guard ownerUserId > 0, ownerUserId == chatStreamOwnerUserId else { return }
        guard updatesBootstrapRefreshTask == nil else { return }
        updatesBootstrapRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self,
                  !Task.isCancelled,
                  ownerUserId == self.chatStreamOwnerUserId else { return }
            self.updatesBootstrapRefreshTask = nil
            do {
                let snapshot = try await self.api.loadBootstrapSnapshot()
                guard snapshot.data.me.id == ownerUserId else { return }
                self.saveBootstrapCache(snapshot.raw)
                self.bootstrap = snapshot.data
                self.configureBlockedUserState(ownerUserId: ownerUserId)
                self.scheduleBlockedUsersRefresh(ownerUserId: ownerUserId)
                self.lastBootstrapRefreshAt = Date()
                self.activatePendingChatOutbox(ownerUserId: ownerUserId)
            } catch {
                // The existing cached state stays usable until the stream reconnects.
            }
        }
    }

    private func scheduleUpdatesAcknowledgement(cursor: Int, ownerUserId: Int) {
        guard cursor > 0, ownerUserId == chatStreamOwnerUserId else { return }
        pendingUpdatesAcknowledgementCursor = max(pendingUpdatesAcknowledgementCursor, cursor)
        guard updatesAcknowledgementTask == nil else { return }
        updatesAcknowledgementTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled, ownerUserId == self.chatStreamOwnerUserId else { return }
            let cursor = self.pendingUpdatesAcknowledgementCursor
            self.pendingUpdatesAcknowledgementCursor = 0
            self.updatesAcknowledgementTask = nil
            guard cursor > 0 else { return }
            try? await self.api.acknowledgeUpdates(
                cursor: cursor,
                deviceId: AloPushCoordinator.shared.deviceId
            )
        }
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

    private func replacingNotificationSettings(
        in data: AloBootstrapData,
        with notificationSettings: AloNotificationSettings
    ) -> AloBootstrapData {
        AloBootstrapData(
            me: data.me,
            feedPopular: data.feedPopular,
            feedSubscriptions: data.feedSubscriptions,
            notifications: data.notifications,
            notificationSettings: notificationSettings,
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

    private func replacingNotifications(
        in data: AloBootstrapData,
        with notifications: [AloNotificationItem]
    ) -> AloBootstrapData {
        AloBootstrapData(
            me: data.me,
            feedPopular: data.feedPopular,
            feedSubscriptions: data.feedSubscriptions,
            notifications: notifications,
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

    private func chatStreamCursor(ownerUserId: Int) -> Int {
        UserDefaults.standard.integer(forKey: "alo.ios.updates-stream.cursor.\(ownerUserId)")
    }

    private func setChatStreamCursor(_ cursor: Int, ownerUserId: Int) {
        UserDefaults.standard.set(
            max(0, cursor),
            forKey: "alo.ios.updates-stream.cursor.\(ownerUserId)"
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
        if let ownerUserId = bootstrap?.me.id {
            AloSecureOfflineCacheStore.shared.removeSearchMessages(
                peerId: target.peerId,
                ownerUserId: ownerUserId,
                messageIds: Set(safeIds)
            )
        }
        enqueuePendingChatOperation(.delete(
            target: target,
            messageIds: safeIds,
            mode: mode,
            operationId: makeClientOperationId()
        ))
        onDone?()
        Task {
            await processPendingChatOperations()
        }
    }

    func rescheduleMessage(_ message: AloChatMessage, at date: Date, onDone: (() -> Void)? = nil) {
        guard let conversation = activeConversation,
              message.isScheduled,
              message.scheduledMessageId > 0 else { return }
        let target = pendingTarget(for: conversation)
        let scheduledAt = ISO8601DateFormatter().string(from: date)
        pendingChatMessageIds.insert(message.id)
        activeConversation = conversation.replacingMessage(
            message.replacingSchedule(scheduledAt)
        )
        enqueuePendingChatOperation(.reschedule(
            target: target,
            messageId: message.id,
            scheduledMessageId: message.scheduledMessageId,
            originalScheduledAt: message.scheduledAt,
            scheduledAt: scheduledAt,
            silent: message.silent,
            operationId: makeClientOperationId()
        ))
        onDone?()
        Task {
            await processPendingChatOperations()
        }
    }

    func cancelScheduledMessage(_ message: AloChatMessage, onDone: (() -> Void)? = nil) {
        guard let conversation = activeConversation,
              message.isScheduled,
              message.scheduledMessageId > 0 else { return }
        let target = pendingTarget(for: conversation)
        pendingChatMessageIds.insert(message.id)
        activeConversation = conversation.replacingItems(
            conversation.items.filter { $0.scheduledMessageId != message.scheduledMessageId }
        )
        enqueuePendingChatOperation(.cancelScheduled(
            target: target,
            messageId: message.id,
            scheduledMessageId: message.scheduledMessageId,
            operationId: makeClientOperationId()
        ))
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

    @Published private(set) var pendingFriendRequestIds = Set<Int>()

    func openNotification(_ item: AloNotificationItem) {
        if item.entityType == "post", item.entityId > 0 {
            if let data = bootstrap, let post = (data.feedPopular + data.feedSubscriptions + data.profilePosts)
                .first(where: { $0.id == item.entityId }) {
                openComments(for: post)
            } else {
                let owner = bootstrap?.me.id
                Task {
                    do {
                        let post = try await api.loadPost(postId: item.entityId)
                        guard bootstrap?.me.id == owner, activeTab == .alerts else { return }
                        openComments(for: post)
                    } catch {
                        guard bootstrap?.me.id == owner else { return }
                        errorMessage = "Не удалось открыть публикацию. Попробуйте ещё раз."
                    }
                }
            }
        } else if let actor = item.actor {
            if item.type == "message" {
                activeTab = .messages
                let summary = bootstrap?.conversations.first { $0.peerId == actor.id } ?? AloConversationSummary([
                    "peerId": actor.id, "kind": "direct",
                    "peer": ["id": actor.id, "name": actor.name, "username": actor.username, "avatarUrl": actor.avatarUrl]])
                openConversation(summary)
            }
            else { openProfile(actor) }
        }
    }

    func markAllNotificationsRead() {
        guard let current = bootstrap else { return }
        let unreadIds = current.notifications.filter { !$0.isRead }.map(\.id)
        guard !unreadIds.isEmpty else { return }
        bootstrap = replacingNotifications(
            in: current,
            with: current.notifications.map { $0.withRead(true) }
        )
        if isFeedInteractionPreview { return }
        Task {
            do {
                try await api.markNotificationsRead(all: true)
            } catch {
                guard let latest = bootstrap else { return }
                let unreadSet = Set(unreadIds)
                bootstrap = replacingNotifications(
                    in: latest,
                    with: latest.notifications.map { item in
                        unreadSet.contains(item.id) ? item.withRead(false) : item
                    }
                )
            }
        }
    }

    func deleteNotification(_ item: AloNotificationItem) {
        guard item.id > 0 else { return }
        Task {
            do {
                try await api.deleteNotification(id: item.id)
                guard let current = bootstrap else { return }
                bootstrap = replacingNotifications(
                    in: current,
                    with: current.notifications.filter { $0.id != item.id }
                )
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось удалить уведомление."
            }
        }
    }

    func respondFriendRequest(requestId: Int, accept: Bool) {
        guard requestId > 0, pendingFriendRequestIds.insert(requestId).inserted else { return }
        Task {
            defer { pendingFriendRequestIds.remove(requestId) }
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
        searchIndexBackfillTask?.cancel()
        searchIndexBackfillTask = nil
        clearBootstrapCache()
        AloSecureMediaStore.shared.clearCache()
        AloImageCache.removeAll()
        URLCache.shared.removeAllCachedResponses()
        notice = "Локальный кэш очищен."
    }

    func openComments(for post: AloPost) {
        if post.author.isChannel {
            Task { await openLinkedDiscussionOrLegacyComments(for: post) }
            return
        }
        openLegacyComments(for: post)
    }

    func openChannelPostDiscussion(postId: Int) {
        guard postId > 0 else { return }
        Task {
            do {
                let post = try await api.loadPost(postId: postId)
                await openLinkedDiscussionOrLegacyComments(for: post)
            } catch let error as AloAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = "Не удалось открыть обсуждение публикации."
            }
        }
    }

    private func openLegacyComments(for post: AloPost) {
        closeComments()
        commentsPost = post
        commentText = ""
        commentsLoading = true
        commentsLoadTask = Task { await loadComments(for: post.id) }
    }

    private func openLinkedDiscussionOrLegacyComments(for post: AloPost) async {
        do {
            let discussion = try await api.openPostDiscussion(postId: post.id)
            let detail = try await api.loadConversation(peerId: discussion.peerId)
            closeComments()
            requestedForumTopicRoomId = discussion.roomId
            requestedForumTopicId = discussion.topicId
            activeTab = .messages
            activeConversation = mergePendingLocalMessages(into: detail)
            if let activeConversation {
                startConversationLive(activeConversation)
            }
            Task(priority: .utility) {
                try? await api.backfillConversationSearchHistory(peerId: discussion.peerId)
            }
        } catch let error as AloAPIError {
            if error.code == "discussion_not_linked" {
                openLegacyComments(for: post)
            } else {
                errorMessage = error.message
            }
        } catch {
            errorMessage = "Не удалось открыть обсуждение публикации."
        }
    }

    func consumeRequestedForumTopic(roomId: Int) -> Int {
        guard requestedForumTopicRoomId == roomId, requestedForumTopicId > 0 else { return 0 }
        let topicId = requestedForumTopicId
        requestedForumTopicRoomId = 0
        requestedForumTopicId = 0
        return topicId
    }

    func closeComments() {
        commentsLoadTask?.cancel()
        commentsLoadTask = nil
        commentsSession = UUID()
        commentsLoadRequest = UUID()
        commentsSendRequest = UUID()
        commentsPost = nil
        comments = []
        commentText = ""
        commentsLoading = false
        commentsError = ""
        isSendingComment = false
        lastCreatedCommentId = 0
    }

    func loadComments(for postId: Int) async {
        guard commentsPost?.id == postId else { return }
        let request = UUID(), session = commentsSession, owner = bootstrap?.me.id
        let idsAtStart = Set(comments.map(\.id))
        commentsLoadRequest = request
        commentsLoading = true
        commentsError = ""
        defer {
            if commentsLoadRequest == request { commentsLoading = false }
        }
        #if DEBUG
        if isFeedInteractionPreview {
            comments = [AloPostComment(["id": 990700, "body": "Отличный кадр! Где это снято?",
                "createdAt": ISO8601DateFormatter().string(from: Date()), "likeCount": 2,
                "author": ["id": 990002, "name": "Александр", "username": "alex"]])]
            return
        }
        #endif
        do {
            let loaded = try await api.loadPostComments(postId: postId)
            guard !Task.isCancelled, commentsLoadRequest == request, commentsSession == session,
                  bootstrap?.me.id == owner, commentsPost?.id == postId else { return }
            // A send may finish while the initial page is loading. Keep it.
            let loadedIds = Set(loaded.map(\.id))
            comments = loaded + comments.filter { !loadedIds.contains($0.id) && !idsAtStart.contains($0.id) }
        } catch {
            guard !Task.isCancelled, commentsLoadRequest == request, commentsSession == session,
                  bootstrap?.me.id == owner else { return }
            commentsError = (error as? AloAPIError)?.message ?? "Не удалось загрузить комментарии."
        }
    }

    func createComment(captchaToken: String? = nil) {
        guard let post = commentsPost, !isSendingComment, let owner = bootstrap?.me.id else { return }
        let body = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let draft = commentText, session = commentsSession, request = UUID()
        commentsSendRequest = request
        isSendingComment = true
        commentsError = ""
        #if DEBUG
        if isFeedInteractionPreview {
            let me = bootstrap!.me
            comments.append(AloPostComment(["id": 990701 + comments.count, "body": body,
                "createdAt": ISO8601DateFormatter().string(from: Date()),
                "author": ["id": me.id, "name": me.name, "username": me.username]]))
            replacePost(post.withEngagement(commentCount: post.commentCount + 1))
            commentText = ""
            isSendingComment = false
            lastCreatedCommentId = comments.last?.id ?? 0
            return
        }
        #endif
        Task {
            defer { if commentsSendRequest == request { isSendingComment = false } }
            do {
                let result = try await api.createComment(postId: post.id, body: body, captchaToken: captchaToken)
                guard bootstrap?.me.id == owner else { return }
                if let current = visiblePost(id: post.id), let updated = result.post {
                    replacePost(current.withEngagement(commentCount: updated.commentCount))
                }
                if commentsSession == session, commentsPost?.id == post.id {
                    if commentText == draft { commentText = "" }
                    if !comments.contains(where: { $0.id == result.comment.id }) { comments.append(result.comment) }
                    lastCreatedCommentId = result.comment.id
                }
            } catch let error as AloAPIError {
                guard bootstrap?.me.id == owner, commentsSession == session else { return }
                isSendingComment = false
                if handleChallenge(error, retry: { token in
                    guard self.commentsSession == session, self.commentText == draft else { return }
                    self.createComment(captchaToken: token)
                }) { return }
                commentsError = error.message
            } catch {
                guard bootstrap?.me.id == owner, commentsSession == session else { return }
                commentsError = "Не удалось отправить комментарий."
            }
        }
    }

    func toggleCommentLike(_ comment: AloPostComment) {
        guard let post = commentsPost, !pendingCommentLikeIds.contains(comment.id) else { return }
        let session = commentsSession, owner = bootstrap?.me.id
        let original = comments.first { $0.id == comment.id } ?? comment
        comments = comments.map { $0.id == comment.id
            ? $0.withLike(count: original.likeCount + (original.viewerLiked ? -1 : 1), liked: !original.viewerLiked) : $0 }
        #if DEBUG
        if isFeedInteractionPreview { return }
        #endif
        pendingCommentLikeIds.insert(comment.id)
        Task {
            defer { pendingCommentLikeIds.remove(comment.id) }
            do {
                let updated = try await api.toggleCommentLike(postId: post.id, commentId: comment.id)
                guard commentsSession == session, bootstrap?.me.id == owner else { return }
                comments = comments.map { $0.id == comment.id
                    ? $0.withLike(count: updated.likeCount, liked: updated.viewerLiked) : $0 }
            } catch {
                guard commentsSession == session, bootstrap?.me.id == owner else { return }
                comments = comments.map { $0.id == comment.id
                    ? $0.withLike(count: original.likeCount, liked: original.viewerLiked) : $0 }
                commentsError = (error as? AloAPIError)?.message ?? "Не удалось обновить лайк."
            }
        }
    }

    func deleteComment(_ comment: AloPostComment) {
        guard let post = commentsPost, let owner = bootstrap?.me.id else { return }
        let session = commentsSession
        #if DEBUG
        if isFeedInteractionPreview {
            comments.removeAll { $0.id == comment.id }
            replacePost(post.withEngagement(commentCount: post.commentCount - 1))
            return
        }
        #endif
        Task {
            do {
                let updatedPost = try await api.deleteComment(postId: post.id, commentId: comment.id)
                guard bootstrap?.me.id == owner else { return }
                if commentsSession == session {
                    comments.removeAll { $0.id == comment.id }
                }
                if let updatedPost, let current = visiblePost(id: post.id) {
                    replacePost(current.withEngagement(commentCount: updatedPost.commentCount))
                }
            } catch {
                guard bootstrap?.me.id == owner, commentsSession == session else { return }
                commentsError = (error as? AloAPIError)?.message ?? "Не удалось удалить комментарий."
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
        cancelInitialRefresh()
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
        patchVisiblePost(post, prepend: false)
    }

    private func removePost(id postId: Int) {
        if let data = bootstrap {
            bootstrap = AloBootstrapDataPatch.remove(postId, from: data)
        }
        if let profile = selectedProfile {
            selectedProfile = AloUserProfilePatch.remove(postId, from: profile)
        }
        if let channel = selectedChannelProfile {
            selectedChannelProfile = AloChannelProfilePatch.remove(postId, from: channel)
        }
        if commentsPost?.id == postId {
            closeComments()
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

    private func isBlockedDirectPeer(_ target: PendingChatTarget) -> Bool {
        AloDirectContactPolicy.isBlockedDirectPeer(
            kind: target.kind,
            peerId: target.peerId,
            blockedUserIds: blockedUserIds
        )
    }

    private func discardPendingChatOperations(forBlockedPeerId userId: Int) {
        let operations = pendingChatOperations.filter {
            $0.target.kind == "direct" && $0.target.peerId == userId
        }
        guard !operations.isEmpty else { return }
        operations.forEach(clearPendingState)
        pendingChatOperations.removeAll {
            $0.target.kind == "direct" && $0.target.peerId == userId
        }
        persistPendingChatOperations()
    }

    private func currentTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func shouldQueueForConnectivity(_ error: AloAPIError) -> Bool {
        error.code == "CONNECTION_FAILED"
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
        let projectedItems = AloPendingChatProjection.applyingScheduledChanges(
            to: visibleServerItems,
            canceledScheduledMessageIds: pendingCanceledScheduledMessageIds(for: target),
            scheduledAtByMessageId: pendingScheduledTimes(for: target)
        )
        let editedItems = AloPendingChatProjection.applyingPendingEdits(
            to: projectedItems,
            bodyByMessageId: pendingEditedBodies(for: target),
            editedAt: currentTimestamp()
        )
        let reactionItems = AloPendingChatProjection.applyingDesiredReactions(
            to: editedItems,
            desiredEmojiByMessageId: pendingDesiredReactions(for: target)
        )
        let projected = refreshed.replacingItems(reactionItems)
        let pending = pendingLocalMessages(for: target)
        guard !pending.isEmpty else { return projected }
        return projected.replacingItems(
            AloPendingChatProjection.mergingPendingMessages(
                serverMessages: reactionItems,
                pendingMessages: pending
            )
        )
    }

    private func pendingLocalMessages(for target: PendingChatTarget) -> [AloChatMessage] {
        let senderId = bootstrap?.me.id ?? pendingChatOperationsOwnerUserId ?? 0
        return pendingChatOperations.compactMap { operation in
            switch operation {
            case let .sendText(
                localId,
                operationTarget,
                body,
                topicId,
                replyToMessageId,
                createdAt,
                _,
                _,
                _,
                silent,
                scheduledAt,
                sendWhenOnline
            ):
                guard operationTarget == target else { return nil }
                return AloChatMessage(
                    localId: localId,
                    senderId: senderId,
                    recipientId: target.kind == "direct" ? target.peerId : 0,
                    body: body,
                    topicId: topicId,
                    replyToMessageId: replyToMessageId,
                    createdAt: createdAt,
                    scheduledAt: scheduledAt,
                    silent: silent,
                    sendWhenOnline: sendWhenOnline
                )
            case let .sendDraft(
                localId,
                operationTarget,
                body,
                topicId,
                replyToMessageId,
                createdAt,
                attachments,
                uploadedAttachments,
                forwardFrom,
                _,
                _,
                silent,
                scheduledAt,
                sendWhenOnline
            ):
                guard operationTarget == target else { return nil }
                return AloChatMessage(
                    localId: localId,
                    senderId: senderId,
                    recipientId: target.kind == "direct" ? target.peerId : 0,
                    body: body,
                    topicId: topicId,
                    replyToMessageId: replyToMessageId,
                    createdAt: createdAt,
                    attachments: attachments.isEmpty
                        ? uploadedAttachments
                        : attachments.map { AloMessageAttachment(local: $0, includeInlineData: false) },
                    forwardFrom: forwardFrom,
                    scheduledAt: scheduledAt,
                    silent: silent,
                    sendWhenOnline: sendWhenOnline
                )
            default:
                return nil
            }
        }
    }

    private func pendingDeletedMessageIds(for target: PendingChatTarget) -> Set<Int> {
        pendingChatOperations.reduce(into: Set<Int>()) { result, operation in
            guard case let .delete(operationTarget, messageIds, _, _) = operation,
                  operationTarget == target else { return }
            result.formUnion(messageIds)
        }
    }

    private func pendingCanceledScheduledMessageIds(for target: PendingChatTarget) -> Set<Int> {
        pendingChatOperations.reduce(into: Set<Int>()) { result, operation in
            guard case let .cancelScheduled(operationTarget, _, scheduledMessageId, _) = operation,
                  operationTarget == target else { return }
            result.insert(scheduledMessageId)
        }
    }

    private func pendingScheduledTimes(for target: PendingChatTarget) -> [Int: String] {
        pendingChatOperations.reduce(into: [Int: String]()) { result, operation in
            guard case let .reschedule(operationTarget, _, scheduledMessageId, _, scheduledAt, _, _) = operation,
                  operationTarget == target else { return }
            result[scheduledMessageId] = scheduledAt
        }
    }

    private func pendingEditedBodies(for target: PendingChatTarget) -> [Int: String] {
        pendingChatOperations.reduce(into: [Int: String]()) { result, operation in
            guard case let .edit(operationTarget, messageId, _, body, _, _, _, _) = operation,
                  operationTarget == target else { return }
            result[messageId] = body
        }
    }

    private func pendingDesiredReactions(for target: PendingChatTarget) -> [Int: String] {
        pendingChatOperations.reduce(into: [Int: String]()) { result, operation in
            guard case let .reaction(operationTarget, messageId, emoji, _) = operation,
                  operationTarget == target else { return }
            result[messageId] = emoji
        }
    }

    private func hasPendingMutation(for target: PendingChatTarget, messageId: Int) -> Bool {
        pendingChatOperations.contains { operation in
            switch operation {
            case let .reaction(operationTarget, operationMessageId, _, _),
                 let .edit(operationTarget, operationMessageId, _, _, _, _, _, _),
                 let .reschedule(operationTarget, operationMessageId, _, _, _, _, _),
                 let .cancelScheduled(operationTarget, operationMessageId, _, _):
                return operationTarget == target && operationMessageId == messageId
            case let .delete(operationTarget, messageIds, _, _):
                return operationTarget == target && messageIds.contains(messageId)
            default:
                return false
            }
        }
    }

    private func hasPendingEdit(for target: PendingChatTarget, messageId: Int) -> Bool {
        pendingChatOperations.contains { operation in
            guard case let .edit(operationTarget, operationMessageId, _, _, _, _, _, _) = operation else {
                return false
            }
            return operationTarget == target && operationMessageId == messageId
        }
    }

    private func settlePendingMessageIndicator(for target: PendingChatTarget, messageId: Int) {
        guard !hasPendingMutation(for: target, messageId: messageId) else { return }
        pendingChatMessageIds.remove(messageId)
    }

    private func enqueuePendingChatOperation(_ operation: PendingChatOperation) {
        if pendingChatOperationsOwnerUserId == nil {
            guard let ownerUserId = bootstrap?.me.id else { return }
            pendingChatOperationsOwnerUserId = ownerUserId
        }
        if case let .reaction(target, messageId, _, _) = operation {
            pendingChatOperations = pendingChatOperations.enumerated().compactMap { index, pending in
                if isProcessingPendingChatOperations && index == 0 { return pending }
                guard case let .reaction(pendingTarget, pendingMessageId, _, _) = pending,
                      pendingTarget == target,
                      pendingMessageId == messageId else {
                    return pending
                }
                return nil
            }
        }
        if case let .edit(target, messageId, _, _, _, _, _, _) = operation {
            pendingChatOperations = pendingChatOperations.enumerated().compactMap { index, pending in
                if isProcessingPendingChatOperations && index == 0 { return pending }
                guard case let .edit(pendingTarget, pendingMessageId, _, _, _, _, _, _) = pending,
                      pendingTarget == target,
                      pendingMessageId == messageId else {
                    return pending
                }
                return nil
            }
        }
        if case let .pin(target, messageId, _, _) = operation {
            pendingChatOperations.removeAll { pending in
                guard case let .pin(pendingTarget, pendingMessageId, _, _) = pending else { return false }
                return pendingTarget == target && pendingMessageId == messageId
            }
        }
        if case let .reschedule(target, _, scheduledMessageId, _, _, _, _) = operation {
            pendingChatOperations = pendingChatOperations.enumerated().compactMap { index, pending in
                if isProcessingPendingChatOperations && index == 0 { return pending }
                guard case let .reschedule(pendingTarget, _, pendingScheduledMessageId, _, _, _, _) = pending,
                      pendingTarget == target,
                      pendingScheduledMessageId == scheduledMessageId else {
                    return pending
                }
                return nil
            }
        }
        if case let .cancelScheduled(target, _, scheduledMessageId, _) = operation {
            pendingChatOperations = pendingChatOperations.enumerated().compactMap { index, pending in
                if isProcessingPendingChatOperations && index == 0 { return pending }
                switch pending {
                case let .reschedule(pendingTarget, _, pendingScheduledMessageId, _, _, _, _),
                     let .cancelScheduled(pendingTarget, _, pendingScheduledMessageId, _):
                    return pendingTarget == target && pendingScheduledMessageId == scheduledMessageId ? nil : pending
                default:
                    return pending
                }
            }
        }
        pendingChatOperations.append(operation)
        persistPendingChatOperations()
        schedulePendingChatRetry()
    }

    private func schedulePendingChatRetry(after delay: UInt64 = 1_500_000_000) {
        guard pendingChatRetryTask == nil else { return }
        pendingChatRetryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.pendingChatRetryTask = nil
            await self?.processPendingChatOperations()
        }
    }

    func pendingSendError(in conversation: AloConversationDetail) -> String? {
        let target = pendingTarget(for: conversation)
        return pendingChatOperations.lazy.filter { $0.target == target }.compactMap {
            $0.outgoingLocalId.flatMap { self.failedChatMessageErrors[$0] }
        }.first
    }

    func retryPendingMessages(in conversation: AloConversationDetail) {
        let target = pendingTarget(for: conversation)
        for operation in pendingChatOperations where operation.target == target {
            guard let id = operation.outgoingLocalId else { continue }
            pausedOutgoingMessageIds.remove(id)
            failedChatMessageErrors.removeValue(forKey: id)
        }
        persistPendingChatOperations()
        Task { await processPendingChatOperations() }
    }

    private func retainFailedSend(_ operation: PendingChatOperation, message: String, pause: Bool) -> Bool {
        guard let id = operation.outgoingLocalId else { return false }
        failedChatMessageErrors[id] = message
        if pause { pausedOutgoingMessageIds.insert(id) }
        return true
    }

    private func sendTextMessageOptimistically(
        body: String,
        conversation: AloConversationDetail,
        replyToMessageId: Int,
        topicId: Int,
        preserveComposer: Bool = false,
        pollDefinition: AloPollDefinition? = nil,
        silent: Bool = false,
        scheduledAt: String = "",
        sendWhenOnline: Bool = false
    ) {
        let localId = nextLocalMessageId
        nextLocalMessageId -= 1
        let target = pendingTarget(for: conversation)
        let createdAt = scheduledAt.isEmpty ? currentTimestamp() : scheduledAt
        let message = AloChatMessage(
            localId: localId,
            senderId: bootstrap?.me.id ?? 0,
            recipientId: conversation.kind == "direct" ? conversation.peerId : 0,
            body: body,
            topicId: topicId,
            replyToMessageId: replyToMessageId,
            createdAt: createdAt,
            scheduledAt: scheduledAt,
            silent: silent,
            sendWhenOnline: sendWhenOnline
        )
        pendingChatMessageIds.insert(localId)
        activeConversation = conversation.replacingItems(conversation.items + [message])
        if !preserveComposer {
            messageText = ""
        }
        enqueuePendingChatOperation(
            .sendText(
                localId: localId,
                target: target,
                body: body,
                topicId: topicId,
                replyToMessageId: replyToMessageId,
                createdAt: createdAt,
                clientMessageId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                encryptedPayload: nil,
                pollDefinition: pollDefinition,
                silent: silent,
                scheduledAt: scheduledAt,
                sendWhenOnline: sendWhenOnline
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
        forwardFrom: AloForwardMeta?,
        replyToMessageId: Int,
        topicId: Int,
        silent: Bool = false,
        scheduledAt: String = "",
        sendWhenOnline: Bool = false
    ) {
        let localId = nextLocalMessageId
        nextLocalMessageId -= 1
        let target = pendingTarget(for: conversation)
        let createdAt = scheduledAt.isEmpty ? currentTimestamp() : scheduledAt
        let message = AloChatMessage(
            localId: localId,
            senderId: bootstrap?.me.id ?? 0,
            recipientId: conversation.kind == "direct" ? conversation.peerId : 0,
            body: body,
            topicId: topicId,
            replyToMessageId: replyToMessageId,
            createdAt: createdAt,
            attachments: localAttachments.map { AloMessageAttachment(local: $0, includeInlineData: false) },
            forwardFrom: forwardFrom,
            scheduledAt: scheduledAt,
            silent: silent,
            sendWhenOnline: sendWhenOnline
        )
        pendingChatMessageIds.insert(localId)
        activeConversation = conversation.replacingItems(conversation.items + [message])
        messageText = ""
        enqueuePendingChatOperation(
            .sendDraft(
                localId: localId,
                target: target,
                body: body,
                topicId: topicId,
                replyToMessageId: replyToMessageId,
                createdAt: createdAt,
                attachments: localAttachments,
                uploadedAttachments: [],
                forwardFrom: forwardFrom,
                clientMessageId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                encryptedPayload: nil,
                silent: silent,
                scheduledAt: scheduledAt,
                sendWhenOnline: sendWhenOnline
            )
        )
        Task {
            await processPendingChatOperations()
        }
    }

    private func sendUploadedAttachmentsOptimistically(
        body: String,
        conversation: AloConversationDetail,
        uploadedAttachments: [AloMessageAttachment],
        replyToMessageId: Int,
        topicId: Int,
        preserveComposer: Bool = false
    ) {
        guard !uploadedAttachments.isEmpty else { return }
        let localId = nextLocalMessageId
        nextLocalMessageId -= 1
        let target = pendingTarget(for: conversation)
        let createdAt = currentTimestamp()
        let message = AloChatMessage(
            localId: localId,
            senderId: bootstrap?.me.id ?? 0,
            recipientId: conversation.kind == "direct" ? conversation.peerId : 0,
            body: body,
            topicId: topicId,
            replyToMessageId: replyToMessageId,
            createdAt: createdAt,
            attachments: uploadedAttachments
        )
        pendingChatMessageIds.insert(localId)
        activeConversation = conversation.replacingItems(conversation.items + [message])
        if !preserveComposer {
            messageText = ""
        }
        enqueuePendingChatOperation(
            .sendDraft(
                localId: localId,
                target: target,
                body: body,
                topicId: topicId,
                replyToMessageId: replyToMessageId,
                createdAt: createdAt,
                attachments: [],
                uploadedAttachments: uploadedAttachments,
                forwardFrom: nil,
                clientMessageId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                encryptedPayload: nil,
                silent: false,
                scheduledAt: "",
                sendWhenOnline: false
            )
        )
        Task {
            await processPendingChatOperations()
        }
    }

    private func applyOptimisticReaction(messageId: Int, desiredEmoji: String) {
        guard let activeConversation else { return }
        let projectedItems = AloPendingChatProjection.applyingDesiredReactions(
            to: activeConversation.items,
            desiredEmojiByMessageId: [messageId: desiredEmoji]
        )
        self.activeConversation = activeConversation.replacingItems(projectedItems)
    }

    private func processPendingChatOperations() async {
        guard !isProcessingPendingChatOperations, !Task.isCancelled else { return }
        pendingChatRetryTask?.cancel()
        pendingChatRetryTask = nil
        isProcessingPendingChatOperations = true
        defer { isProcessingPendingChatOperations = false }

        let ownerUserId = pendingChatOperationsOwnerUserId

        var operationsRemainingInPass = pendingChatOperations.count
        var deferredRetryDelay: UInt64?
        while !pendingChatOperations.isEmpty, operationsRemainingInPass > 0 {
            guard !Task.isCancelled else { return }
            do {
                try await pendingOutboxWrite?.value
            } catch {
                // Do not upload an operation that failed durable storage, and
                // never silently discard it from the in-memory queue.
                guard ownerUserId == pendingChatOperationsOwnerUserId else { return }
                if let operation = pendingChatOperations.first {
                    _ = retainFailedSend(operation, message: "Не удалось сохранить вложение на устройстве. Проверьте свободное место и доступ к файлу, затем повторите отправку.", pause: true)
                }
                return
            }
            guard !Task.isCancelled, ownerUserId == pendingChatOperationsOwnerUserId,
                  !pendingChatOperations.isEmpty else { return }
            operationsRemainingInPass -= 1
            let operation = pendingChatOperations[0]
            if let id = operation.outgoingLocalId, pausedOutgoingMessageIds.contains(id) {
                pendingChatOperations.append(pendingChatOperations.removeFirst())
                continue
            }
            if isBlockedDirectPeer(operation.target) {
                clearPendingState(for: operation)
                pendingChatOperations.removeFirst()
                persistPendingChatOperations()
                continue
            }
            do {
                switch operation {
                case let .sendText(
                    localId,
                    target,
                    body,
                    topicId,
                    replyToMessageId,
                    createdAt,
                    clientMessageId,
                    encryptedPayload,
                    pollDefinition,
                    silent,
                    scheduledAt,
                    sendWhenOnline
                ):
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
                        guard ownerUserId == pendingChatOperationsOwnerUserId,
                              pendingChatOperations.first?.outgoingLocalId == localId else { return }
                        pendingChatOperations[0] = .sendText(
                            localId: localId,
                            target: target,
                            body: body,
                            topicId: topicId,
                            replyToMessageId: replyToMessageId,
                            createdAt: createdAt,
                            clientMessageId: clientMessageId,
                            encryptedPayload: preparedPayload,
                            pollDefinition: pollDefinition,
                            silent: silent,
                            scheduledAt: scheduledAt,
                            sendWhenOnline: sendWhenOnline
                        )
                        persistPendingChatOperations()
                    }
                    let scheduledPollDefinition: AloPollDefinition?
                    if case .create = AloPollCodec.decode(body) {
                        scheduledPollDefinition = pollDefinition
                    } else {
                        scheduledPollDefinition = nil
                    }
                    try await pendingOutboxWrite?.value
                    guard ownerUserId == pendingChatOperationsOwnerUserId, !Task.isCancelled else { return }
                    let acknowledgement = try await api.sendPreparedMessage(
                        peerId: target.peerId,
                        roomId: target.roomId,
                        kind: target.kind,
                        encryptedPayload: preparedPayload,
                        replyToMessageId: replyToMessageId,
                        topicId: topicId,
                        silent: silent,
                        scheduledAt: scheduledAt,
                        sendWhenOnline: sendWhenOnline,
                        scheduledPoll: scheduledPollDefinition,
                        clientMessageId: clientMessageId
                    )
                    guard ownerUserId == pendingChatOperationsOwnerUserId,
                          pendingChatOperations.first?.outgoingLocalId == localId else { return }
                    switch AloPollCodec.decode(body) {
                    case let .create(decodedDefinition):
                        if !acknowledgement.scheduled {
                            let definition = pollDefinition ?? decodedDefinition
                            _ = try await api.registerPoll(
                                definition,
                                messageId: acknowledgement.messageId,
                                conversation: conversation(for: target)
                            )
                        }
                    case let .vote(pollId, optionIds):
                        // An anonymous vote stays inside the E2EE message.  The
                        // canonical endpoint remains only for explicitly public
                        // polls, where the server may expose voters by design.
                        if pollDefinition?.isAnonymous == false {
                            _ = try await api.votePoll(pollId: pollId, optionIds: optionIds)
                        }
                    case .reveal:
                        break
                    case nil:
                        break
                    }
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
                    topicId,
                    replyToMessageId,
                    createdAt,
                    attachments,
                    existingUploadedAttachments,
                    forwardFrom,
                    clientMessageId,
                    encryptedPayload,
                    silent,
                    scheduledAt,
                    sendWhenOnline
                ):
                    var uploadedAttachments = existingUploadedAttachments
                    if uploadedAttachments.count < attachments.count {
                        for index in uploadedAttachments.count..<attachments.count {
                            let attachmentId = "\(clientMessageId)-\(index)"
                            let ownerUserId = pendingChatOperationsOwnerUserId ?? bootstrap?.me.id ?? 0
                            let checkpoint = ownerUserId > 0
                                ? AloSecureOutboxStore.shared.loadUploadCheckpoint(
                                    id: attachmentId,
                                    ownerUserId: ownerUserId
                                )
                                : nil
                            let uploaded = try await api.uploadE2EEAttachment(
                                attachments[index],
                                resumeCheckpoint: checkpoint,
                                onCheckpoint: { checkpoint in
                                    guard ownerUserId > 0 else { return }
                                    try? AloSecureOutboxStore.shared.saveUploadCheckpoint(
                                        checkpoint,
                                        id: attachmentId,
                                        ownerUserId: ownerUserId
                                    )
                                }
                            )
                            guard ownerUserId == pendingChatOperationsOwnerUserId, !Task.isCancelled,
                                  !pendingChatOperations.isEmpty else { return }
                            if ownerUserId > 0 {
                                AloSecureOutboxStore.shared.deleteUploadCheckpoint(
                                    id: attachmentId,
                                    ownerUserId: ownerUserId
                                )
                            }
                            uploadedAttachments.append(uploaded)
                            pendingChatOperations[0] = .sendDraft(
                                localId: localId,
                                target: target,
                                body: body,
                                topicId: topicId,
                                replyToMessageId: replyToMessageId,
                                createdAt: createdAt,
                                attachments: attachments,
                                uploadedAttachments: uploadedAttachments,
                                forwardFrom: forwardFrom,
                                clientMessageId: clientMessageId,
                                encryptedPayload: nil,
                                silent: silent,
                                scheduledAt: scheduledAt,
                                sendWhenOnline: sendWhenOnline
                            )
                            persistPendingChatOperations()
                            try await pendingOutboxWrite?.value
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
                        guard ownerUserId == pendingChatOperationsOwnerUserId,
                              pendingChatOperations.first?.outgoingLocalId == localId else { return }
                        pendingChatOperations[0] = .sendDraft(
                            localId: localId,
                            target: target,
                            body: body,
                            topicId: topicId,
                            replyToMessageId: replyToMessageId,
                            createdAt: createdAt,
                            attachments: attachments,
                            uploadedAttachments: uploadedAttachments,
                            forwardFrom: forwardFrom,
                            clientMessageId: clientMessageId,
                            encryptedPayload: preparedPayload,
                            silent: silent,
                            scheduledAt: scheduledAt,
                            sendWhenOnline: sendWhenOnline
                        )
                        persistPendingChatOperations()
                    }
                    try await pendingOutboxWrite?.value
                    guard ownerUserId == pendingChatOperationsOwnerUserId, !Task.isCancelled else { return }
                    let acknowledgement = try await api.sendPreparedMessage(
                        peerId: target.peerId,
                        roomId: target.roomId,
                        kind: target.kind,
                        encryptedPayload: preparedPayload,
                        attachments: uploadedAttachments,
                        forwardFrom: forwardFrom,
                        replyToMessageId: replyToMessageId,
                        topicId: topicId,
                        silent: silent,
                        scheduledAt: scheduledAt,
                        sendWhenOnline: sendWhenOnline,
                        clientMessageId: clientMessageId
                    )
                    guard ownerUserId == pendingChatOperationsOwnerUserId,
                          pendingChatOperations.first?.outgoingLocalId == localId else { return }
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    deletePersistedAttachments(clientMessageId: clientMessageId, count: attachments.count, drafts: attachments)
                    pendingChatMessageIds.remove(localId)
                    acknowledgePendingMessage(
                        localId: localId,
                        target: target,
                        acknowledgement: acknowledgement
                    )
                    await refreshConversationIfCurrent(target, droppingLocalId: localId)

                case let .reaction(target, messageId, emoji, operationId):
                    guard messageId > 0 else {
                        pendingChatOperations.removeFirst()
                        persistPendingChatOperations()
                        continue
                    }
                    let reactions = try await api.toggleMessageReaction(
                        conversation: conversation(for: target),
                        messageId: messageId,
                        desiredEmoji: emoji,
                        operationId: operationId
                    )
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    settlePendingMessageIndicator(for: target, messageId: messageId)
                    if let activeConversation,
                       isActiveConversation(target),
                       let message = activeConversation.items.first(where: { $0.id == messageId }) {
                        self.activeConversation = mergePendingLocalMessages(
                            into: activeConversation.replacingMessage(message.replacingReactions(reactions))
                        )
                    }

                case let .edit(
                    target,
                    messageId,
                    originalBody,
                    body,
                    attachments,
                    forwardFrom,
                    encryptedPayload,
                    operationId
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
                            encryptedPayload: preparedPayload,
                            operationId: operationId
                        )
                        persistPendingChatOperations()
                    }
                    let result = try await api.sendPreparedMessageEdit(
                        conversation: conversation(for: target),
                        messageId: messageId,
                        body: body,
                        encryptedPayload: preparedPayload,
                        operationId: operationId
                    )
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    settlePendingMessageIndicator(for: target, messageId: messageId)
                    if let activeConversation,
                       isActiveConversation(target),
                       let message = activeConversation.items.first(where: { $0.id == messageId }) {
                        self.activeConversation = mergePendingLocalMessages(
                            into: activeConversation.replacingMessage(
                                message.replacingBody(result.body, editedAt: result.editedAt)
                            )
                        )
                    }
                    await refreshConversationIfCurrent(target)

                case let .delete(target, messageIds, mode, operationId):
                    try await api.deleteMessages(
                        messageIds: messageIds,
                        conversation: conversation(for: target),
                        mode: mode,
                        operationId: operationId
                    )
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    messageIds.forEach { settlePendingMessageIndicator(for: target, messageId: $0) }
                    await refreshConversationIfCurrent(target)

                case let .pin(target, messageId, pinned, operationId):
                    try await api.toggleMessagePin(
                        conversation: conversation(for: target),
                        messageId: messageId,
                        pinned: pinned,
                        operationId: operationId
                    )
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    await refreshConversationIfCurrent(target)

                case let .reschedule(target, messageId, scheduledMessageId, _, scheduledAt, silent, operationId):
                    try await api.updateScheduledMessage(
                        scheduledMessageId: scheduledMessageId,
                        scheduledAt: scheduledAt,
                        silent: silent,
                        operationId: operationId
                    )
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    settlePendingMessageIndicator(for: target, messageId: messageId)
                    await refreshConversationIfCurrent(target)

                case let .cancelScheduled(target, messageId, scheduledMessageId, operationId):
                    try await api.cancelScheduledMessage(
                        scheduledMessageId: scheduledMessageId,
                        operationId: operationId
                    )
                    pendingChatOperations.removeFirst()
                    persistPendingChatOperations()
                    settlePendingMessageIndicator(for: target, messageId: messageId)
                    await refreshConversationIfCurrent(target)
                }
                if let id = operation.outgoingLocalId {
                    failedChatMessageErrors.removeValue(forKey: id)
                    pausedOutgoingMessageIds.remove(id)
                }
            } catch let error as AloAPIError {
                if shouldQueueForConnectivity(error) {
                    _ = retainFailedSend(operation, message: error.message, pause: false)
                    schedulePendingChatRetry(after: retryDelay(for: error))
                    return
                }
                if shouldKeepPending(error) {
                    _ = retainFailedSend(operation, message: error.message, pause: false)
                    let deferredOperation = pendingChatOperations.removeFirst()
                    pendingChatOperations.append(deferredOperation)
                    persistPendingChatOperations()
                    let delay = retryDelay(for: error)
                    deferredRetryDelay = min(deferredRetryDelay ?? delay, delay)
                    continue
                }
                if error.status == 401 {
                    _ = retainFailedSend(operation, message: "Войдите в аккаунт, чтобы отправить сохранённое сообщение.", pause: true)
                    phase = .auth
                    persistPendingChatOperations()
                    return
                }
                if retainFailedSend(operation, message: error.message, pause: true) {
                    pendingChatOperations.append(pendingChatOperations.removeFirst())
                    persistPendingChatOperations()
                    continue
                }
                pendingChatOperations.removeFirst()
                persistPendingChatOperations()
                clearPendingState(for: operation)
                errorMessage = error.message
                switch operation {
                case .reaction, .edit, .reschedule, .cancelScheduled:
                    await refreshConversationIfCurrent(operation.target)
                default:
                    break
                }
                continue
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                let retryable = AloAPIClient.shouldRetryUpload(error)
                if retainFailedSend(operation, message: "Не удалось отправить сообщение. \(error.localizedDescription)", pause: !retryable) {
                    pendingChatOperations.append(pendingChatOperations.removeFirst())
                    persistPendingChatOperations()
                    if retryable { deferredRetryDelay = 15_000_000_000 }
                    continue
                }
                let deferredOperation = pendingChatOperations.removeFirst()
                pendingChatOperations.append(deferredOperation)
                persistPendingChatOperations()
                deferredRetryDelay = min(deferredRetryDelay ?? 1_500_000_000, 1_500_000_000)
            }
        }
        if pendingChatOperations.contains(where: { operation in
            operation.outgoingLocalId.map { !pausedOutgoingMessageIds.contains($0) } ?? true
        }) {
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
        if let id = operation.outgoingLocalId {
            failedChatMessageErrors.removeValue(forKey: id)
            pausedOutgoingMessageIds.remove(id)
        }
        switch operation {
        case let .sendText(localId, _, _, _, _, _, _, _, _, _, _, _):
            pendingChatMessageIds.remove(localId)
            if let activeConversation {
                self.activeConversation = activeConversation.replacingItems(
                    activeConversation.items.filter { $0.id != localId }
                )
            }
        case let .sendDraft(localId, _, _, _, _, _, attachments, _, _, clientMessageId, _, _, _, _):
            deletePersistedAttachments(clientMessageId: clientMessageId, count: attachments.count, drafts: attachments)
            pendingChatMessageIds.remove(localId)
            if let activeConversation {
                self.activeConversation = activeConversation.replacingItems(
                    activeConversation.items.filter { $0.id != localId }
                )
            }
        case let .reaction(target, messageId, _, _):
            settlePendingMessageIndicator(for: target, messageId: messageId)
        case let .edit(target, messageId, originalBody, _, _, _, _, _):
            settlePendingMessageIndicator(for: target, messageId: messageId)
            if !hasPendingEdit(for: target, messageId: messageId),
               let activeConversation,
               isActiveConversation(target),
               let message = activeConversation.items.first(where: { $0.id == messageId }) {
                self.activeConversation = activeConversation.replacingMessage(
                    message.replacingBody(originalBody, editedAt: message.editedAt)
                )
            }
        case let .delete(target, messageIds, _, _):
            messageIds.forEach { settlePendingMessageIndicator(for: target, messageId: $0) }
        case let .pin(target, messageId, pinned, _):
            guard let activeConversation, isActiveConversation(target) else { return }
            let restoredIds = pinned
                ? activeConversation.pinnedMessageIds.filter { $0 != messageId }
                : [messageId] + activeConversation.pinnedMessageIds.filter { $0 != messageId }
            self.activeConversation = activeConversation.replacingPinnedMessageIds(restoredIds)
        case let .reschedule(target, messageId, _, _, _, _, _),
             let .cancelScheduled(target, messageId, _, _):
            settlePendingMessageIndicator(for: target, messageId: messageId)
        }
    }

    private func persistPendingChatOperations() {
        guard let ownerUserId = pendingChatOperationsOwnerUserId else { return }
        let records = pendingChatOperations.compactMap {
            pendingOperationRecord($0, ownerUserId: ownerUserId)
        }
        let attachments = pendingChatOperations.flatMap { operation -> [AloSecureOutboxStore.AttachmentWrite] in
            guard case let .sendDraft(_, _, _, _, _, _, attachments, _, _, clientMessageId, _, _, _, _) = operation else { return [] }
            return attachments.enumerated().map {
                AloSecureOutboxStore.AttachmentWrite(id: "\(clientMessageId)-\($0.offset)", attachment: $0.element)
            }
        }
        pendingOutboxWrite = AloSecureOutboxStore.shared.scheduleSave(records: records, attachments: attachments, ownerUserId: ownerUserId)
    }

    private func activatePendingChatOutbox(ownerUserId: Int) {
        guard ownerUserId > 0, pendingChatOperationsOwnerUserId != ownerUserId else { return }
        pendingChatOperations.removeAll()
        pendingChatMessageIds.removeAll()
        failedChatMessageErrors.removeAll()
        pausedOutgoingMessageIds.removeAll()
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
            case let .sendText(localId, _, _, _, _, _, _, _, _, _, _, _),
                 let .sendDraft(localId, _, _, _, _, _, _, _, _, _, _, _, _, _):
                pendingChatMessageIds.insert(localId)
                nextLocalMessageId = min(nextLocalMessageId, localId - 1)
            case let .reaction(_, messageId, _, _),
                 let .edit(_, messageId, _, _, _, _, _, _):
                pendingChatMessageIds.insert(messageId)
            case let .delete(_, messageIds, _, _):
                pendingChatMessageIds.formUnion(messageIds)
            case let .reschedule(_, messageId, _, _, _, _, _),
                 let .cancelScheduled(_, messageId, _, _):
                pendingChatMessageIds.insert(messageId)
            case .pin:
                break
            }
        }
        persistPendingChatOperations()
    }

    private func clearPendingChatOutboxForLogout() {
        pendingChatRetryTask?.cancel()
        pendingChatRetryTask = nil
        pendingChatRefreshTask?.cancel()
        pendingChatRefreshRevision += 1
        failedChatMessageErrors.removeAll()
        pausedOutgoingMessageIds.removeAll()
        if let ownerUserId = pendingChatOperationsOwnerUserId ?? bootstrap?.me.id {
            AloSecureOutboxStore.shared.scheduleClear(ownerUserId: ownerUserId)
        }
        pendingChatOperations.removeAll()
        pendingChatMessageIds.removeAll()
        pendingChatOperationsOwnerUserId = nil
        pendingOutboxWrite = nil
        nextLocalMessageId = -1
    }

    private func pendingOperationRecord(
        _ operation: PendingChatOperation,
        ownerUserId: Int
    ) -> [String: Any]? {
        switch operation {
        case let .sendText(
            localId,
            target,
            body,
            topicId,
            replyToMessageId,
            createdAt,
            clientMessageId,
            encryptedPayload,
            pollDefinition,
            silent,
            scheduledAt,
            sendWhenOnline
        ):
            var record: [String: Any] = [
                "type": "sendText",
                "localId": localId,
                "target": pendingTargetRecord(target),
                "body": body,
                "topicId": topicId,
                "replyToMessageId": replyToMessageId,
                "createdAt": createdAt,
                "clientMessageId": clientMessageId,
                "silent": silent,
                "scheduledAt": scheduledAt,
                "sendWhenOnline": sendWhenOnline
            ]
            if let encryptedPayload { record["encryptedPayload"] = encryptedPayload }
            if let pollDefinition { record["pollDefinition"] = pollDefinitionRecord(pollDefinition) }
            return record

        case let .sendDraft(
            localId,
            target,
            body,
            topicId,
            replyToMessageId,
            createdAt,
            attachments,
            uploadedAttachments,
            forwardFrom,
            clientMessageId,
            encryptedPayload,
            silent,
            scheduledAt,
            sendWhenOnline
        ):
            var attachmentRecords = [[String: Any]]()
            for (index, attachment) in attachments.enumerated() {
                let fileId = "\(clientMessageId)-\(index)"
                var attachmentRecord: [String: Any] = [
                    "fileId": fileId,
                    "mime": attachment.mime,
                    "type": attachment.type,
                    "name": attachment.name,
                    "waveform": attachment.waveform.map(Double.init)
                ]
                if let duration = attachment.durationSeconds {
                    attachmentRecord["durationSeconds"] = duration
                }
                if let dimensions = attachment.mediaDimensions {
                    attachmentRecord["mediaDimensions"] = dimensions.metadata
                }
                if let playbackURL = attachment.localPlaybackURL {
                    attachmentRecord["localPlaybackURL"] = playbackURL.absoluteString
                }
                if attachment.encryptedSourceURL != nil, !attachment.mediaEncryption.isEmpty {
                    attachmentRecord["storage"] = "chunked"
                    attachmentRecord["mediaEncryption"] = attachment.mediaEncryption
                    attachmentRecord["encryptedChecksum"] = attachment.encryptedChecksum
                }
                attachmentRecords.append(attachmentRecord)
            }
            var record: [String: Any] = [
                "type": "sendDraft",
                "localId": localId,
                "target": pendingTargetRecord(target),
                "body": body,
                "topicId": topicId,
                "replyToMessageId": replyToMessageId,
                "createdAt": createdAt,
                "attachments": attachmentRecords,
                "uploadedAttachments": uploadedAttachments.map(messageAttachmentRecord),
                "clientMessageId": clientMessageId,
                "silent": silent,
                "scheduledAt": scheduledAt,
                "sendWhenOnline": sendWhenOnline
            ]
            if let forwardFrom {
                record["forwardFrom"] = ["userId": forwardFrom.userId, "messageId": forwardFrom.messageId]
            }
            if let encryptedPayload { record["encryptedPayload"] = encryptedPayload }
            return record

        case let .reaction(target, messageId, emoji, operationId):
            return [
                "type": "reaction",
                "target": pendingTargetRecord(target),
                "messageId": messageId,
                "emoji": emoji,
                "operationId": operationId
            ]

        case let .edit(target, messageId, originalBody, body, attachments, forwardFrom, encryptedPayload, operationId):
            var record: [String: Any] = [
                "type": "edit",
                "target": pendingTargetRecord(target),
                "messageId": messageId,
                "originalBody": originalBody,
                "body": body,
                "attachments": attachments.map(messageAttachmentRecord),
                "operationId": operationId
            ]
            if let forwardFrom {
                record["forwardFrom"] = ["userId": forwardFrom.userId, "messageId": forwardFrom.messageId]
            }
            if let encryptedPayload { record["encryptedPayload"] = encryptedPayload }
            return record

        case let .delete(target, messageIds, mode, operationId):
            return [
                "type": "delete",
                "target": pendingTargetRecord(target),
                "messageIds": messageIds,
                "mode": mode,
                "operationId": operationId
            ]
        case let .pin(target, messageId, pinned, operationId):
            return [
                "type": "pin",
                "target": pendingTargetRecord(target),
                "messageId": messageId,
                "pinned": pinned,
                "operationId": operationId
            ]
        case let .reschedule(
            target,
            messageId,
            scheduledMessageId,
            originalScheduledAt,
            scheduledAt,
            silent,
            operationId
        ):
            return [
                "type": "scheduledReschedule",
                "target": pendingTargetRecord(target),
                "messageId": messageId,
                "scheduledMessageId": scheduledMessageId,
                "originalScheduledAt": originalScheduledAt,
                "scheduledAt": scheduledAt,
                "silent": silent,
                "operationId": operationId
            ]
        case let .cancelScheduled(target, messageId, scheduledMessageId, operationId):
            return [
                "type": "scheduledCancel",
                "target": pendingTargetRecord(target),
                "messageId": messageId,
                "scheduledMessageId": scheduledMessageId,
                "operationId": operationId
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
                topicId: max(0, record.int("topicId")),
                replyToMessageId: max(0, record.int("replyToMessageId")),
                createdAt: record.string("createdAt").ifBlank(currentTimestamp()),
                clientMessageId: clientMessageId,
                encryptedPayload: record.optionalObject("encryptedPayload"),
                pollDefinition: record.optionalObject("pollDefinition").flatMap(pollDefinition(from:)),
                silent: record.bool("silent"),
                scheduledAt: record.string("scheduledAt"),
                sendWhenOnline: record.bool("sendWhenOnline")
            )

        case "sendDraft":
            let localId = record.int("localId")
            let clientMessageId = record.string("clientMessageId")
            guard localId < 0, !clientMessageId.isEmpty else { return nil }
            let attachments = record.array("attachments").compactMap { item -> AloLocalAttachment? in
                let waveform = (item["waveform"] as? [NSNumber] ?? []).map { CGFloat($0.doubleValue) }
                if item.string("storage") == "chunked",
                   let encryptedURL = AloSecureOutboxStore.shared.loadChunkedAttachmentURL(
                    id: item.string("fileId"),
                    ownerUserId: ownerUserId
                   ) {
                    let encryption = item.object("mediaEncryption").reduce(into: [String: String]()) { result, pair in
                        result[pair.key] = String(describing: pair.value)
                    }
                    guard AloChunkedMediaCrypto.Metadata(
                        encryption.reduce(into: [String: Any]()) { result, pair in
                            result[pair.key] = pair.value
                        }
                    ) != nil else { return nil }
                    return AloLocalAttachment(
                        data: Data(),
                        mime: item.string("mime"),
                        type: item.string("type"),
                        name: item.string("name"),
                        waveform: waveform,
                        encryptedSourceURL: encryptedURL,
                        mediaEncryption: encryption,
                        encryptedChecksum: item.string("encryptedChecksum"),
                        localPlaybackURL: URL(string: item.string("localPlaybackURL")).flatMap {
                            AloSecureMediaStore.shared.isSecureURL($0) ? $0 : nil
                        },
                        durationSeconds: (item["durationSeconds"] as? NSNumber)?.doubleValue,
                        mediaDimensions: AloMediaDimensions(item.object("mediaDimensions").compactMapValues { $0 as? String })
                    )
                }
                guard let data = AloSecureOutboxStore.shared.loadAttachment(
                    id: item.string("fileId"),
                    ownerUserId: ownerUserId
                ) else { return nil }
                return AloLocalAttachment(
                    data: data,
                    mime: item.string("mime"),
                    type: item.string("type"),
                    name: item.string("name"),
                    waveform: waveform,
                    durationSeconds: (item["durationSeconds"] as? NSNumber)?.doubleValue,
                    mediaDimensions: AloMediaDimensions(item.object("mediaDimensions").compactMapValues { $0 as? String })
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
                topicId: max(0, record.int("topicId")),
                replyToMessageId: max(0, record.int("replyToMessageId")),
                createdAt: record.string("createdAt").ifBlank(currentTimestamp()),
                attachments: attachments,
                uploadedAttachments: uploaded,
                forwardFrom: forwardFrom,
                clientMessageId: clientMessageId,
                encryptedPayload: record.optionalObject("encryptedPayload"),
                silent: record.bool("silent"),
                scheduledAt: record.string("scheduledAt"),
                sendWhenOnline: record.bool("sendWhenOnline")
            )

        case "reaction":
            return .reaction(
                target: target,
                messageId: record.int("messageId"),
                emoji: record.string("emoji"),
                operationId: pendingOperationId(from: record)
            )
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
                encryptedPayload: record.optionalObject("encryptedPayload"),
                operationId: pendingOperationId(from: record)
            )
        case "delete":
            let ids = (record["messageIds"] as? [NSNumber] ?? []).map(\.intValue)
            return .delete(
                target: target,
                messageIds: ids,
                mode: record.string("mode"),
                operationId: pendingOperationId(from: record)
            )
        case "pin":
            let messageId = record.int("messageId")
            guard messageId > 0 else { return nil }
            return .pin(
                target: target,
                messageId: messageId,
                pinned: record.bool("pinned"),
                operationId: pendingOperationId(from: record)
            )
        case "scheduledReschedule":
            let messageId = record.int("messageId")
            let scheduledMessageId = record.int("scheduledMessageId")
            let scheduledAt = record.string("scheduledAt")
            guard messageId != 0, scheduledMessageId > 0, !scheduledAt.isEmpty else { return nil }
            return .reschedule(
                target: target,
                messageId: messageId,
                scheduledMessageId: scheduledMessageId,
                originalScheduledAt: record.string("originalScheduledAt"),
                scheduledAt: scheduledAt,
                silent: record.bool("silent"),
                operationId: pendingOperationId(from: record)
            )
        case "scheduledCancel":
            let messageId = record.int("messageId")
            let scheduledMessageId = record.int("scheduledMessageId")
            guard messageId != 0, scheduledMessageId > 0 else { return nil }
            return .cancelScheduled(
                target: target,
                messageId: messageId,
                scheduledMessageId: scheduledMessageId,
                operationId: pendingOperationId(from: record)
            )
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

    private func pollDefinitionRecord(_ definition: AloPollDefinition) -> [String: Any] {
        [
            "id": definition.id,
            "question": definition.question,
            "options": definition.options.map { ["id": $0.id, "text": $0.text] },
            "allowsMultipleAnswers": definition.allowsMultipleAnswers,
            "isQuiz": definition.isQuiz,
            "correctOptionIds": Array(definition.correctOptionIds).sorted(),
            "quizAnswerCommitment": definition.quizAnswerCommitment,
            "explanation": definition.explanation,
            "isAnonymous": definition.isAnonymous,
            "allowsRevoting": definition.allowsRevoting,
            "closesAt": definition.closesAt
        ]
    }

    private func pollDefinition(from record: [String: Any]) -> AloPollDefinition? {
        let definition = AloPollDefinition(
            id: record.string("id"),
            question: record.string("question"),
            options: record.array("options").map {
                AloPollOption(id: $0.string("id"), text: $0.string("text"))
            },
            allowsMultipleAnswers: record.bool("allowsMultipleAnswers"),
            isQuiz: record.bool("isQuiz"),
            correctOptionIds: Set((record["correctOptionIds"] as? [String]) ?? []),
            quizAnswerCommitment: record.string("quizAnswerCommitment"),
            explanation: record.string("explanation"),
            isAnonymous: record.bool("isAnonymous"),
            allowsRevoting: record.bool("allowsRevoting"),
            closesAt: record.string("closesAt")
        )
        return AloPollCodec.encodeCreate(definition) == nil ? nil : definition
    }

    private func pendingOperationId(from record: [String: Any]) -> String {
        let value = record.string("operationId")
        guard value.count >= 16,
              value.count <= 160,
              value.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return makeClientOperationId()
        }
        return value
    }

    private func makeClientOperationId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func messageAttachmentRecord(_ attachment: AloMessageAttachment) -> [String: Any] {
        var record: [String: Any] = [
            "type": attachment.type,
            "url": attachment.url,
            "name": attachment.name,
            "waveform": attachment.waveform.map(Double.init),
            "mediaEncryption": attachment.mediaEncryption
        ]
        if !attachment.metadata.isEmpty {
            record["metadata"] = attachment.metadata
        }
        return record
    }

    private func deletePersistedAttachments(clientMessageId: String, count: Int, drafts: [AloLocalAttachment] = []) {
        guard let ownerUserId = pendingChatOperationsOwnerUserId else { return }
        AloSecureOutboxStore.shared.scheduleAttachmentRemoval(
            ids: (0..<count).map { "\(clientMessageId)-\($0)" }, drafts: drafts, ownerUserId: ownerUserId)
    }

    private func refreshConversationIfCurrent(_ target: PendingChatTarget, droppingLocalId: Int? = nil) async {
        guard isActiveConversation(target) else { return }
        pendingChatRefreshRevision += 1
        let revision = pendingChatRefreshRevision
        pendingChatRefreshTask?.cancel()
        // Delivery is acknowledged above. History (including media downloads)
        // is reconciliation, not part of the outbox transaction.
        pendingChatRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled, self.isActiveConversation(target) else { return }
                let updatedConversation = try await self.api.loadConversation(peerId: target.peerId)
                guard !Task.isCancelled, revision == self.pendingChatRefreshRevision,
                      self.isActiveConversation(target) else { return }
                self.activeConversation = self.mergePendingLocalMessages(into: updatedConversation)
            } catch {
                // Live refresh will reconcile later. Never resend an already
                // acknowledged operation because fetching its history failed.
            }
        }
    }

    private func initialBootstrapFlow(revision: Int) async {
        guard !Task.isCancelled, revision == initialRefreshRevision else { return }
        connectionState = .updating
        do {
                let snapshot = try await api.loadBootstrapSnapshot(timeout: 6)
                guard !Task.isCancelled, revision == initialRefreshRevision else { return }
                let data = snapshot.data
                saveBootstrapCache(snapshot.raw)
                bootstrap = data
                persistCurrentAccount(data.me)
                configureBlockedUserState(ownerUserId: data.me.id)
                scheduleBlockedUsersRefresh(ownerUserId: data.me.id)
                activatePendingChatOutbox(ownerUserId: data.me.id)
                if let e2eeWarning = api.latestE2EEWarning {
                    notice = e2eeWarning
                }
                phase = .app
                if let activeConversation { startConversationLive(activeConversation) }
                startChatRealtime(ownerUserId: data.me.id)
                AloPushCoordinator.shared.sync(api: api)
                AloVoIPPushCoordinator.shared.sync(api: api)
                calls.startPolling()
                connectionState = .connected
                initialRetryDelay = 3
                await processPendingChatOperations()
                await processPendingDeepLinkIfPossible()
        } catch {
            guard !Task.isCancelled, revision == initialRefreshRevision else { return }
            if let error = error as? AloAPIError, error.status == 401 {
                stopChatRealtime()
                calls.stop()
                bootstrap = nil
                activeConversation = nil
                clearBootstrapCache()
                phase = .auth
                connectionState = .connected
                return
            }
            connectionState = .unavailable
            // One refresh at a time, with capped backoff. No four consecutive
            // blocking requests and no spinner while merely waiting to retry.
            scheduleConnectionRetry()
        }
    }

    private func scheduleConnectionRetry() {
        initialRetryTask?.cancel()
        let revision = initialRefreshRevision
        let delay = initialRetryDelay
        initialRetryDelay = min(30, delay * 2)
        initialRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, revision == self.initialRefreshRevision else { return }
            self.retryInitialBootstrap()
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
    private func restoreBootstrapCache(peerId: Int = 0, startNetwork: Bool = true) -> Bool {
        guard let data = loadBootstrapCacheData(),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let cached = AloBootstrapData(raw)
        bootstrap = cached
        configureBlockedUserState(ownerUserId: cached.me.id)
        if startNetwork { scheduleBlockedUsersRefresh(ownerUserId: cached.me.id) }
        activatePendingChatOutbox(ownerUserId: cached.me.id)
        if peerId > 0, let summary = cached.conversations.first(where: { $0.peerId == peerId }) {
            let messages = cached.activePeerId == peerId ? cached.activeMessages : []
            let detail = AloConversationDetail(summary: summary, items: messages)
            let projected = mergePendingLocalMessages(into: detail)
            activeConversation = projected
            if startNetwork { startConversationLive(projected) }
        } else if activeConversation == nil,
                  cached.activePeerId > 0,
                  let summary = cached.conversations.first(where: { $0.peerId == cached.activePeerId }) {
            let detail = AloConversationDetail(summary: summary, items: cached.activeMessages)
            let projected = mergePendingLocalMessages(into: detail)
            activeConversation = projected
            if startNetwork { startConversationLive(projected) }
        }
        phase = .app
        if startNetwork {
            startChatRealtime(ownerUserId: cached.me.id)
            AloPushCoordinator.shared.sync(api: api)
            AloVoIPPushCoordinator.shared.sync(api: api)
            calls.startPolling()
        }
        errorMessage = ""
        return true
    }

    private func clearBootstrapCache() {
        AloSecureOfflineCacheStore.shared.clearCurrentOwner()
        removeLegacyBootstrapCache()
        UserDefaults.standard.removeObject(forKey: bootstrapCacheKey)
    }

    private func loadBootstrapCacheData() -> Data? {
        if let startupCacheLoader { return startupCacheLoader() }
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
    static func prepend(_ post: AloPost, to profile: AloUserProfile) -> AloUserProfile {
        return AloUserProfile(
            id: profile.id,
            user: profile.user,
            stats: profile.stats,
            posts: [post] + profile.posts.filter { $0.id != post.id },
            likes: profile.likes,
            relation: profile.relation,
            permissions: profile.permissions
        )
    }

    static func replace(_ post: AloPost, in profile: AloUserProfile) -> AloUserProfile {
        return AloUserProfile(
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

    static func relation(
        _ relation: AloProfileRelation,
        canSendFriendRequest: Bool,
        in profile: AloUserProfile
    ) -> AloUserProfile {
        let permissions = AloProfilePermissions([
            "canMessage": profile.permissions.canMessage,
            "canViewContent": profile.permissions.canViewContent,
            "isPrivate": profile.permissions.isPrivate,
            "profileVisibility": profile.permissions.profileVisibility,
            "canSendFriendRequest": canSendFriendRequest
        ])
        return AloUserProfile(
            id: profile.id,
            user: profile.user,
            stats: profile.stats,
            posts: profile.posts,
            likes: profile.likes,
            relation: relation,
            permissions: permissions
        )
    }
}

private enum AloChannelProfilePatch {
    static func prepend(_ post: AloPost, to profile: AloChannelProfile) -> AloChannelProfile {
        build(
            from: profile,
            posts: [post] + profile.posts.filter { $0.id != post.id }
        )
    }

    static func replace(_ post: AloPost, in profile: AloChannelProfile) -> AloChannelProfile {
        build(
            from: profile,
            posts: profile.posts.map { $0.id == post.id ? post : $0 }
        )
    }

    static func remove(_ postId: Int, from profile: AloChannelProfile) -> AloChannelProfile {
        let containedPost = profile.posts.contains { $0.id == postId }
        return build(
            from: profile,
            posts: profile.posts.filter { $0.id != postId },
            postsCount: containedPost ? max(0, profile.postsCount - 1) : profile.postsCount
        )
    }

    static func subscribers(_ count: Int, in profile: AloChannelProfile) -> AloChannelProfile {
        AloChannelProfile(
            id: profile.id,
            name: profile.name,
            username: profile.username,
            description: profile.description,
            avatarUrl: profile.avatarUrl,
            coverImageUrl: profile.coverImageUrl,
            verified: profile.verified,
            subscribersCount: max(0, count),
            postsCount: profile.postsCount,
            posts: profile.posts,
            canManage: profile.canManage,
            isOwner: profile.isOwner,
            commentsEnabled: profile.commentsEnabled,
            signMessages: profile.signMessages,
            showAuthorProfiles: profile.showAuthorProfiles,
            discussionRoomId: profile.discussionRoomId
        )
    }

    static func management(
        _ delta: AloChannelManagementDelta,
        canManage: Bool,
        in profile: AloChannelProfile
    ) -> AloChannelProfile {
        let settings = delta.settings
        return AloChannelProfile(
            id: profile.id,
            name: profile.name,
            username: profile.username,
            description: profile.description,
            avatarUrl: profile.avatarUrl,
            coverImageUrl: profile.coverImageUrl,
            verified: profile.verified,
            subscribersCount: profile.subscribersCount,
            postsCount: profile.postsCount,
            posts: profile.posts,
            canManage: canManage,
            isOwner: profile.isOwner,
            commentsEnabled: settings?.commentsEnabled ?? profile.commentsEnabled,
            signMessages: settings?.signMessages ?? profile.signMessages,
            showAuthorProfiles: settings?.showAuthorProfiles ?? profile.showAuthorProfiles,
            discussionRoomId: settings == nil
                ? profile.discussionRoomId
                : settings?.discussionRoomId
        )
    }

    private static func build(
        from profile: AloChannelProfile,
        posts: [AloPost],
        postsCount: Int? = nil
    ) -> AloChannelProfile {
        AloChannelProfile(
            id: profile.id,
            name: profile.name,
            username: profile.username,
            description: profile.description,
            avatarUrl: profile.avatarUrl,
            coverImageUrl: profile.coverImageUrl,
            verified: profile.verified,
            subscribersCount: profile.subscribersCount,
            postsCount: max(postsCount ?? profile.postsCount, posts.count),
            posts: posts,
            canManage: profile.canManage,
            isOwner: profile.isOwner,
            commentsEnabled: profile.commentsEnabled,
            signMessages: profile.signMessages,
            showAuthorProfiles: profile.showAuthorProfiles,
            discussionRoomId: profile.discussionRoomId
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

    static func upsertChannel(
        _ profile: AloChannelProfile,
        isNew: Bool,
        in data: AloBootstrapData
    ) -> AloBootstrapData {
        let summary = AloEntitySummary(
            id: profile.id,
            name: profile.name,
            username: profile.username,
            avatarUrl: profile.avatarUrl,
            verified: profile.verified,
            isChannel: true
        )
        let existing = data.searchChannels.contains { $0.id == profile.id }
        let channels = isNew || !existing
            ? [summary] + data.searchChannels.filter { $0.id != profile.id }
            : data.searchChannels.map { $0.id == profile.id ? summary : $0 }
        return build(
            from: data,
            feedPopular: data.feedPopular,
            feedSubscriptions: data.feedSubscriptions,
            profilePosts: data.profilePosts,
            searchChannels: channels
        )
    }

    static func removeChannel(_ channelId: Int, from data: AloBootstrapData) -> AloBootstrapData {
        let keepPost: (AloPost) -> Bool = {
            !($0.author.isChannel && $0.author.id == channelId)
        }
        return build(
            from: data,
            feedPopular: data.feedPopular.filter(keepPost),
            feedSubscriptions: data.feedSubscriptions.filter(keepPost),
            profilePosts: data.profilePosts.filter(keepPost),
            searchChannels: data.searchChannels.filter { $0.id != channelId }
        )
    }

    static func upsertGroup(
        _ room: [String: Any],
        isNew: Bool,
        in data: AloBootstrapData
    ) -> AloBootstrapData {
        let roomId = room.int("id")
        let peerId = room.int("peerId")
        guard roomId > 0, peerId > 0 else { return data }
        let existing = data.conversations.first {
            $0.kind == "group" && $0.roomId == roomId
        }
        let policy = room.object("policy")
        let isChannel = policy.string("kind") == "channel" || existing?.peer.entityType == "channel"
        let peer = AloConversationPeer(
            id: peerId,
            name: room.string("title").ifBlank(existing?.peer.name ?? (isChannel ? "Канал" : "Групповой чат")),
            username: policy.string("username").ifBlank(existing?.peer.username ?? ""),
            avatarUrl: room.string("avatarEmoji").ifBlank(existing?.peer.avatarUrl ?? ""),
            verified: existing?.peer.verified ?? false,
            online: false,
            lastSeenAt: existing?.peer.lastSeenAt ?? "",
            isTyping: false,
            entityType: isChannel ? "channel" : "group"
        )
        let summary = AloConversationSummary(
            peerId: peerId,
            kind: "group",
            roomId: roomId,
            memberCount: max(room.int("memberCount"), existing?.memberCount ?? 0),
            lastAt: existing?.lastAt ?? "",
            lastBody: existing?.lastBody ?? "",
            peer: peer
        )
        let hasExisting = existing != nil
        let conversations = isNew || !hasExisting
            ? [summary] + data.conversations.filter { $0.roomId != roomId }
            : data.conversations.map {
                $0.kind == "group" && $0.roomId == roomId ? summary : $0
            }
        return build(
            from: data,
            feedPopular: data.feedPopular,
            feedSubscriptions: data.feedSubscriptions,
            profilePosts: data.profilePosts,
            conversations: conversations
        )
    }

    static func removeGroup(_ roomId: Int, from data: AloBootstrapData) -> AloBootstrapData {
        build(
            from: data,
            feedPopular: data.feedPopular,
            feedSubscriptions: data.feedSubscriptions,
            profilePosts: data.profilePosts,
            conversations: data.conversations.filter {
                !($0.kind == "group" && $0.roomId == roomId)
            }
        )
    }

    static func updateGroupMemberCount(
        _ roomId: Int,
        memberCount: Int,
        in data: AloBootstrapData
    ) -> AloBootstrapData {
        let conversations = data.conversations.map { summary in
            guard summary.kind == "group", summary.roomId == roomId else { return summary }
            return AloConversationSummary(
                peerId: summary.peerId,
                kind: summary.kind,
                roomId: summary.roomId,
                memberCount: max(0, memberCount),
                lastAt: summary.lastAt,
                lastBody: summary.lastBody,
                peer: summary.peer
            )
        }
        return build(
            from: data,
            feedPopular: data.feedPopular,
            feedSubscriptions: data.feedSubscriptions,
            profilePosts: data.profilePosts,
            conversations: conversations
        )
    }

    static func updateRelation(
        userId: Int,
        relation: AloProfileRelation,
        stats: AloProfileStats,
        in data: AloBootstrapData
    ) -> AloBootstrapData {
        let users = data.searchUsers.map { user in
            guard user.id == userId else { return user }
            return AloEntitySummary(
                id: user.id,
                name: user.name,
                username: user.username,
                avatarUrl: user.avatarUrl,
                verified: user.verified,
                isChannel: user.isChannel,
                relation: relation
            )
        }
        return build(
            from: data,
            feedPopular: data.feedPopular,
            feedSubscriptions: data.feedSubscriptions,
            profilePosts: data.profilePosts,
            searchUsers: users,
            profileStats: stats
        )
    }

    private static func build(
        from data: AloBootstrapData,
        feedPopular: [AloPost],
        feedSubscriptions: [AloPost],
        profilePosts: [AloPost],
        searchUsers: [AloEntitySummary]? = nil,
        searchChannels: [AloEntitySummary]? = nil,
        conversations: [AloConversationSummary]? = nil,
        profileStats: AloProfileStats? = nil
    ) -> AloBootstrapData {
        AloBootstrapData(
            me: data.me,
            feedPopular: feedPopular,
            feedSubscriptions: feedSubscriptions,
            notifications: data.notifications,
            notificationSettings: data.notificationSettings,
            searchUsers: searchUsers ?? data.searchUsers,
            searchChannels: searchChannels ?? data.searchChannels,
            profileStats: profileStats ?? data.profileStats,
            profilePosts: profilePosts,
            privacySettings: data.privacySettings,
            conversations: conversations ?? data.conversations,
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
