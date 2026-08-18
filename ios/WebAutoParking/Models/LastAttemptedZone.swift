import Foundation

/// Last Zone # the user reached (`/zone/start?internalZoneCode=`).
/// Persists across reboots for the Duration-bar **Zone {n}** button; Zone tab still
/// opens `/search` unless that button is tapped.
enum LastAttemptedZone {
    private static let internalKey = "lastAttemptedZoneInternal"
    private static let signageKey = "lastAttemptedZoneSignage"

    static var internalCode: String? { stored(internalKey) }
    static var signageCode: String? { stored(signageKey) }

    /// Public Zone # when known (`47922`), else the internal code.
    static var displayLabel: String? { signageCode ?? internalCode }

    static var startURL: URL {
        if let code = internalCode {
            return FixedDurationURLs.zoneStart(internalZoneCode: code)
        }
        return FixedDurationURLs.search
    }

    static func remember(pageURL: URL?) {
        guard let pageURL else { return }
        let path = pageURL.path.lowercased()
        if let code = queryValue("internalzonecode", in: pageURL) {
            setInternal(code)
        }
        if path.contains("/zone/start") || path.contains("/zone/duration")
            || path.contains("/zone/auth") || path.contains("/zone/vehicle")
            || path.contains("/zone/payment") || path.contains("/zone/review") {
            remember(xhrURL: pageURL.absoluteString, responseBody: "")
        }
    }

    static func remember(xhrURL: String, responseBody: String) {
        let lower = xhrURL.lowercased()
        if let code = firstMatch(#"internalzonecode=(\d{5,})"#, in: lower) {
            setInternal(code)
        }
        if let code = firstMatch(#"/zoneoptions/(\d{5,})"#, in: lower) {
            setInternal(code)
        }
        if let code = firstMatch(#"/api/zones/(\d{5,})"#, in: lower),
           !lower.contains("/zones/search") {
            if code.count >= 7 {
                setInternal(code)
            } else {
                setSignage(code)
            }
        }
        if let code = firstMatch(#"parkmobileapi/zones/(\d{4,})"#, in: lower) {
            if code.count >= 7 {
                setInternal(code)
            } else {
                setSignage(code)
            }
        }
        rememberJSON(responseBody)
    }

    private static func rememberJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return }
        var objects: [[String: Any]] = []
        if let obj = root as? [String: Any] {
            objects.append(obj)
            if let zones = obj["zones"] as? [[String: Any]] {
                objects.append(contentsOf: zones)
            }
        }
        for obj in objects {
            if let internalCode = stringValue(obj["internalZoneCode"]) ?? stringValue(obj["internal_zone_code"]) {
                setInternal(internalCode)
            }
            if let signage = stringValue(obj["signageCode"]) ?? stringValue(obj["signage_code"])
                ?? stringValue(obj["zoneCode"]) {
                setSignage(signage)
            }
        }
    }

    private static func setInternal(_ raw: String) {
        let code = digits(raw)
        guard code.count >= 5 else { return }
        if stored(internalKey) != code {
            UserDefaults.standard.set(code, forKey: internalKey)
            AppLog.log("Last zone cached internal=\(code) signage=\(signageCode ?? "-")")
        }
    }

    private static func setSignage(_ raw: String) {
        let code = digits(raw)
        guard code.count >= 4 else { return }
        if stored(signageKey) != code {
            UserDefaults.standard.set(code, forKey: signageKey)
            AppLog.log("Last zone cached signage=\(code) internal=\(internalCode ?? "-")")
        }
    }

    private static func stored(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func digits(_ raw: String) -> String {
        raw.filter(\.isNumber)
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let n = any as? Int { return String(n) }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name.lowercased() == name }?
            .value
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[swiftRange])
    }
}
