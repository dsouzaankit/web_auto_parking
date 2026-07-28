import Foundation
import Combine

/// Global fixed-duration session length (3h or 4h). In-app choice overrides `BookingConfig.json`.
@MainActor
final class SessionPreferences: ObservableObject {
    static let shared = SessionPreferences()

    private let defaultsKey = "sessionDurationHours.override"

    @Published var durationHours: Int {
        didSet {
            let clamped = BookingConfig.clampDuration(durationHours)
            if durationHours != clamped {
                durationHours = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: defaultsKey)
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            durationHours = BookingConfig.clampDuration(
                UserDefaults.standard.integer(forKey: defaultsKey)
            )
        } else {
            durationHours = BookingConfig.load().normalizedSessionDurationHours
        }
    }
}
