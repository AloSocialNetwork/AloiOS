import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import ObjectiveC
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AloAsyncImagePhase {
    case empty
    case success(Image)
    case failure(Error)
}

private final class AloDecodedImageCache: @unchecked Sendable {
    static let shared = AloDecodedImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 320
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        let pixels = max(1, Int(image.size.width * image.scale))
            * max(1, Int(image.size.height * image.scale))
        cache.setObject(image, forKey: url as NSURL, cost: pixels * 4)
        // Remember the proportions for messages that arrive without a size (drafts and inline data aside).
        if url.scheme != "data", url.scheme != "alo-draft-preview" {
            AloMediaSizeRegistry.shared.record(width: Double(image.size.width * image.scale),
                                               height: Double(image.size.height * image.scale),
                                               forKey: Self.remoteImageCacheKey(for: url))
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    @concurrent
    func loadRemoteImage(for url: URL, intent: AloMediaDownloadIntent) async throws -> UIImage {
        if let cached = image(for: url) {
            return cached
        }

        let cacheKey = Self.remoteImageCacheKey(for: url)
        let owner = AloSecureOfflineCacheStore.shared.currentOwnerUserId
        if url.scheme == "data" {
            // Compatibility for inline drafts; never decode a full image in
            // every SwiftUI body pass, and never persist the plaintext preview.
            let image = try await Task.detached(priority: .userInitiated) {
                let value = url.absoluteString
                guard let comma = value.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else {
                    throw AloSecureMediaError.invalidImage
                }
                return try Self.decodeImage(data)
            }.value
            insert(image, for: url)
            return image
        }
        let diskImage = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = AloSecureOfflineCacheStore.shared.loadRemoteImage(cacheKey: cacheKey, ownerUserId: owner) else {
                return nil
            }
            return try? Self.decodeImage(data)
        }.value
        if let diskImage {
            insert(diskImage, for: url)
            return diskImage
        }

        // Protected media must use the API session: it owns both the authenticated
        // cookie and certificate-pinning policy. Bypassing URLCache also discards
        // responses cached before the media route stopped redirecting to itself.
        guard AloMediaCacheSettings.current.permits(type: "image", size: 1_024 * 1_024,
            network: AloMediaNetworkMonitor.shared.network, intent: intent) else { throw AloSecureMediaError.downloadRequired }
        let maximum: Int64 = intent == .automatic ? 1_024 * 1_024 : 32 * 1_024 * 1_024
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("alo-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Share the same two-transfer budget as encrypted movies and voice.
        // Recheck disk after admission: another row may have fetched this avatar.
        try await AloMediaDownloadQueue.shared.fetch(key: temporary.path, intent: intent) {
            if owner > 0, AloSecureOfflineCacheStore.shared.loadRemoteImage(cacheKey: cacheKey, ownerUserId: owner) != nil { return }
            guard AloMediaCacheSettings.current.permits(type: "image", size: 1_024 * 1_024,
                network: AloMediaNetworkMonitor.shared.network, intent: intent) else { throw AloSecureMediaError.downloadRequired }
            let budget = try AloMediaTransferBudget.shared.reserve(bytes: maximum * 2)
            defer { budget.release() }
            try await AloAPIClient.shared.downloadCachedMedia(url.absoluteString, to: temporary, expectedSize: nil, maximumSize: maximum)
            try Task.checkCancellation()
            let bytes = try Data(contentsOf: temporary)
            AloSecureOfflineCacheStore.shared.saveRemoteImage(bytes, cacheKey: cacheKey, ownerUserId: owner)
        }
        try Task.checkCancellation()
        let data: Data
        if FileManager.default.fileExists(atPath: temporary.path) { data = try Data(contentsOf: temporary) }
        else if let cached = AloSecureOfflineCacheStore.shared.loadRemoteImage(cacheKey: cacheKey, ownerUserId: owner) { data = cached }
        else { throw AloSecureMediaError.invalidImage }

        let image = try await Task.detached(priority: .userInitiated) {
            try Self.decodeImage(data)
        }.value
        insert(image, for: url)
        return image
    }

    static func remoteImageCacheKey(for url: URL) -> String {
        // The local development host may change. The resource path remains
        // stable, so cache it independently from a LAN address while keeping
        // third-party absolute URLs distinct.
        if url.path.hasPrefix("/"),
           url.host == AloAPIClient.shared.baseURL.host {
            return url.path + (url.query.map { "?\($0)" } ?? "")
        }
        return url.absoluteString
    }

    static func decodeImage(
        _ data: Data,
        maxPixelSize: Int = 2_048
    ) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ) else {
            throw AloSecureMediaError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw AloSecureMediaError.invalidImage
        }
        return UIImage(cgImage: image)
    }
}

