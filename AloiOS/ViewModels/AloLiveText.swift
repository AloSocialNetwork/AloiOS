import Combine
import SwiftUI

/// Text a field edits letter by letter (a message, a comment, a post, a search). It lives outside `AloAppModel`'s
/// published state: a typed letter redraws the field's own screen part (`AloLiveTextReader`), not every screen that
/// watches the app.
@MainActor
final class AloLiveText: ObservableObject {
    @Published var text = ""
}

/// Redraws its content when the text changes; the views around it do not watch the text. It also redraws with the
/// view that builds it: SwiftUI cannot compare the content closure and kept a stale composer (no reply bar) without
/// the per-build token.
struct AloLiveTextReader<Content: View>: View {
    @ObservedObject var text: AloLiveText
    @ViewBuilder let content: () -> Content
    private let build = UUID()

    init(text: AloLiveText, @ViewBuilder content: @escaping () -> Content) {
        self.text = text
        self.content = content
    }

    var body: some View { content() }
}
