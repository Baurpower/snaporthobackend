import Fluent
import FluentPostgresDriver

/// Phase 2B: adds finer-grained holdout flags alongside Phase 2A's `is_holdout`.
///
/// `is_holdout` (Phase 2A) is the permanent, randomly-assigned, global measurement holdout —
/// untouched by this migration, still the master kill-switch for clean retention measurement.
///
/// These three new flags are operator-set (default `false` for everyone — nobody is excluded
/// from a specific campaign type unless explicitly marked), intended for manually suppressing
/// individual users or cohorts from one growth surface without removing them from the global
/// holdout experiment. Nothing in Phase 2B auto-assigns these; that's a deliberate choice — see
/// NOTIFICATION_PHASE2B_IMPLEMENTATION.md.
struct AddGranularHoldoutColumns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("notification_user_state")
            .field("is_learning_holdout", .bool, .required, .sql(.default(false)))
            .field("is_brobot_holdout", .bool, .required, .sql(.default(false)))
            .field("is_all_growth_holdout", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("notification_user_state")
            .deleteField("is_learning_holdout")
            .deleteField("is_brobot_holdout")
            .deleteField("is_all_growth_holdout")
            .update()
    }
}
