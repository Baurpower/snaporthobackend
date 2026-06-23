import Fluent
import Vapor

/// Versioned copy for a notification type. Rendering ({{variable}} substitution) is a
/// Phase 2B+ concern — this model is storage only for Phase 2A.
final class NotificationTemplate: Model, @unchecked Sendable {
    static let schema = "notification_templates"
    static let defaultDatabase: DatabaseID? = .notifications

    @ID(key: .id) var id: UUID?

    @Field(key: "notification_type") var notificationType: String

    @Field(key: "category") var category: String

    @Field(key: "title_template") var titleTemplate: String

    @Field(key: "body_template") var bodyTemplate: String

    @OptionalField(key: "deeplink_template") var deeplinkTemplate: String?

    @Field(key: "is_active") var isActive: Bool

    @Field(key: "version") var version: Int

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        notificationType: String,
        category: NotificationCategory,
        titleTemplate: String,
        bodyTemplate: String,
        deeplinkTemplate: String? = nil,
        isActive: Bool = true,
        version: Int = 1
    ) {
        self.id = id
        self.notificationType = notificationType
        self.category = category.rawValue
        self.titleTemplate = titleTemplate
        self.bodyTemplate = bodyTemplate
        self.deeplinkTemplate = deeplinkTemplate
        self.isActive = isActive
        self.version = version
    }
}
