import Vapor
import Fluent

final class Device: Model, Content, @unchecked Sendable {
    static let schema = "devices"

    // ── Fields ─────────────────────────────────────────────
    @ID(key: .id)                     var id: UUID?
    @Field(key: "device_token")       var deviceToken: String
    @Field(key: "learn_user_id")      var learnUserId: String
    @Field(key: "platform")           var platform: String
    @Field(key: "app_version")        var appVersion: String
    @Field(key: "last_seen")          var lastSeen: Date
    @Field(key: "language")           var language: String?
    @Field(key: "timezone")           var timezone: String?
    @Field(key: "receive_notifications") var receiveNotifications: Bool
    @Field(key: "last_notified")      var lastNotified: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    // ── Coding keys ───────────────────────────────────────
    // Maps JSON <--> Swift property names, so either
    // `app_version` or `appVersion` in the incoming JSON
    // will populate `appVersion`.
    enum CodingKeys: String, CodingKey {
        case id
        case deviceToken         = "device_token"
        case learnUserId         = "learn_user_id"
        case platform
        case appVersion          = "app_version"
        case lastSeen            = "last_seen"
        case language
        case timezone
        case receiveNotifications = "receive_notifications"
        case lastNotified        = "last_notified"
        case createdAt           = "created_at"
        case updatedAt           = "updated_at"
    }

    // ── Init boilerplate ──────────────────────────────────
    init() {}

    init(
        deviceToken: String,
        learnUserId: String,
        platform: String,
        appVersion: String,
        lastSeen: Date,
        language: String? = nil,
        timezone: String? = nil,
        receiveNotifications: Bool = true,
        lastNotified: Date? = nil
    ) {
        self.deviceToken          = deviceToken
        self.learnUserId          = learnUserId
        self.platform             = platform
        self.appVersion           = appVersion
        self.lastSeen             = lastSeen
        self.language             = language
        self.timezone             = timezone
        self.receiveNotifications = receiveNotifications
        self.lastNotified         = lastNotified
    }
}