enum AloImageCache {
    static func removeAll() {
        AloDecodedImageCache.shared.removeAll()
    }

    static func draftImage(_ attachment: AloLocalAttachment, maxPixelSize: Int) async throws -> UIImage {
        if let playback = attachment.localPlaybackURL {
            _ = try AloSecureMediaStore.shared.contentInfo(for: playback)
        }
        let identity = URL(string: "alo-draft-preview://\(attachment.id.uuidString)?pixels=\(maxPixelSize)")!
        if let cached = AloDecodedImageCache.shared.image(for: identity) { return cached }
        return try await Task.detached(priority: .userInitiated) {
            let bytes: Data
            if let url = attachment.localPlaybackURL {
                bytes = try AloSecureMediaStore.shared.payload(for: url).data
            } else { bytes = attachment.data }
            let image = try AloDecodedImageCache.decodeImage(bytes, maxPixelSize: maxPixelSize)
            AloDecodedImageCache.shared.insert(image, for: identity)
            return image
        }.value
    }

#if DEBUG
    /// Offline layout fixtures have no HTTP server. Seed their generated image,
    /// without changing authenticated media loading or accepting fixture URLs in Release.
    static func installPreviewImage(_ image: UIImage, for url: URL) {
        guard UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") else { return }
        AloDecodedImageCache.shared.insert(image, for: url)
    }
#endif
}

/// Natural size of an image decoded in memory now or on this device before; nil if never seen.
enum AloCachedImageSize {
    static func dimensions(for url: URL) -> AloMediaDimensions? {
        if let image = AloDecodedImageCache.shared.image(for: url) {
            return AloMediaDimensions(width: image.size.width, height: image.size.height)
        }
        // Decoded in an earlier session: the size outlives the in-memory image.
        return AloMediaSizeRegistry.shared.dimensions(forKey: AloDecodedImageCache.remoteImageCacheKey(for: url))
    }
}

/// Like `AloAsyncImage`, but hands out the decoded `UIImage` so full-screen viewers can zoom it.
enum AloAsyncUIImagePhase { case loading, success(UIImage), failure }

struct AloAsyncUIImage<Content: View>: View {
    let url: URL?
    var downloadIntent: AloMediaDownloadIntent = .userInitiated
    @ViewBuilder let content: (AloAsyncUIImagePhase) -> Content
    @State private var phase: AloAsyncUIImagePhase = .loading

    var body: some View {
        if let url, let image = AloDecodedImageCache.shared.image(for: url) {
            content(.success(image))
        } else if let url {
            content(phase)
                .task(id: "\(url.absoluteString):\(downloadIntent)") {
                    phase = .loading
                    do {
                        let image: UIImage
                        if AloSecureMediaStore.shared.isSecureURL(url) {
                            let lease = AloSecureMediaStore.shared.keepResource(url)
                            defer { lease?.release() }
                            try await AloSecureMediaStore.shared.ensureAvailable(url, intent: downloadIntent)
                            image = try await Task.detached(priority: .userInitiated) {
                                let payload = try AloSecureMediaStore.shared.payload(for: url)
                                let image = try AloDecodedImageCache.decodeImage(payload.data)
                                AloDecodedImageCache.shared.insert(image, for: url)
                                return image
                            }.value
                        } else {
                            image = try await AloDecodedImageCache.shared.loadRemoteImage(for: url, intent: downloadIntent)
                        }
                        guard !Task.isCancelled else { return }
                        phase = .success(image)
                    } catch {
                        guard !Task.isCancelled else { return }
                        phase = .failure
                    }
                }
        } else {
            content(.failure)
        }
    }
}

