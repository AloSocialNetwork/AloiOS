import Foundation
import Testing
@testable import AloiOS

/// Dedicated URLSession interception; no server, credentials or account writes.
private final class FeedURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, [String: Any], Double))?
    private static var requests = [URLRequest]()
    private let stateLock = NSLock()
    private var stopped = false

    static func install(_ value: @escaping (URLRequest) -> (Int, [String: Any], Double)) {
        lock.lock(); defer { lock.unlock() }
        handler = value; requests = []
    }
    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }; return requests.count
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let result = Self.handler?(request) ?? (400, [:], 0)
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + result.2) { [self] in
            stateLock.lock(); let cancelled = stopped; stateLock.unlock()
            guard !cancelled else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: result.0,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: result.1)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

@Suite(.serialized) @MainActor
struct AloFeedInteractionTests {
    private func postJSON(likes: Int = 10, liked: Bool = false, reposts: Int = 0, reposted: Bool = false) -> [String: Any] {
        ["id": 50, "creatorId": 7, "body": "Тестовый пост", "likeCount": likes,
         "viewerLiked": liked, "repostCount": reposts, "viewerReposted": reposted, "commentCount": 0,
         "media": [["type": "image", "url": "/photo.jpg"]],
         "author": ["id": 7, "name": "Автор"], "createdAt": "2026-10-12T10:00:00Z"]
    }
    private func bootstrap(_ posts: [[String: Any]], user: Int = 1) -> AloBootstrapData {
        AloBootstrapData(["data": ["me": ["id": user, "name": "Тест"],
            "feed": ["popular": posts, "subs": posts], "profile": ["posts": posts]]])
    }
    private func model(handler: @escaping (URLRequest) -> (Int, [String: Any], Double)) -> AloAppModel {
        FeedURLProtocol.install(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedURLProtocol.self]
        let app = AloAppModel(api: AloAPIClient(baseURLs: [URL(string: "http://feed-unit-test.invalid/")!], configuration: config))
        app.bootstrap = bootstrap([postJSON()]); app.phase = .app
        return app
    }
    private func wait(until predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for intercepted request")
    }

    @Test func likesReactBeforeNetworkAndDoubleTapDoesNotSendTwice() async throws {
        let response = postJSON(likes: 11, liked: true)
        let app = model { _ in (200, ["post": response], 0.1) }
        let post = app.bootstrap!.feedPopular[0]
        app.toggleLike(post); app.toggleLike(post)
        #expect(app.bootstrap?.feedPopular[0].likeCount == 11)
        #expect(app.bootstrap?.feedSubscriptions[0].viewerLiked == true)
        #expect(app.bootstrap?.profilePosts[0].viewerLiked == true)
        try await wait { app.pendingLikePostIds.isEmpty }
        #expect(FeedURLProtocol.requestCount == 1)
    }

    @Test func errorRollsBackWithoutLosingMedia() async throws {
        let app = model { _ in (400, ["error": "Не удалось", "code": "TEST_FAILURE"], 0.05) }
        let original = app.bootstrap!.feedPopular[0]
        app.toggleLike(original)
        #expect(app.bootstrap?.feedPopular[0].viewerLiked == true)
        try await wait { app.pendingLikePostIds.isEmpty }
        #expect(app.bootstrap?.feedPopular[0] == original)
        #expect(!app.errorMessage.isEmpty)
    }

    @Test func concurrentLikeAndRepostDoNotUndoEachOther() async throws {
        let liked = postJSON(likes: 11, liked: true)
        let reposted = postJSON(reposts: 1, reposted: true)
        let app = model { request in
            request.url!.path.hasSuffix("/like") ? (200, ["post": liked], 0.05) : (200, ["post": reposted], 0.1)
        }
        let post = app.bootstrap!.feedPopular[0]
        app.toggleLike(post); app.toggleRepost(post); app.toggleRepost(post)
        #expect(app.bootstrap?.feedPopular[0].likeCount == 11)
        #expect(app.bootstrap?.feedPopular[0].repostCount == 1)
        try await wait { app.pendingLikePostIds.isEmpty && app.pendingRepostPostIds.isEmpty }
        #expect(app.bootstrap?.feedPopular[0].viewerLiked == true)
        #expect(app.bootstrap?.feedPopular[0].viewerReposted == true)
        #expect(FeedURLProtocol.requestCount == 2)
    }

    @Test func aLateResponseCannotPatchAnotherAccount() async throws {
        let response = postJSON(likes: 11, liked: true)
        let app = model { _ in (200, ["post": response], 0.1) }
        app.toggleLike(app.bootstrap!.feedPopular[0])
        app.bootstrap = bootstrap([postJSON()], user: 2)
        try await wait { app.pendingLikePostIds.isEmpty }
        #expect(app.bootstrap?.me.id == 2)
        #expect(app.bootstrap?.feedPopular[0].viewerLiked == false)
    }

