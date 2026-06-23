import Foundation

/// Computes the next "reasonable morning" send time for a candidate. Pure function, no I/O.
enum NextMorningScheduler {
    static let defaultPreferredHour = 8           // 8 AM user-local, when timezone is known
    static let fallbackTimeZoneIdentifier = "America/New_York"
    static let fallbackHour = 9                   // 9 AM Eastern, when timezone is unknown

    /// Returns the next occurrence of `preferredHour:00` in `timezone` that is strictly after
    /// `now`. Falls back to 9 AM Eastern if `timezone` is nil or not a recognized IANA
    /// identifier, and falls back to "1 hour from now in UTC" only if even that fails to
    /// resolve (should not happen in practice — `America/New_York` is always valid).
    static func nextMorning(
        timezone: String?,
        preferredHour: Int = defaultPreferredHour,
        now: Date = Date()
    ) -> Date {
        let resolvedZone: TimeZone
        let resolvedHour: Int

        if let tz = timezone, let zone = TimeZone(identifier: tz) {
            resolvedZone = zone
            resolvedHour = preferredHour
        } else if let fallbackZone = TimeZone(identifier: fallbackTimeZoneIdentifier) {
            resolvedZone = fallbackZone
            resolvedHour = fallbackHour
        } else {
            // Should be unreachable — America/New_York is a guaranteed-valid identifier.
            return now.addingTimeInterval(3600)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedZone

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = resolvedHour
        components.minute = 0
        components.second = 0

        guard let todayAtHour = calendar.date(from: components) else {
            return now.addingTimeInterval(3600)
        }

        if todayAtHour > now {
            return todayAtHour
        }

        guard let tomorrowAtHour = calendar.date(byAdding: .day, value: 1, to: todayAtHour) else {
            return now.addingTimeInterval(3600)
        }
        return tomorrowAtHour
    }
}
