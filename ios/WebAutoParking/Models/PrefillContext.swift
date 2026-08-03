import Foundation

/// Extra inputs for WebView prefill beyond `BookingConfig.json`.
struct PrefillContext: Equatable {
    enum Mode: String, Equatable {
        case standard
        case parkMobileZone
    }

    var mode: Mode = .standard
    var latitude: Double?
    var longitude: Double?
    /// Cap for zone session duration pickers (default 1h 40m).
    var maxDurationMinutes: Int = 100
    var zoneAutomationEnabled: Bool = true

    static let standard = PrefillContext()
}
