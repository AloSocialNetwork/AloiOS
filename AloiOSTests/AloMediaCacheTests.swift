import Foundation
import Testing
@testable import AloiOS

@Suite(.serialized)
struct AloMediaCacheTests {
    private let mb: Int64 = 1_024 * 1_024

    @Test func automaticDownloadMatchesTelegramPresets() {
        #expect(AloMediaDownloadPreset.low.permits(type: "image", size: mb))
        #expect(!AloMediaDownloadPreset.low.permits(type: "image", size: mb + 1))
        #expect(!AloMediaDownloadPreset.low.permits(type: "video", size: 10))
        #expect(AloMediaDownloadPreset.low.permits(type: "voice", size: 2 * mb))
        #expect(!AloMediaDownloadPreset.low.permits(type: "voice", size: 2 * mb + 1))
        #expect(AloMediaDownloadPreset.medium.permits(type: "circle", size: 5 * mb / 2))
        #expect(!AloMediaDownloadPreset.medium.permits(type: "circle", size: 5 * mb / 2 + 1))
        #expect(AloMediaDownloadPreset.high.permits(type: "video", size: 10 * mb))
        #expect(!AloMediaDownloadPreset.high.permits(type: "video", size: 10 * mb + 1))
        #expect(AloMediaDownloadPreset.high.permits(type: "file", size: 3 * mb))
        #expect(!AloMediaDownloadPreset.off.permits(type: "voice", size: 1))
        #expect(!AloMediaDownloadPreset.high.permits(type: "video", size: nil))
        #expect(!AloMediaDownloadPreset.high.permits(type: "image", size: -1))
    }

    @Test func networkAndExplicitDemandHaveSeparateRules() {
        let settings = AloMediaCacheSettings()
        #expect(settings.maximumBytes == 2_048 * mb)
        #expect(settings.permits(type: "video", size: 8 * mb, network: .wifi, intent: .automatic))
        #expect(!settings.permits(type: "video", size: 8 * mb, network: .cellular, intent: .automatic))
        #expect(!settings.permits(type: "voice", size: mb, network: .constrained, intent: .automatic))
        #expect(settings.permits(type: "video", size: nil, network: .constrained, intent: .userInitiated))
        #expect(!settings.permits(type: "voice", size: 1, network: .offline, intent: .userInitiated))
    }

    @Test func unknownSizesUseAvailableDiskAndConcurrentTransfersReserveSpace() throws {
        let budget = AloMediaTransferBudget(freeBytes: { 1_024 * 1_024 * 1_024 })
        let unknown = try budget.reserveDownload(expectedSize: nil, maximumBytes: 16_384 * mb, copies: 2)
        #expect(unknown.maximumBytes == 384 * mb)
        do {
            _ = try budget.reserve(bytes: mb)
            Issue.record("Reserved space must not be allocated to another transfer")
        } catch AloSecureMediaError.insufficientStorage { /* expected */ }
        unknown.lease.release()
        let next = try budget.reserve(bytes: 10 * mb)
        next.release()
    }

