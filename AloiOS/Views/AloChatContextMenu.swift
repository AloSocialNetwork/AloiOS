import SwiftUI
import UIKit

/// Read the originating row once, at activation. Scrolling does not publish
/// a dictionary of every row's coordinates back into the inbox.
@MainActor final class AloContextSourceAnchor {
    weak var view: UIView?
    var frame: CGRect? { view?.convert(view?.bounds ?? .zero, to: nil) }
}

struct AloContextSourceMarker: UIViewRepresentable {
    let anchor: AloContextSourceAnchor
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { anchor.view = view }
}

/// A focused message and its controls share an edge; the action list is not
/// a second full-width card. Frames are local to the overlay's safe viewport.
struct AloChatContextLayout {
    let reactionFrame: CGRect
    let previewFrame: CGRect
    let menuFrame: CGRect

    static func make(size: CGSize, source: CGRect, previewHeight: CGFloat,
                     menuHeight: CGFloat, reactionHeight: CGFloat, outgoing: Bool,
                     expanded: Bool) -> Self {
        let margin: CGFloat = 12
        let gap: CGFloat = 8
        let width = max(44, size.width - margin * 2)
        let previewWidth = min(max(44, source.width), width)
        let reactionWidth = min(378, width)
        let reactionHeight = min(reactionHeight, max(0, size.height - margin * 2 - gap * 2 - (expanded ? 44 : 88)))
        let previewLimit = max(44, min(340, size.height * 0.48,
            size.height - margin * 2 - reactionHeight - gap * 2 - (expanded ? 0 : 44)))
        let previewHeight = min(max(44, previewHeight), previewLimit)
        let gaps = reactionHeight > 0 ? gap * 2 : gap
        let menuHeight = expanded ? 0 : min(menuHeight,
            max(44, size.height - margin * 2 - reactionHeight - previewHeight - gaps))
        let total = reactionHeight + previewHeight + menuHeight + (expanded ? gap : gaps)
        let preferredTop = source.minY - reactionHeight - (reactionHeight > 0 ? gap : 0)
        let top = min(max(margin, preferredTop), max(margin, size.height - margin - total))

        func x(_ itemWidth: CGFloat) -> CGFloat {
            let preferred = outgoing ? source.maxX - itemWidth : source.minX
            return min(max(margin, preferred), max(margin, size.width - margin - itemWidth))
        }
        let reaction = CGRect(x: x(reactionWidth), y: top, width: reactionWidth, height: reactionHeight)
        let preview = CGRect(x: x(previewWidth), y: top + reactionHeight + (reactionHeight > 0 ? gap : 0),
                             width: previewWidth, height: previewHeight)
        let menuWidth = min(250, width)
        return Self(reactionFrame: reaction, previewFrame: preview,
                    menuFrame: CGRect(x: x(menuWidth), y: preview.maxY + gap,
                                      width: menuWidth, height: menuHeight))
    }
}

/// Context menus use one dark, bounded material on both supported iOS paths.
/// Unlike navigation controls they do not need a native glass interaction host.
struct AloContextMenuSurface: ViewModifier {
    var radius: CGFloat = 24
    private var accessibility = AloVisualAccessibility()
    init(radius: CGFloat = 24) { self.radius = radius }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            if accessibility.reduceTransparency || accessibility.increasedContrast {
                shape.fill(AloTheme.surface)
            } else {
                AloBlackChatBackdrop(darkness: 0.12, opaque: false)
                    .clipShape(shape)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(accessibility.increasedContrast ? 0.6 : 0.10), lineWidth: 0.5)
            .allowsHitTesting(false))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
    }
}

struct AloContextActionPressStyle: ButtonStyle {
    private var accessibility = AloVisualAccessibility()
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.10 : 0))
            .animation(accessibility.reduceMotion || configuration.isPressed ? nil : AloPressFeedback.release,
                       value: configuration.isPressed)
    }
}

enum AloContextMotion {
    // Telegram's presentation is a near-critically damped spring. Alo runs it faster (0.30 s
    // instead of 0.42 s) and holds for 0.26 s instead of 0.35 s, so the menu feels immediate.
    static let enter = Animation.spring(response: 0.30, dampingFraction: 1)
    static let exit = Animation.easeInOut(duration: 0.15)
}

