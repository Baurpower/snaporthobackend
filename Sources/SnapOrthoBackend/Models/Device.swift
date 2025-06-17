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

    init() {}

    init(deviceToken: String, learnUserId: String, platform: String, appVersion: String, lastSeen: Date) {
        self.deviceToken = deviceToken
        self.learnUserId = learnUserId
        self.platform = platform
        self.appVersion = appVersion
        self.lastSeen = lastSeen
    }
}
