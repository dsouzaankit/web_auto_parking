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
    /// Cap for zone session duration pickers (Zone tab: 40 / 80 / 120).
    var maxDurationMinutes: Int = 120
    var zoneAutomationEnabled: Bool = true

    static let standard = PrefillContext()
}