struct AloReactionChoice: Identifiable {
    let emoji: String
    let names: String
    var id: String { emoji }
}

enum AloReactionCatalog {
    // Only supported Unicode reactions. No pretend Premium packs or reactor
    // identities: the current API supplies emoji/count/reactedByMe only.
    static let choices: [AloReactionChoice] = [
        .init(emoji: "❤️", names: "сердце любовь heart love"),
        .init(emoji: "🥰", names: "любовь улыбка love smile"),
        .init(emoji: "😭", names: "плач слёзы cry tears"),
        .init(emoji: "👀", names: "глаза смотрю eyes"),
        .init(emoji: "💘", names: "сердце любовь стрела love"),
        .init(emoji: "❤️‍🔥", names: "сердце огонь fire"),
        .init(emoji: "🍓", names: "клубника strawberry"),
        .init(emoji: "💅", names: "ногти nail"),
        .init(emoji: "🕊", names: "голубь мир dove"),
        .init(emoji: "🤩", names: "звёзды восторг star"),
        .init(emoji: "😂", names: "смех laugh"),
        .init(emoji: "👎", names: "нет плохо dislike down"),
        .init(emoji: "🍾", names: "шампанское праздник champagne"),
        .init(emoji: "😁", names: "улыбка smile"),
        .init(emoji: "😢", names: "грусть слёзы sad"),
        .init(emoji: "💔", names: "разбитое сердце heart"),
        .init(emoji: "👍", names: "да хорошо like up"),
        .init(emoji: "🔥", names: "огонь fire"),
        .init(emoji: "👏", names: "аплодисменты clap"),
        .init(emoji: "🤔", names: "думаю think"),
        .init(emoji: "🤯", names: "взрыв mind blown"),
        .init(emoji: "😱", names: "страх shock"),
        .init(emoji: "😡", names: "злость angry"),
        .init(emoji: "🎉", names: "праздник party"),
        .init(emoji: "🤮", names: "тошно sick"),
        .init(emoji: "💩", names: "poop"),
        .init(emoji: "🙏", names: "спасибо молитва thanks"),
        .init(emoji: "👌", names: "хорошо okay"),
        .init(emoji: "🤡", names: "клоун clown"),
        .init(emoji: "🥱", names: "сон зевать sleep"),
        .init(emoji: "😉", names: "подмигнуть wink"),
        .init(emoji: "😍", names: "любовь love"),
        .init(emoji: "💯", names: "сто hundred"),
        .init(emoji: "🤝", names: "рукопожатие handshake"),
        .init(emoji: "😎", names: "круто cool"),
        .init(emoji: "🤗", names: "обнять hug"),
        .init(emoji: "🫡", names: "привет salute"),
        .init(emoji: "🤪", names: "веселье crazy"),
        .init(emoji: "😴", names: "сон sleep"),
        .init(emoji: "🤓", names: "умник nerd"),
        .init(emoji: "👻", names: "призрак ghost"),
        .init(emoji: "🎃", names: "тыква pumpkin"),
        .init(emoji: "⚡", names: "молния lightning"),
        .init(emoji: "🏆", names: "кубок trophy")
    ]

    static func search(_ query: String) -> [AloReactionChoice] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? choices : choices.filter {
            $0.emoji.contains(query) || $0.names.localizedCaseInsensitiveContains(query)
        }
    }
}

