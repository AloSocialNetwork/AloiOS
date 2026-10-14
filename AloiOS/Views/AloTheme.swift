import SwiftUI

enum AloTheme {
    // The product chrome is intentionally close to black.  Content, media and
    // the one blue action color establish hierarchy instead of decorative hue.
    static let background = Color.black
    static let backgroundSecondary = Color(red: 14.0 / 255.0, green: 14.0 / 255.0, blue: 16.0 / 255.0)
    static let surface = Color(red: 29.0 / 255.0, green: 29.0 / 255.0, blue: 31.0 / 255.0)
    static let surfaceRaised = Color(red: 40.0 / 255.0, green: 40.0 / 255.0, blue: 42.0 / 255.0)
    static let surfaceInteractive = Color(red: 54.0 / 255.0, green: 54.0 / 255.0, blue: 57.0 / 255.0)
    static let segmentedBackground = Color(red: 29.0 / 255.0, green: 29.0 / 255.0, blue: 31.0 / 255.0)
    static let segmentedSelection = Color(red: 58.0 / 255.0, green: 58.0 / 255.0, blue: 61.0 / 255.0)
    static let text = Color(red: 245.0 / 255.0, green: 245.0 / 255.0, blue: 247.0 / 255.0)
    static let muted = Color(red: 158.0 / 255.0, green: 158.0 / 255.0, blue: 166.0 / 255.0)
    static let separator = Color.white.opacity(0.13)
    static let border = Color.white.opacity(0.09)
    static let feedDivider = Color.white.opacity(0.15)
    static let accent = Color(red: 10.0 / 255.0, green: 132.0 / 255.0, blue: 1.0)
    static let success = Color(red: 48.0 / 255.0, green: 209.0 / 255.0, blue: 88.0 / 255.0)
    static let warning = Color(red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0)
    static let destructive = Color(red: 1.0, green: 69.0 / 255.0, blue: 58.0 / 255.0)
    static let outgoing = Color(red: 35.0 / 255.0, green: 117.0 / 255.0, blue: 198.0 / 255.0)
    static let incoming = Color(red: 36.0 / 255.0, green: 36.0 / 255.0, blue: 38.0 / 255.0)

    static let radiusSmall: CGFloat = 12
    static let radiusMedium: CGFloat = 18
    static let radiusLarge: CGFloat = 24
    static let spacingSmall: CGFloat = 8
    static let spacingMedium: CGFloat = 12
    static let spacingLarge: CGFloat = 20
    static let pageInset: CGFloat = 14
    static let sectionGap: CGFloat = 24

    static let pressAnimation = Animation.spring(response: 0.24, dampingFraction: 0.90)
}

extension View {
    func aloCard(radius: CGFloat = AloTheme.radiusLarge) -> some View {
        background(AloTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AloTheme.border, lineWidth: 1)
            )
    }
}
