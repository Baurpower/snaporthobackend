@testable import SnapOrthoBackend
import VaporTesting
import Testing
import Vapor
import Fluent
import Crypto

// MARK: - Mock APNS sender

/// Records all send calls for assertion in tests. Never contacts real APNS.
final class MockAPNSSender: APNSSenderProtocol, @unchecked Sendable {
    struct SentCall: Sendable {
        let title: String
        let body: String
        let token: String
        let payload: SnapOrthoAPNSPayload
    }

    private let lock = NSLock()
    private var _calls: [SentCall] = []
    var shouldThrowTokenError: APNSTokenError? = nil
    var shouldThrowGenericError: Bool = false

    var calls: [SentCall] {
        lock.withLock { _calls }
    }

    func sendAlert(
        title: String,
        body: String,
        to token: String,
        payload: SnapOrthoAPNSPayload,
        bundleId: String
    ) async throws -> APNSSendResult {
        if let tokenError = shouldThrowTokenError { throw tokenError }
        if shouldThrowGenericError { throw Abort(.internalServerError, reason: "Mock APNS error") }
        lock.withLock {
            _calls.append(SentCall(title: title, body: body, token: token, payload: payload))
        }
        return APNSSendResult(apnsId: "mock-apns-id-\(UUID().uuidString)")
    }

    func reset() {
        lock.withLock { _calls.removeAll() }
        shouldThrowTokenError = nil
        shouldThrowGenericError = false
    }
}

// MARK: - Test harness

/// Sets up the test application with a mock APNS sender.
/// Relies on the same env vars as the existing test suite (Amazon RDS for both .psql and .notifications).
@Suite("Notification Tests", .serialized)
struct NotificationTests {
    private let mockAPNS = MockAPNSSender()

    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            // Replace the real APNS sender with our mock after configure() runs
            app.apnsSender = mockAPNS
            app.configureNotificationService()
            mockAPNS.reset()
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    // MARK: - Admin Auth

