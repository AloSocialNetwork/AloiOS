import CryptoKit
import Foundation

/// Pixel sizes of images this device has already decoded. Older messages, and some clients, send
/// photos without their size; once such a photo has been shown, the next layout uses its real
/// proportions instead of a guess.
///
/// Only a ratio-sized pair of numbers is stored, under a SHA-256 of the image's cache key, so the
/// file reveals neither URLs nor content. It lives in Application Support with complete file
/// protection until first unlock, and never leaves the device.
final class AloMediaSizeRegistry: @unchecked Sendable {
    static let shared = AloMediaSizeRegistry()

    private static let capacity = 4_000
    private let queue = DispatchQueue(label: "alo.media-size-registry")
    private var sizes: [String: [Double]] = [:]
    private var loaded = false
    private var saveScheduled = false
    private let fileURL: URL?

    init(fileURL: URL? = AloMediaSizeRegistry.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func dimensions(forKey key: String) -> AloMediaDimensions? {
        queue.sync {
            loadIfNeeded()
            guard let pair = sizes[Self.hash(key)], pair.count == 2 else { return nil }
            return AloMediaDimensions(width: pair[0], height: pair[1])
        }
    }

    func record(width: Double, height: Double, forKey key: String) {
        guard width >= 1, height >= 1, !key.isEmpty else { return }
        queue.async { [self] in
            loadIfNeeded()
            let hashed = Self.hash(key)
            if let existing = sizes[hashed], existing == [width, height] { return }
            if sizes.count >= Self.capacity, let evicted = sizes.keys.first { sizes.removeValue(forKey: evicted) }
            sizes[hashed] = [width, height]
            scheduleSave()
        }
    }

    // MARK: Storage

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return }
        sizes = stored
    }

    /// Batches the many sizes recorded while a chat scrolls into one write.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            saveScheduled = false
            guard let fileURL, let data = try? JSONEncoder().encode(sizes) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("alo-media-sizes.json")
    }

    private static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    /// Waits for pending writes; tests only.
    func flush() { queue.sync {} }
    #endif
}