struct AloContextReactionPicker: View {
    let expanded: Bool
    let selectedEmoji: String?
    let accent: Color
    let onExpand: () -> Void
    let onSelect: (String) -> Void
    let onInspect: (String) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            if expanded {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").accessibilityHidden(true)
                        TextField("Поиск реакций", text: $query)
                            .font(.body).focused($searchFocused)
                            .submitLabel(.done).onSubmit { searchFocused = false }
                            .accessibilityIdentifier("alo.reactions.search")
                        Button { searchFocused = false; onExpand() } label: {
                            Image(systemName: "chevron.up").frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(AloChatPressStyle())
                        .accessibilityLabel("Свернуть реакции")
                    }
                    .foregroundStyle(AloTheme.text)
                    .padding(.leading, 12)
                    .background(.white.opacity(0.08), in: Capsule())
                    .padding(.horizontal, 12).padding(.top, 10)
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: 0),
                                                 count: max(1, Int((geometry.size.width - 12) / 44))), spacing: 0) {
                            ForEach(AloReactionCatalog.search(query)) { choice in button(choice.emoji) }
                        }
                        .padding(.horizontal, 6)
                        if AloReactionCatalog.search(query).isEmpty {
                            Text("Реакции не найдены").font(.subheadline).foregroundStyle(AloTheme.muted)
                                .padding(16)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                .modifier(AloContextMenuSurface(radius: 24))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("alo.reactions.expanded")
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(AloReactionCatalog.choices.prefix(max(1, min(7, Int((geometry.size.width - 12) / 44) - 1))))) { choice in
                        button(choice.emoji)
                    }
                    Button(action: onExpand) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AloTheme.text)
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.12), in: Circle())
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(AloChatPressStyle())
                    .accessibilityLabel("Все реакции")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(AloContextMenuSurface(radius: 24))
            }
        }
    }

    private func button(_ emoji: String) -> some View {
        AloContextReactionButton(emoji: emoji, selected: selectedEmoji == emoji,
                                 accent: accent, onSelect: { onSelect(emoji) },
                                 onInspect: { onInspect(emoji) })
    }
}

private struct AloContextReactionButton: View {
    let emoji: String
    let selected: Bool
    let accent: Color
    let onSelect: () -> Void
    let onInspect: () -> Void
    private var accessibility = AloVisualAccessibility()

    init(emoji: String, selected: Bool, accent: Color, onSelect: @escaping () -> Void,
         onInspect: @escaping () -> Void) {
        self.emoji = emoji
        self.selected = selected
        self.accent = accent
        self.onSelect = onSelect
        self.onInspect = onInspect
    }

    var body: some View {
        AloReactionTouchControl(emoji: emoji, selected: selected, reduceMotion: accessibility.reduceMotion,
                                onSelect: onSelect, onInspect: onInspect)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(selected ? accent.opacity(0.24) : .clear, in: Circle())
    }
}

/// Native failure ordering owns this gesture pair. SwiftUI's Button touch-up
/// can otherwise be delivered after its hold callback has removed the picker.
private struct AloReactionTouchControl: UIViewRepresentable {
    let emoji: String
    let selected: Bool
    let reduceMotion: Bool
    let onSelect: () -> Void
    let onInspect: () -> Void

    func makeUIView(context: Context) -> AloReactionTouchButton { AloReactionTouchButton() }
    func updateUIView(_ view: AloReactionTouchButton, context: Context) {
        view.setTitle(emoji, for: .normal)
        view.accessibilityLabel = "Реакция \(emoji)"
        view.accessibilityTraits = selected ? [.button, .selected] : .button
        view.reduceMotion = reduceMotion
        view.onSelect = onSelect
        view.onInspect = onInspect
    }
    static func dismantleUIView(_ view: AloReactionTouchButton, coordinator: ()) {
        view.onSelect = nil
        view.onInspect = nil
    }
}

private final class AloReactionTouchButton: UIButton {
    var onSelect: (() -> Void)?
    var onInspect: (() -> Void)?
    var reduceMotion = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel?.font = .systemFont(ofSize: 29)
        backgroundColor = .clear
        isAccessibilityElement = true
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 12
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: hold)
        addGestureRecognizer(hold)
        addGestureRecognizer(tap)
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Посмотреть реакцию", target: self,
                                                                  selector: #selector(inspectAccessibility))]
    }

    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet {
            let alpha: CGFloat = isHighlighted ? 0.76 : 1
            if isHighlighted || reduceMotion {
                titleLabel?.layer.removeAllAnimations()
                titleLabel?.alpha = alpha
            } else {
                UIView.animate(withDuration: 0.16, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.titleLabel?.alpha = alpha
                }
            }
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        AloHaptics.selection()
        onSelect?()
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        AloHaptics.impact(.light)
        onInspect?()
    }
    override func accessibilityActivate() -> Bool {
        AloHaptics.selection()
        onSelect?()
        return true
    }
    @objc private func inspectAccessibility() -> Bool {
        onInspect?()
        return true
    }
}
