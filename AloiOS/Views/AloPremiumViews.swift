import Combine
import SwiftUI
import UIKit

// Public builds without Alo Премиум (owner, 2026-11-03: not published until payments are connected): the same names
// as the full file (AloPremiumViews.swift), nothing is shown, there are no pages and no payments.

struct AloPremiumLook: Equatable {
    var emojiStatus: String
    var nameColor: String
    var avatarFrame: String
}

struct AloPremiumProfileExtras: Equatable {
    var coverGifUrl: String
    var musicUrl: String
    var musicTitle: String
}

final class AloPremiumDirectory: ObservableObject {
    static let shared = AloPremiumDirectory()

    @Published private(set) var looks: [Int: AloPremiumLook] = [:]
    @Published private(set) var extras: [Int: AloPremiumProfileExtras] = [:]
    @Published private(set) var enabled = false

    func look(_ userId: Int) -> AloPremiumLook? { nil }
    func absorb(_ json: Any) {}
}

struct AloPremiumMark: View {
    let userId: Int
    var size: CGFloat = 15
    var body: some View { EmptyView() }
}

struct AloPremiumName: View {
    let text: String
    let userId: Int
    var font: Font
    var color: Color = AloTheme.text
    var body: some View { Text(text).font(font).foregroundStyle(color) }
}

extension View {
    func aloPremiumFrame(userId: Int, size: CGFloat, frame: String? = nil) -> some View { self }
}

struct AloAnimatedGIF: View {
    let url: URL
    let api: AloAPIClient?
    var body: some View { EmptyView() }
}

struct AloProfileMusicButton: View {
    let url: URL
    let title: String
    var body: some View { EmptyView() }
}

struct AloPremiumGiftRecipient: Equatable {
    let id: Int
    let name: String
}

struct AloPremiumSettingsView: View {
    var onOpenLook: () -> Void = {}
    var giftRecipient: AloPremiumGiftRecipient? = nil
    var body: some View { EmptyView() }
}

struct AloPremiumLookView: View {
    var onOpenPremium: () -> Void = {}
    var body: some View { EmptyView() }
}
