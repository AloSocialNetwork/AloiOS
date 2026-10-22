import Combine
import Foundation

struct AloPublicationJob: Identifiable {
    enum Kind: String { case post, story }
    enum Status: String { case queued, uploading, publishing, failed }
    let id: String
    let kind: Kind
    let body: String
    var attachments: [AloLocalAttachment]
    var uploaded = [AloMessageAttachment]()
    var draftMedia = [AloMediaItem]()
    var draftId: Int?
    var lifetimeHours = 24
    var audience = AloStoryAudience.everyone
    var audienceUserIds = [Int]()
    var status = Status.queued
    var progress = 0.0
    var error = ""
    var retryable = true
    var missingAttachments = false
    var isDurable = false
    var captchaToken: String?

    var label: String {
        switch status {
        case .queued: return "Ожидает отправки"
        case .uploading: return "Загрузка медиа · \(Int(progress * 100))%"
        case .publishing: return "Публикация…"
        case .failed: return error
        }
    }

    func record() -> [String: Any] {
        ["id": id, "kind": kind.rawValue, "body": body,
         "attachments": attachments.map { AloDurableAttachment.record($0, prefix: "publication") },
         "uploaded": uploaded.map { ["type": $0.type, "url": $0.url, "name": $0.name, "poster": $0.posterUrl] },
         "draftMedia": draftMedia.map(\.payload), "draftId": draftId ?? 0,
         "lifetimeHours": lifetimeHours, "audience": audience.rawValue, "audienceUserIds": audienceUserIds,
         "status": status.rawValue, "progress": progress, "error": error, "retryable": retryable,
         "missingAttachments": missingAttachments]
    }

    init(kind: Kind, body: String, attachments: [AloLocalAttachment]) {
        id = UUID().uuidString
        self.kind = kind
        self.body = body
        self.attachments = attachments
    }

    init?(record: [String: Any], owner: Int) {
        guard UUID(uuidString: record.string("id")) != nil, let kind = Kind(rawValue: record.string("kind")) else { return nil }
        id = record.string("id")
        self.kind = kind
        body = record.string("body")
        let files = record.array("attachments")
        attachments = files.compactMap { AloDurableAttachment.restore($0, owner: owner) }
        uploaded = record.array("uploaded").map(AloMessageAttachment.init)
        draftMedia = record.array("draftMedia").map(AloMediaItem.init)
        draftId = record.int("draftId") > 0 ? record.int("draftId") : nil
        lifetimeHours = record.int("lifetimeHours")
        audience = AloStoryAudience(rawValue: record.string("audience")) ?? .everyone
        audienceUserIds = record["audienceUserIds"] as? [Int] ?? []
        status = record.string("status") == "failed" ? .failed : .queued
        error = record.string("error")
        retryable = record.bool("retryable")
        isDurable = true
        missingAttachments = record.bool("missingAttachments") || attachments.count != files.count || uploaded.count > attachments.count
        if missingAttachments {
            status = .failed
            retryable = false
            error = "Вложение не найдено на устройстве. Сохраните текст и создайте публикацию заново."
        }
    }
}

@MainActor
final class AloPublicationQueue: ObservableObject {
    @Published private(set) var jobs = [AloPublicationJob]()
    @Published private(set) var restorationError = ""
    private var owner = 0
    private var generation = UUID()
    private var loaded = false
    private var ready = false
    private var stagingCleared = false
    private var worker: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var write: Task<Void, Error>?
    private let api: AloAPIClient
    var onChange: (([AloPublicationJob]) -> Void)?
    var onPublished: ((Int, AloPublicationJob, AloPost?) -> Void)?
    var onFailure: ((AloPublicationJob, AloAPIError) -> Void)?

    init(api: AloAPIClient) { self.api = api }