    @Test func quotaEvictsLeastRecentlyUsedAndProtectsAnActivePlayer() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try file("old.bin", bytes: 100, root: root, date: Date().addingTimeInterval(-200))
        let recent = try file("recent.bin", bytes: 100, root: root, date: Date().addingTimeInterval(-100))
        let cache = AloMediaDiskCache(root: root)
        let lease = cache.keep(old)
        var settings = AloMediaCacheSettings(); settings.maximumBytes = 150
        let usage = await cache.clean(settings: settings)
        #expect(usage.bytes == 100)
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: recent.path))
        let pinned = await cache.clean(settings: settings, all: true)
        #expect(pinned.bytes == 100)
        lease.release()
        let cleared = await cache.clean(settings: settings, all: true)
        #expect(cleared.bytes == 0)
    }

    @Test func retentionAndQuotaAreIndependent() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateFile = try file("private.bin", bytes: 100, root: root)
        let group = try file("group.bin", bytes: 100, root: root)
        let channel = try file("channel.bin", bytes: 100, root: root)
        let cache = AloMediaDiskCache(root: root)
        cache.record(privateFile, scope: .privateChats)
        cache.record(group, scope: .groups)
        cache.record(channel, scope: .channels)
        _ = await cache.usage() // drain the serial index writer
        _ = await cache.clean(settings: .init(), now: Date().addingTimeInterval(8 * 86_400))
        #expect(FileManager.default.fileExists(atPath: privateFile.path))
        #expect(FileManager.default.fileExists(atPath: group.path))
        #expect(!FileManager.default.fileExists(atPath: channel.path))
        _ = await cache.clean(settings: .init(), now: Date().addingTimeInterval(32 * 86_400))
        #expect(FileManager.default.fileExists(atPath: privateFile.path))
        #expect(!FileManager.default.fileExists(atPath: group.path))
    }

    @Test func cleanupNeverOwnsHistoryDraftsOrExternalSymlinkTargets() async throws {
        let parent = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("AloOfflineSecure")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = try file("conversation-42-v1.bin", bytes: 100, root: root)
        let bootstrap = try file("bootstrap-v2.bin", bytes: 100, root: root)
        let draft = try file("draft-test.bin", bytes: 100, root: root)
        let image = try file("remote-image-test-v1.bin", bytes: 100, root: root)
        let outside = try file("outside.bin", bytes: 100, root: parent)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("remote-image-link"), withDestinationURL: outside)
        let cache = AloMediaDiskCache(root: root)
        cache.record(history, scope: .previews)
        cache.record(outside, scope: .previews)
        _ = await cache.clean(settings: .init(), all: true)
        for url in [history, bootstrap, draft, outside] { #expect(FileManager.default.fileExists(atPath: url.path)) }
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }

    @Test func expiredCopiesAreRemovedBeforeUnexpiredLRUResources() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateFile = try file("private.bin", bytes: 100, root: root)
        let channel = try file("channel.bin", bytes: 100, root: root)
        let cache = AloMediaDiskCache(root: root)
        cache.record(privateFile, scope: .privateChats)
        cache.record(channel, scope: .channels)
        _ = await cache.usage()
        var settings = AloMediaCacheSettings(); settings.maximumBytes = 150
        _ = await cache.clean(settings: settings, now: Date().addingTimeInterval(8 * 86_400))
        #expect(FileManager.default.fileExists(atPath: privateFile.path))
        #expect(!FileManager.default.fileExists(atPath: channel.path))
    }

    @Test func persistedIndexRetainsScopeAndCanRecoverWithoutIndex() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try file("retained.bin", bytes: 75, root: root)
        let cache = AloMediaDiskCache(root: root)
        cache.record(saved, scope: .privateChats)
        _ = await cache.clean(settings: .init())
        let reopened = AloMediaDiskCache(root: root)
        let usage = await reopened.clean(settings: .init(), now: Date().addingTimeInterval(40 * 86_400))
        #expect(usage.bytes == 75)
        try FileManager.default.removeItem(at: root.appendingPathComponent("index-v1.json"))
        let rebuilt = AloMediaDiskCache(root: root)
        #expect(await rebuilt.usage().bytes == 75)
    }

    @Test func downloadQueueDeduplicatesAndCancellationKeepsOtherDemand() async throws {
        let queue = AloMediaDownloadQueue(concurrency: 1)
        let probe = CacheDownloadProbe()
        let first = Task { try await queue.fetch(key: "one", intent: .automatic) { try await probe.run() } }
        let second = Task { try await queue.fetch(key: "one", intent: .userInitiated) { try await probe.run() } }
        for _ in 0..<100 {
            if await queue.demandCount == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await queue.demandCount == 2)
        first.cancel()
        try await second.value
        _ = try? await first.value
        #expect(await probe.started == 1)
    }

    @Test func downloadQueueBoundsConcurrencyAndReleasesCancelledWork() async throws {
        let queue = AloMediaDownloadQueue(concurrency: 2)
        let probe = CacheDownloadProbe()
        let first = Task { try await queue.fetch(key: "first", intent: .automatic) { try await probe.run() } }
        let second = Task { try await queue.fetch(key: "second", intent: .automatic) { try await probe.run() } }
        let third = Task { try await queue.fetch(key: "third", intent: .userInitiated) { try await probe.run() } }
        for _ in 0..<100 {
            if await probe.active == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        first.cancel()
        _ = try? await first.value
        try await second.value; try await third.value
        #expect(await probe.maximumActive == 2)
        #expect(await queue.demandCount == 0)
    }

    @Test func encryptedResourceIsLazyAndSurvivesLosingItsRemoteSource() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try file("source", bytes: 4_000, root: root)
        let ciphertext = root.appendingPathComponent("remote.bin")
        let encrypted = try AloChunkedMediaCrypto.encrypt(sourceURL: source, destinationURL: ciphertext, mime: "audio/mp4")
        let destination = try AloSecureMediaStore.encryptedCacheFileForTesting(named: "cache-test-\(UUID().uuidString).bin")
        let store = AloSecureMediaStore.shared
        let url = try store.register(encryptedURL: destination, encryption: encrypted.metadata.dictionary,
            type: "voice", name: "voice.m4a", remoteURL: ciphertext.absoluteString)
        defer { store.remove(urls: [url]) }
        #expect(!store.isAvailableLocally(url))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try await store.ensureAvailable(url, intent: .userInitiated)
        try FileManager.default.removeItem(at: ciphertext)
        // Cached data does not consult network availability or require its server.
        try await store.ensureAvailable(url, intent: .automatic)
        #expect(store.isAvailableLocally(url))
        #expect(try store.payload(for: url).data == Data(repeating: 7, count: 4_000))
    }

    @Test func oldUnencryptedVoiceIsEncryptedInTheOfflineCache() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try file("voice.m4a", bytes: 3_000, root: root)
        let store = AloSecureMediaStore.shared
        let url = try store.registerRemotePlaintext(source.absoluteString, type: "voice", name: "voice.m4a", size: 3_000, ownerUserId: 1_999_991)
        defer { store.remove(urls: [url]) }
        #expect(!store.isAvailableLocally(url))
        try await store.ensureAvailable(url, intent: .userInitiated)
        try FileManager.default.removeItem(at: source)
        #expect(try store.contentInfo(for: url).isChunked)
        #expect(try store.payload(for: url).data == Data(repeating: 7, count: 3_000))
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AloCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func file(_ name: String, bytes: Int, root: URL, date: Date = Date()) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }
}

private actor CacheDownloadProbe {
    var started = 0
    var active = 0
    var maximumActive = 0
    func run() async throws {
        started += 1; active += 1; maximumActive = max(active, maximumActive)
        do { try await Task.sleep(for: .milliseconds(250)); active -= 1 }
        catch { active -= 1; throw error }
    }
}
