import CoreLocation

enum AloLocationRequestError: LocalizedError {
    case servicesDisabled
    case permissionDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .servicesDisabled:
            return "На устройстве отключены службы геолокации."
        case .permissionDenied:
            return "Разреши Alo доступ к геолокации в настройках iPhone."
        case .unavailable:
            return "Текущая геолокация пока недоступна."
        }
    }
}

/// Requests one coordinate only.  It never starts a background or live-location
/// session, so location data can be placed in the message's E2EE payload once.
@MainActor
final class AloOneShotLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?
    private var didRequestLocation = false

    static func requestCurrentCoordinate() async throws -> CLLocationCoordinate2D {
        try await AloOneShotLocationProvider().requestCurrentCoordinate()
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    private func requestCurrentCoordinate() async throws -> CLLocationCoordinate2D {
        guard CLLocationManager.locationServicesEnabled() else {
            throw AloLocationRequestError.servicesDisabled
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            requestLocationWhenAuthorized()
        }
    }

    private func requestLocationWhenAuthorized() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard !didRequestLocation else { return }
            didRequestLocation = true
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(AloLocationRequestError.permissionDenied))
        @unknown default:
            finish(.failure(AloLocationRequestError.unavailable))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        requestLocationWhenAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate,
              coordinate.latitude.isFinite,
              coordinate.longitude.isFinite else {
            finish(.failure(AloLocationRequestError.unavailable))
            return
        }
        finish(.success(coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(AloLocationRequestError.unavailable))
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
