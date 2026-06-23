import Fluent
import FluentPostgresDriver

struct CreateNotificationPreferences: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("notification_preferences")
            .id()
            .field("user_id", .uuid, .required)               // FK to auth.users — added via Supabase SQL
            .field("category", .string, .required)
            .field("enabled", .bool, .required, .sql(.default(true)))
            .field("quiet_hours_start", .int)                 // 0–23 in user's local time
            .field("quiet_hours_end", .int)                   // 0–23 in user's local time
            .field("timezone", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "category")
            .constraint(.sql(raw: """
                CHECK (category IN ('system','learning','caseprep','brobot','reminders','product'))
            """))
            .constraint(.sql(raw: """
                CHECK (quiet_hours_start IS NULL OR (quiet_hours_start >= 0 AND quiet_hours_start <= 23))
            """))
            .constraint(.sql(raw: """
                CHECK (quiet_hours_end IS NULL OR (quiet_hours_end >= 0 AND quiet_hours_end <= 23))
            """))
            .create()

        if let pg = database as? any PostgresDatabase {
            try await pg.sql().raw("""
                CREATE INDEX idx_np_user_id ON notification_preferences (user_id)
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("notification_preferences").delete()
    }
}

// MARK: - Seed default preferences for a user

extension CreateNotificationPreferences {
    /// Lazily inserts default preference rows for all categories if they don't exist.
    static func ensureDefaults(for userId: UUID, db: any Database) async throws {
        for category in NotificationCategory.allCases {
            let existing = try await NotificationPreference.query(on: db)
                .filter(\.$userId == userId)
                .filter(\.$category == category.rawValue)
                .first()
            if existing == nil {
                let pref = NotificationPreference(
                    userId: userId,
                    category: category,
                    enabled: category.defaultEnabled
                )
                try await pref.create(on: db)
            }
        }
    }
}
