import Fluent
import FluentPostgresDriver

/// Phase 2B: adds a first-class `notification_type` column to `notification_candidates`.
/// Phase 2A only had `source_type` (the broad campaign bucket, e.g. "learning_daily").
/// Phase 2B needs the finer-grained type (e.g. "learning.daily_pearl" vs "learning.oite_question")
/// as a queryable column so the dispatcher can join it against `notification_templates`
/// without unpacking the payload JSON.
struct AddNotificationTypeToCandidates: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("notification_candidates")
            .field("notification_type", .string)
            .update()

        if let pg = database as? any PostgresDatabase {
            try await pg.sql().raw("""
                CREATE INDEX idx_nc_notification_type ON notification_candidates (notification_type)
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("notification_candidates")
            .deleteField("notification_type")
            .update()
    }
}
