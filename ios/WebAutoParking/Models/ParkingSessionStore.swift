import Foundation
import UIKit

/// Guest ParkMobile receipts live on `/sessions/{uuid}` — not in the native app Activity list.
struct SavedParkingSession: Codable, Identifiable, Equatable, Hashable {
    var uuid: String
    var urlString: String
    var capturedAt: Date
    var zoneCode: String?
    var plate: String?
    var startLabel: String?
    var stopLabel: String?
    var amount: String?

    var id: String { uuid.lowercased() }

    var url: URL? { URL(string: urlString) }

    var title: String {
        if let zoneCode, !zoneCode.isEmpty {
            return "Zone \(zoneCode)"
        }
        return "Zone receipt"
    }

    var subtitle: String {
        var parts: [String] = []
        if let startLabel, let stopLabel, !startLabel.isEmpty {
            parts.append("\(Self.compactClock(startLabel))-\(Self.compactClock(stopLabel))")
        } else if let amount, !amount.isEmpty {
            parts.append(amount)
        }
        parts.append(Self.compactTimestamp(capturedAt))
        if let plate, !plate.isEmpty { parts.append(plate) }
        return parts.joined(separator: " . ")
    }

    private static func compactClock(_ text: String) -> String {
        text.replacingOccurrences(of: " AM", with: "a")
            .replacingOccurrences(of: " PM", with: "p")
            .replacingOccurrences(of: " am", with: "a")
            .replacingOccurrences(of: " pm", with: "p")
    }

    private static func compactTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yy"
        return formatter.string(from: date)
    }
}

/// Last 7 paid zone sessions, persisted across app restarts.
@MainActor
final class ParkingSessionStore: ObservableObject {
    static let shared = ParkingSessionStore()
    static let maxSessions = 7

    @Published private(set) var sessions: [SavedParkingSession] = []

    private let storageKey = "savedParkingSessions"
    private var pendingPlate: String?
    private var pendingZone: String?
    private var pendingAmount: String?

    private init() {
        load()
    }

    nonisolated static func isProtectedURL(_ url: URL?) -> Bool {
        guard let path = url?.path.lowercased() else { return false }
        return path.contains("/sessions/")
            || path.contains("/zone/confirmation")
            || path.contains("/zone/receipt")
            || path.contains("/zone/review") && path.contains("confirmation")
    }

    /// Canonical `/sessions/{uuid}` link when the WebView is on the post-checkout timer page.
    nonisolated static func copyableTimerURL(_ url: URL?) -> URL? {
        guard let url, let uuid = uuid(in: url) else { return nil }
        return URL(string: "https://app.parkmobile.io/sessions/\(uuid.lowercased())")
    }

    func capture(pageURL: URL?) {
        guard let pageURL else { return }
        if let uuid = Self.uuid(in: pageURL) {
            remember(
                uuid: uuid,
                fallbackURL: pageURL,
                zone: pendingZone,
                plate: pendingPlate,
                amount: pendingAmount
            )
            return
        }
        if Self.isProtectedURL(pageURL), sessions.isEmpty || sessions.first?.urlString != pageURL.absoluteString {
            AppLog.log("Parking session page without uuid yet \(pageURL.absoluteString)")
        }
    }

    func capture(xhrURL: String, requestBody: String, responseBody: String, pageURL: URL?) {
        rememberCartHints(requestBody: requestBody, responseBody: responseBody, xhrURL: xhrURL)

        if let uuid = Self.uuid(in: xhrURL) {
            remember(
                uuid: uuid,
                fallbackURL: pageURL,
                zone: pendingZone,
                plate: pendingPlate,
                amount: pendingAmount
            )
            return
        }

        let interesting = xhrURL.contains("ondemand-guest-purchase")
            || xhrURL.contains("/v2/parking/")
            || xhrURL.localizedCaseInsensitiveContains("parking_uuid")
        guard interesting else { return }
        guard let uuid = Self.uuid(inJSON: responseBody) ?? Self.uuid(in: responseBody) else { return }
        let times = Self.timeLabels(inJSON: responseBody)
        remember(
            uuid: uuid,
            fallbackURL: pageURL,
            zone: pendingZone,
            plate: pendingPlate,
            amount: pendingAmount,
            startLabel: times.start,
            stopLabel: times.stop
        )
    }

    func addFromClipboard() -> Bool {
        guard let text = UIPasteboard.general.string,
              let uuid = Self.uuid(in: text)
        else { return false }
        remember(uuid: uuid, fallbackURL: URL(string: text), zone: nil, plate: nil, amount: nil)
        return true
    }

    func remove(id: String) {
        sessions.removeAll { $0.id == id.lowercased() }
        persist()
    }

