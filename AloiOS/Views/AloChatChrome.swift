import SwiftUI
import UIKit

/// Propagate the messenger overlay state without coupling it to account data.
struct AloChatPreviewPresentedKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Messenger-only dimensions. Do not scale the feed, profile or inbox with these.
/// One size for every text input bar (chat, comments): the field and its round buttons share it.
enum AloInputMetrics {
    /// Telegram's regular-font composer: 31pt text area + 5/4pt outer insets.
    static let height: CGFloat = 40
    static let touchHeight: CGFloat = 44
    static let inset: CGFloat = 8
    static let spacing: CGFloat = 6
    static let verticalPadding: CGFloat = 6
    static let singleLineRadius: CGFloat = 20
    static let multiLineRadius: CGFloat = 18
}

enum AloChatMetrics {
    static let control: CGFloat = 44
    static let headerHeight: CGFloat = 48
    static let headerHorizontalInset: CGFloat = 12
    static let headerTopInset: CGFloat = 8
    static let inset: CGFloat = 16
    static let sectionGap: CGFloat = 24
    static let cardRadius: CGFloat = 20

    static func messageWidth(availableWidth: CGFloat, selecting: Bool) -> CGFloat {
        let oppositeInset: CGFloat = selecting ? 16 : 40
        let selectionSpace: CGFloat = selecting ? 36 : 0
        return max(1, availableWidth - oppositeInset - 8 - selectionSpace)
    }
}

struct AloChatPressStyle: ButtonStyle {
    private var accessibility = AloVisualAccessibility()

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(accessibility.reduceMotion || configuration.isPressed ? nil : AloPressFeedback.release, value: configuration.isPressed)
    }
}

/// Local feedback: never animates the surrounding row or restarts its layout.
struct AloControlPressStyle: ButtonStyle {
    private var accessibility = AloVisualAccessibility()

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .aloElasticTouch()
            .opacity(configuration.isPressed && accessibility.reduceMotion ? 0.8 : 1)
    }
}

enum AloPressFeedback {
    // Touch-down is immediate; only the release settles. No layout or blur animation.
    static let release = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
}

enum AloGlassRendering: Equatable {
    case opaque, legacy, native

    static func resolve(nativeAvailable: Bool, reduceTransparency: Bool, increasedContrast: Bool,
                        forceLegacy: Bool = false) -> Self {
        if reduceTransparency || increasedContrast { return .opaque }
        return nativeAvailable && !forceLegacy ? .native : .legacy
    }
}

private struct AloLegacyGlassPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

struct AloVisualAccessibilityPreview {
    var reduceMotion = false
    var reduceTransparency = false
    var increasedContrast = false
}

private struct AloVisualAccessibilityPreviewKey: EnvironmentKey {
    static let defaultValue = AloVisualAccessibilityPreview()
}

extension EnvironmentValues {
    /// Set only by the offline Debug fixture, so the iOS 18 path is testable on newer runtimes.
    var aloLegacyGlassPreview: Bool {
        get { self[AloLegacyGlassPreviewKey.self] }
        set { self[AloLegacyGlassPreviewKey.self] = newValue }
    }

    var aloVisualAccessibilityPreview: AloVisualAccessibilityPreview {
        get { self[AloVisualAccessibilityPreviewKey.self] }
        set { self[AloVisualAccessibilityPreviewKey.self] = newValue }
    }
}

/// The system values are read-only. Debug overrides may only strengthen them,
/// never turn off a person's accessibility preference.
struct AloVisualAccessibility: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.aloVisualAccessibilityPreview) private var preview

    var reduceMotion: Bool { systemReduceMotion || preview.reduceMotion }
    var reduceTransparency: Bool { systemReduceTransparency || preview.reduceTransparency }
    var increasedContrast: Bool { systemContrast == .increased || preview.increasedContrast }
}

enum AloGlassRole {
    /// `.chrome` is the lighter glass for floating social controls: content stays visible beneath it.
    case control, panel, chrome

    var material: Material { self == .panel ? .regular : .ultraThin }
    /// On iOS 18 the material needs a darker backing layer to read as glass
    /// over a lively chat wallpaper.  The material remains visible; this is
    /// deliberately not an opaque card masquerading as glass.
    var tintOpacity: Double { self == .control ? 0.36 : self == .chrome ? 0.14 : 0.48 }
    var highlightOpacity: Double { self == .panel ? 0.08 : 0.075 }
    var shadowRadius: CGFloat { self == .panel ? 14 : 8 }
    var shadowOffset: CGFloat { self == .panel ? 5 : 3 }
}