    @Test func switchingCommentsDiscardsThePreviousLoad() async throws {
        let app = model { request in
            let second = request.url!.path.contains("/51/")
            return (200, ["comments": [["id": second ? 2 : 1, "body": second ? "Второй" : "Первый"]]], second ? 0.02 : 0.15)
        }
        var second = postJSON(); second["id"] = 51
        app.openComments(for: app.bootstrap!.feedPopular[0])
        await Task.yield()
        app.openComments(for: AloPost(second))
        try await wait { !app.commentsLoading }
        try await Task.sleep(for: .milliseconds(180))
        #expect(app.commentsPost?.id == 51)
        #expect(app.comments.map(\.body) == ["Второй"])
        app.closeComments()
        #expect(!app.commentsLoading && app.comments.isEmpty)
    }

    @Test func sendPreservesNewTypingAndRejectsDoubleSubmission() async throws {
        let app = model { request in
            if request.httpMethod == "GET" { return (200, ["comments": []], 0) }
            return (200, ["comment": ["id": 100, "body": "Первый текст", "author": ["id": 1]],
                          "post": ["id": 50, "commentCount": 1]], 0.1)
        }
        app.openComments(for: app.bootstrap!.feedPopular[0])
        try await wait { !app.commentsLoading }
        app.commentText = "Первый текст"
        app.createComment(); app.createComment()
        #expect(app.isSendingComment)
        app.commentText = "Новый черновик"
        try await wait { !app.isSendingComment }
        #expect(app.commentText == "Новый черновик")
        #expect(app.comments.map(\.id) == [100])
        #expect(app.bootstrap?.feedPopular[0].commentCount == 1)
        #expect(app.bootstrap?.feedPopular[0].body == "Тестовый пост")
        #expect(FeedURLProtocol.requestCount == 2)
    }

    @Test func closedCommentsCannotReopenFromSendCompletion() async throws {
        let app = model { request in
            request.httpMethod == "GET" ? (200, ["comments": []], 0) : (200, ["comment": ["id": 100],
                "post": ["id": 50, "commentCount": 1]], 0.08)
        }
        app.openComments(for: app.bootstrap!.feedPopular[0])
        try await wait { !app.commentsLoading }
        app.commentText = "Привет"; app.createComment(); app.closeComments()
        try await Task.sleep(for: .milliseconds(160))
        #expect(app.commentsPost == nil && app.comments.isEmpty && !app.isSendingComment)
        #expect(app.bootstrap?.feedPopular[0].commentCount == 1)
    }

    @Test func failedCommentRetainsDraftAndShowsInlineError() async throws {
        let app = model { request in
            request.httpMethod == "GET" ? (200, ["comments": []], 0) : (400, ["error": "Сбой отправки"], 0.02)
        }
        app.openComments(for: app.bootstrap!.feedPopular[0])
        try await wait { !app.commentsLoading }
        app.commentText = "Не потерять"; app.createComment()
        try await wait { !app.isSendingComment }
        #expect(app.commentText == "Не потерять" && app.comments.isEmpty)
        #expect(!app.commentsError.isEmpty)
        #expect(app.errorMessage.isEmpty)
    }

    @Test func engagementCopiesPreserveIdentityAndClampCounts() {
        let post = AloPost(postJSON())
        let edited = post.withEngagement(likeCount: -10, viewerLiked: true)
        #expect(edited.id == post.id && edited.media == post.media && edited.body == post.body)
        #expect(edited.likeCount == 0 && edited.viewerLiked && edited.commentCount == post.commentCount)
    }

    @Test func commentLikeIsImmediateDeduplicatedAndRollsBackOnError() async throws {
        let app = model { request in
            request.httpMethod == "GET" ? (200, ["comments": [["id": 100, "body": "Привет", "likeCount": 2]]], 0)
                : (400, ["error": "Сбой лайка"], 0.05)
        }
        app.openComments(for: app.bootstrap!.feedPopular[0])
        try await wait { !app.commentsLoading }
        let comment = try #require(app.comments.first)
        app.toggleCommentLike(comment); app.toggleCommentLike(comment)
        #expect(app.comments[0].likeCount == 3 && app.comments[0].viewerLiked)
        try await wait { app.pendingCommentLikeIds.isEmpty }
        #expect(app.comments[0] == comment)
        #expect(!app.commentsError.isEmpty && FeedURLProtocol.requestCount == 2)
    }

    @Test func reloadDoesNotKeepCommentsRemovedOnServer() async throws {
        let app = model { _ in (200, ["comments": []], 0) }
        app.openComments(for: app.bootstrap!.feedPopular[0])
        try await wait { !app.commentsLoading }
        app.comments = [AloPostComment(["id": 101, "body": "Уже удалён на сервере"])]
        await app.loadComments(for: 50)
        #expect(app.comments.isEmpty)
    }

    @Test func relativeTimestampsAreReadableAndAcceptFractionalISO() {
        let now = ISO8601DateFormatter().date(from: "2026-10-12T10:12:00Z")!
        #expect(AloPostTimestamp.string("2026-10-12T10:00:00.000Z", now: now) == "12 мин")
        #expect(AloPostTimestamp.string("2026-10-12T11:00:00Z", now: now) == "сейчас")
        #expect(AloPostTimestamp.string("", now: now).isEmpty)
    }
}
