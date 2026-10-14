import SwiftUI
import UIKit

/// Shared social chrome. Materials belong to the controls, not to a full-width shelf.
enum AloSocialMetrics {
    static let inset: CGFloat = 16
    /// Minimum touch target. The visible controls below are smaller and share one rhythm.
    static let controlHeight: CGFloat = 44
    static let segmentHeight: CGFloat = 38
    static let searchHeight: CGFloat = 40
    static let searchSpacing: CGFloat = 10
    static let headerControlSpacing: CGFloat = 12
    static let glassButton: CGFloat = 38
    static let titleSize: CGFloat = 28
    static let bottomClearance: CGFloat = 88
    // Utility chrome grows with Dynamic Type, but never takes the whole viewport.
    // Reading content remains unbounded and independently scalable.
    static let maximumControlHeight: CGFloat = 60
    static let maximumUtilitySize: CGFloat = 21
    static let maximumTitleSize: CGFloat = 32
}

/// Progressive blur plus a soft dim: content dissolves under the title instead
/// of being cut by an opaque plate, and stays readable behind the glass controls.
struct AloSocialTitleShade: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).opacity(0.5)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                    .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            AloEdgeProfile.gradient(top: true, peak: 0.94, solid: 0.3)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Mirror of the title shade for the tab bar: content blurs and dims toward the screen edge.
struct AloSocialBottomShade: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).opacity(0.5)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.5),
                    .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
            AloEdgeProfile.gradient(top: false, peak: 0.85, solid: 0.3)
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Settings, pushed as a full screen (not a sheet: a sheet left a strip of the previous screen
/// above it).
struct AloSocialSettingsSheet: View {
    @EnvironmentObject private var app: AloAppModel
    var initialPage: ProfileSettingsPage = .root

    var body: some View {
        ProfileEditSheet(user: app.bootstrap?.me,
            notificationSettings: app.bootstrap?.notificationSettings ?? .default,
            privacySettings: app.bootstrap?.privacySettings ?? .default,
            onApplyNotifications: { app.updateNotificationSettings($0) },
            onApplyPrivacy: { app.updatePrivacy(settings: $0) }, onLogout: { app.logout() },
            initialPage: initialPage)
    }
}

/// Pushed screens that draw their own header hide the navigation bar, and that also switches off
/// the system edge swipe back. This keeps the swipe for as long as the screen is on top.
struct AloNativeBackSwipe: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var recognizer: UIGestureRecognizer?
        private weak var systemDelegate: UIGestureRecognizerDelegate?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let pop = navigationController?.interactivePopGestureRecognizer, pop.delegate !== self else { return }
            recognizer = pop
            systemDelegate = pop.delegate
            pop.delegate = self
            pop.isEnabled = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Hand the recognizer back, so the root screen never starts a swipe with nothing to pop.
            if let recognizer, recognizer.delegate === self { recognizer.delegate = systemDelegate }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

struct AloSocialSettingsButton: View {
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(AloTheme.muted)
                .frame(width: AloSocialMetrics.glassButton, height: AloSocialMetrics.glassButton)
                .modifier(AloChatGlass(interactive: false, role: .chrome))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(AloControlPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

struct AloSocialHeader: View {
    let title: String
    let subtitle: String
    let settingsLabel: String
    let identifier: String
    let onSettings: () -> Void
    @ScaledMetric(relativeTo: .title) private var titleSize = AloSocialMetrics.titleSize

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AloSocialTitle(text: title, size: min(titleSize, AloSocialMetrics.maximumTitleSize))
                .accessibilityIdentifier(identifier + ".title")
            // The connection state sits beside the title, so it never changes the header height.
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption.weight(.medium)).foregroundStyle(AloTheme.accent)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            AloSocialSettingsButton(label: settingsLabel, identifier: identifier + ".settings", action: onSettings)
        }
        .frame(minHeight: AloSocialMetrics.controlHeight)
        .foregroundStyle(AloTheme.text)
        .padding(.horizontal, AloSocialMetrics.inset)
    }
}

/// The one screen-title style: used by feed, search, chats, notifications, profile.
struct AloSocialTitle: View {
    let text: String
    var size: CGFloat = AloSocialMetrics.titleSize
    var rounded = false

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: rounded ? .rounded : .default))
            .lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityAddTraits(.isHeader)
    }
}