struct AloAsyncImage<Content: View>: View {
    let url: URL?
    var downloadIntent: AloMediaDownloadIntent = .automatic
    @ViewBuilder let content: (AloAsyncImagePhase) -> Content
    @State private var phase: AloAsyncImagePhase = .empty

    var body: some View {
        if let url, let image = AloDecodedImageCache.shared.image(for: url) {
            content(.success(Image(uiImage: image)))
        } else if let url {
            content(phase)
                .task(id: "\(url.absoluteString):\(downloadIntent)") {
                    phase = .empty
                    do {
                        let image: UIImage
                        if AloSecureMediaStore.shared.isSecureURL(url) {
                            let lease = AloSecureMediaStore.shared.keepResource(url)
                            defer { lease?.release() }
                            try await AloSecureMediaStore.shared.ensureAvailable(url, intent: downloadIntent)
                            image = try await Task.detached(priority: .userInitiated) {
                                let payload = try AloSecureMediaStore.shared.payload(for: url)
                                let image = try AloDecodedImageCache.decodeImage(
                                    payload.data
                                )
                                AloDecodedImageCache.shared.insert(image, for: url)
                                return image
                            }.value
                        } else {
                            image = try await AloDecodedImageCache.shared.loadRemoteImage(for: url, intent: downloadIntent)
                        }
                        guard !Task.isCancelled else { return }
                        phase = .success(Image(uiImage: image))
                    } catch {
                        guard !Task.isCancelled else { return }
                        phase = .failure(error)
                    }
                }
        } else {
            content(.empty)
        }
    }
}

final class AloSecureMediaStore: @unchecked Sendable {
    static let shared = AloSecureMediaStore()
    static let scheme = "alo-e2ee-media"

    struct Payload {
        let data: Data
        let mime: String
        let name: String
    }

    struct ContentInfo {
        let mime: String
        let name: String
        let plaintextSize: Int64
        let isChunked: Bool
    }

    private struct Entry: Codable, Equatable {
        let encryptedPath: String
        var algorithm: String?
        var key: String
        var iv: String
        var noncePrefix: String?
        var chunkSize: Int?
        var plaintextSize: Int64?
        let mime: String
        let name: String
        // Optional so registries created before expiring media remain readable.
        let expiresAt: String?
        let remoteURL: String?
        let mediaType: String?
        let scope: AloMediaCacheScope?
        let expectedPlaintextSize: Int64?
        var remoteIsPlaintext: Bool? = nil
    }

    private let lock = NSLock()
    private let registryURL: URL
    private let registryKey: SymmetricKey
    private var entries: [String: Entry]
    private static var playerLoaderAssociation: UInt8 = 0
    private static let maximumInMemoryPayloadSize: Int64 = 64 * 1_024 * 1_024

    private init() {
        let applicationSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        registryURL = applicationSupport
            .appendingPathComponent("AloSecureMedia", isDirectory: true)
            .appendingPathComponent("registry-v1.bin")
        registryKey = SymmetricKey(data: Self.loadOrCreateRegistryKey())
        entries = Self.loadRegistry(from: registryURL, using: registryKey)
        purgeExpired()
    }

