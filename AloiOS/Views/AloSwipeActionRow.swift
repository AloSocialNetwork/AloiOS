import SwiftUI

struct AloSwipeAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let color: Color
    let perform: () -> Void
}

/// Telegram-style row swipe: drag left for the trailing actions, right for the leading ones. A long
/// drag past the middle of the row runs the primary action (last trailing / first leading).
/// Only one row is open at a time (`openedID`). Vertical scrolling is left to the scroll view.
struct AloSwipeActionRow<Content: View>: View {
    let id: String
    @Binding var openedID: String?
    var leading: [AloSwipeAction] = []
    var trailing: [AloSwipeAction] = []
    var isEnabled = true
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var dragBase: CGFloat = 0
    @State private var isDragging = false
    @State private var width: CGFloat = 402

    private let actionWidth: CGFloat = 80

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86) }

    var body: some View {
        ZStack {
            actionsBackground
            content()
                .background(AloTheme.background)
                .offset(x: offset)
                .overlay {
                    if offset != 0 && !isDragging {
                        // While open, a tap closes the row instead of opening the chat.
                        Color.clear.contentShape(Rectangle()).offset(x: offset).onTapGesture { close() }
                    }
                }
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .simultaneousGesture(isEnabled ? drag : nil)
        .onChange(of: openedID) { _, value in
            if value != id, offset != 0 { withAnimation(spring) { offset = 0 } }
        }
        .accessibilityAction(named: Text(trailing.last?.title ?? "")) { trailing.last?.perform() }
        .accessibilityAction(named: Text(leading.first?.title ?? "")) { leading.first?.perform() }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                if !isDragging {
                    // Take over only clearly horizontal drags; everything else scrolls the list.
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
                    isDragging = true
                    dragBase = offset
                    openedID = id
                }
                var next = dragBase + value.translation.width
                let maxLeading = leading.isEmpty ? 0 : width
                let maxTrailing = trailing.isEmpty ? 0 : width
                next = min(max(next, -maxTrailing), maxLeading)
                // Rubber band when there is nothing on that side.
                if next > 0 && leading.isEmpty { next = 0 }
                if next < 0 && trailing.isEmpty { next = 0 }
                offset = next
            }
            .onEnded { value in
                guard isDragging else { return }
                isDragging = false
                let predicted = dragBase + value.predictedEndTranslation.width
                let openTrailing = actionWidth * CGFloat(trailing.count)
                let openLeading = actionWidth * CGFloat(leading.count)
                if offset < -width * 0.55, let action = trailing.last {
                    withAnimation(spring) { offset = 0 }
                    openedID = nil
                    action.perform()
                } else if offset > width * 0.55, let action = leading.first {
                    withAnimation(spring) { offset = 0 }
                    openedID = nil
                    action.perform()
                } else if !trailing.isEmpty, offset < -openTrailing * 0.4 || predicted < -openTrailing * 1.2 {
                    withAnimation(spring) { offset = -openTrailing }
                } else if !leading.isEmpty, offset > openLeading * 0.4 || predicted > openLeading * 1.2 {
                    withAnimation(spring) { offset = openLeading }
                } else {
                    close()
                }
            }
    }

    private func close() {
        withAnimation(spring) { offset = 0 }
        if openedID == id { openedID = nil }
    }

    private var actionsBackground: some View {
        HStack(spacing: 0) {
            if offset > 0 { actionStrip(leading, alignment: .leading) }
            Spacer(minLength: 0)
            if offset < 0 { actionStrip(trailing, alignment: .trailing) }
        }
    }

    private func actionStrip(_ actions: [AloSwipeAction], alignment: HorizontalAlignment) -> some View {
        let revealed = abs(offset)
        let ordered = alignment == .leading ? actions : actions
        return HStack(spacing: 0) {
            ForEach(ordered) { action in
                Button {
                    close()
                    action.perform()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: action.systemImage).font(.system(size: 21, weight: .regular))
                        Text(action.title).font(.system(size: 12, weight: .regular)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(action.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.title)
            }
        }
        // The strip is as wide as the drag, so a long drag fills the row with the primary colour.
        .frame(width: max(revealed, 0))
        .clipped()
    }
}
