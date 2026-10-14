import AVFoundation
import UIKit

/// One short-lived asset probe at a time, deduplicated and bounded in memory.
/// Idle chat rows never own AVPlayers. No plaintext thumbnail is written to disk.
actor AloMediaPreviewCache {
    static let shared = AloMediaPreviewCache()

    struct Preview {
        let duration: Double?
        let image: UIImage?
    }

    private final class Entry: NSObject {
        let preview: Preview
        let expiresAt: Date?
        init(_ preview: Preview, expiresAt: Date? = nil) {
            self.preview = preview
            self.expiresAt = expiresAt
        }
    }

    private let cache = NSCache<NSString, Entry>()
    private struct Request {
        let id: UUID
        let url: URL
        let video: Bool
        var waiters: [UUID: CheckedContinuation<Preview, Never>]
    }
    private var pending: [String: Request] = [:]
    private var queue: [String] = []
    private var running: (key: String, id: UUID, task: Task<Void, Never>)?
    private let loader: (URL, Bool) async -> Preview

    #if DEBUG
    var pendingDemandCount: Int { pending.values.reduce(0) { $0 + $1.waiters.count } }
    #endif

    init(loader: ((URL, Bool) async -> Preview)? = nil) {
        self.loader = loader ?? Self.loadPreview
        cache.countLimit = 64
        cache.totalCostLimit = 12 * 1_024 * 1_024
    }

    func preview(url: URL, video: Bool) async -> Preview {
        await preview(url: url, video: video, identity: url.absoluteString)
    }

    /// New video drafts are file-backed. Retain a bounded compatibility path
    /// for older in-memory drafts, with lifetime owned by the caller's task.
    func preview(localVideo: AloLocalAttachment) async -> Preview {
        if let url = localVideo.localPlaybackURL { return await preview(url: url, video: true) }
        guard !localVideo.data.isEmpty, !Task.isCancelled else { return Preview(duration: nil, image: nil) }
        let identity = "legacy-draft:\(localVideo.id.uuidString)"
        if let cached = cache.object(forKey: (identity + "#video") as NSString),
           cached.expiresAt.map({ $0 > Date() }) ?? true { return cached.preview }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-preview-\(UUID().uuidString)")
            .appendingPathExtension(localVideo.mime.contains("quicktime") ? "mov" : "mp4")
        do {
            try localVideo.data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            defer { try? FileManager.default.removeItem(at: file) }
            return await preview(url: file, video: true, identity: identity)
        } catch { return Preview(duration: nil, image: nil) }
    }

    private func preview(url: URL, video: Bool, identity: String) async -> Preview {
        let empty = Preview(duration: nil, image: nil)
        guard !Task.isCancelled else { return empty }
        // A cached poster must not outlive a deleted/expired secure attachment.
        if AloSecureMediaStore.shared.isSecureURL(url),
           (try? AloSecureMediaStore.shared.contentInfo(for: url)) == nil { return empty }
        let key = identity + (video ? "#video" : "#audio")
        if let cached = cache.object(forKey: key as NSString),
           cached.expiresAt.map({ $0 > Date() }) ?? true { return cached.preview }
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: empty); return }
                if pending[key] != nil {
                    pending[key]?.waiters[waiter] = continuation
                } else {
                    pending[key] = Request(id: UUID(), url: url, video: video, waiters: [waiter: continuation])
                    queue.append(key)
                }
                startNextIfNeeded()
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiter, key: key) }
        }
    }

    /// Queue only visible demand, not a chain of tasks retaining every old
    /// asset. One subscriber leaving must not cancel another row's shared probe.
    private func cancelWaiter(_ waiter: UUID, key: String) {
        guard let continuation = pending[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: Preview(duration: nil, image: nil))
        guard pending[key]?.waiters.isEmpty == true else { return }
        pending[key] = nil
        queue.removeAll { $0 == key }
        if running?.key == key {
            running?.task.cancel()
            running = nil
        }
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard running == nil else { return }
        while !queue.isEmpty {
            let key = queue.removeFirst()
            guard let request = pending[key] else { continue }
            let load = loader
            let id = request.id, url = request.url, video = request.video
            let task = Task { [weak self] in
                let result = await load(url, video)
                guard !Task.isCancelled else { return }
                await self?.finish(result, key: key, id: id)
            }
            running = (key, request.id, task)
            return
        }
    }

    private func finish(_ result: Preview, key: String, id: UUID) {
        // A cancelled/offline/account-cleared probe may finish late. It must
        // never resume a replacement request or repopulate a cleared cache.
        guard running?.id == id, let request = pending[key], request.id == id else { return }
        pending[key] = nil
        running = nil
        if result.duration != nil || result.image != nil {
            let cost = result.image?.cgImage.map { $0.bytesPerRow * $0.height } ?? 128
            cache.setObject(Entry(result), forKey: key as NSString, cost: cost)
        } else {
            // Row recycling should not repeatedly probe the same offline URL.
            cache.setObject(Entry(result, expiresAt: Date().addingTimeInterval(5)), forKey: key as NSString, cost: 128)
        }
        request.waiters.values.forEach { $0.resume(returning: result) }
        startNextIfNeeded()
    }

    func removeAll() {
        running?.task.cancel()
        running = nil
        let empty = Preview(duration: nil, image: nil)
        pending.values.forEach { $0.waiters.values.forEach { $0.resume(returning: empty) } }
        pending.removeAll()
        queue.removeAll()
        cache.removeAllObjects()
    }

    private static func loadPreview(url: URL, video: Bool) async -> Preview {
        let empty = Preview(duration: nil, image: nil)
        guard !Task.isCancelled else { return empty }
        let asset = AloSecureMediaStore.shared.makeAsset(url: url)
        let generator = video ? AVAssetImageGenerator(asset: asset) : nil
        return await withTaskCancellationHandler {
            // A dead remote URL cannot occupy the one probe slot forever.
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                asset.cancelLoading()
                generator?.cancelAllCGImageGeneration()
            }
            defer { deadline.cancel() }
            let seconds = try? await asset.load(.duration).seconds
            guard !Task.isCancelled else { return empty }
            let duration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            // A timed-out/invalid finite message asset must not start a new
            // image request AFTER the only cancellation deadline has fired.
            guard duration != nil else { return empty }
            deadline.cancel()
            var image: UIImage?
            if let generator {
                let imageDeadline = Task {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    generator.cancelAllCGImageGeneration()
                }
                defer { imageDeadline.cancel() }
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 320, height: 320)
                if let frame = try? await generator.image(at: .zero), !Task.isCancelled {
                    image = UIImage(cgImage: frame.image)
                }
            }
            return Preview(duration: duration, image: image)
        } onCancel: {
            asset.cancelLoading()
            generator?.cancelAllCGImageGeneration()
        }
    }
}
