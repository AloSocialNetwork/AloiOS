import SwiftUI

/// Checkmarks (the same as the website, ~/alo/web/js/views/settings-pages.js and moderation.js): a person asks for one for
/// their page (settings → profile), staff with the «Верификация» right review the requests in «Модерация → Галочки»,
/// and may also give or take one straight from a profile's «⋯» without any request. A pending request of the same
/// page is closed with the same outcome. Server: `POST /api/verification/request`, `GET /api/verification/mine`,
/// `GET /api/admin/verification`, `POST /api/admin/verification/:id/review`, `POST /api/admin/verified`.
struct AloVerificationRequest: Identifiable, Equatable {
    let id: Int
    let requesterId: Int
    let requesterName: String
    let requesterUsername: String
    let targetType: String
    let targetId: Int
    let targetTitle: String
    let note: String
    let status: String
    let reviewedNote: String
    let createdAt: String

    init(_ json: [String: Any]) {
        id = json.int("id")
        let requester = json.object("requester")
        requesterId = requester.int("id")
        requesterName = requester.string("name")
        requesterUsername = requester.string("username")
        targetType = json.string("targetType")
        targetId = json.int("targetId")
        targetTitle = json.string("targetTitle")
        note = json.string("note")
        status = json.string("status").ifBlank("pending")
        reviewedNote = json.string("reviewedNote")
        createdAt = json.string("createdAt")
    }
}

extension AloAPIClient {
    func requestVerification(targetType: String, targetId: Int, note: String) async throws {
        _ = try await request("POST", "/api/verification/request", body: ["targetType": targetType, "targetId": targetId, "note": note])
    }

    func myVerificationRequests() async throws -> [AloVerificationRequest] {
        try await request("GET", "/api/verification/mine").array("requests").map(AloVerificationRequest.init)
    }

    func verificationQueue(status: String) async throws -> [AloVerificationRequest] {
        try await request("GET", "/api/admin/verification?status=\(status)&limit=100").array("requests").map(AloVerificationRequest.init)
    }

    func reviewVerification(id: Int, approve: Bool, note: String) async throws {
        _ = try await request("POST", "/api/admin/verification/\(id)/review", body: ["status": approve ? "approved" : "rejected", "note": note])
    }

    /// Staff: give or take the checkmark with no request.
    func setVerified(targetType: String, targetId: Int, verified: Bool) async throws {
        _ = try await request("POST", "/api/admin/verified", body: ["targetType": targetType, "targetId": targetId, "verified": verified])
    }
}

/// Settings → profile: what the page has, and the request for a checkmark.
struct AloOwnVerificationCard: View {
    @EnvironmentObject private var app: AloAppModel
    let verified: Bool
    @State private var request: AloVerificationRequest?
    @State private var isAsking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Галочка")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
                .padding(.leading, 2)
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(verified ? AloTheme.accent : AloTheme.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(AloTheme.muted)
                }
                Spacer(minLength: 8)
                if !verified, request?.status != "pending" {
                    Button(request?.status == "rejected" ? "Подать снова" : "Подать заявку") { isAsking = true }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AloTheme.accent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("alo.settings.checkmark.request")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .task { await reload() }
        .sheet(isPresented: $isAsking) {
            AloVerificationRequestSheet(targetType: "user", targetId: app.bootstrap?.me.id ?? 0, title: "") {
                Task { await reload() }
            }
        }
    }

    private var title: String {
        if verified { return "Страница подтверждена" }
        switch request?.status {
        case "pending": return "Заявка на рассмотрении"
        case "rejected": return "Заявка отклонена"
        default: return "Подтверждённая страница"
        }
    }

    private var subtitle: String {
        if verified { return "Рядом с вашим именем стоит галочка." }
        switch request?.status {
        case "pending": return "Ответ придёт в уведомлениях."
        case "rejected": return request?.reviewedNote.isEmpty == false ? "Причина: \(request!.reviewedNote)" : "Можно подать заявку ещё раз."
        default: return "Галочка показывает, что страница принадлежит именно вам."
        }
    }

    private func reload() async {
        let me = app.bootstrap?.me.id ?? 0
        request = (try? await app.api.myVerificationRequests())?.first { $0.targetType == "user" && $0.targetId == me }
    }
}

