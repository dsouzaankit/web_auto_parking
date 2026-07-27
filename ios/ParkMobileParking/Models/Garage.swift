import Foundation

enum ParkingProvider: String, Codable, CaseIterable, Hashable {
    case parkMobile
    case spotHero

    var displayName: String {
        switch self {
        case .parkMobile: return "ParkMobile"
        case .spotHero: return "SpotHero"
        }
    }

    var idLabel: String {
        switch self {
        case .parkMobile: return "Reservation ID"
        case .spotHero: return "Facility ID"
        }
    }

    var idHelp: String {
        switch self {
        case .parkMobile:
            return "From app.parkmobile.io/reservation/62713 → 62713"
        case .spotHero:
            return "From spothero.com/purchase/hourly?facility=131895 → 131895"
        }
    }

    /// When false, only the start (next 15-min mark) is set — the site may extend free time / pick a rate package.
    var locksFixedDuration: Bool {
        switch self {
        case .parkMobile: return true
        case .spotHero: return false
        }
    }
}

struct Garage: Identifiable, Codable, Equatable, Hashable {
    /// Facility / reservation id on the provider.
    var facilityID: String
    var provider: ParkingProvider
    var name: String
    var address: String
    var notes: String

    /// Stable list identity across providers.
    var id: String { "\(provider.rawValue):\(facilityID)" }

    /// Opens checkout starting at the **next 15-minute mark**.
    /// ParkMobile locks end to the global 3h/4h setting; SpotHero leaves duration to the rate package.
    func reservationURL(
        from date: Date = .now,
        calendar: Calendar = .current,
        durationHours: Int = 4
    ) -> URL {
        let start = SessionWindow.nextFifteenMinuteMark(after: date, calendar: calendar)
        switch provider {
        case .parkMobile:
            let hours = BookingConfig.clampDuration(durationHours)
            let end = calendar.date(byAdding: .hour, value: hours, to: start) ?? start
            return ParkMobileURLs.reservation(
                id: facilityID,
                start: start,
                end: end,
                calendar: calendar
            )
        case .spotHero:
            return SpotHeroURLs.hourlyPurchase(
                facilityID: facilityID,
                start: start,
                end: nil,
                calendar: calendar
            )
        }
    }

    static let harborWeehawken = Garage(
        facilityID: "62713",
        provider: .parkMobile,
        name: "1525 Harbor Garage",
        address: "1525 Harbor Blvd., Weehawken Township, NJ 07086",
        notes: "ParkMobile. Pull ticket at gate. At exit, press Help and read parking pass # to attendant."
    )

    /// ParkMobile: https://app.parkmobile.io/reservation/59277
    static let bisbyJerseyCity = Garage(
        facilityID: "59277",
        provider: .parkMobile,
        name: "(SP+) - The Bisby Garage",
        address: "30 Park Ln. N., Jersey City, NJ 07310",
        notes: "ParkMobile. Park in any non-Reserved spot. Pass validated by license plate — no attendant needed."
    )

    /// SpotHero: https://spothero.com/purchase/hourly?facility=131895
    static let mallDriveJerseyCity = Garage(
        facilityID: "131895",
        provider: .spotHero,
        name: "29245 Mall Dr. E - Lot",
        address: "29245 Mall Drive East, Jersey City, NJ",
        notes: "SpotHero outdoor self-park. Duration follows their rate package — free extra time is kept, not forced to 4h."
    )

    enum CodingKeys: String, CodingKey {
        case facilityID, provider, name, address, notes
        case legacyID = "id"
    }

    init(
        facilityID: String,
        provider: ParkingProvider,
        name: String,
        address: String,
        notes: String
    ) {
        self.facilityID = facilityID
        self.provider = provider
        self.name = name
        self.address = address
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let facilityID = try container.decodeIfPresent(String.self, forKey: .facilityID) {
            self.facilityID = facilityID
        } else {
            self.facilityID = try container.decode(String.self, forKey: .legacyID)
        }
        provider = try container.decodeIfPresent(ParkingProvider.self, forKey: .provider) ?? .parkMobile
        name = try container.decode(String.self, forKey: .name)
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(facilityID, forKey: .facilityID)
        try container.encode(provider, forKey: .provider)
        try container.encode(name, forKey: .name)
        try container.encode(address, forKey: .address)
        try container.encode(notes, forKey: .notes)
    }
}

enum ParkMobileURLs {
    static let search = URL(string: "https://app.parkmobile.io/search")!
    static let zoneStart = URL(string: "https://app.parkmobile.io/zone/start")!
    static let home = URL(string: "https://app.parkmobile.io/")!

    static func reservation(
        id: String,
        start: Date? = nil,
        end: Date? = nil,
        calendar: Calendar = .current
    ) -> URL {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://app.parkmobile.io/reservation/\(trimmed)")!
        if let start, let end {
            components.queryItems = [
                URLQueryItem(name: "startDate", value: SessionWindow.isoLocalDateString(start, calendar: calendar)),
                URLQueryItem(name: "endDate", value: SessionWindow.isoLocalDateString(end, calendar: calendar))
            ]
        }
        return components.url!
    }
}

enum SpotHeroURLs {
    static let home = URL(string: "https://spothero.com/")!

    /// Hourly checkout. Pass `start` for arrival; omit `end` so SpotHero can apply free-extra-time packages.
    static func hourlyPurchase(
        facilityID: String,
        start: Date? = nil,
        end: Date? = nil,
        calendar: Calendar = .current
    ) -> URL {
        let trimmed = facilityID.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://spothero.com/purchase/hourly")!
        var items = [URLQueryItem(name: "facility", value: trimmed)]
        if let start {
            items.append(URLQueryItem(name: "starts", value: SessionWindow.isoLocalDateString(start, calendar: calendar)))
        }
        if let end {
            items.append(URLQueryItem(name: "ends", value: SessionWindow.isoLocalDateString(end, calendar: calendar)))
        }
        components.queryItems = items
        return components.url!
    }
}
