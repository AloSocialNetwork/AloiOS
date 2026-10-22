import Foundation
import Network

enum AloMediaDownloadIntent: Sendable { case automatic, userInitiated }
enum AloMediaNetwork: Sendable { case wifi, cellular, constrained, offline }
enum AloMediaCacheScope: String, Codable, CaseIterable, Sendable {
    case privateChats, groups, channels, stories, previews

    var retention: TimeInterval {
        switch self {
        case .privateChats: return .infinity
        case .groups: return 31 * 86_400
        case .channels: return 7 * 86_400
        case .stories: return 2 * 86_400
        case .previews: return 7 * 86_400
        }
    }
}

/// The low/medium/high thresholds and voice exception follow Telegram iOS
/// MediaAutoDownloadSettings (see docs/TELEGRAM_MEDIA_CACHE_2026-10-19.md).
enum AloMediaDownloadPreset: String, Codable, CaseIterable, Sendable {
    case off, low, medium, high
    var title: String {
        switch self {
        case .off: return "Выключена"
        case .low: return "Мало данных"
        case .medium: return "Средний расход"
        case .high: return "Высокий расход"
        }
    }

    func permits(type: String, size: Int64?) -> Bool {
        guard self != .off else { return false }
        let mb: Int64 = 1_024 * 1_024
        let type = type.lowercased()
        let voice = type == "voice" || type == "audio" || type == "audio/ogg"
        let photo = type == "image" || type.hasPrefix("image/")
        let video = ["video", "circle", "video_circle", "video-circle", "gif"].contains(type) || type.hasPrefix("video/")
        let limit: Int64
        if voice { limit = self == .high ? 3 * mb : 2 * mb }
        else if photo { limit = mb }
        else if self == .low { return false }
        else if video { limit = self == .high ? 10 * mb : 5 * mb / 2 }
        else { limit = self == .high ? 3 * mb : mb }
        // Unlike Telegram photos, our encrypted originals have no separate
        // server-side small representation. Unknown originals require a tap.
        guard let size, size > 0 else { return false }
        return size <= limit
    }
}

struct AloMediaCacheSettings: Codable, Equatable, Sendable {
    var wifi: AloMediaDownloadPreset = .high
    var cellular: AloMediaDownloadPreset = .medium
    // A finite default is intentional: the request explicitly excludes an
    // unbounded cache. 2 GB is one of Telegram's cache-size choices.
    var maximumBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let sizeChoicesGB = [1, 2, 5, 8, 16]

    func permits(type: String, size: Int64?, network: AloMediaNetwork, intent: AloMediaDownloadIntent) -> Bool {
        if network == .offline { return false }
        if intent == .userInitiated { return true }
        switch network {
        case .wifi: return wifi.permits(type: type, size: size)
        case .cellular: return cellular.permits(type: type, size: size)
        case .constrained, .offline: return false
        }
    }

    static var current: Self {
        guard let data = UserDefaults.standard.data(forKey: "alo.media-cache.settings.v1"),
              let settings = try? JSONDecoder().decode(Self.self, from: data),
              settings.maximumBytes >= 1_024 * 1_024 else { return Self() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "alo.media-cache.settings.v1")
        }
        AloMediaDiskCache.shared.scheduleMaintenance()
    }
}

final class AloMediaNetworkMonitor: @unchecked Sendable {
    static let shared = AloMediaNetworkMonitor()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var value: AloMediaNetwork = .cellular
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let next: AloMediaNetwork = path.status != .satisfied ? .offline
                : path.isConstrained ? .constrained : path.usesInterfaceType(.wifi) ? .wifi : .cellular
            guard let self else { return }
            lock.lock(); value = next; lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "alo.media-network", qos: .utility))
    }
    var network: AloMediaNetwork {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// A releasable resource pin, also owned by an AVAsset's loader. Drafts and
/// outbox files are never registered with the evictable cache in the first place.
final class AloMediaCacheLease: @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (() -> Void)?
    init(_ onRelease: @escaping () -> Void) { self.onRelease = onRelease }
    func release() {
        lock.lock(); let action = onRelease; onRelease = nil; lock.unlock()
        action?()
    }
    deinit { release() }
}

/// Only downloaded, reproducible resources are owned here. Metadata/history,
/// cryptographic keys, drafts, pending uploads and exported files are not cache.
final class AloMediaDiskCache: @unchecked Sendable {
    static let shared = AloMediaDiskCache()
    struct Record: Codable, Sendable {
        var path: String
        var size: Int64
        var accessedAt: Date
        var scope: AloMediaCacheScope
    }
    struct Usage: Sendable {
        var bytes: Int64 = 0
        var count = 0
    }
    private let queue = DispatchQueue(label: "alo.media-disk-cache", qos: .utility)
    private let pinLock = NSLock()
    private var pins: [String: Int] = [:]
    private var records: [String: Record] = [:] // queue-confined
    private let indexURL: URL
    private let allowedRoots: [URL]
    private var loaded = false
    private var lastMaintenance = Date.distantPast
    private var persistenceScheduled = false

