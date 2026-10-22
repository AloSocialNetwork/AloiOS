import SwiftUI

struct AloPublicationStatusView: View {
    @EnvironmentObject private var app: AloAppModel
    var kind: AloPublicationJob.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !app.publications.restorationError.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(app.publications.restorationError).font(.footnote).foregroundStyle(AloTheme.destructive)
                    Button("Повторить восстановление") {
                        if let owner = app.bootstrap?.me.id { app.publications.activate(owner: owner) }
                    }.font(.footnote).frame(minHeight: 44)
                }.padding(12)
            }
            ForEach(app.publicationJobs.filter { kind == nil || $0.kind == kind }) { job in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(job.kind == .post ? "Публикация поста" : "Публикация истории").font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        if job.status == .failed && !job.missingAttachments {
                            Button("Повторить") { app.publications.retry(id: job.id) }
                                .font(.subheadline).frame(minHeight: 44)
                        }
                    }
                    if !job.body.isEmpty { Text(job.body).font(.caption).lineLimit(2) }
                    Text(job.label).font(.caption).foregroundStyle(job.status == .failed ? AloTheme.destructive : AloTheme.muted)
                    if job.isDurable && job.status != .failed {
                        Text("Можно закрыть редактор — отправка сохранена на этом устройстве.")
                            .font(.caption).foregroundStyle(AloTheme.muted)
                    }
                    if job.status == .uploading { ProgressView(value: job.progress).tint(AloTheme.accent) }
                    else if job.status == .queued || job.status == .publishing { ProgressView().controlSize(.small) }
                    if job.status == .failed {
                        HStack {
                            Button("Скопировать текст") { UIPasteboard.general.string = job.body }
                            Spacer()
                            Button("Удалить из очереди", role: .destructive) { app.publications.remove(id: job.id) }
                        }.font(.caption).frame(minHeight: 44)
                    }
                }
                .padding(12)
                .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("publication.\(job.id)")
            }
        }
    }
}

struct AloPushFriendRequestSheet: View {
    @EnvironmentObject private var app: AloAppModel
    let item: AloNotificationItem
    var body: some View {
        VStack(spacing: 18) {
            AloAvatar(name: item.actor?.name ?? "Пользователь", url: item.actor?.avatarUrl ?? "", size: 72)
            Text(item.actor?.name ?? "Заявка в друзья").font(.title2.bold())
            Text("Хочет добавить вас в друзья").foregroundStyle(AloTheme.muted)
            HStack(spacing: 14) {
                Button("Принять") { app.respondFriendRequest(item, accept: true); app.pushFriendRequest = nil }
                    .buttonStyle(.borderedProminent)
                Button("Отклонить", role: .destructive) { app.respondFriendRequest(item, accept: false); app.pushFriendRequest = nil }
                    .buttonStyle(.bordered)
            }.frame(minHeight: 44)
            Button("Закрыть") { app.pushFriendRequest = nil }.frame(minHeight: 44)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AloTheme.background).foregroundStyle(AloTheme.text)
        .presentationDetents([.medium])
    }
}
