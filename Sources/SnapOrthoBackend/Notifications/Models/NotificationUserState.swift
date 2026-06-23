import Fluent
import Vapor

/// Denormalized per-user send counters, reset daily/weekly by `CandidateSchedulerJob`.
/// Exists so candidate ranking doesn't need to re-scan `notification_delivery_attempts`
/// on every selection pass.
///
/// `user_id` is the logical key (one row per user, enforced by a unique constraint) rather
/// than the literal table primary key, matching this codebase's existing Fluent conventions
/// (e.g. `NotificationPreference` uses a synthetic `id` + `unique(user_id, category)` rather
/// than a composite primary key) so the model gets normal Fluent CRUD ergonomics.
final class NotificationUserState: Model, @unchecked Sendable {
    static let schema = "notification_user_state"
    static let defaultDatabase: DatabaseID? = .notifications

    @ID(key: .id) var id: UUID?

    @Field(key: "user_id") var userId: UUID

    @Field(key: "sends_today") var sendsToday: Int

    @Field(key: "sends_this_week") var sendsThisWeek: Int

    @OptionalField(key: "last_sent_at") var lastSentAt: Date?

    @OptionalField(key: "last_sent_category") var lastSentCategory: String?

    /// Start-of-day (local server time, UTC) this row's daily counter applies to.
    /// When this no longer matches "today," the scheduler resets `sendsToday` to 0.
    @OptionalField(key: "day_bucket") var dayBucket: Date?

    /// Start-of-week this row's weekly counter applies to. Same reset semantics as `dayBucket`.
    @OptionalField(key: "week_bucket") var weekBucket: Date?

    /// Deterministic, permanent holdout assignment — see `HoldoutAssignment`.
    /// Never reassigned once set.
    @Field(key: "is_holdout") var isHoldout: Bool

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        sendsToday: Int = 0,
        sendsThisWeek: Int = 0,
        lastSentAt: Date? = nil,
        lastSentCategory: String? = nil,
        dayBucket: Date? = nil,
        weekBucket: Date? = nil,
        isHoldout: Bool
    ) {
        self.id = id
        self.userId = userId
        self.sendsToday = sendsToday
        self.sendsThisWeek = sendsThisWeek
        self.lastSentAt = lastSentAt
        self.lastSentCategory = lastSentCategory
        self.dayBucket = dayBucket
        self.weekBucket = weekBucket
        self.isHoldout = isHoldout
    }
}
