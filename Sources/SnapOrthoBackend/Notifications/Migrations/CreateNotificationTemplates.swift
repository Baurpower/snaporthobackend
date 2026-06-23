import Fluent
import FluentPostgresDriver

struct CreateNotificationTemplates: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("notification_templates")
            .id()
            .field("notification_type", .string, .required)
            .field("category", .string, .required)
            .field("title_template", .string, .required)
            .field("body_template", .string, .required)
            .field("deeplink_template", .string)
            .field("is_active", .bool, .required, .sql(.default(true)))
            .field("version", .int, .required, .sql(.default(1)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "notification_type")
            .constraint(.sql(raw: """
                CHECK (category IN ('system','learning','caseprep','brobot','reminders','product'))
            """))
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("notification_templates").delete()
    }
}
