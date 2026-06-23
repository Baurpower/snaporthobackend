import Fluent
import Vapor

final class NotificationPreference: Model, Content, @unchecked Sendable {
    static let schema = "notification_preferences"
    static let defaultDatabase: DatabaseID? = .notifications

    @ID(key: .id) var id: UUID?

    /// Supabase auth.users UUID. Required — anonymous users do not have preferences.
    @Field(key: "user_id") var userId: UUID

    @Field(key: "category") var category: String

    @Field(key: "enabled") var enabled: Bool

    /// Hour (0–23) in user's local time zone when quiet period starts. Nil = no quiet hours.
    @OptionalField(key: "quiet_hours_start") var quietHoursStart: Int?

    /// Hour (0–23) in user's local time zone when quiet period ends.
    @OptionalField(key: "quiet_hours_end") var quietHoursEnd: Int?

    /// IANA timezone string, e.g. "America/Chicago". Used to interpret quiet hours.
    @OptionalField(key: "timezone") var timezone: String?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        category: NotificationCategory,
        enabled: Bool = true,
        quietHoursStart: Int? = nil,
        quietHoursEnd: Int? = nil,
        timezone: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.category = category.rawValue
        self.enabled = enabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.timezone = timezone
    }
}

// MARK: - DTO

struct NotificationPreferenceDTO: Content {
    let category: String
    let enabled: Bool
    let quietHoursStart: Int?
    let quietHoursEnd: Int?
    let timezone: String?
}

struct NotificationPreferencesResponseDTO: Content {
    let preferences: [NotificationPreferenceDTO]
}

extension NotificationPreference {
    func toDTO() -> NotificationPreferenceDTO {
        .init(
            category: category,
            enabled: enabled,
            quietHoursStart: quietHoursStart,
            quietHoursEnd: quietHoursEnd,
            timezone: timezone
        )
    }
}
