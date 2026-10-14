import Foundation
import Testing
@testable import AloiOS

/// A deliberately non-cooperative loader also exercises stale completion:
/// cancelling a consumer must not rely on the asset eventually answering.
private actor AloPreviewProbeGate {
    private var continuations: [String: [CheckedContinuation<AloMediaPreviewCache.Preview, Never>]] = [:]
    private(set) var starts: [String: Int] = [:]

    func load(_ url: URL) async -> AloMediaPreviewCache.Preview {
        starts[url.path, default: 0] += 1
        return await withCheckedContinuation { continuations[url.path, default: []].append($0) }
    }

    func finish(_ path: String, duration: Double = 3) {
        let values = continuations.removeValue(forKey: path) ?? []
        values.forEach { $0.resume(returning: .init(duration: duration, image: nil)) }
    }

    func finishAll() {
        let values = continuations.values.flatMap { $0 }
        continuations.removeAll()
        values.forEach { $0.resume(returning: .init(duration: nil, image: nil)) }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AloMediaPreviewCancellationTests {
    private func url(_ path: String) -> URL { URL(string: "https://preview.invalid/" + path)! }
    private func waitForDemand(_ count: Int, cache: AloMediaPreviewCache) async throws {
        for _ in 0..<200 {
            if await cache.pendingDemandCount == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cache.pendingDemandCount == count)
    }
    private func waitForStart(_ path: String, gate: AloPreviewProbeGate, count: Int = 1) async throws {
        for _ in 0..<200 {
            if await gate.starts[path] == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.starts[path] == count)
    }

    @Test func cancelledOffscreenQueueDoesNotDelayTheNextVisibleProbe() async throws {
        let gate = AloPreviewProbeGate()
        let cache = AloMediaPreviewCache(loader: { url, _ in await gate.load(url) })
        let blocker = Task { await cache.preview(url: url("blocker"), video: false) }
        try await waitForStart("/blocker", gate: gate)
        let offscreen = (0..<30).map { index in
            Task { await cache.preview(url: url("old-\(index)"), video: true) }
        }
        try await waitForDemand(31, cache: cache)
        offscreen.forEach { $0.cancel() }
        for task in offscreen { #expect(await task.value.duration == nil) }
        #expect(await cache.pendingDemandCount == 1)
        let visible = Task { await cache.preview(url: url("visible"), video: true) }
        try await waitForDemand(2, cache: cache)
        await gate.finish("/blocker")
        _ = await blocker.value
        try await waitForStart("/visible", gate: gate)
        let starts = await gate.starts
        #expect(starts.count == 2, "Thirty cancelled rows must never open assets")
        await gate.finish("/visible")
        #expect(await visible.value.duration == 3)
        await cache.removeAll()
        await gate.finishAll()
    }

    @Test func cancellingOneSubscriberKeepsSharedDemandAlive() async throws {
        let gate = AloPreviewProbeGate()
        let cache = AloMediaPreviewCache(loader: { url, _ in await gate.load(url) })
        let first = Task { await cache.preview(url: url("shared"), video: false) }
        let second = Task { await cache.preview(url: url("shared"), video: false) }
        try await waitForDemand(2, cache: cache)
        try await waitForStart("/shared", gate: gate)
        first.cancel()
        #expect(await first.value.duration == nil)
        #expect(await cache.pendingDemandCount == 1)
        await gate.finish("/shared", duration: 7)
        #expect(await second.value.duration == 7)
        let cached = await cache.preview(url: url("shared"), video: false)
        #expect(cached.duration == 7)
        #expect(await gate.starts["/shared"] == 1)
        await cache.removeAll()
        await gate.finishAll()
    }

    @Test func cancelledActiveProbeCannotOverwriteItsReplacement() async throws {
        let gate = AloPreviewProbeGate()
        let cache = AloMediaPreviewCache(loader: { url, _ in await gate.load(url) })
        let old = Task { await cache.preview(url: url("same"), video: true) }
        try await waitForStart("/same", gate: gate)
        old.cancel()
        #expect(await old.value.duration == nil)
        let replacement = Task { await cache.preview(url: url("same"), video: true) }
        try await waitForStart("/same", gate: gate, count: 2)
        await gate.finish("/same", duration: 9) // old and new both answer late
        #expect(await replacement.value.duration == 9)
        #expect(await cache.pendingDemandCount == 0)
        #expect(await cache.preview(url: url("same"), video: true).duration == 9)
        await cache.removeAll()
        await gate.finishAll()
    }

    @Test func cacheClearResumesAllWaitersAndRejectsLateResult() async throws {
        let gate = AloPreviewProbeGate()
        let cache = AloMediaPreviewCache(loader: { url, _ in await gate.load(url) })
        let active = Task { await cache.preview(url: url("old"), video: true) }
        try await waitForStart("/old", gate: gate)
        let queued = Task { await cache.preview(url: url("queued"), video: false) }
        try await waitForDemand(2, cache: cache)
        await cache.removeAll()
        #expect(await active.value.duration == nil)
        #expect(await queued.value.duration == nil)
        await gate.finish("/old", duration: 99)
        let fresh = Task { await cache.preview(url: url("old"), video: true) }
        try await waitForStart("/old", gate: gate, count: 2)
        await gate.finish("/old", duration: 4)
        #expect(await fresh.value.duration == 4)
        #expect(await gate.starts["/queued"] == nil)
        await cache.removeAll()
        await gate.finishAll()
    }
}
