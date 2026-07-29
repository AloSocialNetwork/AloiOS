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
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    func loadRemoteImage(for url: URL) async throws -> UIImage {
        if let cached = image(for: url) {
            return cached
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 30
        )
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        let data: Data
        if let cachedResponse = URLCache.shared.cachedResponse(for: request) {
            data = cachedResponse.data
        } else {
            let response: URLResponse
            (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
        }

        let image = try await Task.detached(priority: .userInitiated) {
            try Self.decodeImage(data)
        }.value
        insert(image, for: url)
        return image
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
}

struct AloAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AloAsyncImagePhase) -> Content
    @State private var phase: AloAsyncImagePhase = .empty

    var body: some View {
        if let url, let image = AloDecodedImageCache.shared.image(for: url) {
            content(.success(Image(uiImage: image)))
        } else if let url {
            content(phase)
                .task(id: url) {
                    phase = .empty
                    do {
                        let image: UIImage
                        if AloSecureMediaStore.shared.isSecureURL(url) {
                            image = try await Task.detached(priority: .userInitiated) {
                                let payload = try AloSecureMediaStore.shared.payload(for: url)
                                let image = try AloDecodedImageCache.decodeImage(
                                    payload.data
                                )
                                AloDecodedImageCache.shared.insert(image, for: url)
                                return image
                            }.value
                        } else {
                            image = try await AloDecodedImageCache.shared.loadRemoteImage(for: url)
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

    private struct Entry: Codable {
        let encryptedPath: String
        let key: String
        let iv: String
        let mime: String
        let name: String
    }

    private let lock = NSLock()
    private let registryURL: URL
    private let registryKey: SymmetricKey
    private var entries: [String: Entry]
    private static var playerLoaderAssociation: UInt8 = 0

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
    }

    func isSecureURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == Self.scheme
    }

    func register(
        encryptedURL: URL,
        encryption: [String: Any],
        type: String,
        name: String
    ) throws -> URL {
        guard encryption.string("algorithm") == "aes-256-gcm-v1" else {
            throw AloSecureMediaError.invalidMetadata
        }
        let key = encryption.string("key")
        let iv = encryption.string("iv")
        guard !key.isEmpty, !iv.isEmpty else { throw AloSecureMediaError.invalidMetadata }
        let canonicalURL = encryptedURL.standardizedFileURL.resolvingSymlinksInPath()
        let allowedRoot = Self.encryptedCacheRoot().standardizedFileURL.resolvingSymlinksInPath()
        let allowedPrefix = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
        guard canonicalURL.path.hasPrefix(allowedPrefix) else { throw AloSecureMediaError.invalidPath }

        let tokenData = Data("\(canonicalURL.path)|\(key)|\(iv)".utf8)
        let token = SHA256.hash(data: tokenData).map { String(format: "%02x", $0) }.joined()
        let mime = encryption.string("mime").ifBlank(Self.mime(type: type, name: name))
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .ifBlank("media.\(Self.fileExtension(mime: mime, type: type))")
        let entry = Entry(
            encryptedPath: canonicalURL.path,
            key: key,
            iv: iv,
            mime: mime,
            name: displayName
        )

        lock.lock()
        entries[token] = entry
        let snapshot = entries
        lock.unlock()
        try persist(snapshot)

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = token
        components.path = "/\(displayName.replacingOccurrences(of: "/", with: "_"))"
        guard let url = components.url else { throw AloSecureMediaError.invalidURL }
        return url
    }

    func payload(for url: URL) throws -> Payload {
        guard isSecureURL(url), let token = url.host, !token.isEmpty else {
            throw AloSecureMediaError.invalidURL
        }
        lock.lock()
        let entry = entries[token]
        lock.unlock()
        guard let entry else { throw AloSecureMediaError.missingRegistration }

        let encryptedURL = URL(fileURLWithPath: entry.encryptedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let allowedRoot = Self.encryptedCacheRoot().standardizedFileURL.resolvingSymlinksInPath()
        let allowedPrefix = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
        guard encryptedURL.path.hasPrefix(allowedPrefix) else { throw AloSecureMediaError.invalidPath }
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
        let plaintext = try AES.GCM.open(sealed, using: SymmetricKey(data: key))
        return Payload(data: plaintext, mime: entry.mime, name: entry.name)
    }

    func makePlayer(url: URL) -> AVPlayer {
        guard isSecureURL(url) else { return AVPlayer(url: url) }
        let asset = AVURLAsset(url: url)
        let loader = AloSecureMediaResourceLoader(sourceURL: url, store: self)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        objc_setAssociatedObject(
            player,
            &Self.playerLoaderAssociation,
            loader,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return player
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: Self.encryptedCacheRoot())
        lock.lock()
        entries.removeAll()
        let snapshot = entries
        lock.unlock()
        try? persist(snapshot)
    }

#if DEBUG
    static func encryptedCacheFileForTesting(named name: String) throws -> URL {
        let root = encryptedCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name)
    }
#endif

    private func persist(_ snapshot: [String: Entry]) throws {
        let data = try JSONEncoder().encode(snapshot)
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

private final class AloSecureMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "com.alo.ios.secure-media-loader")
    private let sourceURL: URL
    private let store: AloSecureMediaStore
    private var cachedResult: Result<AloSecureMediaStore.Payload, Error>?

    init(sourceURL: URL, store: AloSecureMediaStore) {
        self.sourceURL = sourceURL
        self.store = store
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        do {
            let payload = try loadPayload()
            if let information = loadingRequest.contentInformationRequest {
                information.contentType = UTType(mimeType: payload.mime)?.identifier ?? payload.mime
                information.contentLength = Int64(payload.data.count)
                information.isByteRangeAccessSupported = true
            }
            if let request = loadingRequest.dataRequest {
                let rawOffset = request.currentOffset > 0 ? request.currentOffset : request.requestedOffset
                let start = max(0, min(payload.data.count, Int(rawOffset)))
                let end: Int
                if request.requestsAllDataToEndOfResource {
                    end = payload.data.count
                } else {
                    end = min(payload.data.count, start + request.requestedLength)
                }
                if end > start {
                    request.respond(with: payload.data.subdata(in: start..<end))
                }
            }
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
        return true
    }

    private func loadPayload() throws -> AloSecureMediaStore.Payload {
        if let cachedResult { return try cachedResult.get() }
        let result = Result { try store.payload(for: sourceURL) }
        cachedResult = result
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
}