    init(root: URL? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? caches
        allowedRoots = root.map { [$0.standardizedFileURL] } ?? [
            caches.appendingPathComponent("AloE2EEMedia/encrypted", isDirectory: true),
            support.appendingPathComponent("AloOfflineSecure", isDirectory: true)
        ]
        indexURL = (root ?? caches.appendingPathComponent("AloMediaCache", isDirectory: true))
            .appendingPathComponent("index-v1.json")
    }

    private func isManaged(_ url: URL) -> Bool {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let name = canonical.lastPathComponent
        guard !name.hasPrefix("draft-"), !name.hasPrefix("."), name != indexURL.lastPathComponent else { return false }
        return allowedRoots.contains { root in
            let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard canonical.path.hasPrefix(prefix) else { return false }
            // The offline root also owns irreplaceable chat metadata. Only its
            // remote image files can ever participate in media eviction.
            return root.lastPathComponent != "AloOfflineSecure" || name.hasPrefix("remote-image-")
        }
    }

    func keep(_ url: URL) -> AloMediaCacheLease {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        pinLock.lock(); pins[path, default: 0] += 1; pinLock.unlock()
        return AloMediaCacheLease { [weak self] in
            guard let self else { return }
            pinLock.lock()
            if let count = pins[path], count > 1 { pins[path] = count - 1 } else { pins[path] = nil }
            pinLock.unlock()
            queue.async { [self] in
                if self.loaded, self.records.values.reduce(Int64(0), { $0 + $1.size }) > AloMediaCacheSettings.current.maximumBytes {
                    self.maintain(settings: .current, now: Date())
                }
            }
        }
    }

    func record(_ url: URL, scope: AloMediaCacheScope) {
        queue.async { [self] in
            loadIfNeeded()
            guard isManaged(url),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            records[path] = Record(path: path, size: Int64(size), accessedAt: Date(), scope: scope)
            persist()
            let settings = AloMediaCacheSettings.current
            if records.values.reduce(Int64(0), { $0 + $1.size }) > settings.maximumBytes || Date().timeIntervalSince(lastMaintenance) > 10 {
                maintain(settings: settings, now: Date())
            }
        }
    }

