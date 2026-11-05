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
    /// The website's composer (web/css/chat.css): 44 pt field and round buttons, 8 pt apart, 10 pt from the edge.
    static let height: CGFloat = 44
    static let touchHeight: CGFloat = 44
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 8
    static let verticalPadding: CGFloat = 6
    static let singleLineRadius: CGFloat = 22
    static let multiLineRadius: CGFloat = 20
}

enum AloChatMetrics {
    static let control: CGFloat = 44
    static let headerHeight: CGFloat = 48
    static let headerHorizontalInset: CGFloat = 12
    static let headerTopInset: CGFloat = 8
    static let inset: CGFloat = 16
    static let sectionGap: CGFloat = 24
    static let cardRadius: CGFloat = 20

    /// Telegram iOS: the content may take the width less 36 pt and three 3 pt edge insets (`maximumWidthFill`), which
    /// leaves 33 pt from the widest bubble's body to the list's 10 pt edge.
    static func messageWidth(availableWidth: CGFloat, selecting: Bool) -> CGFloat {
        let oppositeInset: CGFloat = selecting ? 16 : 25
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
    // Lighter than before, closer to the website's glass (rgba(26,26,30,.6) with a 12 % white rim).
    var tintOpacity: Double { self == .control ? 0.2 : self == .chrome ? 0.1 : 0.3 }
    var highlightOpacity: Double { self == .panel ? 0.08 : 0.075 }
    /// The iOS 18 body over the thin material; together they read like the website's --glass.
    var legacyBodyOpacity: Double { self == .panel ? 0.34 : self == .control ? 0.2 : 0.14 }
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
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            // iOS 18 has no system glass, so this is the website's recipe (web/css/tokens.css) with public API only:
            // a thin saturated blur (backdrop-filter: blur(22px) saturate(180%)), a translucent body
            // (rgba(26,26,30,.6), lighter here because the material already darkens), a 12 % rim and a shadow
            // that falls outside the shape. The old black veil under the blur made every oval read as solid black.
            content
                .background {
                    ZStack {
                        AloGlassOuterShadow(shape: shape, role: role)
                        AloDarkChatMaterial(role: role).clipShape(shape).accessibilityHidden(true)
                        shape.fill(Color(red: 26 / 255, green: 26 / 255, blue: 30 / 255).opacity(role.legacyBodyOpacity))
                    }
                    .allowsHitTesting(false)
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.17), .white.opacity(0.09)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
        }
    }
}

/// A floating shadow drawn only outside the shape, so it never darkens the glass above it.
private struct AloGlassOuterShadow<S: InsettableShape>: View {
    let shape: S
    let role: AloGlassRole

    var body: some View {
        shape.fill(Color.black)
            .shadow(color: .black.opacity(role == .chrome ? 0.26 : 0.32), radius: role.shadowRadius, y: role.shadowOffset)
            .mask {
                ZStack {
                    Rectangle().padding(-48)
                    shape.fill(Color.black).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
    }
}

/// Public UIKit material on iOS 18; no private backdrop layers or blur filters.
private struct AloDarkChatMaterial: UIViewRepresentable {
    let role: AloGlassRole
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }
    func updateUIView(_ view: UIVisualEffectView, context: Context) {}
}

/// Telegram iOS's message bubble (ChatMessageBubbleImages `messageBubbleImage`, default `PresentationChatBubbleSettings`):
/// 16 pt corners, 8 pt on the side that joins the rest of the person's run, and a tail beside the run's last message.
/// The content is the bubble's body; the tail lies outside its frame, 4.75 pt past the side.
struct AloMessageBubbleSurface: ViewModifier {
    let color: Color
    let isMine: Bool
    let startsRun: Bool
    let endsRun: Bool
    /// A message that is only a photo keeps its full corner: a coloured tail would stick out of the picture.
    var showsTail = true

