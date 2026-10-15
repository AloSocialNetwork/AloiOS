import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import UIKit
import AVFoundation
import AVKit
import Combine
import CoreImage.CIFilterBuiltins
import CoreLocation
import MapKit

private enum AloKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// PhotosPicker normally materializes a selected asset as `Data`.  Keeping a
/// temporary file here lets a video move directly into the encrypted draft
/// pipeline instead, including when the asset is too large for memory.
struct AloPickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try makeLocalCopy(from: received.file)
        }
        FileRepresentation(importedContentType: .movie) { received in
            try makeLocalCopy(from: received.file)
        }
    }

    private static func makeLocalCopy(from source: URL) throws -> AloPickedMediaFile {
        let root = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("AloE2EEMedia", isDirectory: true)
            .appendingPathComponent("picker-imports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let copiedURL = root
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension.ifBlank("bin"))
        try FileManager.default.copyItem(at: source, to: copiedURL)
        return AloPickedMediaFile(url: copiedURL)
    }
}

struct MessagesView: View {
    var bottomBar: AnyView? = nil
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chatDragOffset: CGFloat = 0
    @State private var chatDragActive = false
    @State private var chatSwipeBlocked = false
    @State private var chatSwipeStartX: CGFloat = 0
    @State private var chatSwipeBaseOffset: CGFloat = 0
    @State private var chatPresentationPosition = AloChatTransitionPosition()
    @State private var chatTransitionRevision = 0
    @State private var showsCommunityCreation = false
    @State private var showsArchive = false
    @State private var isSelectingChats = false
    @State private var selectedChatKeys = Set<String>()
    @State private var swipeOpenID: String?
    @State private var pendingChatDeletion: [AloConversationSummary]?
    @State private var showsCallHistory = false
    @State private var chatSearchText = ""
    @State private var chatSearchHits = [AloOfflineMessageSearchHit]()
    // UIKit search input reports its responder state directly. FocusState has
    // no registered SwiftUI TextField here and would immediately reset it.
    @State private var chatSearchFocused = false
    @State private var inboxPosition = ScrollPosition(y: AloChatListSearchMetrics.barHeight)
    @ScaledMetric(relativeTo: .subheadline) private var chatSearchVisualHeight = AloSocialMetrics.searchHeight
    @State private var previewConversation: AloConversationSummary?
    @State private var previewConversationMuted: Bool?
    @State private var previewConversationDetail: AloConversationDetail?
    @State private var previewConversationSourceFrame: CGRect?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                inbox
                    .offset(x: app.activeConversation == nil ? 0 : -proxy.size.width * 0.30 + max(0, chatDragOffset) * 0.30)
                    .allowsHitTesting(app.activeConversation == nil && previewConversation == nil)
                    .accessibilityHidden(app.activeConversation != nil || previewConversation != nil)

                // Stay mounted in the same position throughout push/pop. The
                // opaque conversation is above this layer, not a reason to
                // remove and then reinsert the navigation bar after settling.
                if isSelectingChats, app.activeConversation == nil {
                    chatSelectionToolbar
                        .padding(.horizontal, 16).padding(.bottom, 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .zIndex(1)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let bottomBar {
                    bottomBar.frame(maxHeight: .infinity, alignment: .bottom)
                        .opacity(previewConversation == nil ? 1 : 0)
                        .allowsHitTesting(app.activeConversation == nil && previewConversation == nil)
                        .modifier(AloCoveredFromAccessibility(covered: app.activeConversation != nil || previewConversation != nil))
                        .zIndex(1)
                }
                if app.activeConversation != nil {
                    Color.black.opacity(0.15 * Double(max(CGFloat.zero, 1 - chatDragOffset / max(1, proxy.size.width))))
                        .allowsHitTesting(false).accessibilityHidden(true).zIndex(1.5)
                }

                if let conversation = app.activeConversation {
                    ConversationView(conversation: conversation, blocksParentSwipe: $chatSwipeBlocked)
                        .overlay(alignment: .leading) {
                            // A separate edge surface, not a shadow of the entire
                            // scrolling/video/glass hierarchy on every drag frame.
                            LinearGradient(colors: [.clear, .black.opacity(0.24)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 18).offset(x: -18)
                                .opacity(chatDragOffset > 0 ? 1 : 0)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                        .modifier(AloChatMotionOffset(x: chatDragOffset, position: chatPresentationPosition))
                        .contentShape(Rectangle())
                        .transition(.move(edge: .trailing))
                        .zIndex(2)
                }

                if let conversation = previewConversation, app.activeConversation == nil {
                    ConversationPreviewOverlay(
                        conversation: conversation,
                        detail: previewConversationDetail,
                        muted: previewConversationMuted,
                        isPinned: app.isChatPinned(conversation),
                        isArchived: app.isChatArchived(conversation),
                        onTogglePin: {
                            app.setChatsPinned([conversation], pinned: !app.isChatPinned(conversation))
                            dismissConversationPreview()
                        },
                        onToggleArchive: {
                            app.setChatsArchived([conversation], archived: !app.isChatArchived(conversation))
                            dismissConversationPreview()
                        },
                        onSelect: {
                            dismissConversationPreview()
                            beginChatSelection(with: conversation)
                        },
                        onDelete: {
                            dismissConversationPreview()
                            pendingChatDeletion = [conversation]
                        },
                        sourceFrame: previewConversationSourceFrame,
                        onOpen: {
                            dismissConversationPreview()
                            app.openConversation(conversation)
                        },
                        onToggleMuted: {
                            togglePreviewConversationMuted(conversation)
                            dismissConversationPreview()
                        },
                        onDismiss: dismissConversationPreview
                    )
                    .transition(.opacity)
                    .zIndex(3)
                }
            }
            .modifier(AloChatBackSwipe(
                enabled: app.activeTab == .messages && app.activeConversation != nil && !chatSwipeBlocked,
                exclusions: [],
                onChanged: { translation, startX in
                    if !chatDragActive {
                        beginChatSwipe()
                        chatSwipeStartX = startX - proxy.frame(in: .global).minX
                    }
                    updateChatSwipe(translation: translation, width: proxy.size.width)
                },
                onEnded: { translation, velocity in
                    endChatSwipe(translation: max(0, translation), velocity: velocity, width: proxy.size.width)
                },
                onCancelled: cancelChatSwipe
            ))
        }
        .ignoresSafeArea(app.activeConversation != nil ? .keyboard : [], edges: .bottom)
        .preference(key: AloChatPreviewPresentedKey.self, value: previewConversation != nil)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9), value: app.activeConversation?.peerId)
        .onChange(of: app.activeConversation?.peerId) { _, _ in
            chatDragOffset = 0
            chatDragActive = false
            chatTransitionRevision += 1
        }
        .sheet(isPresented: $showsCommunityCreation) {
            AloNewMessageSheet()
                .environmentObject(app)
        }
    }

    private func beginChatSwipe() {
        guard !chatSwipeBlocked else { return }
        chatTransitionRevision += 1
        chatSwipeBaseOffset = max(0, chatPresentationPosition.x)
        chatDragActive = true
    }

    private func cancelChatSwipe() {
        guard chatDragActive else { return }
        chatDragActive = false
        chatTransitionRevision += 1
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.1)) {
            chatDragOffset = 0
        }
    }

    private func updateChatSwipe(translation: CGFloat, width: CGFloat) {
        guard chatDragActive, !chatSwipeBlocked else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            chatDragOffset = min(width, max(0, chatSwipeBaseOffset + translation))
        }
    }

    private func endChatSwipe(translation: CGFloat, velocity: CGFloat, width: CGFloat) {
        guard chatDragActive else { return }
        chatDragActive = false
        let revision = chatTransitionRevision

        let shouldClose = AloInteractiveDismissPolicy.shouldDismiss(
            translation: chatDragOffset,
            velocity: velocity,
            width: AloChatBackIntent.dismissalWidth(viewport: width,
                startX: chatSwipeStartX)
        )
        let target = shouldClose ? width : 0

        withAnimation(
            reduceMotion ? nil : .easeInOut(duration: shouldClose
                ? AloChatNavigationTiming.completionDuration(distance: width - chatDragOffset, velocity: velocity)
                : 0.1),
            completionCriteria: .logicallyComplete
        ) {
            chatDragOffset = target
        } completion: {
            guard shouldClose, revision == chatTransitionRevision else { return }
            AloKeyboard.dismiss()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                app.closeConversation()
            }
            chatDragOffset = 0
        }
    }

    private var chatSearchActive: Bool { chatSearchFocused || !chatSearchText.isEmpty }
    private var chatSearchRevealHeight: CGFloat { AloChatListSearchMetrics.barHeight(visualHeight: chatSearchVisualHeight) }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                HStack(alignment: .center, spacing: 6) {
                    if showsArchive && !isSelectingChats {
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) { showsArchive = false }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AloTheme.accent)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Назад к чатам")
                        .accessibilityIdentifier("alo.chats.archive.back")
                    }
                    if isSelectingChats {
                        AloSocialTitle(text: selectedChatKeys.isEmpty ? "Выберите чаты" : "Выбрано: \(selectedChatKeys.count)")
                            .foregroundStyle(AloTheme.text)
                            .contentTransition(.numericText())
                    } else {
                        AloSocialTitle(text: showsArchive ? "Архив" : "Чаты")
                            .foregroundStyle(AloTheme.text)
                    }
                    Spacer()
                    if chatSearchActive {
                        Button("Отмена", action: cancelChatSearch)
                            .font(.system(size: 17)).foregroundStyle(AloTheme.accent)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("alo.chats.search.cancel")
                    } else if isSelectingChats {
                        Button("Готово") { endChatSelection() }
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AloTheme.accent)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("alo.chats.select.done")
                    } else {
                        // The text action leads; the two round buttons stay together at the edge.
                        if !arrangedChats.isEmpty {
                            Button("Изменить") { beginChatSelection(with: nil) }
                                .font(.system(size: 17))
                                .foregroundStyle(AloTheme.accent)
                                .frame(minHeight: 44)
                                .padding(.trailing, 6)
                                .accessibilityIdentifier("alo.chats.select.begin")
                        }
                        Button {
                            showsCallHistory = true
                        } label: {
                            Image(systemName: "phone")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AloTheme.accent)
                                .frame(width: AloSocialMetrics.glassButton, height: AloSocialMetrics.glassButton)
                                .modifier(AloChatGlass(interactive: false, role: .chrome))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.94))
                        .accessibilityLabel("Звонки")
                        .accessibilityIdentifier("alo.chats.calls")
                        Button {
                            showsCommunityCreation = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AloTheme.accent)
                                .frame(width: AloSocialMetrics.glassButton, height: AloSocialMetrics.glassButton)
                                .modifier(AloChatGlass(interactive: false, role: .chrome))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.94))
                        .accessibilityLabel("Новое сообщение")
                    }
                }
                .frame(minHeight: AloSocialMetrics.controlHeight)
                .padding(.horizontal, AloSocialMetrics.inset)
                .padding(.top, 8)
            }

            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        AloChatListSearchBar(text: $chatSearchText, focused: $chatSearchFocused,
                                             isActive: chatSearchActive, onCancel: cancelChatSearch)
                            .id("alo.chats.search")
                        if chatSearchActive {
                            chatSearchResults
                        } else {
                            if !showsArchive && !isSelectingChats && !archivedChats.isEmpty {
                                archiveEntryRow.id("alo.chats.archive")
                            }
                            ForEach(arrangedChats) { conversation in
                                chatRow(conversation)
                            }
                            if showsArchive && arrangedChats.isEmpty {
                                Text("В архиве пусто")
                                    .font(.system(size: 15)).foregroundStyle(AloTheme.muted)
                                    .frame(maxWidth: .infinity).padding(.top, 60)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.bottom, 100)
                    .frame(minHeight: viewport.size.height + chatSearchRevealHeight, alignment: .top)
                }
                .accessibilityIdentifier("alo.chats.scroll")
                .scrollDismissesKeyboard(.interactively)
                .scrollPosition($inboxPosition)
                .scrollTargetBehavior(AloSearchRevealBehavior(revealHeight: chatSearchRevealHeight))
                .task {
                    // Resolve the initial point after the viewport has its real size;
                    // no delayed scrollTo-ID task or animated search flash.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { inboxPosition.scrollTo(y: chatSearchRevealHeight) }
                }
                .onChange(of: chatSearchActive) { _, active in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
                        inboxPosition.scrollTo(y: active ? 0 : chatSearchRevealHeight)
                    }
                }
                .onChange(of: showsArchive) { _, _ in inboxPosition.scrollTo(y: chatSearchRevealHeight) }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: chatSearchActive)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9), value: isSelectingChats)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9), value: app.chatPrefsRevision)
        .task(id: visibleConversations.map(\.lastMessageId)) { app.establishUnreadBaseline() }
        .refreshable { await app.loadBootstrap() }
        .task(id: chatSearchText) { await runChatMessageSearch() }
        .confirmationDialog(deletionTitle, isPresented: Binding(
            get: { pendingChatDeletion != nil }, set: { if !$0 { pendingChatDeletion = nil } }
        ), titleVisibility: .visible) {
            Button(deletionActionTitle, role: .destructive) {
                if let chats = pendingChatDeletion { app.deleteChats(chats) }
                pendingChatDeletion = nil
                endChatSelection()
            }
            Button("Отмена", role: .cancel) { pendingChatDeletion = nil }
        } message: {
            Text(deletionMessage)
        }
        .navigationDestination(isPresented: $showsCallHistory) {
            AloCallHistoryView().environmentObject(app)
        }
    }

    private var deletionTitle: String {
        guard let chats = pendingChatDeletion else { return "" }
        if chats.count == 1, let chat = chats.first {
            return chat.kind == "group" ? "Покинуть «\(chat.peer.name)»?" : "Удалить чат «\(chat.peer.name)»?"
        }
        return "Удалить чаты: \(chats.count)?"
    }

    private var deletionActionTitle: String {
        guard let chats = pendingChatDeletion else { return "Удалить" }
        return chats.count == 1 && chats.first?.kind == "group" ? "Покинуть" : "Удалить у меня"
    }

    private var deletionMessage: String {
        guard let chats = pendingChatDeletion else { return "" }
        if chats.allSatisfy({ $0.kind == "group" }) { return "Вы выйдете из группы и она пропадёт из списка." }
        return "История удалится только у вас. У собеседника переписка останется."
    }

    private func unreadState(_ conversation: AloConversationSummary) -> Bool {
        _ = app.unreadRevision
        return app.isConversationUnread(conversation)
    }

    private var arrangedChats: [AloConversationSummary] {
        app.arrangedConversations(archived: showsArchive)
    }

    private var archivedChats: [AloConversationSummary] {
        app.arrangedConversations(archived: true)
    }

    private func chatKey(_ conversation: AloConversationSummary) -> String { AloChatListPrefs.key(for: conversation) }

    private func chatRow(_ conversation: AloConversationSummary) -> some View {
        let key = chatKey(conversation)
        let pinned = app.isChatPinned(conversation)
        let archived = app.isChatArchived(conversation)
        let selected = selectedChatKeys.contains(key)
        return AloSwipeActionRow(
            id: key, openedID: $swipeOpenID,
            leading: [AloSwipeAction(id: "pin", title: pinned ? "Открепить" : "Закрепить",
                                     systemImage: pinned ? "pin.slash.fill" : "pin.fill", color: Color(red: 0.2, green: 0.55, blue: 0.95)) {
                app.setChatsPinned([conversation], pinned: !pinned)
            }],
            trailing: [
                AloSwipeAction(id: "mute", title: "Звук", systemImage: "bell.slash.fill", color: Color(red: 0.96, green: 0.6, blue: 0.1)) {
                    app.toggleChatMuted(conversation)
                },
                AloSwipeAction(id: "delete", title: "Удалить", systemImage: "trash.fill", color: Color(red: 1, green: 0.27, blue: 0.23)) {
                    pendingChatDeletion = [conversation]
                },
                AloSwipeAction(id: "archive", title: archived ? "Вернуть" : "Архив",
                               systemImage: archived ? "tray.and.arrow.up.fill" : "archivebox.fill",
                               color: Color(red: 0.42, green: 0.45, blue: 0.52)) {
                    app.setChatsArchived([conversation], archived: !archived)
                }
            ],
            isEnabled: !isSelectingChats
        ) {
            VStack(spacing: 0) {
                ConversationContextRow(conversation: conversation,
                    isUnread: unreadState(conversation),
                    unreadCount: app.unreadCount(for: conversation),
                    isPinned: pinned,
                    isSelecting: isSelectingChats,
                    isSelected: selected,
                    onOpen: {
                        if swipeOpenID != nil { swipeOpenID = nil; return }
                        if isSelectingChats { toggleChatSelection(conversation) } else { app.openConversation(conversation) }
                    },
                    onPreview: { frame in
                        guard !isSelectingChats else { return }
                        presentConversationPreview(conversation, sourceFrame: frame)
                    })
                Rectangle().fill(AloTheme.separator).frame(height: 1 / UIScreen.main.scale)
                    .padding(.leading, isSelectingChats ? 120 : 86)
            }
        }
        .id(conversation.id)
    }

    private var archiveEntryRow: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) { showsArchive = true }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(red: 0.42, green: 0.45, blue: 0.52))
                    Image(systemName: "archivebox.fill").font(.system(size: 24)).foregroundStyle(.white)
                }
                .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Архив").font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                    Text("Чатов: \(archivedChats.count)").font(.system(size: 15)).foregroundStyle(AloTheme.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(minHeight: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloChatRowPressStyle())
        .accessibilityIdentifier("alo.chats.archive.entry")
    }

    // MARK: Selection

    private func beginChatSelection(with conversation: AloConversationSummary?) {
        swipeOpenID = nil
        selectedChatKeys = conversation.map { [chatKey($0)] } ?? []
        isSelectingChats = true
        AloHaptics.impact(.light)
    }

    private func toggleChatSelection(_ conversation: AloConversationSummary) {
        let key = chatKey(conversation)
        if selectedChatKeys.contains(key) { selectedChatKeys.remove(key) } else { selectedChatKeys.insert(key) }
        AloHaptics.selection()
    }

    private func endChatSelection() {
        isSelectingChats = false
        selectedChatKeys = []
    }

    private var selectedChats: [AloConversationSummary] {
        (app.bootstrap?.conversations ?? []).filter { selectedChatKeys.contains(chatKey($0)) }
    }

    private var chatSelectionToolbar: some View {
        let chats = selectedChats
        let allPinned = !chats.isEmpty && chats.allSatisfy { app.isChatPinned($0) }
        let allArchived = !chats.isEmpty && chats.allSatisfy { app.isChatArchived($0) }
        let hasUnread = chats.contains { unreadState($0) }
        return HStack(spacing: 0) {
            selectionButton(hasUnread ? "Прочитано" : "Прочитано", icon: "checkmark.message", enabled: hasUnread, id: "read") {
                app.markChatsRead(chats); endChatSelection()
            }
            selectionButton(allPinned ? "Открепить" : "Закрепить", icon: allPinned ? "pin.slash" : "pin", enabled: !chats.isEmpty, id: "pin") {
                app.setChatsPinned(chats, pinned: !allPinned); endChatSelection()
            }
            selectionButton(allArchived ? "Вернуть" : "В архив", icon: allArchived ? "tray.and.arrow.up" : "archivebox", enabled: !chats.isEmpty, id: "archive") {
                app.setChatsArchived(chats, archived: !allArchived); endChatSelection()
            }
            selectionButton("Удалить", icon: "trash", enabled: !chats.isEmpty, id: "delete", tint: Color(red: 1, green: 0.27, blue: 0.23)) {
                pendingChatDeletion = chats
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 60)
        .modifier(AloChatGlass(interactive: false, role: .chrome))
        .accessibilityIdentifier("alo.chats.select.toolbar")
    }

    private func selectionButton(_ title: String, icon: String, enabled: Bool, id: String, tint: Color = AloTheme.accent,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 21, weight: .regular))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(enabled ? tint : AloTheme.muted.opacity(0.6))
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloControlPressStyle())
        .disabled(!enabled)
        .accessibilityIdentifier("alo.chats.select.\(id)")
    }

    private var matchingConversations: [AloConversationSummary] {
        let q = chatSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return visibleConversations }
        return visibleConversations.filter {
            $0.peer.name.lowercased().contains(q) || $0.peer.username.lowercased().contains(q)
                || chatPreviewText($0.lastBody).lowercased().contains(q)
        }
    }

    @ViewBuilder
    private var chatSearchResults: some View {
        let chats = matchingConversations
        if !chats.isEmpty {
            AloChatSectionHeader(title: "Чаты")
            ForEach(chats) { chatRow($0) }
        }
        if !chatSearchHits.isEmpty {
            AloChatSectionHeader(title: "Сообщения")
            ForEach(chatSearchHits) { hit in
                AloChatMessageHitRow(hit: hit, preview: hit.message.body.ifBlank(hit.message.attachmentName).ifBlank("Вложение")) {
                    guard let summary = visibleConversations.first(where: { $0.peerId == hit.conversation.peerId }) else { return }
                    chatSearchFocused = false
                    app.openConversation(summary)
                }
            }
        }
        if chats.isEmpty && chatSearchHits.isEmpty && !chatSearchText.isEmpty {
            Text("Ничего не найдено")
                .font(.system(size: 15)).foregroundStyle(AloTheme.muted)
                .frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    private func cancelChatSearch() {
        chatSearchText = ""
        chatSearchFocused = false
        chatSearchHits = []
    }

    private func runChatMessageSearch() async {
        let query = chatSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = app.bootstrap?.me.id ?? 0
        guard !query.isEmpty, owner > 0 else { chatSearchHits = []; return }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        let hits = await Task.detached(priority: .userInitiated) {
            AloSecureOfflineCacheStore.shared.searchAllMessages(ownerUserId: owner, query: query, limit: 100)
        }.value
        guard !Task.isCancelled else { return }
        chatSearchHits = hits
    }

    private var visibleConversations: [AloConversationSummary] {
        app.bootstrap?.conversations ?? []
    }

    private func presentConversationPreview(_ conversation: AloConversationSummary, sourceFrame: CGRect?) {
        previewConversationSourceFrame = sourceFrame
        previewConversationMuted = nil
        previewConversationDetail = app.bootstrap.flatMap {
            app.api.loadCachedConversation(peerId: conversation.peerId, ownerUserId: $0.me.id)
        }
        AloHaptics.impact(.medium)
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.36, dampingFraction: 1)) {
            previewConversation = conversation
        }
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") {
            previewConversationDetail = AloConversationDetail(summary: conversation, items: app.bootstrap?.activeMessages ?? [])
            previewConversationMuted = false
            return
        }
#endif
        Task {
            do {
                let detail = try await app.api.loadConversation(peerId: conversation.peerId)
                guard previewConversation?.peerId == conversation.peerId else { return }
                previewConversationDetail = detail
                let muted = try await app.api.chatMuteState(conversation: detail)
                guard previewConversation?.peerId == conversation.peerId else { return }
                previewConversationMuted = muted
            } catch {
                // The cached preview remains usable while offline.
            }
        }
    }

    private func dismissConversationPreview() {
        withAnimation(AloContextMotion.exit) {
            previewConversation = nil
            previewConversationMuted = nil
            previewConversationDetail = nil
            previewConversationSourceFrame = nil
        }
    }

    private func togglePreviewConversationMuted(_ conversation: AloConversationSummary) {
        guard let currentMuted = previewConversationMuted else { return }
        previewConversationMuted = nil
        Task {
            do {
                let detail = try await app.api.loadConversation(peerId: conversation.peerId)
                let muted = try await app.api.setChatMuted(!currentMuted, conversation: detail)
                guard previewConversation?.peerId == conversation.peerId else { return }
                previewConversationMuted = muted
            } catch let error as AloAPIError {
                guard previewConversation?.peerId == conversation.peerId else { return }
                previewConversationMuted = currentMuted
                app.notice = error.message
            } catch {
                guard previewConversation?.peerId == conversation.peerId else { return }
                previewConversationMuted = currentMuted
                app.notice = "Не удалось изменить уведомления чата."
            }
        }
    }
}

/// Row geometry follows Telegram's chat list: 60 pt avatar, text at 84 pt, 16 semibold title,
/// 15 pt preview up to two lines, 14 pt date, 76 pt minimum height.
private struct ConversationRow: View, Equatable {
    // Plain values only (no environment object), so SwiftUI can skip the row when nothing about
    // this chat changed, instead of rebuilding every row on each app-wide update.
    let conversation: AloConversationSummary
    let isUnread: Bool
    var unreadCount = 0
    var isPinned = false
    var isSelecting = false
    var isSelected = false

    @ViewBuilder
    private var status: some View {
        if unreadCount > 0 {
            // Telegram's counter: a capsule that grows with the number.
            Text(unreadCount > 999 ? "999+" : "\(unreadCount)")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(minWidth: 22, minHeight: 22)
                .background(AloTheme.accent, in: Capsule())
                .contentTransition(.numericText())
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Непрочитанных: \(unreadCount)")
                .accessibilityIdentifier("alo.chat.unread")
        } else if isUnread {
            Circle().fill(AloTheme.accent).frame(width: 11, height: 11)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Есть непрочитанные сообщения")
                .accessibilityIdentifier("alo.chat.unread")
        } else if isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AloTheme.muted)
                .rotationEffect(.degrees(45))
                // Optical centring: the tilted pin's ink sits 1.3pt above its frame's centre.
                .offset(y: 1.3)
                .accessibilityLabel("Закреплён")
                .accessibilityIdentifier("alo.chat.pinned")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isSelecting {
                ZStack {
                    Circle().stroke(isSelected ? Color.clear : AloTheme.muted.opacity(0.6), lineWidth: 1.5)
                    if isSelected {
                        Circle().fill(AloTheme.accent)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 24, height: 24)
                .padding(.top, 18)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if conversation.peer.entityType == "saved" {
                SavedMessagesAvatar(size: 60)
            } else {
                AloAvatar(
                    name: conversation.peer.name,
                    url: conversation.peer.avatarUrl,
                    size: 60,
                    colorSeed: String(conversation.peer.id)
                )
            }
            VStack(alignment: .leading, spacing: -1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if conversation.kind == "group" || conversation.peer.entityType == "channel" {
                        Image(systemName: conversation.peer.entityType == "channel" ? "megaphone.fill" : "person.2.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AloTheme.text.opacity(0.7))
                    }
                    Text(conversation.peer.entityType == "saved" ? "Избранное" : conversation.peer.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AloTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(AloFormatters.messageTime(conversation.lastAt))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(AloTheme.muted)
                        .lineLimit(1)
                }
                HStack(alignment: .center, spacing: 8) {
                    Text(chatPreviewText(conversation.lastBody).ifBlank("Сообщение"))
                        .font(.system(size: 15, weight: .regular))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(isUnread ? AloTheme.text.opacity(0.85) : AloTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Keeps the preview clear of the status, which is drawn centred on the row below.
                    status.hidden().accessibilityHidden(true)
                }
            }
            .padding(.top, 1)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(minHeight: 76, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Counter, dot or pin sits on the row's middle line, level with the avatar's centre,
        // whether the preview has one line or two.
        .overlay(alignment: .trailing) {
            status
                .padding(.trailing, 16)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isUnread)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: unreadCount)
        }
        .background(isPinned && !isSelected ? Color.white.opacity(0.035) : Color.clear)
        .background(isSelected ? AloTheme.accent.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }
}

private func chatPreviewText(_ body: String) -> String {
    AloPollCodec.previewText(for: body)
        ?? AloChatSystemEventCodec.previewText(for: body)
        ?? body
}

private func chatPreviewText(_ message: AloChatMessage) -> String {
    if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return chatPreviewText(message.body) }
    let type = message.attachments.first?.type.lowercased() ?? message.attachmentType.lowercased()
    if type == "voice" || type.hasPrefix("audio") { return "Голосовое сообщение" }
    if ["circle", "video_circle", "video-circle"].contains(type) { return "Видеосообщение" }
    if type == "image" { return message.attachments.count > 1 ? "Фотографии" : "Фото" }
    if type == "video" { return "Видео" }
    if type == "contact" {
        return message.attachments.first?.metadata["displayName"].map { "Контакт: \($0)" } ?? "Контакт"
    }
    if type == "location" { return "Геопозиция" }
    return message.attachmentName.ifBlank(message.attachments.isEmpty ? "Сообщение" : "Вложение")
}

private struct ConversationContextRow: View {
    let conversation: AloConversationSummary
    let isUnread: Bool
    var unreadCount = 0
    var isPinned = false
    var isSelecting = false
    var isSelected = false
    let onOpen: () -> Void
    let onPreview: (CGRect?) -> Void
    @State private var anchor = AloContextSourceAnchor()

    var body: some View {
        ConversationRow(conversation: conversation, isUnread: isUnread, unreadCount: unreadCount, isPinned: isPinned,
                        isSelecting: isSelecting, isSelected: isSelected)
            .equatable()
            .background(AloContextSourceMarker(anchor: anchor).allowsHitTesting(false).accessibilityHidden(true))
            .contentShape(Rectangle())
            .gesture(LongPressGesture(minimumDuration: 0.35, maximumDistance: 18)
                .exclusively(before: TapGesture()).onEnded { gesture in
                    switch gesture {
                    case .first(true): onPreview(anchor.frame)
                    case .second: onOpen()
                    default: break
                    }
                })
            .accessibilityAction(named: Text("Предпросмотр чата")) { onPreview(anchor.frame) }
    }
}

private struct ConversationPreviewOverlay: View {
    @EnvironmentObject private var app: AloAppModel
    var visualAccessibility = AloVisualAccessibility()
    private var reduceMotion: Bool { visualAccessibility.reduceMotion }
    let conversation: AloConversationSummary
    let detail: AloConversationDetail?
    let muted: Bool?
    let isPinned: Bool
    let isArchived: Bool
    let onTogglePin: () -> Void
    let onToggleArchive: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    let sourceFrame: CGRect?
    let onOpen: () -> Void
    let onToggleMuted: () -> Void
    let onDismiss: () -> Void
    @State private var isPresented = false
    @State private var isDismissing = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AloChatModalBackdrop(darkness: 0.42)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss(onDismiss) }
                    .opacity(isPresented ? 1 : 0)

                VStack(alignment: .trailing, spacing: 8) {
                    ZStack {
                        AloChatWallpaper(appearance: previewAppearance)

                        VStack(spacing: 0) {
                            previewHeader.padding(.top, 8).padding(.bottom, 6)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let detail, !detail.items.isEmpty {
                                        ForEach(AloPollProjection.visibleMessages(detail.items).suffix(12)) { message in
                                            HStack {
                                                if message.senderId == app.bootstrap?.me.id { Spacer(minLength: 28) }
                                                ChatMessageRow(message: message,
                                                    replyToMessage: detail.items.first(where: { $0.id == message.replyToMessageId }),
                                                    pollState: previewPollState(message, detail: detail), appearance: previewAppearance,
                                                    isMine: message.senderId == app.bootstrap?.me.id, showsSenderAttribution: detail.kind != "direct",
                                                    isPending: false, isSelected: false, selectionMode: false, previewOnly: true,
                                                    availableWidth: min(proxy.size.width - 24, 390) - 16,
                                                    onTap: {}, onReact: { _ in }, onPollVote: { _ in }, canClosePoll: false,
                                                    onClosePoll: {}, onOpenMediaGallery: { _, _ in }, onOpenDiscussion: {}, onLongPress: { _ in })
                                                if message.senderId != app.bootstrap?.me.id { Spacer(minLength: 28) }
                                            }
                                        }
                                    } else {
                                        previewMessage
                                    }
                                }.padding(8)
                            }
                            .defaultScrollAnchor(.bottom)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(
                        width: min(proxy.size.width - 24, 390),
                        height: min(max(proxy.size.height * 0.60, 300), proxy.size.height - 190)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color.black.opacity(0.34), radius: 24, y: 12)
                    .contentShape(RoundedRectangle(cornerRadius: 22))
                    .onTapGesture { dismiss(onOpen) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("alo.chat.preview")
                    .scaleEffect(isPresented || reduceMotion ? 1 : 0.01, anchor: .center)
                    .offset(y: isPresented || reduceMotion ? 0 : activationOffset(in: proxy))
                    .opacity(isPresented ? 1 : 0)

                    VStack(spacing: 0) {
                        // Same set and order as Telegram's chat-list menu.
                        previewAction(
                            title: isPinned ? "Открепить" : "Закрепить",
                            systemImage: isPinned ? "pin.slash" : "pin",
                            action: { dismiss(onTogglePin) }
                        )
                        previewDivider
                        previewAction(
                            title: "Открыть чат",
                            systemImage: "arrow.up.right",
                            action: { dismiss(onOpen) }
                        )
                        if let muted {
                            previewDivider
                            previewAction(
                                title: muted ? "Включить звук" : "Выключить звук",
                                systemImage: muted ? "bell" : "bell.slash",
                                action: { dismiss(onToggleMuted) }
                            )
                        }
                        previewDivider
                        previewAction(
                            title: isArchived ? "Вернуть из архива" : "В архив",
                            systemImage: isArchived ? "tray.and.arrow.up" : "archivebox",
                            action: { dismiss(onToggleArchive) }
                        )
                        previewDivider
                        previewAction(
                            title: "Выбрать",
                            systemImage: "checkmark.circle",
                            action: { dismiss(onSelect) }
                        )
                        if conversation.peer.entityType != "saved" {
                            previewDivider
                            previewAction(
                                title: conversation.kind == "group" ? "Покинуть" : "Удалить",
                                systemImage: "trash",
                                tint: Color(red: 1, green: 0.27, blue: 0.23),
                                action: { dismiss(onDelete) }
                            )
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(width: min(proxy.size.width - 48, 250))
                    .modifier(AloContextMenuSurface())
                    .accessibilityIdentifier("alo.chat.preview.actions")
                    .scaleEffect(isPresented || reduceMotion ? 1 : 0.01, anchor: .topTrailing)
                    .opacity(isPresented ? 1 : 0)
                }
                .padding(.vertical, 24)
                .allowsHitTesting(!isDismissing)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.16) : AloContextMotion.enter) {
                isPresented = true
            }
        }
    }

    private func activationOffset(in proxy: GeometryProxy) -> CGFloat {
        guard let sourceFrame else { return 12 }
        let targetTop = (proxy.size.height - min(max(proxy.size.height * 0.60, 300), proxy.size.height - 190) - 120) / 2
        let previewHeight = min(max(proxy.size.height * 0.60, 300), proxy.size.height - 190)
        return sourceFrame.midY - proxy.frame(in: .global).minY - targetTop - previewHeight / 2
    }

    private func dismiss(_ action: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        withAnimation(AloContextMotion.exit, completionCriteria: .logicallyComplete) {
            isPresented = false
        } completion: { action() }
    }

    private var previewAppearance: AloChatAppearance {
        detail.map { AloChatAppearanceStore.read(for: $0) } ?? AloChatAppearance()
    }

    private func previewPollState(_ message: AloChatMessage, detail: AloConversationDetail) -> AloPollViewState? {
        guard case let .create(definition)? = AloPollCodec.decode(message.body) else { return nil }
        return AloPollProjection.applyingCanonical(detail.canonicalPolls,
            to: AloPollProjection.states(messages: detail.items, currentUserId: app.bootstrap?.me.id ?? 0))[definition.id]
    }

    private var previewHeader: some View {
        VStack(spacing: 1) {
                Text(conversation.peer.entityType == "saved" ? "Избранное" : conversation.peer.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(conversation.peer.entityType == "saved" ? "Личное облако" : (conversation.peer.online ? "в сети" : previewSubtitle))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 44)
        .modifier(AloContextMenuSurface(radius: 24))
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("alo.chat.preview.header")
    }

    private var previewMessage: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chatPreviewText(conversation.lastBody).ifBlank(previewEmptyText))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.white)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
            if !conversation.lastAt.isEmpty {
                Text(AloFormatters.messageTime(conversation.lastAt))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.60))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 270, alignment: .leading)
        .background(Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewDivider: some View {
        Divider().overlay(Color.white.opacity(0.08)).padding(.horizontal, 16)
    }

    private func previewAction(
        title: String,
        systemImage: String,
        showsProgress: Bool = false,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                if showsProgress {
                    ProgressView().controlSize(.small).tint(Color.white)
                } else {
                    Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 28)
                }
                Text(title)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloContextActionPressStyle())
    }

    private var previewSubtitle: String {
        switch conversation.kind {
        case "channel": return "канал"
        case "group": return "\(conversation.memberCount) участников"
        default: return "чат"
        }
    }

    private var previewEmptyText: String {
        conversation.kind == "channel" ? "Публикаций пока нет" : "Сообщений пока нет"
    }
}

private struct SavedMessagesAvatar: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(SavedMessagesStyle.gradient)
            SavedBookmarkGlyph()
                .fill(Color.white)
                .frame(width: size * 0.52, height: size * 0.52)
                .shadow(color: Color.black.opacity(0.10), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

private extension ConversationView {
    private var lifecycleBoundConversationView: some View {
        presentationBoundConversationView
            .onAppear {
                chatAppearance = AloChatAppearanceStore.read(for: conversation)
                previousMessageCount = visibleConversationItems.count
                app.startConversationLive(conversation)
                let requestedTopicId = app.consumeRequestedForumTopic(roomId: conversation.roomId)
                if requestedTopicId > 0,
                   conversation.forumTopics.contains(where: { $0.id == requestedTopicId && !$0.isHidden }) {
                    activeTopicId = requestedTopicId
                }
                if activeTopicId > 0 {
                    app.selectForumTopic(
                        conversation: conversation,
                        topicId: activeTopicId,
                        replaceComposer: app.messageText.isEmpty
                    )
                }
            }
            .onChange(of: conversation.peerId) { _, _ in
                chatAppearance = AloChatAppearanceStore.read(for: conversation)
                bottomAnchorFrame = .zero
                measuredMessageFrames = [:]
                shouldFollowKeyboardToBottom = false
                hasUserScrolledConversation = false
                didInitialScrollToBottom = false
                previousMessageCount = 0
                scrollMeasurements.dates = [:]
                scrollMeasurements.bottomScrollRevision = nil
                dateHeaderController.reset()
                activeTopicId = conversation.forumTopics.first(where: { $0.isGeneral && !$0.isHidden })?.id
                    ?? conversation.forumTopics.first(where: { !$0.isClosed && !$0.isHidden })?.id
                    ?? 0
                app.startConversationLive(conversation)
                if activeTopicId > 0 {
                    app.selectForumTopic(
                        conversation: conversation,
                        topicId: activeTopicId,
                        replaceComposer: true
                    )
                }
                DispatchQueue.main.async {
                    previousMessageCount = visibleConversationItems.count
                }
            }
            .onChange(of: conversation.forumTopics) { _, topics in
                guard !topics.contains(where: { $0.id == activeTopicId && !$0.isHidden }) else { return }
                activeTopicId = topics.first(where: { $0.isGeneral && !$0.isHidden })?.id
                    ?? topics.first(where: { !$0.isClosed && !$0.isHidden })?.id
                    ?? 0
            }
            .onChange(of: isBlockedDirectPeer) { _, isBlocked in
                guard isBlocked else { return }
                composerFocused = false
                AloKeyboard.dismiss()
                cancelRecording()
                clearSelection()
                closeMessageActions()
            }
            .task(id: activeRecordingMode == nil ? "" : (activeRecordingMode == .circle ? "circle" : "voice")) {
                // The server forgets "typing" after ~4.5 s, so refresh while recording.
                guard let action = activeRecordingMode.map({ $0 == .circle ? "circle" : "voice" }) else { return }
                while !Task.isCancelled {
                    app.sendRecordingActivity(action)
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            .onChange(of: app.messageText) { _, newValue in
                app.sendTypingIfNeeded()
                app.scheduleForumTopicDraftSync(
                    conversation: conversation,
                    topicId: activeTopicId,
                    text: newValue
                )
            }
            .onChange(of: actionMessage != nil || isChatDetailsPresented || selectionMode || activeRecordingMode != nil || activeCallKind != nil) { _, blocked in
                blocksParentSwipe = blocked
            }
            .sheet(isPresented: $isAutoDeletePresented) {
                ChatAutoDeleteSheet(conversation: conversation).environmentObject(app)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let screenHeight = keyWindow?.screen.bounds.height ?? UIScreen.main.bounds.height
                let nextHeight = max(0, screenHeight - frame.minY)
                keyboardAnimationDuration = max(
                    0.01,
                    (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
                )
                keyboardAnimationCurveRaw =
                    (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
                    ?? UIView.AnimationCurve.easeInOut.rawValue

                if keyboardHeight == 0, nextHeight > 0 {
                    shouldFollowKeyboardToBottom = ChatKeyboardFollowPolicy.shouldFollow(
                        hasUserScrolledConversation: hasUserScrolledConversation,
                        isNearBottom: isNearConversationBottom(tolerance: 48),
                        isEmpty: visibleConversationItems.isEmpty
                    )
                }

                withAnimation(keyboardTransitionAnimation) {
                    keyboardHeight = nextHeight
                }

                if nextHeight == 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + keyboardAnimationDuration) {
                        shouldFollowKeyboardToBottom = false
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackDidStart)) { notification in
                guard let attachmentId = notification.object as? String else { return }
                let title = (notification.userInfo?["title"] as? String)?.ifBlank("Голосовое сообщение") ?? "Голосовое сообщение"
                let speed = notification.userInfo?["speed"] as? Double
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    activeVoicePlayback = ActiveVoicePlayback(
                        attachmentId: attachmentId,
                        title: title,
                        isPlaying: notification.userInfo?["isPlaying"] as? Bool ?? true,
                        speed: speed ?? activeVoicePlayback?.speed ?? 1
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackDidStop)) { notification in
                guard let attachmentId = notification.object as? String else { return }
                if activeVoicePlayback?.attachmentId == attachmentId {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                        activeVoicePlayback = nil
                    }
                }
            }
            .onDisappear {
                scrollMeasurements.bottomScrollRevision = nil
                dateHeaderController.reset()
                blocksParentSwipe = false
                cancelRecording()
            }
#if DEBUG
            .task {
                if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"),
                   UserDefaults.standard.string(forKey: "ALO_UI_MESSENGER_CONTENT") == "appearance" {
                    isChatAppearancePresented = true
                }
                guard UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"),
                      UserDefaults.standard.string(forKey: "ALO_UI_MESSENGER_CONTENT") == "circle-draft",
                      localAttachments.isEmpty else { return }
                // Real encrypted playback, but explicitly generated local media;
                // no camera, account, network upload, or fake sent message.
                let sample = await AloMessengerSampleMedia.make()
                guard let source = sample.video,
                      let draft = try? await Task.detached(priority: .userInitiated, operation: {
                          try AloDraftAttachmentStore.makeRecordedCircle(sourceURL: source)
                      }).value else { return }
                handleRecordedAttachment(draft, duration: 3, waveform: [], sendImmediately: false)
            }
#endif
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: selectionMode)
            .animation(.spring(response: 0.26, dampingFraction: 0.86), value: activeVoicePlayback)
            .sheet(isPresented: forwardPickerBinding) {
                ForwardTargetSheet(
                    conversations: app.bootstrap?.conversations ?? [],
                    currentPeerId: conversation.peerId
                ) { target in
                    guard let message = forwardPickerMessage else { return }
                    applyForward(message, to: target)
                }
            }
            .confirmationDialog("Удалить сообщение", isPresented: deleteDialogBinding, titleVisibility: .visible) {
                Button("Удалить у меня", role: .destructive) {
                    deleteSelected(mode: "me")
                }
                if deleteCandidatesCanBeRemovedForEveryone {
                    Button("Удалить у всех", role: .destructive) {
                        deleteSelected(mode: "everyone")
                    }
                }
                Button("Отмена", role: .cancel) {
                    deleteCandidateIds = []
                }
            }
    }

    private var presentationBoundConversationView: some View {
        conversationRoot
            .sheet(isPresented: $isAttachmentSheetPresented, onDismiss: {
                if pendingPollPresentation {
                    pendingPollPresentation = false
                    isPollComposerPresented = true
                }
            }) {
                ChatAttachmentSheet(
                    attachments: $localAttachments,
                    caption: $app.messageText,
                    selfDestructSeconds: $mediaSelfDestructSeconds,
                    canAttachMedia: canSendMedia,
                    canCreatePoll: canComposeMessages,
                    contacts: shareableContacts,
                    onShareContact: { contact in
                        app.shareContact(
                            contact,
                            topicId: activeForumTopic?.id ?? 0
                        )
                    },
                    onShareStaticLocation: { coordinate in
                        app.shareStaticLocation(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude,
                            topicId: activeForumTopic?.id ?? 0
                        )
                    },
                    onShareLiveLocation: { coordinate, expiresAt in
                        app.shareLiveLocation(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude,
                            expiresAt: expiresAt,
                            topicId: activeForumTopic?.id ?? 0
                        )
                    },
                    onCreatePoll: {
                        pendingPollPresentation = true
                        isAttachmentSheetPresented = false
                    }
                )
            }
            .sheet(isPresented: $isPollComposerPresented) {
                ChatPollComposerSheet { definition, scheduledAt in
                    app.sendPoll(
                        definition,
                        topicId: activeForumTopic?.id ?? 0,
                        scheduledAt: scheduledAt
                    )
                }
            }
            .sheet(isPresented: $isSendOptionsPresented) {
                ChatSendOptionsSheet(
                    canSendWhenOnline: canSendWhenOnline,
                    canRepeat: canRepeatCurrentDraft,
                    hasScheduledMessages: !scheduledMessages.isEmpty,
                    onSendSilently: {
                        sendCurrentDraft(silent: true)
                    },
                    onSendWhenOnline: {
                        sendCurrentDraft(sendWhenOnline: true)
                    },
                    onSchedule: {
                        scheduledSendDate = max(
                            scheduledSendDate,
                            Date().addingTimeInterval(60)
                        )
                        isScheduleComposerPresented = true
                    },
                    onRepeat: {
                        isRecurringScheduleComposerPresented = true
                    },
                    onShowScheduled: {
                        isScheduledMessagesPresented = true
                    }
                )
            }
            .sheet(isPresented: $isScheduleComposerPresented) {
                ChatScheduleMessageSheet(date: $scheduledSendDate) {
                    let date = scheduledSendDate
                    isScheduleComposerPresented = false
                    sendCurrentDraft(scheduledDate: date)
                }
            }
            .sheet(isPresented: $isRecurringScheduleComposerPresented) {
                ChatRecurringScheduleSheet { draft in
                    app.createRecurringMessageSchedule(
                        rule: draft.rule,
                        startsAt: draft.startsAt,
                        occurrences: draft.occurrences,
                        silent: draft.silent,
                        topicId: activeForumTopic?.id ?? 0
                    )
                }
            }
            .sheet(item: $scheduledMessageToReschedule) { message in
                ChatScheduleMessageSheet(
                    date: $rescheduledSendDate,
                    title: "Изменить время",
                    actionTitle: "Сохранить"
                ) {
                    let date = rescheduledSendDate
                    scheduledMessageToReschedule = nil
                    app.rescheduleMessage(message, at: date)
                }
            }
            .sheet(isPresented: $isScheduledMessagesPresented) {
                ChatScheduledMessagesSheet(
                    messages: scheduledMessages,
                    onReschedule: { message in
                        isScheduledMessagesPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            beginRescheduling(message)
                        }
                    },
                    onCancel: { message in
                        app.cancelScheduledMessage(message)
                    }
                )
            }
            .sheet(isPresented: $isComposerContentPickerPresented) {
                ChatComposerContentPicker { emoji in
                    app.messageText.append(emoji)
                    composerFocused = true
                } onSticker: { sticker in
                    app.sendCatalogAttachment(
                        sticker.messageAttachment,
                        topicId: activeForumTopic?.id ?? 0,
                        replyToMessageId: replyingToMessage?.id ?? 0
                    )
                    replyingToMessage = nil
                } onGIF: { gif in
                    app.sendCatalogAttachment(
                        gif.messageAttachment,
                        topicId: activeForumTopic?.id ?? 0,
                        replyToMessageId: replyingToMessage?.id ?? 0
                    )
                    replyingToMessage = nil
                } onLocalGIFAttachment: { attachment in
                    guard localAttachments.count < 10 else {
                        app.errorMessage = "Можно прикрепить не более 10 файлов."
                        return
                    }
                    localAttachments.append(attachment)
                }
            }
            .sheet(item: $messageAssistantRequest) { request in
                ChatMessageAssistantSheet(
                    request: request,
                    onTranslate: { targetLanguage in
                        try await app.translateMessage(request.message, targetLanguage: targetLanguage)
                    },
                    onTranscribe: { language in
                        try await app.transcribeVoiceMessage(request.message, language: language)
                    }
                )
            }
            .fullScreenCover(item: $localPreviewAttachment) { attachment in
                LocalAttachmentFullscreenPreview(
                    attachment: attachment,
                    accentColor: chatAppearance.outgoingColor
                )
            }
            .fullScreenCover(item: $activeMediaViewer) { viewer in
                ChatMediaViewer(
                    state: viewer,
                    onDismiss: { activeMediaViewer = nil }
                )
                .environmentObject(app)
            }
            .sheet(isPresented: $isChatAppearancePresented) {
                ChatAppearanceSheet(
                    appearance: chatAppearance,
                    onApply: { updated in
                        chatAppearance = updated
                        AloChatAppearanceStore.save(updated, for: conversation)
                    },
                    onUseDefault: {
                        AloChatAppearanceStore.clear(for: conversation)
                        chatAppearance = AloChatAppearanceStore.readGlobal()
                    }
                )
            }
    }

}

private struct SavedBookmarkGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x / 30,
                y: rect.minY + rect.height * y / 30
            )
        }

        var path = Path()
        path.move(to: point(8, 2))
        path.addLine(to: point(22, 2))
        path.addCurve(
            to: point(26, 6),
            control1: point(24.210_938, 2),
            control2: point(26, 3.789_062)
        )
        path.addLine(to: point(26, 27.378_906))
        path.addCurve(
            to: point(24.5, 28.878_906),
            control1: point(26, 28.207_031),
            control2: point(25.328_125, 28.878_906)
        )
        path.addCurve(
            to: point(23.437_5, 28.437_5),
            control1: point(24.101_562, 28.878_906),
            control2: point(23.718_75, 28.718_75)
        )
        path.addLine(to: point(15.707_031, 20.707_031))
        path.addCurve(
            to: point(14.292_969, 20.707_031),
            control1: point(15.316_406, 20.316_406),
            control2: point(14.683_594, 20.316_406)
        )
        path.addLine(to: point(6.562_5, 28.437_5))
        path.addCurve(
            to: point(4.437_5, 28.437_5),
            control1: point(5.976_562, 29.023_438),
            control2: point(5.023_438, 29.023_438)
        )
        path.addCurve(
            to: point(4, 27.378_906),
            control1: point(4.156_25, 28.156_25),
            control2: point(4, 27.777_344)
        )
        path.addLine(to: point(4, 6))
        path.addCurve(
            to: point(8, 2),
            control1: point(4, 3.789_062),
            control2: point(5.789_062, 2)
        )
        path.closeSubpath()
        return path
    }
}

private enum SavedMessagesStyle {
    static let gradient = LinearGradient(
        colors: [
            Color(red: 114.0 / 255, green: 213.0 / 255, blue: 253.0 / 255),
            Color(red: 42.0 / 255, green: 158.0 / 255, blue: 241.0 / 255)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

private struct SavedMessagesIntroIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(SavedMessagesStyle.gradient)
            SavedBookmarkGlyph()
                .fill(Color.white)
                .frame(width: size * 0.52, height: size * 0.52)
                .shadow(color: Color.black.opacity(0.12), radius: 1.5, y: 1)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: AloTheme.accent.opacity(0.20), radius: 16, y: 8)
    }
}

private struct ActiveVoicePlayback: Equatable {
    let attachmentId: String
    let title: String
    let isPlaying: Bool
    var speed: Double
}

private struct ChatCallLogMeta: Equatable {
    let callType: String
    let status: String
    let durationSec: Int
    let scope: String
}

struct AloChatAppearance: Codable, Equatable {
    var preset = "classic"
    var gradientStyle = "diagonal"
    var patternStyle = "ink"
    var wallpaperHue = 211.0
    var outgoingHue = 211.0
    var incomingHue = 226.0
    var wallpaperBrightness = 0.02
    var outgoingBrightness = 0.78
    var incomingBrightness = 0.16
    var patternIntensity = 0.055
    var compactSpacing = false

    var wallpaperTop: Color {
        if usesNeutralDarkWallpaper {
            let base = max(0.012, min(0.10, wallpaperBrightness))
            return Color(white: base)
        }
        return Color(hue: wallpaperHue / 360, saturation: 0.72, brightness: wallpaperBrightness)
    }

    var wallpaperBottom: Color {
        if usesNeutralDarkWallpaper {
            let base = max(0.018, min(0.13, wallpaperBrightness + 0.028))
            return Color(white: base)
        }
        return Color(
            hue: ((wallpaperHue + 12).truncatingRemainder(dividingBy: 360)) / 360,
            saturation: 0.70,
            brightness: min(1, wallpaperBrightness + 0.11)
        )
    }

    var outgoingColor: Color {
        Color(hue: outgoingHue / 360, saturation: 0.88, brightness: outgoingBrightness)
    }

    var incomingColor: Color {
        Color(hue: incomingHue / 360, saturation: 0.24, brightness: incomingBrightness)
    }

    private var usesNeutralDarkWallpaper: Bool {
        ["classic", "black", "graphite"].contains(preset.lowercased()) && wallpaperBrightness <= 0.12
    }

    /// Dark-mode counterparts of Telegram's built-in Classic, Night, Night
    /// Accent and Tinted foundations.  They preserve Alo's typography and
    /// contrast rather than cloning Telegram assets or interface chrome.
    static let presets: [(id: String, title: String, value: AloChatAppearance)] = [
        ("classic", "Классика", AloChatAppearance(
            wallpaperHue: 220, outgoingHue: 211, incomingHue: 226,
            wallpaperBrightness: 0.02, outgoingBrightness: 0.78, incomingBrightness: 0.16,
            patternIntensity: 0.055
        )),
        ("night", "Ночь", AloChatAppearance(
            preset: "night", gradientStyle: "vertical", patternStyle: "ink",
            wallpaperHue: 216, outgoingHue: 205, incomingHue: 214,
            wallpaperBrightness: 0.075, outgoingBrightness: 0.68, incomingBrightness: 0.19,
            patternIntensity: 0.075
        )),
        ("nightAccent", "Ночной акцент", AloChatAppearance(
            preset: "nightAccent", gradientStyle: "diagonal", patternStyle: "line",
            wallpaperHue: 208, outgoingHue: 205, incomingHue: 212,
            wallpaperBrightness: 0.12, outgoingBrightness: 0.75, incomingBrightness: 0.23,
            patternIntensity: 0.085
        )),
        ("tinted", "Тонированная", AloChatAppearance(
            preset: "tinted", gradientStyle: "glow", patternStyle: "ink",
            wallpaperHue: 250, outgoingHue: 242, incomingHue: 255,
            wallpaperBrightness: 0.11, outgoingBrightness: 0.70, incomingBrightness: 0.22,
            patternIntensity: 0.075
        )),
        ("emerald", "Изумруд", AloChatAppearance(
            preset: "emerald", gradientStyle: "vertical", patternStyle: "line",
            wallpaperHue: 165, outgoingHue: 162, incomingHue: 174,
            wallpaperBrightness: 0.10, outgoingBrightness: 0.67, incomingBrightness: 0.20,
            patternIntensity: 0.07
        )),
        ("sunset", "Закат", AloChatAppearance(
            preset: "sunset", gradientStyle: "glow", patternStyle: "none",
            wallpaperHue: 294, outgoingHue: 325, incomingHue: 292,
            wallpaperBrightness: 0.10, outgoingBrightness: 0.77, incomingBrightness: 0.21,
            patternIntensity: 0
        ))
    ]

    static let accentHues = [211.0, 164, 272, 326, 28, 48]

    private enum CodingKeys: String, CodingKey {
        case preset
        case gradientStyle
        case patternStyle
        case wallpaperHue
        case outgoingHue
        case incomingHue
        case wallpaperBrightness
        case outgoingBrightness
        case incomingBrightness
        case patternIntensity
        case compactSpacing
    }

    init(
        preset: String = "classic",
        gradientStyle: String = "diagonal",
        patternStyle: String = "ink",
        wallpaperHue: Double = 220,
        outgoingHue: Double = 211,
        incomingHue: Double = 226,
        wallpaperBrightness: Double = 0.02,
        outgoingBrightness: Double = 0.78,
        incomingBrightness: Double = 0.16,
        patternIntensity: Double = 0.055,
        compactSpacing: Bool = false
    ) {
        self.preset = preset
        self.gradientStyle = gradientStyle
        self.patternStyle = patternStyle
        self.wallpaperHue = wallpaperHue
        self.outgoingHue = outgoingHue
        self.incomingHue = incomingHue
        self.wallpaperBrightness = wallpaperBrightness
        self.outgoingBrightness = outgoingBrightness
        self.incomingBrightness = incomingBrightness
        self.patternIntensity = patternIntensity
        self.compactSpacing = compactSpacing
    }

    init(from decoder: Decoder) throws {
        let defaults = AloChatAppearance()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = try container.decodeIfPresent(String.self, forKey: .preset) ?? defaults.preset
        gradientStyle = try container.decodeIfPresent(String.self, forKey: .gradientStyle) ?? defaults.gradientStyle
        patternStyle = try container.decodeIfPresent(String.self, forKey: .patternStyle) ?? defaults.patternStyle
        wallpaperHue = try container.decodeIfPresent(Double.self, forKey: .wallpaperHue) ?? defaults.wallpaperHue
        outgoingHue = try container.decodeIfPresent(Double.self, forKey: .outgoingHue) ?? defaults.outgoingHue
        incomingHue = try container.decodeIfPresent(Double.self, forKey: .incomingHue) ?? defaults.incomingHue
        wallpaperBrightness = try container.decodeIfPresent(Double.self, forKey: .wallpaperBrightness) ?? defaults.wallpaperBrightness
        outgoingBrightness = try container.decodeIfPresent(Double.self, forKey: .outgoingBrightness) ?? defaults.outgoingBrightness
        incomingBrightness = try container.decodeIfPresent(Double.self, forKey: .incomingBrightness) ?? defaults.incomingBrightness
        patternIntensity = try container.decodeIfPresent(Double.self, forKey: .patternIntensity) ?? defaults.patternIntensity
        compactSpacing = try container.decodeIfPresent(Bool.self, forKey: .compactSpacing) ?? defaults.compactSpacing
    }
}

enum AloChatAppearanceStore {
    private static let globalKey = "alo.chat.appearance.global"

    static func read(for conversation: AloConversationDetail) -> AloChatAppearance {
        let defaults = UserDefaults.standard
#if DEBUG
        if defaults.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"),
           let preset = defaults.string(forKey: "ALO_UI_MESSENGER_APPEARANCE"),
           let appearance = AloChatAppearance.presets.first(where: { $0.id == preset })?.value {
            return appearance
        }
        if defaults.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"), defaults.bool(forKey: "ALO_UI_MESSENGER_SURFACE") {
            return AloChatAppearance(preset: "ocean", wallpaperHue: 196, wallpaperBrightness: 0.65, patternIntensity: 0.22)
        }
#endif
        // A conversation appearance must win over the app-wide default. The
        // old implementation read the global value first and wrote every
        // change back to that value, so colouring one chat silently recoloured
        // every other chat too.
        if let data = defaults.data(forKey: legacyKey(for: conversation)),
           let decoded = try? JSONDecoder().decode(AloChatAppearance.self, from: data) {
            let value = migrate(decoded)
            if value != decoded { save(value, for: conversation) }
            return value
        }
        return readGlobal()
    }

    static func readGlobal() -> AloChatAppearance {
        guard let data = UserDefaults.standard.data(forKey: globalKey),
              let decoded = try? JSONDecoder().decode(AloChatAppearance.self, from: data) else {
            return AloChatAppearance()
        }
        let value = migrate(decoded)
        if value != decoded { saveGlobal(value) }
        return value
    }

    static func saveGlobal(_ appearance: AloChatAppearance) {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        UserDefaults.standard.set(data, forKey: globalKey)
    }

    static func save(_ appearance: AloChatAppearance, for conversation: AloConversationDetail) {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        UserDefaults.standard.set(data, forKey: legacyKey(for: conversation))
    }

    static func clear(for conversation: AloConversationDetail) {
        UserDefaults.standard.removeObject(forKey: legacyKey(for: conversation))
    }

    private static func migrate(_ appearance: AloChatAppearance) -> AloChatAppearance {
        var value = appearance
        let legacyClassicId = ["tele", "gram"].joined()
        if value.preset.lowercased() == legacyClassicId {
            value.preset = "classic"
        }
        if value.preset == "classic", abs(value.wallpaperBrightness - 0.22) < 0.001 {
            value.wallpaperBrightness = 0.02
        }
        // Only migrate the exact former default. Deliberately customised chats
        // retain their selected colour and texture.
        if value.preset == "classic",
           abs(value.outgoingBrightness - 0.98) < 0.001,
           abs(value.incomingBrightness - 0.18) < 0.001,
           abs(value.patternIntensity - 0.09) < 0.001 {
            value.outgoingBrightness = 0.78
            value.incomingBrightness = 0.16
            value.patternIntensity = 0.04
        }
        // The new stock look uses the supplied chat sketch at a restrained
        // opacity. Only migrate the exact old stock value; a customised chat
        // is never silently recoloured.
        if value.preset == "classic",
           abs(value.outgoingBrightness - 0.78) < 0.001,
           abs(value.incomingBrightness - 0.16) < 0.001,
           (abs(value.patternIntensity - 0.04) < 0.001 || abs(value.patternIntensity) < 0.001) {
            value.patternStyle = "ink"
            value.patternIntensity = 0.055
        }
        return value
    }

    private static func legacyKey(for conversation: AloConversationDetail) -> String {
        let target = conversation.kind == "group" ? conversation.roomId : conversation.peerId
        return "alo.chat.appearance.\(conversation.kind).\(target)"
    }
}

struct ConversationView: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: AloConversationDetail
    @Binding var blocksParentSwipe: Bool

    @State private var localAttachments = [AloLocalAttachment]()
    @State private var mediaSelfDestructSeconds = 0
    @State private var isAttachmentSheetPresented = false
    @State private var isComposerContentPickerPresented = false
    @State private var isPollComposerPresented = false
    @State private var isAutoDeletePresented = false
    @State private var pendingPollPresentation = false
    @State private var isSendOptionsPresented = false
    @State private var isScheduleComposerPresented = false
    @State private var isRecurringScheduleComposerPresented = false
    @State private var scheduledSendDate = Date().addingTimeInterval(3600)
    @State private var scheduledMessageToReschedule: AloChatMessage?
    @State private var rescheduledSendDate = Date().addingTimeInterval(3600)
    @State private var isScheduledMessagesPresented = false
    @State private var localPreviewAttachment: AloLocalAttachment?
    @State private var selectedMessageIds = Set<Int>()
    @State private var selectionMode = false
    @State private var actionMessage: AloChatMessage?
    @State private var actionMessageFrame: CGRect?
    @State private var messageAssistantRequest: ChatMessageAssistantRequest?
    @State private var activeMediaViewer: ChatMediaViewerState?
    @State private var editingMessage: AloChatMessage?
    @State private var replyingToMessage: AloChatMessage?
    @State private var deleteCandidateIds = [Int]()
    @State private var forwardPickerMessage: AloChatMessage?
    @State private var recordingMode: ChatRecordingMode = .voice
    @State private var activeRecordingMode: ChatRecordingMode?
    @State private var isFinalizingCircle = false
    @State private var isFinalizingVoice = false
    @State private var isRecordingLocked = false
    @State private var recordingDrag = AloRecordingDrag()
    @State private var isRecorderReady = false
    @State private var recordingStartedAt = Date()
    @State private var recordedDurations = [UUID: TimeInterval]()
    @State private var recordedWaveforms = [UUID: [CGFloat]]()
    @State private var activeVoicePlayback: ActiveVoicePlayback?
    @State private var circlePlayback = AloCirclePlayback()
    @State private var historyProjectionCache = AloChatHistoryProjectionCache()
    @State private var isChatDetailsPresented = false
    @State private var isChatAppearancePresented = false
    @State private var chatAppearance: AloChatAppearance
    @State private var activeCallKind: ChatCallKind?
    @State private var isCallMinimized = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var composerChromeHeight: CGFloat = ChatComposerMetrics.collapsedChromeHeight
    @State private var keyboardAnimationDuration: TimeInterval = 0.25
    @State private var keyboardAnimationCurveRaw = UIView.AnimationCurve.easeInOut.rawValue
    @State private var previousMessageCount: Int
    @State private var scrollMeasurements = AloChatScrollMeasurements()
    private var measuredMessageFrames: [Int: CGRect] {
        get { scrollMeasurements.frames }
        nonmutating set { scrollMeasurements.frames = newValue }
    }
    private var bottomAnchorFrame: CGRect {
        get { scrollMeasurements.bottom }
        nonmutating set { scrollMeasurements.bottom = newValue }
    }
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var shouldFollowKeyboardToBottom = false
    @State private var hasUserScrolledConversation = false
    @State private var historyNavigation = AloChatHistoryNavigationState()
    private var showsHistoryDownButton: Bool { historyNavigation.showsDownButton }
    @State private var unseenMessages = AloChatUnseenMessages()
    #if DEBUG
    @State private var didInjectUnseenFixture = false
    #endif
    @State private var didInitialScrollToBottom = false
    @StateObject private var dateHeaderController = AloChatDateHeaderController()
    @State private var measuredTopChromeHeight: CGFloat = 0
    @State private var requestedMessageScrollId: Int?
    @State private var preservesComposerFocusForReaction = false
    @State private var activeTopicId: Int
    @State private var isForumSearchPresented = false
    @State private var forumSearchText = ""
    // Meter updates belong to the recording controls, not the entire history.
    @State private var audioRecorder = ChatAudioRecorder()
    @StateObject private var circleRecorder = ChatCircleRecorder()
    @FocusState private var composerFocused: Bool

    /// The transient date is anchored to the bottom of the live top chrome,
    /// not to a magic screen coordinate. That keeps it directly below the
    /// title/presence capsule, or below the voice/circle player when it is
    /// shown in that same slot.
    private var hasTopPlaybackChrome: Bool {
        circlePlayback.item != nil || activeVoicePlayback != nil
    }

    private var conversationTopChromeHeight: CGFloat {
        if measuredTopChromeHeight > 0 { return measuredTopChromeHeight }
        var height = AloChatMetrics.headerHeight + 16
        if app.pendingSendError(in: conversation) != nil { height += 68 }
        if !pinnedMessages.isEmpty { height += 51 }
        if conversation.groupPolicy?.isForumGroup == true, !conversation.forumTopics.isEmpty {
            height += 51
            if isForumSearchPresented { height += 51 }
        }
        if hasTopPlaybackChrome { height += 51 }
        return height
    }

    private var floatingDateTopOffset: CGFloat {
        conversationTopChromeHeight
    }

    private var floatingDateTrackingTop: CGFloat {
        floatingDateTopOffset + AloChatDateMetrics.sectionHeight + keyboardMessagesLift
    }

    private var isChannelConversation: Bool {
        conversation.entityType == "channel" || conversation.groupPolicy?.kind == "channel"
    }

    private var scheduledMessages: [AloChatMessage] {
        conversation.items
            .filter(\.isScheduled)
            .sorted { lhs, rhs in
                if lhs.scheduledAt == rhs.scheduledAt {
                    return lhs.scheduledMessageId < rhs.scheduledMessageId
                }
                return lhs.scheduledAt < rhs.scheduledAt
            }
    }

    private var canStartChannelVideoChat: Bool {
        guard isChannelConversation else { return false }
        if conversation.groupMemberRole == "owner" { return true }
        guard conversation.groupMemberRole == "admin" else { return false }
        let rights = conversation.groupPolicy?.memberAdminRights ?? [:]
        return rights.isEmpty || rights["manageVideoChats"] == true
    }

    private var isBlockedDirectPeer: Bool {
        app.isDirectPeerBlocked(conversation)
    }

    private var canSendWhenOnline: Bool {
        conversation.kind == "direct" &&
            conversation.peerId > 0 &&
            conversation.peerId != app.bootstrap?.me.id
    }

    private var canComposeMessages: Bool {
        guard !isBlockedDirectPeer else { return false }
        guard conversation.kind == "group" || conversation.roomId > 0 else { return true }
        if conversation.groupMemberRole == "owner" { return true }
        if isChannelConversation {
            guard conversation.groupMemberRole == "admin" else { return false }
            let rights = conversation.groupPolicy?.memberAdminRights ?? [:]
            return rights.isEmpty || rights["postMessages"] == true
        }
        if conversation.groupMemberRole == "admin" { return true }
        guard !memberRestrictionsAreActive || conversation.groupPolicy?.memberRestrictions["sendMessages"] != true else {
            return false
        }
        return conversation.groupPolicy?.defaultPermissions["sendMessages"] != false
    }

    private var canSendMedia: Bool {
        guard canComposeMessages else { return false }
        guard conversation.kind == "group" || conversation.roomId > 0 else { return true }
        if conversation.groupMemberRole == "owner" || conversation.groupMemberRole == "admin" { return true }
        guard !memberRestrictionsAreActive || conversation.groupPolicy?.memberRestrictions["sendMedia"] != true else {
            return false
        }
        return conversation.groupPolicy?.defaultPermissions["sendMedia"] != false
    }

    private var shareableContacts: [AloEntitySummary] {
        let currentUserId = app.bootstrap?.me.id
        return (app.bootstrap?.searchUsers ?? []).filter {
            !$0.isChannel && $0.id > 0 && $0.id != currentUserId
        }
    }

    private var memberRestrictionsAreActive: Bool {
        guard let value = conversation.groupPolicy?.memberRestrictedUntil,
              !value.isEmpty else { return true }
        guard let until = ISO8601DateFormatter().date(from: value) else { return true }
        return until > Date()
    }

    private func hasAdministrativeRight(_ right: String) -> Bool {
        if conversation.groupMemberRole == "owner" { return true }
        guard conversation.groupMemberRole == "admin" else { return false }
        let rights = conversation.groupPolicy?.memberAdminRights ?? [:]
        return rights.isEmpty || rights[right] == true
    }

    private func canEditMessage(_ message: AloChatMessage) -> Bool {
        guard !isBlockedDirectPeer else { return false }
        guard message.id > 0,
              message.chatCallLogMeta == nil,
              AloPollCodec.decode(message.body) == nil,
              !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                message.attachments.contains(where: { ["image", "video"].contains($0.type) }) else { return false }
        if message.senderId == app.bootstrap?.me.id { return true }
        return isChannelConversation && hasAdministrativeRight("editMessages")
    }

    private func canDeleteMessageForEveryone(_ message: AloChatMessage) -> Bool {
        guard message.id > 0 else { return false }
        if conversation.kind != "group" && conversation.roomId <= 0 { return true }
        if message.senderId == app.bootstrap?.me.id { return true }
        return hasAdministrativeRight("deleteMessages")
    }

    private var deleteCandidatesCanBeRemovedForEveryone: Bool {
        let candidates = deleteCandidateIds.compactMap { id in
            conversation.items.first(where: { $0.id == id })
        }
        return candidates.count == deleteCandidateIds.count &&
            !candidates.isEmpty &&
            candidates.allSatisfy(canDeleteMessageForEveryone)
    }

    private var canPinMessages: Bool {
        guard !isBlockedDirectPeer else { return false }
        if conversation.kind != "group" && conversation.roomId <= 0 { return true }
        if hasAdministrativeRight("pinMessages") { return true }
        return conversation.groupPolicy?.defaultPermissions["pinMessages"] == true
    }

    private var pinnedMessages: [AloChatMessage] {
        let messages = conversation.pinnedMessageIds.compactMap { id in
            conversation.items.first(where: { $0.id == id })
        }
        guard conversation.groupPolicy?.isForumGroup == true, activeTopicId > 0 else {
            return messages
        }
        return messages.filter { $0.topicId == activeTopicId }
    }

    init(conversation: AloConversationDetail, blocksParentSwipe: Binding<Bool>) {
        self.conversation = conversation
        _blocksParentSwipe = blocksParentSwipe
        _chatAppearance = State(initialValue: AloChatAppearanceStore.read(for: conversation))
        _previousMessageCount = State(initialValue: conversation.items.count)
        _activeTopicId = State(
            initialValue: conversation.forumTopics.first(where: { $0.isGeneral && !$0.isHidden })?.id
                ?? conversation.forumTopics.first(where: { !$0.isClosed && !$0.isHidden })?.id
                ?? 0
        )
    }

    var body: some View {
        lifecycleBoundConversationView
            .environment(\.aloCirclePlayback, circlePlayback)
            .onAppear(perform: updateCircleQueue)
            .onChange(of: conversation.items) { _, _ in updateCircleQueue() }
            .onChange(of: circlePlayback.focusRequest) { _, _ in
                requestedMessageScrollId = circlePlayback.item?.messageID
            }
            .onChange(of: activeTopicId) { _, _ in circlePlayback.stop(); updateCircleQueue() }
            .onReceive(NotificationCenter.default.publisher(for: .aloMediaPlaybackDidStart)) { note in
                if let id = note.object as? String, circlePlayback.item?.id != id { circlePlayback.stop() }
            }
            .onDisappear { circlePlayback.stop() }
    }

    private func updateCircleQueue() {
        if let item = circlePlayback.item, !conversation.items.contains(where: { $0.id == item.messageID }) {
            circlePlayback.stop()
        }
        circlePlayback.setQueue(visibleConversationItems.filter { !$0.isScheduled && $0.selfDestructSeconds == 0 }.flatMap { message in
            message.attachments.filter(\.isCircleLike).compactMap { attachment in
                app.api.absoluteURL(attachment.url).map {
                    AloCircleQueueItem(id: attachment.id, messageID: message.id, url: $0, title: app.voicePlaybackTitle(for: message))
                }
            }
        })
    }

    private var conversationLayers: some View {
        ZStack(alignment: .top) {
            chatBackground
                .ignoresSafeArea(.container)
                .ignoresSafeArea(.keyboard, edges: .bottom)

            messagesList
                .offset(y: -keyboardMessagesLift)

            if visibleConversationItems.isEmpty {
                GeometryReader { proxy in
                    let topInset = max(104, conversationTopChromeHeight + 12)
                    let bottomInset = emptyStateBottomInset
                    let availableHeight = max(0, proxy.size.height - topInset - bottomInset)

                    ChatConversationEmptyState(
                        isSaved: conversation.entityType == "saved",
                        isChannel: isChannelConversation
                    )
                        .padding(.horizontal, 34)
                        .frame(
                            width: proxy.size.width,
                            height: availableHeight,
                            alignment: .center
                        )
                        .offset(y: topInset)
                }
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(2)
            }

            chatChromeBlur
                .ignoresSafeArea(.container, edges: .vertical)
                .allowsHitTesting(false)
                // Messages may scroll behind this material, but never through
                // the status/header area. Keep it above the list itself.
                .zIndex(8)

            AloChatFloatingDateHeader(controller: dateHeaderController,
                anchor: floatingDateTopOffset, isSuppressed: actionMessage != nil || isChatDetailsPresented)
                .zIndex(9)

            // The header must always be above a transient date. The previous
            // ordering let the date paint over the safe area and status bar.
            AnyView(conversationTopChrome)
                .zIndex(16)

            // Keep one presentation host across inline/floating transfers and
            // stop/play. UIKit owns its fade and drag; SwiftUI must not remove
            // that host in the middle of an interactive settle.
            AloFloatingCircle(playback: circlePlayback, accent: chatAppearance.outgoingColor,
                isPresented: !isChatDetailsPresented && actionMessage == nil) { requestedMessageScrollId = $0 }
                    .padding(.top, conversationTopChromeHeight + 44)
                    .padding(.bottom, composerChromeHeight + keyboardComposerLift + 12 + AloCirclePresentation.bottomControlsClearance)
                    // An actively dragged media overlay can cross the header.
                    // Dates remain below chrome, but the circle must not vanish
                    // behind it when the finger leaves the docking container.
                    .zIndex(18)

            if isChatDetailsPresented {
                ChatPeerInfoPanel(
                    conversation: conversation,
                    messages: conversation.items,
                    onClose: dismissChatDetailsAfterInteractiveExit,
                    onOpenProfile: {
                        dismissChatDetails()
                        if conversation.kind != "group" {
                            app.openProfile(userId: conversation.peerId)
                        }
                    },
                    onAudioCall: { await performCall(.audio) },
                    onVideoCall: { await performCall(.video) },
                    onOpenAppearance: {
                        dismissChatDetails(response: 0.28)
                        isChatAppearancePresented = true
                    },
                    onOpenMessage: { messageId in
                        dismissChatDetails()
                        requestedMessageScrollId = messageId
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
                .zIndex(30)
            }

            if let activeCallKind {
                if isCallMinimized {
                    ChatCallMinimizedPill(
                        kind: activeCallKind,
                        conversation: conversation,
                        onExpand: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                                isCallMinimized = false
                            }
                        },
                        onEnd: endCall
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(40)
                } else {
                    ChatCallScreen(
                        kind: activeCallKind,
                        conversation: conversation,
                        onMinimize: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                                isCallMinimized = true
                            }
                        },
                        onEnd: endCall
                    )
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(40)
                }
            }

            if activeRecordingMode == .circle {
                CircleRecordingOverlay(
                    startedAt: recordingStartedAt,
                    ready: isRecorderReady,
                    recorder: circleRecorder,
                    accentColor: chatAppearance.outgoingColor,
                    topChrome: conversationTopChromeHeight,
                    bottomChrome: composerChromeHeight + keyboardComposerLift,
                    onSend: { finishRecording(sendImmediately: false) }
                )
                .transition(.opacity)
                .zIndex(18)
            }
        }
    }

    private var conversationRoot: some View {
        conversationLayers
        .coordinateSpace(name: "conversationRoot")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            circlePlayback.viewport = CGRect(x: frame.minX, y: frame.minY + conversationTopChromeHeight,
                width: frame.width, height: max(0, frame.height - conversationTopChromeHeight - composerChromeHeight - keyboardComposerLift))
        }
        .onChange(of: keyboardComposerLift) { _, lift in
            circlePlayback.viewport.size.height = max(0, scrollViewportHeight - conversationTopChromeHeight - composerChromeHeight - lift)
        }
        .onChange(of: keyboardMessagesLift) { _, _ in updateDateHeader() }
        .onChange(of: conversationTopChromeHeight) { old, height in
            circlePlayback.viewport.origin.y += height - old
            circlePlayback.viewport.size.height = max(0, scrollViewportHeight - height - composerChromeHeight - keyboardComposerLift)
            updateDateHeader()
        }
        .overlay(alignment: .bottom) {
            composerChromeOverlay
        }
        .overlay {
            messageActionOverlay
        }
        .onPreferenceChange(ChatComposerHeightPreferenceKey.self) { height in
            guard height > 0, abs(height - composerChromeHeight) > 0.5 else { return }
            composerChromeHeight = height
        }
    }

    private var conversationTopChrome: some View {
        // Material and interaction stay bounded to the actual controls, not
        // a full-screen stack with an invisible spacer over the history.
        conversationTopContent
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if height > 0, abs(measuredTopChromeHeight - height) > 0.5 {
                    measuredTopChromeHeight = height
                    updateDateHeader()
                }
            }
    }

    private var conversationTopContent: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, AloChatMetrics.headerHorizontalInset)
                .padding(.top, AloChatMetrics.headerTopInset)
                .padding(.bottom, 8)

            if let error = app.pendingSendError(in: conversation) {
                Button { app.retryPendingMessages(in: conversation) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(error).lineLimit(3)
                            Text("Сообщение сохранено · Нажмите, чтобы повторить")
                                .font(.system(size: 12))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(AloTheme.text)
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("alo.chat.send-error")
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            }

            if let pinnedMessage = pinnedMessages.first {
                ChatPinnedMessageBar(
                    message: pinnedMessage,
                    count: pinnedMessages.count,
                    onTap: { requestedMessageScrollId = pinnedMessage.id }
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 7)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if conversation.groupPolicy?.isForumGroup == true, !conversation.forumTopics.isEmpty {
                forumTopicPicker
                    .padding(.horizontal, 18)
                    .padding(.bottom, 7)
                if isForumSearchPresented {
                    forumTopicSearchField
                        .padding(.horizontal, 18)
                        .padding(.bottom, 7)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            if circlePlayback.item != nil {
                AloCirclePlaybackBar(playback: circlePlayback) { requestedMessageScrollId = $0 }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 7)
                    .transition(.opacity)
            } else if let activeVoicePlayback {
                VoicePlaybackTopBar(
                    playback: activeVoicePlayback,
                    onToggle: { toggleTopVoicePlayback(activeVoicePlayback.attachmentId) },
                    onSpeed: { cycleVoicePlaybackSpeed(activeVoicePlayback.attachmentId) },
                    onClose: { stopTopVoicePlayback(activeVoicePlayback.attachmentId) }
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 7)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

        }
    }

    private var composerChromeOverlay: some View {
        bottomSafeAreaChrome
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ChatComposerHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .offset(y: -keyboardComposerLift)
    }

    @ViewBuilder
    private var messageActionOverlay: some View {
        if let actionMessage {
            MessageActionOverlay(
                message: actionMessage,
                replyToMessage: visibleConversationItems.first(where: { $0.id == actionMessage.replyToMessageId }),
                targetFrame: actionMessageFrame,
                pollState: pollState(for: actionMessage),
                appearance: chatAppearance,
                canEditMessage: canEditMessage(actionMessage),
                canPinMessage: canPinMessages && actionMessage.chatCallLogMeta == nil,
                isPinned: conversation.pinnedMessageIds.contains(actionMessage.id),
                onCopy: {
                    if AloPollCodec.decode(actionMessage.body) == nil,
                       !actionMessage.body.isEmpty {
                        UIPasteboard.general.string = actionMessage.body
                    }
                    closeMessageActions()
                },
                onForward: {
                    beginForward(actionMessage)
                    closeMessageActions()
                },
                onTranslate: {
                    let message = actionMessage
                    closeMessageActions()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        messageAssistantRequest = ChatMessageAssistantRequest(
                            message: message,
                            kind: .translation
                        )
                    }
                },
                onTranscribe: {
                    let message = actionMessage
                    closeMessageActions()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        messageAssistantRequest = ChatMessageAssistantRequest(
                            message: message,
                            kind: .transcription
                        )
                    }
                },
                onReply: {
                    beginReply(actionMessage)
                    closeMessageActions()
                },
                onPin: {
                    app.toggleMessagePin(actionMessage)
                    closeMessageActions()
                },
                onEdit: {
                    beginEdit(actionMessage)
                    closeMessageActions()
                },
                onReact: { emoji in
                    toggleReactionPreservingComposer(actionMessage, emoji: emoji)
                    closeMessageActions()
                },
                onSelect: {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1)) {
                        selectionMode = true
                        selectedMessageIds = [actionMessage.id]
                        self.actionMessage = nil
                    }
                },
                onDelete: {
                    deleteCandidateIds = [actionMessage.id]
                    closeMessageActions()
                },
                onReschedule: {
                    let message = actionMessage
                    closeMessageActions()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        beginRescheduling(message)
                    }
                },
                onViewScheduled: {
                    closeMessageActions()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        isScheduledMessagesPresented = true
                    }
                },
                onCancelScheduled: {
                    app.cancelScheduledMessage(actionMessage)
                    closeMessageActions()
                },
                onClosePoll: {
                    guard let state = pollState(for: actionMessage) else { return }
                    app.closePoll(state.definition.id)
                    closeMessageActions()
                },
                onCancel: closeMessageActions
            )
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var bottomSafeAreaChrome: some View {
        bottomChrome
        .background(alignment: .bottom) {
            if keyboardHeight > 0 {
                // iOS 26 keyboards have transparent rounded top corners. The
                // fade must continue *behind* the keyboard, not end at its top
                // and expose an abrupt stripe of bright wallpaper below it.
                let tailHeight = keyboardHeight + windowBottomSafeAreaInset + 40
                AloChatEdgeBackdrop(edge: .bottom, wallpaper: chatAppearance)
                    .frame(height: composerChromeHeight + AloChatEdge.bottom.inwardExtension + tailHeight)
                    .offset(y: tailHeight + keyboardScrimDrop)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        if activeCallKind == nil && !isChatDetailsPresented {
            Group {
                if selectionMode {
                    MessageSelectionToolbar(
                        count: selectedMessageIds.count,
                        onCancel: clearSelection,
                        onForward: beginForwardSelected,
                        onDelete: { deleteCandidateIds = Array(selectedMessageIds) }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if isBlockedDirectPeer {
                    blockedPeerUnavailableBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if canComposeMessages {
                    composer
                        .aloChatSwipeControl()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    channelReadOnlyBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, AloInputMetrics.inset)
            .padding(.top, ChatComposerMetrics.verticalChromePadding)
            .padding(.bottom, ChatComposerMetrics.verticalChromePadding)
        }
    }

    private var channelReadOnlyBar: some View {
        Text("У вас нет права публиковать в этом канале")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AloTheme.muted)
            .frame(maxWidth: .infinity, minHeight: ChatComposerMetrics.controlSize)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(AloTheme.surface)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AloTheme.border, lineWidth: 1)
            )
            .accessibilityLabel("Публикация недоступна")
    }

    private var blockedPeerUnavailableBar: some View {
        Label(AloDirectContactPolicy.unavailableMessage, systemImage: "person.fill.xmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AloTheme.muted)
            .frame(maxWidth: .infinity, minHeight: ChatComposerMetrics.controlSize)
            .padding(.horizontal, 16)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(AloTheme.surface)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AloTheme.border, lineWidth: 1)
            )
            .accessibilityIdentifier("alo.blocked-peer-unavailable")
            .accessibilityLabel("Связь недоступна")
    }

    private var keyboardComposerLift: CGFloat {
        guard keyboardHeight > 0,
              activeCallKind == nil,
              !isChatDetailsPresented else { return 0 }
        return max(0, keyboardHeight - windowBottomSafeAreaInset + ChatComposerMetrics.keyboardGap)
    }

    private var keyboardScrimLift: CGFloat {
        guard keyboardHeight > 0,
              activeCallKind == nil,
              !isChatDetailsPresented else { return 0 }
        return max(0, keyboardHeight - windowBottomSafeAreaInset - 2)
    }

    private var keyboardScrimDrop: CGFloat {
        max(0, keyboardComposerLift - keyboardScrimLift)
    }

    private var messageListBottomInset: CGFloat {
        guard activeCallKind == nil,
              activeRecordingMode != .circle,
              !isChatDetailsPresented else { return 8 }
        return composerChromeHeight + 8
    }

    private var emptyStateBottomInset: CGFloat {
        messageListBottomInset + keyboardComposerLift
    }

    private var keyboardMessagesLift: CGFloat {
        shouldFollowKeyboardToBottom ? keyboardComposerLift : 0
    }

    private var keyboardTransitionAnimation: Animation {
        let duration = keyboardAnimationDuration
        switch UIView.AnimationCurve(rawValue: keyboardAnimationCurveRaw) {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .linear:
            return .linear(duration: duration)
        case .easeInOut:
            return .easeInOut(duration: duration)
        case .none:
            return .easeOut(duration: duration)
        @unknown default:
            return .easeOut(duration: duration)
        }
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private var windowBottomSafeAreaInset: CGFloat {
        keyWindow?.safeAreaInsets.bottom ?? 0
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { !deleteCandidateIds.isEmpty },
            set: { isPresented in
                if !isPresented { deleteCandidateIds = [] }
            }
        )
    }

    private var forwardPickerBinding: Binding<Bool> {
        Binding(
            get: { forwardPickerMessage != nil },
            set: { isPresented in
                if !isPresented { forwardPickerMessage = nil }
            }
        )
    }

    private var messagesList: some View {
        let snapshot = historyProjection
        let items = snapshot.messages
        let dayKeys = snapshot.dayKeys
        let itemsByID = snapshot.byID
        let projectedPolls = snapshot.polls
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(spacing: chatAppearance.compactSpacing ? 3 : 8) {
                            Color.clear.frame(height: max(132, conversationTopChromeHeight + 16))
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || dayKeys[index - 1] != dayKeys[index] {
                                    AloChatInlineDateHeader(controller: dateHeaderController, id: item.id,
                                        label: snapshot.dateLabels[item.id] ?? "")
                                }
                                if shouldShowTopicSeparator(at: index, items: items),
                                   let topic = topic(for: item) {
                                    ChatDatePill(
                                        label: "\(topic.iconEmoji) \(topic.title)\(topic.isClosed ? " · закрыта" : "")"
                                    )
                                    .padding(.vertical, 2)
                                }
                                Group {
                                    if let systemEvent = AloChatSystemEventCodec.decode(item.body) {
                                        ChatSystemEventPill(
                                            event: systemEvent,
                                            isMine: item.senderId == app.bootstrap?.me.id
                                        )
                                    } else if let callMeta = item.chatCallLogMeta,
                                       callMeta.scope == "group" {
                                        GroupCallHistoryEvent(message: item, meta: callMeta)
                                    } else {
                                        ChatMessageRow(
                                            message: item,
                                            replyToMessage: itemsByID[item.replyToMessageId],
                                            pollState: snapshot.pollIDsByMessage[item.id].flatMap { projectedPolls[$0] },
                                            appearance: chatAppearance,
                                            isMine: !isChannelConversation && item.senderId == app.bootstrap?.me.id,
                                            showsSenderAttribution: conversation.kind == "group" && !isChannelConversation,
                                            isPending: app.isChatMessagePending(item),
                                            isSelected: selectedMessageIds.contains(item.id),
                                            selectionMode: selectionMode,
                                            isContextMenuPresented: actionMessage != nil || isChatDetailsPresented,
                                            availableWidth: max(0, viewport.size.width - 28),
                                            onTap: { handleMessageTap(item) },
                                            onReact: { emoji in
                                                toggleReactionPreservingComposer(item, emoji: emoji)
                                            },
                                            onPollVote: { optionId in
                                                vote(in: item, optionId: optionId)
                                            },
                                            canClosePoll: item.senderId == app.bootstrap?.me.id,
                                            onClosePoll: {
                                                guard let state = pollState(for: item) else { return }
                                                app.closePoll(state.definition.id)
                                            },
                                            onOpenMediaGallery: { items, startIndex in
                                                activeMediaViewer = ChatMediaViewerState(
                                                    items: items,
                                                    startIndex: startIndex,
                                                    isSensitive: item.selfDestructSeconds > 0,
                                                    topicId: item.topicId,
                                                    reportsScreenshot: item.selfDestructSeconds > 0 &&
                                                        item.senderId != app.bootstrap?.me.id &&
                                                        !isChannelConversation
                                                )
                                            },
                                            onOpenDiscussion: {
                                                app.openChannelPostDiscussion(postId: item.channelPostId)
                                            },
                                            onLongPress: { frame in
                                                AloHaptics.impact(.medium)
                                                withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.36, dampingFraction: 1)) {
                                                    actionMessageFrame = frame
                                                    actionMessage = item
                                                }
                                            },
                                            onOpenReply: { requestedMessageScrollId = $0 }
                                        )
                                    }
                                }
                                .id(item.id)
                                .transition(.scale(scale: 0.86).combined(with: .opacity))
                                .background {
                                    GeometryReader { rowProxy in
                                        Color.clear.preference(
                                            key: ChatMessageFramePreferenceKey.self,
                                            value: [item.id: rowProxy.frame(in: .named("conversationScroll"))]
                                        )
                                    }
                                }
                            }
                        }
                        // Keep the destination outside LazyVStack: an
                        // unrealized footer cannot resolve a reliable scroll ID.
                        Color.clear
                            .frame(height: messageListBottomInset)
                            .id(bottomAnchorId)
                            .background {
                                GeometryReader { bottomProxy in
                                    Color.clear.preference(
                                        key: ChatBottomAnchorFramePreferenceKey.self,
                                        value: bottomProxy.frame(in: .named("conversationScroll"))
                                    )
                                }
                            }
                    }
                    .frame(minHeight: viewport.size.height, alignment: .bottom)
                    .padding(.horizontal, 14)
                    .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: snapshot.ids)
                }
                .scrollDismissesKeyboard(.interactively)
                .coordinateSpace(name: "conversationScroll")
                .onPreferenceChange(ChatMessageFramePreferenceKey.self, perform: updateFloatingDate)
                .onPreferenceChange(AloChatDateFramesKey.self) { frames in
                    scrollMeasurements.dates = frames
                    updateDateHeader()
                }
                .onPreferenceChange(ChatBottomAnchorFramePreferenceKey.self) { frame in
                    bottomAnchorFrame = frame
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting {
                        hasUserScrolledConversation = true
                        scrollMeasurements.bottomScrollRevision = nil
                        withAnimation(reduceMotion ? nil : AloPressFeedback.release) {
                            historyNavigation.userInteracted()
                        }
                    }
                    dateHeaderController.scrollingChanged(phase == .interacting || phase == .decelerating)
                }
                .onScrollGeometryChange(for: AloChatHistoryViewport.self) { geometry in
                    AloChatHistoryViewport(contentHeight: geometry.contentSize.height,
                        offsetY: geometry.contentOffset.y,
                        viewportHeight: max(0, geometry.containerSize.height - max(0, keyboardComposerLift - keyboardMessagesLift)),
                        bottomInset: geometry.contentInsets.bottom)
                } action: { _, state in
                    // Navigation uses scroll geometry, independently of the
                    // cadence at which lazy message-frame preferences arrive.
                    if state.isAtBottom {
                        hasUserScrolledConversation = false
                        unseenMessages.reachedBottom()
                    }
                    withAnimation(reduceMotion ? nil : AloPressFeedback.release) {
                        historyNavigation.update(state)
                    }
                }
                .accessibilityIdentifier("alo.chat.history")
                .simultaneousGesture(TapGesture().onEnded {
                    guard !preservesComposerFocusForReaction else { return }
                    composerFocused = false
                    AloKeyboard.dismiss()
                })
                .onAppear {
                    scrollViewportHeight = viewport.size.height
                    guard !didInitialScrollToBottom else { return }
                    didInitialScrollToBottom = true
                    unseenMessages.reset(messages: visibleConversationItems)
                    scrollToBottom(proxy, animation: nil)
                }
                .onChange(of: viewport.size.height) { _, height in
                    scrollViewportHeight = height
                }
                .onChange(of: conversation.items.count) { _, _ in
                    let newVisibleCount = visibleConversationItems.count
                    if newVisibleCount > previousMessageCount {
                        let lastMessage = visibleConversationItems.last
                        let isOwnMessage = lastMessage?.senderId == app.bootstrap?.me.id
                        let shouldFollow = isOwnMessage || ChatKeyboardFollowPolicy.shouldFollow(
                            hasUserScrolledConversation: hasUserScrolledConversation,
                            isNearBottom: isNearConversationBottom(),
                            isEmpty: visibleConversationItems.isEmpty
                        )
                        if shouldFollow {
                            scrollToBottom(proxy, animation: .easeOut(duration: 0.22))
                        }
                    }
                    previousMessageCount = newVisibleCount
                }
                .onChange(of: activeTopicId) { _, _ in
                    previousMessageCount = visibleConversationItems.count
                    historyNavigation = AloChatHistoryNavigationState()
                    measuredMessageFrames = [:]
                    scrollMeasurements.dates = [:]
                    scrollMeasurements.bottomScrollRevision = nil
                    dateHeaderController.reset()
                    hasUserScrolledConversation = false
                    unseenMessages.reset(messages: visibleConversationItems)
                    scrollToBottom(proxy, animation: .easeOut(duration: 0.18))
                }
                .onChange(of: snapshot.ids) { _, _ in
                    unseenMessages.update(messages: visibleConversationItems,
                        currentUserID: app.bootstrap?.me.id ?? 0,
                        isAtBottom: !hasUserScrolledConversation && !showsHistoryDownButton)
                }
                .onChange(of: requestedMessageScrollId) { _, messageId in
                    guard let messageId else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(messageId, anchor: .center)
                    }
                    requestedMessageScrollId = nil
                }
                .overlay(alignment: .bottomTrailing) {
                    if showsHistoryDownButton, !selectionMode, actionMessage == nil,
                       activeRecordingMode == nil, activeCallKind == nil, !isChatDetailsPresented {
                        AloChatHistoryDownButton(unreadCount: max(unseenMessages.unseenIDs.count,
                            activeForumTopicState?.unreadCount ?? 0)) {
                            AloHaptics.selection()
                            let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.25)
                            withAnimation(animation) {
                                if keyboardHeight > 0 { shouldFollowKeyboardToBottom = true }
                            }
                            // Edge-based scrolling can stop at LazyVStack's
                            // estimated content height before it materializes
                            // the newest rows. Resolve the actual bottom ID on
                            // the next layout turn, after keyboard-follow changes.
                            scrollToBottom(proxy, animation: animation)
                        }
                        .aloChatSwipeControl()
                        .padding(.trailing, AloInputMetrics.inset)
                        .padding(.bottom, composerChromeHeight + 2 + max(0, keyboardComposerLift - keyboardMessagesLift))
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                    }
                }
                #if DEBUG
                .onChange(of: showsHistoryDownButton) { _, shown in
                    // Deterministic offline UI test of messages arriving while
                    // reading older history. No real account/network writes.
                    guard shown, !didInjectUnseenFixture,
                          UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"),
                          UserDefaults.standard.string(forKey: "ALO_UI_MESSENGER_CONTENT") == "unread-navigation" else { return }
                    didInjectUnseenFixture = true
                    guard let current = app.activeConversation else { return }
                    let arrivals = (0..<2).map { index in AloChatMessage([
                        "id": 991000 + index, "senderId": 990002, "recipientId": 990001,
                        "body": "Новое тестовое сообщение \(index + 1)", "createdAt": "2026-10-05T12:00:00Z"
                    ]) }
                    app.activeConversation = current.replacingItems(current.items + arrivals)
                }
                #endif
            }
        }
    }

    private var header: some View {
        // Keep navigation in fixed slots; a larger Dynamic Type title can grow
        // below without moving Back away from the media viewer's close button.
        HStack(alignment: .top, spacing: 12) {
            AloChatCircleButton(systemImage: "chevron.left", label: "Назад к чатам") {
                composerFocused = false
                AloKeyboard.dismiss()
                app.closeConversation()
            }
            .accessibilityIdentifier("alo.chat.back")
            .frame(height: AloChatMetrics.headerHeight)

            Button {
                composerFocused = false
                AloKeyboard.dismiss()
                presentChatDetails()
            } label: {
                VStack(spacing: 1) {
                    Text(conversation.title)
                        .font(.headline)
                        .foregroundStyle(AloTheme.text)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if case .updating = app.connectionState {
                            ProgressView().controlSize(.mini)
                        }
                        Text(conversationPresenceLabel)
                    }
                    .font(.caption)
                    .foregroundStyle(conversationPresenceIsActive ? AloTheme.accent : AloTheme.muted)
                    .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: AloChatMetrics.headerHeight)
                .modifier(AloChatGlass())
                .contentShape(Capsule())
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityIdentifier("alo.chat.info")
            .contextMenu { chatMenuItems }

            Button {
                composerFocused = false
                AloKeyboard.dismiss()
                presentChatDetails()
            } label: {
                Group {
                    if conversation.entityType == "saved" {
                        SavedMessagesAvatar(size: AloChatMetrics.control)
                    } else {
                        AloAvatar(
                            name: conversation.title,
                            url: conversation.avatarUrl,
                            size: AloChatMetrics.control,
                            colorSeed: String(conversation.peerId)
                        )
                    }
                }
                .overlay(Circle().stroke(AloTheme.border, lineWidth: 0.5))
                .contentShape(Circle())
            }
            .buttonStyle(AloChatPressStyle())
            .accessibilityLabel("Профиль собеседника")
            .frame(height: AloChatMetrics.headerHeight)
            .contextMenu { chatMenuItems }
        }
    }

    @ViewBuilder private var chatMenuItems: some View {
        if conversation.entityType != "saved", !isChannelConversation {
            Button("Аудиозвонок", systemImage: "phone") { startCall(.audio) }.disabled(isBlockedDirectPeer)
            Button("Видеозвонок", systemImage: "video") { startCall(.video) }.disabled(isBlockedDirectPeer)
        }
        if conversation.entityType != "saved", conversation.kind == "direct" || conversation.canManageGroup {
            Button("Автоудаление сообщений", systemImage: "timer") { isAutoDeletePresented = true }
        }
    }

    private func presentChatDetails() {
        // Block the chat-level interactive dismissal before this overlay is
        // rendered. Otherwise the first horizontal gesture can close the chat
        // instead of returning from the profile to that same chat.
        blocksParentSwipe = true
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            isChatDetailsPresented = true
        }
    }

    private func dismissChatDetails(response: Double = 0.34) {
        withAnimation(.spring(response: response, dampingFraction: 0.9)) {
            isChatDetailsPresented = false
        }
        blocksParentSwipe = actionMessage != nil
    }

    // ChatPeerInfoPanel has already completed its own interactive translation
    // when it invokes this closure. Removing it without another transition
    // prevents one stale frame of the profile from flashing back at x = 0.
    private func dismissChatDetailsAfterInteractiveExit() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isChatDetailsPresented = false
        }
        blocksParentSwipe = actionMessage != nil
    }

    private var forumTopicPicker: some View {
        Menu {
            ForEach(conversation.forumTopics.filter { !$0.isHidden }) { topic in
                Button {
                    app.persistForumTopicDraftNow(
                        conversation: conversation,
                        topicId: activeTopicId,
                        text: app.messageText
                    )
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                        activeTopicId = topic.id
                    }
                    app.selectForumTopic(
                        conversation: conversation,
                        topicId: topic.id,
                        replaceComposer: true
                    )
                } label: {
                    let state = conversation.forumTopicStates.first {
                        $0.topicId == topic.id
                    }
                    Label(
                        "\(topic.title)\((state?.unreadCount ?? 0) > 0 ? " · \(state?.unreadCount ?? 0)" : "")\(topic.isClosed ? " · закрыта" : "")",
                        systemImage: state?.muted == true
                            ? "speaker.slash"
                            : topic.id == activeTopicId
                                ? "checkmark.circle.fill"
                                : "bubble.left"
                    )
                }
            }
            if let state = activeForumTopicState {
                Divider()
                Button {
                    app.setForumTopicMuted(
                        conversation: conversation,
                        topicId: state.topicId,
                        muted: !state.muted
                    )
                } label: {
                    Label(
                        state.muted ? "Включить уведомления" : "Выключить уведомления",
                        systemImage: state.muted ? "speaker.wave.2" : "speaker.slash"
                    )
                }
            }
            if let topic = activeForumTopic,
               let url = AloDeepLinkTarget.forumTopicURL(
                   roomId: conversation.roomId,
                   topicId: topic.id
               ) {
                Divider()
                Button {
                    UIPasteboard.general.string = url.absoluteString
                    app.notice = "Ссылка на тему скопирована."
                } label: {
                    Label("Скопировать ссылку на тему", systemImage: "link")
                }
            }
            Divider()
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    isForumSearchPresented.toggle()
                    if !isForumSearchPresented { forumSearchText = "" }
                }
            } label: {
                Label(
                    isForumSearchPresented ? "Закрыть поиск" : "Поиск в теме",
                    systemImage: isForumSearchPresented ? "xmark" : "magnifyingglass"
                )
            }
        } label: {
            HStack(spacing: 8) {
                Text(activeForumTopic?.iconEmoji ?? "💬")
                    .font(.system(size: 15))
                Text(activeForumTopic?.title ?? "Темы")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                if let unreadCount = activeForumTopicState?.unreadCount,
                   unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6)
                        .frame(minHeight: 20)
                        .background(Capsule().fill(chatAppearance.outgoingColor))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(AloTheme.text)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(AloTheme.surface.opacity(0.92)))
            .overlay(Capsule().stroke(AloTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var forumTopicSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
            TextField("Поиск в теме", text: $forumSearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, weight: .semibold))
            if !forumSearchText.isEmpty {
                Button {
                    forumSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AloTheme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Capsule().fill(AloTheme.surface.opacity(0.94)))
        .overlay(Capsule().stroke(AloTheme.border, lineWidth: 1))
    }

    private var composer: some View {
        let recordedDraft = localAttachments.first(where: \.isRecordedDraft)
        let visibleAttachments = localAttachments.filter { !$0.isRecordedDraft }
        let composerCornerRadius: CGFloat = app.messageText.count > 40 || app.messageText.contains("\n") ? AloInputMetrics.multiLineRadius : AloInputMetrics.singleLineRadius

        return VStack(spacing: 8) {
            if let editingMessage {
                EditDraftBar(preview: chatPreviewText(editingMessage)) {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                        self.editingMessage = nil
                        app.messageText = ""
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if app.pendingForwardDraft != nil {
                ForwardDraftBar(title: app.pendingForwardTitle.ifBlank("Переслать сообщение")) {
                    app.pendingForwardDraft = nil
                    app.pendingForwardTitle = ""
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let replyingToMessage {
                ReplyDraftBar(message: replyingToMessage) {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                        self.replyingToMessage = nil
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !mentionCandidates.isEmpty {
                MentionSuggestionsBar(members: mentionCandidates) { member in
                    insertMention(member)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !visibleAttachments.isEmpty {
                LocalAttachmentStrip(
                    attachments: visibleAttachments,
                    accentColor: chatAppearance.outgoingColor,
                    onAdd: { isAttachmentSheetPresented = true },
                    onOpen: { localPreviewAttachment = $0 }
                ) { attachment in
                    localAttachments.removeAll { $0.id == attachment.id }
                }
            }

            HStack(alignment: .bottom, spacing: AloInputMetrics.spacing) {
                if isFinalizingCircle || isFinalizingVoice {
                    ProgressView(isFinalizingCircle ? "Подготовка кружка…" : "Подготовка голосового…")
                        .font(.subheadline).tint(AloTheme.accent)
                        .frame(maxWidth: .infinity, minHeight: ChatComposerMetrics.controlSize)
                        .modifier(AloChatPanelGlass(radius: 22))
                } else if let activeRecordingMode {
                    AloRecordingLevelsView(recorder: audioRecorder) { levels in
                    RecordingComposerPanel(
                        mode: activeRecordingMode,
                        startedAt: recordingStartedAt,
                        ready: isRecorderReady,
                        isLocked: isRecordingLocked,
                        drag: recordingDrag,
                        accentColor: chatAppearance.outgoingColor,
                        levels: levels,
                        onCancel: cancelRecording,
                        onStop: { finishRecording(sendImmediately: false) }
                    )
                    }
                    .transition(.opacity)
                } else if let recordedDraft {
                    RecordedDraftComposerPanel(
                        attachment: recordedDraft,
                        duration: recordedDurations[recordedDraft.id] ?? 0,
                        levels: recordedWaveforms[recordedDraft.id] ?? recordedDraft.waveform,
                        accentColor: chatAppearance.outgoingColor,
                        onRemove: {
                            discardRecordedDraft(recordedDraft)
                            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.88)) {
                                localAttachments.removeAll { $0.id == recordedDraft.id }
                                recordedDurations[recordedDraft.id] = nil
                                recordedWaveforms[recordedDraft.id] = nil
                            }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    ChatComposerButton(systemName: "paperclip") {
                        composerFocused = false
                        AloKeyboard.dismiss()
                        isAttachmentSheetPresented = true
                    }
                    .accessibilityLabel("Прикрепить")
                    .accessibilityIdentifier("alo.chat.attach")
                    .transition(.scale(scale: 0.88).combined(with: .opacity))

                    TextField("Сообщение", text: $app.messageText, axis: .vertical)
                        .focused($composerFocused)
                        .accessibilityLabel("Сообщение")
                        .accessibilityIdentifier("alo.chat.composer")
                        .foregroundStyle(AloTheme.text)
                        .font(.body)
                        .padding(.leading, 12)
                        .padding(.trailing, 44)
                        .padding(.vertical, 5)
                        .lineLimit(1...5)
                        .frame(minHeight: ChatComposerMetrics.visualSize)
                        .modifier(AloChatPanelGlass(radius: composerCornerRadius, role: .control))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("alo.chat.composer.field")
                        .modifier(AloSocialControlGeometry())
                        .frame(minHeight: ChatComposerMetrics.controlSize)
                        .contentShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            Button {
                                composerFocused = false
                                isComposerContentPickerPresented = true
                            } label: {
                                Image(systemName: "face.smiling")
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundStyle(AloTheme.muted)
                                    .frame(width: AloInputMetrics.touchHeight, height: AloInputMetrics.touchHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(AloChatPressStyle())
                            .accessibilityLabel("Эмодзи, стикеры и GIF")
                            .accessibilityHint("Удерживайте для форматирования текста")
                            .accessibilityIdentifier("alo.chat.expressions")
                            .contextMenu {
                                    Button("Жирный", systemImage: "bold") {
                                        applyDraftFormatting(marker: "**")
                                    }
                                    Button("Курсив", systemImage: "italic") {
                                        applyDraftFormatting(marker: "__")
                                    }
                                    Button("Подчёркнутый", systemImage: "underline") {
                                        applyDraftFormatting(marker: "++")
                                    }
                                    Button("Зачёркнутый", systemImage: "strikethrough") {
                                        applyDraftFormatting(marker: "~~")
                                    }
                                    Button("Скрытый текст", systemImage: "eye.slash") {
                                        applyDraftFormatting(marker: "||")
                                    }
                                    Button("Моноширинный", systemImage: "chevron.left.forwardslash.chevron.right") {
                                        applyDraftFormatting(marker: "`")
                                    }
                                    Button("Цитата", systemImage: "text.quote") {
                                        applyDraftQuote()
                                    }
                                    Button("Блок кода", systemImage: "curlybraces") {
                                        applyDraftCodeBlock()
                                    }
                            }
                            .padding(.trailing, 2)
                        }
                        // The input material, text and expression button are
                        // one physical surface, including while being dragged.
                        .aloElasticTouch()
                }
                ZStack {
                    AloRecordingLevelsView(recorder: audioRecorder) { levels in
                    ChatRecordSendButton(
                        mode: recordingMode,
                        canSend: !sendDisabled,
                        isEditing: editingMessage != nil,
                        isRecording: activeRecordingMode != nil,
                        isLocked: isRecordingLocked,
                        level: activeRecordingMode == .voice ? (levels.last ?? 0) : 0,
                        drag: $recordingDrag,
                        accentColor: chatAppearance.outgoingColor,
                        allowsSendOptions: editingMessage == nil,
                        onSend: { sendCurrentDraft() },
                        onShowSendOptions: { isSendOptionsPresented = true },
                        onToggleMode: toggleRecordingMode,
                        onHoldStart: startRecording,
                        onHoldEnd: finishRecording,
                        onLock: lockRecording,
                        onCancel: cancelRecording
                    )
                    }
                    .opacity(isRecordingLocked ? 0 : 1)
                    .allowsHitTesting(!isRecordingLocked && !isFinalizingCircle && !isFinalizingVoice)
                    .accessibilityHidden(isRecordingLocked)
                    if isRecordingLocked {
                        Button { finishRecording(sendImmediately: true) } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(chatAppearance.outgoingColor, in: Circle())
                        }
                        .buttonStyle(AloControlPressStyle())
                        .accessibilityLabel("Отправить запись")
                        .disabled(!isRecorderReady)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if activeRecordingMode != nil && !isRecordingLocked {
                        AloRecordingLock(progress: recordingDrag.lockProgress, onLock: lockRecording)
                            .offset(y: -108)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: localAttachments.count)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: app.pendingForwardDraft != nil)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: editingMessage?.id)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1), value: activeRecordingMode)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1), value: isRecordingLocked)
    }

    private var mentionCandidates: [AloGroupMember] {
        guard conversation.kind == "group",
              let query = activeMentionQuery else { return [] }
        return conversation.groupMembers
            .filter { !$0.username.isEmpty }
            .filter {
                query.isEmpty || $0.username.localizedCaseInsensitiveContains(query) ||
                    $0.name.localizedCaseInsensitiveContains(query)
            }
            .prefix(6)
            .map { $0 }
    }

    private var activeMentionQuery: String? {
        let text = app.messageText
        guard let at = text.lastIndex(of: "@") else { return nil }
        let before = text[..<at]
        guard before.isEmpty || before.last?.isWhitespace == true else { return nil }
        let suffix = text[at...]
        guard !suffix.contains(where: { $0.isWhitespace }) else { return nil }
        let query = String(suffix.dropFirst())
        guard query.count <= 32,
              query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return query
    }

    private func insertMention(_ member: AloGroupMember) {
        guard let at = app.messageText.lastIndex(of: "@") else { return }
        app.messageText = String(app.messageText[..<at]) + "@\\(member.username) "
        composerFocused = true
    }

    private var sendDisabled: Bool {
        if let editingMessage {
            return app.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && editingMessage.attachments.isEmpty
        }
        return app.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            localAttachments.isEmpty &&
            app.pendingForwardDraft == nil
    }

    private var canRepeatCurrentDraft: Bool {
        !app.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            localAttachments.isEmpty &&
            app.pendingForwardDraft == nil &&
            editingMessage == nil
    }

    private var chatBackground: some View {
        AloChatWallpaper(appearance: chatAppearance)
    }

    private var chatChromeBlur: some View {
        VStack(spacing: 0) {
            AloChatEdgeBackdrop(edge: .top, wallpaper: chatAppearance)
                .frame(height: AloChatEdge.top.height(chrome: conversationTopChromeHeight,
                    safeArea: keyWindow?.safeAreaInsets.top ?? 0))
            Spacer(minLength: 0)
            if keyboardHeight == 0 {
                AloChatEdgeBackdrop(edge: .bottom, wallpaper: chatAppearance)
                    .frame(height: AloChatEdge.bottom.height(chrome: composerChromeHeight,
                        safeArea: windowBottomSafeAreaInset))
            }
        }
    }

    private var conversationPresenceLabel: String {
        switch app.connectionState {
        case .updating, .unavailable:
            // Keep the current chat in place and tell the user that its state
            // is being refreshed instead of showing a stale “был недавно”.
            return "Обновление…"
        case .connected:
            if conversation.isTyping {
                switch conversation.typingAction {
                case "voice": return "записывает голосовое сообщение…"
                case "circle": return "записывает видеосообщение…"
                default: return "печатает…"
                }
            }
            return conversation.online ? "в сети" : conversation.subtitle
        }
    }

    private var conversationPresenceIsActive: Bool {
        if case .connected = app.connectionState {
            return conversation.isTyping || conversation.online
        }
        return true
    }

    private var activeForumTopic: AloForumTopic? {
        conversation.forumTopics.first(where: { $0.id == activeTopicId && !$0.isHidden })
            ?? conversation.forumTopics.first(where: { $0.isGeneral && !$0.isHidden })
            ?? conversation.forumTopics.first(where: { !$0.isClosed && !$0.isHidden })
    }

    private var activeForumTopicState: AloForumTopicState? {
        guard let topicId = activeForumTopic?.id else { return nil }
        return conversation.forumTopicStates.first(where: { $0.topicId == topicId })
    }

    private var historyProjection: AloChatHistorySnapshot {
        historyProjectionCache.snapshot(
            messages: conversation.items, canonical: conversation.canonicalPolls,
            userID: app.bootstrap?.me.id ?? 0,
            topicID: conversation.groupPolicy?.isForumGroup == true ? activeForumTopic?.id : nil,
            generalTopicID: conversation.forumTopics.first(where: { $0.isGeneral })?.id ?? 0,
            query: isForumSearchPresented ? forumSearchText : ""
        )
    }

    private var visibleConversationItems: [AloChatMessage] { historyProjection.messages }

    private func pollState(for message: AloChatMessage, states: [String: AloPollViewState]? = nil) -> AloPollViewState? {
        let snapshot = historyProjection
        guard let id = snapshot.pollIDsByMessage[message.id] else { return nil }
        return (states ?? snapshot.polls)[id]
    }

    private func vote(in message: AloChatMessage, optionId: String) {
        guard let state = pollState(for: message) else { return }
        guard !state.isClosed else { return }
        if !state.allowsRevoting, !state.selectedOptionIds.isEmpty { return }
        var selected = state.selectedOptionIds
        if state.definition.allowsMultipleAnswers {
            if selected.contains(optionId) {
                selected.remove(optionId)
            } else {
                selected.insert(optionId)
            }
        } else {
            selected = selected == [optionId] ? [] : [optionId]
        }
        guard let body = AloPollCodec.encodeVote(
            pollId: state.definition.id,
            optionIds: selected
        ) else { return }
        app.sendChatSystemEvent(
            body,
            topicId: message.topicId,
            pollDefinition: state.definition
        )
    }

    private func topic(for message: AloChatMessage) -> AloForumTopic? {
        if message.topicId > 0 {
            return conversation.forumTopics.first(where: { $0.id == message.topicId })
        }
        return conversation.forumTopics.first(where: { $0.isGeneral })
    }

    private func shouldShowTopicSeparator(at index: Int, items: [AloChatMessage]) -> Bool {
        guard conversation.groupPolicy?.isForumGroup == true,
              activeForumTopic == nil,
              items.indices.contains(index) else { return false }
        let currentTopicId = topic(for: items[index])?.id ?? 0
        guard index > 0 else { return currentTopicId > 0 }
        return currentTopicId != (topic(for: items[index - 1])?.id ?? 0)
    }

    private func updateFloatingDate(_ frames: [Int: CGRect]) {
        measuredMessageFrames = frames
        updateDateHeader()
    }

    private func updateDateHeader() {
        dateHeaderController.update(anchor: floatingDateTopOffset, rows: measuredMessageFrames,
            headers: scrollMeasurements.dates, snapshot: historyProjection, reduceMotion: reduceMotion,
            contentTranslationY: -keyboardMessagesLift)
    }

    private func isNearConversationBottom(tolerance: CGFloat = 96) -> Bool {
        if visibleConversationItems.isEmpty { return true }
        return isBottomFrameNearViewport(bottomAnchorFrame, tolerance: tolerance)
    }

    private func isBottomFrameNearViewport(_ frame: CGRect, tolerance: CGFloat) -> Bool {
        guard scrollViewportHeight > 0, frame != .zero else { return false }
        return frame.maxY <= scrollViewportHeight + tolerance
    }

    private func topVisibleMessageId(visibleTop: CGFloat? = nil) -> Int? {
        let visibleTop = visibleTop ?? floatingDateTrackingTop
        return measuredMessageFrames
            .filter { $0.value.maxY > visibleTop }
            .min(by: { $0.value.minY < $1.value.minY })?
            .key
    }

    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animation: Animation?,
        delay: TimeInterval = 0
    ) {
        let revision = UUID()
        scrollMeasurements.bottomScrollRevision = revision
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard scrollMeasurements.bottomScrollRevision == revision else { return }
            // Lazy row heights are estimates until the newest message is laid
            // out. Resolve that message, then align the always-mounted footer.
            // One proxy owns both steps; a user drag cancels the correction.
            withAnimation(animation) {
                if let lastID = visibleConversationItems.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                } else {
                    proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (animation == nil ? 0.05 : 0.3)) {
                guard scrollMeasurements.bottomScrollRevision == revision else { return }
                withAnimation(animation == nil ? nil : .easeOut(duration: 0.12)) {
                    proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    correctBottomScroll(proxy, revision: revision, animated: animation != nil, attempt: 0)
                }
            }
        }
    }

    private func correctBottomScroll(_ proxy: ScrollViewProxy, revision: UUID, animated: Bool, attempt: Int) {
        guard scrollMeasurements.bottomScrollRevision == revision else { return }
        guard AloChatBottomScrollCorrection.isNeeded(footer: bottomAnchorFrame,
            viewportHeight: scrollViewportHeight, attempt: attempt) else {
            scrollMeasurements.bottomScrollRevision = nil
            return
        }
        // The first footer target can use a stale lazy-list height while the
        // latest media/date rows materialize. Re-align against the now-measured
        // footer, with a hard retry bound and the same user-cancellable token.
        withAnimation(animated && !reduceMotion ? .easeOut(duration: 0.12) : nil) {
            proxy.scrollTo(bottomAnchorId, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            correctBottomScroll(proxy, revision: revision, animated: animated, attempt: attempt + 1)
        }
    }

    private var bottomAnchorId: String {
        "conversation-bottom-\(conversation.kind)-\(conversation.peerId)-\(conversation.roomId)"
    }

    private func handleMessageTap(_ message: AloChatMessage) {
        guard selectionMode else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            if selectedMessageIds.contains(message.id) {
                selectedMessageIds.remove(message.id)
            } else {
                selectedMessageIds.insert(message.id)
            }
            if selectedMessageIds.isEmpty {
                selectionMode = false
            }
        }
    }

    private func clearSelection() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            selectionMode = false
            selectedMessageIds = []
        }
    }

    private func closeMessageActions() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            actionMessage = nil
            actionMessageFrame = nil
        }
    }

    private func toggleReactionPreservingComposer(_ message: AloChatMessage, emoji: String) {
        guard !isBlockedDirectPeer else { return }
        let shouldKeepKeyboardVisible = composerFocused || keyboardHeight > 0
        if shouldKeepKeyboardVisible {
            preservesComposerFocusForReaction = true
        }

        app.toggleMessageReaction(message, emoji: emoji)

        guard shouldKeepKeyboardVisible else { return }
        composerFocused = true
        DispatchQueue.main.async {
            composerFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                preservesComposerFocusForReaction = false
            }
        }
    }

    private func toggleTopVoicePlayback(_ attachmentId: String) {
        NotificationCenter.default.post(name: .aloVoicePlaybackToggleRequested, object: attachmentId)
    }

    private func cycleVoicePlaybackSpeed(_ attachmentId: String) {
        guard let playback = activeVoicePlayback else { return }
        let nextSpeed: Double
        switch playback.speed {
        case ..<1.25:
            nextSpeed = 1.5
        case ..<1.75:
            nextSpeed = 2.0
        default:
            nextSpeed = 1.0
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            activeVoicePlayback = ActiveVoicePlayback(
                attachmentId: attachmentId,
                title: playback.title,
                isPlaying: playback.isPlaying,
                speed: nextSpeed
            )
        }
        NotificationCenter.default.post(
            name: .aloVoicePlaybackSpeedChanged,
            object: attachmentId,
            userInfo: ["speed": nextSpeed]
        )
        AloHaptics.selection()
    }

    private func stopTopVoicePlayback(_ attachmentId: String) {
        NotificationCenter.default.post(name: .aloVoicePlaybackStopRequested, object: attachmentId)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            activeVoicePlayback = nil
        }
    }

    private func beginForward(_ message: AloChatMessage) {
        guard message.selfDestructSeconds <= 0 else { return }
        forwardPickerMessage = message
    }

    private func beginReply(_ message: AloChatMessage) {
        guard message.id > 0 else { return }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
            editingMessage = nil
            replyingToMessage = message
            composerFocused = true
        }
    }

    private func beginEdit(_ message: AloChatMessage) {
        guard canEditMessage(message) else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            editingMessage = message
            replyingToMessage = nil
            app.pendingForwardDraft = nil
            app.pendingForwardTitle = ""
            localAttachments = []
            app.messageText = message.markupSource
            composerFocused = true
        }
    }

    private func beginRescheduling(_ message: AloChatMessage) {
        guard message.isScheduled else { return }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        rescheduledSendDate = fractional.date(from: message.scheduledAt)
            ?? ISO8601DateFormatter().date(from: message.scheduledAt)
            ?? Date().addingTimeInterval(3600)
        rescheduledSendDate = max(rescheduledSendDate, Date().addingTimeInterval(60))
        scheduledMessageToReschedule = message
    }

    private func beginForwardSelected() {
        guard let firstId = selectedMessageIds.first,
              let message = conversation.items.first(where: { $0.id == firstId }),
              message.selfDestructSeconds <= 0 else { return }
        beginForward(message)
    }

    private func applyForward(_ message: AloChatMessage, to target: AloConversationSummary) {
        app.pendingForwardDraft = AloForwardMeta(userId: message.senderId, messageId: message.id, user: nil)
        app.pendingForwardTitle = "Переслать сообщение"
        forwardPickerMessage = nil
        clearSelection()
        if target.peerId != conversation.peerId {
            app.openConversation(target)
        }
    }

    private func deleteSelected(mode: String) {
        let ids = deleteCandidateIds
        deleteCandidateIds = []
        app.deleteMessages(ids, mode: mode) {
            clearSelection()
        }
    }

    private func sendCurrentDraft(
        silent: Bool = false,
        scheduledDate: Date? = nil,
        sendWhenOnline: Bool = false
    ) {
        if let editingMessage {
            app.editMessage(editingMessage, body: app.messageText) {
                self.editingMessage = nil
                self.app.messageText = ""
            }
            return
        }

        app.sendMessage(
            localAttachments: localAttachments,
            forwardFrom: app.pendingForwardDraft,
            replyToMessageId: replyingToMessage?.id ?? 0,
            topicId: activeForumTopic?.id ?? 0,
            selfDestructSeconds: mediaSelfDestructSeconds,
            silent: silent,
            scheduledAt: scheduledDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            sendWhenOnline: sendWhenOnline
        ) {
            localAttachments = []
            mediaSelfDestructSeconds = 0
            recordedDurations = [:]
            recordedWaveforms = [:]
            app.pendingForwardDraft = nil
            app.pendingForwardTitle = ""
            replyingToMessage = nil
        }
    }

    private func applyDraftFormatting(marker: String) {
        let current = app.messageText
        guard !current.isEmpty else { return }
        if current.hasPrefix(marker),
           current.hasSuffix(marker),
           current.count >= marker.count * 2 {
            app.messageText = String(current.dropFirst(marker.count).dropLast(marker.count))
        } else {
            app.messageText = marker + current + marker
        }
        composerFocused = true
    }

    /// "> " before every line makes the draft a quote; the same again removes it.
    private func applyDraftQuote() {
        let lines = app.messageText.components(separatedBy: "\n")
        guard !app.messageText.isEmpty else { return }
        let quoted = lines.allSatisfy { $0.hasPrefix("> ") || $0.isEmpty }
        app.messageText = lines.map { line in
            quoted ? String(line.dropFirst(line.hasPrefix("> ") ? 2 : 0)) : "> " + line
        }.joined(separator: "\n")
        composerFocused = true
    }

    /// Fences the draft as a code block (``` … ```), or removes the fence.
    private func applyDraftCodeBlock() {
        let current = app.messageText
        guard !current.isEmpty else { return }
        if current.hasPrefix("```\n"), current.hasSuffix("\n```") {
            app.messageText = String(current.dropFirst(4).dropLast(4))
        } else {
            app.messageText = "```\n" + current + "\n```"
        }
        composerFocused = true
    }

    private func toggleRecordingMode() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86)) {
            recordingMode = recordingMode == .voice ? .circle : .voice
        }
        AloHaptics.selection()
    }

    private func startRecording() {
        guard sendDisabled, activeRecordingMode == nil else { return }
        guard app.calls.activeCall == nil, app.calls.groupCall.activeCall == nil else {
            app.errorMessage = "Запись недоступна во время звонка. Завершите звонок и повторите попытку."
            return
        }
        circlePlayback.stop()
        recordingStartedAt = Date()
        isRecordingLocked = false
        isRecorderReady = false
        recordingDrag = AloRecordingDrag()
        if recordingMode == .circle {
            composerFocused = false
            AloKeyboard.dismiss()
        }
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.22)) {
            activeRecordingMode = recordingMode
        }
        AloHaptics.impact(.medium)
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"),
           UserDefaults.standard.bool(forKey: "ALO_UI_RECORDING_FIXTURE"), recordingMode == .circle {
            recordingDidStart(nil)
            return
        }
#endif
        switch recordingMode {
        case .voice:
            audioRecorder.start(onReady: recordingDidStart)
        case .circle:
            circleRecorder.start(onReady: recordingDidStart, onStopped: {
                if activeRecordingMode == .circle { finishRecording() }
            })
        }
    }

    private func recordingDidStart(_ error: String?) {
        guard activeRecordingMode != nil else { return }
        if let error {
            cancelRecording()
            app.errorMessage = error
        } else {
            recordingStartedAt = Date()
            isRecorderReady = true
        }
    }

    private func lockRecording() {
        guard activeRecordingMode != nil, !isRecordingLocked else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1)) {
            isRecordingLocked = true
            recordingDrag = AloRecordingDrag()
        }
        AloHaptics.notification(.success)
    }

    private func finishRecording() {
        finishRecording(sendImmediately: false)
    }

    private func finishRecording(sendImmediately: Bool) {
        guard let mode = activeRecordingMode else { return }
        let duration = Date().timeIntervalSince(recordingStartedAt)
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.2)) {
            activeRecordingMode = nil
            isRecordingLocked = false
            recordingDrag = AloRecordingDrag()
        }
        guard isRecorderReady, duration > 0.55 else {
            audioRecorder.cancel()
            circleRecorder.cancel()
            return
        }
        AloHaptics.impact(.light)
        switch mode {
        case .voice:
            let waveform = audioRecorder.levels
            isFinalizingVoice = true
            audioRecorder.stop { attachment, extractedWaveform in
                isFinalizingVoice = false
                guard let attachment else {
                    app.errorMessage = "Не удалось сохранить голосовое сообщение. Попробуйте записать снова."
                    return
                }
                let finalWaveform = extractedWaveform.isEmpty ? waveform : extractedWaveform
                handleRecordedAttachment(
                    attachment.replacingWaveform(finalWaveform),
                    duration: duration,
                    waveform: finalWaveform,
                    sendImmediately: sendImmediately
                )
            }
        case .circle:
            isFinalizingCircle = true
            circleRecorder.stop { attachment in
                isFinalizingCircle = false
                guard app.activeConversation?.peerId == conversation.peerId else {
                    if let attachment { discardRecordedDraft(attachment) }
                    return
                }
                guard let attachment else {
                    app.errorMessage = "Кружок не записан. Проверьте доступ к камере и попробуйте снова."
                    return
                }
                handleRecordedAttachment(attachment, duration: duration, waveform: [], sendImmediately: sendImmediately)
            }
        }
    }

    private func cancelRecording() {
        guard activeRecordingMode != nil else { return }
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.2)) {
            activeRecordingMode = nil
            isRecordingLocked = false
            isRecorderReady = false
            recordingDrag = AloRecordingDrag()
        }
        audioRecorder.cancel()
        circleRecorder.cancel()
        AloHaptics.notification(.warning)
    }

    private func handleRecordedAttachment(_ attachment: AloLocalAttachment, duration: TimeInterval, waveform: [CGFloat], sendImmediately: Bool) {
        let attachment = attachment.withDuration(attachment.durationSeconds ?? duration)
        guard app.activeConversation?.peerId == conversation.peerId else {
            discardRecordedDraft(attachment)
            return
        }
        if sendImmediately {
            app.sendMessage(localAttachments: [attachment], forwardFrom: nil)
            return
        }
        let storedWaveform = waveform.isEmpty ? attachment.waveform : waveform
        localAttachments.filter(\.isRecordedDraft).forEach(discardRecordedDraft)
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)) {
            localAttachments.removeAll { $0.isRecordedDraft }
            recordedDurations = recordedDurations.filter { key, _ in
                localAttachments.contains { $0.id == key }
            }
            recordedWaveforms = recordedWaveforms.filter { key, _ in
                localAttachments.contains { $0.id == key }
            }
            localAttachments.append(attachment)
            recordedDurations[attachment.id] = attachment.durationSeconds ?? duration
            recordedWaveforms[attachment.id] = storedWaveform
        }
    }

    private func discardRecordedDraft(_ attachment: AloLocalAttachment) {
        Task.detached(priority: .utility) {
            AloDraftAttachmentStore.discard(attachment)
        }
    }

    private func startCall(_ kind: ChatCallKind) {
        Task { await performCall(kind) }
    }

    private func performCall(_ kind: ChatCallKind) async {
        guard !isBlockedDirectPeer else {
            app.errorMessage = AloDirectContactPolicy.unavailableMessage
            return
        }
        if isChannelConversation,
           (kind != .video || !canStartChannelVideoChat) {
            return
        }
        circlePlayback.stop()
        await app.calls.startCall(conversation: conversation, video: kind == .video)
    }

    private func endCall() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            activeCallKind = nil
            isCallMinimized = false
        }
    }
}

struct AloChatWallpaper: View {
    let appearance: AloChatAppearance

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .topLeading) {
                ZStack {
                    gradient

                    if appearance.patternStyle != "none", appearance.patternIntensity > 0 {
                        Image(patternAssetName)
                            .resizable()
                            .renderingMode(.template)
                            .foregroundStyle(Color.white)
                            .scaledToFill()
                            .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
                            .clipped()
                            .opacity(appearance.patternIntensity)
                    }
                }
                .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
            }
            .clipped()
    }

    static var canvasSize: CGSize {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .bounds.size ?? UIScreen.main.bounds.size
    }

    @ViewBuilder
    private var gradient: some View {
        let colors = [appearance.wallpaperTop, appearance.wallpaperBottom]
        switch appearance.gradientStyle {
        case "vertical":
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
        case "glow":
            RadialGradient(
                colors: [appearance.wallpaperBottom, appearance.wallpaperTop],
                center: .topLeading,
                startRadius: 0,
                endRadius: max(Self.canvasSize.width, Self.canvasSize.height)
            )
        default:
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var patternAssetName: String {
        appearance.patternStyle == "line" ? "AloChatPattern" : "AloChatPatternInk"
    }
}

private struct ChatConversationEmptyState: View {
    let isSaved: Bool
    let isChannel: Bool

    var body: some View {
        let cornerRadius: CGFloat = isSaved ? 24 : 20

        VStack(spacing: isSaved ? 12 : 11) {
            if isSaved {
                SavedMessagesIntroIcon(size: 72)
            } else {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 62, height: 62)
            }

            Text(isSaved ? "Избранное" : (isChannel ? "Публикаций пока нет" : "Сообщений пока нет"))
                .font(.system(size: isSaved ? 22 : 19, weight: .bold, design: .rounded))
                .foregroundStyle(AloTheme.text)

            Text(
                isSaved
                    ? "Личное облако для сообщений, фото, видео и файлов. Доступно на всех ваших устройствах."
                    : (isChannel
                        ? "Новые публикации канала появятся здесь."
                        : "Напишите первое сообщение, чтобы начать диалог.")
            )
            .font(.system(size: isSaved ? 15 : 14, weight: .medium))
            .foregroundStyle(AloTheme.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, isSaved ? 24 : 20)
        .padding(.vertical, isSaved ? 22 : 18)
        .frame(maxWidth: isSaved ? 286 : 268)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AloTheme.surface.opacity(isSaved ? 0.34 : 0.46))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isSaved ? 0.12 : 0.08),
                            Color.white.opacity(isSaved ? 0.025 : 0),
                            Color.black.opacity(isSaved ? 0.14 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if isSaved {
                ChatGlassGrain(opacity: 0.12)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(isSaved ? 0.16 : 0.11), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isSaved ? 0.26 : 0.18), radius: isSaved ? 24 : 18, y: 10)
    }
}

private struct ChatGlassGrain: View {
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            let dotCount = Int(max(90, min(260, size.width * size.height / 360)))
            for index in 0..<dotCount {
                let x = deterministicUnit(index, salt: 19) * size.width
                let y = deterministicUnit(index, salt: 47) * size.height
                let alpha = 0.18 + deterministicUnit(index, salt: 83) * 0.22
                let radius = 0.42 + deterministicUnit(index, salt: 131) * 0.58
                let color = index.isMultiple(of: 3)
                    ? Color.black.opacity(opacity * alpha)
                    : Color.white.opacity(opacity * alpha)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)),
                    with: .color(color)
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func deterministicUnit(_ index: Int, salt: Int) -> Double {
        let value = sin(Double(index * 12_989 + salt * 78_233)) * 43_758.5453
        return value - floor(value)
    }
}

struct ChatAppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AloChatAppearance
    @State private var section = 0
    private var accessibility = AloVisualAccessibility()
    let onApply: (AloChatAppearance) -> Void
    let onUseDefault: (() -> Void)?

    init(
        appearance: AloChatAppearance,
        onApply: @escaping (AloChatAppearance) -> Void,
        onUseDefault: (() -> Void)? = nil
    ) {
        _draft = State(initialValue: appearance)
        self.onApply = onApply
        self.onUseDefault = onUseDefault
    }

    var body: some View {
        ZStack {
            livePreview.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomPanel
            }
        }
        .tint(AloTheme.accent)
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: AloSocialMetrics.glassButton, height: AloSocialMetrics.glassButton)
                    .modifier(AloChatGlass(interactive: false, role: .chrome))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityLabel("Отмена").accessibilityIdentifier("alo.appearance.cancel")
            Spacer()
            Text("Оформление чата")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 16).frame(height: AloSocialMetrics.glassButton)
                .modifier(AloChatGlass(interactive: false, role: .chrome))
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var bottomPanel: some View {
        VStack(spacing: 14) {
            AloSocialSegments(values: [0, 1, 2], selected: $section,
                title: { ["Тема", "Обои", "Сообщения"][$0] },
                identifier: { "alo.appearance.section.\($0)" })
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { sectionContent }
                    .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 250)
            .animation(accessibility.reduceMotion ? nil : .easeInOut(duration: 0.20), value: section)
            Button { onApply(draft); dismiss() } label: {
                Text("Применить")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(AloTheme.accent, in: Capsule())
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))
            .accessibilityIdentifier("alo.appearance.apply")
        }
        .padding(16)
        .padding(.bottom, 4)
        .modifier(AloChatPanelGlass(radius: 32, role: .panel))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var sectionContent: some View {
        if section == 0 {
            presets
            Text("Стиль меняет фон и цвета сообщений. Детали можно настроить во вкладках «Обои» и «Сообщения».")
                .font(.footnote).foregroundStyle(AloTheme.muted)
            if let onUseDefault {
                Button("Использовать оформление по умолчанию") {
                    onUseDefault()
                    dismiss()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                .buttonStyle(AloControlPressStyle())
            }
            Button("Вернуть классическую тему", role: .destructive) {
                draft = AloChatAppearance()
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .buttonStyle(AloControlPressStyle())
        } else if section == 1 {
            appearanceSection(title: "Акцент обоев") {
                colorChoices(value: custom(\.wallpaperHue), brightness: 0.45)
                DisclosureGroup("Точная настройка") {
                    ChatHueControl(title: "Оттенок", value: custom(\.wallpaperHue))
                    ChatLevelControl(title: "Яркость", value: custom(\.wallpaperBrightness), range: 0.02...0.42)
                }
            }
            appearanceSection(title: "Детали фона") {
                ChatAppearanceOptionPicker(title: "Градиент",
                    options: [("diagonal", "Спокойный"), ("vertical", "Глубина"), ("glow", "Сияние")],
                    selection: custom(\.gradientStyle))
                ChatAppearanceOptionPicker(title: "Узор",
                    options: [("none", "Без узора"), ("line", "Контур"), ("ink", "Эскиз")],
                    selection: custom(\.patternStyle))
                if draft.patternStyle != "none" {
                    ChatLevelControl(title: "Интенсивность", value: custom(\.patternIntensity), range: 0...0.30)
                }
            }
        } else {
            appearanceSection(title: "Ваши сообщения") {
                colorChoices(value: custom(\.outgoingHue), brightness: 0.78)
                DisclosureGroup("Настроить цвет") {
                    ChatHueControl(title: "Оттенок", value: custom(\.outgoingHue))
                    ChatLevelControl(title: "Яркость", value: custom(\.outgoingBrightness), range: 0.45...1)
                }
            }
            appearanceSection(title: "Входящие сообщения") {
                DisclosureGroup("Цвет и яркость") {
                    ChatHueControl(title: "Оттенок", value: custom(\.incomingHue))
                    ChatLevelControl(title: "Яркость", value: custom(\.incomingBrightness), range: 0.07...0.42)
                }
            }
            appearanceSection(title: "Расположение") {
                Toggle("Компактные интервалы", isOn: $draft.compactSpacing)
                    .font(.body)
            }
        }

    }

    private func custom<T>(_ keyPath: WritableKeyPath<AloChatAppearance, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: keyPath] }, set: {
            draft[keyPath: keyPath] = $0
            draft.preset = "custom"
        })
    }

    private func colorChoices(value: Binding<Double>, brightness: Double) -> some View {
        ViewThatFits {
            swatches(value: value, brightness: brightness)
            ScrollView(.horizontal, showsIndicators: false) { swatches(value: value, brightness: brightness) }
        }
    }

    private func swatches(value: Binding<Double>, brightness: Double) -> some View {
        HStack(spacing: 6) {
            ForEach(AloChatAppearance.accentHues, id: \.self) { hue in
                Button {
                    value.wrappedValue = hue
                    if section == 1 { draft.wallpaperBrightness = max(0.16, draft.wallpaperBrightness) }
                } label: {
                    Circle().fill(Color(hue: hue / 360, saturation: 0.75, brightness: brightness))
                        .frame(width: 32, height: 32)
                        .overlay {
                            if abs(value.wrappedValue - hue) < 1 {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(AloControlPressStyle())
                .accessibilityLabel(colorName(hue))
                .accessibilityAddTraits(abs(value.wrappedValue - hue) < 1 ? .isSelected : [])
            }
        }
    }

    private func colorName(_ hue: Double) -> String {
        switch hue {
        case 211: return "Синий"
        case 164: return "Зелёный"
        case 272: return "Фиолетовый"
        case 326: return "Розовый"
        case 28: return "Оранжевый"
        default: return "Золотой"
        }
    }

    /// A real-looking conversation, not a placeholder: the wallpaper and both bubble colours update live.
    private var livePreview: some View {
        ZStack {
            AloChatWallpaper(appearance: draft)
            VStack(spacing: draft.compactSpacing ? 4 : 8) {
                Text("Сегодня")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(Color.black.opacity(0.32), in: Capsule())
                    .padding(.bottom, 4)
                previewBubble("Привет! Смотри, как будет выглядеть чат", mine: false, time: "13:00")
                previewBubble("Выглядит отлично", mine: true, time: "13:01")
                previewBubble("Можно поменять цвета и обои прямо здесь, всё меняется сразу", mine: false, time: "13:02")
                previewBubble("Тогда оставляем так", mine: true, time: "13:03")
            }
            .font(.system(size: 17))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.top, 76)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.appearance.preview")
    }

    private func previewBubble(_ text: String, mine: Bool, time: String) -> some View {
        HStack {
            if mine { Spacer(minLength: 56) }
            (Text(text) + Text("  " + time).font(.system(size: 11)).foregroundColor(.white.opacity(0.65)))
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(mine ? draft.outgoingColor : draft.incomingColor,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !mine { Spacer(minLength: 56) }
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Темы")
                .font(.system(size: 15, weight: .semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AloChatAppearance.presets, id: \.id) { preset in
                        Button {
                            draft = preset.value
                        } label: {
                            VStack(spacing: 7) {
                                ZStack {
                                    AloChatWallpaper(appearance: preset.value)
                                    VStack(spacing: 7) {
                                        HStack {
                                            Spacer()
                                            Capsule().fill(preset.value.outgoingColor).frame(width: 54, height: 18)
                                        }
                                        HStack {
                                            Capsule().fill(preset.value.incomingColor).frame(width: 46, height: 18)
                                            Spacer()
                                        }
                                    }
                                    .padding(9)
                                }
                                .frame(width: 104, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .stroke(draft.preset == preset.id ? Color.white : Color.white.opacity(0.10), lineWidth: draft.preset == preset.id ? 2 : 1)
                                )
                                Text(preset.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .frame(width: 104)
                        }
                        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.96))
                    }
                }
            }
        }
    }

    private func appearanceSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AloTheme.muted)
            VStack(spacing: 18, content: content)
                .padding(16)
                .background(AloTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AloTheme.border, lineWidth: 1))
        }
    }
}

private struct ChatAppearanceOptionPicker: View {
    let title: String
    let options: [(id: String, title: String)]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 7) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button {
                        selection = option.id
                    } label: {
                        Text(option.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selection == option.id ? Color.white : AloTheme.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(selection == option.id ? AloTheme.accent : AloTheme.surfaceRaised)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))
                }
            }
        }
    }
}

private struct ChatHueControl: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Circle()
                    .fill(Color(hue: value / 360, saturation: 0.82, brightness: 0.96))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
            }
            Slider(value: $value, in: 0...359)
                .tint(Color(hue: value / 360, saturation: 0.82, brightness: 0.96))
        }
    }
}

private struct ChatLevelControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AloTheme.muted)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct TypingStatusText: View {
    @State private var dotCount = 1
    private let timer = Timer.publish(every: 0.42, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("печатает" + String(repeating: ".", count: dotCount))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AloTheme.accent)
            .lineLimit(1)
            .onReceive(timer) { _ in
                dotCount = dotCount == 3 ? 1 : dotCount + 1
            }
    }
}

/// Geometry is bookkeeping, not rendered state. Publishing it on every scroll
/// tick used to rebuild the full history and reschedule its animations.
private final class AloChatScrollMeasurements {
    var frames: [Int: CGRect] = [:]
    var bottom: CGRect = .zero
    var dates: [Int: CGRect] = [:]
    var bottomScrollRevision: UUID?
}

private final class AloBubbleMeasurement { var frame: CGRect = .zero }

private struct ChatMessageRow: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.aloCirclePlayback) private var circlePlayback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var pollIndicatorWidth: CGFloat = 42
    @ScaledMetric(relativeTo: .body) private var pollPercentageSize: CGFloat = 14.5
    @ScaledMetric(relativeTo: .body) private var pollFullPercentageSize: CGFloat = 12.5
    @State private var bubbleMeasurement = AloBubbleMeasurement()
    private var bubbleFrame: CGRect { bubbleMeasurement.frame }
#if DEBUG
    @State private var debugBubbleFrame: CGRect = .zero
#endif
    @State private var didOpenLongPressMenu = false
    @State private var didMoveDuringPress = false
    @State private var suppressMediaOpenUntil = Date.distantPast

    let message: AloChatMessage
    let replyToMessage: AloChatMessage?
    let pollState: AloPollViewState?
    let appearance: AloChatAppearance
    let isMine: Bool
    let showsSenderAttribution: Bool
    let isPending: Bool
    let isSelected: Bool
    let selectionMode: Bool
    var isContextMenuPresented = false
    var previewOnly = false
    /// Width proposed by the message list, after its horizontal content insets.
    let availableWidth: CGFloat
    let onTap: () -> Void
    let onReact: (String) -> Void
    let onPollVote: (String) -> Void
    let canClosePoll: Bool
    let onClosePoll: () -> Void
    let onOpenMediaGallery: ([AloMediaItem], Int) -> Void
    let onOpenDiscussion: () -> Void
    let onLongPress: (CGRect) -> Void
    var onOpenReply: (Int) -> Void = { _ in }

    @ViewBuilder var body: some View {
        if previewOnly {
            bubble.environment(\.aloCirclePlayback, nil).allowsHitTesting(false)
        } else {
            interactiveRow
        }
    }

    private var interactiveRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine { Spacer(minLength: oppositeInset) }
            if selectionMode && !isMine {
                selectionIndicator
            }
            bubble
                .background(bubbleFrameReader)
                // Selection owns a separate overlay. A no-op tap on this parent
                // would consume taps intended for voice, links and poll options.
                .aloObserveTouch(enabled: voiceOnly || circleOnly, changed: updateScrubPressGuard)
                .modifier(AloMessageLongPress(enabled: !selectionMode && !isContextMenuPresented,
                                             allowedBounds: { circlePlayback?.viewport },
                                             onPrepare: { AloHaptics.prepare() }, onBegan: openLongPressMenuIfNeeded))
                // Context activation belongs to the visible bubble, not the
                // full-width alignment slot beside a short message.
                .frame(maxWidth: bubbleMaxWidth, alignment: isMine ? .trailing : .leading)
                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                .allowsHitTesting(!selectionMode)
                .accessibilityHidden(selectionMode)
            if selectionMode && isMine {
                selectionIndicator
            }
            if !isMine { Spacer(minLength: oppositeInset) }
        }
        .padding(.vertical, 2)
        .background {
            // A soft, rounded wash inside the row, not a hard full-width rectangle.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AloTheme.accent.opacity(0.18))
                .padding(.horizontal, 4)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .overlay {
            if selectionMode {
                Button(action: onTap) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Снять выделение сообщения" : "Выбрать сообщение")
                .accessibilityIdentifier("alo.message.select.\(message.id)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.message.\(message.id)")
#if DEBUG
        .modifier(AloMessageDesignGeometryModifier(frame: debugBubbleFrame))
#endif
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isSelected)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1), value: selectionMode)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: expandedCircle)
    }

    private var expandedCircle: Bool {
        !selectionMode && !previewOnly && circleOnly && circleAttachments.contains { $0.id == circlePlayback?.item?.id }
    }

    private var oppositeInset: CGFloat { expandedCircle ? 0 : selectionMode ? 16 : 40 }

    private var bubbleMaxWidth: CGFloat {
        expandedCircle ? max(1, availableWidth - 8)
            : AloChatMetrics.messageWidth(availableWidth: availableWidth, selecting: selectionMode)
    }

    private var bubbleFrameReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    updateBubbleFrame(proxy.frame(in: .named("conversationRoot")))
                }
                .onChange(of: proxy.frame(in: .named("conversationRoot"))) { _, newFrame in
                    updateBubbleFrame(newFrame)
                }
        }
    }

    private func updateBubbleFrame(_ newFrame: CGRect) {
        guard newFrame != bubbleFrame else { return }
        bubbleMeasurement.frame = newFrame
#if DEBUG
        if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"),
           UserDefaults.standard.string(forKey: "ALO_UI_MESSENGER_CONTENT") != "media-stress" {
            DispatchQueue.main.async { debugBubbleFrame = newFrame }
        }
#endif
    }

    private var shouldSuppressMediaOpen: Bool {
        isContextMenuPresented || didOpenLongPressMenu || Date() < suppressMediaOpenUntil
    }

    private func openLongPressMenuIfNeeded() {
        guard !selectionMode, !isContextMenuPresented, !didOpenLongPressMenu, !didMoveDuringPress else { return }
        suppressMediaOpenUntil = Date().addingTimeInterval(0.55)
        didOpenLongPressMenu = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            didOpenLongPressMenu = false
            didMoveDuringPress = false
        }
        onLongPress(bubbleFrame)
    }

    private func updateScrubPressGuard(_ translation: CGSize?) {
        if let translation {
            if hypot(translation.width, translation.height) > 8 { didMoveDuringPress = true }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { didMoveDuringPress = false }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if pollState != nil {
            pollBubble
        } else if circleOnly {
            circleBubble
        } else if voiceOnly {
            voiceBubble
        } else if simpleTextOnly {
            textOnlyBubble
        } else if !mediaAttachments.isEmpty && cardAttachments.isEmpty && voiceAttachments.isEmpty && circleAttachments.isEmpty && mediaAttachments.allSatisfy({ ["image", "video"].contains($0.chatMediaItem.type) }) {
            visualMediaBubble
        } else {
            standardBubble
        }
    }

    @ViewBuilder
    private var pollBubble: some View {
        if let state = pollState {
            let foreground = isMine ? Color.white : AloTheme.text
            let secondary = foreground.opacity(isMine ? 0.7 : 0.66)

            VStack(alignment: .leading, spacing: 6) {
                senderAttribution

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.definition.question)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(state.definition.isQuiz ? "Викторина" : (state.definition.isAnonymous ? "Анонимный опрос" : "Открытый опрос"))
                        .font(.system(size: 14))
                        .foregroundStyle(secondary)
                }

                VStack(spacing: 0) {
                    ForEach(state.definition.options) { option in
                        pollOption(option, state: state, foreground: foreground)
                    }
                }

                if state.definition.isQuiz,
                   !state.definition.explanation.isEmpty,
                   state.isClosed || !state.selectedOptionIds.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Пояснение")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(secondary)
                        Text(state.definition.explanation)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if pollShowsResults(state), !state.publicVoters.isEmpty {
                    Text(publicVoterSummary(state))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }

                if state.isClosed {
                    Label("Опрос завершён", systemImage: "lock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(secondary)
                } else {
                    if let closeLabel = pollCloseLabel(state.closesAt) {
                        Label(closeLabel, systemImage: "clock")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(secondary)
                    }
                }

                HStack(spacing: 8) {
                    Text(pollFooterText(state))
                    if !state.isClosed, state.definition.allowsMultipleAnswers {
                        Text("Несколько ответов")
                    }
                    Spacer(minLength: 12)
                    messageTimestamp
                }
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(secondary)

                if !message.reactions.isEmpty {
                    inlineReactionFooter(showMeta: false)
                }
            }
            .frame(width: max(1, min(312, bubbleMaxWidth) - 24), alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func pollOption(
        _ option: AloPollOption,
        state: AloPollViewState,
        foreground: Color
    ) -> some View {
        let selected = state.selectedOptionIds.contains(option.id)
        let count = state.voteCounts[option.id, default: 0]
        let fraction = state.totalVoters > 0 ? min(1, max(0, CGFloat(count) / CGFloat(state.totalVoters))) : 0
        let percentage = Int((fraction * 100).rounded())
        let showsResults = pollShowsResults(state)
        let isCorrect = state.definition.isQuiz && state.isClosed && state.correctOptionIds.contains(option.id)
        let isIncorrect = state.definition.isQuiz && state.isClosed && selected && !isCorrect
        let accent = isCorrect ? AloTheme.success : (isIncorrect ? Color.red : foreground)
        let indicatorName: String
        if isCorrect || selected {
            indicatorName = isIncorrect ? "xmark.circle.fill" : "checkmark.circle.fill"
        } else {
            indicatorName = "circle"
        }
        let secondary = foreground.opacity(isMine ? 0.7 : 0.66)

        return Button {
            guard !shouldSuppressMediaOpen else { return }
            onPollVote(option.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if showsResults {
                        Text("\(percentage)%")
                            .font(.system(size: percentage == 100 ? pollFullPercentageSize : pollPercentageSize,
                                          weight: .bold).monospacedDigit())
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(secondary)
                            .frame(width: pollIndicatorWidth, alignment: .trailing)
                    } else {
                        Image(systemName: indicatorName)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(selected || isCorrect || isIncorrect ? accent : secondary)
                            .frame(width: pollIndicatorWidth)
                    }
                    Text(option.text)
                        .font(.body)
                        .foregroundStyle(foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsResults {
                    GeometryReader { proxy in
                        Capsule().fill(foreground.opacity(0.09))
                        Capsule().fill(accent.opacity(selected || isCorrect ? 0.85 : 0.45))
                            .frame(width: max(4, proxy.size.width * fraction))
                    }
                    .frame(height: 4)
                    .padding(.leading, pollIndicatorWidth + 8)
                    .overlay(alignment: .leading) {
                        if selected || isCorrect {
                            Image(systemName: isIncorrect ? "xmark" : "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(accent)
                                .frame(width: pollIndicatorWidth, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(.vertical, 14)
            .frame(minHeight: showsResults ? 59 : 52)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(AloChatPressStyle())
        .accessibilityIdentifier("alo.poll.option.\(option.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(state.isClosed || (!state.allowsRevoting && !state.selectedOptionIds.isEmpty))
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 1),
            value: fraction
        )
    }

    private func pollShowsResults(_ state: AloPollViewState) -> Bool {
        state.isClosed || !state.selectedOptionIds.isEmpty
    }

    private func pollFooterText(_ state: AloPollViewState) -> String {
        let voteCount = "\(state.totalVoters) \(pollVoterLabel(state.totalVoters))"
        return state.isClosed ? "Опрос завершён · \(voteCount)" : voteCount
    }

    private func pollVoterLabel(_ count: Int) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        if mod100 >= 11 && mod100 <= 14 { return "голосов" }
        if mod10 == 1 { return "голос" }
        if mod10 >= 2 && mod10 <= 4 { return "голоса" }
        return "голосов"
    }

    private func pollCloseLabel(_ closesAt: String) -> String? {
        guard !closesAt.isEmpty else { return nil }
        let date = ISO8601DateFormatter().date(from: closesAt)
            ?? ISO8601DateFormatter().date(from: closesAt.replacingOccurrences(of: ".000Z", with: "Z"))
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM, HH:mm"
        return "Завершится \(formatter.string(from: date))"
    }

    private func publicVoterSummary(_ state: AloPollViewState) -> String {
        let names = state.publicVoters.prefix(3).map(\.name)
        let remaining = max(0, state.totalVoters - names.count)
        return "Ответили: " + names.joined(separator: ", ") +
            (remaining > 0 ? " и ещё \(remaining)" : "")
    }

    private var voiceBubble: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            senderAttribution
            replyPreview
            if let forwardFrom = message.forwardFrom {
                AloForwardAttribution(name: forwardFrom.user?.name ?? "пользователя", isMine: isMine)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(voiceAttachments) { attachment in
                VoiceMessageAttachmentView(
                    attachment: attachment,
                    senderName: app.voicePlaybackTitle(for: message),
                    isMine: isMine,
                    accentColor: appearance.outgoingColor,
                    showMessageMeta: attachment.id == voiceAttachments.last?.id,
                    createdAt: message.createdAt,
                    editedAt: message.editedAt,
                    isRead: !message.readAt.isEmpty,
                    isPending: isPending,
                    isScheduled: message.isScheduled,
                    preparePlayback: prepareExpiringMediaPlayback,
                    onLongPress: { onLongPress(bubbleFrame) },
                    isTapSuppressed: { shouldSuppressMediaOpen }
                )
            }

            messageExpiryBadge
            inlineReactionFooter(showMeta: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: max(1, min(270, bubbleMaxWidth) - 18), alignment: isMine ? .trailing : .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
    }

    private var messageTimestamp: some View { timestamp(checksBleed: 0) }

    /// Time, then read checks for own messages. In a text bubble Telegram reserves 13 pt for the
    /// checks and lets the second one run 5 pt into the bubble's side inset (`checksBleed`).
    private func timestamp(checksBleed: CGFloat) -> some View {
        HStack(spacing: 3) {
            if !message.editedAt.isEmpty {
                Text("изм.")
            }
            Text(AloFormatters.messageTime(message.createdAt))
            if isMine {
                MessageReadStatusChecks(
                    isRead: !message.readAt.isEmpty,
                    isSending: isPending,
                    isScheduled: message.isScheduled
                )
                .padding(.trailing, -checksBleed)
            }
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(Color.white.opacity(0.72))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("alo.message.time.\(message.id)")
    }

    private var standardBubble: some View {
        AloMessageContentLayout {
            VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
                senderAttribution
                replyPreview
                if let forwardFrom = message.forwardFrom {
                    AloForwardAttribution(name: forwardFrom.user?.name ?? "пользователя", isMine: isMine)
                }

                ForEach(cardAttachments) { attachment in
                    if attachment.isContactCard {
                        ContactMessageAttachmentCard(
                            attachment: attachment,
                            isMine: isMine,
                            onOpen: {
                                guard let userId = Int(attachment.metadata["userId"] ?? "") else { return }
                                app.openProfile(userId: userId)
                            }
                        )
                    } else if attachment.isLocationCard {
                        LocationMessageAttachmentCard(
                            attachment: attachment,
                            isMine: isMine
                        )
                    }
                }

                if !mediaAttachments.isEmpty {
                    if hasUnpreparedExpiringMedia {
                        ExpiringMediaPlaceholder(
                            itemCount: mediaAttachments.count,
                            selfDestructSeconds: message.selfDestructSeconds
                        )
                        .frame(maxWidth: 310)
                        .frame(height: mediaAttachments.count > 1 ? 230 : 220)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openMediaAttachment(at: 0)
                        }
                    } else {
                        MessageMediaGrid(
                            attachments: mediaAttachments,
                            isTapSuppressed: { shouldSuppressMediaOpen },
                            onOpenAt: { index in
                                openMediaAttachment(at: index)
                            }
                        )
                            .frame(maxWidth: 310)
                    }
                }

                ForEach(voiceAttachments) { attachment in
                    VoiceMessageAttachmentView(
                        attachment: attachment,
                        senderName: app.voicePlaybackTitle(for: message),
                        isMine: isMine,
                        accentColor: appearance.outgoingColor,
                        preparePlayback: prepareExpiringMediaPlayback,
                        onLongPress: { onLongPress(bubbleFrame) },
                        isTapSuppressed: { shouldSuppressMediaOpen }
                    )
                        .frame(maxWidth: 292)
                }

                ForEach(circleAttachments) { attachment in
                    CircleMessageAttachmentView(
                        attachment: attachment,
                        accentColor: appearance.outgoingColor,
                        messageID: message.id,
                        senderName: app.voicePlaybackTitle(for: message),
                        preparePlayback: prepareExpiringMediaPlayback,
                        isTapSuppressed: { shouldSuppressMediaOpen }
                    )
                        .frame(width: min(212, bubbleMaxWidth), height: min(212, bubbleMaxWidth))
                }

                if let callLogMeta {
                    ChatCallLogAttachment(
                        meta: callLogMeta,
                        isMine: isMine,
                        isRead: !message.readAt.isEmpty,
                        createdAt: message.createdAt
                    )
                } else if !message.body.isEmpty {
                    AloRichMessageText(body: message.body, entities: message.entities)
                        .accessibilityIdentifier("alo.message.body.\(message.id)")
                }

                if callLogMeta == nil {
                    messageExpiryBadge
                }
            }
            VStack(spacing: 0) {
                if callLogMeta == nil {
                    inlineReactionFooter(showMeta: true)
                    channelDiscussionFooter
                }
            }
        }
        .padding(.horizontal, callLogMeta == nil ? bubbleHorizontalPadding : 10)
        .padding(.top, callLogMeta == nil ? (attachmentsOnly ? 4 : 10) : 8)
        .padding(.bottom, !message.reactions.isEmpty && callLogMeta == nil ? 0 : (callLogMeta == nil ? (attachmentsOnly ? 4 : 10) : 8))
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(RoundedRectangle(cornerRadius: messageBubbleCornerRadius, style: .continuous))
    }

    private var visualMediaBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            if message.replyToMessageId > 0 || message.forwardFrom != nil || (showsSenderAttribution && !isMine) {
                VStack(alignment: .leading, spacing: 4) {
                    senderAttribution
                    replyPreview
                    if let forwarded = message.forwardFrom {
                        AloForwardAttribution(name: forwarded.user?.name ?? "пользователя", isMine: isMine)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            Group {
                if hasUnpreparedExpiringMedia {
                    ExpiringMediaPlaceholder(itemCount: mediaAttachments.count, selfDestructSeconds: message.selfDestructSeconds)
                        .frame(height: visualMediaSize.height)
                        .onTapGesture { openMediaAttachment(at: 0) }
                } else {
                    MessageMediaGrid(attachments: mediaAttachments, edgeToEdge: true,
                        availableWidth: visualMediaSize.width,
                        dimensions: mediaDisplayDimensions,
                        isTapSuppressed: { shouldSuppressMediaOpen },
                        onOpenAt: openMediaAttachment)
                }
            }
            .accessibilityIdentifier("alo.message.media.\(message.id)")
            .overlay(alignment: .bottomTrailing) {
                if message.body.isEmpty && message.reactions.isEmpty {
                    messageTimestamp.padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.42), in: Capsule()).padding(7)
                }
            }
            if !message.body.isEmpty && message.reactions.isEmpty {
                // A caption is a text bubble under the photo: the time shares its last line when it fits.
                VStack(alignment: .leading, spacing: 2) {
                    AloTextStatusLayout(attributedText: AloRichMessageText.statusMeasureText(message.body, entities: message.entities)) {
                        AloRichMessageText(body: message.body, entities: message.entities)
                            .accessibilityIdentifier("alo.message.body.\(message.id)")
                        timestamp(checksBleed: 5).layoutPriority(1)
                    }
                    messageExpiryBadge
                }
                .padding(.horizontal, 11).padding(.top, 6).padding(.bottom, 6)
            } else if !message.body.isEmpty || !message.reactions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !message.body.isEmpty {
                        AloRichMessageText(body: message.body, entities: message.entities)
                            .accessibilityIdentifier("alo.message.body.\(message.id)")
                    }
                    inlineReactionFooter(showMeta: true)
                    messageExpiryBadge
                }
                .padding(.horizontal, 11).padding(.top, 7).padding(.bottom, message.reactions.isEmpty ? 5 : 0)
            }
            channelDiscussionFooter.padding(.horizontal, 12)
        }
        .frame(width: visualMediaSize.width, alignment: .leading)
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var visualMediaSize: CGSize {
        let dimensions = mediaDisplayDimensions
        guard mediaAttachments.count == 1, let attachment = mediaAttachments.first else {
            return AloChatMosaic.layout(dimensions: dimensions, availableWidth: bubbleMaxWidth).size
        }
        return AloChatMediaSizing.single(dimensions: dimensions.first ?? nil,
            video: attachment.type == "video", availableWidth: bubbleMaxWidth)
    }

    /// The size each photo or video is laid out with: the one the message carries, else the one this
    /// device saw when it last showed that image (older and other-client messages have none).
    private var mediaDisplayDimensions: [AloMediaDimensions?] {
        mediaAttachments.map { attachment in
            if let dimensions = attachment.mediaDimensions { return dimensions }
            let source = attachment.posterUrl.ifBlank(attachment.url)
            return AloChatMediaSession.dimensions(forKey: "\(message.id)|\(source)") {
                app.api.absoluteURL(source).flatMap(AloCachedImageSize.dimensions(for:))
            }
        }
    }

    private var textOnlyBubble: some View {
        // Telegram's minimum bubble is 40 × 35: a one-word message is as wide as its word and time.
        AloMessageContentLayout(minimumWidth: 40 - 22) {
            VStack(alignment: .leading, spacing: 5) {
                senderAttribution
                replyPreview
                AloTextStatusLayout(showsStatus: message.reactions.isEmpty,
                    attributedText: AloRichMessageText.statusMeasureText(message.body, entities: message.entities)) {
                    AloRichMessageText(body: message.body, entities: message.entities)
                        .accessibilityIdentifier("alo.message.body.\(message.id)")
                    timestamp(checksBleed: 5).layoutPriority(1)
                        .opacity(message.reactions.isEmpty ? 1 : 0)
                        .accessibilityHidden(!message.reactions.isEmpty)
                }
            }
            VStack(spacing: 0) {
                if !message.reactions.isEmpty { inlineReactionFooter(showMeta: true) }
                channelDiscussionFooter
            }
        }
        // A single line is 32 pt; Telegram grows such a bubble to 35 and centres the line.
        .frame(minHeight: 35 - 12)
        .padding(.leading, 11)
        .padding(.trailing, 11)
        .padding(.top, 6)
        .padding(.bottom, message.reactions.isEmpty ? 6 : 0)
        .background(isMine ? appearance.outgoingColor : appearance.incomingColor)
        .clipShape(
            RoundedRectangle(
                cornerRadius: messageBubbleCornerRadius,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    private var replyPreview: some View {
        if message.replyToMessageId > 0 {
            Button {
                guard !shouldSuppressMediaOpen, replyToMessage != nil else { return }
                onOpenReply(message.replyToMessageId)
            } label: {
                AloMessageReplyPreview(author: replySenderName, preview: replyMessagePreviewText,
                    accent: isMine ? .white.opacity(0.9) : AloTheme.accent,
                    foreground: isMine ? .white.opacity(0.8) : AloTheme.text.opacity(0.8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloChatPressStyle())
            .accessibilityIdentifier("alo.message.reply.\(message.id)")
            .accessibilityHint("Перейти к исходному сообщению")
        }
    }

    private var replySenderName: String {
        guard let replyToMessage else { return "Ответ на сообщение" }
        if let forwardedName = replyToMessage.forwardFrom?.user?.name, !forwardedName.isEmpty {
            return forwardedName
        }
        return app.voicePlaybackTitle(for: replyToMessage).ifBlank("Ответ на сообщение")
    }

    private var replyMessagePreviewText: String {
        guard let replyToMessage else { return "Сообщение" }
        return chatPreviewText(replyToMessage)
    }

    @ViewBuilder
    private var channelDiscussionFooter: some View {
        if message.channelPostId > 0, message.channelPostCommentsEnabled {
            Button(action: onOpenDiscussion) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 12, weight: .semibold))
                    Text(channelDiscussionLabel)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(isMine ? Color.white.opacity(0.88) : AloTheme.accent)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .frame(minHeight: 44)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 0.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(AloChatPressStyle())
            .accessibilityIdentifier("alo.message.comments.\(message.id)")
        }
    }

    private var channelDiscussionLabel: String {
        let count = message.channelPostCommentCount
        guard count > 0 else { return "Обсудить" }
        return "\(count) \(russianCommentWord(count))"
    }

    private func russianCommentWord(_ count: Int) -> String {
        let mod100 = count % 100
        if (11...14).contains(mod100) { return "комментариев" }
        switch count % 10 {
        case 1: return "комментарий"
        case 2...4: return "комментария"
        default: return "комментариев"
        }
    }

    private func circleDiameter(_ attachment: AloMessageAttachment) -> CGFloat {
        AloCirclePresentation.diameter(available: bubbleMaxWidth,
            expanded: !previewOnly && circlePlayback?.item?.id == attachment.id)
    }

    private var circleBubble: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            senderAttribution
            replyPreview
                .padding(.horizontal, 10)
                .padding(.vertical, message.replyToMessageId > 0 ? 6 : 0)
                .background(message.replyToMessageId > 0 ? appearance.incomingColor : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let forwardFrom = message.forwardFrom {
                AloForwardAttribution(name: forwardFrom.user?.name ?? "пользователя", isMine: isMine)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background((isMine ? appearance.outgoingColor : appearance.incomingColor).opacity(0.9))
                    .clipShape(Capsule())
            }

            ForEach(circleAttachments) { attachment in
                CircleMessageAttachmentView(
                    attachment: attachment,
                    accentColor: appearance.outgoingColor,
                    messageID: message.id,
                    senderName: app.voicePlaybackTitle(for: message),
                    preparePlayback: prepareExpiringMediaPlayback,
                    isTapSuppressed: { shouldSuppressMediaOpen }
                )
                    .frame(width: circleDiameter(attachment), height: circleDiameter(attachment))
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: circlePlayback?.item?.id)
                    .overlay(alignment: .bottomTrailing) {
                        Text(AloFormatters.messageTime(message.createdAt))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.46))
                            .clipShape(Capsule())
                            .padding(10)
                    }
                if attachment.id == circleAttachments.last?.id, !message.reactions.isEmpty {
                    MessageReactionStrip(reactions: message.reactions, onTap: {
                        guard !shouldSuppressMediaOpen else { return }
                        onReact($0.emoji)
                    })
                        .frame(width: AloCirclePresentation.diameter(available: bubbleMaxWidth, expanded: false), alignment: .leading)
                }
            }

            messageExpiryBadge
        }
    }

    @ViewBuilder
    private var senderAttribution: some View {
        if showsSenderAttribution, !isMine, let senderName = message.sender?.name, !senderName.isEmpty {
            HStack(spacing: 4) {
                Text(senderName)
                    .foregroundStyle(message.senderIsAnonymous ? AloTheme.accent : Color.white.opacity(0.84))
                if !message.senderAdminTitle.isEmpty && !message.senderIsAnonymous {
                    Text("· \(message.senderAdminTitle)")
                        .foregroundStyle(Color.white.opacity(0.56))
                }
            }
            .font(.system(size: 12, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func inlineReactionFooter(showMeta: Bool) -> some View {
        MessageReactionFooter(reactions: message.reactions, showMeta: showMeta, onTap: { reaction in
            guard !shouldSuppressMediaOpen else { return }
            onReact(reaction.emoji)
        }) {
            messageTimestamp
        }
    }

    private var callLogMeta: ChatCallLogMeta? {
        message.chatCallLogMeta
    }

    private var simpleTextOnly: Bool {
        callLogMeta == nil &&
        message.forwardFrom == nil &&
        !message.body.isEmpty &&
        cardAttachments.isEmpty &&
        mediaAttachments.isEmpty &&
        voiceAttachments.isEmpty &&
        circleAttachments.isEmpty
    }

    private var messageBubbleCornerRadius: CGFloat {
        if message.body.contains("\n") || message.body.count > 34 {
            return 16
        }
        return attachmentsOnly ? 18 : 22
    }

    private var attachments: [AloMessageAttachment] {
        if !message.attachments.isEmpty { return message.attachments }
        guard !message.attachmentUrl.isEmpty else { return [] }
        return [
            AloMessageAttachment([
                "type": message.attachmentType,
                "url": message.attachmentUrl,
                "name": message.attachmentName
            ])
        ]
    }

    private var mediaAttachments: [AloMessageAttachment] {
        attachments.filter { !$0.isVoiceLike && !$0.isCircleLike && !$0.isVirtualCard }
    }

    private var cardAttachments: [AloMessageAttachment] {
        attachments.filter(\.isVirtualCard)
    }

    private func openMediaAttachment(at index: Int) {
        guard !shouldSuppressMediaOpen else { return }
        if selectionMode {
            onTap()
            return
        }
        Task {
            guard let prepared = await app.prepareMessageMedia(message) else { return }
            let preparedAttachments = prepared.attachments.filter {
                !$0.isVoiceLike && !$0.isCircleLike && !$0.isVirtualCard
            }
            let items = preparedAttachments.map(\.chatMediaItem)
            guard items.indices.contains(index) else { return }
            onOpenMediaGallery(items, index)
        }
    }

    private var prepareExpiringMediaPlayback: (() async -> Bool)? {
        guard message.selfDestructSeconds > 0, hasUnpreparedExpiringMedia else { return nil }
        return {
            await app.prepareMessageMediaOpen(message)
        }
    }

    private var hasUnpreparedExpiringMedia: Bool {
        guard message.selfDestructSeconds > 0 else { return false }
        return attachments.contains { attachment in
            guard !attachment.mediaEncryption.isEmpty else { return false }
            return URL(string: attachment.url)?.scheme?.lowercased() != AloSecureMediaStore.scheme
        }
    }

    @ViewBuilder
    private var messageExpiryBadge: some View {
        if message.selfDestructSeconds > 0 {
            MessageExpiryBadge(message: message)
                .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        }
    }

    private var voiceAttachments: [AloMessageAttachment] {
        attachments.filter(\.isVoiceLike)
    }

    private var circleAttachments: [AloMessageAttachment] {
        attachments.filter(\.isCircleLike)
    }

    private var attachmentsOnly: Bool {
        !mediaAttachments.isEmpty && voiceAttachments.isEmpty && circleAttachments.isEmpty && message.body.isEmpty
    }

    private var circleOnly: Bool {
        mediaAttachments.isEmpty && voiceAttachments.isEmpty && !circleAttachments.isEmpty && message.body.isEmpty
    }

    private var voiceOnly: Bool {
        mediaAttachments.isEmpty && !voiceAttachments.isEmpty && circleAttachments.isEmpty && message.body.isEmpty
    }

    private var bubbleHorizontalPadding: CGFloat {
        if attachmentsOnly { return 4 }
        if voiceOnly { return 10 }
        return 11
    }

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(isSelected ? AloTheme.accent : AloTheme.muted)
            .frame(width: 28, height: 28)
    }

}

private struct ContactMessageAttachmentCard: View {
    let attachment: AloMessageAttachment
    let isMine: Bool
    let onOpen: () -> Void

    private var displayName: String {
        (attachment.metadata["displayName"] ?? "").ifBlank(attachment.name.ifBlank("Контакт"))
    }

    private var username: String {
        attachment.metadata["username"] ?? ""
    }

    private var avatarURL: String {
        attachment.metadata["avatarUrl"] ?? ""
    }

    private var isVerified: Bool {
        attachment.metadata["verified"] == "1"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                AloAvatar(
                    name: displayName,
                    url: avatarURL,
                    size: 40,
                    colorSeed: attachment.metadata["userId"] ?? displayName
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(displayName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    if !username.isEmpty {
                        Text("@\(username)")
                            .font(.subheadline)
                            .lineLimit(1)
                    } else {
                        Text("Контакт Alo")
                            .font(.subheadline)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isMine ? Color.white : AloTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: 220, maxWidth: 286, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloChatPressStyle())
        .accessibilityLabel("Открыть контакт \(displayName)")
        .accessibilityIdentifier("alo.contact.card")
    }
}

private struct LocationMessageAttachmentCard: View {
    @Environment(\.openURL) private var openURL

    let attachment: AloMessageAttachment
    let isMine: Bool

    private var latitude: Double? {
        Double(attachment.metadata["latitude"] ?? "")
    }

    private var longitude: Double? {
        Double(attachment.metadata["longitude"] ?? "")
    }

    private var title: String {
        (attachment.metadata["title"] ?? "").ifBlank(attachment.name.ifBlank("Геолокация"))
    }

    private var coordinateLabel: String {
        guard let latitude, let longitude else { return "Координаты недоступны" }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }

    private var isLive: Bool {
        attachment.metadata["live"] == "1"
    }

    private var detailLabel: String {
        guard isLive else { return coordinateLabel }
        let expiresAt = attachment.metadata["expiresAt"] ?? ""
        guard !expiresAt.isEmpty else { return "В реальном времени" }
        return "В реальном времени · до \(AloFormatters.messageTime(expiresAt))"
    }

    var body: some View {
        Button {
            guard let latitude, let longitude,
                  let url = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)") else { return }
            openURL(url)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: isLive ? "location.circle.fill" : "location.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(isMine ? Color.white : AloTheme.accent)
                    .frame(width: 46, height: 46)
                    .background(isMine ? Color.white.opacity(0.15) : AloTheme.surfaceRaised.opacity(0.72))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    Text(detailLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(isMine ? Color.white : AloTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: 235, maxWidth: 286, alignment: .leading)
            .background(isMine ? Color.white.opacity(0.15) : AloTheme.surfaceRaised.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))
        .disabled(latitude == nil || longitude == nil)
        .accessibilityLabel("Открыть \(title)")
    }
}

struct AloRichMessageText: View {
    let text: String
    let entities: [AloMessageTextEntity]
    let fontSize: CGFloat
    @EnvironmentObject private var app: AloAppModel
    @State private var revealsSpoilers = false

    init(body: String, entities: [AloMessageTextEntity], fontSize: CGFloat = 17) {
        text = body
        self.entities = entities
        self.fontSize = fontSize
    }

    var body: some View {
        renderedText
            .environment(\.openURL, OpenURLAction { url in
                guard AloDeepLinkTarget(url: url) != nil else { return .systemAction }
                app.handleDeepLink(url)
                return .handled
            })
    }

    @ViewBuilder private var renderedText: some View {
        if let blocks = Self.blocks(text, entities: entities) {
            blockText(blocks)
        } else if entities.contains(where: { $0.type == "spoiler" }) {
            messageText.onTapGesture {
                withAnimation(.easeOut(duration: 0.18)) { revealsSpoilers = true }
            }
        } else {
            messageText
        }
    }

    // MARK: Quotes and code blocks

    struct Block: Identifiable {
        enum Kind { case plain, quote, code }
        let id: Int
        let kind: Kind
        let range: NSRange
        let language: String
    }

    /// The message cut into plain runs, quotes and code blocks; nil when it has neither.
    static func blocks(_ text: String, entities: [AloMessageTextEntity]) -> [Block]? {
        let blockEntities = entities.filter { $0.type == "blockquote" || $0.type == "pre" }.sorted { $0.offset < $1.offset }
        guard !blockEntities.isEmpty, AloPollCodec.previewText(for: text) == nil else { return nil }
        let string = text as NSString
        var result = [Block]()
        var cursor = 0
        func appendPlain(_ start: Int, _ end: Int) {
            var range = NSRange(location: start, length: end - start)
            // Newlines around a block are its own spacing.
            while range.length > 0, string.character(at: range.location) == 10 { range.location += 1; range.length -= 1 }
            while range.length > 0, string.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
            if range.length > 0 { result.append(Block(id: result.count, kind: .plain, range: range, language: "")) }
        }
        for entity in blockEntities where entity.offset >= cursor && entity.offset + entity.length <= string.length {
            appendPlain(cursor, entity.offset)
            result.append(Block(id: result.count, kind: entity.type == "pre" ? .code : .quote,
                                range: NSRange(location: entity.offset, length: entity.length), language: entity.url))
            cursor = entity.offset + entity.length
        }
        appendPlain(cursor, string.length)
        return result.isEmpty ? nil : result
    }

    /// Text for bubble measurement. A message with blocks puts its time on a line of its own.
    static func statusMeasureText(_ text: String, entities: [AloMessageTextEntity]) -> AttributedString? {
        blocks(text, entities: entities) == nil ? AttributedString(attributedBody(text, entities: entities)) : nil
    }

    private func blockText(_ blocks: [Block]) -> some View {
        let full = attributedText
        let whole = NSAttributedString(full)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                let slice = AttributedString(whole.attributedSubstring(from: block.range))
                switch block.kind {
                case .plain:
                    Text(slice).foregroundStyle(Color.white).fixedSize(horizontal: false, vertical: true)
                case .quote:
                    // Telegram's quote: a tinted block with a bar on the left and a quote mark.
                    Text(slice)
                        .foregroundStyle(Color.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 11).padding(.trailing, 22).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.12))
                        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.9)).frame(width: 3) }
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "quote.closing").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.75)).padding(6)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityLabel("Цитата: \(String(slice.characters))")
                case .code:
                    VStack(alignment: .leading, spacing: 4) {
                        if !block.language.isEmpty {
                            Text(block.language).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.7))
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(slice).foregroundStyle(Color.white).fixedSize()
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.24))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contextMenu {
                        Button { UIPasteboard.general.string = String(slice.characters) } label: {
                            Label("Скопировать код", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
        .font(.system(size: fontSize, weight: .regular))
        .contentShape(Rectangle())
        .onTapGesture {
            guard entities.contains(where: { $0.type == "spoiler" }) else { return }
            withAnimation(.easeOut(duration: 0.18)) { revealsSpoilers = true }
        }
    }

    private var messageText: some View {
        Text(attributedText)
            .font(.system(size: fontSize, weight: .regular))
            .foregroundStyle(Color.white)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
    }

    private var attributedText: AttributedString {
        let original = Self.attributedBody(text, entities: entities, revealsSpoilers: revealsSpoilers)
        guard fontSize != 17 else { return AttributedString(original) }
        let scaled = NSMutableAttributedString(attributedString: original)
        original.enumerateAttribute(.font, in: NSRange(location: 0, length: original.length)) { value, range, _ in
            if let font = value as? UIFont {
                scaled.addAttribute(.font, value: font.withSize(font.pointSize * fontSize / 17), range: range)
            }
        }
        return AttributedString(scaled)
    }

    /// Drawing and last-line measurement must use identical font runs.
    static func attributedBody(_ text: String, entities: [AloMessageTextEntity], revealsSpoilers: Bool = false) -> NSAttributedString {
        // Protocol events must never leak their hexadecimal payload into a
        // bubble, search result or context preview when the poll card is absent.
        if let preview = AloPollCodec.previewText(for: text) {
            return NSAttributedString(string: preview, attributes: [
                .font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.white
            ])
        }
        let value = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17),
                .foregroundColor: UIColor.white
            ]
        )
        let fullLength = value.length
        // Server entities win; plain pasted web addresses remain usable too.
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector?.matches(in: text, range: NSRange(location: 0, length: fullLength)) ?? [] {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  !entities.contains(where: {
                      ($0.type == "link" || $0.type == "mention" || $0.type == "code" || $0.type == "spoiler") &&
                      NSIntersectionRange(match.range, NSRange(location: max(0, $0.offset), length: max(0, $0.length))).length > 0
                  }) else { continue }
            value.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
        }
        for entity in entities {
            let range = NSRange(location: entity.offset, length: entity.length)
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= fullLength else { continue }
            switch entity.type {
            case "bold":
                value.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 17), range: range)
            case "italic":
                value.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: 17), range: range)
            case "underline":
                value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case "strikethrough":
                value.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case "code":
                value.addAttributes(
                    [
                        .font: UIFont.monospacedSystemFont(ofSize: 16, weight: .medium),
                        .backgroundColor: UIColor.white.withAlphaComponent(0.13)
                    ],
                    range: range
                )
            case "pre":
                value.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular), range: range)
            case "link", "mention":
                if let url = URL(string: entity.url) {
                    value.addAttributes(
                        [
                            .link: url,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: UIColor.white
                        ],
                        range: range
                    )
                }
            case "spoiler":
                if !revealsSpoilers {
                    value.addAttributes(
                        [
                            .foregroundColor: UIColor.clear,
                            .backgroundColor: UIColor.white.withAlphaComponent(0.28)
                        ],
                        range: range
                    )
                }
            default:
                break
            }
        }
        return value
    }
}

private struct GroupCallHistoryEvent: View {
    let message: AloChatMessage
    let meta: ChatCallLogMeta

    var body: some View {
        Text(eventTitle)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.92))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.48))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
    }

    private var eventTitle: String {
        let actor = message.sender?.name.ifBlank("Участник") ?? "Участник"
        let action = meta.callType == "video"
            ? "завершил(а) видеочат"
            : "завершил(а) голосовой чат"
        guard meta.durationSec > 0 else { return "\(actor) \(action)" }
        let hours = meta.durationSec / 3_600
        let minutes = (meta.durationSec % 3_600) / 60
        let seconds = meta.durationSec % 60
        let duration = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        return "\(actor) \(action) (\(duration))"
    }
}

private struct ChatCallLogAttachment: View {
    let meta: ChatCallLogMeta
    let isMine: Bool
    let isRead: Bool
    let createdAt: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: meta.callType == "video" ? "video.fill" : "phone.fill")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(iconColor.opacity(isMine ? 0.18 : 0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(meta.menuTitle(isMine: isMine))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(secondaryText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .monospacedDigit()
            }

            Spacer(minLength: 10)

            HStack(spacing: 3) {
                Text(AloFormatters.messageTime(createdAt))
                if isMine {
                    MessageReadStatusChecks(isRead: isRead)
                }
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.72))
            .offset(y: 9)
        }
        .frame(width: 210, alignment: .leading)
    }

    private var iconColor: Color {
        switch meta.status {
        case "missed", "declined":
            return Color(red: 1.0, green: 0.42, blue: 0.42)
        default:
            return isMine ? Color.white.opacity(0.92) : AloTheme.accent
        }
    }

    private var secondaryText: String {
        if meta.durationSec > 0 {
            let minutes = meta.durationSec / 60
            let seconds = meta.durationSec % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
        return AloFormatters.messageTime(createdAt)
    }
}

/// Let metadata wrap before stealing an entire line from the reactions.
/// One forward-attribution style for every bubble kind: 14 pt, regular prefix, medium name.
private struct AloForwardAttribution: View {
    let name: String
    let isMine: Bool

    var body: some View {
        (Text("Переслано от ").font(.system(size: 14)) + Text(name).font(.system(size: 14, weight: .medium)))
            .foregroundStyle(isMine ? Color.white.opacity(0.9) : AloTheme.accent)
            .lineLimit(1)
    }
}

private struct MessageReactionFooter<Metadata: View>: View {
    let reactions: [AloMessageReaction]
    let showMeta: Bool
    let onTap: (AloMessageReaction) -> Void
    @ViewBuilder let metadata: () -> Metadata

    var body: some View {
        Group {
            if reactions.isEmpty {
                if showMeta { metadata().frame(maxWidth: .infinity, alignment: .trailing) }
            } else if !showMeta {
                strip.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                AloWrappingRowLayout(spacing: 6, rowSpacing: -8, trailingLastSubview: true) {
                    ForEach(reactions) { reaction in
                        MessageReactionChip(reaction: reaction, onTap: onTap)
                    }
                    metadata().fixedSize()
                }
            }
        }
    }

    private var strip: some View { MessageReactionStrip(reactions: reactions, onTap: onTap) }
}

private struct MessageReactionStrip: View {
    let reactions: [AloMessageReaction]
    let onTap: (AloMessageReaction) -> Void

    var body: some View {
        AloWrappingRowLayout(spacing: 6, rowSpacing: -8) {
            ForEach(reactions) { reaction in
                MessageReactionChip(reaction: reaction, onTap: onTap)
            }
        }
    }
}

private struct MessageReactionChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reaction: AloMessageReaction
    let onTap: (AloMessageReaction) -> Void

    var body: some View {
                Button {
                    AloHaptics.selection()
                    onTap(reaction)
                } label: {
                    // Telegram's regular reaction: 30 pt tall, 20 pt emoji box, 11 pt side inset,
                    // 2 pt to the 11 pt medium counter.
                    HStack(spacing: 2) {
                        Text(reaction.emoji)
                            .font(.system(size: 16))
                            .frame(width: 20, height: 20)
                        if reaction.count > 1 {
                            Text(AloCompactCount.string(reaction.count))
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                                .contentTransition(reduceMotion ? .identity : .numericText())
                        }
                    }
                    .foregroundStyle(reaction.reactedByMe ? Color.white : Color.white.opacity(0.85))
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(reaction.reactedByMe ? AloTheme.accent.opacity(0.8) : Color.white.opacity(0.09))
                    .clipShape(Capsule())
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: reaction.reactedByMe)
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: reaction.count)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AloChatPressStyle())
                .accessibilityLabel("\(reaction.emoji), \(reaction.count)")
                .accessibilityAddTraits(reaction.reactedByMe ? .isSelected : [])
                .transition(.opacity)
    }
}

private struct MessageMediaGrid: View {
    let attachments: [AloMessageAttachment]
    var edgeToEdge = false
    var availableWidth: CGFloat = AloChatMediaSizing.maximumWidth
    /// Sizes to lay out with; nil uses the sizes the attachments carry.
    var dimensions: [AloMediaDimensions?]? = nil
    var isTapSuppressed: () -> Bool = { false }
    var onOpenAt: ((Int) -> Void)?

    var body: some View {
        Group {
            switch attachments.count {
            case 0:
                EmptyView()
            case 1:
                attachmentCell(attachments[0], index: 0)
                    .frame(height: AloChatMediaSizing.single(dimensions: resolvedDimensions[0],
                        video: attachments[0].type == "video", availableWidth: availableWidth).height)
            default:
                // Telegram's album mosaic, up to ten tiles; anything beyond shows as "+N" on the last one.
                let mosaic = AloChatMosaic.layout(dimensions: resolvedDimensions, availableWidth: availableWidth)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(mosaic.frames.enumerated()), id: \.offset) { index, frame in
                        attachmentCell(attachments[index], index: index,
                                       extraCount: index == mosaic.frames.count - 1 ? max(0, attachments.count - mosaic.frames.count) : 0)
                            .frame(width: frame.width, height: frame.height)
                            .clipped()
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: mosaic.size.width, height: mosaic.size.height, alignment: .topLeading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: edgeToEdge ? 0 : 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: edgeToEdge ? 0 : 18, style: .continuous)
                .stroke(Color.white.opacity(edgeToEdge ? 0 : 0.08), lineWidth: 1)
        )
    }

    private var resolvedDimensions: [AloMediaDimensions?] {
        dimensions ?? attachments.map(\.mediaDimensions)
    }

    private func attachmentCell(_ attachment: AloMessageAttachment, index: Int, extraCount: Int = 0) -> some View {
        RemoteAttachmentCell(attachment: attachment, extraCount: extraCount)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isTapSuppressed() else { return }
                onOpenAt?(index)
            }
    }
}

private struct ExpiringMediaPlaceholder: View {
    let itemCount: Int
    let selfDestructSeconds: Int

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "timer")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.10))
                .clipShape(Circle())

            Text(
                selfDestructSeconds == 1
                    ? "Открыть один раз"
                    : "Открыть на \(durationLabel(selfDestructSeconds))"
            )
            .font(.system(size: 15, weight: .semibold))

            if itemCount > 1 {
                Text("\(itemCount) медиа")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
            }
        }
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.09, green: 0.10, blue: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func durationLabel(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        if safe >= 86_400, safe.isMultiple(of: 86_400) {
            return "\(safe / 86_400) д."
        }
        if safe >= 3_600, safe.isMultiple(of: 3_600) {
            return "\(safe / 3_600) ч."
        }
        if safe >= 60, safe.isMultiple(of: 60) {
            return "\(safe / 60) мин."
        }
        return "\(safe) с"
    }
}

private struct MessageExpiryBadge: View {
    let message: AloChatMessage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label(label(at: context.date), systemImage: "timer")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.82))
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.22))
                .clipShape(Capsule())
        }
    }

    private func label(at now: Date) -> String {
        guard let expiryDate else {
            if message.selfDestructSeconds == 1 {
                return "Один просмотр"
            }
            return "После открытия: \(durationLabel(message.selfDestructSeconds))"
        }
        return durationLabel(max(0, Int(ceil(expiryDate.timeIntervalSince(now)))))
    }

    private var expiryDate: Date? {
        guard !message.expiresAt.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: message.expiresAt)
            ?? ISO8601DateFormatter().date(from: message.expiresAt)
    }

    private func durationLabel(_ value: Int) -> String {
        let seconds = max(0, value)
        if seconds >= 3600 {
            return "\(seconds / 3600) ч"
        }
        if seconds >= 60 {
            return "\(seconds / 60) мин"
        }
        return "\(seconds) с"
    }
}

private struct VoiceMessageAttachmentView: View {
    @EnvironmentObject private var app: AloAppModel
    let attachment: AloMessageAttachment
    var senderName = "Голосовое сообщение"
    let isMine: Bool
    let accentColor: Color
    var showMessageMeta = false
    var createdAt = ""
    var editedAt = ""
    var isRead = false
    var isPending = false
    var isScheduled = false
    var preparePlayback: (() async -> Bool)?
    let onLongPress: () -> Void
    var isTapSuppressed: () -> Bool = { false }

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var durationUnavailable = false
    @State private var endObserver: NSObjectProtocol?
    @State private var isSeeking = false
    @State private var hasStartedScrubbing = false
    @State private var playbackSpeed: Double = 1
    @State private var hasPreparedPlayback = false
    @State private var isPreparingPlayback = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Button(action: requestPlaybackToggle) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.95))
                    if isPreparingPlayback {
                        AloMediaLoadingRing(color: accentColor, diameter: 22)
                    } else {
                        // The icon morphs between play and pause instead of swapping.
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(accentColor)
                            .contentTransition(.symbolEffect(.replace.downUp))
                            .offset(x: isPlaying ? 0 : 1)
                    }
                }
                .frame(width: 40, height: 40)
                .animation(.spring(response: 0.26, dampingFraction: 0.8), value: isPlaying)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(AloChatPressStyle())
            .accessibilityLabel(isPlaying ? "Приостановить голосовое" : "Воспроизвести голосовое")
            .accessibilityIdentifier("alo.voice.play")

            VStack(alignment: .leading, spacing: 2) {
                GeometryReader { proxy in
                    VoiceScrubberWaveform(
                        progress: progress,
                        levels: attachment.waveform,
                        activeColor: Color.white,
                        inactiveColor: Color.white.opacity(0.34)
                    )
                        .contentShape(Rectangle())
                        .gesture(scrubGesture(width: proxy.size.width))
                        .aloChatSwipeControl()
                }
                .frame(height: 20)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Перемотка голосового")
                .accessibilityIdentifier("alo.voice.scrubber")

                HStack(alignment: .center, spacing: 6) {
                    Text(voiceTimeLabel)
                        .accessibilityIdentifier("alo.voice.duration")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.76))
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    if showMessageMeta {
                        HStack(alignment: .center, spacing: 3) {
                            if !editedAt.isEmpty {
                                Text("изм.")
                            }
                            Text(AloFormatters.messageTime(createdAt))
                            if isMine {
                                MessageReadStatusChecks(
                                    isRead: isRead,
                                    isSending: isPending,
                                    isScheduled: isScheduled
                                )
                                    .scaleEffect(0.86, anchor: .center)
                            }
                        }
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .monospacedDigit()
                    }
                }
                .frame(height: 12, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 39, alignment: .leading)
        .contentShape(Rectangle())
        .task(id: attachment.url) {
            durationUnavailable = false
            if let seconds = attachment.durationSeconds { duration = seconds; return }
            // Do not open disappearing media before the explicit playback action.
            guard preparePlayback == nil, let url = app.api.absoluteURL(attachment.url) else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let preview = await AloMediaPreviewCache.shared.preview(url: url, video: false)
            guard !Task.isCancelled else { return }
            if let seconds = preview.duration { duration = seconds }
            else { durationUnavailable = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloMediaPlaybackDidStart)) { notification in
            guard (notification.object as? String) != attachment.id else { return }
            stopPlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackDidStart)) { notification in
            guard let playingAttachmentId = notification.object as? String,
                  playingAttachmentId != attachment.id,
                  isPlaying else {
                return
            }
            player?.pause()
            isPlaying = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackToggleRequested)) { notification in
            guard (notification.object as? String) == attachment.id else { return }
            requestPlaybackToggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackStopRequested)) { notification in
            guard (notification.object as? String) == attachment.id else { return }
            stopPlayback()
            NotificationCenter.default.post(name: .aloVoicePlaybackDidStop, object: attachment.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .aloVoicePlaybackSpeedChanged)) { notification in
            guard (notification.object as? String) == attachment.id,
                  let speed = notification.userInfo?["speed"] as? Double else { return }
            playbackSpeed = speed
            if isPlaying {
                player?.rate = Float(speed)
            }
        }
        .onDisappear(perform: stopPlayback)
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, currentTime / duration))
    }

    private var voiceTimeLabel: String {
        if duration == 0 { return durationUnavailable ? "Недоступно" : "…" }
        return isPlaying || currentTime > 0 ? formatTime(currentTime) : formatTime(duration)
    }

    private func requestPlaybackToggle() {
        guard !isPreparingPlayback, !isTapSuppressed() else { return }
        guard !hasPreparedPlayback, let preparePlayback else {
            togglePlayback()
            return
        }
        isPreparingPlayback = true
        Task {
            let canPlay = await preparePlayback()
            await MainActor.run {
                isPreparingPlayback = false
                guard canPlay else { return }
                hasPreparedPlayback = true
                togglePlayback()
            }
        }
    }

    private func togglePlayback() {
        if player == nil {
            preparePlayer()
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            NotificationCenter.default.post(
                name: .aloVoicePlaybackDidStart,
                object: attachment.id,
                userInfo: [
                    "title": senderName,
                    "speed": playbackSpeed,
                    "isPlaying": false
                ]
            )
        } else {
            NotificationCenter.default.post(name: .aloMediaPlaybackDidStart, object: attachment.id)
            NotificationCenter.default.post(
                name: .aloVoicePlaybackDidStart,
                object: attachment.id,
                userInfo: [
                    "title": senderName,
                    "speed": playbackSpeed,
                    "isPlaying": true
                ]
            )
            player.rate = Float(playbackSpeed)
            isPlaying = true
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard preparePlayback == nil || hasPreparedPlayback else { return }
                let distance = hypot(value.translation.width, value.translation.height)
                if !hasStartedScrubbing && (distance < 6 || abs(value.translation.height) >= abs(value.translation.width)) {
                    return
                }
                hasStartedScrubbing = true
                isSeeking = true
                let location = max(0, min(width, value.startLocation.x + value.translation.width))
                let normalized = min(1, max(0, location / max(1, width)))
                seek(to: normalized * duration, playAfterSeek: isPlaying)
            }
            .onEnded { _ in
                hasStartedScrubbing = false
                isSeeking = false
            }
    }

    private func seek(to seconds: Double, playAfterSeek: Bool) {
        if player == nil {
            preparePlayer()
        }
        let target = max(0, min(duration, seconds))
        currentTime = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { _ in
            if playAfterSeek {
                player?.rate = Float(playbackSpeed)
            }
        }
    }

    private func preparePlayer() {
        guard let url = app.api.absoluteURL(attachment.url) else { return }
        let player = AloSecureMediaStore.shared.makePlayer(url: url)
        self.player = player
        if let item = player.currentItem {
            Task {
                let loadedDuration = try? await item.asset.load(.duration)
                if let seconds = loadedDuration?.seconds,
                   seconds.isFinite,
                   seconds > 0 {
                    await MainActor.run { duration = seconds }
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600),
            queue: .main
        ) { time in
            if !isSeeking {
                currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            isPlaying = false
            currentTime = 0
            player.seek(to: .zero)
            NotificationCenter.default.post(name: .aloVoicePlaybackDidStop, object: attachment.id)
        }
    }

    private func stopPlayback() {
        let wasPlaying = isPlaying
        player?.pause()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        timeObserver = nil
        player = nil
        isPlaying = false
        if wasPlaying {
            NotificationCenter.default.post(name: .aloVoicePlaybackDidStop, object: attachment.id)
        }
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VoiceScrubberWaveform: View {
    let progress: Double
    var levels: [CGFloat] = []
    var activeColor: Color = .white
    var inactiveColor: Color = Color.white.opacity(0.34)

    var body: some View {
        GeometryReader { geometry in
            let samples = AloVoiceWaveform.samples(levels, width: geometry.size.width)
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(Double(index + 1) / Double(max(1, samples.count)) <= progress ? activeColor : inactiveColor)
                        .frame(maxWidth: 3)
                        .frame(height: 4 + level * 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}

private struct CircleMessageAttachmentView: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.aloCirclePlayback) private var sharedPlayback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let attachment: AloMessageAttachment
    let accentColor: Color
    var messageID = 0
    var senderName = "Видеосообщение"
    var preparePlayback: (() async -> Bool)?
    var isTapSuppressed: () -> Bool = { false }

    @State private var localPlayback = AloCirclePlayback()
    @State private var poster: UIImage?
    @State private var hasPreparedPlayback = false
    @State private var isPreparingPlayback = false
    @State private var isScrubbing = false
    private var playback: AloCirclePlayback { sharedPlayback ?? localPlayback }
    private var active: Bool { playback.item?.id == attachment.id }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle().fill(AloTheme.background)
                if let poster {
                    // The poster is cropped to a square once, so it fits the circle exactly
                    // instead of a wider filled image that is only clipped visually.
                    Image(uiImage: poster).resizable().scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "video.circle.fill").font(.system(size: 46))
                        .foregroundStyle(accentColor)
                }
                if active && playback.surfaceOwner == .inline {
                    AloCirclePlayerSurface(playback: playback, accent: accentColor)
                        .allowsHitTesting(false)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 24))
                        .foregroundStyle(.white).frame(width: 52, height: 52)
                        .background(.black.opacity(0.35), in: Circle())
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.88).combined(with: .opacity))
                }
                if isPreparingPlayback { ProgressView().tint(.white) }
            }
            .clipShape(Circle())
            .contentShape(Circle())
            .onTapGesture { requestPlaybackToggle() }
            .simultaneousGesture(playbackGesture(size: proxy.size))
            .aloChatSwipeControl(ring: true, enabled: active)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if active { playback.updateVisibility(id: attachment.id, frame: frame) }
            }
            .onChange(of: playback.item?.id) { _, _ in
                if active { playback.updateVisibility(id: attachment.id, frame: proxy.frame(in: .global)) }
            }
            .onChange(of: playback.viewport) { _, _ in
                if active { playback.updateVisibility(id: attachment.id, frame: proxy.frame(in: .global)) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(active && playback.isPlaying ? "Приостановить видеосообщение" : "Воспроизвести видеосообщение")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("alo.circle.play")
            .accessibilityValue(active && playback.isPlaying ? "Воспроизводится" : "Остановлено")
            .accessibilityAction { requestPlaybackToggle() }
            .animation(
                reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.32, dampingFraction: 0.9),
                value: active
            )
        }
        .task(id: attachment.url) {
            guard preparePlayback == nil, let url = app.api.absoluteURL(attachment.url) else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let preview = await AloMediaPreviewCache.shared.preview(url: url, video: true)
            guard !Task.isCancelled else { return }
            poster = preview.image.map(AloSquareImage.centerCrop)
        }
        .onDisappear {
            playback.leaveInline(id: attachment.id)
            if sharedPlayback == nil { localPlayback.stop() }
        }
    }

    private func requestPlaybackToggle() {
        guard !isPreparingPlayback, !isTapSuppressed() else { return }
        guard !hasPreparedPlayback, let preparePlayback else { toggle(); return }
        isPreparingPlayback = true
        Task {
            let canPlay = await preparePlayback()
            isPreparingPlayback = false
            guard canPlay else { return }
            hasPreparedPlayback = true
            toggle()
        }
    }

    private func toggle() {
        guard let url = app.api.absoluteURL(attachment.url) else { return }
        playback.toggle(
            AloCircleQueueItem(id: attachment.id, messageID: messageID, url: url, title: senderName),
            startsInline: true
        )
    }

    private func playbackGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard active else { return }
                let radius = min(size.width, size.height) / 2
                let distance = hypot(value.startLocation.x - size.width / 2, value.startLocation.y - size.height / 2)
                guard abs(distance - radius) <= 28,
                      isScrubbing || abs(value.translation.width) > abs(value.translation.height),
                      hypot(value.translation.width, value.translation.height) > 8 else { return }
                isScrubbing = true
                var angle = atan2(value.location.y - size.height / 2, value.location.x - size.width / 2) + .pi / 2
                if angle < 0 { angle += .pi * 2 }
                playback.seek(angle / (.pi * 2))
            }
            .onEnded { _ in isScrubbing = false }
    }
}

private struct RemoteAttachmentCell: View {
    @EnvironmentObject private var app: AloAppModel
    let attachment: AloMessageAttachment
    var extraCount = 0

    var body: some View {
        GeometryReader { geometry in
        ZStack {
            AloTheme.background
            if let url = previewURL {
                AloAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    case .failure:
                        RemoteMediaLoadingPlaceholder(isVideo: isVideo, isFailed: true)
                    case .empty:
                        RemoteMediaLoadingPlaceholder(isVideo: isVideo, isFailed: false)
                    @unknown default:
                        RemoteMediaLoadingPlaceholder(isVideo: isVideo, isFailed: false)
                    }
                }
            } else if isVideo {
                RemoteVideoPosterFallback(title: attachment.name.ifBlank("Видео"))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: isVideo ? "play.rectangle.fill" : "doc.fill")
                        .font(.system(size: 28, weight: .bold))
                    Text(attachment.name.ifBlank(isVideo ? "Видео" : "Файл"))
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(AloTheme.text)
                .padding(12)
            }

            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 50, height: 50)
                    .background(Color.black.opacity(0.46))
                    .clipShape(Circle())
            }

            if extraCount > 0 {
                Color.black.opacity(0.42)
                Text("+\(extraCount)")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped()
        }
    }

    private var isImage: Bool {
        attachment.type == "image" || attachment.url.lowercased().hasImageExtension
    }

    private var isVideo: Bool {
        attachment.type == "video" || attachment.url.lowercased().hasVideoExtension
    }

    private var previewURL: URL? {
        guard isImage || isVideo else { return nil }
        let source = previewSource
        guard !source.isEmpty else { return nil }
        return app.api.absoluteURL(source)
    }

    private var previewSource: String {
        if !attachment.posterUrl.isEmpty {
            return attachment.posterUrl
        }
        return isImage ? attachment.url : ""
    }
}

/// Media that is still loading: a flat, quiet surface with a slow light sweep and a small spinner ring
/// in the centre, as Telegram shows it. No blurred highlight blobs or dark gradients.
private struct RemoteMediaLoadingPlaceholder: View {
    let isVideo: Bool
    let isFailed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.07))
            if !isFailed && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = (context.date.timeIntervalSinceReferenceDate / 1.4).truncatingRemainder(dividingBy: 1)
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: -proxy.size.width * 0.6 + proxy.size.width * 1.6 * phase)
                    }
                }
                .allowsHitTesting(false)
            }
            ZStack {
                Circle().fill(Color.black.opacity(0.42))
                if isFailed {
                    Image(systemName: isVideo ? "play.slash.fill" : "arrow.clockwise")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                } else {
                    AloMediaLoadingRing()
                }
            }
            .frame(width: 46, height: 46)
            .accessibilityLabel(isFailed ? "Нет связи" : "Загрузка")
        }
    }
}

/// A quarter-ring that turns steadily, like Telegram's download indicator.
private struct AloMediaLoadingRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color = .white
    var diameter: CGFloat = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let angle = reduceMotion ? 0 : (context.date.timeIntervalSinceReferenceDate * 360 / 1.0).truncatingRemainder(dividingBy: 360)
            Circle().trim(from: 0, to: 0.28)
                .stroke(color.opacity(0.92), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(angle))
        }
    }
}

private struct RemoteVideoPosterFallback: View {
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.38),
                    Color.white.opacity(0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 9) {
                Image(systemName: "play.fill")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 50, height: 50)
                    .background(Color.black.opacity(0.42))
                    .clipShape(Circle())

                Text(title.ifBlank("Видео"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(1)
            }
            .padding(12)
        }
    }
}

private struct ChatMediaViewerState: Identifiable {
    let id = UUID()
    let items: [AloMediaItem]
    let startIndex: Int
    let isSensitive: Bool
    let topicId: Int
    let reportsScreenshot: Bool

    init(
        items: [AloMediaItem],
        startIndex: Int,
        isSensitive: Bool = false,
        topicId: Int = 0,
        reportsScreenshot: Bool = false
    ) {
        self.items = items
        self.startIndex = startIndex
        self.isSensitive = isSensitive
        self.topicId = topicId
        self.reportsScreenshot = reportsScreenshot
    }
}

private struct ChatSystemEventPill: View {
    let event: AloChatSystemEvent
    let isMine: Bool

    private var title: String {
        switch event {
        case .protectedMediaScreenshot:
            return isMine
                ? "Вы сделали снимок исчезающего медиа"
                : "Сделан снимок исчезающего медиа"
        }
    }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.9))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.58))
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .accessibilityLabel(title)
    }
}

private struct ChatMediaViewer: View {
    @EnvironmentObject private var app: AloAppModel
    let state: ChatMediaViewerState
    let onDismiss: () -> Void

    @State private var selectedIndex: Int
    @State private var isZoomed = false
    @State private var chromeHidden = false
    @State private var chromeToken = 0
    @State private var dismissState = AloViewerDismissState()
    @State private var isScreenCaptured = UIScreen.main.isCaptured
    @State private var screenshotDetected = false
    @State private var didReportScreenshot = false

    init(state: ChatMediaViewerState, onDismiss: @escaping () -> Void) {
        self.state = state
        self.onDismiss = onDismiss
        _selectedIndex = State(initialValue: min(max(0, state.startIndex), max(0, state.items.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - dismissState.progress).ignoresSafeArea()

            TabView(selection: $selectedIndex) {
                ForEach(state.items.indices, id: \.self) { index in
                    viewerContent(for: state.items[index], isActive: index == selectedIndex)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: state.items.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            .modifier(AloViewerDismissModifier(state: $dismissState))

            if state.isSensitive && (isScreenCaptured || screenshotDetected) {
                Color.black.ignoresSafeArea()
            }

            VStack {
                HStack(alignment: .top) {
                    AloChatCircleButton(systemImage: "chevron.left", label: "Закрыть медиа", action: onDismiss)
                        .accessibilityIdentifier("alo.media.close")
                        .frame(height: AloChatMetrics.headerHeight)

                    Spacer()

                    if state.items.count > 1 {
                        Text("\(selectedIndex + 1) из \(state.items.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minHeight: AloChatMetrics.headerHeight)
                            .accessibilityIdentifier("alo.media.position")
                        Spacer()
                        Color.clear.frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: AloChatMetrics.headerHeight)
                .padding(.horizontal, AloChatMetrics.headerHorizontalInset)
                .padding(.top, AloChatMetrics.headerTopInset)
                .opacity(chromeHidden ? 0 : 1)

                Spacer()

                if let caption = currentItem?.caption, !caption.isEmpty, !chromeHidden {
                    Text(caption)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.44))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 18)
                        .padding(.bottom, 24)
                }
            }
        }
        .presentationBackground(.clear)
        .task(id: chromeToken) {
            guard !chromeHidden else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = true }
        }
        .onChange(of: isZoomed) { _, zoomed in
            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = zoomed }
            if !zoomed { chromeToken += 1 }
        }
        .onChange(of: selectedIndex) { _, _ in
            chromeHidden = false
            chromeToken += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            isScreenCaptured = UIScreen.main.isCaptured
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard state.isSensitive else { return }
            screenshotDetected = true
            if state.reportsScreenshot && !didReportScreenshot {
                didReportScreenshot = true
                app.sendChatSystemEvent(
                    AloChatSystemEventCodec.encode(.protectedMediaScreenshot),
                    topicId: state.topicId
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                onDismiss()
            }
        }
        .onAppear {
            guard state.isSensitive else { return }
            AloProtectedContentShield.shared.beginViewingProtectedContent()
        }
        .onDisappear {
            guard state.isSensitive else { return }
            AloProtectedContentShield.shared.endViewingProtectedContent()
        }
    }

    @ViewBuilder
    private func viewerContent(for item: AloMediaItem, isActive: Bool) -> some View {
        let source = item.posterUrl.ifBlank(item.url)
        if item.type.lowercased().contains("video"), let url = app.api.absoluteURL(item.url.ifBlank(item.posterUrl)) {
            ChatMediaVideoPlayer(url: url, isActive: isActive, dismiss: dismissDrag)
        } else if let image = localImage(from: source) {
            AloZoomableImage(image: image, onZoomChanged: { if isActive { isZoomed = $0 } },
                             onSingleTap: { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }; chromeToken += 1 },
                             dismiss: dismissDrag)
                .ignoresSafeArea()
        } else if let url = app.api.absoluteURL(source) {
            AloZoomableImagePage(url: url, isActive: isActive,
                onZoomChanged: { isZoomed = $0 },
                onSingleTap: { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }; chromeToken += 1 },
                dismiss: dismissDrag) { failed in
                RemoteMediaLoadingPlaceholder(isVideo: false, isFailed: failed)
            }
        } else {
            RemoteMediaLoadingPlaceholder(isVideo: false, isFailed: true)
        }
    }

    private var dismissDrag: AloViewerDismissDrag {
        AloViewerDismissDrag(changed: { dismissState.offset = $0 }, ended: { translation, velocity in
            if AloViewerDismissState.shouldDismiss(translation: translation, velocity: velocity) {
                withAnimation(.easeOut(duration: 0.2)) { dismissState.offset = translation >= 0 ? 1_000 : -1_000 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onDismiss() }
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { dismissState.offset = 0 }
            }
        })
    }

    private func localImage(from value: String) -> UIImage? {
        guard value.hasPrefix("data:image"),
              let commaIndex = value.firstIndex(of: ",") else { return nil }
        let encoded = String(value[value.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return UIImage(data: data)
    }

    private var currentItem: AloMediaItem? {
        guard state.items.indices.contains(selectedIndex) else { return state.items.first }
        return state.items[selectedIndex]
    }
}

private struct ChatMediaVideoPlayer: View {
    let url: URL
    var isActive = true
    var dismiss: AloViewerDismissDrag? = nil
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                AloVideoPlayerView(player: player, dismiss: dismiss)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(AloTheme.accent)
            }
        }
        .onAppear {
            if isActive, player == nil {
                player = AloSecureMediaStore.shared.makePlayer(url: url)
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .onChange(of: isActive) { _, active in
            if active, player == nil { player = AloSecureMediaStore.shared.makePlayer(url: url) }
            else if !active { player?.pause(); player = nil }
        }
    }
}

private struct LocalAttachmentFullscreenPreview: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: AloLocalAttachment
    let accentColor: Color

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 44)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.86))
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if attachment.type == "image" {
            LocalDraftPhotoPreview(attachment: attachment, mode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if attachment.type == "video" {
            LocalDraftVideoPlayer(attachment: attachment)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(accentColor.opacity(0.28), lineWidth: 1)
                )
        } else {
            VStack(spacing: 14) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(accentColor)
                Text(attachment.name.ifBlank("Файл"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct LocalDraftVideoPlayer: View {
    let attachment: AloLocalAttachment
    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?

    var body: some View {
        Group {
            if let player {
                AloVideoPlayerView(player: player, autoplay: false)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(AloTheme.accent)
            }
        }
        .onAppear(perform: preparePlayer)
        .onDisappear(perform: cleanup)
    }

    private func preparePlayer() {
        guard player == nil else { return }
        if let url = attachment.localPlaybackURL {
            player = AloSecureMediaStore.shared.makePlayer(url: url)
            return
        }
        let fileExtension = attachment.mime.contains("quicktime") ? "mov" : "mp4"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-local-preview-\(attachment.id.uuidString).\(fileExtension)")
        do {
            try attachment.data.write(to: url, options: .atomic)
            temporaryURL = url
            player = AloSecureMediaStore.shared.makePlayer(url: url)
        } catch {
            temporaryURL = nil
        }
    }

    private func cleanup() {
        player?.pause()
        player = nil
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        temporaryURL = nil
    }
}

private struct LocalAttachmentStrip: View {
    let attachments: [AloLocalAttachment]
    let accentColor: Color
    let onAdd: () -> Void
    let onOpen: (AloLocalAttachment) -> Void
    let onRemove: (AloLocalAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(attachmentTitle, systemImage: "photo.on.rectangle.angled")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(AloTheme.text)
                    Text(attachments.count == 1 ? "Отправится с подписью" : "Отправится одним сообщением")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(AloTheme.muted)
                }
                Spacer(minLength: 8)
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 28, height: 28)
                        .background(accentColor)
                        .clipShape(Circle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.84))
            }

            LocalAttachmentPreviewGrid(
                attachments: attachments,
                accentColor: accentColor,
                onOpen: onOpen,
                onRemove: onRemove
            )
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AloTheme.surface.opacity(0.68))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AloTheme.border.opacity(0.50), lineWidth: 1)
        )
    }

    private var attachmentTitle: String {
        let photoCount = attachments.filter { $0.type == "image" }.count
        let videoCount = attachments.filter { $0.type == "video" }.count
        if photoCount > 0 && videoCount > 0 {
            return "\(photoCount) фото, \(videoCount) видео"
        }
        if photoCount > 0 {
            return photoCount == 1 ? "Фото с подписью" : "\(photoCount) фото"
        }
        if videoCount > 0 {
            return videoCount == 1 ? "Видео с подписью" : "\(videoCount) видео"
        }
        return "\(attachments.count) вложений"
    }
}

private struct LocalAttachmentPreviewGrid: View {
    let attachments: [AloLocalAttachment]
    let accentColor: Color
    let onOpen: (AloLocalAttachment) -> Void
    let onRemove: (AloLocalAttachment) -> Void

    var body: some View {
        Group {
            switch attachments.count {
            case 0:
                EmptyView()
            case 1:
                tile(attachments[0], index: 0)
                    .frame(height: 118)
            case 2:
                HStack(spacing: 3) {
                    tile(attachments[0], index: 0)
                    tile(attachments[1], index: 1)
                }
                .frame(height: 112)
            case 3:
                HStack(spacing: 3) {
                    tile(attachments[0], index: 0)
                    VStack(spacing: 3) {
                        tile(attachments[1], index: 1)
                        tile(attachments[2], index: 2)
                    }
                }
                .frame(height: 144)
            default:
                LazyVGrid(columns: gridColumns, spacing: 3) {
                    ForEach(Array(attachments.prefix(4).enumerated()), id: \.element.id) { index, attachment in
                        tile(attachment, index: index, overlayText: index == 3 && attachments.count > 4 ? "+\(attachments.count - 4)" : nil)
                            .frame(height: 72)
                    }
                }
        }
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]
    }

    private func tile(_ attachment: AloLocalAttachment, index: Int, overlayText: String? = nil) -> some View {
        LocalAttachmentPreviewTile(
            attachment: attachment,
            accentColor: accentColor,
            index: index,
            overlayText: overlayText,
            onOpen: { onOpen(attachment) },
            onRemove: { onRemove(attachment) }
        )
    }
}

private struct LocalAttachmentPreviewTile: View {
    let attachment: AloLocalAttachment
    let accentColor: Color
    let index: Int
    let overlayText: String?
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LocalAttachmentVisual(attachment: attachment, accentColor: accentColor)

            if let overlayText {
                Color.black.opacity(0.48)
                Text(overlayText)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack {
                Spacer()
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Color.black.opacity(0.52))
                        .clipShape(Capsule())

                    if attachment.type == "video" {
                        Label("Видео", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Color.black.opacity(0.52))
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 0)
                }
                .padding(7)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.60))
                    .clipShape(Circle())
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.82))
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture(perform: onOpen)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct LocalDraftPhotoPreview: View {
    let attachment: AloLocalAttachment
    var mode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: mode)
                    .accessibilityIdentifier("alo.local.image.loaded")
            } else {
                Image(systemName: "photo").foregroundStyle(AloTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: attachment.id) {
            let result = try? await AloImageCache.draftImage(attachment, maxPixelSize: mode == .fit ? 2_048 : 512)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

private struct LocalAttachmentVisual: View {
    let attachment: AloLocalAttachment
    let accentColor: Color

    var body: some View {
        ZStack {
            AloTheme.surfaceRaised
            if attachment.type == "image" {
                LocalDraftPhotoPreview(attachment: attachment)
            } else if attachment.type == "video" {
                LocalVideoAttachmentPreview(attachment: attachment, accentColor: accentColor)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(AloTheme.text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct LocalVideoAttachmentPreview: View {
    let attachment: AloLocalAttachment
    let accentColor: Color
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [AloTheme.background, accentColor.opacity(0.28)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            Image(systemName: "play.fill")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(accentColor)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.92))
                .clipShape(Circle())
        }
        .task(id: attachment.id) {
            thumbnail = nil
            let preview = await AloMediaPreviewCache.shared.preview(localVideo: attachment)
            guard !Task.isCancelled else { return }
            thumbnail = preview.image
        }
    }
}

private enum ChatRecordingMode: Equatable {
    case voice
    case circle

    var title: String {
        switch self {
        case .voice: return "Голосовое"
        case .circle: return "Кружок"
        }
    }

    var shortTitle: String {
        switch self {
        case .voice: return "ГС"
        case .circle: return "Кружок"
        }
    }

    var systemImage: String {
        switch self {
        case .voice: return "mic.fill"
        case .circle: return "video.circle.fill"
        }
    }

}

private enum ChatCallKind {
    case audio
    case video

    var title: String {
        switch self {
        case .audio: return "Аудиозвонок"
        case .video: return "Видеозвонок"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: return "phone.fill"
        case .video: return "video.fill"
        }
    }
}

private extension ChatCallLogMeta {
    func menuTitle(isMine: Bool) -> String {
        let isVideo = callType == "video"
        let isGroup = scope == "group"
        switch status {
        case "missed":
            return isMine ? "Звонок без ответа" : "Пропущенный звонок"
        case "declined":
            return isMine ? "Звонок отклонён" : "Отклонённый звонок"
        default:
            if isGroup && isVideo { return "Групповой видеозвонок" }
            if isGroup { return "Групповой звонок" }
            if isVideo { return isMine ? "Исходящий видеозвонок" : "Входящий видеозвонок" }
            return isMine ? "Исходящий звонок" : "Входящий звонок"
        }
    }
}

private extension AloChatMessage {
    var chatCallLogMeta: ChatCallLogMeta? {
        let candidates = [attachmentName, body, attachmentUrl].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for raw in candidates {
            if let meta = ChatCallLogMeta(rawJSON: raw) {
                return meta
            }
        }
        guard attachmentType == "call" else { return nil }
        return ChatCallLogMeta(callType: "voice", status: "ended", durationSec: 0, scope: "")
    }
}

private extension ChatCallLogMeta {
    init?(rawJSON: String) {
        guard rawJSON.contains("call") || rawJSON.contains("callType") else { return nil }
        guard let data = rawJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let kind = json.string("kind")
        let callTypeValue = json.string("callType").ifBlank(json.string("type"))
        guard kind == "call" || !callTypeValue.isEmpty || json["durationSec"] != nil else { return nil }
        callType = callTypeValue.ifBlank("voice")
        status = json.string("status").ifBlank("ended")
        durationSec = json.int("durationSec")
        scope = json.string("scope")
    }
}

private enum ChatComposerMetrics {
    static let controlSize: CGFloat = AloInputMetrics.touchHeight
    static let visualSize: CGFloat = AloInputMetrics.height
    static let verticalChromePadding: CGFloat = AloInputMetrics.verticalPadding
    static let keyboardGap: CGFloat = 4
    static let collapsedChromeHeight = controlSize + verticalChromePadding * 2
}

enum ChatKeyboardFollowPolicy {
    static func shouldFollow(
        hasUserScrolledConversation: Bool,
        isNearBottom: Bool,
        isEmpty: Bool
    ) -> Bool {
        isEmpty || !hasUserScrolledConversation || isNearBottom
    }
}

private struct ChatRecordSendButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: ChatRecordingMode
    let canSend: Bool
    var isEditing = false
    let isRecording: Bool
    let isLocked: Bool
    let level: CGFloat
    @Binding var drag: AloRecordingDrag
    let accentColor: Color
    let allowsSendOptions: Bool
    let onSend: () -> Void
    let onShowSendOptions: () -> Void
    let onToggleMode: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    let onLock: () -> Void
    let onCancel: () -> Void

    @State private var isPressing = false
    @State private var didStartHold = false
    @State private var didLockRecording = false
    @State private var didCancelRecording = false
    @State private var didOpenSendOptions = false
    @State private var pressToken = UUID()
    @GestureState private var touchActive = false

    var body: some View {
        ZStack {
            Image(systemName: canSend ? (isEditing ? "checkmark" : "arrow.right") : mode.systemImage)
                .font(.system(size: canSend ? 19 : 20, weight: .medium))
                .foregroundStyle(canSend ? Color.white : AloTheme.muted)
        }
        .frame(width: ChatComposerMetrics.visualSize, height: ChatComposerMetrics.visualSize)
        .background {
            if canSend {
                Circle().fill(accentColor)
            } else {
                Color.clear.modifier(AloChatGlass())
            }
        }
        .frame(width: ChatComposerMetrics.controlSize, height: ChatComposerMetrics.controlSize)
        .opacity(isRecording ? 0 : 1)
        .overlay {
            if isRecording && !isLocked {
                AloRecordingOrb(symbol: mode.systemImage, color: accentColor,
                    level: level, cancelProgress: drag.cancelProgress)
                    .offset(drag.offset)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.4).combined(with: .opacity)
                            .animation(.spring(response: 0.5, dampingFraction: 0.82)),
                        removal: .scale(scale: 0.4).combined(with: .opacity)
                            .animation(.easeOut(duration: 0.18))))
            }
        }
        .aloElasticTouch(enabled: !isRecording)
        .contentShape(Circle())
        .gesture(recordGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(canSend ? (isEditing ? "Сохранить изменения" : "Отправить") : mode.title)
        .accessibilityIdentifier("alo.chat.record-send")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(canSend ? "" : "Нажмите для смены режима. Удерживайте для записи, сдвиньте вверх для фиксации или влево для отмены.")
        .accessibilityAction { canSend ? onSend() : onToggleMode() }
        .accessibilityAction(named: "Начать запись без удержания") {
            guard !canSend && !isRecording else { return }
            onHoldStart()
            onLock()
        }
        .onChange(of: touchActive) { _, active in
            // GestureState also resets after system cancellation, unlike onEnded.
            if !active, isPressing {
                pressToken = UUID()
                isPressing = false
                if didStartHold && !didLockRecording && !didCancelRecording && !isLocked { onCancel() }
                didStartHold = false
                drag = AloRecordingDrag()
            }
        }
        .onDisappear { pressToken = UUID() }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1), value: isPressing)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: mode)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: isRecording)
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($touchActive) { _, active, _ in active = true }
            .onChanged { value in
                if !isPressing {
                    isPressing = true
                    didStartHold = false
                    didLockRecording = false
                    didCancelRecording = false
                    didOpenSendOptions = false
                    let token = UUID()
                    pressToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + (canSend ? 0.30 : 0.19)) {
                        guard isPressing, pressToken == token else { return }
                        if canSend, allowsSendOptions {
                            didOpenSendOptions = true
                            AloHaptics.impact(.soft)
                            onShowSendOptions()
                        } else if !canSend {
                            didStartHold = true
                            onHoldStart()
                        }
                    }
                }

                guard didStartHold, !didCancelRecording, !didLockRecording, !isLocked else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { drag = AloRecordingDrag(translation: value.translation) }
                if drag.shouldLock {
                    didLockRecording = true
                    onLock()
                } else if drag.shouldCancel {
                    didCancelRecording = true
                    onCancel()
                }
            }
            .onEnded { value in
                let shouldFinishRecording = didStartHold
                let shouldStayLocked = didLockRecording || isLocked
                let shouldCancel = didCancelRecording
                let didOpenOptions = didOpenSendOptions
                let releaseIntent = AloRecordingDrag(translation: value.translation).releaseIntent(velocity: value.velocity)
                isPressing = false
                didStartHold = false
                didLockRecording = false
                didCancelRecording = false
                didOpenSendOptions = false
                pressToken = UUID()
                drag = AloRecordingDrag()
                if shouldCancel || shouldStayLocked {
                    return
                } else if shouldFinishRecording {
                    switch releaseIntent {
                    case .cancel: onCancel()
                    case .lock: onLock()
                    case .finish: onHoldEnd()
                    }
                } else if canSend {
                    if !didOpenOptions {
                        AloHaptics.impact(.light)
                        onSend()
                    }
                } else {
                    onToggleMode()
                }
            }
    }
}

private struct ChatSendOptionsSheet: View {
    let canSendWhenOnline: Bool
    let canRepeat: Bool
    let hasScheduledMessages: Bool
    let onSendSilently: () -> Void
    let onSendWhenOnline: () -> Void
    let onSchedule: () -> Void
    let onRepeat: () -> Void
    let onShowScheduled: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var sheetHeight: CGFloat {
        100 + CGFloat(2 + (canSendWhenOnline ? 1 : 0) + (canRepeat ? 1 : 0) + (hasScheduledMessages ? 1 : 0)) * 62
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(AloTheme.muted.opacity(0.55))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("Отправка сообщения")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AloTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                SendOptionRow(
                    title: "Отправить без звука",
                    subtitle: "Получатель увидит сообщение без уведомления",
                    systemImage: "bell.slash"
                ) {
                    perform(onSendSilently)
                }

                if canSendWhenOnline {
                    SendOptionDivider()
                    SendOptionRow(
                        title: "Когда появится в сети",
                        subtitle: "Сообщение уйдёт, когда получатель будет онлайн",
                        systemImage: "person.crop.circle.badge.clock"
                    ) {
                        perform(onSendWhenOnline)
                    }
                }

                SendOptionDivider()
                SendOptionRow(
                    title: "Выбрать дату и время",
                    subtitle: "Отправить позже",
                    systemImage: "calendar.badge.clock"
                ) {
                    perform(onSchedule)
                }

                if canRepeat {
                    SendOptionDivider()
                    SendOptionRow(
                        title: "Повторять отправку",
                        subtitle: "По дням, неделям или месяцам",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) {
                        perform(onRepeat)
                    }
                }

                if hasScheduledMessages {
                    SendOptionDivider()
                    SendOptionRow(
                        title: "Запланированные сообщения",
                        subtitle: "Изменить время или отменить отправку",
                        systemImage: "clock.badge"
                    ) {
                        perform(onShowScheduled)
                    }
                }
            }
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .background(AloTheme.background.ignoresSafeArea())
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(26)
    }

    private func perform(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: action)
    }
}

private struct SendOptionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AloTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(AloTheme.accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AloTheme.text)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(AloTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AloTheme.muted.opacity(0.75))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .aloTouchBounce(pressedScale: 0.98)
    }
}

private struct SendOptionDivider: View {
    var body: some View {
        Divider()
            .overlay(AloTheme.border.opacity(0.72))
            .padding(.leading, 62)
    }
}

private struct ChatScheduleMessageSheet: View {
    @Binding var date: Date
    let title: String
    let actionTitle: String
    let onSchedule: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        date: Binding<Date>,
        title: String = "Отправить позже",
        actionTitle: String = "Отправить",
        onSchedule: @escaping () -> Void
    ) {
        _date = date
        self.title = title
        self.actionTitle = actionTitle
        self.onSchedule = onSchedule
    }

    private var allowedRange: ClosedRange<Date> {
        Date().addingTimeInterval(60)...Date().addingTimeInterval(366 * 24 * 60 * 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(AloTheme.muted.opacity(0.55))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)

            HStack {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AloTheme.text)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AloTheme.muted)
                        .frame(width: 34, height: 34)
                        .background(AloTheme.surface, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            HStack(spacing: 8) {
                ScheduleQuickDateButton(title: "Через час") {
                    date = max(Date().addingTimeInterval(3600), allowedRange.lowerBound)
                }
                ScheduleQuickDateButton(title: "Сегодня вечером") {
                    date = nextTime(hour: 20, minute: 0)
                }
                ScheduleQuickDateButton(title: "Завтра утром") {
                    date = nextTime(hour: 9, minute: 0, requireTomorrow: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            DatePicker(
                "Дата и время",
                selection: $date,
                in: allowedRange,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.wheel)
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .tint(AloTheme.accent)
            .frame(height: 178)
            .clipped()

            Button {
                onSchedule()
            } label: {
                Text("\(actionTitle) \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white)
            .background(AloTheme.accent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(AloTheme.background.ignoresSafeArea())
        .presentationDetents([.height(390)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(26)
    }

    private func nextTime(hour: Int, minute: Int, requireTomorrow: Bool = false) -> Date {
        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        var candidate = calendar.date(from: components) ?? now
        if requireTomorrow || candidate <= now.addingTimeInterval(60) {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return min(max(candidate, allowedRange.lowerBound), allowedRange.upperBound)
    }
}

private struct ScheduleQuickDateButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AloTheme.accent)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(AloTheme.accent.opacity(0.12), in: Capsule())
            .buttonStyle(.plain)
            .aloTouchBounce(pressedScale: 0.96)
    }
}

private struct ChatScheduledMessagesSheet: View {
    let messages: [AloChatMessage]
    let onReschedule: (AloChatMessage) -> Void
    let onCancel: (AloChatMessage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if messages.isEmpty {
                    ContentUnavailableView(
                        "Нет отложенных сообщений",
                        systemImage: "clock",
                        description: Text("Новые отложенные сообщения появятся здесь.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(messages, id: \AloChatMessage.scheduledMessageId) { (message: AloChatMessage) in
                                HStack(spacing: 8) {
                                    Button {
                                        onReschedule(message)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: message.silent ? "bell.slash.fill" : "clock.fill")
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(AloTheme.accent)
                                                .frame(width: 30, height: 30)
                                                .background(AloTheme.accent.opacity(0.12), in: Circle())

                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(preview(for: message))
                                                    .font(.system(size: 16, weight: .medium))
                                                    .foregroundStyle(AloTheme.text)
                                                    .lineLimit(2)
                                                Text(scheduleLabel(for: message))
                                                    .font(.system(size: 13, weight: .medium))
                                                    .foregroundStyle(AloTheme.muted)
                                                if !message.deliveryError.isEmpty {
                                                    Text("Не удалось отправить: \(message.deliveryError)")
                                                        .font(.system(size: 12, weight: .medium))
                                                        .foregroundStyle(Color.red)
                                                        .lineLimit(2)
                                                }
                                            }
                                            Spacer(minLength: 8)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button(role: .destructive) {
                                        onCancel(message)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 16, weight: .semibold))
                                            .frame(width: 40, height: 40)
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)

                                Divider()
                                    .overlay(AloTheme.border.opacity(0.7))
                                    .padding(.leading, 60)
                            }
                        }
                    }
                }
            }
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Отложенные сообщения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func preview(for message: AloChatMessage) -> String {
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return chatPreviewText(body) }
        if message.attachments.contains(where: \.isVoiceLike) { return "Голосовое сообщение" }
        if message.attachments.contains(where: \.isCircleLike) { return "Кружок" }
        if !message.attachments.isEmpty { return message.attachments.first?.name.ifBlank("Вложение") ?? "Вложение" }
        return "Сообщение"
    }

    private func scheduleLabel(for message: AloChatMessage) -> String {
        if message.sendWhenOnline {
            return "Когда появится в сети"
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: message.scheduledAt)
            ?? ISO8601DateFormatter().date(from: message.scheduledAt)
        guard let date else { return "Время отправки не определено" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct RecordingComposerPanel: View {
    let mode: ChatRecordingMode
    let startedAt: Date
    let ready: Bool
    let isLocked: Bool
    let drag: AloRecordingDrag
    let accentColor: Color
    let levels: [CGFloat]
    let onCancel: () -> Void
    let onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if isLocked {
                Button(action: onCancel) {
                    Image(systemName: "trash").font(.system(size: 19))
                        .foregroundStyle(.red).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AloControlPressStyle())
                .accessibilityLabel("Удалить запись")
            }
            AloRecordingTimer(startedAt: startedAt, ready: ready)
                .padding(.leading, isLocked ? 0 : 14)
            if isLocked {
                if mode == .voice {
                    VoiceWaveform(levels: levels, activeColor: accentColor)
                        .frame(height: 20)
                } else {
                    Spacer(minLength: 0)
                }
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.system(size: 15))
                        .foregroundStyle(accentColor).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AloControlPressStyle())
                .accessibilityLabel(mode == .voice ? "Завершить и прослушать запись" : "Завершить и просмотреть кружок")
                .disabled(!ready)
            } else {
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Label(ready ? "Отмена" : "Подготовка…", systemImage: "chevron.left")
                        .font(.system(size: 14)).foregroundStyle(AloTheme.muted)
                        .lineLimit(1).frame(minHeight: 44)
                        .offset(x: -drag.cancelProgress * 24)
                        .opacity(1 - Double(drag.cancelProgress) * 0.65)
                }
                .buttonStyle(AloChatPressStyle())
                .padding(.trailing, 12)
                .accessibilityLabel("Отменить запись")
                .accessibilityHint("Также можно сдвинуть палец влево")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .modifier(AloChatPanelGlass(radius: 22, role: .control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.recording.panel")
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: isLocked)
    }
}

private struct CircleRecordingOverlay: View {
    let startedAt: Date
    let ready: Bool
    @ObservedObject var recorder: ChatCircleRecorder
    let accentColor: Color
    let topChrome: CGFloat
    let bottomChrome: CGFloat
    let onSend: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        GeometryReader { geometry in
            let diameter = AloCircleRecordingLayout.diameter(viewport: geometry.size, topChrome: topChrome, bottomChrome: bottomChrome)
            let centerY = AloCircleRecordingLayout.centerY(viewport: geometry.size, diameter: diameter,
                topChrome: topChrome, bottomChrome: bottomChrome)
            ZStack {
                AloChatModalBackdrop(darkness: 0.32)
                    CircleCameraPreview(session: recorder.session, mirrored: recorder.isFrontCamera,
                                        transitioning: recorder.isSwitchingCamera)
                        .frame(width: diameter, height: diameter)
                        .background(.black)
                        .clipShape(Circle())
                        .simultaneousGesture(MagnifyGesture()
                            .onChanged { recorder.updateZoom(magnification: $0.magnification, ended: false) }
                            .onEnded { recorder.updateZoom(magnification: $0.magnification, ended: true) })
                        .accessibilityLabel("Камера кружка")
                        .accessibilityIdentifier("alo.circle.recording.camera")
                        .accessibilityHint("Сведите или разведите два пальца для изменения масштаба")
                        .overlay {
                            if ready {
                                CircleRecordingProgress(startedAt: startedAt, color: .white.opacity(0.6))
                            } else {
                                ProgressView().tint(.white)
                            }
                        }
                        .shadow(color: .black.opacity(0.3), radius: 21, y: 10)
                        .scaleEffect(appeared || reduceMotion ? 1 : 0.3)
                        .position(x: geometry.size.width / 2, y: centerY)
                        .offset(y: appeared || reduceMotion ? 0 : geometry.size.height + diameter * 0.3 - centerY)
                        .opacity(appeared ? 1 : 0)
                    HStack(spacing: 20) {
                        CircleIconButton(systemName: "camera.rotate", action: { recorder.switchCamera() })
                            .accessibilityLabel("Переключить камеру")
                            .accessibilityIdentifier("alo.circle.recording.flip")
                            .disabled(!ready || recorder.isSwitchingCamera)
                        if !recorder.isFrontCamera {
                            CircleIconButton(systemName: recorder.isTorchEnabled ? "bolt.fill" : "bolt.slash",
                                             action: { recorder.toggleTorch() })
                                .accessibilityLabel("Вспышка")
                        }
                    }
                    .position(x: geometry.size.width / 2, y: centerY + diameter / 2 + 34)
                    .opacity(appeared ? 1 : 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear {
                withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8)) {
                    appeared = true
                }
            }
        }
        .task(id: startedAt) {
            guard ready else { return }
            let remaining = max(0, 60 - Date().timeIntervalSince(startedAt))
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            onSend()
        }
    }
}

private struct CircleRecordingProgress: View {
    let startedAt: Date
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Only this ring updates once a second, not the camera view at 20 fps.
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let progress = min(1, max(0, context.date.timeIntervalSince(startedAt) / 60))
            Circle().trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 1), value: progress)
        }
        .padding(4)
        .allowsHitTesting(false)
    }
}

private struct CircleIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 46, height: 46)
                .background(Color.black.opacity(0.38))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(AloControlPressStyle())
    }
}

private struct VoicePlaybackTopBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let playback: ActiveVoicePlayback
    let onToggle: () -> Void
    let onSpeed: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
.contentTransition(.symbolEffect(.replace.downUp))
.animation(.spring(response: 0.26, dampingFraction: 0.8), value: playback.isPlaying)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(AloTheme.text)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityIdentifier("alo.voice.toggle")
            .accessibilityLabel(playback.isPlaying ? "Приостановить голосовое" : "Продолжить голосовое")
            .aloChatSwipeControl()

            VStack(alignment: .leading, spacing: 1) {
                Text(playback.title)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(AloTheme.text)
                    .lineLimit(1)
                    .accessibilityIdentifier("alo.voice.sender-title")
                Text("Голосовое сообщение")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(AloTheme.muted)
            }

            Spacer(minLength: 8)

            Button(action: onSpeed) {
                Text(speedTitle)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(AloTheme.text)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityIdentifier("alo.voice.speed")
            .aloChatSwipeControl()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityIdentifier("alo.voice.close")
            .accessibilityLabel("Остановить голосовое")
            .aloChatSwipeControl()
        }
        .padding(.horizontal, 8)
        .modifier(AloChatPanelGlass(radius: 18, role: .control))
        .animation(reduceMotion ? nil : AloPressFeedback.release, value: playback.isPlaying)
    }

    private var speedTitle: String {
        playback.speed == 1 ? "1x" : String(format: "%.1fx", playback.speed)
    }
}

private struct VoiceWaveform: View {
    var levels: [CGFloat] = []
    var activeColor: Color = AloTheme.accent

    var body: some View {
        // Recorder samples drive updates. A static draft must not keep a
        // display-rate TimelineView running or invent activity in silence.
        Canvas { context, size in
            let samples = AloVoiceWaveform.samples(levels, width: size.width)
            for (index, value) in samples.enumerated() {
                let height = max(3, size.height * value)
                let rect = CGRect(x: CGFloat(index) * 5, y: (size.height - height) / 2,
                                  width: 3, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(activeColor))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ChatComposerButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(AloTheme.muted)
                .frame(width: ChatComposerMetrics.visualSize, height: ChatComposerMetrics.visualSize)
                .modifier(AloChatGlass())
                .frame(width: ChatComposerMetrics.controlSize, height: ChatComposerMetrics.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(AloControlPressStyle())
    }
}

private struct LocalAttachmentThumb: View {
    let attachment: AloLocalAttachment
    var size: CGFloat = 74

    var body: some View {
        ZStack {
            AloTheme.surfaceRaised
            if attachment.type == "image" {
                LocalDraftPhotoPreview(attachment: attachment)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AloTheme.text)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }

    private var iconName: String {
        switch attachment.type {
        case "video": return "play.rectangle.fill"
        case "audio": return "waveform"
        case "file": return "doc.fill"
        default: return "paperclip"
        }
    }
}

private struct RecordedDraftComposerPanel: View {
    let attachment: AloLocalAttachment
    let duration: TimeInterval
    let levels: [CGFloat]
    let accentColor: Color
    let onRemove: () -> Void

    @StateObject private var playback = AloRecordedAudioPreview()
    @State private var playbackError: String?

    var body: some View {
        HStack(spacing: 12) {
            if attachment.isLocalCircleLike {
                LocalCircleDraftPreview(attachment: attachment, accentColor: accentColor)
                    .frame(width: 46, height: 46)
            } else {
                Button(action: togglePlayback) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.92))
                        Image(systemName: buttonIcon)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(accentColor)
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(AloControlPressStyle())
                .accessibilityLabel(playback.isPlaying ? "Приостановить предпросмотр" : "Прослушать запись")
                .accessibilityIdentifier("alo.recording.preview-play")
            }

            VStack(alignment: .leading, spacing: 5) {
                if attachment.isLocalVoiceLike {
                    VoiceWaveform(levels: levels, activeColor: accentColor)
                        .frame(height: 26)
                } else {
                    Text("Кружок готов к отправке")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AloTheme.text)
                }

                Text(formatTime(duration))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AloTheme.muted)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(AloTheme.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloChatPressStyle())
            .accessibilityLabel("Удалить черновик записи")
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .modifier(AloChatPanelGlass(radius: 26))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.recording.preview")
        .onDisappear { playback.stop() }
        .alert("Не удалось воспроизвести запись", isPresented: Binding(
            get: { playbackError != nil }, set: { if !$0 { playbackError = nil } }
        )) {
            Button("Ок", role: .cancel) { playbackError = nil }
        } message: {
            Text(playbackError ?? "")
        }
    }

    private var buttonIcon: String {
        if attachment.isLocalCircleLike { return "video.circle.fill" }
        return playback.isPlaying ? "pause.fill" : "play.fill"
    }

    private func togglePlayback() {
        guard attachment.isLocalVoiceLike else { return }
        Task {
            do {
                try await playback.toggle(attachment: attachment)
            } catch {
                playbackError = "Не удалось открыть аудио. Черновик сохранён — можно попробовать снова или удалить его."
            }
        }
    }

    private func formatTime(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.isFinite ? value.rounded() : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct LocalCircleDraftPreview: View {
    let attachment: AloLocalAttachment
    let accentColor: Color

    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var isPlaying = false

    var body: some View {
        Button(action: togglePlayback) {
            ZStack {
                Circle().fill(AloTheme.background)
                if let player {
                    CircleVideoPlayerView(player: player)
                        .clipShape(Circle())
                        .allowsHitTesting(false)
                }
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
.contentTransition(.symbolEffect(.replace.downUp))
.animation(.spring(response: 0.26, dampingFraction: 0.8), value: isPlaying)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 28, height: 28)
                    .background(Color.black.opacity(0.42))
                    .clipShape(Circle())
            }
            .clipShape(Circle())
            .overlay(Circle().stroke(accentColor.opacity(0.72), lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(AloChatPressStyle())
        .accessibilityLabel(isPlaying ? "Приостановить предпросмотр кружка" : "Посмотреть кружок")
        .accessibilityIdentifier("alo.circle.draft-play")
        .onAppear(perform: preparePlayer)
        .onDisappear(perform: cleanup)
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            isPlaying = false
            player?.seek(to: .zero)
        }
    }

    private func preparePlayer() {
        guard player == nil else { return }
        if let url = attachment.localPlaybackURL {
            let prepared = AloSecureMediaStore.shared.makePlayer(url: url)
            prepared.seek(to: CMTime(seconds: 0.08, preferredTimescale: 600))
            player = prepared
            return
        }
        let fileExtension = attachment.mime.contains("quicktime") ? "mov" : "mp4"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-circle-preview-\(attachment.id.uuidString).\(fileExtension)")
        do {
            try attachment.data.write(to: url, options: .atomic)
            temporaryURL = url
            let prepared = AVPlayer(url: url)
            prepared.seek(to: CMTime(seconds: 0.08, preferredTimescale: 600))
            player = prepared
        } catch {
            temporaryURL = nil
        }
    }

    private func togglePlayback() {
        preparePlayer()
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func cleanup() {
        player?.pause()
        player = nil
        isPlaying = false
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        temporaryURL = nil
    }
}

private struct MessageReadStatusChecks: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isRead: Bool
    var isSending = false
    var isScheduled = false

    var body: some View {
        Group {
            if isScheduled {
                Image(systemName: "clock")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .frame(width: 13, height: 13)
            } else if isSending {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color.white.opacity(0.78))
                    .scaleEffect(0.48)
                    .frame(width: 13, height: 13)
            } else {
                AloMessageCheckmark(readProgress: isRead ? 1 : 0)
                .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Color.white.opacity(isRead ? 0.86 : 0.68))
                .frame(width: 15, height: 11)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isRead)
            }
        }
        .frame(width: 15, height: 13)
        .accessibilityLabel(
            isScheduled ? "Отправится позже" : (isSending ? "Отправляется" : (isRead ? "Прочитано" : "Отправлено"))
        )
    }
}

/// A full tick and an offset partial tick, not two overlapping SF Symbols.
private struct AloMessageCheckmark: Shape {
    var readProgress: CGFloat

    var animatableData: CGFloat {
        get { readProgress }
        set { readProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = (1 - readProgress) * 2.5
        path.move(to: CGPoint(x: x + 0.8, y: 5.8))
        path.addLine(to: CGPoint(x: x + 3.4, y: 8.4))
        path.addLine(to: CGPoint(x: x + 9.5, y: 1.7))
        if readProgress > 0.001 {
            path.move(to: CGPoint(x: 8.2, y: 8.4))
            path.addLine(to: CGPoint(x: 8.2 + 6.1 * readProgress, y: 8.4 - 6.7 * readProgress))
        }
        return path
    }
}

private let aloMessageReactionEmojis = [
    "❤️", "🔥", "😂", "😮", "👏", "👍", "👎", "🥰",
    "😁", "🤩", "🤔", "🤯", "😱", "😢", "😭", "😡", "🎉",
    "💯", "🤝", "🙏", "👌", "😎", "👀", "🤗", "🫡",
    "🤪", "😴", "🤓", "👻", "🎃", "💔", "⚡", "🏆"
]

private struct ChatPinnedMessageBar: View {
    let message: AloChatMessage
    let count: Int
    let onTap: () -> Void

    private var preview: String {
        if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return chatPreviewText(message)
        }
        if !message.attachmentName.isEmpty { return chatPreviewText(message) }
        if !message.attachments.isEmpty { return "Вложение" }
        return "Сообщение"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AloTheme.accent)
                    .frame(width: 3, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(count > 1 ? "Закреплённые сообщения · \(count)" : "Закреплённое сообщение")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AloTheme.accent)
                    Text(preview)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AloTheme.text.opacity(0.88))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 45)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(AloTheme.surface.opacity(0.80))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(AloTheme.border.opacity(0.8), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.98))
        .accessibilityLabel("Перейти к закреплённому сообщению")
    }
}

private struct MessageActionOverlay: View {
    var visualAccessibility = AloVisualAccessibility()
    private var reduceMotion: Bool { visualAccessibility.reduceMotion }
    @EnvironmentObject private var app: AloAppModel
    let message: AloChatMessage
    let replyToMessage: AloChatMessage?
    let targetFrame: CGRect?
    let pollState: AloPollViewState?
    let appearance: AloChatAppearance
    let canEditMessage: Bool
    let canPinMessage: Bool
    let isPinned: Bool
    let onCopy: () -> Void
    let onForward: () -> Void
    let onTranslate: () -> Void
    let onTranscribe: () -> Void
    let onReply: () -> Void
    let onPin: () -> Void
    let onEdit: () -> Void
    let onReact: (String) -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onReschedule: () -> Void
    let onViewScheduled: () -> Void
    let onCancelScheduled: () -> Void
    let onClosePoll: () -> Void
    let onCancel: () -> Void

    @State private var showsAllReactions = false
    @State private var measuredPreviewHeight: CGFloat?
    @State private var isPresented = false
    @State private var showsClosePollConfirmation = false
    @State private var isDismissing = false
    @State private var inspectedEmoji: String?
    @State private var measuredMenuHeight: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let layout = overlayLayout(in: proxy.size, origin: origin)

            ZStack(alignment: .topLeading) {
                AloChatModalBackdrop(darkness: 0.40)
                .opacity(isPresented ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { dismiss(onCancel) }

                if let inspectedEmoji {
                    reactionInspection(inspectedEmoji)
                        .frame(width: min(proxy.size.width - 24, 320))
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.64)
                        .opacity(isPresented ? 1 : 0)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                } else {
                if showsReactions {
                    reactionsPanel
                        .frame(width: layout.reactionFrame.width, height: layout.reactionFrame.height)
                        .scaleEffect(isPresented || reduceMotion ? 1 : 0.01, anchor: isMine ? .bottomTrailing : .bottomLeading)
                        .opacity(isPresented ? 1 : 0)
                        .position(x: layout.reactionFrame.midX, y: layout.reactionFrame.midY)
                        .zIndex(3)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.98).combined(with: .opacity))
                }

                ChatMessageRow(message: message, replyToMessage: replyToMessage, pollState: pollState,
                    appearance: appearance, isMine: isMine, showsSenderAttribution: false,
                    isPending: false, isSelected: false, selectionMode: false, previewOnly: true,
                    availableWidth: layout.previewFrame.width + 48,
                    onTap: {}, onReact: { _ in }, onPollVote: { _ in }, canClosePoll: false,
                    onClosePoll: {}, onOpenMediaGallery: { _, _ in }, onOpenDiscussion: {}, onLongPress: { _ in })
                    .frame(width: layout.previewFrame.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: MessageActionPreviewHeightKey.self, value: content.size.height)
                        }
                    }
                    .scaleEffect(min(1, layout.previewFrame.height / max(1, measuredPreviewHeight ?? sourceFrame(in: proxy.size).height)),
                                 anchor: isMine ? .topTrailing : .topLeading)
                    .frame(
                        width: layout.previewFrame.width,
                        height: layout.previewFrame.height,
                        alignment: isMine ? .topTrailing : .topLeading
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 10)
                    .offset(y: isPresented || reduceMotion ? 0 : sourceFrame(in: proxy.size, origin: origin).midY - layout.previewFrame.midY)
                    .opacity(isPresented ? 1 : 0)
                    .position(x: layout.previewFrame.midX, y: layout.previewFrame.midY)
                    .zIndex(2)
                    .transition(.opacity)

                if !showsAllReactions {
                actionMenu
                    .frame(
                        width: layout.menuFrame.width,
                        height: layout.menuFrame.height,
                        alignment: .topLeading
                    )
                    .scaleEffect(isPresented || reduceMotion ? 1 : 0.01, anchor: isMine ? .topTrailing : .topLeading)
                    .offset(y: isPresented || reduceMotion ? 0 : -12)
                    .opacity(isPresented ? 1 : 0)
                    .position(x: layout.menuFrame.midX, y: layout.menuFrame.midY)
                    .zIndex(1)
                    .transition(.opacity)
                }
                }
            }
            .allowsHitTesting(!isDismissing)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.16) : AloContextMotion.enter) {
                    isPresented = true
                }
            }
            .onPreferenceChange(MessageActionPreviewHeightKey.self) { height in
                if height > 0, abs(height - (measuredPreviewHeight ?? 0)) > 0.5 {
                    measuredPreviewHeight = height
                }
            }
        }
    }

    private var reactionsPanel: some View {
        let selectedEmoji = message.reactions.first(where: \.reactedByMe)?.emoji
        return AloContextReactionPicker(expanded: showsAllReactions, selectedEmoji: selectedEmoji,
            accent: appearance.outgoingColor, onExpand: {
                AloHaptics.selection()
                withAnimation(reduceMotion ? .easeOut(duration: 0.16) : AloContextMotion.enter) {
                    showsAllReactions.toggle()
                }
            }, onSelect: { emoji in dismiss { onReact(emoji) } }, onInspect: { emoji in
                withAnimation(reduceMotion ? .easeOut(duration: 0.16) : AloContextMotion.enter) { inspectedEmoji = emoji }
            })
    }

    private func reactionInspection(_ emoji: String) -> some View {
        let reaction = message.reactions.first { $0.emoji == emoji }
        return VStack(spacing: 12) {
            Text(emoji).font(.system(size: 88)).padding(.bottom, 12)
            if reaction?.reactedByMe == true, let me = app.bootstrap?.me {
                HStack(spacing: 10) {
                    AloAvatar(name: me.name, url: me.avatarUrl, size: 40, colorSeed: String(me.id))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(me.name).font(.body)
                        Text("Ваша реакция").font(.subheadline).foregroundStyle(AloTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16).modifier(AloContextMenuSurface())
            }
            HStack {
                Text(reaction.map { "Реакций: \($0.count)" } ?? "Эта реакция ещё не добавлена")
                    .font(.body).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16).modifier(AloContextMenuSurface())
            Button {
                withAnimation(AloContextMotion.exit) { inspectedEmoji = nil }
            } label: {
                Text("Назад к реакциям").frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(AloChatPressStyle())
            .accessibilityIdentifier("alo.reactions.inspection.back")
        }
        .foregroundStyle(AloTheme.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alo.reactions.inspection")
    }

    private func dismiss(_ action: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        withAnimation(AloContextMotion.exit, completionCriteria: .logicallyComplete) {
            isPresented = false
        } completion: { action() }
    }

    private var deliveryHeader: some View {
        let raw = isMine && !message.readAt.isEmpty ? message.readAt : message.createdAt
        return HStack(spacing: 12) {
            if isMine {
                AloMessageCheckmark(readProgress: message.readAt.isEmpty ? 0 : 1)
                    .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                    .frame(width: 17, height: 12).frame(width: 28)
            } else {
                Image(systemName: "clock").font(.system(size: 19, weight: .regular)).frame(width: 28)
            }
            Text("\(AloFormatters.messageDateLabel(raw).lowercased()) в \(AloFormatters.messageTime(raw))")
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(AloTheme.muted)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 44)
        .accessibilityLabel(isMine && !message.readAt.isEmpty ? "Прочитано: \(raw)" : "Отправлено: \(raw)")
    }

    private func action(_ title: String, _ symbol: String, tint: Color = AloTheme.text,
                        perform: @escaping () -> Void) -> some View {
        MessageActionButton(title: title, systemName: symbol, tint: tint) { dismiss(perform) }
    }

    private var contextDivider: some View {
        Divider().overlay(Color.white.opacity(0.12)).padding(.vertical, 6).padding(.horizontal, 16)
    }

    private var actionMenu: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                deliveryHeader
                contextDivider
                if message.isScheduled {
                    if canCopy { action("Скопировать", "doc.on.doc", perform: onCopy) }
                    action("Изменить время", "clock.arrow.circlepath", perform: onReschedule)
                    action("Все отложенные", "clock.badge", perform: onViewScheduled)
                    action("Отменить отправку", "trash", tint: .red, perform: onCancelScheduled)
                } else {
                    if message.chatCallLogMeta == nil {
                        action("Ответить", "arrowshape.turn.up.left", perform: onReply)
                    }
                    if canCopy { action("Скопировать", "doc.on.doc", perform: onCopy) }
                    if canEdit { action("Изменить", "square.and.pencil", perform: onEdit) }
                    if canPinMessage {
                        action(isPinned ? "Открепить" : "Закрепить", isPinned ? "pin.slash" : "pin", perform: onPin)
                    }
                    if message.chatCallLogMeta == nil, message.selfDestructSeconds <= 0 {
                        action("Переслать", "arrowshape.turn.up.right", perform: onForward)
                    }
                    if canTranslate { action("Перевести", "translate", perform: onTranslate) }
                    if canTranscribe { action("Расшифровать голосовое", "waveform.badge.magnifyingglass", perform: onTranscribe) }
                    if canClosePoll {
                        MessageActionButton(title: "Завершить опрос", systemName: "chart.bar.xaxis") {
                            showsClosePollConfirmation = true
                        }.accessibilityIdentifier("alo.poll.close")
                    }
                    action("Удалить", "trash", tint: .red, perform: onDelete)
                    contextDivider
                    action("Выбрать", "checkmark.circle", perform: onSelect)
                }
            }
            .padding(.vertical, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(height - (measuredMenuHeight ?? 0)) > 0.5 { measuredMenuHeight = height }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("alo.message.actions")
        .modifier(AloContextMenuSurface())
        .alert("Завершить опрос?", isPresented: $showsClosePollConfirmation) {
            Button("Завершить", role: .destructive) { dismiss(onClosePoll) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("После завершения участники больше не смогут голосовать.")
        }
    }

    private func sourceFrame(in size: CGSize, origin: CGPoint = .zero) -> CGRect {
        targetFrame?.offsetBy(dx: -origin.x, dy: -origin.y)
            ?? CGRect(x: size.width / 2 - 80, y: size.height / 2 - 28, width: 160, height: 56)
    }

    private func overlayLayout(in size: CGSize, origin: CGPoint) -> AloChatContextLayout {
        AloChatContextLayout.make(size: size, source: sourceFrame(in: size, origin: origin),
            previewHeight: measuredPreviewHeight ?? sourceFrame(in: size, origin: origin).height,
            menuHeight: measuredMenuHeight ?? estimatedActionMenuHeight,
            reactionHeight: showsReactions ? (showsAllReactions ? min(340, size.height * 0.40) : 46) : 0,
            outgoing: isMine, expanded: showsAllReactions)
    }

    private var estimatedActionMenuHeight: CGFloat {
        if message.isScheduled {
            let rows = canCopy ? 4 : 3
            return CGFloat(rows) * 46 + 69
        }
        var rows = 2
        if canCopy {
            rows += 1
        }
        if canEdit {
            rows += 1
        }
        if message.chatCallLogMeta == nil {
            rows += message.selfDestructSeconds <= 0 ? 2 : 1
        }
        if canTranslate {
            rows += 1
        }
        if canTranscribe {
            rows += 1
        }
        if canPinMessage {
            rows += 1
        }
        if canClosePoll { rows += 1 }
        return CGFloat(rows) * 46 + 82
    }

    private var canCopy: Bool {
        message.selfDestructSeconds <= 0 && AloPollCodec.decode(message.body) == nil &&
            !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isMine: Bool {
        message.senderId == app.bootstrap?.me.id
    }

    private var canClosePoll: Bool {
        isMine && pollState != nil && pollState?.isClosed == false
    }

    private var showsReactions: Bool {
        !message.isScheduled && message.chatCallLogMeta == nil
    }

    private var previewText: String {
        if let callLogMeta = message.chatCallLogMeta {
            return callLogMeta.menuTitle(isMine: message.senderId == app.bootstrap?.me.id)
        }
        if !message.body.isEmpty {
            return chatPreviewText(message.body)
        }
        let attachments = !message.attachments.isEmpty ? message.attachments : legacyAttachments
        if attachments.contains(where: \.isVoiceLike) {
            return "Голосовое сообщение"
        }
        if attachments.contains(where: \.isCircleLike) {
            return "Кружок"
        }
        let imageCount = attachments.filter { $0.type == "image" || $0.url.lowercased().hasImageExtension }.count
        let videoCount = attachments.filter { $0.type == "video" || $0.url.lowercased().hasVideoExtension }.count
        if imageCount > 0 && videoCount > 0 {
            return "\(imageCount) фото, \(videoCount) видео"
        }
        if imageCount > 1 {
            return "\(imageCount) фото"
        }
        if videoCount > 1 {
            return "\(videoCount) видео"
        }
        if imageCount == 1 {
            return "Фотография"
        }
        if videoCount == 1 {
            return "Видео"
        }
        if !attachments.isEmpty {
            return attachments.first?.name.ifBlank("Файл") ?? "Файл"
        }
        if message.forwardFrom != nil {
            return "Пересланное сообщение"
        }
        return "Без текста"
    }

    private var canEdit: Bool {
        canEditMessage
    }

    private var canTranslate: Bool {
        !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            AloPollCodec.decode(message.body) == nil &&
            message.chatCallLogMeta == nil
    }

    private var canTranscribe: Bool {
        let attachments = !message.attachments.isEmpty ? message.attachments : legacyAttachments
        return attachments.contains(where: \.isVoiceLike)
    }

    private var legacyAttachments: [AloMessageAttachment] {
        guard !message.attachmentUrl.isEmpty else { return [] }
        return [
            AloMessageAttachment([
                "type": message.attachmentType,
                "url": message.attachmentUrl,
                "name": message.attachmentName
            ])
        ]
    }
}

private struct MessageActionPreviewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct MessageActionButton: View {
    let title: String
    let systemName: String
    var tint: Color = AloTheme.text
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button {
            AloHaptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 28, height: 22)
                Text(title)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .foregroundStyle(disabled ? AloTheme.muted.opacity(0.45) : tint)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(Color.white.opacity(0.001))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(AloContextActionPressStyle())
        .disabled(disabled)
    }
}

private struct ChatPollComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var allowsMultipleAnswers = false
    @State private var isQuiz = false
    @State private var correctOptionIndex = 0
    @State private var quizExplanation = ""
    @State private var isAnonymous = true
    @State private var allowsRevoting = true
    @State private var shouldSchedule = false
    @State private var scheduledDate = Date().addingTimeInterval(60 * 60)
    @State private var closeAfterSeconds = 0

    let onCreate: (AloPollDefinition, String) -> Void

    @FocusState private var focusedField: Field?
    @State private var showsDiscardConfirmation = false

    private enum Field: Hashable {
        case question, option(Int), explanation
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AloChatMetrics.sectionGap) {
                    pollSection("ВОПРОС") {
                        TextField("Задайте вопрос", text: $question, axis: .vertical)
                            .font(.body)
                            .lineLimit(1...5)
                            .padding(16)
                            .frame(minHeight: 52)
                            .focused($focusedField, equals: .question)
                            .accessibilityLabel("Вопрос опроса")
                            .accessibilityIdentifier("alo.poll.question")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        pollSection("ВАРИАНТЫ ОТВЕТА") {
                            VStack(spacing: 0) {
                                ForEach(options.indices, id: \.self) { index in
                                    HStack(spacing: 0) {
                                        if isQuiz {
                                            Button { correctOptionIndex = index } label: {
                                                Image(systemName: correctOptionIndex == index ? "checkmark.circle.fill" : "circle")
                                                    .font(.system(size: 22))
                                                    .foregroundStyle(correctOptionIndex == index ? AloTheme.accent : AloTheme.muted)
                                                    .frame(width: 44, height: 44)
                                            }
                                            .buttonStyle(AloChatPressStyle())
                                            .accessibilityLabel("Правильный ответ: вариант \(index + 1)")
                                            .accessibilityAddTraits(correctOptionIndex == index ? .isSelected : [])
                                        }
                                        TextField("Вариант \(index + 1)", text: $options[index])
                                            .font(.body)
                                            .focused($focusedField, equals: .option(index))
                                            .submitLabel(index == options.count - 1 ? .done : .next)
                                            .onSubmit {
                                                focusedField = index + 1 < options.count ? .option(index + 1) : nil
                                            }
                                            .padding(.vertical, 14)
                                            .accessibilityIdentifier("alo.poll.option.\(index)")
                                        if options.count > 2 {
                                            Button { removeOption(at: index) } label: {
                                                Image(systemName: "minus.circle.fill")
                                                    .font(.system(size: 20))
                                                    .foregroundStyle(AloTheme.destructive)
                                                    .frame(width: 44, height: 44)
                                            }
                                            .buttonStyle(AloChatPressStyle())
                                            .accessibilityLabel("Удалить вариант \(index + 1)")
                                        }
                                    }
                                    .padding(.leading, isQuiz ? 4 : 16)
                                    .padding(.trailing, options.count > 2 ? 4 : 16)
                                    .frame(minHeight: 52)
                                    if index < options.count - 1 || options.count < 10 {
                                        Divider().overlay(AloTheme.separator).padding(.horizontal, 16)
                                    }
                                }
                                if options.count < 10 {
                                    Button {
                                        options.append("")
                                        focusedField = .option(options.count - 1)
                                    } label: {
                                        Label("Добавить вариант", systemImage: "plus.circle")
                                            .font(.body)
                                            .foregroundStyle(AloTheme.accent)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 16)
                                            .frame(minHeight: 52)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(AloChatPressStyle())
                                }
                            }
                        }
                        if hasDuplicateOptions {
                            Text("Варианты ответа должны отличаться.")
                                .font(.footnote)
                                .foregroundStyle(AloTheme.destructive)
                                .padding(.horizontal, 16)
                        } else {
                            Text(isQuiz ? "Отметьте один правильный ответ." : "Можно добавить до 10 вариантов.")
                                .font(.footnote)
                                .foregroundStyle(AloTheme.muted)
                                .padding(.horizontal, 16)
                        }
                    }

                    pollSection("НАСТРОЙКИ") {
                        VStack(spacing: 0) {
                            pollToggle("Анонимное голосование", isOn: $isAnonymous)
                            pollDivider
                            pollToggle("Несколько ответов", isOn: $allowsMultipleAnswers, disabled: isQuiz)
                            pollDivider
                            pollToggle("Режим викторины", isOn: $isQuiz)
                        }
                    }

                    if isQuiz {
                        pollSection("ПОЯСНЕНИЕ") {
                            TextField("Будет показано после ответа", text: $quizExplanation, axis: .vertical)
                                .font(.body)
                                .lineLimit(1...5)
                                .focused($focusedField, equals: .explanation)
                                .padding(16)
                                .onChange(of: quizExplanation) { _, value in
                                    if value.count > 500 { quizExplanation = String(value.prefix(500)) }
                                }
                        }
                    }

                    pollSection("ДОПОЛНИТЕЛЬНО") {
                        VStack(spacing: 0) {
                            pollToggle("Можно переголосовать", isOn: $allowsRevoting, disabled: isQuiz)
                            pollDivider
                            pollToggle("Отправить позже", isOn: $shouldSchedule)
                            if shouldSchedule {
                                pollDivider
                                DatePicker("Дата и время", selection: $scheduledDate,
                                           in: Date().addingTimeInterval(60)...Date().addingTimeInterval(365 * 24 * 60 * 60),
                                           displayedComponents: [.date, .hourAndMinute])
                                    .datePickerStyle(.compact)
                                    .padding(16)
                            }
                            pollDivider
                            HStack {
                                Text("Автозакрытие").font(.body)
                                Spacer(minLength: 8)
                                Picker("Автозакрытие", selection: $closeAfterSeconds) {
                                    Text("Не закрывать").tag(0)
                                    Text("Через 1 час").tag(3600)
                                    Text("Через 6 часов").tag(21600)
                                    Text("Через 1 день").tag(86400)
                                    Text("Через 3 дня").tag(259200)
                                    Text("Через неделю").tag(604800)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .font(.callout)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                        }
                    }
                }
                .padding(.horizontal, AloChatMetrics.inset)
                .padding(.vertical, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AloTheme.background.ignoresSafeArea())
            .foregroundStyle(AloTheme.text)
            .navigationTitle("Новый опрос")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        if hasDraft { showsDiscardConfirmation = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") { createPoll() }
                        .fontWeight(.semibold)
                        .disabled(!canCreate)
                        .accessibilityIdentifier("alo.poll.create")
                }
            }
            .confirmationDialog("Удалить черновик опроса?", isPresented: $showsDiscardConfirmation, titleVisibility: .visible) {
                Button("Удалить черновик", role: .destructive) { dismiss() }
                Button("Продолжить редактирование", role: .cancel) {}
            }
            .onChange(of: isQuiz) { _, enabled in
                if enabled {
                    allowsMultipleAnswers = false
                    allowsRevoting = false
                } else {
                    quizExplanation = ""
                }
            }
        }
        .tint(AloTheme.accent)
        .presentationDetents([.large])
        .interactiveDismissDisabled(hasDraft)
    }

    private func pollSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(AloTheme.muted)
                .padding(.leading, 16)
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: AloChatMetrics.cardRadius))
        }
    }

    private var pollDivider: some View {
        Divider().overlay(AloTheme.separator).padding(.horizontal, 16)
    }

    private func pollToggle(_ title: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        Toggle(title, isOn: isOn)
            .font(.body)
            .disabled(disabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 52)
    }

    private var hasDraft: Bool {
        !question.isEmpty || options.contains { !$0.isEmpty } || !quizExplanation.isEmpty
    }

    private var hasDuplicateOptions: Bool {
        let filled = normalizedOptions.filter { !$0.isEmpty }.map { $0.lowercased() }
        return Set(filled).count != filled.count
    }

    private func removeOption(at index: Int) {
        guard options.count > 2, options.indices.contains(index) else { return }
        focusedField = nil
        options.remove(at: index)
        if index < correctOptionIndex {
            correctOptionIndex -= 1
        } else if index == correctOptionIndex {
            correctOptionIndex = min(index, options.count - 1)
        }
    }

    private var normalizedOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            normalizedOptions.count >= 2 &&
            normalizedOptions.allSatisfy { !$0.isEmpty } &&
            Set(normalizedOptions.map { $0.lowercased() }).count == normalizedOptions.count
    }

    private func createPoll() {
        guard canCreate else { return }
        let pollOptions = normalizedOptions.enumerated().map {
            AloPollOption(id: "o\($0.offset + 1)", text: $0.element)
        }
        let correctIds: Set<String> = isQuiz && pollOptions.indices.contains(correctOptionIndex)
            ? [pollOptions[correctOptionIndex].id]
            : []
        let scheduledAt = shouldSchedule
            ? ISO8601DateFormatter().string(from: max(scheduledDate, Date().addingTimeInterval(60)))
            : ""
        let closeStartDate = shouldSchedule ? max(scheduledDate, Date().addingTimeInterval(60)) : Date()
        let closesAt = closeAfterSeconds > 0
            ? ISO8601DateFormatter().string(from: closeStartDate.addingTimeInterval(TimeInterval(closeAfterSeconds)))
            : ""
        onCreate(
            AloPollDefinition(
                id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                options: pollOptions,
                allowsMultipleAnswers: allowsMultipleAnswers,
                isQuiz: isQuiz,
                correctOptionIds: correctIds,
                explanation: isQuiz
                    ? quizExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
                    : "",
                isAnonymous: isAnonymous,
                allowsRevoting: allowsRevoting,
                closesAt: closesAt
            ),
            scheduledAt
        )
        dismiss()
    }
}

private struct ChatRecurringScheduleDraft {
    let rule: AloRecurringScheduleRule
    let startsAt: Date
    let occurrences: Int
    let silent: Bool
}

/// Recurring delivery is intentionally a server-backed action: a local timer
/// would silently stop when the app is terminated and would not be acceptable
/// for a message that the sender expects to be delivered.
private struct ChatRecurringScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: AloRecurringScheduleRule = .daily
    @State private var startsAt = Date().addingTimeInterval(60 * 60)
    @State private var occurrences = 7
    @State private var silent = false

    let onSchedule: (ChatRecurringScheduleDraft) -> Void

    private var allowedRange: ClosedRange<Date> {
        Date().addingTimeInterval(60)...Date().addingTimeInterval(366 * 24 * 60 * 60)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Текст сообщения будет отправляться по расписанию. Вложения и пересылки для повтора пока недоступны.")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(AloTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 0) {
                        ForEach(AloRecurringScheduleRule.allCases) { candidate in
                            Button {
                                rule = candidate
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: candidate.systemImage)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(rule == candidate ? AloTheme.accent : AloTheme.muted)
                                        .frame(width: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.title)
                                            .font(.system(size: 16, weight: .semibold))
                                        Text(candidate.subtitle)
                                            .font(.system(size: 13))
                                            .foregroundStyle(AloTheme.muted)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: rule == candidate ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(rule == candidate ? AloTheme.accent : AloTheme.muted)
                                }
                                .foregroundStyle(AloTheme.text)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 62)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if candidate != AloRecurringScheduleRule.allCases.last! {
                                Divider().overlay(AloTheme.border).padding(.leading, 56)
                            }
                        }
                    }
                    .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(spacing: 0) {
                        DatePicker(
                            "Первое отправление",
                            selection: $startsAt,
                            in: allowedRange,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.compact)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 54)

                        Divider().overlay(AloTheme.border).padding(.leading, 14)

                        Picker("Количество отправлений", selection: $occurrences) {
                            Text("7 отправлений").tag(7)
                            Text("14 отправлений").tag(14)
                            Text("30 отправлений").tag(30)
                            Text("52 отправления").tag(52)
                        }
                        .tint(AloTheme.accent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 54)

                        Divider().overlay(AloTheme.border).padding(.leading, 14)

                        Toggle("Без звука", isOn: $silent)
                            .tint(AloTheme.accent)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 54)
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(18)
            }
            .background(AloTheme.background.ignoresSafeArea())
            .foregroundStyle(AloTheme.text)
            .navigationTitle("Повторная отправка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запланировать") {
                        onSchedule(
                            ChatRecurringScheduleDraft(
                                rule: rule,
                                startsAt: max(startsAt, Date().addingTimeInterval(60)),
                                occurrences: occurrences,
                                silent: silent
                            )
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private enum ChatComposerContentTab: String, CaseIterable, Identifiable {
    case emoji = "Эмодзи"
    case stickers = "Стикеры"
    case gifs = "GIF"

    var id: String { rawValue }
}

private struct ChatComposerContentPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AloAppModel
    @State private var tab: ChatComposerContentTab = .emoji
    @State private var emojiQuery = ""
    @State private var stickerQuery = ""
    @State private var stickerPacks = [AloStickerPack]()
    @State private var selectedStickerPack: AloStickerPack?
    @State private var selectedStickerItems = [AloStickerItem]()
    @State private var stickerSearchResults = [AloStickerItem]()
    @State private var isLoadingStickers = false
    @State private var stickerError = ""
    @State private var gifQuery = ""
    @State private var gifResults = [AloGIFItem]()
    @State private var isLoadingCatalogGIFs = false
    @State private var gifCatalogError = ""
    @State private var gifItem: PhotosPickerItem?
    @State private var isImportingLocalGIF = false
    @State private var localGIFError = ""

    let onEmoji: (String) -> Void
    let onSticker: (AloStickerItem) -> Void
    let onGIF: (AloGIFItem) -> Void
    let onLocalGIFAttachment: (AloLocalAttachment) -> Void

    init(
        _ onEmoji: @escaping (String) -> Void,
        onSticker: @escaping (AloStickerItem) -> Void,
        onGIF: @escaping (AloGIFItem) -> Void,
        onLocalGIFAttachment: @escaping (AloLocalAttachment) -> Void
    ) {
        self.onEmoji = onEmoji
        self.onSticker = onSticker
        self.onGIF = onGIF
        self.onLocalGIFAttachment = onLocalGIFAttachment
    }

    private let emojiEntries: [ChatEmojiEntry] = [
        .init("😀", "улыбка радость"), .init("😂", "смех слёзы"), .init("😍", "любовь глаза"),
        .init("👍", "лайк да"), .init("❤️", "сердце любовь"), .init("🔥", "огонь горячо"),
        .init("🎉", "праздник конфетти"), .init("👀", "глаза смотрю"), .init("🤝", "рукопожатие договор"),
        .init("🙏", "спасибо просьба"), .init("😎", "очки круто"), .init("😢", "грусть слёзы"),
        .init("🙂", "улыбка"), .init("😊", "счастье"), .init("😄", "смех улыбка"),
        .init("😁", "улыбка зубы"), .init("🥹", "слёзы"), .init("🤔", "думаю вопрос"),
        .init("🫡", "салют понял"), .init("🤗", "объятия"), .init("😴", "сон"),
        .init("😡", "злость"), .init("😭", "плачу"), .init("🤩", "звёзды"),
        .init("🤯", "взрыв мозг"), .init("🙌", "ура руки"), .init("👏", "аплодисменты"),
        .init("👋", "привет пока"), .init("💪", "сила"), .init("🌿", "листья природа"),
        .init("🌸", "цветок"), .init("🌙", "луна ночь"), .init("☀️", "солнце день"),
        .init("⚡", "молния"), .init("🍀", "удача"), .init("🎵", "музыка"),
        .init("🎮", "игра"), .init("📸", "фото камера"), .init("💬", "сообщение"),
        .init("🎁", "подарок"), .init("🚀", "ракета"), .init("🏆", "победа"),
        .init("💎", "бриллиант"), .init("🎨", "рисование"), .init("☕️", "кофе"),
        .init("🍕", "пицца еда"), .init("🐈", "кот кошка")
    ]

    private var normalizedEmojiQuery: String {
        emojiQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredEmojiEntries: [ChatEmojiEntry] {
        guard !normalizedEmojiQuery.isEmpty else { return emojiEntries }
        return emojiEntries.filter {
            $0.emoji.contains(normalizedEmojiQuery) || $0.keywords.localizedCaseInsensitiveContains(normalizedEmojiQuery)
        }
    }

    private var displayedStickers: [AloStickerItem] {
        stickerQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? selectedStickerItems
            : stickerSearchResults
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Тип контента", selection: $tab) {
                    ForEach(ChatComposerContentTab.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                ScrollView(showsIndicators: false) {
                    switch tab {
                    case .emoji:
                        emojiGrid
                    case .stickers:
                        stickerGrid
                    case .gifs:
                        gifPicker
                    }
                }
            }
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle(tab.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .alert("Не удалось добавить GIF", isPresented: Binding(
            get: { !localGIFError.isEmpty },
            set: { if !$0 { localGIFError = "" } }
        )) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(localGIFError)
        }
        .onChange(of: gifItem) { _, item in
            guard let item else { return }
            Task { await importGIF(item) }
        }
        .onChange(of: tab) { _, value in
            switch value {
            case .stickers:
                Task { await loadStickersIfNeeded() }
            case .gifs:
                Task { await loadTrendingGIFsIfNeeded() }
            case .emoji:
                break
            }
        }
        .task { await loadStickersIfNeeded() }
        .presentationDetents([.medium, .large])
    }

    private var emojiGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Поиск emoji", text: $emojiQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            if filteredEmojiEntries.isEmpty {
                Text("Ничего не найдено")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(AloTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                emojiEntryGrid(filteredEmojiEntries)
            }
        }
        .padding(18)
    }

    private var stickerGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("Поиск по установленным наборам", text: $stickerQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await searchStickers() } }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Button {
                    Task { await searchStickers() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AloTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.90))
                .disabled(isLoadingStickers)
            }

            if !stickerPacks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(stickerPacks) { pack in
                            Button {
                                Task { await selectStickerPack(pack) }
                            } label: {
                                Text(pack.title.ifBlank(pack.shortName).ifBlank("Набор"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(selectedStickerPack?.id == pack.id ? AloTheme.background : AloTheme.text)
                                    .padding(.horizontal, 12)
                                    .frame(height: 34)
                                    .background(
                                        selectedStickerPack?.id == pack.id ? AloTheme.accent : AloTheme.surface,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.94))
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }

            if let selectedStickerPack, !selectedStickerPack.installed {
                Button {
                    Task { await installStickerPack(selectedStickerPack) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Добавить «\(selectedStickerPack.title.ifBlank(selectedStickerPack.shortName))»")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(AloTheme.accent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    .background(AloTheme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.98))
                .disabled(isLoadingStickers)
            }

            if isLoadingStickers && displayedStickers.isEmpty {
                ProgressView("Загружаем наборы…")
                    .tint(AloTheme.accent)
                    .foregroundStyle(AloTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if !stickerError.isEmpty && stickerPacks.isEmpty {
                catalogUnavailable(text: stickerError, symbol: "face.dashed") {
                    Task { await loadStickers(force: true) }
                }
            } else if stickerPacks.isEmpty {
                catalogUnavailable(
                    text: "На сервере пока нет доступных наборов. Когда администратор добавит набор, он появится здесь без обновления приложения.",
                    symbol: "square.stack.3d.up"
                ) {
                    Task { await loadStickers(force: true) }
                }
            } else if displayedStickers.isEmpty {
                Text(stickerQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "В этом наборе пока нет стикеров."
                     : "По вашему запросу ничего не найдено в установленных наборах.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(AloTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                stickerTileGrid(displayedStickers)
            }
        }
        .padding(18)
    }

    private var gifPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("Поиск GIF", text: $gifQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await searchGIFs() } }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Button {
                    Task { await searchGIFs() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AloTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.90))
                .disabled(isLoadingCatalogGIFs)
            }

            if isLoadingCatalogGIFs && gifResults.isEmpty {
                ProgressView("Ищем GIF…")
                    .tint(AloTheme.accent)
                    .foregroundStyle(AloTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else if !gifCatalogError.isEmpty {
                catalogUnavailable(text: gifCatalogError, symbol: "sparkles.rectangle.stack") {
                    Task { await searchGIFs() }
                }
            } else if gifResults.isEmpty {
                Text(gifQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Введите запрос или дождитесь подборки GIF."
                     : "По этому запросу GIF не найдено.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(AloTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                gifTileGrid(gifResults)
            }

            Divider().overlay(AloTheme.border)

            Text("GIF из файлов")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AloTheme.text)
            Text("Можно отправить свой GIF до 20 МБ. Он попадёт во вложения сообщения и будет зашифрован так же, как фото.")
                .font(.system(size: 13.5))
                .foregroundStyle(AloTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            PhotosPicker(selection: $gifItem, matching: .images) {
                HStack(spacing: 10) {
                    if isImportingLocalGIF {
                        ProgressView().tint(AloTheme.accent)
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 18, weight: .bold))
                    }
                    Text(isImportingLocalGIF ? "Добавляем GIF…" : "Выбрать GIF")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(AloTheme.text)
                .padding(.horizontal, 14)
                .frame(height: 54)
                .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AloTheme.border, lineWidth: 1))
            }
            .disabled(isImportingLocalGIF)
        }
        .padding(18)
    }

    private func emojiEntryGrid(_ values: [ChatEmojiEntry]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
            ForEach(values) { value in
                Button {
                    AloHaptics.selection()
                    onEmoji(value.emoji)
                } label: {
                    Text(value.emoji)
                        .font(.system(size: 27))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AloTheme.border.opacity(0.72), lineWidth: 1))
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.88))
                .accessibilityLabel("Вставить \(value.emoji)")
            }
        }
    }

    private func stickerTileGrid(_ stickers: [AloStickerItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(stickers) { sticker in
                Button {
                    AloHaptics.selection()
                    onSticker(sticker)
                    dismiss()
                } label: {
                    stickerArtwork(sticker)
                        .frame(maxWidth: .infinity)
                        .frame(height: 86)
                        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AloTheme.border.opacity(0.64), lineWidth: 1))
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.91))
                .accessibilityLabel("Отправить стикер \(sticker.alt.ifBlank(sticker.emoji).ifBlank("из набора"))")
            }
        }
    }

    private func gifTileGrid(_ gifs: [AloGIFItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            ForEach(gifs) { gif in
                Button {
                    AloHaptics.selection()
                    onGIF(gif)
                    dismiss()
                } label: {
                    gifArtwork(gif)
                        .frame(maxWidth: .infinity)
                        .frame(height: 128)
                        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AloTheme.border.opacity(0.64), lineWidth: 1))
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.95))
                .accessibilityLabel("Отправить GIF \(gif.title.ifBlank("из каталога"))")
            }
        }
    }

    @ViewBuilder
    private func stickerArtwork(_ sticker: AloStickerItem) -> some View {
        if let url = app.api.absoluteURL(sticker.thumbnailURL.ifBlank(sticker.assetURL)) {
            AloAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit().padding(7)
                case .failure:
                    Text(sticker.emoji.ifBlank("◌")).font(.system(size: 34))
                default:
                    ProgressView().tint(AloTheme.accent)
                }
            }
        } else {
            Text(sticker.emoji.ifBlank("◌")).font(.system(size: 34))
        }
    }

    @ViewBuilder
    private func gifArtwork(_ gif: AloGIFItem) -> some View {
        if let url = app.api.absoluteURL(gif.previewURL.ifBlank(gif.url)) {
            AloAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill().clipped()
                case .failure:
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                default:
                    ProgressView().tint(AloTheme.accent)
                }
            }
        } else {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
        }
    }

    private func catalogUnavailable(
        text: String,
        symbol: String,
        retry: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
            Text(text)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(AloTheme.muted)
                .multilineTextAlignment(.center)
            Button("Повторить", action: retry)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AloTheme.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 156)
        .padding(.horizontal, 18)
    }

    @MainActor
    private func loadStickersIfNeeded() async {
        guard stickerPacks.isEmpty, !isLoadingStickers else { return }
        await loadStickers(force: false)
    }

    @MainActor
    private func loadStickers(force: Bool) async {
        guard !isLoadingStickers else { return }
        if !force, !stickerPacks.isEmpty { return }
        isLoadingStickers = true
        stickerError = ""
        defer { isLoadingStickers = false }
        do {
            let installed = try await app.api.loadInstalledStickerPacks()
            let packs = installed.isEmpty ? try await app.api.loadStickerPacks() : installed
            stickerPacks = packs
            guard let first = packs.first else {
                selectedStickerPack = nil
                selectedStickerItems = []
                return
            }
            await selectStickerPack(first)
        } catch let error as AloAPIError {
            stickerError = error.message
        } catch {
            stickerError = "Не удалось получить наборы стикеров."
        }
    }

    @MainActor
    private func selectStickerPack(_ pack: AloStickerPack) async {
        guard selectedStickerPack?.id != pack.id || selectedStickerItems.isEmpty else { return }
        selectedStickerPack = pack
        selectedStickerItems = []
        stickerSearchResults = []
        isLoadingStickers = true
        stickerError = ""
        defer { isLoadingStickers = false }
        do {
            let fullPack = try await app.api.loadStickerPack(id: pack.id)
            selectedStickerPack = fullPack
            selectedStickerItems = fullPack.items
            if let index = stickerPacks.firstIndex(where: { $0.id == fullPack.id }) {
                stickerPacks[index] = fullPack
            }
        } catch let error as AloAPIError {
            stickerError = error.message
        } catch {
            stickerError = "Не удалось открыть набор стикеров."
        }
    }

    @MainActor
    private func installStickerPack(_ pack: AloStickerPack) async {
        guard !isLoadingStickers else { return }
        isLoadingStickers = true
        stickerError = ""
        defer { isLoadingStickers = false }
        do {
            _ = try await app.api.installStickerPack(id: pack.id)
            let fullPack = try await app.api.loadStickerPack(id: pack.id)
            selectedStickerPack = fullPack
            selectedStickerItems = fullPack.items
            if let index = stickerPacks.firstIndex(where: { $0.id == fullPack.id }) {
                stickerPacks[index] = fullPack
            } else {
                stickerPacks.insert(fullPack, at: 0)
            }
        } catch let error as AloAPIError {
            stickerError = error.message
        } catch {
            stickerError = "Не удалось добавить набор стикеров."
        }
    }

    @MainActor
    private func searchStickers() async {
        let query = stickerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            stickerSearchResults = []
            return
        }
        guard !isLoadingStickers else { return }
        isLoadingStickers = true
        stickerError = ""
        defer { isLoadingStickers = false }
        do {
            stickerSearchResults = try await app.api.searchStickers(query: query)
        } catch let error as AloAPIError {
            stickerError = error.message
        } catch {
            stickerError = "Не удалось найти стикеры."
        }
    }

    @MainActor
    private func loadTrendingGIFsIfNeeded() async {
        guard gifResults.isEmpty, !isLoadingCatalogGIFs, gifCatalogError.isEmpty else { return }
        await searchGIFs()
    }

    @MainActor
    private func searchGIFs() async {
        guard !isLoadingCatalogGIFs else { return }
        isLoadingCatalogGIFs = true
        gifCatalogError = ""
        defer { isLoadingCatalogGIFs = false }
        do {
            let query = gifQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let page = query.isEmpty
                ? try await app.api.loadTrendingGIFs()
                : try await app.api.searchGIFs(query: query)
            gifResults = page.items
        } catch let error as AloAPIError {
            gifCatalogError = error.message
        } catch {
            gifCatalogError = "Не удалось получить GIF."
        }
    }

    @MainActor
    private func importGIF(_ item: PhotosPickerItem) async {
        isImportingLocalGIF = true
        defer {
            isImportingLocalGIF = false
            gifItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            localGIFError = "Не удалось прочитать выбранный файл."
            return
        }
        guard data.count <= 20 * 1_024 * 1_024 else {
            localGIFError = "GIF должен быть не больше 20 МБ."
            return
        }
        let contentType = item.supportedContentTypes.first
        let isGIF = contentType?.conforms(to: .gif) == true || data.starts(with: Data("GIF".utf8))
        guard isGIF else {
            localGIFError = "Выберите анимированный GIF из галереи."
            return
        }
        onLocalGIFAttachment(
            AloLocalAttachment(
                data: data,
                mime: "image/gif",
                type: "image",
                name: "gif-\(Int(Date().timeIntervalSince1970)).gif"
            )
        )
        dismiss()
    }
}

private struct ChatEmojiEntry: Identifiable {
    let emoji: String
    let keywords: String

    init(_ emoji: String, _ keywords: String) {
        self.emoji = emoji
        self.keywords = keywords
    }

    var id: String { emoji }
}

private struct ChatMessageAssistantRequest: Identifiable {
    enum Kind {
        case translation
        case transcription

        var title: String {
            switch self {
            case .translation: return "Перевод"
            case .transcription: return "Расшифровка"
            }
        }
    }

    let id = UUID()
    let message: AloChatMessage
    let kind: Kind
}

private struct ChatMessageAssistantSheet: View {
    enum Phase: Equatable {
        case ready
        case processing
        case result(String)
        case unavailable(String)
    }

    @Environment(\.dismiss) private var dismiss
    let request: ChatMessageAssistantRequest
    let onTranslate: (String) async throws -> AloMessageTranslation
    let onTranscribe: (String) async throws -> AloVoiceTranscription
    @State private var preferredLanguage = "ru"
    @State private var phase: Phase = .ready

    private var actionTitle: String {
        request.kind == .translation ? "Перевести" : "Расшифровать"
    }

    private var sourcePreview: String {
        if request.kind == .translation { return request.message.body }
        return "Голосовое сообщение будет расшифровано после вашего явного подтверждения."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(request.kind == .translation ? "Перевод сообщения" : "Расшифровка голосового", systemImage: request.kind == .translation ? "translate" : "waveform.badge.magnifyingglass")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AloTheme.text)
                        Text(sourcePreview)
                            .font(.system(size: 15))
                            .foregroundStyle(AloTheme.muted)
                            .lineLimit(request.kind == .translation ? 6 : 3)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.kind == .translation ? "Перевести на" : "Язык речи")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(AloTheme.muted)
                        Picker("Язык", selection: $preferredLanguage) {
                            Text("Русский").tag("ru")
                            Text("English").tag("en")
                            Text("Deutsch").tag("de")
                            Text("Español").tag("es")
                        }
                        .pickerStyle(.segmented)
                    }

                    phaseView
                }
                .padding(18)
            }
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle(request.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .processing ? "" : "Закрыть") { dismiss() }
                        .disabled(phase == .processing)
                }
                if phase == .ready {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(actionTitle) { perform() }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var phaseView: some View {
        switch phase {
        case .ready:
            Text("Данные будут отправлены на обработку только после нажатия «\(actionTitle)». Для защищённых чатов сервер должен поддерживать этот запрос.")
                .font(.system(size: 14))
                .foregroundStyle(AloTheme.muted)
        case .processing:
            HStack(spacing: 10) {
                ProgressView().tint(AloTheme.accent)
                Text("Обрабатываем…")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(AloTheme.text)
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        case let .result(text):
            VStack(alignment: .leading, spacing: 8) {
                Label("Готово", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AloTheme.accent)
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(AloTheme.text)
                    .textSelection(.enabled)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        case let .unavailable(message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Пока недоступно", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(AloTheme.muted)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func perform() {
        phase = .processing
        Task {
            do {
                let text: String
                switch request.kind {
                case .translation:
                    text = try await onTranslate(preferredLanguage).text
                case .transcription:
                    text = try await onTranscribe(preferredLanguage).text
                }
                phase = .result(text)
            } catch let error as AloAPIError where error.status == 404 || error.status == 501 {
                phase = .unavailable("Сервер Alo ещё не поддерживает эту операцию. Контракт клиента уже подготовлен; повторите после обновления сервера.")
            } catch let error as AloAPIError {
                phase = .unavailable(error.message)
            } catch {
                phase = .unavailable("Не удалось выполнить запрос. Проверьте соединение и попробуйте ещё раз.")
            }
        }
    }
}

private enum ChatAttachmentTab: String, CaseIterable {
    case gallery, file, location, contact, poll, audio

    var title: String {
        switch self {
        case .gallery: return "Галерея"
        case .file: return "Файл"
        case .location: return "Геопозиция"
        case .contact: return "Контакт"
        case .poll: return "Опрос"
        case .audio: return "Звук"
        }
    }

    var icon: String {
        switch self {
        case .gallery: return "photo.on.rectangle"
        case .file: return "doc"
        case .location: return "mappin.circle"
        case .contact: return "person.crop.circle"
        case .poll: return "chart.bar"
        case .audio: return "play.circle"
        }
    }
}

/// Keep the remote Photos controller in its own hosting boundary. Otherwise
/// sheet presentation preferences can attach to Photos instead of our panel.
private struct EmbeddedChatPhotoPicker: UIViewControllerRepresentable {
    @Binding var selection: [PhotosPickerItem]
    let limit: Int

    private var picker: some View {
        PhotosPicker(selection: $selection, maxSelectionCount: limit,
                     selectionBehavior: .continuousAndOrdered, matching: .any(of: [.images, .videos])) {
            Label("Фотографии и видео", systemImage: "photo")
        }
        .photosPickerStyle(.inline)
        .photosPickerAccessoryVisibility(.hidden, edges: [.top, .bottom])
        .photosPickerDisabledCapabilities([.selectionActions, .stagingArea])
        .environment(\.colorScheme, .dark)
    }

    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: AnyView(picker))
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.view.accessibilityIdentifier = "alo.attachments.photos"
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<AnyView>, context: Context) {
        controller.rootView = AnyView(picker)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIHostingController<AnyView>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

private struct ChatAttachmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace
    @Binding var attachments: [AloLocalAttachment]
    @Binding var caption: String
    @Binding var selfDestructSeconds: Int
    let canAttachMedia: Bool
    let canCreatePoll: Bool
    let contacts: [AloEntitySummary]
    let onShareContact: (AloEntitySummary) -> Void
    let onShareStaticLocation: (CLLocationCoordinate2D) -> Void
    let onShareLiveLocation: (CLLocationCoordinate2D, Date) -> Void
    let onCreatePoll: () -> Void
    @State private var selectedTab: ChatAttachmentTab = .gallery
    @State private var importError: String?
    @State private var galleryItems = [PhotosPickerItem]()
    @State private var pickedItems = [PhotosPickerItem]()
    @State private var isFileImporterPresented = false
    @State private var isContactPickerPresented = false
    @State private var isLocationPickerPresented = false
    @State private var isLoading = false

    private var tabs: [ChatAttachmentTab] {
        ChatAttachmentTab.allCases.filter { tab in
            switch tab {
            case .gallery, .file, .audio: return canAttachMedia
            case .contact: return !contacts.isEmpty
            case .poll: return canCreatePoll
            case .location: return true
            }
        }
    }

    var body: some View {
        GeometryReader { sheetGeometry in
        VStack(spacing: 0) {
            HStack {
                AloChatCircleButton(systemImage: "xmark", label: "Закрыть вложения") { dismiss() }
                    .accessibilityIdentifier("alo.attachments.close")
                    .disabled(isLoading)
                Spacer(minLength: 8)
                Text(selectedTab.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { finishSelection() } label: {
                    Group {
                        if isLoading {
                            ProgressView().tint(AloTheme.accent)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 21, weight: .semibold))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .modifier(AloChatGlass())
                }
                .buttonStyle(AloChatPressStyle())
                .foregroundStyle(attachments.isEmpty && galleryItems.isEmpty ? AloTheme.muted : AloTheme.accent)
                .disabled((attachments.isEmpty && galleryItems.isEmpty) || isLoading)
                .accessibilityLabel("Добавить выбранные вложения")
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)

            if selectedTab == .gallery {
                GeometryReader { geometry in
                EmbeddedChatPhotoPicker(
                    selection: $galleryItems,
                    limit: max(1, 10 - mediaAttachments.count)
                )
                .disabled(isLoading || mediaAttachments.count >= 10)
                .frame(width: geometry.size.width - 20, height: geometry.size.height)
                // Rounded and inset like the rest of the sheet; the system picker has square corners.
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if let importError {
                    Text(importError).font(.footnote).foregroundStyle(AloTheme.destructive).padding(16)
                }
                if !galleryItems.isEmpty {
                    TextField("Добавить подпись", text: $caption, axis: .vertical)
                        .font(.body)
                        .lineLimit(1...4)
                        .padding(12)
                        .background(AloTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 20))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    attachmentSource
                        .disabled(isLoading)
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().tint(AloTheme.accent)
                            Text("Подготавливаем вложения…").font(.subheadline)
                        }
                        .foregroundStyle(AloTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    if !mediaAttachments.isEmpty {
                        Text("ВЫБРАНО: \(mediaAttachments.count)")
                            .font(.footnote)
                            .foregroundStyle(AloTheme.muted)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                            ForEach(mediaAttachments) { attachment in
                                GeometryReader { geometry in
                                    LocalAttachmentThumb(attachment: attachment, size: geometry.size.width)
                                }
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            attachments.removeAll { $0.id == attachment.id }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .frame(width: 26, height: 26)
                                                .background(.black.opacity(0.7), in: Circle())
                                                .frame(width: 44, height: 44)
                                        }
                                        .buttonStyle(AloChatPressStyle())
                                        .accessibilityLabel("Убрать \(attachment.name)")
                                    }
                            }
                        }
                        TextField("Добавить подпись", text: $caption, axis: .vertical)
                            .font(.body)
                            .lineLimit(1...5)
                            .padding(14)
                            .frame(minHeight: 48)
                            .background(AloTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityLabel("Подпись к вложениям")
                    }
                    if let importError {
                        Text(importError)
                            .font(.footnote)
                            .foregroundStyle(AloTheme.destructive)
                            .accessibilityLabel("Ошибка вложения: " + importError)
                    }
                    if !attachments.isEmpty {
                        Menu {
                            selfDestructOption(seconds: 0, title: "Не удалять")
                            selfDestructOption(seconds: 1, title: "Один просмотр")
                            selfDestructOption(seconds: 5, title: "Через 5 секунд")
                            selfDestructOption(seconds: 10, title: "Через 10 секунд")
                            selfDestructOption(seconds: 30, title: "Через 30 секунд")
                            selfDestructOption(seconds: 60, title: "Через 1 минуту")
                        } label: {
                            sourceRow(selfDestructLabel, icon: selfDestructSeconds > 0 ? "timer" : "infinity")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabs, id: \.self) { tab in
                            Button {
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                                    selectedTab = tab
                                    proxy.scrollTo(tab, anchor: .center)
                                }
                                switch tab {
                                case .location: isLocationPickerPresented = true
                                case .contact: isContactPickerPresented = true
                                case .poll:
                                    onCreatePoll()
                                    dismiss()
                                default: break
                                }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 25, weight: .regular))
                                        .frame(height: 28)
                                    Text(tab.title).font(.caption)
                                }
                                .foregroundStyle(selectedTab == tab ? AloTheme.accent : AloTheme.text)
                                .padding(.horizontal, 12)
                                .frame(minWidth: 64, minHeight: 64)
                                .background {
                                    if selectedTab == tab {
                                        Capsule().fill(AloTheme.surfaceInteractive)
                                            .matchedGeometryEffect(id: "attachment-tab", in: selectionNamespace)
                                    }
                                }
                                .contentShape(Capsule())
                            }
                            .id(tab)
                            .buttonStyle(AloChatPressStyle())
                            .accessibilityIdentifier("alo.attachments.\(tab.rawValue)")
                            .disabled(isLoading)
                            .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                        }
                    }
                    .padding(4)
                }
                .modifier(AloChatGlass())
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .frame(width: sheetGeometry.size.width, height: sheetGeometry.size.height, alignment: .top)
        }
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.surface.ignoresSafeArea())
        .presentationDetents([.fraction(0.66), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .interactiveDismissDisabled(isLoading)
        .onAppear {
            if !tabs.contains(selectedTab), let first = tabs.first { selectedTab = first }
        }
        .onChange(of: pickedItems) { _, newItems in
            guard !newItems.isEmpty, !isLoading else { return }
            Task {
                await loadPickedItems(newItems)
                pickedItems = []
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: selectedTab == .audio ? [.audio] : [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                guard !urls.isEmpty else { return }
                Task { await loadFiles(urls) }
            case .failure:
                importError = "Не удалось открыть файл. Выберите его ещё раз."
            }
        }
        .sheet(isPresented: $isContactPickerPresented) {
            ChatContactPickerSheet(contacts: contacts) { contact in
                dismiss()
                onShareContact(contact)
            }
        }
        .sheet(isPresented: $isLocationPickerPresented) {
            ChatLocationPickerSheet { delivery in
                dismiss()
                switch delivery {
                case let .staticLocation(coordinate): onShareStaticLocation(coordinate)
                case let .liveLocation(coordinate, expiresAt): onShareLiveLocation(coordinate, expiresAt)
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentSource: some View {
        switch selectedTab {
        case .gallery, .file:
            VStack(spacing: 0) {
                PhotosPicker(selection: $pickedItems, maxSelectionCount: max(1, 10 - mediaAttachments.count), matching: .any(of: [.images, .videos])) {
                    sourceRow("Выбрать из Галереи", icon: "photo")
                }
                .buttonStyle(AloChatPressStyle())
                .disabled(isLoading || mediaAttachments.count >= 10)
                if selectedTab == .file {
                    Divider().padding(.leading, 54).padding(.trailing, 16)
                    Button { isFileImporterPresented = true } label: {
                        sourceRow("Выбрать из файлов", icon: "folder")
                    }
                    .buttonStyle(AloChatPressStyle())
                }
            }
            .background(AloTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 24))
            if selectedTab == .gallery, mediaAttachments.isEmpty {
                Text("Выберите фотографии и видео из медиатеки. Здесь появятся только выбранные вами файлы.")
                    .font(.subheadline)
                    .foregroundStyle(AloTheme.muted)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        case .audio:
            Button { isFileImporterPresented = true } label: {
                sourceRow("Выбрать аудиофайл", icon: "folder")
            }
            .buttonStyle(AloChatPressStyle())
            .background(AloTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 24))
        case .location:
            Button { isLocationPickerPresented = true } label: {
                sourceRow("Выбрать место на карте", icon: "map")
            }
            .buttonStyle(AloChatPressStyle())
        case .contact:
            Button { isContactPickerPresented = true } label: {
                sourceRow("Выбрать контакт", icon: "person.crop.circle")
            }
            .buttonStyle(AloChatPressStyle())
        case .poll:
            EmptyView()
        }
    }

    private func sourceRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .regular))
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title).font(.body)
            Spacer(minLength: 4)
        }
        .foregroundStyle(AloTheme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private var mediaAttachments: [AloLocalAttachment] {
        attachments.filter { !$0.isRecordedDraft }
    }

    private func finishSelection() {
        guard !isLoading else { return }
        guard !galleryItems.isEmpty else {
            dismiss()
            return
        }
        Task {
            await loadPickedItems(galleryItems)
            galleryItems = []
            if importError == nil { dismiss() }
        }
    }

    private var selfDestructLabel: String {
        switch selfDestructSeconds {
        case 1: return "Один просмотр"
        case 5: return "Исчезнет через 5 секунд"
        case 10: return "Исчезнет через 10 секунд"
        case 30: return "Исчезнет через 30 секунд"
        case 60: return "Исчезнет через 1 минуту"
        default: return "Хранить в чате"
        }
    }

    private func selfDestructOption(seconds: Int, title: String) -> some View {
        Button {
            selfDestructSeconds = seconds
        } label: {
            if selfDestructSeconds == seconds {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        isLoading = true
        importError = nil
        var next = [AloLocalAttachment]()
        for (index, item) in items.enumerated() {
            let contentType = item.supportedContentTypes.first
            let isVideo = contentType?.conforms(to: .movie) == true || contentType?.conforms(to: .video) == true
            let mime = contentType?.preferredMIMEType ?? (isVideo ? "video/mp4" : "image/jpeg")
            let ext = contentType?.preferredFilenameExtension ?? (isVideo ? "mp4" : "jpg")
            let name = "media-\(index + 1).\(ext)"

            if let pickedFile = try? await item.loadTransferable(type: AloPickedMediaFile.self) {
                let encryptedAttachment = await makeEncryptedDraftAttachment(
                    sourceURL: pickedFile.url,
                    mime: mime,
                    type: isVideo ? "video" : "image",
                    name: name
                )
                try? FileManager.default.removeItem(at: pickedFile.url)
                if let encryptedAttachment {
                    next.append(encryptedAttachment)
                }
                continue
            }

            // A few Photos providers do not expose a file representation.
            // Keep their previous small-media fallback, but never read an
            // arbitrary large asset into RAM.
            guard let data = try? await item.loadTransferable(type: Data.self),
                  data.count <= 32 * 1_024 * 1_024 else { continue }
            if let draft = try? await Task.detached(priority: .utility, operation: {
                try AloDraftAttachmentStore.makePickedMedia(data: data, mime: mime,
                    type: isVideo ? "video" : "image", name: name)
            }).value { next.append(draft) }
        }
        let recordedDrafts = attachments.filter(\.isRecordedDraft)
        let existingMedia = attachments.filter { !$0.isRecordedDraft }
        attachments = recordedDrafts + Array((existingMedia + next).prefix(10))
        if next.count < items.count {
            importError = "Некоторые фото или видео не удалось загрузить. Попробуйте выбрать их ещё раз."
        } else if existingMedia.count + next.count > 10 {
            importError = "В одно сообщение можно добавить не более 10 вложений."
        }
        isLoading = false
    }

    private func loadFiles(_ urls: [URL]) async {
        isLoading = true
        importError = nil
        defer { isLoading = false }

        var next = [AloLocalAttachment]()
        for url in urls {
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .nameKey, .fileSizeKey])
            let contentType = values?.contentType
            let mime = contentType?.preferredMIMEType ?? "application/octet-stream"
            let type: String
            if contentType?.conforms(to: .image) == true {
                type = "image"
            } else if contentType?.conforms(to: .movie) == true || contentType?.conforms(to: .video) == true {
                type = "video"
            } else if contentType?.conforms(to: .audio) == true {
                type = "audio"
            } else {
                type = "file"
            }
            let name = values?.name?.ifBlank(url.lastPathComponent) ?? url.lastPathComponent
            let encryptedAttachment = await makeEncryptedDraftAttachment(
                sourceURL: url,
                mime: mime,
                type: type,
                name: name
            )
            guard let encryptedAttachment else { continue }
            next.append(encryptedAttachment)
        }

        let recordedDrafts = attachments.filter(\.isRecordedDraft)
        let existingMedia = attachments.filter { !$0.isRecordedDraft }
        attachments = recordedDrafts + Array((existingMedia + next).prefix(10))
        if next.count < urls.count {
            importError = "Некоторые файлы не удалось открыть. Проверьте доступ и выберите их ещё раз."
        } else if existingMedia.count + next.count > 10 {
            importError = "В одно сообщение можно добавить не более 10 вложений."
        }
    }

    private func makeEncryptedDraftAttachment(
        sourceURL: URL,
        mime: String,
        type: String,
        name: String
    ) async -> AloLocalAttachment? {
        try? await Task.detached(priority: .utility) {
            if type == "video" {
                let dimensions = await AloMediaDimensions.video(sourceURL: sourceURL)
                return try AloDraftAttachmentStore.makePickedVideo(sourceURL: sourceURL, mime: mime, name: name)
                    .withMediaDimensions(dimensions)
            }
            return try AloDraftAttachmentStore.makePickedMedia(
                sourceURL: sourceURL,
                mime: mime,
                type: type,
                name: name
            )
        }.value
    }
}

private enum ChatLocationDelivery {
    case staticLocation(CLLocationCoordinate2D)
    case liveLocation(CLLocationCoordinate2D, Date)
}

private struct ChatLocationPickerSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case staticLocation = "Точка"
        case liveLocation = "В реальном времени"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var cameraPosition = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 55.7512, longitude: 37.6184),
            span: MKCoordinateSpan(latitudeDelta: 0.13, longitudeDelta: 0.13)
        )
    )
    @State private var mode: Mode = .staticLocation
    @State private var duration = 60 * 60
    @State private var isLocating = false
    @State private var errorText = ""

    let onDeliver: (ChatLocationDelivery) -> Void

    private var expiresAt: Date {
        Date().addingTimeInterval(TimeInterval(duration))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        if let selectedCoordinate {
                            Annotation("Выбранное место", coordinate: selectedCoordinate) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 34, weight: .semibold))
                                    .foregroundStyle(AloTheme.accent)
                                    .shadow(color: Color.black.opacity(0.24), radius: 6, y: 3)
                            }
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .onTapGesture(coordinateSpace: .local) { point in
                        if let coordinate = proxy.convert(point, from: .local) {
                            selectedCoordinate = coordinate
                            AloHaptics.selection()
                        }
                    }
                }
                .frame(height: 276)
                .overlay(alignment: .bottomLeading) {
                    Text(selectedCoordinate == nil ? "Нажмите на карту, чтобы выбрать точку" : coordinateLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AloTheme.text)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Button {
                            locateCurrentPosition()
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: isLocating ? "location.fill" : "location.circle.fill")
                                    .font(.system(size: 21, weight: .semibold))
                                    .foregroundStyle(AloTheme.accent)
                                    .frame(width: 32)
                                Text(isLocating ? "Определяем место…" : "Моё текущее место")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(AloTheme.text)
                                Spacer()
                                if isLocating { ProgressView().tint(AloTheme.accent) }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 54)
                            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AloTheme.border, lineWidth: 1))
                        }
                        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.98))
                        .disabled(isLocating)

                        Picker("Режим", selection: $mode) {
                            ForEach(Mode.allCases) { value in
                                Text(value.rawValue).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)

                        if mode == .liveLocation {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Как долго показывать")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(AloTheme.muted)
                                Picker("Длительность", selection: $duration) {
                                    Text("15 минут").tag(15 * 60)
                                    Text("1 час").tag(60 * 60)
                                    Text("8 часов").tag(8 * 60 * 60)
                                }
                                .pickerStyle(.segmented)
                                Text("Старт live-сессии защищён в сообщении. Обновление начнётся после подключения live-геолокации на сервере Alo; срок — до \(AloFormatters.messageTime(ISO8601DateFormatter().string(from: expiresAt))).")
                                    .font(.system(size: 13))
                                    .foregroundStyle(AloTheme.muted)
                            }
                            .padding(14)
                            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(16)
                }
            }
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Геолокация")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .liveLocation ? "Начать" : "Отправить") {
                        guard let selectedCoordinate else { return }
                        switch mode {
                        case .staticLocation:
                            onDeliver(.staticLocation(selectedCoordinate))
                        case .liveLocation:
                            onDeliver(.liveLocation(selectedCoordinate, expiresAt))
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedCoordinate == nil)
                }
            }
        }
        .alert("Не удалось получить геолокацию", isPresented: Binding(
            get: { !errorText.isEmpty },
            set: { if !$0 { errorText = "" } }
        )) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(errorText)
        }
        .presentationDetents([.large])
    }

    private var coordinateLabel: String {
        guard let selectedCoordinate else { return "" }
        return String(format: "%.5f, %.5f", selectedCoordinate.latitude, selectedCoordinate.longitude)
    }

    @MainActor
    private func locateCurrentPosition() {
        guard !isLocating else { return }
        isLocating = true
        Task {
            defer { isLocating = false }
            do {
                let coordinate = try await AloOneShotLocationProvider.requestCurrentCoordinate()
                selectedCoordinate = coordinate
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
                    )
                )
            } catch let error as AloLocationRequestError {
                errorText = error.localizedDescription
            } catch {
                errorText = "Проверьте разрешение на геолокацию и повторите попытку."
            }
        }
    }
}

private struct ChatContactPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    let contacts: [AloEntitySummary]
    let onPick: (AloEntitySummary) -> Void

    private var filteredContacts: [AloEntitySummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return contacts }
        return contacts.filter {
            $0.name.lowercased().contains(needle) ||
                $0.username.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredContacts.isEmpty {
                    ContentUnavailableView(
                        "Контакты не найдены",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Попробуй другое имя или username."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredContacts) { contact in
                        Button {
                            onPick(contact)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                AloAvatar(
                                    name: contact.name,
                                    url: contact.avatarUrl,
                                    size: 48,
                                    colorSeed: String(contact.id)
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(contact.name)
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundStyle(AloTheme.text)
                                        if contact.verified {
                                            Image(systemName: "checkmark.seal.fill")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(AloTheme.accent)
                                        }
                                    }
                                    if !contact.username.isEmpty {
                                        Text("@\(contact.username)")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(AloTheme.muted)
                                    }
                                }
                                Spacer()
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(AloTheme.accent)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(AloTheme.surface)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AloTheme.background)
            .searchable(text: $query, prompt: "Поиск контакта")
            .navigationTitle("Отправить контакт")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ForwardTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversations: [AloConversationSummary]
    let currentPeerId: Int
    let onPick: (AloConversationSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(AloTheme.muted.opacity(0.55))
                .frame(width: 54, height: 5)
                .frame(maxWidth: .infinity)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Кому переслать")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Выбери чат, сообщение появится в поле ввода.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AloTheme.muted)
                        .frame(width: 40, height: 40)
                        .background(AloTheme.surfaceRaised)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(conversations) { conversation in
                        Button {
                            onPick(conversation)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                if conversation.peer.entityType == "saved" {
                                    SavedMessagesAvatar(size: 52)
                                } else {
                                    AloAvatar(
                                        name: conversation.peer.name,
                                        url: conversation.peer.avatarUrl,
                                        size: 52,
                                        colorSeed: String(conversation.peer.id)
                                    )
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(conversation.peer.name)
                                            .font(.system(size: 17, weight: .bold))
                                            .foregroundStyle(AloTheme.text)
                                            .lineLimit(1)
                                        if conversation.peerId == currentPeerId {
                                            Text("текущий")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(AloTheme.accent)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(AloTheme.accent.opacity(0.14))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(chatPreviewText(conversation.lastBody).ifBlank("Чат"))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AloTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(AloTheme.accent)
                            }
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                            .background(AloTheme.border)
                            .padding(.leading, 64)
                    }
                }
            }
        }
        .padding(18)
        .foregroundStyle(AloTheme.text)
        .background(AloTheme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

private struct MessageSelectionToolbar: View {
    let count: Int
    let onCancel: () -> Void
    let onForward: () -> Void
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloControlPressStyle())
            .accessibilityLabel("Отменить выделение")
            .accessibilityIdentifier("alo.selection.cancel")
            Text("Выбрано: \(count)")
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: count)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onForward) {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloControlPressStyle())
            .disabled(count == 0)
            .accessibilityLabel("Переслать выбранные сообщения")
            .accessibilityIdentifier("alo.selection.forward")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(count == 0 ? AloTheme.muted : Color(red: 1, green: 0.27, blue: 0.23))
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AloControlPressStyle())
            .disabled(count == 0)
            .accessibilityLabel("Удалить выбранные сообщения")
            .accessibilityIdentifier("alo.selection.delete")
        }
        .foregroundStyle(AloTheme.text)
        .padding(.horizontal, 6)
        .frame(height: AloInputMetrics.height + 4)
        .modifier(AloChatPanelGlass(radius: (AloInputMetrics.height + 4) / 2, role: .control))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct ForwardDraftBar: View {
    let title: String
    let onCancel: () -> Void
    var body: some View {
        AloComposerAccessory(title: title, preview: "Отправить в этот чат", symbol: "arrowshape.turn.up.right",
                             kind: .forward, onCancel: onCancel)
    }
}

private struct MentionSuggestionsBar: View {
    let members: [AloGroupMember]
    let onSelect: (AloGroupMember) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(members) { member in
                    Button {
                        onSelect(member)
                    } label: {
                        HStack(spacing: 7) {
                            AloAvatar(
                                name: member.name,
                                url: member.avatarUrl,
                                size: 26,
                                colorSeed: String(member.id)
                            )
                            VStack(alignment: .leading, spacing: 0) {
                                Text(member.name)
                                    .font(.system(size: 13, weight: .bold))
                                    .lineLimit(1)
                                Text("@\\(member.username)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AloTheme.muted)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 42)
                        .background(Capsule().fill(AloTheme.surface.opacity(0.96)))
                        .overlay(Capsule().stroke(AloTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .aloTouchBounce(pressedScale: 0.96)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct ReplyDraftBar: View {
    @EnvironmentObject private var app: AloAppModel
    let message: AloChatMessage
    let onCancel: () -> Void
    var body: some View {
        AloComposerAccessory(title: app.voicePlaybackTitle(for: message), preview: chatPreviewText(message),
                             symbol: "arrowshape.turn.up.left", kind: .reply, onCancel: onCancel)
    }
}

private struct EditDraftBar: View {
    let preview: String
    let onCancel: () -> Void
    var body: some View {
        AloComposerAccessory(title: "Редактировать сообщение", preview: preview.ifBlank("Сообщение"),
                             symbol: "square.and.pencil", kind: .edit, onCancel: onCancel)
    }
}

private struct ChatPeerInfoPanel: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let conversation: AloConversationDetail
    let messages: [AloChatMessage]
    let onClose: () -> Void
    let onOpenProfile: () -> Void
    let onAudioCall: () async -> Void
    let onVideoCall: () async -> Void
    let onOpenAppearance: () -> Void
    let onOpenMessage: (Int) -> Void

    @State private var selectedMediaTab: PeerMediaTab = .photos
    @State private var mediaPagerFrame: CGRect = .zero
    @State private var selectedGroupAvatarItem: PhotosPickerItem?
    @State private var groupAvatarCrop: AloAvatarCropRequest?
    @State private var isLeaveGroupConfirmationPresented = false
    @State private var isDeleteGroupConfirmationPresented = false
    @State private var isSearchPresented = false
    @FocusState private var searchFocused: Bool
    @State private var pendingCall: ChatCallKind?
    @State private var searchText = ""
    @State private var cachedSearchResults = [AloChatMessage]()
    @State private var mediaScrollRequest = 0
    @State private var isMuted = false
    @State private var isMuteStateKnown = false
    @State private var isMuteLoading = false
    @State private var isSafetyPresented = false
    @State private var isSafetyLoading = false
    @State private var safetyVerification: AloSafetyVerification?
    @State private var safetyError = ""
    @State private var isGroupManagementPresented = false
    @State private var profileDragOffset: CGFloat = 0
    @State private var profileViewportWidth: CGFloat = UIScreen.main.bounds.width
    @State private var profileViewportHeight: CGFloat = UIScreen.main.bounds.height
    @State private var profileDragActive = false
    @State private var profileTransitionRevision = 0
    @State private var showsCompactTitle = false
    @State private var activeMediaViewer: ChatMediaViewerState?
    @State private var suppressMediaOpenUntil = Date.distantPast

    private var isChannelConversation: Bool {
        conversation.entityType == "channel" || conversation.groupPolicy?.kind == "channel"
    }

    private var canStartChannelVideoChat: Bool {
        if conversation.groupMemberRole == "owner" { return true }
        guard conversation.groupMemberRole == "admin" else { return false }
        let rights = conversation.groupPolicy?.memberAdminRights ?? [:]
        return rights.isEmpty || rights["manageVideoChats"] == true
    }

    private var isBlockedDirectPeer: Bool {
        app.isDirectPeerBlocked(conversation)
    }


    var body: some View {
        let attachments = allAttachments
        let mediaIndex = Dictionary(uniqueKeysWithValues: PeerMediaTab.allCases.map { tab in
            (tab, attachments.filter { tab.matches($0) })
        })
        ZStack {
            AloTheme.background.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14, pinnedViews: [.sectionHeaders]) {
                        hero
                        quickActions
                        if isSearchPresented {
                            searchSection
                                .id("peer-search")
                        }
                        profileInformation
                        if conversation.kind == "group" && !isChannelConversation {
                            groupMembersSection
                        }
                        Section {
                            AloPeerMediaPager(selection: $selectedMediaTab, width: max(1, profileViewportWidth - 28), minimumHeight: max(260, profileViewportHeight - 124), onDragState: { dragging in
                                suppressMediaOpenUntil = Date().addingTimeInterval(dragging ? 60 : 0.4)
                            }) { tab in
                                mediaContent(for: tab, attachments: mediaIndex[tab] ?? [])
                            }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mediaPagerFrame = $0 }
                        } header: {
                            mediaTabs
                                .padding(.vertical, 6)
                                .background(AloTheme.background)
                                .id("peer-media")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 26)
                }
                .coordinateSpace(name: "peer-scroll")
                .accessibilityIdentifier("alo.peer.scroll")
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: isSearchPresented) { _, shown in
                    guard shown else { return }
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1)) {
                        proxy.scrollTo("peer-search", anchor: .top)
                    }
                }
                .onChange(of: mediaScrollRequest) { _, _ in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 1)) {
                        proxy.scrollTo("peer-media", anchor: .top)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                AloChatCircleButton(systemImage: "chevron.left", label: "Назад в чат", action: dismissProfile)
                    .accessibilityIdentifier("alo.peer.back")
                VStack(spacing: 2) {
                    Text(conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(peerPresenceLabel)
                        .font(.caption)
                        .foregroundStyle(peerPresenceIsActive ? AloTheme.accent : AloTheme.muted)
                        .lineLimit(1)
                }
                    .frame(maxWidth: .infinity)
                    .opacity(showsCompactTitle ? 1 : 0)
                    .accessibilityHidden(!showsCompactTitle)
                    .accessibilityIdentifier("alo.peer.compact-title")
                moreMenu(compact: true)
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                // Let the hero move naturally under a transparent header.
                // Only a scrolled, compact title earns a material surface.
                if showsCompactTitle {
                    if reduceTransparency {
                        AloTheme.background.opacity(0.94).ignoresSafeArea(edges: .top)
                    } else {
                        Rectangle().fill(.regularMaterial)
                            .overlay(AloTheme.background.opacity(0.34))
                            .ignoresSafeArea(edges: .top)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsCompactTitle)
        }
        .fullScreenCover(item: $activeMediaViewer) { viewer in
            ChatMediaViewer(state: viewer, onDismiss: { activeMediaViewer = nil })
                .environmentObject(app)
        }
        .task(id: "\(conversation.kind):\(conversation.roomId):\(conversation.peerId)") {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") {
                isMuteStateKnown = true
                return
            }
            #endif
            isMuteLoading = true
            if let muted = try? await app.api.chatMuteState(conversation: conversation) {
                isMuted = muted
                isMuteStateKnown = true
            }
            isMuteLoading = false
        }
        .sheet(isPresented: $isSafetyPresented) {
            ChatSafetyNumberSheet(
                verification: safetyVerification,
                isLoading: isSafetyLoading,
                errorMessage: safetyError,
                onToggleVerified: { verified in
                    guard let current = safetyVerification else { return }
                    app.api.setSafetyVerification(
                        peerId: current.peerId,
                        digest: current.digest,
                        verified: verified
                    )
                    safetyVerification = AloSafetyVerification(
                        peerId: current.peerId,
                        decimalCode: current.decimalCode,
                        qrPayload: current.qrPayload,
                        digest: current.digest,
                        localFingerprint: current.localFingerprint,
                        peerDevices: current.peerDevices,
                        isVerified: verified
                    )
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isGroupManagementPresented) {
            GroupManagementSheet(conversation: conversation, onDelete: {
                isGroupManagementPresented = false
                // Ask once the sheet is gone, so the dialog has a screen to sit on.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { isDeleteGroupConfirmationPresented = true }
            })
                .environmentObject(app)
        }
        .onChange(of: selectedGroupAvatarItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                selectedGroupAvatarItem = nil
                guard let data, let image = await AloAvatarImage.decoded(from: data) else {
                    app.errorMessage = "Не удалось открыть это фото. Выберите другое."
                    return
                }
                groupAvatarCrop = AloAvatarCropRequest(image: image)
            }
        }
        .fullScreenCover(item: $groupAvatarCrop) { request in
            AloAvatarCropView(image: request.image, onCancel: { groupAvatarCrop = nil }) { jpeg in
                groupAvatarCrop = nil
                app.updateGroupAvatar(conversation: conversation, data: jpeg)
            }
        }
        .confirmationDialog(
            isChannelConversation ? "Покинуть канал?" : "Покинуть группу?",
            isPresented: $isLeaveGroupConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(isChannelConversation ? "Покинуть канал" : "Покинуть", role: .destructive) {
                app.leaveGroupChat(conversation)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(leaveConfirmationMessage)
        }
        .confirmationDialog(
            isChannelConversation ? "Удалить канал?" : "Удалить группу?",
            isPresented: $isDeleteGroupConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(isChannelConversation ? "Удалить канал" : "Удалить группу", role: .destructive) {
                app.deleteGroupChat(conversation)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(isChannelConversation
                ? "Канал, публикации и список подписчиков будут удалены для всех."
                : "Группа, сообщения и список участников будут удалены для всех.")
        }
        .offset(x: max(0, profileDragOffset))
        .simultaneousGesture(profileBackSwipeGesture)
        .background {
            GeometryReader { proxy in
                Color.clear
                .onAppear {
                    profileViewportWidth = max(proxy.size.width, 1)
                    profileViewportHeight = max(proxy.size.height, 1)
                }
                .onChange(of: proxy.size.width) { _, width in
                    profileViewportWidth = max(width, 1)
                }
                .onChange(of: proxy.size.height) { _, height in
                    profileViewportHeight = max(height, 1)
                }
            }
        }
    }

    private var profileBackSwipeGesture: some Gesture {
        // Telegram accepts an intentional rightward return from the body of a
        // profile as well as from the edge. Lock the axis before translating so
        // vertical scrolling and a tap on a control remain unaffected.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard activeMediaViewer == nil else { return }
                if !profileDragActive {
                    // On the media pages a rightward swipe turns back a page; only the first page lets it close the profile.
                    if selectedMediaTab != .photos && mediaPagerFrame.contains(value.startLocation) { return }
                    guard value.startLocation.x < profileViewportWidth - 28,
                          value.translation.width > 0,
                          abs(value.translation.width) > abs(value.translation.height) * 1.3 else { return }
                    profileTransitionRevision += 1
                    profileDragActive = true
                }
                updateProfileSwipe(value.translation.width)
            }
            .onEnded { value in
                endProfileSwipe(max(0, value.translation.width), value.velocity.width)
            }
    }

    private var leaveConfirmationMessage: String {
        if isChannelConversation {
            if conversation.groupMemberRole == "owner" {
                return "Если в канале есть другие подписчики, права владельца будут переданы автоматически. Если подписчиков нет, канал удалится."
            }
            return conversation.groupPolicy?.joinPolicy == "public"
                ? "Вы сможете снова подписаться на публичный канал."
                : "Чтобы вернуться в закрытый канал, снова понадобится ссылка-приглашение."
        }
        return conversation.groupMemberRole == "owner"
            ? "Если в группе есть участники, владелец будет передан следующему участнику. Если участников нет, группа удалится."
            : "Вы сможете вернуться только если вас добавят снова."
    }

    private var peerPresenceLabel: String {
        switch app.connectionState {
        case .updating, .unavailable:
            return "Обновление…"
        case .connected:
            return conversation.online ? "в сети" : conversation.subtitle
        }
    }

    private var peerPresenceIsActive: Bool {
        if case .connected = app.connectionState { return conversation.online }
        return true
    }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 8) {
                heroAvatar
                HStack(spacing: 6) {
                    Text(conversation.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(AloTheme.text)
                        .lineLimit(1)
                        .onGeometryChange(for: Bool.self) { proxy in
                            proxy.frame(in: .named("peer-scroll")).maxY <= 0
                        } action: { hidden in
                            showsCompactTitle = hidden
                        }
                }
                Text(peerPresenceLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(peerPresenceIsActive ? AloTheme.accent : AloTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
    }

    private func updateProfileSwipe(_ translation: CGFloat) {
        guard profileDragActive else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            profileDragOffset = min(profileViewportWidth, max(0, translation))
        }
    }

    private func endProfileSwipe(_ translation: CGFloat, _ velocity: CGFloat) {
        guard profileDragActive else { return }
        profileDragActive = false
        let shouldClose = velocity > -300 && AloInteractiveDismissPolicy.shouldDismiss(
            translation: translation, velocity: velocity, width: profileViewportWidth
        )
        settleProfileSwipe(shouldClose: shouldClose, velocity: velocity)
    }

    private func dismissProfile() {
        guard !profileDragActive else { return }
        settleProfileSwipe(shouldClose: true, velocity: 1_100)
    }

    private func settleProfileSwipe(shouldClose: Bool, velocity: CGFloat) {
        profileTransitionRevision += 1
        let revision = profileTransitionRevision
        let target = shouldClose ? profileViewportWidth : 0
        let remaining = abs(target - profileDragOffset)
        let duration = min(0.28, max(0.15, Double(remaining / max(velocity, 850))))
        withAnimation(
            reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: duration),
            completionCriteria: .logicallyComplete
        ) {
            profileDragOffset = target
        } completion: {
            guard shouldClose, profileTransitionRevision == revision else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                onClose()
            }
        }
    }

    @ViewBuilder
    private var heroAvatar: some View {
        if conversation.entityType == "saved" {
            SavedMessagesAvatar(size: 96)
                .shadow(color: AloTheme.accent.opacity(0.20), radius: 16, y: 8)
        } else if conversation.canManageGroup {
            PhotosPicker(selection: $selectedGroupAvatarItem, matching: .images) {
                AloAvatar(
                    name: conversation.title,
                    url: conversation.avatarUrl,
                    size: 108,
                    colorSeed: String(conversation.peerId)
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(AloTheme.accent)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AloTheme.background, lineWidth: 3))
                }
            }
            .buttonStyle(.plain)
        } else {
            AloAvatar(
                name: conversation.title,
                url: conversation.avatarUrl,
                size: 108,
                colorSeed: String(conversation.peerId)
            )
        }
    }

    private var quickActions: some View {
        HStack(alignment: .top, spacing: 8) {
            if conversation.entityType == "saved" {
                PeerCompactActionButton(title: "Поиск", systemName: "magnifyingglass", action: toggleSearch)
                    .accessibilityIdentifier("alo.peer.action.search")
                PeerCompactActionButton(title: "Медиа", systemName: "paperclip", action: scrollToMedia)
                PeerCompactActionButton(title: "Оформление", systemName: "paintpalette", action: onOpenAppearance)
            } else {
                if conversation.kind == "group" {
                    // Telegram's group and channel header: video chat for those who can start it, mute,
                    // search, leave, more. Deleting lives in Управление, never on this page.
                    if canStartChannelVideoChat {
                        PeerCompactActionButton(title: "Видеочат", systemName: "waveform", isLoading: pendingCall == .video, action: { beginCall(.video) })
                            .disabled(pendingCall != nil)
                    }
                    PeerCompactActionButton(
                        title: isMuted ? "Со звуком" : "Звук",
                        systemName: isMuted ? "bell" : "bell.slash",
                        isLoading: isMuteLoading,
                        action: toggleMute
                    )
                    .disabled(isMuteLoading)
                    PeerCompactActionButton(title: "Поиск", systemName: "magnifyingglass", action: toggleSearch)
                        .accessibilityIdentifier("alo.peer.action.search")
                    // A channel's owner cannot leave it, only delete it; a group's owner may leave.
                    if !(isChannelConversation && conversation.groupMemberRole == "owner") {
                        PeerCompactActionButton(
                            title: "Покинуть",
                            systemName: "rectangle.portrait.and.arrow.right",
                            action: { isLeaveGroupConfirmationPresented = true }
                        )
                        .accessibilityIdentifier("alo.group.leave")
                    }
                    moreMenu(compact: false)
                        .frame(maxWidth: .infinity)
                } else {
                    Group {
                        PeerCompactActionButton(title: "Звонок", systemName: "phone.fill", isLoading: pendingCall == .audio, action: { beginCall(.audio) })
                            .accessibilityIdentifier("alo.peer.call.audio")
                        PeerCompactActionButton(title: "Видео", systemName: "video.fill", isLoading: pendingCall == .video, action: { beginCall(.video) })
                            .accessibilityIdentifier("alo.peer.call.video")
                    }
                    .disabled(isBlockedDirectPeer || pendingCall != nil)
                    .opacity(isBlockedDirectPeer ? 0.42 : 1)
                    PeerCompactActionButton(
                        title: isMuted ? "Со звуком" : "Звук",
                        systemName: isMuted ? "bell" : "bell.slash",
                        isLoading: isMuteLoading,
                        action: toggleMute
                    )
                    .disabled(isMuteLoading)
                    PeerCompactActionButton(title: "Поиск", systemName: "magnifyingglass", action: toggleSearch)
                        .accessibilityIdentifier("alo.peer.action.search")
                    moreMenu(compact: false)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func moreMenu(compact: Bool) -> some View {
        Menu {
            Button("Оформление чата", systemImage: "paintbrush") { onOpenAppearance() }
            Button("Медиа", systemImage: "photo.on.rectangle") { scrollToMedia() }
            if conversation.kind == "direct", conversation.entityType != "saved" {
                Button("Профиль в Alo", systemImage: "person.crop.circle") { onOpenProfile() }
                Button("Проверить шифрование", systemImage: "lock.shield") { openSafetyNumber() }
            }
            if conversation.canManageGroup {
                Button("Управление", systemImage: "slider.horizontal.3") { isGroupManagementPresented = true }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .medium))
                    .frame(height: 24)
                if !compact { Text("Ещё").font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundStyle(AloTheme.accent)
            .frame(maxWidth: compact ? 44 : .infinity, minHeight: compact ? 44 : 58)
            .background(compact ? Color.clear : AloTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Ещё")
        .buttonStyle(AloControlPressStyle())
        .accessibilityIdentifier(compact ? "alo.peer.more.header" : "alo.peer.more")
    }

    @ViewBuilder
    private var profileInformation: some View {
        VStack(spacing: 12) {
            if conversation.entityType != "saved" {
            VStack(spacing: 0) {
                if !conversation.username.isEmpty {
                    profileInfoRow(
                        title: isChannelConversation ? "ссылка" : "имя пользователя",
                        value: isChannelConversation
                            ? "\(AloServerConfiguration.appLinkDisplayHost)/\(conversation.username.trimmingCharacters(in: CharacterSet(charactersIn: "@")))"
                            : conversation.username.withAtPrefix,
                        isAccent: true
                    )
                }

                if !conversation.profileDescription.isEmpty {
                    if !conversation.username.isEmpty { Divider().overlay(AloTheme.border) }
                    profileInfoRow(title: "описание", value: conversation.profileDescription, isAccent: false)
                } else if conversation.kind == "direct" {
                    if !conversation.username.isEmpty { Divider().overlay(AloTheme.border) }
                    profileInfoRow(
                        title: "статус",
                        value: conversation.online ? "в сети" : conversation.subtitle,
                        isAccent: false
                    )
                }
            }
            .padding(.horizontal, 18)
            .background(AloTheme.surface.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }


    private func profileInfoRow(title: String, value: String, isAccent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AloTheme.muted)
            Text(value)
                .font(.system(size: 17, weight: .medium))
                .textSelection(.enabled)
                .foregroundStyle(isAccent ? AloTheme.accent : AloTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 15)
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AloTheme.muted)
                TextField("Поиск по сообщениям", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .accessibilityIdentifier("alo.peer.search")
                    .onAppear { searchFocused = true }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AloTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(AloTheme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let results = cachedSearchResults
                if results.isEmpty {
                    Text("Совпадений не найдено")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                } else {
                    ForEach(results.prefix(20)) { message in
                        Button { onOpenMessage(message.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chatPreviewText(message))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AloTheme.text)
                                .lineLimit(3)
                            Text(AloFormatters.messageTime(message.createdAt))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(AloTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(AloChatPressStyle())
                        .accessibilityIdentifier("alo.peer.search-result.\(message.id)")
                    }
                }
            }
        }
        .padding(14)
        .background(AloTheme.surface.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: searchText) {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                cachedSearchResults = []
                return
            }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW") {
                cachedSearchResults = messages.filter { $0.body.localizedCaseInsensitiveContains(query) }
                return
            }
            #endif
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let ownerUserId = app.bootstrap?.me.id ?? 0
            let peerId = conversation.peerId
            let results = await Task.detached(priority: .userInitiated) {
                AloSecureOfflineCacheStore.shared.searchMessages(
                    peerId: peerId,
                    ownerUserId: ownerUserId,
                    query: query,
                    limit: 100
                )
            }.value
            guard !Task.isCancelled,
                  query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return
            }
            cachedSearchResults = results
        }
    }

    private func toggleSearch() {
        searchFocused = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1)) {
            isSearchPresented.toggle()
        }
    }

    private func beginCall(_ kind: ChatCallKind) {
        guard pendingCall == nil else { return }
        pendingCall = kind
        Task {
            if kind == .video { await onVideoCall() } else { await onAudioCall() }
            pendingCall = nil
        }
    }

    private func scrollToMedia() {
        mediaScrollRequest += 1
    }

    private func toggleMute() {
        guard !isMuteLoading else { return }
        isMuteLoading = true
        Task {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "ALO_UI_MESSENGER_PREVIEW"), conversation.peerId == 990002 {
                isMuted.toggle()
                isMuteLoading = false
                return
            }
            #endif
            do {
                if !isMuteStateKnown {
                    isMuted = try await app.api.chatMuteState(conversation: conversation)
                    isMuteStateKnown = true
                }
                isMuted = try await app.api.setChatMuted(!isMuted, conversation: conversation)
            } catch let error as AloAPIError {
                app.errorMessage = error.message
            } catch {
                app.errorMessage = "Не удалось изменить уведомления чата."
            }
            isMuteLoading = false
        }
    }

    private func openSafetyNumber() {
        safetyError = ""
        safetyVerification = nil
        isSafetyLoading = true
        isSafetyPresented = true
        Task {
            do {
                safetyVerification = try await app.api.loadSafetyVerification(peerId: conversation.peerId)
            } catch let error as AloAPIError {
                safetyError = error.message
            } catch {
                safetyError = "Не удалось загрузить данные шифрования."
            }
            isSafetyLoading = false
        }
    }

    private var mediaTabs: some View {
        // The shared segmented control, so media tabs match feed, notifications and profile.
        AloSocialSegments(values: Array(PeerMediaTab.allCases), selected: $selectedMediaTab,
                          title: { $0.title }, identifier: { "alo.peer.tab.\($0.rawValue)" })
        .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) * 1.4,
                  abs(value.translation.width) > 28,
                  let index = PeerMediaTab.allCases.firstIndex(of: selectedMediaTab) else { return }
            let next = index + (value.translation.width < 0 ? 1 : -1)
            guard PeerMediaTab.allCases.indices.contains(next) else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1)) {
                selectedMediaTab = PeerMediaTab.allCases[next]
            }
        })
    }

    private var groupMembersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(conversation.groupMembers.count) участников")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(AloTheme.text)

            ForEach(conversation.groupMembers.prefix(16)) { member in
                HStack(spacing: 11) {
                    AloAvatar(
                        name: member.name,
                        url: member.avatarUrl,
                        size: 42,
                        colorSeed: String(member.id)
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(AloTheme.text)
                            .lineLimit(1)
                        Text(member.username.isEmpty ? member.roleLabel : "@\(member.username)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AloTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !member.roleLabel.isEmpty {
                        Text(member.roleLabel)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(AloTheme.muted)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AloTheme.surface.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private func mediaContent(for tab: PeerMediaTab, attachments: [AloMessageAttachment]) -> some View {
        if attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(tab.emptyTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(AloTheme.text)
                Text(
                    isChannelConversation
                        ? tab.channelEmptySubtitle
                        : tab.emptySubtitle
                )
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(AloTheme.surface.opacity(0.68))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
        } else if tab == .photos || tab == .videos {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    Button {
                        guard Date() >= suppressMediaOpenUntil else { return }
                        activeMediaViewer = ChatMediaViewerState(
                            items: attachments.map(\.chatMediaItem), startIndex: index
                        )
                    } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { RemoteAttachmentCell(attachment: attachment) }
                            .clipped()
                    }
                    .buttonStyle(AloChatPressStyle())
                    .accessibilityLabel(attachment.name.ifBlank(tab == .photos ? "Фото" : "Видео"))
                    .accessibilityIdentifier("alo.peer.media.\(index)")
                }
            }
        } else {
            LazyVStack(spacing: 12) {
                ForEach(attachments) { attachment in
                    if attachment.isVoiceLike {
                        VoiceMessageAttachmentView(
                            attachment: attachment,
                            senderName: messages.first(where: { $0.attachments.contains(where: { $0.id == attachment.id }) })
                                .map { app.voicePlaybackTitle(for: $0) } ?? "Голосовое сообщение",
                            isMine: false, accentColor: AloTheme.accent,
                            onLongPress: {}
                        )
                    } else {
                        RemoteAttachmentCell(attachment: attachment)
                            .frame(height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private var allAttachments: [AloMessageAttachment] {
        messages.flatMap { message -> [AloMessageAttachment] in
            // Expiring media must only be opened through its message lifecycle.
            if message.selfDestructSeconds > 0 { return [] }
            if !message.attachments.isEmpty { return message.attachments }
            if message.attachmentUrl.isEmpty { return [] }
            return [
                AloMessageAttachment([
                    "type": message.attachmentType,
                    "url": message.attachmentUrl,
                    "name": message.attachmentName
                ])
            ]
        }
    }

}

/// Only the current page and its neighbour exist during a drag. Vertical scroll
/// remains owned by the profile; the leading 24 pt belong to interactive Back.
private struct AloPeerMediaPager<Content: View>: View {
    @Binding var selection: PeerMediaTab
    let width: CGFloat
    let minimumHeight: CGFloat
    let onDragState: (Bool) -> Void
    @ViewBuilder let content: (PeerMediaTab) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var translation: CGFloat = 0
    @State private var dragIsHorizontal: Bool?

    private var neighbour: PeerMediaTab? {
        guard translation != 0, let index = PeerMediaTab.allCases.firstIndex(of: selection) else { return nil }
        let next = index + (translation < 0 ? 1 : -1)
        return PeerMediaTab.allCases.indices.contains(next) ? PeerMediaTab.allCases[next] : nil
    }

    var body: some View {
        content(selection)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .top)
            .offset(x: reduceMotion ? 0 : translation)
            .overlay(alignment: .topLeading) {
                if let neighbour, !reduceMotion {
                    content(neighbour)
                        .frame(width: width, alignment: .top)
                        .offset(x: translation + (translation < 0 ? width : -width))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityIdentifier("alo.peer.pages")
            .simultaneousGesture(DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    if dragIsHorizontal == nil {
                        dragIsHorizontal = value.startLocation.x > 24 &&
                            abs(value.translation.width) > abs(value.translation.height) * 1.4
                        if dragIsHorizontal == true { onDragState(true) }
                    }
                    guard dragIsHorizontal == true else { return }
                    let delta = value.translation.width
                    let atBoundary = (selection == .photos && delta > 0) || (selection == .files && delta < 0)
                    // A light resistance at either end; no wrap from Files to Photos.
                    translation = atBoundary ? delta * 0.18 : min(width, max(-width, delta))
                }
                .onEnded { value in
                    defer {
                        dragIsHorizontal = nil
                        onDragState(false)
                    }
                    guard dragIsHorizontal == true else { return }
                    let target = neighbour
                    let commit = abs(translation) > width * 0.22 ||
                        (abs(value.velocity.width) > 450 && value.velocity.width * translation > 0)
                    if let target, commit {
                        // Commit selection synchronously. The incoming page starts
                        // exactly where the finger left it, then settles to zero.
                        var instant = Transaction(animation: nil)
                        instant.disablesAnimations = true
                        withTransaction(instant) {
                            translation += translation < 0 ? width : -width
                            selection = target
                        }
                    }
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
                        translation = 0
                    }
                })
    }
}

private struct GroupManagementSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss

    let conversation: AloConversationDetail
    /// Owner only: asks to delete the community, as the last row of Telegram's edit screen.
    var onDelete: (() -> Void)? = nil

    @State private var snapshot: AloGroupManagementSnapshot?
    @State private var policy: AloGroupPolicy?
    @State private var selectedMember: AloGroupMember?
    @State private var newTopicTitle = ""
    @State private var newTopicEmoji = "💬"
    @State private var topicPendingDeletion: AloForumTopic?
    @State private var topicPendingMerge: AloForumTopic?
    @State private var inviteLabel = ""
    @State private var inviteRequiresApproval = false
    @State private var inviteUsageLimit = 0
    @State private var inviteHasExpiry = false
    @State private var inviteExpiryDate = Date().addingTimeInterval(7 * 24 * 60 * 60)
    @State private var selectedInvite: AloGroupInviteLink?
    @State private var selectedInviteStats: AloGroupInviteLink?
    @State private var createdInviteToken = ""
    @State private var memberQuery = ""
    @State private var memberRoleFilter = "all"
    @State private var isLoading = true
    @State private var isLoadingEarlierEvents = false
    @State private var isSaving = false
    @State private var errorMessage = ""

    private let permissionItems = [
        ("sendMessages", "Отправка сообщений"),
        ("sendMedia", "Отправка медиа"),
        ("addMembers", "Добавление участников"),
        ("pinMessages", "Закрепление сообщений"),
        ("changeInfo", "Изменение профиля сообщества")
    ]

    private var communityKind: String {
        // Before the policy loads, the conversation's own type decides: a channel is never shown as a group.
        let rawKind = policy?.kind ?? snapshot?.policy.kind ?? conversation.groupPolicy?.kind
            ?? (conversation.entityType == "channel" ? "channel" : "group")
        return rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "channel"
            ? "channel"
            : "group"
    }

    private var isChannelCommunity: Bool { communityKind == "channel" }

    private var communityTypeTitle: String {
        isChannelCommunity ? "Канал" : "Группа"
    }

    private func normalizedPolicy(_ source: AloGroupPolicy) -> AloGroupPolicy {
        var normalized = source
        normalized.kind = source.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "channel"
            ? "channel"
            : "group"
        if normalized.kind == "channel" {
            normalized.isForum = false
            normalized.historyVisible = true
            normalized.slowModeSeconds = 0
        }
        return normalized
    }

    private func normalizedSnapshot(_ source: AloGroupManagementSnapshot) -> AloGroupManagementSnapshot {
        let normalized = normalizedPolicy(source.policy)
        return AloGroupManagementSnapshot(
            policy: normalized,
            members: source.members,
            requests: source.requests,
            invites: source.invites,
            events: source.events,
            topics: normalized.kind == "channel" ? [] : source.topics,
            bans: source.bans,
            nextAdminLogBeforeId: source.nextAdminLogBeforeId
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && snapshot == nil {
                    ProgressView("Загружаем управление…")
                        .tint(AloTheme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    managementList
                }
            }
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Управление")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") { savePolicy() }
                        .fontWeight(.semibold)
                        .disabled(policy == nil || isSaving)
                }
            }
        }
        .task { await load(showProgress: true) }
        .onChange(of: app.activeConversation?.groupPolicy) { _, value in
            guard let value,
                  app.activeConversation?.roomId == conversation.roomId,
                  let current = snapshot else { return }
            let normalized = normalizedPolicy(value)
            policy = normalized
            snapshot = AloGroupManagementSnapshot(
                policy: normalized,
                members: current.members,
                requests: current.requests,
                invites: current.invites,
                events: current.events,
                topics: normalized.kind == "channel" ? [] : current.topics,
                bans: current.bans,
                nextAdminLogBeforeId: current.nextAdminLogBeforeId
            )
        }
        .onChange(of: app.activeConversation?.groupMembers) { _, members in
            guard let members,
                  app.activeConversation?.roomId == conversation.roomId,
                  let current = snapshot else { return }
            snapshot = AloGroupManagementSnapshot(
                policy: current.policy,
                members: members,
                requests: current.requests,
                invites: current.invites,
                events: current.events,
                topics: current.topics,
                bans: current.bans,
                nextAdminLogBeforeId: current.nextAdminLogBeforeId
            )
        }
        .onChange(of: app.groupManagementRevision(for: conversation.roomId)) { _, _ in
            Task { await load(showProgress: false) }
        }
        .onChange(of: app.groupManagementDelta(for: conversation.roomId)) { _, delta in
            guard let delta else { return }
            apply(delta)
        }
        .sheet(item: $selectedMember) { member in
            GroupMemberAccessSheet(
                member: member,
                actorRole: conversation.groupMemberRole,
                onSave: { role, adminTitle, isAnonymous, rights, restrictions in
                    do {
                        _ = try await app.api.updateGroupMemberAccess(
                            roomId: conversation.roomId,
                            userId: member.id,
                            role: role,
                            adminTitle: adminTitle,
                            isAnonymous: isAnonymous,
                            adminRights: rights,
                            restrictions: restrictions,
                            changeRole: conversation.groupMemberRole == "owner"
                        )
                        await load(showProgress: false)
                        return true
                    } catch {
                        report(error, fallback: "Не удалось обновить права участника.")
                        return false
                    }
                },
                onRemove: {
                    do {
                        _ = try await app.api.removeGroupMember(
                            roomId: conversation.roomId,
                            userId: member.id
                        )
                        await load(showProgress: false)
                        return true
                    } catch {
                        report(error, fallback: "Не удалось удалить участника.")
                        return false
                    }
                },
                onTransferOwnership: {
                    password in
                    do {
                        _ = try await app.api.transferGroupOwnership(
                            roomId: conversation.roomId,
                            userId: member.id,
                            currentPassword: password
                        )
                        app.activeConversation = try await app.api.loadConversation(
                            peerId: conversation.peerId
                        )
                        await load(showProgress: false)
                        return true
                    } catch {
                        report(error, fallback: "Не удалось передать сообщество.")
                        return false
                    }
                },
                onBan: { reason, expiresAt in
                    do {
                        _ = try await app.api.banGroupMember(
                            roomId: conversation.roomId,
                            userId: member.id,
                            reason: reason,
                            expiresAt: expiresAt
                        )
                        await load(showProgress: false)
                        return true
                    } catch {
                        report(error, fallback: "Не удалось заблокировать участника.")
                        return false
                    }
                }
            )
        }
        .sheet(item: $selectedInvite) { invite in
            GroupInviteEditSheet(invite: invite) { label, requiresApproval, usageLimit, expiresAt in
                do {
                    _ = try await app.api.updateGroupInviteLink(
                        roomId: conversation.roomId,
                        inviteId: invite.id,
                        label: label,
                        requiresApproval: requiresApproval,
                        usageLimit: usageLimit,
                        expiresAt: expiresAt
                    )
                    await load(showProgress: false)
                    return true
                } catch {
                    report(error, fallback: "Не удалось изменить ссылку.")
                    return false
                }
            }
        }
        .sheet(item: $selectedInviteStats) { invite in
            GroupInviteStatsSheet(roomId: conversation.roomId, invite: invite)
                .environmentObject(app)
        }
        .confirmationDialog(
            "Удалить тему вместе со всеми сообщениями?",
            isPresented: Binding(
                get: { topicPendingDeletion != nil },
                set: { if !$0 { topicPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить тему", role: .destructive) {
                guard let topic = topicPendingDeletion else { return }
                topicPendingDeletion = nil
                deleteTopic(topic)
            }
            Button("Отмена", role: .cancel) {
                topicPendingDeletion = nil
            }
        } message: {
            Text("Действие нельзя отменить. Сообщения темы будут удалены у всех участников.")
        }
        .confirmationDialog(
            "Куда перенести историю темы?",
            isPresented: Binding(
                get: { topicPendingMerge != nil },
                set: { if !$0 { topicPendingMerge = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let source = topicPendingMerge, let snapshot {
                ForEach(snapshot.topics.filter { $0.id != source.id && !$0.isClosed && !$0.isHidden }) { target in
                    Button("\(target.iconEmoji) \(target.title)") {
                        topicPendingMerge = nil
                        mergeTopic(source, into: target)
                    }
                }
            }
            Button("Отмена", role: .cancel) { topicPendingMerge = nil }
        } message: {
            Text("Все сообщения, реакции, закрепления и состояния прочтения будут перенесены в выбранную тему.")
        }
    }

    private var managementList: some View {
        List {
            if !errorMessage.isEmpty {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }

            if policy != nil {
                Section("Тип и доступ") {
                    HStack {
                        Text("Тип")
                        Spacer()
                        Text(communityTypeTitle)
                            .foregroundStyle(AloTheme.muted)
                    }
                    Picker("Вступление", selection: policyBinding(\.joinPolicy, fallback: "invite")) {
                        Text("По приглашению").tag("invite")
                        Text("По заявке").tag("request")
                        Text("Публичное").tag("public")
                    }
                    if policy?.joinPolicy == "public" {
                        TextField("Публичное имя", text: policyBinding(\.username, fallback: ""))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if !isChannelCommunity {
                        Toggle("Темы", isOn: policyBinding(\.isForum, fallback: false))
                        Toggle("История для новых участников", isOn: policyBinding(\.historyVisible, fallback: true))
                        Picker("Медленный режим", selection: policyBinding(\.slowModeSeconds, fallback: 0)) {
                            Text("Выключен").tag(0)
                            Text("10 секунд").tag(10)
                            Text("30 секунд").tag(30)
                            Text("1 минута").tag(60)
                            Text("5 минут").tag(300)
                            Text("1 час").tag(3600)
                        }
                    }
                }

                if !isChannelCommunity {
                    Section("Разрешения участников") {
                        ForEach(permissionItems, id: \.0) { key, title in
                            Toggle(title, isOn: permissionBinding(key))
                        }
                    }
                }

                Section("Ссылки приглашения") {
                    TextField("Название ссылки", text: $inviteLabel)
                    Toggle("Одобрять заявки", isOn: $inviteRequiresApproval)
                    Picker("Лимит вступлений", selection: $inviteUsageLimit) {
                        Text("Без лимита").tag(0)
                        Text("1").tag(1)
                        Text("10").tag(10)
                        Text("100").tag(100)
                    }
                    Toggle("Ограничить срок", isOn: $inviteHasExpiry)
                    if inviteHasExpiry {
                        DatePicker(
                            "Действует до",
                            selection: $inviteExpiryDate,
                            in: Date().addingTimeInterval(60)...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                    Button {
                        createInvite()
                    } label: {
                        Label("Создать ссылку", systemImage: "link.badge.plus")
                    }
                    .disabled(isSaving)

                    if !createdInviteToken.isEmpty {
                        Button {
                            UIPasteboard.general.string = AloDeepLinkTarget.inviteURL(
                                token: createdInviteToken
                            )?.absoluteString
                        } label: {
                            Label("Скопировать ссылку приглашения", systemImage: "doc.on.doc")
                        }
                        Text("Код показывается один раз и хранится на сервере только в виде хеша.")
                            .font(.footnote)
                            .foregroundStyle(AloTheme.muted)
                    }

                    if let snapshot {
                        ForEach(snapshot.invites) { invite in
                            HStack(spacing: 10) {
                                Image(systemName: invite.isActive ? "link" : "link.badge.minus")
                                    .foregroundStyle(invite.isActive ? AloTheme.accent : AloTheme.muted)
                                Button {
                                    selectedInviteStats = invite
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(invite.label.ifBlank("Ссылка без названия"))
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(AloTheme.text)
                                        Text(inviteSummary(invite))
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(AloTheme.muted)
                                        if let creatorName = invite.creator?.name, !creatorName.isEmpty {
                                            Text("Создал: \(creatorName)")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(AloTheme.muted.opacity(0.82))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                if invite.isActive {
                                    Button {
                                        selectedInvite = invite
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.borderless)
                                    Button(role: .destructive) {
                                        revokeInvite(invite)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }

            if !isChannelCommunity, policy?.isForum == true {
                Section("Темы форума") {
                    HStack(spacing: 10) {
                        TextField("Иконка", text: $newTopicEmoji)
                            .multilineTextAlignment(.center)
                            .frame(width: 58)
                        TextField("Новая тема", text: $newTopicTitle)
                        Button {
                            createTopic()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .disabled(newTopicTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let snapshot {
                        ForEach(snapshot.topics) { topic in
                            HStack(spacing: 11) {
                                Text(topic.iconEmoji)
                                    .font(.system(size: 21))
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(AloTheme.surface))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(topic.title)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(AloTheme.text)
                                    Text(topic.isGeneral ? "Основная тема" : topic.isClosed ? "Закрыта" : "Открыта")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AloTheme.muted)
                                }
                                Spacer()
                                Menu {
                                    Button {
                                        updateTopic(topic, isClosed: !topic.isClosed)
                                    } label: {
                                        Label(
                                            topic.isClosed ? "Открыть тему" : "Закрыть тему",
                                            systemImage: topic.isClosed ? "lock.open" : "lock"
                                        )
                                    }
                                    if topic.isGeneral {
                                        Button {
                                            updateTopicVisibility(topic, isHidden: !topic.isHidden)
                                        } label: {
                                            Label(
                                                topic.isHidden ? "Показать общую тему" : "Скрыть общую тему",
                                                systemImage: topic.isHidden ? "eye" : "eye.slash"
                                            )
                                        }
                                    } else {
                                        Button {
                                            topicPendingMerge = topic
                                        } label: {
                                            Label("Объединить тему", systemImage: "arrow.triangle.merge")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            topicPendingDeletion = topic
                                        } label: {
                                            Label("Удалить тему", systemImage: "trash")
                                        }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(AloTheme.muted)
                                        .frame(width: 36, height: 36)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            if let snapshot, !snapshot.requests.isEmpty {
                Section("Заявки на вступление") {
                    ForEach(snapshot.requests) { request in
                        HStack(spacing: 11) {
                            AloAvatar(
                                name: request.user.name,
                                url: request.user.avatarUrl,
                                size: 42,
                                colorSeed: String(request.user.id)
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.user.name)
                                    .font(.system(size: 15, weight: .bold))
                                Text(request.user.username.withAtPrefix)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AloTheme.muted)
                            }
                            Spacer()
                            Button {
                                review(request, approve: false)
                            } label: {
                                Image(systemName: "xmark")
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            Button {
                                review(request, approve: true)
                            } label: {
                                Image(systemName: "checkmark")
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.circle)
                        }
                    }
                }
            }

            if let snapshot {
                Section(isChannelCommunity ? "Подписчики" : "Участники") {
                    TextField("Поиск по имени или username", text: $memberQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Роль", selection: $memberRoleFilter) {
                        Text("Все").tag("all")
                        Text("Админы").tag("admins")
                        Text("Остальные").tag("members")
                    }
                    .pickerStyle(.segmented)

                    if filteredMembers.isEmpty {
                        Text(memberQuery.isEmpty ? "Список пуст" : "Ничего не найдено")
                            .foregroundStyle(AloTheme.muted)
                    }
                    ForEach(filteredMembers) { member in
                        Button {
                            guard member.role != "owner",
                                  member.id != (app.bootstrap?.me.id ?? 0) else { return }
                            selectedMember = member
                        } label: {
                            HStack(spacing: 11) {
                                AloAvatar(
                                    name: member.name,
                                    url: member.avatarUrl,
                                    size: 42,
                                    colorSeed: String(member.id)
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.name)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(AloTheme.text)
                                    Text(member.username.withAtPrefix.ifBlank("Участник"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AloTheme.muted)
                                }
                                Spacer()
                                Text(member.roleLabel)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(AloTheme.accent)
                                if member.role != "owner", member.id != (app.bootstrap?.me.id ?? 0) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(AloTheme.muted)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !snapshot.bans.isEmpty {
                    Section("Заблокированные") {
                        ForEach(snapshot.bans) { ban in
                            HStack(spacing: 11) {
                                AloAvatar(
                                    name: ban.user.name,
                                    url: ban.user.avatarUrl,
                                    size: 42,
                                    colorSeed: String(ban.user.id)
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ban.user.name)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(AloTheme.text)
                                    Text(ban.reason.ifBlank("Причина не указана"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AloTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("Разблокировать") {
                                    unban(ban)
                                }
                                .font(.system(size: 12, weight: .bold))
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("Недавние действия") {
                if snapshot.events.isEmpty {
                        Text("Действий пока нет")
                            .foregroundStyle(AloTheme.muted)
                    } else {
                        ForEach(snapshot.events) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(eventTitle(event))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AloTheme.text)
                                Text(event.createdAt)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(AloTheme.muted)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                if snapshot.nextAdminLogBeforeId != nil {
                    Button {
                        loadEarlierAdminEvents()
                    } label: {
                        HStack(spacing: 8) {
                            if isLoadingEarlierEvents {
                                ProgressView()
                                    .tint(AloTheme.accent)
                            }
                            Text(isLoadingEarlierEvents ? "Загружаем…" : "Показать предыдущие")
                        }
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isLoadingEarlierEvents)
                }
            }
            if conversation.groupMemberRole == "owner", let onDelete {
                Section {
                    Button(role: .destructive, action: onDelete) {
                        Text(isChannelCommunity ? "Удалить канал" : "Удалить группу")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("alo.group.delete")
                } footer: {
                    Text(isChannelCommunity
                        ? "Канал, публикации и подписчики будут удалены для всех."
                        : "Группа, сообщения и участники будут удалены для всех.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await load(showProgress: false) }
        .disabled(isSaving)
    }

    private func policyBinding<Value>(
        _ keyPath: WritableKeyPath<AloGroupPolicy, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { policy?[keyPath: keyPath] ?? fallback },
            set: { value in policy?[keyPath: keyPath] = value }
        )
    }

    private var filteredMembers: [AloGroupMember] {
        guard let members = snapshot?.members else { return [] }
        let query = memberQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return members.filter { member in
            let matchesRole: Bool
            switch memberRoleFilter {
            case "admins":
                matchesRole = member.role == "owner" || member.role == "admin"
            case "members":
                matchesRole = member.role != "owner" && member.role != "admin"
            default:
                matchesRole = true
            }
            guard matchesRole else { return false }
            guard !query.isEmpty else { return true }
            return member.name.lowercased().contains(query)
                || member.username.lowercased().contains(query)
        }
    }

    private func permissionBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { policy?.defaultPermissions[key] ?? false },
            set: { value in policy?.defaultPermissions[key] = value }
        )
    }

    private func load(showProgress: Bool) async {
        if showProgress { isLoading = true }
        do {
            let loaded = try await app.api.loadGroupManagement(roomId: conversation.roomId)
            let normalized = normalizedSnapshot(loaded)
            snapshot = normalized
            policy = normalized.policy
            errorMessage = ""
        } catch {
            report(error, fallback: "Не удалось загрузить управление сообществом.")
        }
        isLoading = false
    }

    private func apply(_ delta: AloGroupManagementDelta) {
        guard let current = snapshot else {
            Task { await load(showProgress: false) }
            return
        }

        var members = current.members.filter {
            !delta.memberIdsRemoved.contains($0.id)
        }
        for member in delta.membersUpserted {
            members.removeAll { $0.id == member.id }
            members.append(member)
        }
        members.sort {
            let leftRank = $0.role == "owner" ? 0 : ($0.role == "admin" ? 1 : 2)
            let rightRank = $1.role == "owner" ? 0 : ($1.role == "admin" ? 1 : 2)
            if leftRank != rightRank { return leftRank < rightRank }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        var requests = current.requests.filter {
            !delta.requestUserIdsRemoved.contains($0.user.id)
        }
        for request in delta.requestsUpserted {
            requests.removeAll { $0.user.id == request.user.id }
            requests.append(request)
        }
        requests.sort { $0.createdAt < $1.createdAt }

        var bans = current.bans.filter {
            !delta.banUserIdsRemoved.contains($0.user.id)
        }
        for ban in delta.bansUpserted {
            bans.removeAll { $0.user.id == ban.user.id }
            bans.insert(ban, at: 0)
        }

        var invites = current.invites
        for invite in delta.invitesUpserted {
            invites.removeAll { $0.id == invite.id }
            invites.insert(invite, at: 0)
        }

        var topics = current.topics.filter {
            !delta.topicIdsRemoved.contains($0.id)
        }
        for topic in delta.topicsUpserted {
            topics.removeAll { $0.id == topic.id }
            topics.append(topic)
        }
        topics.sort {
            if $0.isGeneral != $1.isGeneral { return $0.isGeneral }
            if $0.isClosed != $1.isClosed { return !$0.isClosed }
            return $0.updatedAt > $1.updatedAt
        }

        var events = current.events
        if let event = delta.adminEvent {
            events.removeAll { $0.id == event.id }
            events.insert(event, at: 0)
            if events.count > 200 {
                events.removeLast(events.count - 200)
            }
        }

        let nextPolicy = normalizedPolicy(delta.policy ?? current.policy)
        policy = nextPolicy
        snapshot = AloGroupManagementSnapshot(
            policy: nextPolicy,
            members: members,
            requests: requests,
            invites: invites,
            events: events,
            topics: nextPolicy.kind == "channel" ? [] : topics,
            bans: bans,
            nextAdminLogBeforeId: current.nextAdminLogBeforeId
        )

        if let selectedMember {
            if delta.memberIdsRemoved.contains(selectedMember.id) {
                self.selectedMember = nil
            } else if let updated = delta.membersUpserted.first(
                where: { $0.id == selectedMember.id }
            ) {
                self.selectedMember = updated
            }
        }
    }

    private func loadEarlierAdminEvents() {
        guard let current = snapshot,
              let beforeId = current.nextAdminLogBeforeId,
              !isLoadingEarlierEvents else { return }
        isLoadingEarlierEvents = true
        Task {
            defer { isLoadingEarlierEvents = false }
            do {
                let page = try await app.api.loadGroupAdminLog(
                    roomId: conversation.roomId,
                    beforeId: beforeId
                )
                let eventIds = Set(current.events.map(\.id))
                let mergedEvents = current.events + page.events.filter { !eventIds.contains($0.id) }
                snapshot = AloGroupManagementSnapshot(
                    policy: current.policy,
                    members: current.members,
                    requests: current.requests,
                    invites: current.invites,
                    events: mergedEvents,
                    topics: current.topics,
                    bans: current.bans,
                    nextAdminLogBeforeId: page.nextBeforeId
                )
            } catch {
                report(error, fallback: "Не удалось загрузить предыдущие действия.")
            }
        }
    }

    private func savePolicy() {
        guard let policy, !isSaving else { return }
        let outgoingPolicy = normalizedPolicy(policy)
        isSaving = true
        Task {
            do {
                self.policy = try await app.api.updateGroupSettings(
                    roomId: conversation.roomId,
                    policy: outgoingPolicy
                )
                await load(showProgress: false)
            } catch {
                report(error, fallback: "Не удалось сохранить настройки сообщества.")
            }
            isSaving = false
        }
    }

    private func review(_ request: AloGroupJoinRequest, approve: Bool) {
        Task {
            do {
                try await app.api.reviewGroupJoinRequest(
                    roomId: conversation.roomId,
                    userId: request.user.id,
                    approve: approve
                )
                await load(showProgress: false)
            } catch {
                report(error, fallback: "Не удалось обработать заявку.")
            }
        }
    }

    private func createTopic() {
        let title = newTopicTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            do {
                _ = try await app.api.createGroupTopic(
                    roomId: conversation.roomId,
                    title: title,
                    iconEmoji: newTopicEmoji
                )
                newTopicTitle = ""
                newTopicEmoji = "💬"
                await load(showProgress: false)
            } catch {
                report(error, fallback: "Не удалось создать тему.")
            }
        }
    }

    private func createInvite() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do {
                let result = try await app.api.createGroupInviteLink(
                    roomId: conversation.roomId,
                    label: inviteLabel,
                    requiresApproval: inviteRequiresApproval,
                    usageLimit: inviteUsageLimit,
                    expiresAt: inviteHasExpiry
                        ? ISO8601DateFormatter().string(from: inviteExpiryDate)
                        : ""
                )
                createdInviteToken = result.token
                UIPasteboard.general.string = AloDeepLinkTarget.inviteURL(
                    token: result.token
                )?.absoluteString
                inviteLabel = ""
                await load(showProgress: false)
            } catch {
                report(error, fallback: "Не удалось создать ссылку.")
            }
            isSaving = false
        }
    }

    private func revokeInvite(_ invite: AloGroupInviteLink) {
        Task {
            do {
                try await app.api.revokeGroupInviteLink(
                    roomId: conversation.roomId,
                    inviteId: invite.id
                )
                await load(showProgress: false)
            } catch {
                report(error, fallback: "Не удалось отозвать ссылку.")
            }
        }
    }

    private func inviteSummary(_ invite: AloGroupInviteLink) -> String {
        if !invite.isActive { return "Отозвана" }
        let joined = invite.usageLimit > 0
            ? "\(invite.joinedCount) из \(invite.usageLimit) вступили"
            : "\(invite.joinedCount) вступили"
        var parts = [joined]
        if invite.pendingCount > 0 {
            parts.append("\(invite.pendingCount) ожидают")
        } else if invite.requiresApproval {
            parts.append("вступление по заявке")
        }
        if !invite.expiresAt.isEmpty {
            parts.append("до \(String(invite.expiresAt.prefix(10)))")
        }
        return parts.joined(separator: " · ")
    }

    private func updateTopic(_ topic: AloForumTopic, isClosed: Bool) {
        Task {
            do {
                _ = try await app.api.updateGroupTopic(
                    roomId: conversation.roomId,
                    topicId: topic.id,
                    title: topic.title,
                    iconEmoji: topic.iconEmoji,
                    isClosed: isClosed,
                    isHidden: topic.isHidden
                )
                await load(showProgress: false)
            } catch {
                report(error, fallback: "Не удалось изменить тему.")
            }
        }
    }

    private func updateTopicVisibility(_ topic: AloForumTopic, isHidden: Bool) {
        Task {
            do {
                _ = try await app.api.updateGroupTopic(
                    roomId: conversation.roomId,
                    topicId: topic.id,
                    title: topic.title,
                    iconEmoji: topic.iconEmoji,
                    isClosed: topic.isClosed,
                    isHidden: isHidden
                )
                await load(showProgress: false)
                app.activeConversation = try? await app.api.loadConversation(
                    peerId: conversation.peerId
                )
            } catch {
                report(error, fallback: "Не удалось изменить видимость темы.")
            }
        }
    }

    private func deleteTopic(_ topic: AloForumTopic) {
        Task {
            do {
                try await app.api.deleteGroupTopic(
                    roomId: conversation.roomId,
                    topicId: topic.id
                )
                await load(showProgress: false)
                app.activeConversation = try? await app.api.loadConversation(
                    peerId: conversation.peerId
                )
            } catch {
                report(error, fallback: "Не удалось удалить тему.")
            }
        }
    }

    private func mergeTopic(_ source: AloForumTopic, into target: AloForumTopic) {
        Task {
            do {
                _ = try await app.api.mergeGroupTopic(
                    roomId: conversation.roomId,
                    sourceTopicId: source.id,
                    targetTopicId: target.id
                )
                if let ownerUserId = app.bootstrap?.me.id {
                    AloSecureOfflineCacheStore.shared.reassignSearchHistoryTopic(
                        peerId: conversation.peerId,
                        ownerUserId: ownerUserId,
                        sourceTopicId: source.id,
                        targetTopicId: target.id
                    )
                }
                await load(showProgress: false)
                app.activeConversation = try? await app.api.loadConversation(
                    peerId: conversation.peerId
                )
            } catch {
                report(error, fallback: "Не удалось объединить темы.")
            }
        }
    }

    private func unban(_ ban: AloGroupBan) {
        Task {
            do {
                try await app.api.unbanGroupMember(
                    roomId: conversation.roomId,
                    userId: ban.user.id
                )
                await load(showProgress: false)
            } catch {
                report(error, fallback: "Не удалось снять блокировку.")
            }
        }
    }

    private func report(_ error: Error, fallback: String) {
        if let error = error as? AloAPIError {
            errorMessage = error.message
        } else {
            errorMessage = fallback
        }
    }

    private func eventTitle(_ event: AloGroupAdminEvent) -> String {
        let actor = event.actor.name
        let target = event.target?.name ?? ""
        switch event.action {
        case "profile_updated": return "\(actor) изменил профиль группы"
        case "settings_updated": return "\(actor) изменил настройки"
        case "member_added": return "\(actor) добавил \(target)"
        case "member_removed": return "\(actor) удалил \(target)"
        case "member_promoted": return "\(actor) назначил \(target) администратором"
        case "member_demoted": return "\(actor) снял права администратора у \(target)"
        case "member_permissions_updated": return "\(actor) изменил права \(target)"
        case "member_banned": return "\(actor) заблокировал \(target)"
        case "member_unbanned": return "\(actor) разблокировал \(target)"
        case "ownership_transferred": return "\(actor) передал сообщество пользователю \(target)"
        case "join_request_approved": return "\(actor) одобрил заявку \(target)"
        case "join_request_rejected": return "\(actor) отклонил заявку \(target)"
        case "invite_link_created": return "\(actor) создал ссылку-приглашение"
        case "invite_link_updated": return "\(actor) изменил ссылку-приглашение"
        case "invite_link_revoked": return "\(actor) отозвал ссылку-приглашение"
        case "topic_created": return "\(actor) создал тему"
        case "topic_closed": return "\(actor) закрыл тему"
        case "topic_updated": return "\(actor) изменил тему"
        default: return "\(actor): \(event.action)"
        }
    }
}

private struct GroupMemberAccessSheet: View {
    @Environment(\.dismiss) private var dismiss

    let member: AloGroupMember
    let actorRole: String
    let onSave: (String, String, Bool, [String: Bool], [String: Bool]) async -> Bool
    let onRemove: () async -> Bool
    let onTransferOwnership: (String) async -> Bool
    let onBan: (String, String) async -> Bool

    @State private var role: String
    @State private var adminTitle: String
    @State private var isAnonymous: Bool
    @State private var adminRights: [String: Bool]
    @State private var restrictions: [String: Bool]
    @State private var isSaving = false
    @State private var transferPassword = ""
    @State private var banReason = "Заблокирован администратором"
    @State private var banDurationHours = 0

    private let adminItems = [
        ("changeInfo", "Изменение профиля"),
        ("deleteMessages", "Удаление сообщений"),
        ("banUsers", "Блокировка участников"),
        ("inviteUsers", "Приглашения и заявки"),
        ("pinMessages", "Закрепление сообщений"),
        ("manageVideoChats", "Управление видеочатами"),
        ("addAdmins", "Назначение администраторов"),
        ("manageTopics", "Управление темами"),
        ("postMessages", "Публикация сообщений"),
        ("editMessages", "Редактирование сообщений")
    ]
    private let restrictionItems = [
        ("sendMessages", "Запретить сообщения"),
        ("sendMedia", "Запретить медиа"),
        ("addMembers", "Запретить приглашения"),
        ("pinMessages", "Запретить закрепление"),
        ("changeInfo", "Запретить изменение профиля")
    ]

    init(
        member: AloGroupMember,
        actorRole: String,
        onSave: @escaping (String, String, Bool, [String: Bool], [String: Bool]) async -> Bool,
        onRemove: @escaping () async -> Bool,
        onTransferOwnership: @escaping (String) async -> Bool,
        onBan: @escaping (String, String) async -> Bool
    ) {
        self.member = member
        self.actorRole = actorRole
        self.onSave = onSave
        self.onRemove = onRemove
        self.onTransferOwnership = onTransferOwnership
        self.onBan = onBan
        _role = State(initialValue: member.role)
        _adminTitle = State(initialValue: member.adminTitle)
        _isAnonymous = State(initialValue: member.isAnonymous)
        _adminRights = State(initialValue: member.adminRights)
        _restrictions = State(initialValue: member.restrictions)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        AloAvatar(
                            name: member.name,
                            url: member.avatarUrl,
                            size: 48,
                            colorSeed: String(member.id)
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(member.name).font(.headline)
                            Text(member.username.withAtPrefix)
                                .font(.subheadline)
                                .foregroundStyle(AloTheme.muted)
                        }
                    }
                }

                if actorRole == "owner" {
                    Section("Роль") {
                        Picker("Роль", selection: $role) {
                            Text("Участник").tag("member")
                            Text("Администратор").tag("admin")
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if role == "admin" {
                    Section {
                        Toggle("Оставаться анонимным", isOn: $isAnonymous)
                        Text("В интерфейсе сообщения будут подписаны от имени сообщества. Криптографическая доставка остаётся привязана к устройству администратора.")
                            .font(.footnote)
                            .foregroundStyle(AloTheme.muted)
                    }
                    Section("Подпись администратора") {
                        TextField("Например, Редактор", text: $adminTitle)
                            .onChange(of: adminTitle) { _, value in
                                if value.count > 16 {
                                    adminTitle = String(value.prefix(16))
                                }
                            }
                        Text("Подпись отображается рядом с ролью администратора.")
                            .font(.footnote)
                            .foregroundStyle(AloTheme.muted)
                    }
                    Section("Права администратора") {
                        ForEach(adminItems, id: \.0) { key, title in
                            Toggle(title, isOn: mapBinding($adminRights, key))
                        }
                    }
                } else {
                    Section("Ограничения") {
                        ForEach(restrictionItems, id: \.0) { key, title in
                            Toggle(title, isOn: mapBinding($restrictions, key))
                        }
                    }
                }

                Section {
                    if actorRole == "owner" {
                        SecureField("Пароль владельца", text: $transferPassword)
                            .textContentType(.password)
                        Button {
                            runTransferOwnership()
                        } label: {
                            Label("Передать права владельца", systemImage: "person.2.badge.gearshape")
                        }
                        .disabled(transferPassword.isEmpty)
                    }
                    TextField("Причина блокировки", text: $banReason)
                    Picker("Срок блокировки", selection: $banDurationHours) {
                        Text("Навсегда").tag(0)
                        Text("1 час").tag(1)
                        Text("1 день").tag(24)
                        Text("1 неделя").tag(168)
                        Text("1 месяц").tag(720)
                    }
                    Button(role: .destructive) {
                        runBan()
                    } label: {
                        Label("Заблокировать", systemImage: "person.crop.circle.badge.xmark")
                    }
                    Button(role: .destructive) {
                        runRemove()
                    } label: {
                        Label("Удалить из группы", systemImage: "person.fill.xmark")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AloTheme.background)
            .navigationTitle("Права участника")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { runSave() }
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                }
            }
        }
        .onChange(of: role) { _, newRole in
            if newRole == "admin", adminRights.isEmpty {
                adminRights = Dictionary(
                    uniqueKeysWithValues: adminItems.map { ($0.0, $0.0 != "addAdmins") }
                )
            }
        }
    }

    private func mapBinding(_ map: Binding<[String: Bool]>, _ key: String) -> Binding<Bool> {
        Binding(
            get: { map.wrappedValue[key] ?? false },
            set: { value in
                var next = map.wrappedValue
                next[key] = value
                map.wrappedValue = next
            }
        )
    }

    private func runSave() {
        isSaving = true
        Task {
            let success = await onSave(role, adminTitle, role == "admin" && isAnonymous, adminRights, restrictions)
            isSaving = false
            if success { dismiss() }
        }
    }

    private func runTransferOwnership() {
        let password = transferPassword
        guard !password.isEmpty else { return }
        isSaving = true
        Task {
            let success = await onTransferOwnership(password)
            isSaving = false
            if success { dismiss() }
        }
    }

    private func runBan() {
        let reason = banReason.trimmingCharacters(in: .whitespacesAndNewlines)
            .ifBlank("Заблокирован администратором")
        let expiresAt = banDurationHours > 0
            ? ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(TimeInterval(banDurationHours * 60 * 60))
            )
            : ""
        isSaving = true
        Task {
            let success = await onBan(reason, expiresAt)
            isSaving = false
            if success { dismiss() }
        }
    }

    private func runRemove() {
        isSaving = true
        Task {
            let success = await onRemove()
            isSaving = false
            if success { dismiss() }
        }
    }
}

private struct GroupInviteEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let invite: AloGroupInviteLink
    let onSave: (String, Bool, Int, String) async -> Bool

    @State private var label: String
    @State private var requiresApproval: Bool
    @State private var usageLimit: Int
    @State private var hasExpiry: Bool
    @State private var expiryDate: Date
    @State private var isSaving = false

    init(
        invite: AloGroupInviteLink,
        onSave: @escaping (String, Bool, Int, String) async -> Bool
    ) {
        self.invite = invite
        self.onSave = onSave
        let parsedExpiry = ISO8601DateFormatter().date(from: invite.expiresAt)
        _label = State(initialValue: invite.label)
        _requiresApproval = State(initialValue: invite.requiresApproval)
        _usageLimit = State(initialValue: invite.usageLimit)
        _hasExpiry = State(initialValue: parsedExpiry != nil)
        _expiryDate = State(
            initialValue: max(parsedExpiry ?? Date().addingTimeInterval(7 * 24 * 60 * 60), Date())
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ссылка") {
                    TextField("Название", text: $label)
                    Toggle("Одобрять заявки", isOn: $requiresApproval)
                    Picker("Лимит вступлений", selection: $usageLimit) {
                        Text("Без лимита").tag(0)
                        ForEach([1, 10, 100], id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    Toggle("Ограничить срок", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker(
                            "Действует до",
                            selection: $expiryDate,
                            in: Date().addingTimeInterval(60)...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }
                Section {
                    Text("Использовано: \(invite.usageCount)")
                        .foregroundStyle(AloTheme.muted)
                }
            }
            .navigationTitle("Ссылка приглашения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(isSaving || (usageLimit > 0 && usageLimit < invite.usageCount))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        isSaving = true
        Task {
            let success = await onSave(
                label,
                requiresApproval,
                usageLimit,
                hasExpiry ? ISO8601DateFormatter().string(from: expiryDate) : ""
            )
            isSaving = false
            if success { dismiss() }
        }
    }
}

private struct GroupInviteStatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AloAppModel

    let roomId: Int
    let invite: AloGroupInviteLink

    @State private var stats: AloGroupInviteStats?
    @State private var isLoading = true
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(invite.label.ifBlank("Ссылка без названия"))
                            .font(.headline)
                        Text("Вступили: \(stats?.joined.count ?? invite.joinedCount) · ожидают: \(stats?.pending.count ?? invite.pendingCount)")
                            .font(.subheadline)
                            .foregroundStyle(AloTheme.muted)
                        if let creatorName = invite.creator?.name, !creatorName.isEmpty {
                            Text("Создал: \(creatorName)")
                                .font(.footnote)
                                .foregroundStyle(AloTheme.muted)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                } else if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                        Button("Повторить") { load() }
                    }
                } else if let stats {
                    participantSection("Вступили", participants: stats.joined)
                    participantSection("Ожидают одобрения", participants: stats.pending)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AloTheme.background)
            .navigationTitle("Статистика ссылки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .task { load() }
            .refreshable { await reload() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func participantSection(
        _ title: String,
        participants: [AloGroupInviteParticipant]
    ) -> some View {
        Section(title) {
            if participants.isEmpty {
                Text("Пока никого")
                    .foregroundStyle(AloTheme.muted)
            } else {
                ForEach(participants) { participant in
                    HStack(spacing: 12) {
                        AloAvatar(
                            name: participant.user.name,
                            url: participant.user.avatarUrl,
                            size: 40,
                            colorSeed: String(participant.user.id)
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(participant.user.name)
                                .font(.system(size: 15, weight: .semibold))
                            HStack(spacing: 6) {
                                if !participant.user.username.isEmpty {
                                    Text(participant.user.username.withAtPrefix)
                                }
                                Text(AloFormatters.messageDateLabel(participant.createdAt))
                            }
                            .font(.caption)
                            .foregroundStyle(AloTheme.muted)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func load() {
        Task { await reload() }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        errorMessage = ""
        do {
            stats = try await app.api.loadGroupInviteStats(roomId: roomId, inviteId: invite.id)
        } catch let error as AloAPIError {
            errorMessage = error.message
        } catch {
            errorMessage = "Не удалось загрузить статистику ссылки."
        }
        isLoading = false
    }
}

private struct ChatSafetyNumberSheet: View {
    @Environment(\.dismiss) private var dismiss
    let verification: AloSafetyVerification?
    let isLoading: Bool
    let errorMessage: String
    let onToggleVerified: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if isLoading {
                        ProgressView()
                            .tint(AloTheme.accent)
                            .padding(.top, 80)
                    } else if let verification {
                        Image(uiImage: qrImage(verification.qrPayload))
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 210, height: 210)
                            .padding(14)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(spacing: 8) {
                            Label(
                                verification.isVerified ? "Устройство подтверждено" : "Проверьте код",
                                systemImage: verification.isVerified ? "checkmark.shield.fill" : "lock.shield"
                            )
                            .font(.system(size: 19, weight: .heavy, design: .rounded))
                            .foregroundStyle(verification.isVerified ? Color.green : AloTheme.text)

                            Text("Сравните QR-код или цифры с собеседником по другому защищённому каналу.")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AloTheme.muted)
                                .multilineTextAlignment(.center)
                        }

                        Text(verification.decimalCode)
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundStyle(AloTheme.text)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .background(AloTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Устройства собеседника")
                                .font(.system(size: 17, weight: .heavy, design: .rounded))
                            ForEach(verification.peerDevices) { device in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.label)
                                        .font(.system(size: 14, weight: .bold))
                                    Text(device.fingerprint)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(AloTheme.muted)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(AloTheme.surface.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        Button {
                            onToggleVerified(!verification.isVerified)
                        } label: {
                            Text(verification.isVerified ? "Снять подтверждение" : "Коды совпадают")
                                .font(.system(size: 16, weight: .heavy, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(verification.isVerified ? AloTheme.surfaceRaised : AloTheme.accent)
                    } else {
                        ContentUnavailableView(
                            "Данные недоступны",
                            systemImage: "lock.trianglebadge.exclamationmark",
                            description: Text(errorMessage)
                        )
                        .padding(.top, 60)
                    }
                }
                .padding(20)
            }
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Шифрование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func qrImage(_ value: String) -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)),
              let image = CIContext().createCGImage(output, from: output.extent) else {
            return UIImage()
        }
        return UIImage(cgImage: image)
    }
}

private struct PeerActionButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PeerActionButtonLabel(title: title, systemName: systemName)
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.90))
    }
}

private struct PeerCompactActionButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let systemName: String
    var tint: Color = AloTheme.accent
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Image(systemName: systemName)
                        .font(.system(size: 20, weight: .medium))
                        .opacity(isLoading ? 0 : 1)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    if isLoading { ProgressView().tint(tint) }
                }
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 24)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 58)
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(AloControlPressStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
    }
}

private struct PeerActionButtonLabel: View {
    let title: String
    let systemName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .frame(width: 24)
            Text(title)
                .font(.system(size: 16, weight: .bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(AloTheme.text)
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(AloTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AloTheme.border, lineWidth: 1)
        )
    }
}

private enum PeerMediaTab: String, CaseIterable, Identifiable {
    case photos
    case videos
    case voices
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "Фото"
        case .videos: return "Видео"
        case .voices: return "ГС"
        case .files: return "Файлы"
        }
    }

    var emptyTitle: String {
        switch self {
        case .photos: return "Фотографий пока нет"
        case .videos: return "Видео пока нет"
        case .voices: return "Голосовых пока нет"
        case .files: return "Файлов пока нет"
        }
    }

    var emptySubtitle: String {
        switch self {
        case .photos: return "Когда в чате появятся изображения, они будут здесь."
        case .videos: return "Видео из переписки появятся в этом разделе."
        case .voices: return "Голосовые и кружки будут собраны здесь."
        case .files: return "Документы и остальные файлы будут здесь."
        }
    }

    var channelEmptySubtitle: String {
        switch self {
        case .photos: return "Опубликованные в канале изображения будут здесь."
        case .videos: return "Видео из публикаций канала появятся в этом разделе."
        case .voices: return "Голосовые публикации и кружки канала будут собраны здесь."
        case .files: return "Документы и остальные файлы канала будут здесь."
        }
    }

    func matches(_ attachment: AloMessageAttachment) -> Bool {
        let type = attachment.type.lowercased()
        let url = attachment.url.lowercased()
        switch self {
        case .photos:
            return type == "image" || url.hasImageExtension
        case .videos:
            return type == "video" || url.hasVideoExtension
        case .voices:
            return type == "audio" || type == "voice" || type == "circle" || url.hasSuffix(".m4a") || url.hasSuffix(".aac") || url.hasSuffix(".mp3")
        case .files:
            return !PeerMediaTab.photos.matches(attachment) &&
                !PeerMediaTab.videos.matches(attachment) &&
                !PeerMediaTab.voices.matches(attachment)
        }
    }
}

private struct ChatCallScreen: View {
    let kind: ChatCallKind
    let conversation: AloConversationDetail
    let onMinimize: () -> Void
    let onEnd: () -> Void

    @State private var isMuted = false
    @State private var isCameraOff = false
    @State private var isSpeakerOn = true
    @State private var startedAt = Date()
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AloTheme.background,
                    Color(red: 0.035, green: 0.07, blue: 0.13),
                    AloTheme.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .frame(height: 18)
                    .accessibilityLabel("Свернуть звонок")
                Spacer(minLength: 22)
                AloAvatar(
                    name: conversation.title,
                    url: conversation.avatarUrl,
                    size: 112,
                    colorSeed: String(conversation.peerId)
                )
                VStack(spacing: 6) {
                    Text(conversation.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(AloTheme.text)
                        .lineLimit(1)
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("\(kind.title) · \(callTime(context.date.timeIntervalSince(startedAt)))")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AloTheme.muted)
                            .monospacedDigit()
                    }
                }

                if kind == .video {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(AloTheme.surface)
                        .overlay {
                            VStack(spacing: 10) {
                                Image(systemName: isCameraOff ? "video.slash.fill" : "video.fill")
                                    .font(.system(size: 36, weight: .bold))
                                Text(isCameraOff ? "Камера выключена" : "Видео готово")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .foregroundStyle(AloTheme.muted)
                        }
                        .frame(height: 240)
                        .padding(.horizontal, 18)
                }

                Spacer()

                HStack(spacing: 16) {
                    CallControlButton(systemName: isMuted ? "mic.slash.fill" : "mic.fill", title: "Микрофон", isActive: !isMuted) {
                        isMuted.toggle()
                    }
                    if kind == .video {
                        CallControlButton(systemName: isCameraOff ? "video.slash.fill" : "video.fill", title: "Камера", isActive: !isCameraOff) {
                            isCameraOff.toggle()
                        }
                    }
                    CallControlButton(systemName: isSpeakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill", title: "Звук", isActive: isSpeakerOn) {
                        isSpeakerOn.toggle()
                    }
                    CallControlButton(systemName: "phone.down.fill", title: "Завершить", isDestructive: true, isActive: true, action: onEnd)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 26)
            }
        }
        .offset(y: dragOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    dragOffset = min(0, value.translation.height)
                }
                .onEnded { value in
                    if value.translation.height < -72 || value.predictedEndTranslation.height < -110 {
                        AloHaptics.impact(.medium)
                        onMinimize()
                    }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        dragOffset = 0
                    }
                }
        )
        .onAppear { startedAt = Date() }
    }

    private func callTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ChatCallMinimizedPill: View {
    let kind: ChatCallKind
    let conversation: AloConversationDetail
    let onExpand: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onExpand) {
                    HStack(spacing: 10) {
                        AloAvatar(
                            name: conversation.title,
                            url: conversation.avatarUrl,
                            size: 38,
                            colorSeed: String(conversation.peerId)
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AloTheme.text)
                                .lineLimit(1)
                            Text("\(kind.title) · нажмите, чтобы открыть")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AloTheme.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.97))

                Button(action: onEnd) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 38)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.88))
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(AloTheme.border.opacity(0.7), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CallControlButton: View {
    let systemName: String
    let title: String
    var isDestructive = false
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 58, height: 58)
                    .background(isDestructive ? Color.red : (isActive ? AloTheme.surfaceRaised : AloTheme.surface))
                    .foregroundStyle(isDestructive ? Color.white : AloTheme.text)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(AloTheme.border, lineWidth: 1))
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AloTheme.muted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct AloRecordingLevelsView<Content: View>: View {
    @ObservedObject var recorder: ChatAudioRecorder
    @ViewBuilder let content: ([CGFloat]) -> Content

    var body: some View { content(recorder.levels) }
}

private final class ChatAudioRecorder: NSObject, ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var levels: [CGFloat] = []

    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    private var meterTimer: Timer?
    private var requestID = UUID()

    func start(onReady: @escaping (String?) -> Void) {
        let id = UUID()
        requestID = id
        Task { @MainActor in
            let granted = await requestPermission()
            guard requestID == id else { return }
            guard granted else {
                onReady("Разрешите Alo доступ к микрофону в настройках iPhone.")
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
                try session.setActive(true)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("alo-voice-\(UUID().uuidString).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                outputURL = url
                recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder?.isMeteringEnabled = true
                guard recorder?.record() == true else {
                    cancel()
                    onReady("Не удалось начать запись с микрофона.")
                    return
                }
                updateLevels([])
                startMetering()
                onReady(nil)
            } catch {
                stopMetering(clearLevels: true)
                recorder = nil
                outputURL = nil
                onReady("Не удалось запустить микрофон. Повторите попытку.")
            }
        }
    }

    func stop(completion: @escaping (AloLocalAttachment?, [CGFloat]) -> Void) {
        requestID = UUID()
        let id = requestID
        stopMetering(clearLevels: false)
        let duration = recorder?.currentTime
        recorder?.stop()
        recorder = nil
        guard let outputURL else {
            completion(nil, [])
            return
        }
        self.outputURL = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let waveform = AloAudioWaveformAnalysis.samples(from: outputURL, count: 28)
            let attachment = try? AloDraftAttachmentStore.makeRecordedVoice(
                sourceURL: outputURL, waveform: waveform, durationSeconds: duration)
            try? FileManager.default.removeItem(at: outputURL)
            let deliver = await MainActor.run { [weak self] in
                guard let self, self.requestID == id else { return false }
                completion(attachment, waveform)
                return true
            }
            if !deliver, let attachment { AloDraftAttachmentStore.discard(attachment) }
        }
    }

    func cancel() {
        requestID = UUID()
        stopMetering(clearLevels: true)
        recorder?.stop()
        recorder = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    private func startMetering() {
        stopMetering(clearLevels: false)
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            recorder.updateMeters()
            let average = recorder.averagePower(forChannel: 0)
            let peak = recorder.peakPower(forChannel: 0)
            let power = max(average, peak - 8)
            let normalized = pow(10, power / 34)
            let level = CGFloat(max(0.10, min(1, normalized)))
            self.updateLevels(Array((self.levels + [level]).suffix(28)))
        }
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMetering(clearLevels: Bool) {
        meterTimer?.invalidate()
        meterTimer = nil
        if clearLevels {
            updateLevels([])
        }
    }

    private func updateLevels(_ nextLevels: [CGFloat]) {
        objectWillChange.send()
        levels = nextLevels
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}


private struct CircleCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var mirrored = true
    var transitioning = false

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
        uiView.setTransitioning(transitioning)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let connection = uiView.previewLayer.connection {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
    }

    final class PreviewView: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        private let frost = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        private var transitioning = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(previewLayer)
            frost.alpha = 0
            frost.isUserInteractionEnabled = false
            frost.accessibilityElementsHidden = true
            addSubview(frost)
        }
        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
            frost.frame = bounds
        }

        func setTransitioning(_ value: Bool) {
            guard transitioning != value else { return }
            transitioning = value
            // Public UIKit material masks the lens handoff; no animated mirror
            // through zero width and no snapshot of the camera or second session.
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.1 : 0.2,
                           delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
                self.frost.alpha = value ? 1 : 0
            }
        }
    }
}

struct CircleVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) {
        uiView.playerLayer.player = nil
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
            layer.masksToBounds = true
        }
    }
}

private extension Notification.Name {
    static let aloMediaPlaybackDidStart = Notification.Name("aloMediaPlaybackDidStart")
    static let aloVoicePlaybackDidStart = Notification.Name("aloVoicePlaybackDidStart")
    static let aloVoicePlaybackDidStop = Notification.Name("aloVoicePlaybackDidStop")
    static let aloVoicePlaybackToggleRequested = Notification.Name("aloVoicePlaybackToggleRequested")
    static let aloVoicePlaybackStopRequested = Notification.Name("aloVoicePlaybackStopRequested")
    static let aloVoicePlaybackSpeedChanged = Notification.Name("aloVoicePlaybackSpeedChanged")
}

@MainActor enum AloHaptics {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static var impacts: [Int: UIImpactFeedbackGenerator] = [:]

    static func prepare() {
        let generator = impacts[UIImpactFeedbackGenerator.FeedbackStyle.medium.rawValue] ?? UIImpactFeedbackGenerator(style: .medium)
        impacts[UIImpactFeedbackGenerator.FeedbackStyle.medium.rawValue] = generator
        generator.prepare()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = impacts[style.rawValue] ?? UIImpactFeedbackGenerator(style: style)
        impacts[style.rawValue] = generator
        generator.impactOccurred()
        generator.prepare()
    }

    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notificationGenerator.notificationOccurred(type)
        notificationGenerator.prepare()
    }
}

private extension AloLocalAttachment {
    var isLocalVoiceLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "audio" ||
            normalizedType == "voice" ||
            normalizedName.hasPrefix("voice-") ||
            normalizedName.hasSuffix(".m4a") ||
            normalizedName.hasSuffix(".aac") ||
            normalizedName.hasSuffix(".mp3")
    }

    var isLocalCircleLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "circle" || normalizedName.hasPrefix("circle-")
    }

    var isRecordedDraft: Bool {
        isLocalVoiceLike || isLocalCircleLike
    }
}

private extension String {
    var hasImageExtension: Bool {
        hasSuffix(".jpg") || hasSuffix(".jpeg") || hasSuffix(".png") || hasSuffix(".webp") || hasSuffix(".gif") || hasSuffix(".avif")
    }

    var hasVideoExtension: Bool {
        hasSuffix(".mp4") || hasSuffix(".mov") || hasSuffix(".m4v") || hasSuffix(".webm")
    }
}

private extension AloMessageAttachment {
    var isVoiceLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedURL = url.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "audio" ||
            normalizedType == "voice" ||
            normalizedName.hasPrefix("voice-") ||
            normalizedURL.hasSuffix(".m4a") ||
            normalizedURL.hasSuffix(".aac") ||
            normalizedURL.hasSuffix(".mp3") ||
            normalizedURL.hasSuffix(".wav")
    }

    var isCircleLike: Bool {
        let normalizedType = type.lowercased()
        let normalizedName = name.lowercased()
        return normalizedType == "circle" ||
            normalizedName.hasPrefix("circle-") ||
            normalizedName.contains("video-circle") ||
            normalizedName.contains("circle-video") ||
            normalizedName.contains("video-note")
    }

    var isVisualMedia: Bool {
        let normalizedType = type.lowercased()
        let normalizedURL = url.lowercased()
        return !isVoiceLike &&
            !isCircleLike &&
            (normalizedType == "image" ||
                normalizedType == "video" ||
                normalizedURL.hasImageExtension ||
                normalizedURL.hasVideoExtension)
    }

    var chatMediaItem: AloMediaItem {
        let normalizedType = type.lowercased()
        let inferredType: String
        if normalizedType == "image" || url.lowercased().hasImageExtension {
            inferredType = "image"
        } else if normalizedType == "video" || url.lowercased().hasVideoExtension {
            inferredType = "video"
        } else {
            inferredType = normalizedType.ifBlank("file")
        }
        return AloMediaItem(
            type: inferredType,
            url: url,
            posterUrl: posterUrl,
            caption: name
        )
    }
}

private struct ChatMessageFramePreferenceKey: PreferenceKey {
    static var defaultValue = [Int: CGRect]()

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct ChatBottomAnchorFramePreferenceKey: PreferenceKey {
    static var defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ChatComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private typealias ChatDatePill = AloChatDatePill

enum AloSquareImage {
    /// Centre square of an image, drawn once (used for round video-message posters).
    static func centerCrop(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        guard side > 0, image.size.width != image.size.height else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(at: CGPoint(x: (side - image.size.width) / 2, y: (side - image.size.height) / 2))
        }
    }
}
