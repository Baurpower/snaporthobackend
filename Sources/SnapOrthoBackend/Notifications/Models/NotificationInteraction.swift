import Fluent
import Vapor

/// Records what a user did with a delivered notification (open/dismiss/deep-link completion).
/// No endpoint writes to this yet in Phase 2A — the table exists so Phase 2B+ analytics and
/// the conversion-attribution join (strategy doc Part 7) have somewhere to land data.
final class NotificationInteraction: Model, @unchecked Sendable {
    static let schema = "notification_interactions"
    static let defaultDatabase: DatabaseID? = .notifications

    @ID(key: .id) var id: UUID?

    @Parent(key: "delivery_attempt_id") var deliveryAttempt: NotificationDeliveryAttempt

    @OptionalField(key: "user_id") var userId: UUID?

    @Field(key: "action") var action: InteractionAction

    @OptionalField(key: "app_version") var appVersion: String?

    @Timestamp(key: "interacted_at", on: .create) var interactedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        deliveryAttemptId: UUID,
        userId: UUID?,
        action: InteractionAction,
        appVersion: String? = nil
    ) {
        self.id = id
        self.$deliveryAttempt.id = deliveryAttemptId
        self.userId = userId
        self.action = action
        self.appVersion = appVersion
    }

    enum InteractionAction: String, Codable, Sendable {
        case opened
        case dismissed
        case deepLinkCompleted = "deep_link_completed"
    }
}