    func body(content: Content) -> some View {
        let tailed = showsTail && endsRun
        content
            .background(color)
            .clipShape(AloMessageBubbleShape(isMine: isMine, startsRun: startsRun, endsRun: endsRun, tail: false))
            .background {
                if tailed {
                    AloMessageBubbleShape(isMine: isMine, startsRun: startsRun, endsRun: endsRun, tail: true)
                        .fill(color)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// The bubble path as Telegram draws it, for an outgoing message and mirrored for an incoming one: circular corners
/// (`addArc(tangent1End:)`) and the tail from the same 33 pt template — two quadratic curves under the corner with an
/// ellipse cut out of their inner side.
struct AloMessageBubbleShape: Shape {
    static let radius: CGFloat = 16
    static let joined: CGFloat = 8

    let isMine: Bool
    let startsRun: Bool
    let endsRun: Bool
    let tail: Bool

    func path(in rect: CGRect) -> Path {
        // Outgoing orientation: the tail side is the right one.
        let topLeft = Self.radius, bottomLeft = Self.radius
        let topRight = startsRun ? Self.radius : Self.joined
        let bottomRight = endsRun ? Self.radius : Self.joined
        var body = Path()
        let w = rect.width, h = rect.height
        func r(_ value: CGFloat) -> CGFloat { min(value, w / 2, h / 2) }
        body.move(to: CGPoint(x: 0, y: r(topLeft)))
        body.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: r(topLeft), y: 0), radius: r(topLeft))
        body.addLine(to: CGPoint(x: w - r(topRight), y: 0))
        body.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: r(topRight)), radius: r(topRight))
        body.addLine(to: CGPoint(x: w, y: h - r(bottomRight)))
        body.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: w - r(bottomRight), y: h), radius: r(bottomRight))
        body.addLine(to: CGPoint(x: r(bottomLeft), y: h))
        body.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: h - r(bottomLeft)), radius: r(bottomLeft))
        body.closeSubpath()
        var result = body
        if tail {
            // Telegram's template bubble is 33 × 33; its tail lives in the bottom-right corner of it.
            let ox = w - 33, oy = h - 33
            var curve = Path()
            curve.move(to: CGPoint(x: ox + 24, y: oy + 24.5))
            curve.addQuadCurve(to: CGPoint(x: ox + 37.5, y: oy + 33), control: CGPoint(x: ox + 24, y: oy + 33))
            curve.addQuadCurve(to: CGPoint(x: ox + 51, y: oy + 24.5), control: CGPoint(x: ox + 51, y: oy + 33))
            curve.closeSubpath()
            // A union, not a second subpath: the two wind opposite ways, and their overlap would be a hole.
            curve = curve.union(Path(CGRect(x: ox + 16.5, y: oy + 16, width: 16.5, height: 9)))
            var notch = Path(ellipseIn: CGRect(x: ox + 33, y: oy + 14, width: 23, height: 21))
            // The curves close along the ellipse's own diameter; without this band the subtraction leaves a hairline
            // beside the bubble. No part of the tail lies there (the ellipse's edge is below y + 26 past x + 33).
            notch.addRect(CGRect(x: ox + 33, y: oy + 14, width: 30, height: 11))
            result = body.union(curve.subtracting(notch))
        }
        let mirror = isMine ? CGAffineTransform.identity : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        return result.applying(mirror.concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// The website's outlined smile. The system's face.smiling draws as a filled disc at this size.
struct AloSmileyGlyph: View {
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 24
            let color = GraphicsContext.Shading.foreground
            context.stroke(Path(ellipseIn: CGRect(x: 2.4 * unit, y: 2.4 * unit, width: 19.2 * unit, height: 19.2 * unit)),
                           with: color, lineWidth: 1.7 * unit)
            for x in [8.7, 15.3] {
                context.fill(Path(ellipseIn: CGRect(x: (x - 1.25) * unit, y: 8.2 * unit, width: 2.5 * unit, height: 2.5 * unit)), with: color)
            }
            var smile = Path()
            smile.move(to: CGPoint(x: 7.6 * unit, y: 14 * unit))
            smile.addQuadCurve(to: CGPoint(x: 16.4 * unit, y: 14 * unit), control: CGPoint(x: 12 * unit, y: 19.2 * unit))
            context.stroke(smile, with: color, style: StrokeStyle(lineWidth: 1.7 * unit, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
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
