import Fluent
import Vapor
import Crypto

// MARK: - Database ID

extension DatabaseID {
    static var notifications: DatabaseID { .init(string: "notifications") }
}

// MARK: - Model

final class UserDeviceToken: Model, @unchecked Sendable {
    static let schema = "user_device_tokens"
    // All queries on this model target the Supabase/notifications database
    static let defaultDatabase: DatabaseID? = .notifications

    @ID(key: .id) var id: UUID?

    /// Supabase auth.users UUID. NULL for pre-auth / anonymous device registrations.
    @OptionalField(key: "user_id") var userId: UUID?

    /// Raw APNS device token. Never returned in API responses.
    @Field(key: "token") var token: String

    /// SHA-256 hex of the raw token. Used for deduplication. Safe to log (prefix only).
    @Field(key: "token_hash") var tokenHash: String

    @Field(key: "platform") var platform: String

    /// "production" or "sandbox". Must match the APNS environment used to send.
    @Field(key: "environment") var environment: String

    @OptionalField(key: "app_version") var appVersion: String?
    @OptionalField(key: "build_number") var buildNumber: String?
    @OptionalField(key: "timezone") var timezone: String?

    @Field(key: "receive_notifications") var receiveNotifications: Bool

    @Field(key: "last_seen_at") var lastSeenAt: Date

    /// Set when APNS returns BadDeviceToken or Unregistered. Excluded from future sends.
    @OptionalField(key: "invalidated_at") var invalidatedAt: Date?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID?,
        token: String,
        platform: String = "ios",
        environment: String,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        timezone: String? = nil,
        receiveNotifications: Bool = true,
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.token = token
        self.tokenHash = UserDeviceToken.hash(token)
        self.platform = platform
        self.environment = environment
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.timezone = timezone
        self.receiveNotifications = receiveNotifications
        self.lastSeenAt = lastSeenAt
    }

    // MARK: - Token helpers

    static func hash(_ rawToken: String) -> String {
        let digest = SHA256.hash(data: Data(rawToken.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Safe prefix for logging — never log the full raw token.
    static func logSafePrefix(of tokenHash: String) -> String {
        String(tokenHash.prefix(12))
    }

    var isActive: Bool { invalidatedAt == nil }
}
