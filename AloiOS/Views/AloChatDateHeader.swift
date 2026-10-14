import SwiftUI
import Combine

/// Telegram's service date: 34 pt section, 22 pt capsule, 13 pt medium text.
/// Keep this separate from the interactive glass used by the composer/header.
enum AloChatDateMetrics {
    static let sectionHeight: CGFloat = 34
    static let capsuleHeight: CGFloat = 22
    static let horizontalInset: CGFloat = 6
    static let idleDelay: Duration = .milliseconds(300)
    static let appearDuration = 0.3
    static let disappearDuration = 0.4
}

struct AloChatDatePlacement: Equatable {
    let headerID: Int
    let label: String
    let sectionY: CGFloat
}

enum AloChatDateLayout {
    /// One header per day. Its natural position takes over when it returns to
    /// view; the next day pushes the pinned header out instead of overlapping it.
    static func placement(anchor: CGFloat, rows: [Int: CGRect], headers: [Int: CGRect],
                          headerIDs: [Int: Int], labels: [Int: String]) -> AloChatDatePlacement? {
        guard let row = rows.filter({ $0.value.maxY > anchor })
            .min(by: { $0.value.minY < $1.value.minY }),
              let headerID = headerIDs[row.key], let label = labels[headerID], !label.isEmpty else { return nil }
        if let natural = headers[headerID], natural.minY >= anchor { return nil }
        let nextY = headers.filter { $0.key != headerID && $0.value.minY >= anchor }
            .map(\.value.minY).min()
        let y = min(anchor, nextY.map { $0 - AloChatDateMetrics.sectionHeight } ?? anchor)
        return AloChatDatePlacement(headerID: headerID, label: label, sectionY: y)
    }
}

/// Only date subviews observe this object. Scroll geometry must not invalidate
/// the whole message history on every frame, or restart a recording/player.
@MainActor
final class AloChatDateHeaderController: ObservableObject {
    @Published private(set) var placement: AloChatDatePlacement?
    @Published private(set) var isVisible = false
    private var isScrolling = false
    private var hideTask: Task<Void, Never>?
    private var reduceMotion = false

    func update(anchor: CGFloat, rows: [Int: CGRect], headers: [Int: CGRect],
                snapshot: AloChatHistorySnapshot, reduceMotion: Bool, contentTranslationY: CGFloat = 0) {
        self.reduceMotion = reduceMotion
        let next = AloChatDateLayout.placement(anchor: anchor - contentTranslationY, rows: rows, headers: headers,
            headerIDs: snapshot.dateHeaderIDs, labels: snapshot.dateHeaderLabels).map {
                AloChatDatePlacement(headerID: $0.headerID, label: $0.label, sectionY: $0.sectionY + contentTranslationY)
            }
        if placement != next {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { placement = next }
        }
        if isScrolling { setVisible(next != nil) }
        else if next == nil { setVisible(false) }
    }

    func scrollingChanged(_ scrolling: Bool) {
        hideTask?.cancel()
        hideTask = nil
        isScrolling = scrolling
        if scrolling { setVisible(placement != nil) }
        else if isVisible {
            hideTask = Task { [weak self] in
                do { try await Task.sleep(for: AloChatDateMetrics.idleDelay) }
                catch { return }
                guard let self, !self.isScrolling else { return }
                self.setVisible(false)
                self.hideTask = nil
            }
        }
    }

    func reset() {
        hideTask?.cancel()
        hideTask = nil
        isScrolling = false
        placement = nil
        isVisible = false
    }

    private func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: visible
            ? AloChatDateMetrics.appearDuration : AloChatDateMetrics.disappearDuration)) {
            isVisible = visible
        }
    }

    deinit { hideTask?.cancel() }
}

struct AloChatDateFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct AloChatDatePill: View {
    let label: String
    var isFloating = false
    @ScaledMetric(relativeTo: .caption) private var fontSize: CGFloat = 13
    private var accessibility = AloVisualAccessibility()

    init(label: String, isFloating: Bool = false) {
        self.label = label
        self.isFloating = isFloating
    }

    var body: some View {
        Text(label)
            .font(.system(size: min(18, fontSize), weight: .medium))
            .foregroundStyle(.white.opacity(0.94))
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, AloChatDateMetrics.horizontalInset)
            .frame(minHeight: AloChatDateMetrics.capsuleHeight)
            .background {
                if isFloating && !accessibility.reduceTransparency && !accessibility.increasedContrast {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(.black.opacity(0.4))
                } else {
                    Capsule().fill(accessibility.reduceTransparency || accessibility.increasedContrast
                        ? AloTheme.surface : .black.opacity(0.55))
                }
            }
            .accessibilityAddTraits(.isHeader)
    }
}

struct AloChatInlineDateHeader: View {
    @ObservedObject var controller: AloChatDateHeaderController
    let id: Int
    let label: String

    var body: some View {
        AloChatDatePill(label: label)
            .opacity(controller.placement?.headerID == id ? 0 : 1)
            .frame(height: AloChatDateMetrics.sectionHeight)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: AloChatDateFramesKey.self,
                        value: [id: geometry.frame(in: .named("conversationScroll"))])
                }
            }
            .accessibilityIdentifier("alo.chat.date.\(id)")
            .accessibilityHidden(controller.placement?.headerID == id)
    }
}

struct AloChatFloatingDateHeader: View {
    @ObservedObject var controller: AloChatDateHeaderController
    let anchor: CGFloat
    var isSuppressed = false

    var body: some View {
        GeometryReader { geometry in
            if let placement = controller.placement, controller.isVisible, !isSuppressed {
                AloChatDatePill(label: placement.label, isFloating: true)
                    .frame(maxWidth: min(320, geometry.size.width - 28))
                    .frame(height: AloChatDateMetrics.sectionHeight)
                    .position(x: geometry.size.width / 2,
                              y: placement.sectionY + AloChatDateMetrics.sectionHeight / 2)
                    .accessibilityIdentifier("alo.chat.floating-date")
                    .mask(alignment: .top) {
                        Rectangle().padding(.top, max(0, anchor))
                    }
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }
}
