import SwiftUI
import UIKit

/// Chat scroll edges, as Telegram's WallpaperEdgeEffectNodeImpl draws them: a copy of the
/// wallpaper, aligned with the real one and faded inward, so messages dissolve into the
/// background under the header and composer. Only dark wallpapers (Telegram's inverted
/// patterns) get the black overlay; on a light wallpaper black read as a dirty band.
enum AloChatEdge: Equatable {
    case top, bottom

    var fadeHeight: CGFloat { self == .top ? 80 : 60 }
    var inwardExtension: CGFloat { self == .top ? 28 : 16 }

    func dimmingOpacity(reduceTransparency: Bool, increasedContrast: Bool) -> Double {
        reduceTransparency || increasedContrast ? 1 : 0.68
    }

    /// Telegram fades the wallpaper copy in at 0.75 over patterned wallpapers.
    func wallpaperCopyOpacity(reduceTransparency: Bool, increasedContrast: Bool) -> Double {
        reduceTransparency || increasedContrast ? 1 : 0.75
    }

    func height(chrome: CGFloat, safeArea: CGFloat) -> CGFloat {
        max(100, max(0, chrome) + max(0, safeArea) + inwardExtension)
    }

    /// A compact sampling of the reference's normalized edge profile. A solid
    /// section covers the controls; only the inward-facing edge fades away.
    /// Do not stretch the falloff across a taller player/keyboard container.
    func maskStops(height: CGFloat) -> [(location: CGFloat, alpha: CGFloat)] {
        let height = max(1, height)
        let fraction = min(height, fadeHeight) / height
        let alpha: [CGFloat] = [1, 0.9755, 0.901, 0.7378, 0.4826, 0.24, 0.0888, 0.0332, 0]
        let profile = alpha.enumerated().map { index, value in
            (location: 1 - fraction + CGFloat(index) / CGFloat(alpha.count - 1) * fraction, alpha: value)
        }
        let top = fraction < 1 ? [(location: CGFloat(0), alpha: CGFloat(1))] + profile : profile
        return self == .top ? top : top.reversed().map { (location: 1 - $0.location, alpha: $0.alpha) }
    }
}

/// The same Telegram edge-falloff curve for every screen: feed, search, notifications, chats.
enum AloEdgeProfile {
    private static let alpha: [Double] = [1, 0.9755, 0.901, 0.7378, 0.4826, 0.24, 0.0888, 0.0332, 0]

    /// `solid` is the fraction (0...1) of the height that stays fully dark before the fade starts.
    static func gradient(top: Bool, peak: Double, solid: Double = 0.35) -> LinearGradient {
        let fade = 1 - solid
        var stops = [Gradient.Stop(color: .black.opacity(peak), location: 0)]
        for (index, value) in alpha.enumerated() {
            let location = solid + Double(index) / Double(alpha.count - 1) * fade
            stops.append(.init(color: .black.opacity(peak * value), location: location))
        }
        if !top { stops = stops.map { .init(color: $0.color, location: 1 - $0.location) }.reversed() }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }
}

struct AloChatEdgeBackdrop: View {
    let edge: AloChatEdge
    /// The chat's wallpaper. Light wallpapers are continued over the messages; dark ones (and
    /// screens without a wallpaper) keep the black edge.
    var wallpaper: AloChatAppearance?
    private var accessibility = AloVisualAccessibility()

    init(edge: AloChatEdge, wallpaper: AloChatAppearance? = nil) {
        self.edge = edge
        self.wallpaper = wallpaper
    }

    var body: some View {
        GeometryReader { proxy in
            let mask = LinearGradient(stops: edge.maskStops(height: proxy.size.height).map {
                .init(color: Color.black.opacity(Double($0.alpha)), location: $0.location)
            }, startPoint: .top, endPoint: .bottom)
            if let wallpaper, wallpaper.hasLightWallpaper {
                // The same canvas as the chat background, shifted so its pixels line up with it.
                let frame = proxy.frame(in: .global)
                AloChatWallpaper(appearance: wallpaper)
                    .frame(width: AloChatWallpaper.canvasSize.width, height: AloChatWallpaper.canvasSize.height)
                    .offset(x: -frame.minX, y: -frame.minY)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .clipped()
                    .opacity(edge.wallpaperCopyOpacity(reduceTransparency: accessibility.reduceTransparency,
                        increasedContrast: accessibility.increasedContrast))
                    .mask { mask }
            } else {
                // One black layer: do not compound its alpha with a .dark material. Glass controls
                // retain their own blur. Telegram's tiny private variable-blur filter is not used.
                Color.black
                    .opacity(edge.dimmingOpacity(reduceTransparency: accessibility.reduceTransparency,
                        increasedContrast: accessibility.increasedContrast))
                    .mask { mask }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension AloChatAppearance {
    /// Average HSB brightness of the two wallpaper colours; built-in themes are all dark.
    var hasLightWallpaper: Bool {
        (wallpaperBrightness + min(1, wallpaperBrightness + 0.11)) / 2 >= 0.35
    }
}

/// Modal/menu isolation only; scroll edges use their own lightweight gradient.
/// Public UIKit blur plus a separate black sibling. Never animate the blur's
/// alpha or strength.
struct AloBlackChatBackdrop: UIViewRepresentable {
    var darkness: Double
    var opaque: Bool

    func makeUIView(context: Context) -> AloChatBackdropView {
        let view = AloChatBackdropView(frame: .zero)
        view.configure(darkness: darkness, opaque: opaque)
        return view
    }

    func updateUIView(_ view: AloChatBackdropView, context: Context) {
        view.configure(darkness: darkness, opaque: opaque)
    }
}

final class AloChatBackdropView: UIView {
    private let blur = UIVisualEffectView(effect: nil)
    private let dim = UIView()
    private var configuration: Configuration?

    private struct Configuration: Equatable {
        let darkness: Double
        let opaque: Bool
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        blur.isUserInteractionEnabled = false
        dim.isUserInteractionEnabled = false
        dim.backgroundColor = .black
        addSubview(blur)
        addSubview(dim)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(darkness: Double, opaque: Bool) {
        let next = Configuration(darkness: min(1, max(0, darkness)), opaque: opaque)
        guard next != configuration else { return }
        // Scrolling, playback timers and parent rendering must not recreate
        // the backdrop or restart its effect. Only accessibility changes it.
        if configuration == nil || configuration?.opaque != opaque {
            blur.effect = opaque ? nil : UIBlurEffect(style: .dark)
        }
        dim.alpha = opaque ? 1 : next.darkness
        configuration = next
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        dim.frame = bounds
    }
}
