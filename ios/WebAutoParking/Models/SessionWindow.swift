import Foundation

enum SessionWindow {
    /// Checkout start/end pickers snap to this many minutes for ASAP.
    static let snapMinutes = 15

    /// Active global duration (3–6), from in-app preference / config.
    @MainActor
    static var durationHours: Int {
        SessionPreferences.shared.durationHours
    }

    /// Resolve reservation start from the selected mode.
    static func startDate(
        mode: ReservationStartMode,
        from date: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        switch mode {
        case .asap:
            return nextMinuteMark(atOrAfter: date, interval: snapMinutes, calendar: calendar)
        case .last15:
            return previousMinuteMark(atOrBefore: date, interval: 15, calendar: calendar)
        case .last30:
            return previousMinuteMark(atOrBefore: date, interval: 30, calendar: calendar)
        }
    }

    /// Next `interval`-minute boundary at or after `date`.
    /// If `date` is already exactly on a mark (0s), that mark is used.
    static func nextMinuteMark(
        atOrAfter date: Date,
        interval: Int,
        calendar: Calendar = .current
    ) -> Date {
        let snap = max(interval, 1)
        let comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0
        let nanosecond = comps.nanosecond ?? 0

        let onMark = minute % snap == 0 && second == 0 && nanosecond == 0
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

        let minutesToAdd = snap - (minute % snap)
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

    /// Previous `interval`-minute boundary at or before `date` (floors to the mark).
    static func previousMinuteMark(
        atOrBefore date: Date,
        interval: Int,
        calendar: Calendar = .current
    ) -> Date {
        let snap = max(interval, 1)
        let comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        let minute = comps.minute ?? 0
        let floored = minute - (minute % snap)
        return calendar.date(from: DateComponents(
            year: comps.year,
            month: comps.month,
            day: comps.day,
            hour: comps.hour,
            minute: floored,
            second: 0
        )) ?? date
    }

    /// Next quarter-hour boundary at or after `date` (ASAP helper).
    static func nextFifteenMinuteMark(
        after date: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        nextMinuteMark(atOrAfter: date, interval: snapMinutes, calendar: calendar)
    }

    /// Start from mode; end = start + duration.
    static func bookingWindow(
        from date: Date = .now,
        calendar: Calendar = .current,
        durationHours: Int,
        startMode: ReservationStartMode = .last15
    ) -> (start: Date, end: Date) {
        let hours = BookingConfig.clampDuration(durationHours)
        let start = startDate(mode: startMode, from: date, calendar: calendar)
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

    /// Local wall clock stamped as a UTC unix timestamp (ParkChirp deep links).
    /// Same class of quirk as ParkMobile Z-stamp: real EDT epochs display +4h on their GUI.
    static func unixParkChirpWallSeconds(_ date: Date, calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let stamped = utc.date(from: DateComponents(
            year: comps.year,
            month: comps.month,
            day: comps.day,
            hour: comps.hour,
            minute: comps.minute,
            second: 0
        )) ?? date
        return Int(stamped.timeIntervalSince1970)
    }

    /// ParkChirp time pickers are :00 / :30 only.
    static func startDateParkChirp(
        mode: ReservationStartMode,
        from date: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        switch mode {
        case .asap:
            return nextMinuteMark(atOrAfter: date, interval: 30, calendar: calendar)
        case .last15, .last30:
            return previousMinuteMark(atOrBefore: date, interval: 30, calendar: calendar)
        }
    }

    /// Fixed ParkChirp evening on a calendar day: **5:30 PM → 11:30 PM**.
    static func parkChirpFixedEvening(
        on day: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let start = calendar.date(bySettingHour: 17, minute: 30, second: 0, of: day) ?? day
        let end = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: day) ?? start
        return (start, end)
    }

    /// Today's ParkChirp window: **5:30→11:30** until 5:30 PM; after that, earliest :30 start → **11:30 PM**.
    /// Returns nil when no room left before 11:30 (caller walks future days).
    static func parkChirpTodayWindow(
        on date: Date = .now,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        let fiveThirty = calendar.date(bySettingHour: 17, minute: 30, second: 0, of: date) ?? date
        let elevenThirty = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: date) ?? date
        let start: Date
        if date <= fiveThirty {
            start = fiveThirty
        } else {
            // After 5:30 PM: earliest bookable :30 slot at or after now.
            start = nextMinuteMark(atOrAfter: date, interval: 30, calendar: calendar)
        }
        guard start < elevenThirty else { return nil }
        return (start, elevenThirty)
    }

    /// Deep-link / list helper: today window if bookable, else next day's fixed 5:30–11:30.
    static func parkChirpLockedEveningWindow(
        on date: Date = .now,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        if let today = parkChirpTodayWindow(on: date, calendar: calendar) {
            return today
        }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return parkChirpFixedEvening(on: nextDay, calendar: calendar)
    }

    /// Today (5:30 or earliest after 5:30) + next `futureDays` fixed 5:30→11:30 evenings.
    static func parkChirpEveningCandidates(
        on date: Date = .now,
        calendar: Calendar = .current,
        futureDays: Int = 3
    ) -> [(start: Date, end: Date)] {
        let days = max(futureDays, 0)
        var out: [(start: Date, end: Date)] = []
        if let today = parkChirpTodayWindow(on: date, calendar: calendar) {
            out.append(today)
        }
        for offset in 1...days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            out.append(parkChirpFixedEvening(on: day, calendar: calendar))
        }
        return out
    }

    static func displayRange(
        from date: Date = .now,
        calendar: Calendar = .current,
        durationHours: Int,
        startMode: ReservationStartMode = .last15
    ) -> String {
        let hours = BookingConfig.clampDuration(durationHours)
        let window = bookingWindow(
            from: date,
            calendar: calendar,
            durationHours: hours,
            startMode: startMode
        )
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE, MMM d · h:mm a"
        let startText = formatter.string(from: window.start)
        formatter.dateFormat = "h:mm a"
        let endText = formatter.string(from: window.end)
        return "\(startText) → \(endText) · \(startMode.shortLabel) · fixed \(hours)h"
    }
}