struct AloSocialSegments<Value: Hashable>: View {
    let values: [Value]
    @Binding var selected: Value
    let title: (Value) -> String
    let identifier: (Value) -> String
    private var accessibility = AloVisualAccessibility()
    @ScaledMetric(relativeTo: .subheadline) private var labelSize = 15
    @ScaledMetric(relativeTo: .subheadline) private var height = AloSocialMetrics.controlHeight

    init(values: [Value], selected: Binding<Value>, title: @escaping (Value) -> String,
         identifier: @escaping (Value) -> String) {
        self.values = values
        _selected = selected
        self.title = title
        self.identifier = identifier
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button {
                    withAnimation(accessibility.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
                        selected = value
                    }
                } label: {
                    Text(title(value))
                        .font(.system(size: min(labelSize, AloSocialMetrics.maximumUtilitySize), weight: .semibold))
                        .foregroundStyle(selected == value ? AloTheme.text : AloTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: min(height, AloSocialMetrics.maximumControlHeight))
                        .contentShape(Capsule())
                }
                .buttonStyle(AloFeedPressStyle())
                .accessibilityIdentifier(identifier(value))
                .accessibilityAddTraits(selected == value ? .isSelected : [])
            }
        }
        .background(alignment: .leading) {
            GeometryReader { geometry in
                let width = geometry.size.width / CGFloat(max(1, values.count))
                let position = Double(values.firstIndex(of: selected) ?? 0)
                AloGlassSelection()
                    .frame(width: width, height: max(0, geometry.size.height - 8))
                    .modifier(AloSocialSelectionTravel(position: position, enabled: !accessibility.reduceMotion))
                    .offset(x: CGFloat(position) * width, y: 4)
            }.allowsHitTesting(false)
        }
        .padding(.horizontal, 4)
        .modifier(AloChatGlass(interactive: false, role: .chrome))
        .animation(accessibility.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: selected)
    }
}

/// Preserve the feed's subtle travel blur on the small highlight only — never on rows/text.
private struct AloSocialSelectionTravel: AnimatableModifier {
    var position: Double
    let enabled: Bool
    var animatableData: Double {
        get { position }
        set { position = newValue }
    }
    func body(content: Content) -> some View {
        let fraction = position - floor(position)
        let travel = enabled ? max(0, sin(.pi * fraction)) : 0
        content.scaleEffect(x: 1 + travel * 0.035, y: 1).blur(radius: travel * 1.6)
    }
}

struct AloSocialSearchField: View {
    @Binding var text: String
    var identifier = "alo.search"
    var focused: Binding<Bool>? = nil
    @ScaledMetric(relativeTo: .subheadline) private var height = AloSocialMetrics.searchHeight
    @ScaledMetric(relativeTo: .subheadline) private var labelSize = 16

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17)).foregroundStyle(AloTheme.muted)
                .accessibilityHidden(true)
            AloSocialNativeSearchInput(text: $text, fontSize: min(labelSize, AloSocialMetrics.maximumUtilitySize),
                identifier: identifier, focused: focused)
                .frame(height: min(height, AloSocialMetrics.maximumControlHeight))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: min(height, AloSocialMetrics.maximumControlHeight))
        .modifier(AloChatGlass(interactive: false, role: .chrome))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier + ".field")
        .modifier(AloSocialControlGeometry())
        .frame(minHeight: AloSocialMetrics.controlHeight)
    }
}

