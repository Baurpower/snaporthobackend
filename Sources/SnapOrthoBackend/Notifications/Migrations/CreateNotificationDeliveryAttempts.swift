import Fluent
import FluentPostgresDriver
import SQLKit

struct CreateNotificationDeliveryAttempts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("notification_delivery_attempts")
            .id()
            .field("user_id", .uuid)
            .field(
                "device_token_id",
                .uuid,
                .references("user_device_tokens", "id", onDelete: .setNull)
            )
            .field("category", .string, .required)
            .field("notification_type", .string, .required)
            .field("title", .string, .required)
            .field("body", .string, .required)
            .field("deeplink", .string)
            .field("metadata", .json, .required)
            .field("status", .string, .required)
            .field("apns_id", .string)
            .field("error_code", .string)
            .field("error_message", .string)
            .field("created_at", .datetime)
            .field("sent_at", .datetime)
            .constraint(.sql(raw: """
                CHECK (status IN ('pending','sent','failed','skipped'))
            """))
            .create()

        if let pg = database as? any PostgresDatabase {
            try await pg.sql().raw("""
                ALTER TABLE notification_delivery_attempts
                ALTER COLUMN metadata SET DEFAULT '{}'::jsonb
            """).run()

            let indexes: [String] = [
                "CREATE INDEX idx_nda_user_id ON notification_delivery_attempts (user_id) WHERE user_id IS NOT NULL",
                "CREATE INDEX idx_nda_device_token_id ON notification_delivery_attempts (device_token_id) WHERE device_token_id IS NOT NULL",
                "CREATE INDEX idx_nda_category ON notification_delivery_attempts (category)",
                "CREATE INDEX idx_nda_type ON notification_delivery_attempts (notification_type)",
                "CREATE INDEX idx_nda_status ON notification_delivery_attempts (status)",
                "CREATE INDEX idx_nda_created_at ON notification_delivery_attempts (created_at DESC)",
            ]

            for sql in indexes {
                try await pg.sql().raw(SQLQueryString(sql)).run()
            }
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("notification_delivery_attempts").delete()
    }
}
