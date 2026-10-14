import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import Vision
import VisionKit

struct AloAccountSecurityControls: View {
    @EnvironmentObject private var app: AloAppModel
    @State private var passkeyStatus: AloPasskeyStatus?
    @State private var passkeyMessage = ""
    @State private var exportFile: AloDataExportFile?
    @State private var exportMessage = ""
    @State private var isLoadingPasskey = true
    @State private var isWorking = false
    @State private var isQRApprovalPresented = false
    @State private var isDeviceLinkShowPresented = false
    @State private var isExportPresented = false
    @State private var isDeletionPresented = false

    var body: some View {
        VStack(spacing: 22) {
            accountCard
            passkeyCard
            qrCard
            exportCard
            deletionCard
        }
        .task {
            await refreshPasskeyStatus()
        }
        .sheet(isPresented: $isDeviceLinkShowPresented) {
            AloDeviceLinkShowSheet()
                .environmentObject(app)
        }
        .sheet(isPresented: $isQRApprovalPresented) {
            AloQRCodeApprovalSheet()
                .environmentObject(app)
        }
        .sheet(isPresented: $isExportPresented) {
            AloAccountExportSheet { file in
                exportFile = file
                exportMessage = "Архив подготовлен. Выберите, куда его сохранить."
            }
            .environmentObject(app)
        }
        .sheet(isPresented: $isDeletionPresented) {
            AloAccountDeletionConfirmationSheet()
                .environmentObject(app)
        }
    }

