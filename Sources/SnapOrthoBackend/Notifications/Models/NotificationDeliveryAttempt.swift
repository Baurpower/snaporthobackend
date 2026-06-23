import Fluent
import Vapor

final class NotificationDeliveryAttempt: Model, @unchecked Sendable {
    static let schema = "notification_delivery_attempts"
    static let defaultDatabase: DatabaseID? = .notifications

    @ID(key: .id) var id: UUID?

    @OptionalField(key: "user_id") var userId: UUID?
    @OptionalParent(key: "device_token_id") var deviceToken: UserDeviceToken?

    @Field(key: "category") var category: String
    @Field(key: "notification_type") var notificationType: String
    @Field(key: "title") var title: String
    @Field(key: "body") var body: String
    @OptionalField(key: "deeplink") var deeplink: String?
    @Field(key: "metadata") var metadata: [String: String]

    @Field(key: "status") var status: DeliveryStatus
    @OptionalField(key: "apns_id") var apnsId: String?
    @OptionalField(key: "error_code") var errorCode: String?
    @OptionalField(key: "error_message") var errorMessage: String?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "sent_at") var sentAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID?,
        deviceTokenId: UUID?,
        category: NotificationCategory,
        notificationType: String,
        title: String,
        body: String,
        deeplink: String?,
        metadata: [String: String] = [:],
        status: DeliveryStatus,
        apnsId: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        sentAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.$deviceToken.id = deviceTokenId
        self.category = category.rawValue
        self.notificationType = notificationType
        self.title = title
        self.body = body
        self.deeplink = deeplink
        self.metadata = metadata
        self.status = status
        self.apnsId = apnsId
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.sentAt = sentAt
    }

    enum DeliveryStatus: String, Codable, Sendable {
        case pending
        case sent
        case failed
        case skipped
    }
}
