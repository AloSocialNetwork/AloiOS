import SwiftUI

/// The editor of a published post: its text (the time stays, the post gets «изменено»).
struct AloPostEditSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let post: AloPost
    @State private var text: String
    @State private var problem = ""
    @State private var saving = false
    private static let limit = 1200

    init(post: AloPost) {
        self.post = post
        _text = State(initialValue: post.body)
    }

    private var canSave: Bool {
        !saving && text.trimmingCharacters(in: .whitespacesAndNewlines) != post.body.trimmingCharacters(in: .whitespacesAndNewlines)
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !post.media.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Текст поста", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .onChange(of: text) { _, value in
                            if value.count > Self.limit { text = String(value.prefix(Self.limit)) }
                        }
                        .accessibilityIdentifier("alo.post.edit.text")
                } footer: {
                    Text("\(text.count) из \(Self.limit). Время публикации не изменится, у поста появится пометка «изменено».")
                }
                if !problem.isEmpty {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Изменить пост")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        saving = true
                        problem = ""
                        Task {
                            let failure = await app.editPost(post, body: text)
                            saving = false
                            if let failure { problem = failure } else { dismiss() }
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("alo.post.edit.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The last row of a list that has more pages: it only appears when the person has scrolled close to the end, which is the moment to ask for
/// the next page. It goes away once the list has no more.
struct AloLoadMoreRow: View {
    @EnvironmentObject private var app: AloAppModel
    let list: AloPagedList
    let loaded: Int

    var body: some View {
        if loaded > 0, !app.pagedListsEnded.contains(list) {
            HStack {
                Spacer()
                if app.pagedListsLoading.contains(list) { ProgressView() }
                Spacer()
            }
            .frame(height: 56)
            .onAppear { app.loadMore(list) }
            // Asks again when a page arrived and this row is still on screen.
            .onChange(of: loaded) { _, _ in app.loadMore(list) }
            .accessibilityHidden(true)
        }
    }
}
