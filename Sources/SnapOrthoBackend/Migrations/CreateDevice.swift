import Fluent

struct CreateDevice: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema("devices")
            .id()
            .field("device_token", .string, .required)
            .field("learn_user_id", .string, .required)
            .field("platform", .string, .required)
            .field("app_version", .string, .required)
            .field("last_seen", .datetime, .required)

            // ✅ Notification-friendly additions
            .field("language", .string)                         // e.g., "en", "es"
            .field("timezone", .string)                         // e.g., "America/New_York"
            .field("receive_notifications", .bool, .sql(.default(true)))  // opt-out logic
            .field("last_notified", .datetime)                  // track most recent notification
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)

            .unique(on: "device_token")
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("devices").delete()
    }
}
