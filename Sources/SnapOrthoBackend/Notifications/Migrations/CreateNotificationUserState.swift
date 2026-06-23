import Fluent
import FluentPostgresDriver

struct CreateNotificationUserState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("notification_user_state")
            .id()
            .field("user_id", .uuid, .required)               // FK to auth.users — added via Supabase SQL, see Phase 1 pattern
            .field("sends_today", .int, .required, .sql(.default(0)))
            .field("sends_this_week", .int, .required, .sql(.default(0)))
            .field("last_sent_at", .datetime)
            .field("last_sent_category", .string)
            .field("day_bucket", .date)
            .field("week_bucket", .date)
            .field("is_holdout", .bool, .required, .sql(.default(false)))
            .unique(on: "user_id")
            .create()

        if let pg = database as? any PostgresDatabase {
            try await pg.sql().raw("""
                CREATE INDEX idx_nus_holdout ON notification_user_state (is_holdout)
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("notification_user_state").delete()
    }
}
