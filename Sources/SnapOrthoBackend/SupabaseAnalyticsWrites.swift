import Vapor
import Fluent
import PostgresKit

enum SupabaseAnalyticsWrites {

    static func insertCasePrepLog(
        prompt: String,
        responseJSON: String,
        wasHelpful: Bool?,
        userFeedback: String?,
        source: String,
        db: any Database,
        logger: Logger
    ) async throws {
        guard let sql = db as? any PostgresDatabase else {
            throw Abort(.internalServerError, reason: "Supabase database driver unavailable")
        }

        try await sql.sql().raw("""
            INSERT INTO case_prep_logs
                (prompt, response_json, was_helpful, user_feedback, source)
            VALUES
                (\(bind: prompt),
                 \(bind: responseJSON),
                 \(bind: wasHelpful),
                 \(bind: userFeedback),
                 \(bind: source))
        """).run()

        logger.info("✅ [datastore] primary=supabase case_prep_write=success source=\(source)")
    }
}