    func isSecureURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == Self.scheme
    }

    /// Stage ciphertext for resource-loader playback. Called on the capture
    /// worker, so no plaintext movie/base64 string is created on the UI thread.
    func registerDraft(_ attachment: AloLocalAttachment) throws -> URL {
        guard let source = attachment.encryptedSourceURL else { throw AloSecureMediaError.invalidPath }
        let root = Self.encryptedCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("draft-\(attachment.id.uuidString).bin")
        let alreadyExists = FileManager.default.fileExists(atPath: destination.path)
        if !alreadyExists { try FileManager.default.copyItem(at: source, to: destination) }
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            try Self.excludeFromBackup(destination)
            let result = try register(encryptedURL: destination,
                encryption: attachment.mediaEncryption.reduce(into: [String: Any]()) { $0[$1.key] = $1.value },
                type: attachment.type, name: attachment.name)
            AloMediaDiskCache.shared.record(destination, scope: .privateChats)
            return result
        } catch {
            if !alreadyExists { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    func register(
        encryptedURL: URL,
        encryption: [String: Any],
        type: String,
        name: String,
        expiresAt: String = "",
        remoteURL: String? = nil,
        scope: AloMediaCacheScope = .privateChats,
        expectedPlaintextSize: Int64? = nil
    ) throws -> URL {
        let algorithm = encryption.string("algorithm")
        let key = encryption.string("key")
        let iv = encryption.string("iv")
        let chunkedMetadata = AloChunkedMediaCrypto.Metadata(encryption)
        guard
            (algorithm == "aes-256-gcm-v1" && !key.isEmpty && !iv.isEmpty) ||
            chunkedMetadata != nil
        else { throw AloSecureMediaError.invalidMetadata }
        let canonicalURL = encryptedURL.standardizedFileURL.resolvingSymlinksInPath()
        let allowedRoot = Self.encryptedCacheRoot().standardizedFileURL.resolvingSymlinksInPath()
        let allowedPrefix = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
        guard canonicalURL.path.hasPrefix(allowedPrefix) else { throw AloSecureMediaError.invalidPath }

        let tokenData = Data([
            canonicalURL.path,
            algorithm,
            key,
            iv,
            chunkedMetadata?.noncePrefix ?? "",
            chunkedMetadata.map { String($0.chunkSize) } ?? "",
            chunkedMetadata.map { String($0.plaintextSize) } ?? ""
        ].joined(separator: "|").utf8)
        let token = SHA256.hash(data: tokenData).map { String(format: "%02x", $0) }.joined()
        let mime = encryption.string("mime").ifBlank(Self.mime(type: type, name: name))
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .ifBlank("media.\(Self.fileExtension(mime: mime, type: type))")
        let normalizedExpiry = expiresAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = Entry(
            encryptedPath: canonicalURL.path,
            algorithm: algorithm,
            key: key,
            iv: iv,
            noncePrefix: chunkedMetadata?.noncePrefix,
            chunkSize: chunkedMetadata?.chunkSize,
            plaintextSize: chunkedMetadata?.plaintextSize,
            mime: mime,
            name: displayName,
            expiresAt: normalizedExpiry.isEmpty ? nil : normalizedExpiry,
            remoteURL: remoteURL,
            mediaType: type,
            scope: scope,
            expectedPlaintextSize: expectedPlaintextSize ?? chunkedMetadata?.plaintextSize
        )

        lock.lock()
        let changed = entries[token] != entry
        entries[token] = entry
        lock.unlock()
        if changed { try persist() }

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = token
        components.path = "/\(displayName.replacingOccurrences(of: "/", with: "_"))"
        guard let url = components.url else { throw AloSecureMediaError.invalidURL }
        if remoteURL != nil { AloMediaDiskCache.shared.record(canonicalURL, scope: scope) }
        return url
    }

    func remoteURL(for url: URL) -> String? { try? resolvedEntry(for: url).0.remoteURL }

    /// Compatibility with older, non-E2EE audio/video messages: the transport
    /// may be plain, but their offline file is still encrypted on this device.
    func registerRemotePlaintext(_ remote: String, type: String, name: String, size: Int64?, ownerUserId: Int,
                                 scope: AloMediaCacheScope = .privateChats) throws -> URL {
        let token = SHA256.hash(data: Data("plain:\(ownerUserId):\(remote)".utf8)).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        if entries[token] == nil {
            var entry = Entry(encryptedPath: Self.encryptedCacheRoot().appendingPathComponent("plain-\(token).bin").path,
                algorithm: nil, key: "", iv: "", noncePrefix: nil, chunkSize: nil, plaintextSize: nil,
                mime: Self.mime(type: type, name: name), name: name.ifBlank("media.bin"), expiresAt: nil,
                remoteURL: remote, mediaType: type, scope: scope, expectedPlaintextSize: size)
            entry.remoteIsPlaintext = true
            entries[token] = entry
        }
        lock.unlock()
        try persist()
        var components = URLComponents()
        components.scheme = Self.scheme; components.host = token; components.path = "/media"
        guard let url = components.url else { throw AloSecureMediaError.invalidURL }
        return url
    }

    func isAvailableLocally(_ url: URL) -> Bool {
        guard let (_, file) = try? resolvedEntry(for: url) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    func keepResource(_ url: URL) -> AloMediaCacheLease? {
        guard let (_, file) = try? resolvedEntry(for: url) else { return nil }
        return AloMediaDiskCache.shared.keep(file)
    }

    /// Registering a resource never fetches it. Only visible automatic demand
    /// admitted by the size/network rules, or an explicit tap, reaches this path.
    @concurrent
    func ensureAvailable(_ url: URL, intent: AloMediaDownloadIntent) async throws {
        guard isSecureURL(url) else { return }
        let (entry, file) = try resolvedEntry(for: url)
        let lease = AloMediaDiskCache.shared.keep(file)
        defer { lease.release() }
        if FileManager.default.fileExists(atPath: file.path) {
            AloMediaDiskCache.shared.touch(file)
            return
        }
        guard let remote = entry.remoteURL else { throw AloSecureMediaError.missingRegistration }
        let settings = AloMediaCacheSettings.current
        guard remote.hasPrefix("file://") || settings.permits(type: entry.mediaType ?? "file", size: entry.expectedPlaintextSize,
            network: AloMediaNetworkMonitor.shared.network, intent: intent) else {
            throw AloSecureMediaError.downloadRequired
        }
        try await AloMediaDownloadQueue.shared.fetch(key: file.path, intent: intent) { [self] in
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: file.path) { return }
            guard remote.hasPrefix("file://") || AloMediaCacheSettings.current.permits(type: entry.mediaType ?? "file",
                size: entry.expectedPlaintextSize, network: AloMediaNetworkMonitor.shared.network, intent: intent) else {
                throw AloSecureMediaError.downloadRequired
            }
            // A manual download can exceed the automatic threshold, not the
            // finite disk budget. Preserve room for the OS and unsent work.
            let maximum = AloMediaCacheSettings.current.maximumBytes
            let expected = entry.expectedPlaintextSize
            guard expected.map({ $0 <= maximum }) ?? true else { throw AloSecureMediaError.payloadTooLarge }
            let metadata = chunkedMetadata(for: entry)
            let expectedCiphertext = entry.remoteIsPlaintext == true ? entry.expectedPlaintextSize : metadata.map {
                AloChunkedMediaCrypto.expectedCiphertextSize(plaintextSize: $0.plaintextSize, chunkSize: $0.chunkSize)
            } ?? entry.expectedPlaintextSize.map { $0 + 16 } // Legacy AES-GCM appends one authentication tag.
            let budget = try AloMediaTransferBudget.shared.reserveDownload(expectedSize: expectedCiphertext,
                maximumBytes: maximum + maximum / 100, copies: entry.remoteIsPlaintext == true ? 2 : 1)
            defer { budget.lease.release() }
            let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).part")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await AloAPIClient.shared.downloadCachedMedia(remote, to: temporary, expectedSize: expectedCiphertext,
                maximumSize: budget.maximumBytes)
            try Task.checkCancellation()
            // Recheck expiry after the suspension before publishing the file.
            _ = try resolvedEntry(for: url)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if entry.remoteIsPlaintext == true {
                let encrypted = temporary.appendingPathExtension("encrypted")
                defer { try? FileManager.default.removeItem(at: encrypted) }
                let result = try AloChunkedMediaCrypto.encrypt(sourceURL: temporary, destinationURL: encrypted, mime: entry.mime)
                var updated = entry
                updated.algorithm = AloChunkedMediaCrypto.scheme
                updated.key = result.metadata.key; updated.noncePrefix = result.metadata.noncePrefix
                updated.chunkSize = result.metadata.chunkSize; updated.plaintextSize = result.metadata.plaintextSize
                try updateEntry(updated, token: url.host ?? "")
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                try FileManager.default.moveItem(at: encrypted, to: file)
            } else {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                try FileManager.default.moveItem(at: temporary, to: file)
            }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            try Self.excludeFromBackup(file)
            AloMediaDiskCache.shared.record(file, scope: entry.scope ?? .privateChats)
        }
    }

    /// Removes encrypted cache entries whose disappearing-media deadline
    /// elapsed while the application was suspended or terminated.
    func purgeExpired(now: Date = Date()) {
        lock.lock()
        let expiredTokens = entries.compactMap { token, entry in
            Self.isExpired(entry.expiresAt, at: now) ? token : nil
        }
        let removedPaths = expiredTokens.compactMap { token in
            entries.removeValue(forKey: token)?.encryptedPath
        }
        lock.unlock()

        guard !removedPaths.isEmpty else { return }
        removedPaths.forEach { path in
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        try? persist()
    }

    func payload(for url: URL) throws -> Payload {
        let (entry, encryptedURL) = try resolvedEntry(for: url)
        if let metadata = chunkedMetadata(for: entry) {
            guard metadata.plaintextSize <= Self.maximumInMemoryPayloadSize else {
                throw AloSecureMediaError.payloadTooLarge
            }
            return Payload(
                data: try AloChunkedMediaCrypto.readRange(
                    encryptedURL: encryptedURL,
                    metadata: metadata,
                    offset: 0,
                    length: Int(metadata.plaintextSize)
                ),
                mime: entry.mime,
                name: entry.name
            )
        }
        return Payload(
            data: try decryptLegacyPayload(encryptedURL: encryptedURL, entry: entry),
            mime: entry.mime,
            name: entry.name
        )
    }

    func contentInfo(for url: URL) throws -> ContentInfo {
        let (entry, encryptedURL) = try resolvedEntry(for: url)
        if let metadata = chunkedMetadata(for: entry) {
            return ContentInfo(
                mime: entry.mime,
                name: entry.name,
                plaintextSize: metadata.plaintextSize,
                isChunked: true
            )
        }
        if let size = entry.expectedPlaintextSize, size > 0 {
            return ContentInfo(mime: entry.mime, name: entry.name, plaintextSize: size, isChunked: false)
        }
        let encryptedSize = try encryptedURL.resourceValues(forKeys: [.fileSizeKey])
            .fileSize
            .map(Int64.init) ?? -1
        guard encryptedSize > 16 else { throw AloSecureMediaError.invalidMetadata }
        return ContentInfo(
            mime: entry.mime,
            name: entry.name,
            plaintextSize: encryptedSize - 16,
            isChunked: false
        )
    }

    func readData(for url: URL, offset: Int64, length: Int) throws -> Data {
        let (entry, encryptedURL) = try resolvedEntry(for: url)
        if let metadata = chunkedMetadata(for: entry) {
            return try AloChunkedMediaCrypto.readRange(
                encryptedURL: encryptedURL,
                metadata: metadata,
                offset: offset,
                length: length
            )
        }
        let plaintext = try decryptLegacyPayload(encryptedURL: encryptedURL, entry: entry)
        guard offset >= 0, length > 0, offset < Int64(plaintext.count) else { return Data() }
        let start = Int(offset)
        let end = min(plaintext.count, start + length)
        return Data(plaintext[start..<end])
    }

    private func resolvedEntry(for url: URL) throws -> (Entry, URL) {
        guard isSecureURL(url), let token = url.host, !token.isEmpty else {
            throw AloSecureMediaError.invalidURL
        }
        lock.lock()
        let entry = entries[token]
        lock.unlock()
        guard let entry else { throw AloSecureMediaError.missingRegistration }
        if Self.isExpired(entry.expiresAt, at: Date()) {
            remove(urls: [url])
            throw AloSecureMediaError.expired
        }

        let encryptedURL = URL(fileURLWithPath: entry.encryptedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let allowedRoot = Self.encryptedCacheRoot().standardizedFileURL.resolvingSymlinksInPath()
        let allowedPrefix = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
        guard encryptedURL.path.hasPrefix(allowedPrefix) else { throw AloSecureMediaError.invalidPath }
        AloMediaDiskCache.shared.touch(encryptedURL)
        return (entry, encryptedURL)
    }

    private func chunkedMetadata(for entry: Entry) -> AloChunkedMediaCrypto.Metadata? {
        AloChunkedMediaCrypto.Metadata([
            "algorithm": entry.algorithm ?? "aes-256-gcm-v1",
            "key": entry.key,
            "noncePrefix": entry.noncePrefix ?? "",
            "chunkSize": entry.chunkSize.map(String.init) ?? "",
            "plaintextSize": entry.plaintextSize.map(String.init) ?? "",
            "mime": entry.mime
        ])
    }

    private func decryptLegacyPayload(encryptedURL: URL, entry: Entry) throws -> Data {
        let encrypted = try Data(contentsOf: encryptedURL, options: [.mappedIfSafe])
        guard encrypted.count > 16,
              let key = Self.base64URLData(entry.key),
              let iv = Self.base64URLData(entry.iv) else {
            throw AloSecureMediaError.invalidMetadata
        }
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: Data(encrypted.dropLast(16)),
            tag: Data(encrypted.suffix(16))
        )
        return try AES.GCM.open(sealed, using: SymmetricKey(data: key))
    }

    func makePlayer(url: URL) -> AVPlayer {
        AVPlayer(playerItem: AVPlayerItem(asset: makeAsset(url: url, intent: .userInitiated)))
    }

    /// Metadata/posters must not allocate a decoder, playback clock or player
    /// layer for every row. Retain the private loader for the asset's lifetime.
    func makeAsset(url: URL, intent: AloMediaDownloadIntent = .automatic) -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        guard isSecureURL(url) else { return asset }
        let loader = AloSecureMediaResourceLoader(sourceURL: url, store: self, intent: intent)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        objc_setAssociatedObject(
            asset,
            &Self.playerLoaderAssociation,
            loader,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return asset
    }

    func clearCache() {
        Task { await AloMediaPreviewCache.shared.removeAll() }
        try? FileManager.default.removeItem(at: Self.encryptedCacheRoot())
        lock.lock()
        entries.removeAll()
        lock.unlock()
        try? persist()
    }

    func remove(urls: [URL]) {
        let tokens = Set(
            urls.compactMap { url in
                isSecureURL(url) ? url.host : nil
            }
        )
        guard !tokens.isEmpty else { return }

        lock.lock()
        let removedPaths = tokens.compactMap { token -> String? in
            entries.removeValue(forKey: token)?.encryptedPath
        }
        lock.unlock()

        removedPaths.forEach { path in
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        try? persist()
    }

#if DEBUG
    static func encryptedCacheFileForTesting(named name: String) throws -> URL {
        let root = encryptedCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name)
    }
#endif

    private func updateEntry(_ entry: Entry, token: String) throws {
        lock.lock(); entries[token] = entry; lock.unlock()
        try persist()
    }

    // Always serialize the latest registry while locked. A slow writer must
    // never overwrite registrations added by another concurrent history page.
    private func persist() throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(entries)
        let sealed = try AES.GCM.seal(data, using: registryKey)
        guard let combined = sealed.combined else { throw AloSecureMediaError.invalidRegistry }
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try combined.write(to: registryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try Self.excludeFromBackup(registryURL.deletingLastPathComponent())
        try Self.excludeFromBackup(registryURL)
    }

    private static func loadRegistry(from url: URL, using key: SymmetricKey) -> [String: Entry] {
        guard let combined = try? Data(contentsOf: url),
              let sealed = try? AES.GCM.SealedBox(combined: combined),
              let opened = try? AES.GCM.open(sealed, using: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: opened) else {
            return [:]
        }
        return decoded
    }

    private static func isExpired(_ value: String?, at date: Date) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        // A malformed non-empty deadline must not make protected media durable.
        guard let expiry else { return true }
        return expiry <= date
    }

    private static func loadOrCreateRegistryKey() -> Data {
        let service = "com.alo.ios.secure-media"
        let account = "registry-key-v1"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           data.count == 32 {
            return data
        }
        var random = [UInt8](repeating: 0, count: 32)
        let randomStatus = random.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            return Data(SHA256.hash(data: Data(UUID().uuidString.utf8)))
        }
        let data = Data(random)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            return data
        }
        return data
    }

    private static func encryptedCacheRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("AloE2EEMedia", isDirectory: true)
            .appendingPathComponent("encrypted", isDirectory: true)
    }

    private static func base64URLData(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var next = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? next.setResourceValues(values)
    }

    private static func mime(type: String, name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if let value = UTType(filenameExtension: ext)?.preferredMIMEType { return value }
        if type.lowercased().contains("video") { return "video/mp4" }
        if type.lowercased().contains("voice") || type.lowercased().contains("audio") { return "audio/mp4" }
        if type.lowercased() == "image" { return "image/jpeg" }
        return "application/octet-stream"
    }

    private static func fileExtension(mime: String, type: String) -> String {
        if let ext = UTType(mimeType: mime)?.preferredFilenameExtension { return ext }
        if type.lowercased().contains("video") { return "mp4" }
        if type.lowercased().contains("voice") { return "m4a" }
        if type.lowercased() == "image" { return "jpg" }
        return "bin"
    }
}

