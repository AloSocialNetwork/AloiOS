import SwiftUI

// Telegram's story privacy, archive and highlights ("Актуальное").

// MARK: - Publishing: who sees it and for how long

/// Shown after "Далее" in the story editor, as in Telegram: who may see the story, how long it
/// lives, then "Опубликовать".
struct AloStoryPublishSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Binding var audience: AloStoryAudience
    @Binding var selectedPeople: [AloEntitySummary]
    @Binding var lifetimeHours: Int
    let onPublish: () -> Void
    @State private var settings = AloStorySettings()
    @State private var picker: AloPeoplePickerRequest?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 0) {
                        ForEach(AloStoryAudience.allCases) { option in
                            audienceRow(option)
                            if option != AloStoryAudience.allCases.last {
                                Divider().overlay(AloTheme.border).padding(.leading, 62)
                            }
                        }
                    }
                    .background(AloTheme.surfaceRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("История исчезнет через")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(AloTheme.muted)
                        Picker("Срок жизни", selection: $lifetimeHours) {
                            ForEach([6, 12, 24, 48], id: \.self) { hours in Text("\(hours) ч").tag(hours) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("История исчезнет через \(lifetimeHours) часов")
                        .accessibilityIdentifier("alo.story.lifetime")
                    }

                    AloPrimaryButton(title: "Опубликовать", action: onPublish)
                        .disabled(audience == .selected && selectedPeople.isEmpty)
                        .accessibilityIdentifier("alo.story.publish-confirm")
                }
                .padding(16)
            }
            .navigationTitle("Кто увидит историю")
            .navigationBarTitleDisplayMode(.inline)
            .background(AloTheme.background)
            .navigationDestination(item: $picker) { request in
                AloPeoplePicker(title: request.title, initial: request.initial) { people in
                    Task { await apply(people, to: request.kind) }
                }
            }
        }
        .task { settings = (try? await app.storySettings()) ?? settings }
        .accessibilityIdentifier("alo.story.publish-sheet")
    }

    private func audienceRow(_ option: AloStoryAudience) -> some View {
        let chosen = audience == option
        return HStack(spacing: 12) {
            Image(systemName: option.symbol)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint(option), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                if let detail = detail(option) {
                    Button(detail) { openPicker(for: option) }
                        .font(.system(size: 14)).foregroundStyle(AloTheme.accent)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("alo.story.audience.edit.\(option.rawValue)")
                }
            }
            Spacer(minLength: 0)
            Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22)).foregroundStyle(chosen ? AloTheme.accent : AloTheme.muted.opacity(0.6))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture {
            audience = option
            if option == .selected, selectedPeople.isEmpty { openPicker(for: option) }
            if option == .closeFriends, settings.closeFriends.isEmpty { openPicker(for: option) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(chosen ? "выбрано" : "")
        .accessibilityIdentifier("alo.story.audience.\(option.rawValue)")
    }

    private func tint(_ option: AloStoryAudience) -> Color {
        switch option {
        case .everyone: return AloTheme.accent
        case .friends: return Color(red: 0.2, green: 0.72, blue: 0.4)
        case .closeFriends: return Color(red: 0.16, green: 0.78, blue: 0.35)
        case .selected: return Color(red: 0.58, green: 0.36, blue: 0.95)
        }
    }

    private func detail(_ option: AloStoryAudience) -> String? {
        switch option {
        case .everyone, .friends:
            return settings.hiddenFrom.isEmpty ? "Скрыть от…" : "Скрыто от: \(AloPeoplePicker.count(settings.hiddenFrom.count))"
        case .closeFriends:
            return settings.closeFriends.isEmpty ? "Выбрать близких друзей" : "\(AloPeoplePicker.count(settings.closeFriends.count)) · Изменить"
        case .selected:
            return selectedPeople.isEmpty ? "Выбрать людей" : "\(AloPeoplePicker.count(selectedPeople.count)) · Изменить"
        }
    }

    /// Editing an audience's list also chooses that audience, as in Telegram.
    private func openPicker(for option: AloStoryAudience) {
        audience = option
        switch option {
        case .everyone, .friends:
            picker = AloPeoplePickerRequest(kind: .hiddenFrom, title: "Скрыть историю от", initial: settings.hiddenFrom)
        case .closeFriends:
            picker = AloPeoplePickerRequest(kind: .closeFriends, title: "Близкие друзья", initial: settings.closeFriends)
        case .selected:
            picker = AloPeoplePickerRequest(kind: .selected, title: "Кому показать", initial: selectedPeople)
        }
    }

    private func apply(_ people: [AloEntitySummary], to kind: AloPeoplePickerRequest.Kind) async {
        switch kind {
        case .selected:
            selectedPeople = people
        case .closeFriends:
            settings.closeFriends = people
            try? await app.saveCloseFriends(people)
        case .hiddenFrom:
            settings.hiddenFrom = people
            try? await app.saveStoryHiddenFrom(people)
        }
    }
}

