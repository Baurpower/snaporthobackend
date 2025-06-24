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

            // Optional fields
            .field("language", .string)
            .field("timezone", .string)
            .field("receive_notifications", .bool, .sql(.default(true)))
            .field("last_notified", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)

            .unique(on: "device_token")
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema("devices").delete()
    }
}