/// One public-API material for floating chrome, not for every message/card.
/// The shadow belongs to the shape behind the content, never to text or glyphs.
private struct AloGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var role: AloGlassRole = .control
    var interactive = false
    private var accessibility = AloVisualAccessibility()
    @Environment(\.aloLegacyGlassPreview) private var forceLegacy

    init(shape: S, role: AloGlassRole = .control, interactive: Bool = false) {
        self.shape = shape
        self.role = role
        self.interactive = interactive
    }

    private var rendering: AloGlassRendering {
        let nativeAvailable: Bool
        if #available(iOS 26.0, *) { nativeAvailable = true } else { nativeAvailable = false }
        return .resolve(nativeAvailable: nativeAvailable, reduceTransparency: accessibility.reduceTransparency,
                        increasedContrast: accessibility.increasedContrast, forceLegacy: forceLegacy)
    }

    func body(content: Content) -> some View {
        if rendering == .opaque {
            content.background(AloTheme.surface, in: shape)
                .overlay(shape.strokeBorder(AloTheme.muted.opacity(accessibility.increasedContrast ? 1 : 0.35), lineWidth: 1)
                    .allowsHitTesting(false))
        } else if #available(iOS 26.0, *), rendering == .native {
            // Telegram uses a dark material and its own touch effect, rather
            // than layering native and custom stretch animations together.
            // Material is decorative; do not wrap the semantic control or its
            // enclosing stack in a native glass interaction host.
            content.background {
                shape.fill(.clear)
                    .glassEffect(.regular.tint(.black.opacity(role.tintOpacity)).interactive(false), in: shape)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            // iOS 18 has no system glass. Telegram's pre-26 chrome is a plain dark blur with a thin
            // rim, not a bright gradient, so this is the same idea with public API only: a dark blur
            // (no light veil), a dark body, and one hairline edge. No sheen, no glossy bevel.
            let light = role == .chrome
            content
                .background {
                    ZStack {
                        shape.fill(Color.black.opacity(0.22))
                            .shadow(color: .black.opacity(light ? 0.22 : 0.3), radius: role.shadowRadius * 0.7, y: role.shadowOffset * 0.6)
                        AloDarkChatMaterial(role: role).clipShape(shape).accessibilityHidden(true)
                        shape.fill(Color(white: 0.06).opacity(light ? 0.46 : 0.58))
                    }
                    .allowsHitTesting(false)
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.07)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
                        .allowsHitTesting(false)
                }
        }
    }
}

/// Public UIKit material on iOS 18; no private backdrop layers or blur filters.
private struct AloDarkChatMaterial: UIViewRepresentable {
    let role: AloGlassRole
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }
    func updateUIView(_ view: UIVisualEffectView, context: Context) {}
}

struct AloChatGlass: ViewModifier {
    var interactive = true
    var role: AloGlassRole = .control

    func body(content: Content) -> some View {
        content.modifier(AloGlassSurface(shape: Capsule(), role: role, interactive: interactive))
    }
}

struct AloChatPanelGlass: ViewModifier {
    var radius: CGFloat = 24
    var role: AloGlassRole = .panel

    func body(content: Content) -> some View {
        content.modifier(AloGlassSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), role: role))
    }
}

/// The selected segment sits inside one material, without a second live blur.
struct AloGlassSelection: View {
    private var accessibility = AloVisualAccessibility()

    var body: some View {
        Capsule()
            .fill(accessibility.reduceTransparency || accessibility.increasedContrast ? AloTheme.segmentedSelection : .white.opacity(0.115))
            .overlay {
                if accessibility.increasedContrast {
                    Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 0.65)
                } else {
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.16), .white.opacity(0.035)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.65
                    )
                }
            }
            .shadow(
                color: accessibility.reduceTransparency ? .clear : .black.opacity(0.22),
                radius: 5,
                y: 2
            )
            .allowsHitTesting(false)
    }
}

struct AloChatCircleButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(AloTheme.text)
                .frame(width: AloChatMetrics.control, height: AloChatMetrics.control)
                .modifier(AloChatGlass())
                .contentShape(Circle())
        }
        .buttonStyle(AloControlPressStyle())
        .accessibilityLabel(label)
    }
}
