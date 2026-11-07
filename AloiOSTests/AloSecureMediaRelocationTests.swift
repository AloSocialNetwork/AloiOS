import Foundation
import Testing
@testable import AloiOS

/// iOS moves an app's data container on reinstall and update. Media registered by the older install must keep working
/// under the new container instead of failing with «invalidPath» (black circles and videos, silent voice messages).
struct AloSecureMediaRelocationTests {
    private let root = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/NEW/Library/Caches/AloE2EEMedia/encrypted")

    @Test func aPathFromTheOldContainerMovesUnderTodaysRoot() {
        let old = "/var/mobile/Containers/Data/Application/OLD/Library/Caches/AloE2EEMedia/encrypted/plain-abc.bin"
        #expect(AloSecureMediaStore.relocatedIntoCurrentContainer(old, root: root)?.path == root.path + "/plain-abc.bin")
        let nested = "/private/var/OLD/Library/Caches/AloE2EEMedia/encrypted/drafts/x.bin"
        #expect(AloSecureMediaStore.relocatedIntoCurrentContainer(nested, root: root)?.path == root.path + "/drafts/x.bin")
    }

    @Test func pathsOutsideTheMediaCacheOrEscapingItAreRefused() {
        #expect(AloSecureMediaStore.relocatedIntoCurrentContainer("/tmp/other/file.bin", root: root) == nil)
        #expect(AloSecureMediaStore.relocatedIntoCurrentContainer("/OLD/AloE2EEMedia/encrypted/../../etc/passwd", root: root) == nil)
        #expect(AloSecureMediaStore.relocatedIntoCurrentContainer("/OLD/AloE2EEMedia/encrypted/", root: root) == nil)
    }
}
