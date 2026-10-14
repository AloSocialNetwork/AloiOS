import SwiftUI
import AVFoundation
import VisionKit

/// Sign-in screen, new device: scan the QR that a signed-in device shows ("Показать QR для входа").
struct AloDeviceLinkScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var app: AloAppModel
    @StateObject private var flow = AloDeviceLinkScanFlow()
    @State private var cameraReady = false
    @State private var isCheckingCamera = true
    @State private var cameraAttempt = 0
    @State private var scanned: String?
    @State private var showsOwnQRCode = false

    var body: some View {
        NavigationStack {
            Group {
                switch flow.state {
                case .scanning:
                    scanningContent
                case .claiming, .waitingForOwner, .completing:
                    progressContent
                case .signedIn:
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(AloTheme.accent)
                        Text("Вход подтверждён").font(.title2.weight(.semibold))
                    }
                case .failed(let message):
                    failureContent(message)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(AloTheme.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("Вход по QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }.foregroundStyle(AloTheme.accent)
                }
            }
        }
        .tint(AloTheme.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsOwnQRCode) { AloQRCodeLoginSheet().environmentObject(app) }
        .task(id: cameraAttempt) { await prepareCamera() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !cameraReady, !isCheckingCamera, flow.state == .scanning { cameraAttempt += 1 }
        }
        .task(id: scanned) {
            guard let raw = scanned else { return }
            await flow.run(raw: raw,
                claim: { try await app.api.claimDeviceLink(requestID: $0.requestID, secret: $0.secret) },
                status: { try await app.api.loadQRCodeLoginStatus(requestID: $0.requestID, secret: $0.secret) },
                complete: { payload in
                    guard await app.completeQRCodeLogin(requestID: payload.requestID, secret: payload.secret) else {
                        throw AloQRCodeLoginFailure.completion(app.errorMessage.ifBlank("Не удалось завершить вход."))
                    }
                })
            if !Task.isCancelled, flow.state == .signedIn { dismiss() }
        }
    }

    private var scanningContent: some View {
        VStack(spacing: 0) {
            if cameraReady {
                AloQRCodeScanner { value in scanned = value } onError: { flow.scannerFailed($0) }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .padding(16)
                    .accessibilityIdentifier("alo.device-link.scanner")
            } else if isCheckingCamera {
                ProgressView("Проверяем доступ к камере…").frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill").font(.system(size: 40)).accessibilityHidden(true)
                    Text(DataScannerViewController.isSupported
                         ? "Для сканирования QR-кода разрешите Alo доступ к камере."
                         : "Сканер QR недоступен на этом устройстве.")
                    if DataScannerViewController.isSupported {
                        Button("Открыть настройки") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
                .padding(24).frame(maxHeight: .infinity)
            }
            VStack(spacing: 10) {
                Text("На устройстве, где вы уже вошли в Alo, откройте Настройки → Безопасность → «Показать QR для входа» и наведите камеру на код.")
                    .font(.subheadline).foregroundStyle(AloTheme.muted)
                Button("Показать QR на этом устройстве") { showsOwnQRCode = true }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
    }

    private var progressContent: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(flow.state == .completing ? "Завершаем вход…"
                 : flow.state == .claiming ? "Проверяем код…" : "Подтвердите вход на другом устройстве")
                .font(.title3.weight(.semibold))
            if flow.state == .waitingForOwner {
                Text("На устройстве, где вы уже вошли, появится запрос. Он действует 2 минуты.")
                    .font(.subheadline).foregroundStyle(AloTheme.muted)
            }
        }
        .padding(24)
        .accessibilityIdentifier("alo.device-link.waiting")
    }

    private func failureContent(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 44)).accessibilityHidden(true)
            Text(message).font(.body).accessibilityIdentifier("alo.device-link.error")
            Button("Сканировать снова") {
                scanned = nil
                flow.reset()
                cameraReady = false
                cameraAttempt += 1
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(24)
    }

    private func prepareCamera() async {
        isCheckingCamera = true
        defer { isCheckingCamera = false }
        guard flow.state == .scanning, DataScannerViewController.isSupported else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled, granted else { return }
        }
        guard !Task.isCancelled else { return }
        cameraReady = AloQRCodeScanner.isAvailable
    }
}

/// Settings, signed-in device: show a QR for a new device and confirm its sign-in.
struct AloDeviceLinkShowSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AloAppModel
    @StateObject private var flow = AloDeviceLinkShowFlow()
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    switch flow.state {
                    case .loading:
                        ProgressView("Создаём QR-код…")
                    case .showing(let request):
                        qrCode(request)
                        Text("На новом устройстве нажмите «Сканировать QR» на экране входа и наведите камеру на этот код.")
                        Text("Код действует 2 минуты. Он одноразовый.")
                            .font(.subheadline).foregroundStyle(AloTheme.muted)
                    case .confirming(let request):
                        qrCode(request).opacity(0.25)
                        Image(systemName: "lock.shield").font(.system(size: 38)).accessibilityHidden(true)
                        Text("Войти на другом устройстве?").font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Новое устройство отсканировало код. Подтверждайте, только если вы сами сейчас входите на нём.")
                        Button("Подтвердить вход") {
                            Task { await flow.approve { try await app.api.approveDeviceLink(requestID: $0.requestID, secret: $0.secret) } }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("alo.device-link.confirm")
                        Button("Отклонить", role: .destructive) {
                            Task { await flow.deny { try await app.api.denyDeviceLink(requestID: $0.requestID, secret: $0.secret) } }
                        }
                        .frame(minHeight: 44)
                    case .approving:
                        ProgressView("Подтверждаем вход…")
                    case .approved:
                        Label("Вход подтверждён", systemImage: "checkmark.circle.fill").font(.title2)
                        Text("Новое устройство сейчас откроет ваш аккаунт.")
                        Button("Готово") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
                    case .denied:
                        Label("Вход отклонён", systemImage: "xmark.circle").font(.title2)
                        Button("Закрыть") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
                    case .failed(let message):
                        Image(systemName: "qrcode").font(.system(size: 44)).accessibilityHidden(true)
                        Text(message)
                        Button("Создать новый QR-код") { attempt += 1 }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(AloTheme.text)
                .frame(maxWidth: 440).frame(maxWidth: .infinity)
                .padding(24)
            }
            .id(attempt)
            .background(AloTheme.background.ignoresSafeArea())
            .navigationTitle("QR для входа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }.foregroundStyle(AloTheme.accent)
                }
            }
        }
        .tint(AloTheme.accent)
        .preferredColorScheme(.dark)
        .task(id: attempt) {
            await flow.run(start: { try await app.api.startDeviceLink() },
                           status: { try await app.api.loadQRCodeLoginStatus(requestID: $0.requestID, secret: $0.secret) })
        }
    }

    private func qrCode(_ request: AloQRCodeLoginRequest) -> some View {
        AloQRCodeImage(payload: request.payload)
            .frame(maxWidth: 240)
            .aspectRatio(1, contentMode: .fit)
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("QR-код для входа на другом устройстве")
            .accessibilityIdentifier("alo.device-link.code")
    }
}