/// «Заявка на галочку»: why the page (or community) should get one.
struct AloVerificationRequestSheet: View {
    @EnvironmentObject private var app: AloAppModel
    @Environment(\.dismiss) private var dismiss
    let targetType: String
    let targetId: Int
    let title: String
    var onSent: () -> Void = {}
    @State private var note = ""
    @State private var error = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(targetType == "channel"
                     ? "Галочка подтверждает, что сообщество «\(title)» — официальное. Расскажите модераторам, кто вы, и дайте ссылки, если есть."
                     : "Галочка показывает, что страница принадлежит именно вам. Расскажите модераторам, кто вы, и дайте ссылки, если есть.")
                    .font(.system(size: 15))
                    .foregroundStyle(AloTheme.muted)
                TextField("Например: я автор канала на YouTube, ссылка…", text: $note, axis: .vertical)
                    .lineLimit(4...8)
                    .padding(14)
                    .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onChange(of: note) { _, value in if value.count > 500 { note = String(value.prefix(500)) } }
                    .accessibilityIdentifier("alo.checkmark.note")
                if !error.isEmpty {
                    Text(error).font(.system(size: 14)).foregroundStyle(AloTheme.destructive)
                }
                AloPrimaryButton(title: isSending ? "Отправка…" : "Отправить заявку",
                                 disabled: isSending || note.trimmingCharacters(in: .whitespacesAndNewlines).count < 3) {
                    Task { await send() }
                }
                .accessibilityIdentifier("alo.checkmark.send")
                Spacer()
            }
            .padding(20)
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Заявка на галочку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        do {
            try await app.api.requestVerification(targetType: targetType, targetId: targetId,
                                                  note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            app.notice = "Заявка отправлена. Ответ придёт в уведомлениях."
            onSent()
            dismiss()
        } catch let failure as AloAPIError {
            error = failure.message
        } catch {
            self.error = "Не удалось отправить заявку. Проверьте подключение."
        }
    }
}

/// «Модерация → Галочки»: requests waiting for a decision, and the ones already decided.
struct AloVerificationQueue: View {
    @EnvironmentObject private var app: AloAppModel
    var onCount: (Int) -> Void = { _ in }
    @State private var status = "pending"
    @State private var items = [AloVerificationRequest]()
    @State private var isLoading = true
    @State private var error = ""
    @State private var rejecting: AloVerificationRequest?
    @State private var rejectNote = ""
    @State private var busy = Set<Int>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Заявки", selection: $status) {
                    Text("Ожидают").tag("pending")
                    Text("Одобрены").tag("approved")
                    Text("Отклонены").tag("rejected")
                }
                .pickerStyle(.segmented)
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
                } else if !error.isEmpty {
                    Text(error).font(.system(size: 15)).foregroundStyle(AloTheme.muted)
                } else if items.isEmpty {
                    Text(status == "pending" ? "Новых заявок на галочку нет." : "Ничего с таким исходом.")
                        .font(.system(size: 15)).foregroundStyle(AloTheme.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 32)
                } else {
                    ForEach(items) { item in row(item) }
                }
            }
            .padding(.horizontal, AloSocialMetrics.inset)
            .padding(.vertical, 12)
        }
        .background(AloTheme.background.ignoresSafeArea())
        .navigationTitle("Галочки")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: status) { await load() }
        .refreshable { await load() }
        .alert("Отклонить заявку?", isPresented: Binding(get: { rejecting != nil }, set: { if !$0 { rejecting = nil } })) {
            TextField("Причина (её увидит автор)", text: $rejectNote)
            Button("Отклонить", role: .destructive) {
                if let rejecting { Task { await decide(rejecting, approve: false, note: rejectNote) } }
            }
            Button("Отмена", role: .cancel) { rejecting = nil }
        }
    }

    private func row(_ item: AloVerificationRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.targetType == "channel" ? "megaphone.fill" : "person.fill")
                    .foregroundStyle(AloTheme.accent)
                Text(item.targetTitle.ifBlank(item.requesterName))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(AloTheme.text)
                Spacer(minLength: 0)
                Text(AloPostTimestamp.string(item.createdAt)).font(.system(size: 13)).foregroundStyle(AloTheme.muted)
            }
            Text(item.targetType == "channel" ? "Сообщество · заявка от \(item.requesterName)" : "Страница \(item.requesterUsername.isEmpty ? item.requesterName : "@\(item.requesterUsername)")")
                .font(.system(size: 13)).foregroundStyle(AloTheme.muted)
            if !item.note.isEmpty {
                Text(item.note).font(.system(size: 15)).foregroundStyle(AloTheme.text)
            }
            if item.status == "pending" {
                HStack(spacing: 10) {
                    Button { Task { await decide(item, approve: true, note: "") } } label: {
                        Label("Выдать галочку", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(AloTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityIdentifier("alo.checkmark.approve.\(item.id)")
                    Button { rejectNote = ""; rejecting = item } label: {
                        Text("Отклонить")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(AloTheme.destructive)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(AloTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityIdentifier("alo.checkmark.reject.\(item.id)")
                }
                .disabled(busy.contains(item.id))
            } else if !item.reviewedNote.isEmpty {
                Text("Решение: \(item.reviewedNote)").font(.system(size: 13)).foregroundStyle(AloTheme.muted)
            }
        }
        .padding(14)
        .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func load() async {
        isLoading = items.isEmpty
        do {
            items = try await app.api.verificationQueue(status: status)
            error = ""
            if status == "pending" { onCount(items.count) }
        } catch let failure as AloAPIError {
            error = failure.message
        } catch {
            self.error = "Не удалось загрузить заявки."
        }
        isLoading = false
    }

    private func decide(_ item: AloVerificationRequest, approve: Bool, note: String) async {
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        do {
            try await app.api.reviewVerification(id: item.id, approve: approve, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            app.notice = approve ? "Галочка выдана" : "Заявка отклонена"
            rejecting = nil
            await load()
        } catch let failure as AloAPIError {
            app.notice = failure.message
        } catch {
            app.notice = "Не удалось сохранить решение."
        }
    }
}
