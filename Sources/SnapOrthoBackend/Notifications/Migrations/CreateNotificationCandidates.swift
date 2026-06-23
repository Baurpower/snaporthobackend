import Fluent
import FluentPostgresDriver

struct CreateNotificationCandidates: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("notification_candidates")
            .id()
            .field("user_id", .uuid, .required)               // FK to auth.users — added via Supabase SQL, see Phase 1 pattern
            .field("source_type", .string, .required)
            .field("source_ref_id", .uuid)                    // nullable — see uniqueness note below
            .field("category", .string, .required)
            .field("priority_score", .int, .required)
            .field("payload", .json, .required)
            .field("eligible_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("status", .string, .required, .sql(.default("pending")))
            .field("created_at", .datetime)
            .constraint(.sql(raw: """
                CHECK (status IN ('pending','sent','expired','superseded','cooldown_blocked'))
            """))
            .constraint(.sql(raw: """
                CHECK (category IN ('system','learning','caseprep','brobot','reminders','product'))
            """))
            .create()

        if let pg = database as? any PostgresDatabase {
            try await pg.sql().raw("""
                ALTER TABLE notification_candidates
                ALTER COLUMN payload SET DEFAULT '{}'::jsonb
            """).run()

            // Plain UNIQUE(user_id, source_type, source_ref_id) would NOT prevent duplicate
            // candidates when source_ref_id IS NULL — Postgres treats every NULL as distinct
            // in a unique constraint. Coalescing to a sentinel UUID makes idempotency hold
            // for source types with no specific referenced row (e.g. a static daily pearl),
            // not just ones with a real conversation/question id.
            try await pg.sql().raw("""
                CREATE UNIQUE INDEX idx_nc_dedupe ON notification_candidates (
                    user_id,
                    source_type,
                    COALESCE(source_ref_id, '00000000-0000-0000-0000-000000000000'::uuid)
                )
            """).run()

            try await pg.sql().raw("""
                CREATE INDEX idx_nc_pending_eligible ON notification_candidates (status, eligible_at)
                    WHERE status = 'pending'
            """).run()

            try await pg.sql().raw("""
                CREATE INDEX idx_nc_user_id ON notification_candidates (user_id)
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("notification_candidates").delete()
    }
}