    @Test("Admin broadcast rejected when X-Admin-Key missing")
    func adminBroadcastRejectsUnauthenticated() async throws {
        try await withApp { app in
            try await app.testing().test(
                .POST, "admin/notifications/broadcast",
                beforeRequest: { req in
                    try req.content.encode([
                        "category": "product",
                        "notificationType": "product.test",
                        "title": "Test",
                        "body": "Test body"
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                }
            )
        }
    }

    @Test("Admin broadcast rejected when X-Admin-Key incorrect")
    func adminBroadcastRejectsWrongKey() async throws {
        try await withApp { app in
            try await app.testing().test(
                .POST, "admin/notifications/broadcast",
                beforeRequest: { req in
                    req.headers.add(name: "X-Admin-Key", value: "wrong-key")
                    try req.content.encode([
                        "category": "product",
                        "notificationType": "product.test",
                        "title": "Test",
                        "body": "Test body"
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .forbidden)
                }
            )
        }
    }

    @Test("Admin broadcast accepted with correct key")
    func adminBroadcastAcceptsCorrectKey() async throws {
        guard let adminKey = Environment.get("ADMIN_API_KEY"), !adminKey.isEmpty else {
            Issue.record("Skipped: ADMIN_API_KEY env var not set — set it to run this test")
            return
        }
        try await withApp { app in
            try await app.testing().test(
                .POST, "admin/notifications/broadcast",
                beforeRequest: { req in
                    req.headers.add(name: "X-Admin-Key", value: adminKey)
                    try req.content.encode([
                        "category": "product",
                        "notificationType": "product.test",
                        "title": "Test",
                        "body": "Test body"
                    ])
                },
                afterResponse: { res async in
                    // Returns 200 (even if 0 devices) — not 401/403
                    #expect(res.status == .ok)
                }
            )
        }
    }

    // MARK: - Device Registration

    @Test("Device registration upserts rather than duplicating")
    func deviceRegistrationUpserts() async throws {
        try await withApp { app in
            let token = "test-token-\(UUID().uuidString)"
            let tokenHash = UserDeviceToken.hash(token)

            // Register once
            try await app.testing().test(
                .POST, "device/register",
                beforeRequest: { req in
                    try req.content.encode(RegisterDevicePayload(
                        deviceToken: token,
                        platform: "ios",
                        appVersion: "1.0.0",
                        timezone: "America/Chicago"
                    ))
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                }
            )

            // Register again with same token
            try await app.testing().test(
                .POST, "device/register",
                beforeRequest: { req in
                    try req.content.encode(RegisterDevicePayload(
                        deviceToken: token,
                        platform: "ios",
                        appVersion: "1.1.0",
                        timezone: "America/New_York"
                    ))
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                }
            )

            // Should exist exactly once in Supabase
            let count = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == tokenHash)
                .count()
            #expect(count == 1)

            // Version should be updated to latest
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == tokenHash)
                .first()
            #expect(device?.appVersion == "1.1.0")
            #expect(device?.timezone == "America/New_York")
        }
    }

    @Test("Production and sandbox tokens for same device tracked separately")
    func sandboxAndProductionTokensAreDistinct() async throws {
        try await withApp { app in
            let token = "same-physical-device-token-\(UUID().uuidString)"

            // Insert production token
            let prodToken = UserDeviceToken(
                userId: nil,
                token: token,
                platform: "ios",
                environment: "production",
                appVersion: "1.0"
            )
            try await prodToken.create(on: app.db(.notifications))

            // Insert sandbox token (same raw token, different environment)
            let sandboxToken = UserDeviceToken(
                userId: nil,
                token: token,
                platform: "ios",
                environment: "sandbox",
                appVersion: "1.0"
            )
            try await sandboxToken.create(on: app.db(.notifications))

            let count = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .count()
            #expect(count == 2)
        }
    }

    @Test("Multiple devices per user are supported")
    func multipleDevicesPerUser() async throws {
        try await withApp { app in
            let userId = UUID()
            let tokens = ["token-device-a-\(UUID())", "token-device-b-\(UUID())"]

            for t in tokens {
                let d = UserDeviceToken(userId: userId, token: t, platform: "ios", environment: "production")
                try await d.create(on: app.db(.notifications))
            }

            let count = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$userId == userId)
                .count()
            #expect(count == 2)
        }
    }

    // MARK: - Deregister

    @Test("Deregister invalidates device token")
    func deregisterInvalidatesToken() async throws {
        try await withApp { app in
            let token = "token-to-deregister-\(UUID().uuidString)"
            let device = UserDeviceToken(userId: nil, token: token, platform: "ios", environment: "production")
            try await device.create(on: app.db(.notifications))
            #expect(device.invalidatedAt == nil)

            try await app.testing().test(
                .DELETE, "notifications/device-token",
                beforeRequest: { req in
                    try req.content.encode(DeregisterDeviceRequest(
                        deviceToken: token,
                        environment: "production"
                    ))
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                }
            )

            let updated = try await UserDeviceToken.find(device.id, on: app.db(.notifications))
            #expect(updated?.invalidatedAt != nil)
        }
    }

