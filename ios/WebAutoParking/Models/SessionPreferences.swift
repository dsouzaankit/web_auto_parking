import Foundation
import Combine

enum ReservationStartMode: String, CaseIterable, Identifiable {
    /// Next upcoming 15-minute mark (or now if already on one).
    case asap
    /// Most recent past-or-current 15-minute mark (`:00`, `:15`, `:30`, `:45`).
    case last15
    /// Most recent past-or-current 30-minute mark (`:00`, `:30`).
    case last30

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .asap: return "ASAP"
        case .last15: return "−15m"
        case .last30: return "−30m"
        }
    }

    var footerHint: String {
        switch self {
        case .asap: return "next 15-minute mark"
        case .last15: return "last 15-minute mark"
        case .last30: return "last 30-minute mark"
        }
    }
}

/// Global fixed-duration session length (3–6h) and reservation start mode.
/// In-app choices override `BookingConfig.json` defaults where applicable.
@MainActor
final class SessionPreferences: ObservableObject {
    static let shared = SessionPreferences()

    private let durationKey = "sessionDurationHours.override"
    private let startModeKey = "reservationStartMode"

    @Published var durationHours: Int {
        didSet {
            let clamped = BookingConfig.clampDuration(durationHours)
            if durationHours != clamped {
                durationHours = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: durationKey)
        }
    }

    @Published var startMode: ReservationStartMode {
        didSet {
            UserDefaults.standard.set(startMode.rawValue, forKey: startModeKey)
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: durationKey) != nil {
            durationHours = BookingConfig.clampDuration(
                UserDefaults.standard.integer(forKey: durationKey)
            )
        } else {
            durationHours = BookingConfig.load().normalizedSessionDurationHours
        }
        if let raw = UserDefaults.standard.string(forKey: startModeKey),
           let mode = ReservationStartMode(rawValue: raw) {
            startMode = mode
        } else {
            startMode = .last15
        }
    }
}