/// UITextField owns the marked-text transaction while the keyboard is editing. The clear button is
/// our own right view: from iOS 26 the system one is no longer a plain UIButton that can be labelled.
private struct AloSocialNativeSearchInput: UIViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let identifier: String
    var focused: Binding<Bool>?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focused: focused) }
    func makeUIView(context: Context) -> AloSocialSearchUITextField {
        let field = AloSocialSearchUITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.clearButtonMode = .never
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.keyboardAppearance = .dark
        field.backgroundColor = .clear
        field.textColor = UIColor(AloTheme.text)
        field.accessibilityIdentifier = identifier + ".input"
        field.accessibilityLabel = "Поиск людей, сообществ и сообщений"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let clear = UIButton(type: .system)
        clear.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clear.tintColor = UIColor(AloTheme.muted)
        clear.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        clear.accessibilityLabel = "Очистить поиск"
        clear.accessibilityIdentifier = identifier + ".clear"
        clear.addTarget(context.coordinator, action: #selector(Coordinator.clear(_:)), for: .touchUpInside)
        field.rightView = clear
        field.rightViewMode = .never
        context.coordinator.field = field
        return field
    }
    func updateUIView(_ field: AloSocialSearchUITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.focused = focused
        if field.text != text { field.text = text }
        field.font = .systemFont(ofSize: fontSize)
        field.attributedPlaceholder = NSAttributedString(string: "Поиск", attributes: [.foregroundColor: UIColor(AloTheme.muted)])
        context.coordinator.updateClear()
        if let focused, focused.wrappedValue != field.isFirstResponder, field.window != nil {
            if focused.wrappedValue { field.becomeFirstResponder() }
            else { field.resignFirstResponder() }
        }
    }
    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var focused: Binding<Bool>?
        weak var field: UITextField?
        init(text: Binding<String>, focused: Binding<Bool>?) { self.text = text; self.focused = focused }
        @objc func changed(_ field: UITextField) {
            text.wrappedValue = field.text ?? ""
            updateClear()
        }
        @objc func clear(_ sender: UIButton) {
            field?.text = ""
            text.wrappedValue = ""
            updateClear()
        }
        func updateClear() {
            guard let field else { return }
            field.rightViewMode = (field.text ?? "").isEmpty ? .never : .always
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
        func textFieldDidBeginEditing(_ textField: UITextField) {
            if focused?.wrappedValue == false { focused?.wrappedValue = true }
        }
        func textFieldDidEndEditing(_ textField: UITextField) {
            if focused?.wrappedValue == true { focused?.wrappedValue = false }
        }
    }
}

private final class AloSocialSearchUITextField: UITextField {
    override func rightViewRect(forBounds bounds: CGRect) -> CGRect {
        CGRect(x: max(0, bounds.width - 44), y: max(0, (bounds.height - 44) / 2), width: 44, height: 44)
    }
}

/// DEBUG-only proof of the rendered material's bounds. Accessibility containers
/// may report the union of glyphs instead of the surrounding control surface.
struct AloSocialControlGeometry: ViewModifier {
    #if DEBUG
    @State private var frame = CGRect.zero
    #endif
    func body(content: Content) -> some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                .modifier(AloMessageDesignGeometryModifier(frame: frame))
        } else { content }
        #else
        content
        #endif
    }
}

/// The list keeps its full viewport: rows travel behind the floating header.
/// Only the initial content inset is measured; no per-row/per-frame layout polling.
struct AloSocialScrollScreen<Header: View, Rows: View>: View {
    let identifier: String
    @ViewBuilder let header: () -> Header
    @ViewBuilder let rows: () -> Rows
    @State private var headerHeight: CGFloat = 120

    var body: some View {
        ScrollView {
            rows()
                .padding(.top, headerHeight + 8)
                .padding(.bottom, AloSocialMetrics.bottomClearance)
        }
        .clipped()
        .accessibilityIdentifier(identifier)
        .overlay(alignment: .top) {
            header().padding(.top, 8).padding(.bottom, 8)
                .background(alignment: .top) {
                    AloSocialTitleShade().padding(.bottom, -16).ignoresSafeArea(edges: .top)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { headerHeight = height }
                }
        }
    }
}

/// A compact visible button inside a full 44pt touch target, without native double padding.
struct AloSocialRequestButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    private var accessibility = AloVisualAccessibility()
    @ScaledMetric(relativeTo: .subheadline) private var visualHeight = 32

    init(prominent: Bool = false) { self.prominent = prominent }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : AloTheme.text)
            .padding(.horizontal, 12)
            .frame(minHeight: visualHeight)
            .background(prominent ? AloTheme.outgoing : AloTheme.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AloTheme.border, lineWidth: prominent ? 0 : 1))
            .scaleEffect(configuration.isPressed && !accessibility.reduceMotion ? 0.97 : 1)
            .opacity(!enabled ? 0.5 : configuration.isPressed ? 0.8 : 1)
            .animation(accessibility.reduceMotion || configuration.isPressed ? nil : AloPressFeedback.release, value: configuration.isPressed)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