    private var accountCard: some View {
        AloSecurityCard(title: "Аккаунты на устройстве") {
            let accounts = app.storedAccounts
            if accounts.isEmpty {
                Text("Сеанс появится здесь после безопасного сохранения входа.")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(AloTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
            } else {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    AloStoredAccountRow(
                        account: account,
                        isCurrent: account.userId == app.bootstrap?.me.id,
                        action: { app.switchToStoredAccount(account) }
                    )
                    if index < accounts.count - 1 {
                        AloSecurityDivider()
                    }
                }
            }
            AloSecurityDivider()
            Button {
                app.addAnotherAccount()
            } label: {
                AloSecurityRow(
                    title: "Добавить аккаунт",
                    subtitle: "Войти в другой аккаунт без выхода из текущего",
                    icon: "plus.circle",
                    tint: AloTheme.accent,
                    showsChevron: true
                )
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
            .accessibilityHint("Открыть обычный вход для другого аккаунта")
        }
    }

    private var passkeyCard: some View {
        AloSecurityCard(title: "Ключ доступа") {
            if isLoadingPasskey {
                HStack(spacing: 10) {
                    ProgressView().tint(AloTheme.accent)
                    Text("Проверяем ключи доступа…")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(AloTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
            } else if let passkeyStatus {
                AloSecurityRow(
                    title: passkeyStatus.configured ? "Ключ доступа настроен" : "Ключ доступа не настроен",
                    subtitle: passkeySubtitle(passkeyStatus),
                    icon: "key.fill",
                    tint: AloTheme.accent,
                    trailing: passkeyStatus.configured ? "Готово" : nil
                )
                AloSecurityDivider()
                Button {
                    registerPasskey()
                } label: {
                    HStack(spacing: 8) {
                        if isWorking {
                            ProgressView().tint(AloTheme.accent)
                        }
                        Text(passkeyStatus.configured ? "Добавить ещё один ключ" : "Настроить ключ доступа")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AloTheme.accent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking || !AloPasskeyCoordinator.isSystemAvailable)
                .accessibilityHint("Откроется системное подтверждение Face ID, Touch ID или кодом устройства")
            } else {
                AloSecurityRow(
                    title: "Ключ доступа недоступен",
                    subtitle: passkeyMessage.ifBlank("Сервер ещё не включил поддержку ключей доступа."),
                    icon: "key.fill",
                    tint: AloTheme.muted,
                    showsChevron: false
                )
            }

            if !passkeyMessage.isEmpty, passkeyStatus != nil {
                AloSecurityDivider()
                Text(passkeyMessage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AloTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
        }
    }

    private var qrCard: some View {
        AloSecurityCard(title: "Вход с другого устройства") {
            Button {
                isQRApprovalPresented = true
            } label: {
                AloSecurityRow(
                    title: "Подтвердить вход по QR-коду",
                    subtitle: "Сканируйте код, показанный на устройстве, где выполняется вход",
                    icon: "qrcode.viewfinder",
                    tint: AloTheme.accent,
                    showsChevron: true
                )
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
            .accessibilityHint("Открыть системный сканер QR-кода")
            Button {
                isDeviceLinkShowPresented = true
            } label: {
                AloSecurityRow(
                    title: "Показать QR для входа",
                    subtitle: "Новое устройство отсканирует его, а вы подтвердите вход здесь",
                    icon: "qrcode",
                    tint: AloTheme.accent,
                    showsChevron: true
                )
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
            .accessibilityIdentifier("alo.device-link.show-entry")
        }
    }

    private var exportCard: some View {
        AloSecurityCard(title: "Ваши данные") {
            Button {
                isExportPresented = true
            } label: {
                AloSecurityRow(
                    title: "Экспортировать данные",
                    subtitle: exportSubtitle,
                    icon: "arrow.down.doc",
                    tint: AloTheme.accent,
                    showsChevron: true
                )
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
            .disabled(isWorking)
            .accessibilityHint("Подтвердить пароль и скачать архив данных")

            if let exportFile {
                AloSecurityDivider()
                ShareLink(item: exportFile.fileURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Сохранить или отправить JSON")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(AloTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityHint("Открыть системное меню сохранения или отправки файла \(exportFile.fileName)")
            }
        }
    }

    private var deletionCard: some View {
        AloSecurityCard(title: "Опасная зона") {
            Button(role: .destructive) {
                isDeletionPresented = true
            } label: {
                AloSecurityRow(
                    title: "Удалить аккаунт",
                    subtitle: "Необратимо удалить профиль и данные после подтверждения",
                    icon: "trash",
                    tint: AloTheme.destructive,
                    showsChevron: true
                )
            }
            .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
            .accessibilityHint("Потребуется текущий пароль и явное подтверждение удаления")
        }
    }

    private var exportSubtitle: String {
        if let exportFile {
            return "Готов файл \(exportFile.fileName)"
        }
        return exportMessage.ifBlank("Скачать JSON профиля и контента")
    }

    private func passkeySubtitle(_ status: AloPasskeyStatus) -> String {
        if status.configured {
            let count = max(1, status.credentialCount)
            return count == 1 ? "1 ключ защищает этот аккаунт" : "\(count) ключа защищают этот аккаунт"
        }
        return "Используйте Face ID, Touch ID или код устройства вместо пароля"
    }

    private func refreshPasskeyStatus() async {
        isLoadingPasskey = true
        defer { isLoadingPasskey = false }
        do {
            passkeyStatus = try await app.api.loadPasskeyStatus()
            passkeyMessage = ""
        } catch let error as AloAPIError {
            passkeyStatus = nil
            passkeyMessage = error.status == 404 || error.status == 501
                ? "Сервер ещё не включил поддержку ключей доступа."
                : error.message
        } catch {
            passkeyStatus = nil
            passkeyMessage = "Не удалось проверить ключи доступа."
        }
    }

    private func registerPasskey() {
        guard !isWorking else { return }
        isWorking = true
        passkeyMessage = ""
        Task {
            defer { isWorking = false }
            do {
                passkeyStatus = try await app.registerPasskey()
                passkeyMessage = "Ключ доступа добавлен."
            } catch let error as AloAPIError {
                passkeyMessage = error.status == 404 || error.status == 501
                    ? "Сервер ещё не включил поддержку ключей доступа."
                    : error.message
            } catch {
                passkeyMessage = error.localizedDescription.ifBlank("Не удалось добавить ключ доступа.")
            }
        }
    }

}

struct AloAccountSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AloAppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Сохранённые аккаунты") {
                    ForEach(app.storedAccounts) { account in
                        Button {
                            app.switchToStoredAccount(account)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                AloAccountAvatar(account: account, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(AloTheme.text)
                                    Text(account.username.isEmpty ? "Сохранённый сеанс" : "@\(account.username)")
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundStyle(AloTheme.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AloTheme.muted)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Войти в сохранённый аккаунт без пароля")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AloTheme.background)
            .navigationTitle("Сменить аккаунт")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundStyle(AloTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct AloQRCodeLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AloAppModel
    @StateObject private var flow = AloQRCodeLoginFlow()
    @State private var attempt = 0
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    switch flow.state {
                    case .waiting(let request):
                        AloQRCodeImage(payload: request.payload)
                            .frame(maxWidth: 220)
                            .aspectRatio(1, contentMode: .fit)
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("QR-код для входа в Alo")
                            .accessibilityIdentifier("alo.qr-login.code")
                        Text("На устройстве, где уже открыт Alo, перейдите в настройки аккаунта → «Подтвердить вход по QR-коду» и отсканируйте код.")
                            .font(.body)
                        Text("Код действует 2 минуты. Подтвердите вход только на своём устройстве.")
                            .font(.subheadline)
                            .foregroundStyle(AloTheme.muted)
                        ProgressView("Ожидаем подтверждение…")
                            .accessibilityIdentifier("alo.qr-login.waiting")
                    case .loading:
                        ProgressView("Создаём защищённый QR-код…")
                    case .completing:
                        ProgressView("Завершаем вход…")
                    case .signedIn:
                        Label("Вход подтверждён", systemImage: "checkmark.circle")
                    case .failed(let message):
                        Image(systemName: "qrcode").font(.largeTitle).accessibilityHidden(true)
                        Text(message)
                            .font(.body)
                            .accessibilityFocused($errorFocused)
                            .accessibilityIdentifier("alo.qr-login.error")
                        Button("Создать новый QR-код") { attempt += 1 }
                            .frame(minHeight: 44)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .font(.body.weight(.bold))
                            .accessibilityIdentifier("alo.qr-login.retry")
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(AloTheme.text)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .id(attempt)
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Вход по QR")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                        .foregroundStyle(AloTheme.accent)
                }
            }
        }
        .tint(AloTheme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: flow.state) { _, state in
            if case .failed = state { errorFocused = true } else { errorFocused = false }
        }
        .task(id: attempt) {
            await flow.run(start: { try await app.api.startQRCodeLogin() }, status: { payload in
                try await app.api.loadQRCodeLoginStatus(requestID: payload.requestID, secret: payload.secret)
            }, complete: { payload in
                guard await app.completeQRCodeLogin(requestID: payload.requestID, secret: payload.secret) else {
                    throw AloQRCodeLoginFailure.completion(app.errorMessage.ifBlank("Не удалось завершить вход."))
                }
            })
            if !Task.isCancelled, flow.state == .signedIn { dismiss() }
        }
    }
}

struct AloQRCodeApprovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var app: AloAppModel
    @StateObject private var flow: AloQRCodeApprovalFlow
    @State private var cameraReady = false
    @State private var isCheckingCamera = true
    @State private var cameraAttempt = 0
    @State private var scannerGeneration = 0
    @State private var approvalAttempt = 0
    @State private var approvalRequested = false
    @AccessibilityFocusState private var confirmationFocused: Bool

    init() {
        _flow = StateObject(wrappedValue: AloQRCodeApprovalFlow())
    }

    init(flow: AloQRCodeApprovalFlow) {
        _flow = StateObject(wrappedValue: flow)
    }

    var body: some View {
        NavigationStack {
            Group {
                if cameraReady, flow.state == .scanning {
                    VStack(spacing: 0) {
                        AloQRCodeScanner { scannedValue in
                            flow.scanned(scannedValue)
                        } onError: { flow.scannerFailed($0) }
                            .id(scannerGeneration)
                        Text("Наведите камеру на QR-код входа Alo. После сканирования мы попросим подтвердить вход.")
                            .font(.body)
                            .padding(24)
                    }
                } else if flow.state != .scanning {
                    ScrollView { approvalContent.padding(24) }
                } else if isCheckingCamera {
                    ProgressView("Проверяем доступ к камере…")
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            Image(systemName: "camera.fill").font(.largeTitle).accessibilityHidden(true)
                            Text(DataScannerViewController.isSupported
                                 ? "Для сканирования QR-кода разрешите Alo доступ к камере в настройках iPhone."
                                 : "Системный QR-сканер недоступен на этом устройстве.")
                                .font(.body)
                            if DataScannerViewController.isSupported {
                                Button("Открыть настройки") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                                }
                                .frame(minHeight: 44)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(AloTheme.text)
            .background(AloTheme.background)
            .navigationTitle("Сканировать QR")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                        .foregroundStyle(AloTheme.accent)
                }
            }
        }
        .tint(AloTheme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: flow.state) { _, state in
            switch state {
            case .confirming, .failed: confirmationFocused = true
            default: confirmationFocused = false
            }
        }
        .task(id: cameraAttempt) { await prepareCamera() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !cameraReady, !isCheckingCamera { cameraAttempt += 1 }
        }
        .task(id: approvalAttempt) {
            guard approvalAttempt > 0 else { return }
            defer { approvalRequested = false }
            await flow.confirm { payload in
                try await app.api.approveQRCodeLogin(requestID: payload.requestID, secret: payload.secret)
            }
        }
    }

    private var approvalContent: some View {
        VStack(spacing: 24) {
            switch flow.state {
            case .confirming:
                Image(systemName: "lock.shield").font(.largeTitle).accessibilityHidden(true)
                Text("Подключить новое устройство?").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($confirmationFocused)
                Text("На устройстве с этим QR-кодом будет открыт ваш аккаунт Alo. Подтверждайте вход только на устройстве, которым пользуетесь сами.")
                    .font(.body)
                Button("Подтвердить вход") {
                    guard !approvalRequested else { return }
                    approvalRequested = true
                    approvalAttempt += 1
                }
                    .frame(minHeight: 44)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .font(.body.weight(.bold))
                    .disabled(approvalRequested)
                    .accessibilityIdentifier("alo.qr-approval.confirm")
                Button("Сканировать другой код") { rescan() }.frame(minHeight: 44)
            case .approving:
                ProgressView("Подтверждаем вход…")
            case .approved:
                Label("Вход подтверждён", systemImage: "checkmark.circle").font(.title2)
                Text("Другое устройство теперь может открыть ваш аккаунт.").font(.body)
                Button("Готово") { dismiss() }.frame(minHeight: 44).buttonStyle(.borderedProminent).controlSize(.large)
            case .failed(let message):
                Text(message).font(.body).accessibilityIdentifier("alo.qr-approval.error")
                    .accessibilityFocused($confirmationFocused)
                Button("Сканировать снова") { rescan() }.frame(minHeight: 44).buttonStyle(.borderedProminent).controlSize(.large)
            case .scanning: EmptyView()
            }
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
    }

    private func rescan() {
        approvalRequested = false
        scannerGeneration += 1
        flow.reset()
        cameraReady = false
        cameraAttempt += 1
    }

    private func prepareCamera() async {
        isCheckingCamera = true
        defer { isCheckingCamera = false }
        guard flow.state == .scanning else { return }
        guard DataScannerViewController.isSupported else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled, granted else { return }
        }
        guard !Task.isCancelled else { return }
        cameraReady = AloQRCodeScanner.isAvailable
    }
}

struct AloQRCodeImage: View {
    let payload: String

    var body: some View {
        if let image = Self.makeImage(payload: payload) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 68, weight: .light))
                .foregroundStyle(AloTheme.muted)
        }
    }

    static func makeImage(payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Four white modules form the quiet zone scanners need, even in dark mode.
        let extent = output.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: .white).cropped(to: extent)
        let transformed = output.composited(over: white)
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct AloAccountExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AloAppModel
    @State private var currentPassword = ""
    @State private var message = ""
    @State private var isExporting = false

    let onExportReady: (AloDataExportFile) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Сервер сформирует JSON-файл прямо сейчас. Введите текущий пароль: это защищает личные данные, если устройство оказалось разблокировано.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(AloTheme.muted)

                SecureField("Текущий пароль", text: $currentPassword)
                    .textContentType(.password)
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(AloTheme.muted)
                }

                Button {
                    exportData()
                } label: {
                    HStack(spacing: 8) {
                        if isExporting { ProgressView().tint(.white) }
                        Text("Скачать JSON")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(AloTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isExporting || currentPassword.isEmpty)

                Spacer()
            }
            .padding(20)
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Экспорт данных")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Отмена") { dismiss() }
                        .foregroundStyle(AloTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func exportData() {
        guard !isExporting else { return }
        isExporting = true
        message = ""
        Task {
            defer {
                currentPassword = ""
                isExporting = false
            }
            do {
                let file = try await app.api.exportAccountData(currentPassword: currentPassword)
                onExportReady(file)
                dismiss()
            } catch let error as AloAPIError {
                message = error.message
            } catch {
                message = "Не удалось скачать архив данных."
            }
        }
    }
}

private struct AloAccountDeletionConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AloAppModel
    @State private var currentPassword = ""
    @State private var confirmation = ""
    @State private var message = ""
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Это действие нельзя отменить. Введите текущий пароль и слово DELETE, чтобы сервер мог подтвердить удаление.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(AloTheme.muted)

                SecureField("Текущий пароль", text: $currentPassword)
                    .textContentType(.password)
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                TextField("Введите DELETE", text: $confirmation)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(AloTheme.muted)
                }

                Button(role: .destructive) {
                    deleteAccount()
                } label: {
                    HStack(spacing: 8) {
                        if isDeleting { ProgressView().tint(.white) }
                        Text("Удалить аккаунт")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(AloTheme.destructive, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isDeleting || currentPassword.isEmpty || confirmation != "DELETE")

                Spacer()
            }
            .padding(20)
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Удалить аккаунт")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Отмена") { dismiss() }
                        .foregroundStyle(AloTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func deleteAccount() {
        guard !isDeleting else { return }
        isDeleting = true
        message = ""
        Task {
            let removed = await app.deleteCurrentAccount(currentPassword: currentPassword)
            currentPassword = ""
            isDeleting = false
            if removed {
                dismiss()
            } else {
                message = app.errorMessage.ifBlank("Не удалось удалить аккаунт.")
            }
        }
    }
}

private struct AloSecurityCard<Content: View>: View {
    let title: String
    private let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AloTheme.muted)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(AloTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct AloSecurityDivider: View {
    var body: some View {
        Rectangle()
            .fill(AloTheme.border.opacity(0.7))
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.leading, 46)
    }
}

private struct AloSecurityRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    var showsChevron = false
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AloTheme.text)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(AloTheme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AloTheme.accent)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AloTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 66)
        .contentShape(Rectangle())
    }
}

private struct AloStoredAccountRow: View {
    let account: AloStoredAccount
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AloAccountAvatar(account: account, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AloTheme.text)
                    Text(account.username.isEmpty ? "Сохранённый сеанс" : "@\(account.username)")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(AloTheme.muted)
                }
                Spacer(minLength: 6)
                if isCurrent {
                    Text("Сейчас")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AloTheme.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AloTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(AloPressBounceButtonStyle(pressedScale: 0.985))
        .disabled(isCurrent)
        .accessibilityHint(isCurrent ? "Текущий аккаунт" : "Переключиться на этот сохранённый аккаунт")
    }
}

