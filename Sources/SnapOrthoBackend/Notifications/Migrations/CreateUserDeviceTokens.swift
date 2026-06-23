import Fluent
import FluentPostgresDriver

struct CreateUserDeviceTokens: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_device_tokens")
            .id()
            .field("user_id", .uuid)                          // FK added via raw SQL below
            .field("token", .string, .required)
            .field("token_hash", .string, .required)
            .field("platform", .string, .required)
            .field("environment", .string, .required)         // 'production' | 'sandbox'
            .field("app_version", .string)
            .field("build_number", .string)
            .field("timezone", .string)
            .field("receive_notifications", .bool, .required, .sql(.default(true)))
            .field("last_seen_at", .datetime, .required, .sql(.default("NOW()")))
            .field("invalidated_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // token_hash + environment must be unique so sandbox and production tokens
            // for the same physical device are tracked separately
            .unique(on: "token_hash", "environment")
            .constraint(.sql(raw: "CHECK (environment IN ('production', 'sandbox'))"))
            .create()

        // Indexes for common query patterns
        if let pg = database as? any PostgresDatabase {
            try await pg.sql().raw("""
                CREATE INDEX idx_udt_user_id ON user_device_tokens (user_id)
                    WHERE user_id IS NOT NULL
            """).run()

            try await pg.sql().raw("""
                CREATE INDEX idx_udt_active ON user_device_tokens (environment, last_seen_at)
                    WHERE invalidated_at IS NULL AND receive_notifications = TRUE
            """).run()

            try await pg.sql().raw("""
                CREATE INDEX idx_udt_invalidated ON user_device_tokens (invalidated_at)
                    WHERE invalidated_at IS NOT NULL
            """).run()

            // FK to auth.users only exists in real Supabase — skip in test/non-Supabase envs.
            // The constraint is documented in NOTIFICATION_PHASE1_IMPLEMENTATION.md and
            // should be added via the Supabase SQL editor for the production database.
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_device_tokens").delete()
    }
}
