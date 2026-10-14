import Foundation
import WebRTC

/// A call screen and its camera-source sheet may render the same track at once.
/// Weak membership lets either surface disappear without detaching the other.
final class AloVideoRendererRegistry {
    private let storage = NSHashTable<AnyObject>.weakObjects()
    private let lock = NSLock()
    var all: [RTCVideoRenderer] {
        lock.withLock { storage.allObjects.compactMap { $0 as? RTCVideoRenderer } }
    }
    @discardableResult func insert(_ renderer: RTCVideoRenderer) -> Bool {
        lock.withLock {
            guard !storage.contains(renderer) else { return false }
            storage.add(renderer)
            return true
        }
    }
    func remove(_ renderer: RTCVideoRenderer) { lock.withLock { storage.remove(renderer) } }
}
