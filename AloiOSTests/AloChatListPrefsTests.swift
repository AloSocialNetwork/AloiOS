import Foundation
import Testing
@testable import AloiOS

struct AloChatListPrefsTests {
    private func prefs() -> AloChatListPrefs {
        let defaults = UserDefaults(suiteName: "alo.test.chatprefs.\(UUID().uuidString)")!
        return AloChatListPrefs(defaults: defaults)
    }

    @Test func pinKeepsOrderAndRespectsTheLimit() {
        let p = prefs()
        let keys = (1...6).map { "direct:\($0)" }
        #expect(p.setPinned(owner: 1, keys: Array(keys.prefix(5)), pinned: true))
        #expect(!p.setPinned(owner: 1, keys: [keys[5]], pinned: true))
        #expect(p.state(owner: 1).pinned == Array(keys.prefix(5)))
        p.setPinned(owner: 1, keys: [keys[0]], pinned: false)
        #expect(p.setPinned(owner: 1, keys: [keys[5]], pinned: true))
    }

    @Test func archivingUnpinsAndStateIsPerAccount() {
        let p = prefs()
        p.setPinned(owner: 1, keys: ["direct:7"], pinned: true)
        p.setArchived(owner: 1, keys: ["direct:7"], archived: true)
        #expect(p.state(owner: 1) == .init(pinned: [], archived: ["direct:7"]))
        #expect(p.state(owner: 2) == .init())
        p.setArchived(owner: 1, keys: ["direct:7"], archived: false)
        #expect(p.state(owner: 1).archived.isEmpty)
    }

    @Test func prefsSurviveRelaunch() {
        let name = "alo.test.chatprefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        AloChatListPrefs(defaults: defaults).setPinned(owner: 3, keys: ["group:9"], pinned: true)
        #expect(AloChatListPrefs(defaults: defaults).isPinned(owner: 3, key: "group:9"))
    }
}
