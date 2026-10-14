import SwiftUI
import AVKit

/// Construct a player only for the selected full-screen page, never per feed
/// row/body evaluation. Moving to another page or closing releases its asset.
struct AloTimelineVideoPlayer: View {
    let url: URL
    let isActive: Bool
    var dismiss: AloViewerDismissDrag? = nil
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player { AloVideoPlayerView(player: player, dismiss: dismiss) }
            else { Color.black }
        }
        .onAppear { updatePlayback() }
        .onChange(of: isActive) { _, _ in updatePlayback() }
        .onDisappear { releasePlayer() }
        .accessibilityIdentifier("alo.post.viewer.video")
    }
    private func updatePlayback() {
        if isActive {
            if player == nil { player = AVPlayer(url: url) }
        } else {
            releasePlayer()
        }
    }
    private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