    func activate(owner: Int) {
        guard owner > 0 else { return }
        if self.owner == owner {
            guard !restorationError.isEmpty else { return }
            generation = UUID(); loadTask?.cancel()
        } else {
            reset()
            self.owner = owner
        }
        restorationError = ""
        let generation = generation
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let store = AloSecureOutboxStore.shared
                await store.finishPendingWrites()
                return Result {
                    try (store.loadChecked(ownerUserId: owner, collection: .publications) +
                        store.loadChecked(ownerUserId: owner, collection: .publicationStaging))
                        .compactMap { AloPublicationJob(record: $0, owner: owner) }
                }
            }.value
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            guard case let .success(restored) = result else {
                restorationError = "Не удалось открыть защищённую очередь. Данные не перезаписаны."
                for index in jobs.indices { jobs[index].status = .failed; jobs[index].error = restorationError }
                onChange?(jobs)
                return
            }
            let existing = Set(jobs.map(\.id))
            var seen = existing
            jobs.insert(contentsOf: restored.filter { seen.insert($0.id).inserted }, at: 0)
            loaded = true
            persist()
            do {
                try await write?.value
                guard self.generation == generation, !Task.isCancelled else { return }
                try await AloSecureOutboxStore.shared.scheduleSave(records: [], attachments: [], ownerUserId: owner,
                    collection: .publicationStaging).value
                guard self.generation == generation, !Task.isCancelled else { return }
                stagingCleared = true
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                // Keep both copies on disk if consolidation fails. Do not send
                // before durable recovery has completed.
                for index in jobs.indices { jobs[index].status = .failed; jobs[index].error = "Не удалось сохранить очередь. Проверьте свободное место." }
                ready = true // Explicit retry can recover after storage becomes writable.
                onChange?(jobs)
                return
            }
            guard self.generation == generation, !Task.isCancelled else { return }
            ready = true
            resume()
        }
    }

    func reset() {
        generation = UUID()
        worker?.cancel(); worker = nil
        loadTask?.cancel(); loadTask = nil
        owner = 0; loaded = false; ready = false; stagingCleared = false; jobs = []; write = nil
        restorationError = ""
        onChange?(jobs)
    }

    /// The call queues the ciphertext copy before an editor can release its
    /// temporary media. The worker awaits that receipt before any HTTP request.
    @discardableResult func enqueue(_ job: AloPublicationJob) -> String {
        // A retry from an editor is the same operation, not a second post.
        if let index = jobs.firstIndex(where: { $0.kind == job.kind && $0.body == job.body &&
            $0.attachments.map(\.id) == job.attachments.map(\.id) && $0.draftMedia == job.draftMedia &&
            $0.audience == job.audience && $0.audienceUserIds == job.audienceUserIds && $0.lifetimeHours == job.lifetimeHours }) {
            jobs[index].captchaToken = job.captchaToken
            retry(id: jobs[index].id)
            return jobs[index].id
        }
        jobs.append(job)
        // Protect new attachments immediately, even while the old queue loads.
        let writes = job.attachments.map { AloSecureOutboxStore.AttachmentWrite(
            id: AloDurableAttachment.fileID($0, prefix: "publication"), attachment: $0) }
        // No partial metadata snapshot is written until activation finishes.
        write = AloSecureOutboxStore.shared.scheduleSave(records: jobs.map { $0.record() }, attachments: writes,
            ownerUserId: owner, collection: loaded ? .publications : .publicationStaging)
        let receipt = write, generation = generation
        Task { [weak self] in
            do { try await receipt?.value } catch { return }
            guard let self, self.generation == generation,
                  let index = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
            self.jobs[index].isDurable = true
            self.onChange?(self.jobs)
        }
        onChange?(jobs)
        start()
        return job.id
    }

    func retry(id: String, captchaToken: String? = nil) {
        if !restorationError.isEmpty { activate(owner: owner); return }
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.status == .failed && !$0.missingAttachments }) else { return }
        if let captchaToken { jobs[index].captchaToken = captchaToken }
        jobs[index].status = .queued; jobs[index].error = ""
        persist(); start()
    }

    func resume() {
        for index in jobs.indices where jobs[index].status == .failed && jobs[index].retryable {
            jobs[index].status = .queued; jobs[index].error = ""
        }
        persist(); start()
    }

    func remove(id: String) {
        guard let job = jobs.first(where: { $0.id == id }), job.status == .failed else { return }
        jobs.removeAll { $0.id == id }
        persist()
        AloSecureOutboxStore.shared.scheduleAttachmentRemoval(ids: job.attachments.indices.map {
            "publication-upload-\(job.id)-\($0)" }, ownerUserId: owner)
    }

    private func persist() {
        guard loaded, owner > 0 else { return }
        let writes = jobs.flatMap(\.attachments).map { AloSecureOutboxStore.AttachmentWrite(
            id: AloDurableAttachment.fileID($0, prefix: "publication"), attachment: $0) }
        write = AloSecureOutboxStore.shared.scheduleSave(records: jobs.map { $0.record() }, attachments: writes,
            ownerUserId: owner, collection: .publications)
        onChange?(jobs)
    }

    private func start() {
        guard ready, owner > 0, worker == nil else { return }
        let generation = generation
        let owner = owner
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { worker = nil } }
            while let job = jobs.first(where: { $0.status == .queued }) {
                guard self.generation == generation, !Task.isCancelled else { return }
                var current = job
                do {
                    try await write?.value
                    guard self.generation == generation, !Task.isCancelled else { return }
                    if !stagingCleared {
                        try await AloSecureOutboxStore.shared.scheduleSave(records: [], attachments: [], ownerUserId: owner,
                            collection: .publicationStaging).value
                        guard self.generation == generation, !Task.isCancelled else { return }
                        stagingCleared = true
                    }
                    guard self.generation == generation, !Task.isCancelled else { return }
                    current.isDurable = true
                    // Work only on the durable copy, not the editor's temp file.
                    let records = job.attachments.map { AloDurableAttachment.record($0, prefix: "publication") }
                    let restored = await Task.detached(priority: .utility) {
                        records.compactMap { AloDurableAttachment.restore($0, owner: owner) }
                    }.value
                    guard self.generation == generation, !Task.isCancelled else { return }
                    guard restored.count == job.attachments.count else { throw CocoaError(.fileReadNoSuchFile) }
                    current.attachments = restored
                    for index in current.uploaded.count..<current.attachments.count {
                        current.status = .uploading
                        replace(current)
                        let fileID = "publication-upload-\(job.id)-\(index)"
                        let checkpoint = AloSecureOutboxStore.shared.loadUploadCheckpoint(id: fileID, ownerUserId: owner)
                        let uploaded = try await api.uploadAttachment(current.attachments[index], purpose: "post",
                            resumeCheckpoint: checkpoint, onCheckpoint: { [weak self] checkpoint in
                                try? AloSecureOutboxStore.shared.saveUploadCheckpoint(checkpoint, id: fileID, ownerUserId: owner)
                                Task { @MainActor in
                                    guard let self, self.generation == generation,
                                          let position = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                                    self.jobs[position].progress = (Double(index) + Double(checkpoint.offset) / Double(max(1, checkpoint.total))) / Double(max(1, job.attachments.count))
                                    self.onChange?(self.jobs)
                                }
                            }, expectedOwnerId: owner)
                        guard self.generation == generation, !Task.isCancelled else { return }
                        current.uploaded.append(uploaded)
                        current.progress = Double(index + 1) / Double(max(1, current.attachments.count))
                        replace(current)
                        try await write?.value
                        guard self.generation == generation, !Task.isCancelled else { return }
                    }
                    current.status = .publishing; replace(current)
                    try await write?.value
                    guard self.generation == generation, !Task.isCancelled else { return }
                    let post: AloPost?
                    if current.kind == .post {
                        post = try await api.createPost(body: current.body, media: current.uploaded,
                            draftMedia: current.draftMedia, draftId: current.draftId,
                            captchaToken: current.captchaToken, clientOperationId: current.id, expectedOwnerId: owner)
                    } else {
                        _ = try await api.createStory(body: current.body, media: current.uploaded,
                            lifetimeHours: current.lifetimeHours, audience: current.audience,
                            audienceUserIds: current.audienceUserIds, clientOperationId: current.id, expectedOwnerId: owner)
                        post = nil
                    }
                    guard self.generation == generation, !Task.isCancelled else { return }
                    jobs.removeAll { $0.id == job.id }
                    persist()
                    // Save ACK/removal before removing media. A lost ACK replays
                    // the stable server operation instead of creating a duplicate.
                    try await write?.value
                    guard self.generation == generation, !Task.isCancelled else { return }
                    onPublished?(owner, current, post)
                    // Source files are pruned against *all* remaining jobs by
                    // the store, so sharing an attachment cannot break a peer job.
                    AloSecureOutboxStore.shared.scheduleAttachmentRemoval(ids: current.attachments.indices.map {
                            "publication-upload-\(current.id)-\($0)" }, drafts: job.attachments, ownerUserId: owner)
                } catch {
                    guard self.generation == generation, !Task.isCancelled else { return }
                    if !jobs.contains(where: { $0.id == job.id }) { jobs.append(current) }
                    if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                        jobs[index].status = .failed
                        jobs[index].error = (error as? AloAPIError)?.message ?? "Не удалось отправить. Проверьте соединение и свободное место."
                        jobs[index].retryable = (error as? AloAPIError).map { $0.status >= 500 || $0.status == 0 || $0.status == 408 || $0.status == 429 } ?? (error is URLError)
                        persist()
                        if let error = error as? AloAPIError { onFailure?(jobs[index], error) }
                    }
                }
            }
        }
    }

    private func replace(_ job: AloPublicationJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job; persist()
    }
}
