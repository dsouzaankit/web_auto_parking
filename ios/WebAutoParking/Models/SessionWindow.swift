import Foundation

enum SessionWindow {
    /// Checkout start/end pickers snap to this many minutes.
    static let snapMinutes = 15

    /// Active global duration (3 or 4), from in-app preference / config.
    @MainActor
    static var durationHours: Int {
        SessionPreferences.shared.durationHours
    }

    /// Next quarter-hour boundary at or after `date`.
    /// If `date` is already exactly on a mark (0s), that mark is used.
    static func nextFifteenMinuteMark(
        after date: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        let comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0
        let nanosecond = comps.nanosecond ?? 0

        let onMark = minute % snapMinutes == 0 && second == 0 && nanosecond == 0
        if onMark {
            return calendar.date(from: DateComponents(
                year: comps.year,
                month: comps.month,
                day: comps.day,
                hour: comps.hour,
                minute: minute,
                second: 0
            )) ?? date
        }

        let minutesToAdd = snapMinutes - (minute % snapMinutes)
        guard
            let truncated = calendar.date(from: DateComponents(
                year: comps.year,
                month: comps.month,
                day: comps.day,
                hour: comps.hour,
                minute: minute,
                second: 0
            )),
            let snapped = calendar.date(byAdding: .minute, value: minutesToAdd, to: truncated)
        else {
            return date
        }
        return snapped
    }

    /// Start = next 15-minute mark; end = start + duration.
    static func bookingWindow(
        from date: Date = .now,
        calendar: Calendar = .current,
        durationHours: Int
    ) -> (start: Date, end: Date) {
        let hours = BookingConfig.clampDuration(durationHours)
        let start = nextFifteenMinuteMark(after: date, calendar: calendar)
        let end = calendar.date(byAdding: .hour, value: hours, to: start) ?? start
        return (start, end)
    }

    /// Local wall clock stamped with a literal `Z`.
    /// ParkMobile's checkout URL builder takes `getUTCHours()` then appends the local
    /// offset, so a real `09:45-04:00` becomes `13:45-04:00` (1:45 PM). Feeding the
    /// Eastern wall time as `…Z` makes their UTC getters keep 09:45 → `09:45-04:00`.
    static func isoParkMobileZuluWallString(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    /// Local wall time `yyyy-MM-dd'T'HH:mm:ss` (no zone) — flexible `starts`/`ends`.
    static func isoLocalDateString(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    static func displayRange(
        from date: Date = .now,
        calendar: Calendar = .current,
        durationHours: Int
    ) -> String {
        let hours = BookingConfig.clampDuration(durationHours)
        let window = bookingWindow(from: date, calendar: calendar, durationHours: hours)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE, MMM d · h:mm a"
        let startText = formatter.string(from: window.start)
        formatter.dateFormat = "h:mm a"
        let endText = formatter.string(from: window.end)
        return "\(startText) → \(endText) · fixed \(hours)h · flexible rate package"
    }
}
