import Vapor
import Fluent

final class Device: Model, Content, @unchecked Sendable {
    static let schema = "devices"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "device_token")
    var deviceToken: String

    @Field(key: "learn_user_id")
    var learnUserId: String

    @Field(key: "platform")
    var platform: String

    @Field(key: "app_version")
    var appVersion: String

    @Field(key: "last_seen")
    var lastSeen: Date

    // ✅ Notification-friendly additions
    @Field(key: "language")
    var language: String?

    @Field(key: "timezone")
    var timezone: String?

    @Field(key: "receive_notifications")
    var receiveNotifications: Bool?

    @Field(key: "last_notified")
    var lastNotified: Date?

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    init() {}

    init(
        deviceToken: String,
        learnUserId: String,
        platform: String,
        appVersion: String,
        lastSeen: Date,
        language: String? = nil,
        timezone: String? = nil,
        receiveNotifications: Bool? = true,
        lastNotified: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.deviceToken = deviceToken
        self.learnUserId = learnUserId
        self.platform = platform
        self.appVersion = appVersion
        self.lastSeen = lastSeen
        self.language = language
        self.timezone = timezone
        self.receiveNotifications = receiveNotifications
        self.lastNotified = lastNotified
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