struct AloPeoplePickerRequest: Identifiable, Hashable {
    enum Kind: Hashable { case selected, closeFriends, hiddenFrom }
    let kind: Kind
    let title: String
    let initial: [AloEntitySummary]
    var id: String { "\(kind)-\(initial.map(\.id))" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Your friends with search and checkmarks; "Готово" hands back the chosen ones.
struct AloPeoplePicker: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: [AloEntitySummary]
    let onDone: ([AloEntitySummary]) -> Void
    @State private var people: [AloEntitySummary] = []
    @State private var chosen: Set<Int> = []
    @State private var query = ""
    @State private var isLoading = true

    private var shown: [AloEntitySummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return people }
        return people.filter { $0.name.lowercased().contains(needle) || $0.username.lowercased().contains(needle) }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if people.isEmpty {
                ContentUnavailableView("Пока нет друзей", systemImage: "person.2",
                                       description: Text("Добавьте друзей, и их можно будет выбрать здесь."))
            } else {
                List(shown) { person in
                    Button { toggle(person) } label: {
                        HStack(spacing: 12) {
                            AloAvatar(name: person.name, url: person.avatarUrl, size: 40, colorSeed: String(person.id))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                                if !person.username.isEmpty {
                                    Text(person.username.withAtPrefix).font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: chosen.contains(person.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(chosen.contains(person.id) ? AloTheme.accent : AloTheme.muted.opacity(0.6))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(person.username.isEmpty ? person.name : "\(person.name), \(person.username.withAtPrefix)")
                    .accessibilityAddTraits(chosen.contains(person.id) ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("alo.people.row")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .searchable(text: $query, prompt: "Поиск")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(chosen.isEmpty ? "Готово" : "Готово (\(chosen.count))") {
                    // Keep the friends order; people chosen earlier but no longer friends stay chosen.
                    let fromFriends = people.filter { chosen.contains($0.id) }
                    let kept = initial.filter { chosen.contains($0.id) && !people.contains($0) }
                    onDone(fromFriends + kept)
                    dismiss()
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("alo.people.done")
            }
        }
        .background(AloTheme.background)
        .task {
            chosen = Set(initial.map(\.id))
            people = (try? await app.friends()) ?? []
            isLoading = false
        }
    }

    private func toggle(_ person: AloEntitySummary) {
        if chosen.contains(person.id) { chosen.remove(person.id) } else { chosen.insert(person.id) }
    }

    static func count(_ value: Int) -> String {
        let mod10 = value % 10, mod100 = value % 100
        let word = mod10 == 1 && mod100 != 11 ? "человек"
            : (2...4).contains(mod10) && !(12...14).contains(mod100) ? "человека" : "человек"
        return "\(value) \(word)"
    }
}

// MARK: - Thumbnails

/// A 9:16 tile of a story: its picture (or video poster), or the text story's gradient.
struct AloStoryThumbnail: View {
    @Environment(\.aloAPIClient) private var api
    let story: AloStory
    var cornerRadius: CGFloat = 10

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The gradient takes exactly the space offered; the picture is laid over it and clipped,
        // so a tile never grows past its cell.
        LinearGradient(colors: [AloTheme.accent, Color(red: 0.42, green: 0.27, blue: 0.93)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                if let media = story.media.first,
                   let url = api?.absoluteURL(media.type == "video" ? media.posterUrl.ifBlank(media.url) : media.url) {
                    AloAsyncImage(url: url) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFill() } else { Color.clear }
                    }
                } else if !story.body.isEmpty {
                    Text(story.body).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).lineLimit(4).padding(6)
                }
            }
            .clipShape(shape)
            .accessibilityHidden(true)
    }
}

// MARK: - Highlights on the profile

/// The row of highlight circles under a profile header. Your own starts with "Новое" and
/// "Архив"; a circle plays its stories; a long press renames or deletes.
struct AloStoryHighlightsRow: View {
    @EnvironmentObject private var app: AloAppModel
    let user: AloEntitySummary
    let isOwn: Bool
    @State private var highlights: [AloStoryHighlight] = []
    @State private var playing: AloHighlightPlayback?
    @State private var archiveMode: AloStoryArchiveScreen.Mode?
    @State private var renaming: AloStoryHighlight?
    @State private var newTitle = ""

    var body: some View {
        Group {
            if isOwn || !highlights.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        if isOwn {
                            tile(title: "Новое", symbol: "plus") { archiveMode = .newHighlight }
                                .accessibilityIdentifier("alo.highlights.new")
                            tile(title: "Архив", symbol: "archivebox") { archiveMode = .browse }
                                .accessibilityIdentifier("alo.highlights.archive")
                        }
                        ForEach(highlights) { highlight in
                            highlightCircle(highlight)
                        }
                    }
                    .padding(.horizontal, AloSocialMetrics.inset)
                    .padding(.vertical, 6)
                }
            }
        }
        .task(id: "\(user.id)-\(app.highlightsRevision)") {
            highlights = (try? await app.highlights(userId: user.id)) ?? highlights
        }
        .fullScreenCover(item: $playing) { playback in
            AloStoryViewer(groups: [playback.group], startGroupID: playback.group.id, highlight: playback.highlight)
                .environmentObject(app)
                .environment(\.aloAPIClient, app.api)
        }
        .fullScreenCover(item: $archiveMode) { mode in
            AloStoryArchiveScreen(mode: mode)
                .environmentObject(app)
                .environment(\.aloAPIClient, app.api)
        }
        .alert("Название актуального", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $newTitle)
            Button("Отмена", role: .cancel) { renaming = nil }
            Button("Сохранить") {
                guard let highlight = renaming else { return }
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                renaming = nil
                guard !title.isEmpty else { return }
                Task { try? await app.renameHighlight(highlight, title: title) }
            }
        }
        .accessibilityIdentifier("alo.highlights")
    }

    private func tile(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(AloTheme.text)
                    .frame(width: 62, height: 62)
                    .background(AloTheme.surfaceRaised, in: Circle())
                    .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(AloTheme.text).lineLimit(1)
            }
            .frame(width: 70)
        }
        .buttonStyle(AloFeedPressStyle())
        .accessibilityLabel(title)
    }

    private func highlightCircle(_ highlight: AloStoryHighlight) -> some View {
        Button {
            playing = AloHighlightPlayback(highlight: highlight, user: user)
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let cover = highlight.cover {
                        AloStoryThumbnail(story: cover, cornerRadius: 31)
                    } else {
                        Circle().fill(AloTheme.surfaceRaised)
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(Circle())
                .padding(2)
                .overlay(Circle().stroke(AloTheme.border, lineWidth: 1.5))
                Text(highlight.title).font(.system(size: 12, weight: .medium)).foregroundStyle(AloTheme.text).lineLimit(1)
            }
            .frame(width: 70)
        }
        .buttonStyle(AloFeedPressStyle())
        .contextMenu {
            if isOwn {
                Button("Переименовать", systemImage: "pencil") {
                    newTitle = highlight.title
                    renaming = highlight
                }
                Button("Удалить актуальное", systemImage: "trash", role: .destructive) {
                    Task { try? await app.deleteHighlight(highlight) }
                }
            }
        }
        .accessibilityLabel("Актуальное: \(highlight.title)")
        .accessibilityIdentifier("alo.highlight.\(highlight.title)")
    }
}

