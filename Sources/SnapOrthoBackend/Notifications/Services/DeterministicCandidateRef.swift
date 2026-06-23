import Foundation
import Crypto

/// Synthesizes a deterministic `source_ref_id` for candidate types that recur on a schedule
/// (daily, every-14-days, etc.) rather than referencing one specific row (a conversation,
/// a question).
///
/// Why this exists: `notification_candidates` has `UNIQUE(user_id, source_type, COALESCE(
/// source_ref_id, sentinel))` (Phase 2A). If a recurring candidate type always passed
/// `sourceRefId: nil`, every day after the first would collide with day one's row forever —
/// Postgres unique constraints treat repeated NULLs in a tuple as a single value once
/// coalesced to the sentinel, so the user could never get a second daily pearl. Deriving a
/// stable, bucket-scoped UUID instead (e.g. one value per calendar day, or per 14-day window)
/// gives each recurrence its own slot while keeping the exact same DB constraint from Phase 2A.
enum DeterministicCandidateRef {
    /// Same (userId, sourceType, bucketKey) always produces the same UUID — pure function.
    static func forBucket(userId: UUID, sourceType: String, bucketKey: String) -> UUID {
        let input = "\(userId.uuidString)|\(sourceType)|\(bucketKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let bytes = Array(digest.prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuidString = [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20).prefix(12),
        ].joined(separator: "-")
        guard let uuid = UUID(uuidString: uuidString) else {
            // SHA-256 always yields 32 bytes, so this can only fail from a logic error above.
            preconditionFailure("DeterministicCandidateRef produced an invalid UUID string")
        }
        return uuid
    }

    /// `yyyy-MM-dd` in UTC — one bucket per calendar day. Used for daily-recurring types
    /// (daily_pearl, oite_question).
    static func dayBucketKey(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let components = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// A coarser bucket spanning `days` calendar days, anchored to the Unix epoch — used for
    /// types that recur on a multi-day cooldown (e.g. brobot.first_try, every 14 days) so the
    /// same user can receive a fresh one once the window rolls over.
    static func multiDayBucketKey(for date: Date, days: Int) -> String {
        let epochDays = Int(date.timeIntervalSince1970 / 86400)
        let bucket = epochDays / days
        return "\(days)d:\(bucket)"
    }
}
