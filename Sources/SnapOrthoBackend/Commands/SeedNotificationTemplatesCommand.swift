import Vapor
import Fluent

/// Idempotently upserts the Phase 2B notification templates. Seeding templates has no
/// user-facing effect by itself — it does not schedule or send anything. Safe to re-run;
/// upserts by `notification_type` rather than inserting duplicates.
///
/// Usage:
///   swift run SnapOrthoBackend seed-notification-templates
struct SeedNotificationTemplatesCommand: AsyncCommand {
    static let name = "seed-notification-templates"

    struct Signature: CommandSignature {}

    var help: String {
        "Idempotently seeds Phase 2B notification templates (learning + brobot.first_try)."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        try await Self.seed(application: context.application)
    }

    /// Testable core, separate from the thin CLI wrapper above (matches the pattern used by
    /// `CandidateSchedulerJob.tick` in Phase 2A) — avoids constructing a `CommandSignature`
    /// directly in tests.
    static func seed(application: Application) async throws {
        let logger = application.logger
        let db = application.db(.notifications)

        let templates: [NotificationTemplate] = [
            NotificationTemplate(
                notificationType: "learning.daily_pearl",
                category: .learning,
                titleTemplate: "Today's Ortho Pearl",
                bodyTemplate: "A quick high-yield review is ready.",
                deeplinkTemplate: "snaportho://brobot?mode=oite&source=notification_daily_pearl"
            ),
            NotificationTemplate(
                notificationType: "learning.oite_question",
                category: .learning,
                titleTemplate: "Daily OITE Question",
                bodyTemplate: "Test yourself with one high-yield ortho question.",
                deeplinkTemplate: "snaportho://brobot?mode=oite&source=notification_oite_daily"
            ),
            NotificationTemplate(
                notificationType: "brobot.first_try",
                category: .brobot,
                titleTemplate: "Try BroBot in 60 seconds",
                bodyTemplate: "Ask one ortho question or start a quick OITE review.",
                deeplinkTemplate: "snaportho://brobot?source=notification_first_try"
            ),
        ]

        var created = 0
        var updated = 0

        for template in templates {
            if let existing = try await NotificationTemplate.query(on: db)
                .filter(\.$notificationType == template.notificationType)
                .first()
            {
                existing.category = template.category
                existing.titleTemplate = template.titleTemplate
                existing.bodyTemplate = template.bodyTemplate
                existing.deeplinkTemplate = template.deeplinkTemplate
                existing.isActive = true
                try await existing.update(on: db)
                updated += 1
            } else {
                try await template.create(on: db)
                created += 1
            }
        }

        logger.info("✅ Templates seeded: created=\(created) updated=\(updated) total=\(templates.count)")
    }
}