/// A highlight opened in the story viewer, its stories as one person's group.
struct AloHighlightPlayback: Identifiable {
    let highlight: AloStoryHighlight
    let group: AloStoryGroup
    var id: Int { highlight.id }

    init(highlight: AloStoryHighlight, user: AloEntitySummary) {
        self.highlight = highlight
        group = AloStoryGroup([
            "user": ["id": user.id, "name": user.name, "username": user.username, "avatarEmoji": user.avatarUrl,
                     "verified": user.verified],
            "stories": highlight.stories.map(\.dictionary),
            "hasUnseen": false
        ])
    }
}

// MARK: - Archive

/// Your stories, expired ones too, newest first. Tap one to watch it; "Выбрать" picks several to
/// put into a highlight. Opened from "Новое", it starts in that picking mode.
struct AloStoryArchiveScreen: View {
    enum Mode: String, Identifiable {
        case browse, newHighlight
        var id: String { rawValue }
    }

    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var stories: [AloStory] = []
    @State private var nextBefore = ""
    @State private var isLoading = true
    @State private var isSelecting = false
    @State private var selected: [AloStory] = []
    @State private var watching: AloHighlightPlayback?
    @State private var isAddSheetPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if stories.isEmpty {
                ContentUnavailableView("Архив пуст", systemImage: "archivebox",
                                       description: Text("Здесь хранятся ваши истории после того, как они исчезнут из ленты."))
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                        ForEach(stories) { story in
                            cell(story)
                        }
                    }
                    .padding(.horizontal, 3)
                    if !nextBefore.isEmpty {
                        ProgressView().padding().task { await loadMore() }
                    }
                }
            }
            if isSelecting {
                AloPrimaryButton(title: selected.isEmpty ? "Выберите истории" : "Добавить в актуальное (\(selected.count))") {
                    isAddSheetPresented = true
                }
                .disabled(selected.isEmpty)
                .padding(16)
                .accessibilityIdentifier("alo.archive.add")
            }
        }
        .background(AloTheme.background.ignoresSafeArea())
        .task {
            isSelecting = mode == .newHighlight
            await loadMore()
        }
        .fullScreenCover(item: $watching) { playback in
            AloStoryViewer(groups: [playback.group], startGroupID: playback.group.id)
                .environmentObject(app)
        }
        .sheet(isPresented: $isAddSheetPresented) {
            AloAddToHighlightSheet(stories: selected, startsWithNew: mode == .newHighlight) {
                isAddSheetPresented = false
                dismiss()
            }
            .environmentObject(app)
            .presentationDetents([.medium, .large])
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.archive")
    }

    private var header: some View {
        HStack(spacing: 12) {
            AloChatCircleButton(systemImage: "xmark", label: "Закрыть") { dismiss() }
            Text(mode == .newHighlight ? "Новое актуальное" : "Архив историй")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(AloTheme.text)
                .frame(maxWidth: .infinity)
            Button(isSelecting ? "Отмена" : "Выбрать") {
                if isSelecting, mode == .newHighlight { dismiss(); return }
                isSelecting.toggle()
                selected = []
            }
            .font(.system(size: 16, weight: .semibold))
            .frame(minWidth: 72, minHeight: 44)
            .accessibilityIdentifier("alo.archive.select")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func cell(_ story: AloStory) -> some View {
        let index = selected.firstIndex(where: { $0.id == story.id })
        return Button {
            if isSelecting {
                if let index { selected.remove(at: index) } else { selected.append(story) }
            } else if let me = app.bootstrap?.me {
                let owner = AloEntitySummary(["id": me.id, "name": me.name, "username": me.username, "avatarEmoji": me.avatarUrl])
                watching = AloHighlightPlayback(highlight: AloStoryHighlight(["id": -story.id, "title": "",
                    "coverStoryId": story.id, "stories": [story.dictionary]]), user: owner)
            }
        } label: {
            Color.clear
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay { AloStoryThumbnail(story: story, cornerRadius: 6) }
                .overlay(alignment: .bottomLeading) {
                    Text(Self.day(story.createdAt))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        ZStack {
                            Circle().fill(index == nil ? Color.black.opacity(0.25) : AloTheme.accent)
                            Circle().stroke(.white, lineWidth: 1.5)
                            if let index {
                                Text("\(index + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .padding(6)
                    }
                }
        }
        .buttonStyle(AloFeedPressStyle())
        .accessibilityLabel("История от \(Self.day(story.createdAt))")
        .accessibilityAddTraits(index != nil ? .isSelected : [])
        .accessibilityIdentifier("alo.archive.story")
    }

    private func loadMore() async {
        do {
            let page = try await app.storyArchive(before: nextBefore)
            stories += page.stories.filter { story in !stories.contains { $0.id == story.id } }
            nextBefore = page.nextBefore
        } catch {
            nextBefore = ""
        }
        isLoading = false
    }

    static func day(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU")))
    }
}

// MARK: - Adding to a highlight

/// Your highlights to add the stories to, or a new one with a name.
struct AloAddToHighlightSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let stories: [AloStory]
    var startsWithNew = false
    let onDone: () -> Void
    @State private var highlights: [AloStoryHighlight] = []
    @State private var title = ""
    @State private var isSaving = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        if let cover = stories.first {
                            AloStoryThumbnail(story: cover, cornerRadius: 22).frame(width: 44, height: 44).clipShape(Circle())
                        }
                        TextField("Название нового актуального", text: $title)
                            .focused($titleFocused)
                            .submitLabel(.done)
                            .onSubmit(createNew)
                            .accessibilityIdentifier("alo.highlight.title")
                        Button("Создать", action: createNew)
                            .fontWeight(.semibold)
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                            .accessibilityIdentifier("alo.highlight.create")
                    }
                } header: {
                    Text("Новое актуальное")
                }
                if !highlights.isEmpty, !startsWithNew {
                    Section("Добавить в существующее") {
                        ForEach(highlights) { highlight in
                            Button {
                                Task {
                                    isSaving = true
                                    try? await app.addToHighlight(highlight, stories: stories)
                                    isSaving = false
                                    onDone()
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    if let cover = highlight.cover {
                                        AloStoryThumbnail(story: cover, cornerRadius: 22).frame(width: 44, height: 44).clipShape(Circle())
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(highlight.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                                        Text("\(highlight.stories.count) \(Self.storiesWord(highlight.stories.count))")
                                            .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                                    }
                                }
                            }
                            .accessibilityIdentifier("alo.highlight.add.\(highlight.title)")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AloTheme.background)
            .navigationTitle("В актуальное")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
            }
        }
        .task {
            if let id = app.bootstrap?.me.id { highlights = (try? await app.highlights(userId: id)) ?? [] }
            if startsWithNew || highlights.isEmpty { titleFocused = true }
        }
    }

    private func createNew() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isSaving else { return }
        Task {
            isSaving = true
            do {
                try await app.createHighlight(title: name, stories: stories)
                onDone()
            } catch let error as AloAPIError {
                app.errorMessage = error.message
            } catch {
                app.errorMessage = "Не удалось создать актуальное."
            }
            isSaving = false
        }
    }

    static func storiesWord(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "история" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "истории" }
        return "историй"
    }
}
