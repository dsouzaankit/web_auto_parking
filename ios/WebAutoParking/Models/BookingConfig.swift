import Foundation

/// Shared booking preferences. Copy `BookingConfig.example.json` → `BookingConfig.json` and edit locally (gitignored).
struct BookingConfig: Codable, Equatable {
    var email: String
    var phone: String
    var address: String
    /// Stay on guest checkout; avoid Log In when a guest path exists.
    var preferGuestCheckout: Bool
    /// Preferred payment: `applePay` (default), `card`, or `paypal`.
    var paymentMethod: String
    /// Fixed-duration locked window length (3 or 4). Overridable in-app.
    var sessionDurationHours: Int
    var vehicle: VehicleDetails

    /// Allowed fixed-duration session lengths.
    static let allowedDurations = [3, 4]

    struct VehicleDetails: Codable, Equatable {
        var makeAndModel: String
        var licensePlateNumber: String
        var country: String
        var state: String

        static let empty = VehicleDetails(
            makeAndModel: "",
            licensePlateNumber: "",
            country: "",
            state: ""
        )

        var normalizedMakeAndModel: String { BookingConfig.clean(makeAndModel) }
        var normalizedLicensePlate: String { BookingConfig.clean(licensePlateNumber) }
        /// ParkMobile/SpotHero selects use ISO-ish codes (US, NJ). Accept full names too.
        var normalizedCountry: String { BookingConfig.normalizeCountry(country) }
        var normalizedState: String { BookingConfig.normalizeState(state) }

        var hasAnyValue: Bool {
            !normalizedMakeAndModel.isEmpty
                || !normalizedLicensePlate.isEmpty
                || !normalizedCountry.isEmpty
                || !normalizedState.isEmpty
        }

        init(
            makeAndModel: String = "",
            licensePlateNumber: String = "",
            country: String = "",
            state: String = ""
        ) {
            self.makeAndModel = makeAndModel
            self.licensePlateNumber = licensePlateNumber
            self.country = country
            self.state = state
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            makeAndModel = try container.decodeIfPresent(String.self, forKey: .makeAndModel) ?? ""
            licensePlateNumber = try container.decodeIfPresent(String.self, forKey: .licensePlateNumber) ?? ""
            country = try container.decodeIfPresent(String.self, forKey: .country) ?? ""
            state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        }
    }

    static let empty = BookingConfig(
        email: "",
        phone: "",
        address: "",
        preferGuestCheckout: true,
        paymentMethod: "applePay",
        sessionDurationHours: 4,
        vehicle: .empty
    )

    var prefersApplePay: Bool {
        let key = paymentMethod.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty || key == "applepay" || key == "apple_pay" || key == "apple-pay"
    }

    /// Normalized to 3 or 4 (default 4).
    var normalizedSessionDurationHours: Int {
        Self.clampDuration(sessionDurationHours)
    }

    static func clampDuration(_ hours: Int) -> Int {
        allowedDurations.contains(hours) ? hours : 4
    }

    var normalizedEmail: String { Self.clean(email) }
    var normalizedPhone: String { Self.clean(phone) }
    var normalizedAddress: String { Self.clean(address) }

    static func load() -> BookingConfig {
        guard
            let url = Bundle.main.url(forResource: "BookingConfig", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(BookingConfig.self, from: data)
        else {
            return .empty
        }
        return decoded
    }

    init(
        email: String,
        phone: String,
        address: String,
        preferGuestCheckout: Bool = true,
        paymentMethod: String = "applePay",
        sessionDurationHours: Int = 4,
        vehicle: VehicleDetails = .empty
    ) {
        self.email = email
        self.phone = phone
        self.address = address
        self.preferGuestCheckout = preferGuestCheckout
        self.paymentMethod = paymentMethod
        self.sessionDurationHours = sessionDurationHours
        self.vehicle = vehicle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? ""
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        preferGuestCheckout = try container.decodeIfPresent(Bool.self, forKey: .preferGuestCheckout) ?? true
        paymentMethod = try container.decodeIfPresent(String.self, forKey: .paymentMethod) ?? "applePay"
        sessionDurationHours = try container.decodeIfPresent(Int.self, forKey: .sessionDurationHours) ?? 4
        vehicle = try container.decodeIfPresent(VehicleDetails.self, forKey: .vehicle) ?? .empty
    }

    /// Treat blank / placeholder dots as unset.
    fileprivate static func clean(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "." || $0 == "…" }) {
            return ""
        }
        return trimmed
    }

    static func normalizeCountry(_ raw: String) -> String {
        let cleaned = clean(raw)
        if cleaned.isEmpty { return "" }
        let key = cleaned.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "us", "usa", "unitedstates", "unitedstatesofamerica", "america":
            return "US"
        case "ca", "can", "canada":
            return "CA"
        case "mx", "mex", "mexico":
            return "MX"
        default:
            return cleaned.count == 2 ? cleaned.uppercased() : cleaned
        }
    }

    static func normalizeState(_ raw: String) -> String {
        let cleaned = clean(raw)
        if cleaned.isEmpty { return "" }
        if cleaned.count == 2 { return cleaned.uppercased() }
        let key = cleaned.lowercased().filter { $0.isLetter || $0.isNumber }
        let map: [String: String] = [
            "newjersey": "NJ", "newyork": "NY", "pennsylvania": "PA", "california": "CA",
            "texas": "TX", "florida": "FL", "massachusetts": "MA", "connecticut": "CT",
            "delaware": "DE", "maryland": "MD", "virginia": "VA", "ohio": "OH",
            "illinois": "IL", "georgia": "GA", "northcarolina": "NC", "southcarolina": "SC"
        ]
        return map[key] ?? cleaned
    }
}
