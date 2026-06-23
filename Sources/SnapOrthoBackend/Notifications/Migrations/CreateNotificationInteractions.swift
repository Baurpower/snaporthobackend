import Fluent
import FluentPostgresDriver

struct CreateNotificationInteractions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("notification_interactions")
            .id()
            .field(
                "delivery_attempt_id",
                .uuid,
                .required,
                .references("notification_delivery_attempts", "id", onDelete: .cascade)
            )
            .field("user_id", .uuid)                          // nullable — mirrors notification_delivery_attempts.user_id
            .field("action", .string, .required)
            .field("app_version", .string)
            .field("interacted_at", .datetime)
            .constraint(.sql(raw: """
                CHECK (action IN ('opened','dismissed','deep_link_completed'))
            """))
            .create()

        if let pg = database as? any PostgresDatabase {
            try await pg.sql().raw("""
                CREATE INDEX idx_ni_delivery_attempt_id ON notification_interactions (delivery_attempt_id)
            """).run()

            try await pg.sql().raw("""
                CREATE INDEX idx_ni_user_id ON notification_interactions (user_id)
                    WHERE user_id IS NOT NULL
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("notification_interactions").delete()
    }
}