    func touch(_ url: URL) {
        queue.async { [self] in
            loadIfNeeded()
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard let record = records[path], Date().timeIntervalSince(record.accessedAt) >= 10 else { return }
            records[path]?.accessedAt = Date()
            // Playback asks for many ranges. Batch access-time writes rather
            // than rewriting the whole index for every visible resource.
            if !persistenceScheduled {
                persistenceScheduled = true
                queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self else { return }
                    self.persistenceScheduled = false; self.persist()
                }
            }
        }
    }

    func scheduleMaintenance() {
        queue.async { [self] in loadIfNeeded(); maintain(settings: .current, now: Date()) }
    }

    func usage() async -> Usage {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                loadIfNeeded()
                records = records.filter { FileManager.default.fileExists(atPath: $0.key) }
                continuation.resume(returning: Usage(bytes: records.values.reduce(0) { $0 + $1.size }, count: records.count))
            }
        }
    }

    @discardableResult
    func clean(settings: AloMediaCacheSettings, now: Date = Date(), all: Bool = false) async -> Usage {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                loadIfNeeded(); maintain(settings: settings, now: now, all: all)
                continuation.resume(returning: Usage(bytes: records.values.reduce(0) { $0 + $1.size }, count: records.count))
            }
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }; loaded = true
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([Record].self, from: data) {
            for entry in saved where isManaged(URL(fileURLWithPath: entry.path)) { records[entry.path] = entry }
        }
        // Index existing cache files too; a lost index must not make old files
        // invisible to the quota. Never recursively delete a resource directory.
        for root in allowedRoots {
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard isManaged(url), let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                if records[path] == nil { records[path] = Record(path: path, size: Int64(values.fileSize ?? 0),
                    accessedAt: values.contentModificationDate ?? Date(), scope: .previews) }
            }
        }
    }

    private func maintain(settings: AloMediaCacheSettings, now: Date, all: Bool = false) {
        lastMaintenance = now
        records = records.filter { FileManager.default.fileExists(atPath: $0.key) }
        var total = records.values.reduce(Int64(0)) { $0 + $1.size }
        let oldestFirst = records.values.sorted(by: { $0.accessedAt < $1.accessedAt })
        // Expired copies first, then LRU quota eviction. Reversing this order
        // would unnecessarily discard private files before expiring a channel.
        for record in oldestFirst.filter({ all || now.timeIntervalSince($0.accessedAt) > $0.scope.retention })
            + oldestFirst {
            guard records[record.path] != nil,
                  all || total > settings.maximumBytes || now.timeIntervalSince(record.accessedAt) > record.scope.retention else { continue }
            let url = URL(fileURLWithPath: record.path)
            guard isManaged(url) else { records[record.path] = nil; continue }
            pinLock.lock()
            if pins[record.path, default: 0] == 0 {
                do {
                    try FileManager.default.removeItem(at: url)
                    records[record.path] = nil; total -= record.size
                } catch { /* Keep accounting for a file the OS did not remove. */ }
            }
            pinLock.unlock()
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Array(records.values)) else { return }
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = indexURL
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// Two transfers, deduplicated by resource. User taps precede automatic work;
/// an offscreen row cancels only its own demand, never another visible user.
actor AloMediaDownloadQueue {
    static let shared = AloMediaDownloadQueue()
    private struct Request {
        let id: UUID
        let operation: () async throws -> Void
        var waiters: [UUID: CheckedContinuation<Void, Error>]
    }
    private var requests: [String: Request] = [:]
    private var order: [String] = []
    private var running: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private let concurrency: Int
    init(concurrency: Int = 2) { self.concurrency = max(1, concurrency) }
    #if DEBUG
    var demandCount: Int { requests.values.reduce(0) { $0 + $1.waiters.count } }
    #endif

    func fetch(key: String, intent: AloMediaDownloadIntent, operation: @escaping () async throws -> Void) async throws {
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if requests[key] != nil {
                    requests[key]?.waiters[waiter] = continuation
                    if intent == .userInitiated, running[key] == nil {
                        order.removeAll { $0 == key }; order.insert(key, at: 0)
                    }
                }
                else {
                    requests[key] = Request(id: UUID(), operation: operation, waiters: [waiter: continuation])
                    if intent == .userInitiated { order.insert(key, at: 0) } else { order.append(key) }
                }
                startNext()
            }
        } onCancel: { Task { await self.cancel(key: key, waiter: waiter) } }
    }

    private func cancel(key: String, waiter: UUID) {
        guard let continuation = requests[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if requests[key]?.waiters.isEmpty == true {
            requests[key] = nil; order.removeAll { $0 == key }
            running[key]?.task.cancel()
            startNext()
        }
    }

    private func startNext() {
        while running.count < concurrency, let index = order.firstIndex(where: { running[$0] == nil }) {
            let key = order.remove(at: index)
            guard let request = requests[key] else { continue }
            let task = Task { [weak self] in
                let result: Result<Void, Error>
                do { try Task.checkCancellation(); try await request.operation(); result = .success(()) }
                catch { result = .failure(error) }
                await self?.finish(key: key, id: request.id, result: result)
            }
            running[key] = (request.id, task)
        }
    }

    private func finish(key: String, id: UUID, result: Result<Void, Error>) {
        guard running[key]?.id == id else { return }
        running[key] = nil
        if let request = requests[key], request.id == id {
            requests[key] = nil
            request.waiters.values.forEach { $0.resume(with: result) }
        }
        startNext()
    }
}

/// URLSession writes directly to a temporary file, never a giant Data buffer.
/// Stop as soon as either declared or received bytes exceed the admission cap.
final class AloBoundedDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximumBytes: Int64
    private let lock = NSLock()
    private var exceeded = false
    init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }
    var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            lock.lock(); exceeded = true; lock.unlock()
            downloadTask.cancel()
        }
    }
}

/// Reserve transient disk space across concurrent transfers as well as their
/// encrypted replacement. The OS and unsent attachments retain a safety margin.
final class AloMediaTransferBudget: @unchecked Sendable {
    static let shared = AloMediaTransferBudget()
    private let lock = NSLock()
    private var reserved: Int64 = 0
    private let freeBytes: () -> Int64
    init(freeBytes: @escaping () -> Int64 = {
        (try? FileManager.default.attributesOfFileSystem(forPath: NSTemporaryDirectory())[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }) { self.freeBytes = freeBytes }

    func reserve(bytes: Int64) throws -> AloMediaCacheLease {
        try reserveDownload(expectedSize: bytes, maximumBytes: bytes, copies: 1).lease
    }

    func reserveDownload(expectedSize: Int64?, maximumBytes: Int64, copies: Int64) throws -> (maximumBytes: Int64, lease: AloMediaCacheLease) {
        lock.lock(); defer { lock.unlock() }
        guard copies > 0 else { throw AloSecureMediaError.insufficientStorage }
        let available = max(0, freeBytes() - reserved - 256 * 1_024 * 1_024)
        let limit = min(maximumBytes, available / copies)
        guard limit > 0, expectedSize.map({ $0 > 0 && $0 <= limit }) ?? true else {
            throw AloSecureMediaError.insufficientStorage
        }
        // An unknown-size old voice must not require several GB free just
        // because the user's cache limit is large. Bound its transfer by space
        // actually available; a larger response is cancelled by the delegate.
        let bytes = (expectedSize ?? limit) * copies
        reserved += bytes
        let lease = AloMediaCacheLease { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.reserved -= bytes; self.lock.unlock()
        }
        return (expectedSize ?? limit, lease)
    }
}