    @Test("Deregister is idempotent")
    func deregisterIsIdempotent() async throws {
        try await withApp { app in
            let token = "idempotent-deregister-\(UUID().uuidString)"
            let device = UserDeviceToken(userId: nil, token: token, platform: "ios", environment: "production")
            device.invalidatedAt = Date()   // already invalidated
            try await device.create(on: app.db(.notifications))

            try await app.testing().test(
                .DELETE, "notifications/device-token",
                beforeRequest: { req in
                    try req.content.encode(DeregisterDeviceRequest(
                        deviceToken: token,
                        environment: "production"
                    ))
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)   // not 404 or 409
                }
            )
        }
    }

    // MARK: - Category defaults

    @Test("Product category defaults to disabled; others default enabled")
    func productCategoryDefaultDisabled() {
        #expect(NotificationCategory.product.defaultEnabled == false)
        #expect(NotificationCategory.learning.defaultEnabled == true)
        #expect(NotificationCategory.system.defaultEnabled == true)
    }

    @Test("Broadcast respects product-disabled-by-default for users with no preference row")
    func broadcastSkipsProductForUsersWithNoPreference() async throws {
        try await withApp { app in
            let userId = UUID()
            let token = "broadcast-pref-token-\(UUID().uuidString)"
            let device = UserDeviceToken(userId: userId, token: token, platform: "ios", environment: "production")
            try await device.create(on: app.db(.notifications))
            // No NotificationPreference row exists for this user/category — product defaults to disabled

            let svc = app.notificationService
            let result = try await svc.broadcast(
                category: .product,
                notificationType: "product.announcement",
                title: "Test",
                body: "Test",
                deeplink: nil,
                db: app.db(.notifications)
            )

            #expect(result.sent == 0)
            #expect(result.skipped == 1)
            #expect(mockAPNS.calls.isEmpty)

            let attempts = try await NotificationDeliveryAttempt.query(on: app.db(.notifications))
                .filter(\.$userId == userId)
                .all()
            #expect(attempts.first?.status == .skipped)
            #expect(attempts.first?.errorCode == "category_disabled")
        }
    }

    @Test("Broadcast sends product notifications to users who explicitly opted in")
    func broadcastSendsProductForOptedInUsers() async throws {
        try await withApp { app in
            let userId = UUID()
            let token = "broadcast-optin-token-\(UUID().uuidString)"
            let device = UserDeviceToken(userId: userId, token: token, platform: "ios", environment: "production")
            try await device.create(on: app.db(.notifications))

            let pref = NotificationPreference(userId: userId, category: .product, enabled: true)
            try await pref.create(on: app.db(.notifications))

            let svc = app.notificationService
            let result = try await svc.broadcast(
                category: .product,
                notificationType: "product.announcement",
                title: "Test",
                body: "Test",
                deeplink: nil,
                db: app.db(.notifications)
            )

            #expect(result.sent == 1)
            #expect(result.skipped == 0)
        }
    }

    @Test("Broadcast always sends anonymous devices regardless of category default")
    func broadcastSendsAnonymousDevicesForProduct() async throws {
        try await withApp { app in
            let token = "broadcast-anon-token-\(UUID().uuidString)"
            let device = UserDeviceToken(userId: nil, token: token, platform: "ios", environment: "production")
            try await device.create(on: app.db(.notifications))

            let svc = app.notificationService
            let result = try await svc.broadcast(
                category: .product,
                notificationType: "product.announcement",
                title: "Test",
                body: "Test",
                deeplink: nil,
                db: app.db(.notifications)
            )

            // Anonymous devices have no user_id, so there's no preference row to check
            #expect(result.sent == 1)
        }
    }

    // MARK: - Admin test send logging

    @Test("sendToDevice creates delivery attempt with matching notification_id")
    func sendToDeviceLogsDeliveryAttempt() async throws {
        try await withApp { app in
            let token = "admin-test-token-\(UUID().uuidString)"
            let device = UserDeviceToken(userId: nil, token: token, platform: "ios", environment: "production")
            try await device.create(on: app.db(.notifications))

            let svc = app.notificationService
            let result = try await svc.sendToDevice(
                rawToken: token,
                environment: "production",
                category: .system,
                notificationType: "admin.test",
                title: "Test",
                body: "Test body",
                db: app.db(.notifications)
            )

            #expect(result.sent == 1)
            #expect(mockAPNS.calls.count == 1)

            let attempts = try await NotificationDeliveryAttempt.query(on: app.db(.notifications)).all()
            #expect(attempts.count == 1)
            #expect(attempts.first?.status == .sent)
            #expect(attempts.first?.notificationType == "admin.test")

            let attemptId = try attempts.first!.requireID().uuidString
            #expect(mockAPNS.calls.first?.payload.notificationId == attemptId)
        }
    }

    // MARK: - Preferences

    @Test("Unauthenticated preferences request rejected")
    func preferencesRequiresAuth() async throws {
        try await withApp { app in
            try await app.testing().test(
                .GET, "notifications/preferences",
                afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                }
            )
        }
    }

    @Test("Disabling a category causes sends to be skipped")
    func disabledCategoryCausesSkip() async throws {
        try await withApp { app in
            let userId = UUID()
            // Disable learning category
            let pref = NotificationPreference(
                userId: userId,
                category: .learning,
                enabled: false
            )
            try await pref.create(on: app.db(.notifications))

            // Create an active device for this user
            let token = "pref-test-token-\(UUID().uuidString)"
            let device = UserDeviceToken(userId: userId, token: token, platform: "ios", environment: "production")
            try await device.create(on: app.db(.notifications))

            let svc = app.notificationService
            let result = try await svc.sendToUser(
                userID: userId,
                category: .learning,
                notificationType: "learning.daily_question",
                title: "Daily Question",
                body: "Test question body",
                deeplink: "snaportho://learn/question/daily",
                db: app.db(.notifications)
            )

            #expect(result.skipped == 1)
            #expect(result.sent == 0)
            #expect(mockAPNS.calls.isEmpty)

            // A skipped delivery attempt should be logged
            let attempts = try await NotificationDeliveryAttempt.query(on: app.db(.notifications))
                .filter(\.$userId == userId)
                .all()
            #expect(attempts.count == 1)
            #expect(attempts.first?.status == .skipped)
        }
    }

    // MARK: - Delivery Logging

    @Test("Successful send creates a delivery attempt with status=sent")
    func successfulSendCreatesDeliveryAttempt() async throws {
        try await withApp { app in
            let userId = UUID()
            let token = "logging-test-token-\(UUID().uuidString)"
            let device = UserDeviceToken(userId: userId, token: token, platform: "ios", environment: "production")
            try await device.create(on: app.db(.notifications))

            let svc = app.notificationService
            let result = try await svc.sendToUser(
                userID: userId,
                category: .system,
                notificationType: "system.account",
                title: "Account Update",
                body: "Your account has been updated.",
                deeplink: nil,
                db: app.db(.notifications)
            )

            #expect(result.sent == 1)
            #expect(mockAPNS.calls.count == 1)
            #expect(mockAPNS.calls.first?.payload.type == "system.account")

            let attempts = try await NotificationDeliveryAttempt.query(on: app.db(.notifications))
                .filter(\.$userId == userId)
                .all()
            #expect(attempts.count == 1)
            #expect(attempts.first?.status == .sent)
            #expect(attempts.first?.notificationType == "system.account")
        }
    }

    @Test("Failed send creates a delivery attempt with status=failed")
    func failedSendCreatesFailedAttempt() async throws {
        try await withApp { app in
            mockAPNS.shouldThrowGenericError = true

            let userId = UUID()
            let token = "failed-send-token-\(UUID().uuidString)"
            let device = UserDeviceToken(userId: userId, token: token, platform: "ios", environment: "production")
            try await device.create(on: app.db(.notifications))

            let svc = app.notificationService
            let result = try await svc.sendToUser(
                userID: userId,
                category: .system,
                notificationType: "system.test",
                title: "Test",
                body: "Test",
                deeplink: nil,
                db: app.db(.notifications)
            )

            #expect(result.failed == 1)
            #expect(result.sent == 0)

            let attempts = try await NotificationDeliveryAttempt.query(on: app.db(.notifications))
                .filter(\.$userId == userId)
                .all()
            #expect(attempts.first?.status == .failed)
            #expect(attempts.first?.errorCode == "transient")
        }
    }

    @Test("APNS bad device token invalidates device and creates failed attempt")
    func badDeviceTokenInvalidatesDevice() async throws {
        try await withApp { app in
            mockAPNS.shouldThrowTokenError = .badDeviceToken

            let userId = UUID()
            let token = "bad-device-token-\(UUID().uuidString)"
            let device = UserDeviceToken(userId: userId, token: token, platform: "ios", environment: "production")
            try await device.create(on: app.db(.notifications))
            let deviceId = try device.requireID()

            let svc = app.notificationService
            _ = try await svc.sendToUser(
                userID: userId,
                category: .system,
                notificationType: "system.test",
                title: "Test",
                body: "Test",
                deeplink: nil,
                db: app.db(.notifications)
            )

            let updated = try await UserDeviceToken.find(deviceId, on: app.db(.notifications))
            #expect(updated?.invalidatedAt != nil)

            let attempts = try await NotificationDeliveryAttempt.query(on: app.db(.notifications)).all()
            #expect(attempts.first?.status == .failed)
            #expect(attempts.first?.errorCode == "invalid_token")
        }
    }

    @Test("APNS unregistered token invalidates device")
    func unregisteredTokenInvalidatesDevice() async throws {
        try await withApp { app in
            mockAPNS.shouldThrowTokenError = .unregistered

            let userId = UUID()
            let token = "unregistered-token-\(UUID().uuidString)"
            let device = UserDeviceToken(userId: userId, token: token, platform: "ios", environment: "production")
            try await device.create(on: app.db(.notifications))
            let deviceId = try device.requireID()

            let svc = app.notificationService
            _ = try await svc.sendToUser(
                userID: userId,
                category: .system,
                notificationType: "system.test",
                title: "Test",
                body: "Test",
                deeplink: nil,
                db: app.db(.notifications)
            )

            let updated = try await UserDeviceToken.find(deviceId, on: app.db(.notifications))
            #expect(updated?.invalidatedAt != nil)
        }
    }

    // MARK: - Backfill idempotency

    @Test("Backfill upsert does not duplicate tokens")
    func backfillIsIdempotent() async throws {
        try await withApp { app in
            let token = "backfill-test-token-\(UUID().uuidString)"
            let tokenHash = UserDeviceToken.hash(token)

            // Simulate running backfill twice
            for _ in 0..<2 {
                try await upsertSupabaseDeviceToken(
                    rawToken: token,
                    userID: nil,
                    platform: "ios",
                    environment: "production",
                    appVersion: "1.0",
                    buildNumber: nil,
                    timezone: "America/Chicago",
                    receiveNotifications: true,
                    db: app.db(.notifications),
                    logger: app.logger
                )
            }

            let count = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == tokenHash)
                .filter(\.$environment == "production")
                .count()
            #expect(count == 1)
        }
    }

    @Test("Backfill with non-UUID learn_user_id inserts with user_id = nil")
    func backfillHandlesInvalidUID() async throws {
        try await withApp { app in
            let token = "invalid-uid-backfill-\(UUID().uuidString)"

            // "anonymous" is not a UUID — should insert with user_id = nil
            let userID: UUID? = UUID(uuidString: "anonymous")  // nil
            #expect(userID == nil)

            try await upsertSupabaseDeviceToken(
                rawToken: token,
                userID: nil,
                platform: "ios",
                environment: "production",
                appVersion: "1.0",
                buildNumber: nil,
                timezone: nil,
                receiveNotifications: true,
                db: app.db(.notifications),
                logger: app.logger
            )

            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()
            #expect(device != nil)
            #expect(device?.userId == nil)
        }
    }
}

// MARK: - Helpers

private struct RegisterDevicePayload: Content {
    let deviceToken: String
    let platform: String
    let appVersion: String
    let timezone: String?
    var buildNumber: String? = nil
    var environment: String? = nil
}

private struct DeregisterDeviceRequest: Content {
    let deviceToken: String
    let environment: String?
}
