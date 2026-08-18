import Combine
import Foundation

/// One unfinished / last-reached Zone checkout (`/zone/start?internalZoneCode=`).
struct AttemptedZone: Codable, Identifiable, Equatable, Hashable {
    var internalCode: String
    var signageCode: String?
    var attemptedAt: Date

    var id: String { internalCode }

    var displayLabel: String { signageCode ?? internalCode }

    var title: String { "Zone \(displayLabel)" }

    var subtitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "a"
        formatter.pmSymbol = "p"
        let clock = formatter.string(from: attemptedAt)
        formatter.dateFormat = "MM/dd/yy"
        return "\(clock) . \(formatter.string(from: attemptedAt))"
    }

    var startURL: URL {
        FixedDurationURLs.zoneStart(internalZoneCode: internalCode)
    }
}

/// Last 3 attempted Zone checkouts, persisted across app restarts.
@MainActor
final class AttemptedZoneStore: ObservableObject {
    static let shared = AttemptedZoneStore()
    static let maxAttempts = 3
    /// ParkMobile internals are vendor+zone (e.g. `30447039`, `1081972`). A public Zone # like `47922` is not an internal.
    private static let minInternalDigits = 7

    @Published private(set) var attempts: [AttemptedZone] = []

    private let storageKey = "attemptedZoneCheckouts"
    private let legacyInternalKey = "lastAttemptedZoneInternal"
    private let legacySignageKey = "lastAttemptedZoneSignage"

    private init() {
        load()
    }

    func remember(pageURL: URL?) {
        guard let pageURL else { return }
        let path = pageURL.path.lowercased()
        if Self.shouldIgnore(path) { return }
        if let code = queryValue("internalzonecode", in: pageURL) {
            upsert(internalCode: code, signageCode: nil)
        }
        if path.contains("/zone/start") || path.contains("/zone/duration")
            || path.contains("/zone/auth") || path.contains("/zone/vehicle")
            || path.contains("/zone/payment") || path.contains("/zone/review") {
            remember(xhrURL: pageURL.absoluteString, responseBody: "")
        }
    }

    func remember(xhrURL: String, responseBody: String) {
        let lower = xhrURL.lowercased()
        if Self.shouldIgnore(lower) { return }
        if let code = firstMatch(#"internalzonecode=(\d{7,})"#, in: lower) {
            upsert(internalCode: code, signageCode: nil)
        }
        if let code = firstMatch(#"/zoneoptions/(\d{7,})"#, in: lower) {
            upsert(internalCode: code, signageCode: nil)
        }
        if let code = firstMatch(#"/api/zones/(\d{4,})"#, in: lower) {
            rememberPathCode(code)
        }
        if let code = firstMatch(#"parkmobileapi/zones/(\d{4,})"#, in: lower) {
            rememberPathCode(code)
        }
        rememberJSON(responseBody)
    }

    private static func shouldIgnore(_ lower: String) -> Bool {
        lower.contains("/zones/search")
            || lower.contains("/search/transient")
            || lower.contains("/sessions/")
            || lower.contains("/v2/parking")
            || lower.contains("ondemand-guest-purchase")
            || lower.contains("/zone/confirmation")
            || lower.contains("/zone/receipt")
    }

    func remove(id: String) {
        attempts.removeAll { $0.id == id }
        persist()
    }

    private func rememberJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        // Do not walk `zones: []` (map search lists Atlanta/Austin defaults as attempts).
        let internalCode = stringValue(root["internalZoneCode"]) ?? stringValue(root["internal_zone_code"])
        let signage = stringValue(root["signageCode"]) ?? stringValue(root["signage_code"])
            ?? stringValue(root["zoneCode"])
        if let internalCode {
            upsert(internalCode: internalCode, signageCode: signage)
        } else if let signage {
            attachSignage(signage)
        }
    }

    private func rememberPathCode(_ code: String) {
        if code.count >= Self.minInternalDigits {
            upsert(internalCode: code, signageCode: nil)
        } else {
            attachSignage(code)
        }
    }

    private func upsert(internalCode raw: String, signageCode: String?) {
        let code = digits(raw)
        guard code.count >= Self.minInternalDigits else { return }
        let signage = signageCode.flatMap { value -> String? in
            let cleaned = digits(value)
            return (4...6).contains(cleaned.count) ? cleaned : nil
        }

        if let index = attempts.firstIndex(where: { $0.internalCode == code }) {
            var item = attempts[index]
            var changed = false
            if let signage, item.signageCode != signage {
                item.signageCode = signage
                changed = true
            }
            if index == 0, !changed { return }
            item.attemptedAt = Date()
            attempts.remove(at: index)
            attempts.insert(item, at: 0)
        } else {
            attempts.insert(
                AttemptedZone(internalCode: code, signageCode: signage, attemptedAt: Date()),
                at: 0
            )
        }
        if attempts.count > Self.maxAttempts {
            attempts = Array(attempts.prefix(Self.maxAttempts))
        }
        persist()
        AppLog.log(
            "Attempted zone cached internal=\(code) signage=\(attempts.first?.signageCode ?? "-") " +
            "count=\(attempts.count)"
        )
    }

    private func attachSignage(_ raw: String) {
        let code = digits(raw)
        guard (4...6).contains(code.count), let latest = attempts.first else { return }
        upsert(internalCode: latest.internalCode, signageCode: code)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([AttemptedZone].self, from: data) {
            let usable = decoded.filter { $0.internalCode.filter(\.isNumber).count >= Self.minInternalDigits }
            attempts = Array(usable.prefix(Self.maxAttempts))
            if attempts != decoded {
                persist()
            }
        }
        if attempts.isEmpty {
            migrateLegacySingleZone()
        }
    }

    private func migrateLegacySingleZone() {
        guard let legacyInternal = stored(legacyInternalKey),
              digits(legacyInternal).count >= Self.minInternalDigits
        else { return }
        let signage = stored(legacySignageKey)
        attempts = [
            AttemptedZone(internalCode: legacyInternal, signageCode: signage, attemptedAt: Date())
        ]
        persist()
        AppLog.log("Attempted zone migrated internal=\(legacyInternal) signage=\(signage ?? "-")")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(attempts) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func stored(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func digits(_ raw: String) -> String {
        raw.filter(\.isNumber)
    }

    private func stringValue(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let n = any as? Int { return String(n) }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name.lowercased() == name }?
            .value
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[swiftRange])
    }
}