private struct AloAccountAvatar: View {
    let account: AloStoredAccount
    let size: CGFloat

    var body: some View {
        Group {
            if let url = URL(string: account.avatarURL),
               !account.avatarURL.isEmpty {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var fallback: some View {
        Text(account.name.prefix(1).uppercased())
            .font(.system(size: size * 0.43, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(AloTheme.accent, in: Circle())
    }
}

struct AloQRCodeScanner: UIViewControllerRepresentable {
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    func makeUIViewController(context: Context) -> AloQRScannerHost {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true
        )
        scanner.delegate = context.coordinator
        return AloQRScannerHost(scanner: scanner, onError: context.coordinator.onError)
    }

    func updateUIViewController(_ uiViewController: AloQRScannerHost, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AloQRScannerHost, coordinator: Coordinator) {
        uiViewController.scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        let onError: (String) -> Void
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onError = onError
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasScanned else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let payload = barcode.payloadStringValue,
                      !payload.isEmpty else {
                    continue
                }
                hasScanned = true
                dataScanner.stopScanning()
                onScan(payload)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            onError("Системный сканер недоступен. Проверьте камеру и разрешение.")
        }
    }
}

/// Start capture only after the scanner is in the visible view hierarchy.
/// This also avoids publishing a failure from makeUIViewController's layout pass.
final class AloQRScannerHost: UIViewController {
    let scanner: DataScannerViewController
    private let onError: (String) -> Void

    init(scanner: DataScannerViewController, onError: @escaping (String) -> Void) {
        self.scanner = scanner
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(scanner)
        view.addSubview(scanner.view)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
            scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        do { try scanner.startScanning() }
        catch { onError("Не удалось запустить системный сканер. Попробуйте сканировать снова.") }
    }

    override func viewWillDisappear(_ animated: Bool) {
        scanner.stopScanning()
        super.viewWillDisappear(animated)
    }
}