    private func rememberCartHints(requestBody: String, responseBody: String, xhrURL: String) {
        if xhrURL.contains("guest/cart"), let obj = Self.jsonObject(requestBody) {
            if let plate = obj["vehicle_lpn"] as? String, !plate.isEmpty {
                pendingPlate = plate
            }
            if let zone = obj["zone_code"] as? String, !zone.isEmpty {
                pendingZone = zone.hasPrefix("304") ? String(zone.dropFirst(3)) : zone
            }
        }
        if xhrURL.contains("guest/price"), let obj = Self.jsonObject(responseBody) {
            if let price = obj["price"] as? [String: Any],
               let total = price["total_price"] as? Double {
                pendingAmount = String(format: "$%.2f", total)
            }
        }
        if xhrURL.contains("ondemand-guest-purchase") || xhrURL.contains("guest/cart") {
            if let obj = Self.jsonObject(responseBody) {
                if pendingZone == nil, let signage = obj["signage_code"] as? String {
                    pendingZone = signage
                }
            }
        }
    }

    private func remember(
        uuid: String,
        fallbackURL: URL?,
        zone: String?,
        plate: String?,
        amount: String?,
        startLabel: String? = nil,
        stopLabel: String? = nil
    ) {
        let key = uuid.lowercased()
        let link = URL(string: "https://app.parkmobile.io/sessions/\(key)")
            ?? fallbackURL
        guard let link else { return }

        var session = SavedParkingSession(
            uuid: key,
            urlString: link.absoluteString,
            capturedAt: Date(),
            zoneCode: Self.preferredZoneCode(incoming: zone, existing: nil),
            plate: plate,
            startLabel: startLabel,
            stopLabel: stopLabel,
            amount: amount
        )

        if let existing = sessions.first(where: { $0.id == key }) {
            session.capturedAt = existing.capturedAt
            session.zoneCode = Self.preferredZoneCode(incoming: session.zoneCode, existing: existing.zoneCode)
            session.plate = existing.plate ?? session.plate
            session.startLabel = session.startLabel ?? existing.startLabel
            session.stopLabel = session.stopLabel ?? existing.stopLabel
            session.amount = session.amount ?? existing.amount
            if session == existing { return }
        }

        sessions.removeAll { $0.id == key }
        sessions.insert(session, at: 0)
        if sessions.count > Self.maxSessions {
            sessions = Array(sessions.prefix(Self.maxSessions))
        }
        persist()
        AppLog.log(
            "Parking session captured uuid=\(key) zone=\(session.zoneCode ?? "-") " +
            "plate=\(session.plate ?? "-") url=\(link.absoluteString)"
        )
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([SavedParkingSession].self, from: data) {
            sessions = Array(decoded.prefix(Self.maxSessions))
            if sessions.count < decoded.count {
                persist()
            }
        }
    }

    /// Public Zone # is 4–6 digits (e.g. `47922`). Do not replace it with a later vendor+zone cart code (`95347922`).
    private static func preferredZoneCode(incoming: String?, existing: String?) -> String? {
        func normalized(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let digits = raw.filter(\.isNumber)
            if digits.isEmpty { return nil }
            if digits.hasPrefix("304"), digits.count >= 8 {
                let rest = String(digits.dropFirst(3))
                if (4...6).contains(rest.count) { return rest }
            }
            return digits
        }
        let incomingNorm = normalized(incoming)
        let existingNorm = normalized(existing)
        let isSignage: (String) -> Bool = { (4...6).contains($0.count) }
        if let existingNorm, isSignage(existingNorm) { return existingNorm }
        if let incomingNorm, isSignage(incomingNorm) { return incomingNorm }
        return existingNorm ?? incomingNorm
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated private static func uuid(in url: URL) -> String? {
        uuid(in: url.absoluteString)
    }

    nonisolated private static func uuid(in text: String) -> String? {
        let pattern = #"(?:/sessions/|parking_uuid"?\s*[:=]\s*"?)([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[swiftRange])
    }

    private static func uuid(inJSON text: String) -> String? {
        guard let obj = jsonObject(text) else { return uuid(in: text) }
        for key in ["parking_uuid", "parkingUuid"] {
            if let value = obj[key] as? String, value.contains("-"), value.count >= 32 {
                return value
            }
        }
        return uuid(in: text)
    }

    private static func timeLabels(inJSON text: String) -> (start: String?, stop: String?) {
        guard let obj = jsonObject(text) else { return (nil, nil) }
        let startRaw = (obj["parking_start_time_utc"] as? String)
            ?? (obj["startTimeUtc"] as? String)
        let stopRaw = (obj["parking_stop_time_utc"] as? String)
            ?? (obj["stopTimeUtc"] as? String)
        let offset = (obj["parking_start_time_offset"] as? Int)
            ?? (obj["parking_stop_time_offset"] as? Int)
            ?? -240
        return (formatWall(startRaw, offsetMinutes: offset), formatWall(stopRaw, offsetMinutes: offset))
    }

    private static func formatWall(_ raw: String?, offsetMinutes: Int) -> String? {
        guard var raw else { return nil }
        if raw.hasSuffix("Z") == false {
            raw += "Z"
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        guard let date = iso.date(from: raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60)
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "a"
        formatter.pmSymbol = "p"
        return formatter.string(from: date)
    }
}