// AVFoundation callbacks and every mutable cache/request below are confined to
// `queue`; async work captures immutable inputs and hops back before mutation.
private final class AloSecureMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.alo.ios.secure-media-loader")
    private let sourceURL: URL
    private let store: AloSecureMediaStore
    private var cachedContentInfo: Result<AloSecureMediaStore.ContentInfo, Error>?
    private var cachedLegacyPayload: Result<AloSecureMediaStore.Payload, Error>?
    private let responseChunkSize = 1_024 * 1_024
    private let intent: AloMediaDownloadIntent
    private let lease: AloMediaCacheLease?
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(sourceURL: URL, store: AloSecureMediaStore, intent: AloMediaDownloadIntent) {
        self.sourceURL = sourceURL
        self.store = store
        self.intent = intent
        lease = store.keepResource(sourceURL)
    }

    deinit { requests.values.forEach { $0.cancel() }; lease?.release() }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let id = ObjectIdentifier(loadingRequest)
        requests[id] = Task { [weak self, sourceURL, store, intent] in
            let result: Result<Void, Error>
            do { try await store.ensureAvailable(sourceURL, intent: intent); result = .success(()) }
            catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                guard let self, self.requests.removeValue(forKey: id) != nil else { return }
                switch result {
                case .success: self.fulfill(loadingRequest)
                case .failure(let error): loadingRequest.finishLoading(with: error)
                }
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        requests.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    private func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest) {
        do {
            let info = try loadContentInfo()
            if let information = loadingRequest.contentInformationRequest {
                information.contentType = UTType(mimeType: info.mime)?.identifier ?? info.mime
                information.contentLength = info.plaintextSize
                information.isByteRangeAccessSupported = true
            }
            if let request = loadingRequest.dataRequest {
                try respond(to: request, info: info)
            }
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }

    private func loadContentInfo() throws -> AloSecureMediaStore.ContentInfo {
        if let cachedContentInfo { return try cachedContentInfo.get() }
        let result = Result { try store.contentInfo(for: sourceURL) }
        cachedContentInfo = result
        return try result.get()
    }

    private func respond(
        to request: AVAssetResourceLoadingDataRequest,
        info: AloSecureMediaStore.ContentInfo
    ) throws {
        let requestedOffset = request.currentOffset > 0 ? request.currentOffset : request.requestedOffset
        let start = max(0, min(info.plaintextSize, requestedOffset))
        let end: Int64
        if request.requestsAllDataToEndOfResource {
            end = info.plaintextSize
        } else {
            let requestedLength = max(0, Int64(request.requestedLength))
            end = min(info.plaintextSize, start + requestedLength)
        }
        guard end > start else { return }

        if info.isChunked {
            // AVFoundation may request the complete asset. Keep that request streamed
            // so a large video never becomes one Data allocation.
            var offset = start
            while offset < end {
                let length = Int(min(Int64(responseChunkSize), end - offset))
                let data = try store.readData(for: sourceURL, offset: offset, length: length)
                guard !data.isEmpty else { throw AloSecureMediaError.invalidMetadata }
                request.respond(with: data)
                offset += Int64(data.count)
            }
            return
        }

        let payload = try loadLegacyPayload()
        let legacyStart = Int(start)
        let legacyEnd = Int(end)
        if legacyEnd > legacyStart {
            request.respond(with: payload.data.subdata(in: legacyStart..<legacyEnd))
        }
    }

    private func loadLegacyPayload() throws -> AloSecureMediaStore.Payload {
        if let cachedLegacyPayload { return try cachedLegacyPayload.get() }
        let result = Result { try store.payload(for: sourceURL) }
        cachedLegacyPayload = result
        return try result.get()
    }
}

enum AloSecureMediaError: Error {
    case invalidURL
    case invalidPath
    case invalidMetadata
    case missingRegistration
    case invalidRegistry
    case invalidImage
    case payloadTooLarge
    case expired
    case downloadRequired
    case insufficientStorage
}
