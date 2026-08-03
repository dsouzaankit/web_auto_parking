import CoreLocation
import Foundation

/// When-in-use location for ParkMobile Zone nearest-zone automation.
@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastError: String?

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var hasWhenInUse: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    func requestWhenInUseIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            // Warm the provider; requestLocation alone is often slow/empty on first grant.
            manager.requestLocation()
            manager.startUpdatingLocation()
        default:
            lastError = "Location denied — enable in Settings for nearest zone"
            AppLog.log("Location denied status=\(manager.authorizationStatus.rawValue)")
        }
    }

    /// Fresh fix when possible; falls back to last known coordinate.
    func currentCoordinate(timeoutSeconds: TimeInterval = 8) async -> CLLocationCoordinate2D? {
        if let coordinate { return coordinate }
        requestWhenInUseIfNeeded()
        return await withCheckedContinuation { cont in
            continuation = cont
            if hasWhenInUse {
                manager.requestLocation()
                manager.startUpdatingLocation()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if let continuation {
                    self.continuation = nil
                    continuation.resume(returning: self.coordinate)
                }
                self.manager.stopUpdatingLocation()
            }
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            AppLog.log("Location auth=\(manager.authorizationStatus.rawValue)")
            if hasWhenInUse {
                manager.requestLocation()
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let loc = locations.last else { return }
            coordinate = loc.coordinate
            lastError = nil
            AppLog.log(
                String(format: "Location fix lat=%.5f lng=%.5f acc=%.0fm",
                       loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy)
            )
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: loc.coordinate)
                manager.stopUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            lastError = error.localizedDescription
            AppLog.log("Location error: \(error.localizedDescription)")
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: coordinate)
            }
        }
    }
}
