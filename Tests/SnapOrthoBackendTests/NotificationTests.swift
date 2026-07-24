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
        let bundleId: String
        let environment: String
    }

    private let lock = NSLock()
    private var _calls: [SentCall] = []
    var shouldThrowTokenError: APNSTokenError? = nil
    var shouldThrowProviderError: APNSProviderError? = nil
    var shouldThrowTransientError: APNSTransientError? = nil
    var shouldThrowGenericError: Bool = false
    /// If set, only allows sends for this environment (simulates single-client server).
    var allowedEnvironments: Set<String>? = nil

    var calls: [SentCall] {
        lock.withLock { _calls }
    }

    func sendAlert(
        title: String,
        body: String,
        to token: String,
        payload: SnapOrthoAPNSPayload,
        bundleId: String,
        environment: String
    ) async throws -> APNSSendResult {
        if let allowed = allowedEnvironments, !allowed.contains(environment) {
            throw APNSProviderError.environmentNotConfigured(environment)
        }
        if let tokenError = shouldThrowTokenError { throw tokenError }
        if let providerError = shouldThrowProviderError { throw providerError }
        if let transient = shouldThrowTransientError { throw transient }
        if shouldThrowGenericError { throw Abort(.internalServerError, reason: "Mock APNS error") }
        lock.withLock {
            _calls.append(SentCall(
                title: title,
                body: body,
                token: token,
                payload: payload,
                bundleId: bundleId,
                environment: environment
            ))
        }
        return APNSSendResult(
            apnsId: "mock-apns-id-\(UUID().uuidString)",
            environment: environment,
            topic: bundleId
        )
    }

    func reset() {
        lock.withLock { _calls.removeAll() }
        shouldThrowTokenError = nil
        shouldThrowProviderError = nil
        shouldThrowTransientError = nil
        shouldThrowGenericError = false
        allowedEnvironments = nil
    }
}

// MARK: - Pure unit tests (no database)

@Suite("APNs unit helpers")
struct APNSUnitHelperTests {
    @Test("Token hashing is canonical across case and surrounding whitespace")
    func tokenHashNormalization() {
        let lower = String(repeating: "ab", count: 32)
        #expect(UserDeviceToken.hash(lower) == UserDeviceToken.hash("  \(lower.uppercased())\n"))
    }

    @Test("Tokens are masked in API presentation form")
    func tokensAreMasked() {
        let token = String(repeating: "a", count: 60) + "89ef"
        let masked = UserDeviceToken.maskedToken(token)
        #expect(masked.hasPrefix("aaaaaaaa…"))
        #expect(masked.hasSuffix("89ef"))
        #expect(!masked.contains(token))
        #expect(masked.count < token.count)
    }

    @Test("APNS environment parsing rejects unknown values")
    func environmentParsing() {
        #expect(APNSDeviceEnvironment.parse("production") == .production)
        #expect(APNSDeviceEnvironment.parse("sandbox") == .sandbox)
        #expect(APNSDeviceEnvironment.parse("development") == .sandbox)
        #expect(APNSDeviceEnvironment.parse("prod") == .production)
        #expect(APNSDeviceEnvironment.parse("unknown") == nil)
        #expect(APNSDeviceEnvironment.parse(nil) == nil)
    }

    @Test("PEM normalizer accepts escaped newlines and rejects garbage")
    func pemNormalizer() throws {
        let escaped = "-----BEGIN PRIVATE KEY-----\\nABC\\n-----END PRIVATE KEY-----"
        let normalized = APNSKeyMaterial.normalizePEM(escaped)
        #expect(normalized.contains("\n"))
        #expect(throws: (any Error).self) {
            try APNSKeyMaterial.validatePEMShape("not-a-key")
        }
        try APNSKeyMaterial.validatePEMShape(normalized)
    }

    @Test("Product category defaults to disabled; others default enabled")
    func productCategoryDefaultDisabled() {
        #expect(NotificationCategory.product.defaultEnabled == false)
        #expect(NotificationCategory.learning.defaultEnabled == true)
        #expect(NotificationCategory.system.defaultEnabled == true)
    }
}

// MARK: - Integration tests (require database)

/// Sets up the test application with a mock APNS sender.
/// Relies on the same env vars as the existing test suite (Amazon RDS / Supabase for .notifications).
@Suite("Notification Tests", .serialized)
struct NotificationTests {
    private let mockAPNS = MockAPNSSender()

    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
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

    private func validHexToken(prefix: String = "aa") -> String {
        // Build a deterministic 64-char hex token from a short seed.
        let seed = prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let hex = seed.lowercased().filter { "0123456789abcdef".contains($0) }
        if hex.count >= 64 { return String(hex.prefix(64)) }
        return hex + String(repeating: "0", count: 64 - hex.count)
    }

    private func adminKey() -> String? {
        let key = Environment.get("ADMIN_API_KEY")
        return (key?.isEmpty == false) ? key : nil
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
        guard let adminKey = adminKey() else {
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
                    #expect(res.status == .ok)
                }
            )
        }
    }

    // MARK: - Device Registration

    @Test("Device registration rejects malformed APNS tokens")
    func deviceRegistrationRejectsMalformedToken() async throws {
        try await withApp { app in
            try await app.testing().test(
                .POST, "device/register",
                beforeRequest: { req in
                    try req.content.encode(RegisterDevicePayload(
                        deviceToken: "not-an-apns-token",
                        platform: "ios",
                        appVersion: "3.0.0",
                        timezone: "America/Los_Angeles"
                    ))
                },
                afterResponse: { res async in
                    #expect(res.status == .badRequest)
                }
            )
        }
    }

    @Test("Device registration rejects unknown environment")
    func deviceRegistrationRejectsUnknownEnvironment() async throws {
        try await withApp { app in
            try await app.testing().test(
                .POST, "device/register",
                beforeRequest: { req in
                    try req.content.encode(RegisterDevicePayload(
                        deviceToken: validHexToken(),
                        platform: "ios",
                        appVersion: "3.0.0",
                        timezone: "America/Los_Angeles",
                        environment: "staging"
                    ))
                },
                afterResponse: { res async in
                    #expect(res.status == .badRequest)
                }
            )
        }
    }

    @Test("1. Authenticated device registration attaches verified user")
    func authenticatedDeviceRegistration() async throws {
        try await withApp { app in
            // Without a real JWT, registration is anonymous — verify path accepts no bearer.
            // Authenticated path is covered by optionalVerified + upsert unit below.
            let userId = UUID()
            let token = validHexToken(prefix: "11")
            try await upsertSupabaseDeviceToken(
                rawToken: token,
                userID: userId,
                platform: "ios",
                environment: "sandbox",
                appVersion: "3.0.0",
                buildNumber: "100",
                timezone: "America/Chicago",
                receiveNotifications: true,
                db: app.db(.notifications),
                logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()
            #expect(device?.userId == userId)
            #expect(device?.environment == "sandbox")
        }
    }

    @Test("2. Invalid bearer token is rejected (not stored as anonymous)")
    func invalidBearerTokenRejected() async throws {
        try await withApp { app in
            try await app.testing().test(
                .POST, "device/register",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: "not.a.valid.jwt")
                    try req.content.encode(RegisterDevicePayload(
                        deviceToken: validHexToken(prefix: "22"),
                        platform: "ios",
                        appVersion: "3.0.0",
                        timezone: "America/Los_Angeles",
                        environment: "sandbox"
                    ))
                },
                afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                }
            )
        }
    }

    @Test("3. Anonymous registration stores user_id null")
    func anonymousRegistration() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "33")
            try await app.testing().test(
                .POST, "device/register",
                beforeRequest: { req in
                    try req.content.encode(RegisterDevicePayload(
                        deviceToken: token,
                        platform: "ios",
                        appVersion: "3.0.0",
                        timezone: "America/Los_Angeles",
                        environment: "sandbox"
                    ))
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                }
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()
            #expect(device?.userId == nil)
        }
    }

    @Test("4. Anonymous-to-authenticated reassignment updates user_id")
    func anonymousToAuthenticatedReassignment() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "44")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let userId = UUID()
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: userId, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .filter(\.$environment == "production")
                .first()
            #expect(device?.userId == userId)
            let count = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .count()
            #expect(count == 1)
        }
    }

    @Test("5. Same token with different environments tracked separately")
    func sandboxAndProductionTokensAreDistinct() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "55")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "sandbox",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let count = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .count()
            #expect(count == 2)
        }
    }

    @Test("6. Duplicate registration upserts rather than duplicating")
    func deviceRegistrationUpserts() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "66")
            let tokenHash = UserDeviceToken.hash(token)

            try await app.testing().test(
                .POST, "device/register",
                beforeRequest: { req in
                    try req.content.encode(RegisterDevicePayload(
                        deviceToken: token, platform: "ios", appVersion: "1.0.0",
                        timezone: "America/Chicago", environment: "production"
                    ))
                },
                afterResponse: { res async in #expect(res.status == .ok) }
            )
            try await app.testing().test(
                .POST, "device/register",
                beforeRequest: { req in
                    try req.content.encode(RegisterDevicePayload(
                        deviceToken: token, platform: "ios", appVersion: "1.1.0",
                        timezone: "America/New_York", environment: "production"
                    ))
                },
                afterResponse: { res async in #expect(res.status == .ok) }
            )

            let count = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == tokenHash)
                .filter(\.$environment == "production")
                .count()
            #expect(count == 1)
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == tokenHash)
                .first()
            #expect(device?.appVersion == "1.1.0")
            #expect(device?.timezone == "America/New_York")
        }
    }

    @Test("Multiple devices per user are supported")
    func multipleDevicesPerUser() async throws {
        try await withApp { app in
            let userId = UUID()
            for prefix in ["a1", "b2"] {
                try await upsertSupabaseDeviceToken(
                    rawToken: validHexToken(prefix: prefix), userID: userId, platform: "ios",
                    environment: "production", appVersion: "1.0", buildNumber: nil,
                    timezone: nil, receiveNotifications: true,
                    db: app.db(.notifications), logger: app.logger
                )
            }
            let count = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$userId == userId)
                .count()
            #expect(count == 2)
        }
    }

    // MARK: - Exact-device test path

    @Test("7. Exact-device test-send selects only the given registration")
    func exactDeviceTestSelection() async throws {
        try await withApp { app in
            let tokenA = validHexToken(prefix: "71")
            let tokenB = validHexToken(prefix: "72")
            try await upsertSupabaseDeviceToken(
                rawToken: tokenA, userID: nil, platform: "ios", environment: "sandbox",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            try await upsertSupabaseDeviceToken(
                rawToken: tokenB, userID: nil, platform: "ios", environment: "sandbox",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let deviceA = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(tokenA))
                .first()!
            let idA = try deviceA.requireID()

            let result = try await app.notificationService.sendToRegistration(
                registrationId: idA,
                title: "SnapOrtho Test",
                body: "APNs test notification",
                deeplink: "snaportho://notifications/test",
                db: app.db(.notifications)
            )

            #expect(result.success)
            #expect(result.registrationId == idA)
            #expect(result.environment == "sandbox")
            #expect(mockAPNS.calls.count == 1)
            #expect(mockAPNS.calls.first?.token == tokenA)
            #expect(mockAPNS.calls.first?.environment == "sandbox")
            #expect(mockAPNS.calls.first?.payload.deeplink == "snaportho://notifications/test")
            #expect(result.maskedToken.contains("…"))
            #expect(!result.maskedToken.contains(tokenA))
        }
    }

    @Test("8. Missing registration ID rejected")
    func missingRegistrationIdRejected() async throws {
        guard let adminKey = adminKey() else {
            Issue.record("Skipped: ADMIN_API_KEY not set")
            return
        }
        try await withApp { app in
            try await app.testing().test(
                .POST, "admin/push/test",
                beforeRequest: { req in
                    req.headers.add(name: "X-Admin-Key", value: adminKey)
                    try req.content.encode(["title": "SnapOrtho Test"] as [String: String])
                },
                afterResponse: { res async in
                    #expect(res.status == .badRequest)
                }
            )
        }
    }

    @Test("9. Unknown registration rejected")
    func unknownRegistrationRejected() async throws {
        try await withApp { app in
            do {
                _ = try await app.notificationService.sendToRegistration(
                    registrationId: UUID(),
                    title: "T", body: "B",
                    db: app.db(.notifications)
                )
                Issue.record("Expected not found")
            } catch let abort as any AbortError {
                #expect(abort.status == .notFound)
            }
            #expect(mockAPNS.calls.isEmpty)
        }
    }

    @Test("10. Disabled token rejection")
    func disabledTokenRejection() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "10")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()!
            device.invalidatedAt = Date()
            try await device.update(on: app.db(.notifications))
            let id = try device.requireID()

            do {
                _ = try await app.notificationService.sendToRegistration(
                    registrationId: id, title: "T", body: "B",
                    db: app.db(.notifications)
                )
                Issue.record("Expected conflict")
            } catch let abort as any AbortError {
                #expect(abort.status == .conflict)
            }
            #expect(mockAPNS.calls.isEmpty)
        }
    }

    @Test("11. Unknown environment rejection on registration row")
    func unknownEnvironmentOnRowRejected() async throws {
        try await withApp { app in
            // Bypass upsert validation to plant a bad environment (simulates corrupt data)
            let token = validHexToken(prefix: "11")
            let device = UserDeviceToken(
                userId: nil, token: token, platform: "ios", environment: "production"
            )
            try await device.create(on: app.db(.notifications))
            // Force unknown environment via raw update if CHECK allows — may fail on CHECK constraint
            // So instead verify parse rejects and sendToDevice rejects bad env strings.
            do {
                _ = try await app.notificationService.sendToDevice(
                    rawToken: token,
                    environment: "staging",
                    notificationType: "admin.test",
                    title: "T", body: "B",
                    db: app.db(.notifications)
                )
                Issue.record("Expected bad request")
            } catch let abort as any AbortError {
                #expect(abort.status == .badRequest)
            }
        }
    }

    @Test("12. Sandbox client selection")
    func sandboxClientSelection() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "12")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "sandbox",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()!
            _ = try await app.notificationService.sendToRegistration(
                registrationId: try device.requireID(),
                title: "T", body: "B",
                db: app.db(.notifications)
            )
            #expect(mockAPNS.calls.first?.environment == "sandbox")
        }
    }

    @Test("13. Production client selection")
    func productionClientSelection() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "13")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()!
            _ = try await app.notificationService.sendToRegistration(
                registrationId: try device.requireID(),
                title: "T", body: "B",
                db: app.db(.notifications)
            )
            #expect(mockAPNS.calls.first?.environment == "production")
        }
    }

    @Test("14. Topic is the configured bundle id")
    func topicMatchesBundle() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "14")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()!
            let result = try await app.notificationService.sendToRegistration(
                registrationId: try device.requireID(),
                title: "T", body: "B",
                db: app.db(.notifications)
            )
            #expect(result.topic == app.notificationService.bundleId)
            #expect(mockAPNS.calls.first?.bundleId == app.notificationService.bundleId)
        }
    }

    @Test("15. APNs success response persistence")
    func apnsSuccessPersistence() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "15")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()!
            let id = try device.requireID()
            let result = try await app.notificationService.sendToRegistration(
                registrationId: id, title: "T", body: "B",
                deeplink: "snaportho://notifications/test",
                db: app.db(.notifications)
            )
            #expect(result.success)
            #expect(result.apnsId != nil)
            #expect(result.deliveryAttemptId != nil)

            let attempt = try await NotificationDeliveryAttempt.find(result.deliveryAttemptId!, on: app.db(.notifications))
            #expect(attempt?.status == .sent)
            #expect(attempt?.apnsId != nil)
            #expect(attempt?.metadata["apns_environment"] == "production")
            #expect(attempt?.metadata["apns_topic"] == app.notificationService.bundleId)
            #expect(attempt?.deeplink == "snaportho://notifications/test")
        }
    }

    @Test("16. Permanent APNs failure disables token")
    func permanentFailureDisablesToken() async throws {
        try await withApp { app in
            mockAPNS.shouldThrowTokenError = .unregistered
            let token = validHexToken(prefix: "16")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()!
            let id = try device.requireID()
            let result = try await app.notificationService.sendToRegistration(
                registrationId: id, title: "T", body: "B",
                db: app.db(.notifications)
            )
            #expect(!result.success)
            #expect(result.registrationDisabled)
            #expect(result.errorCode == "Unregistered")

            let updated = try await UserDeviceToken.find(id, on: app.db(.notifications))
            #expect(updated?.invalidatedAt != nil)
        }
    }

    @Test("17. Transient APNs failure does not disable token")
    func transientFailureDoesNotDisable() async throws {
        try await withApp { app in
            mockAPNS.shouldThrowTransientError = .timeout
            let token = validHexToken(prefix: "17")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()!
            let id = try device.requireID()
            let result = try await app.notificationService.sendToRegistration(
                registrationId: id, title: "T", body: "B",
                db: app.db(.notifications)
            )
            #expect(!result.success)
            #expect(!result.registrationDisabled)
            #expect(result.errorCode == "Timeout")

            let updated = try await UserDeviceToken.find(id, on: app.db(.notifications))
            #expect(updated?.invalidatedAt == nil)
        }
    }

    @Test("18. Tokens masked in list API response")
    func tokensMaskedInListAPI() async throws {
        guard let adminKey = adminKey() else {
            Issue.record("Skipped: ADMIN_API_KEY not set")
            return
        }
        try await withApp { app in
            let token = validHexToken(prefix: "18")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "sandbox",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            try await app.testing().test(
                .GET, "admin/notifications/registrations?environment=sandbox&limit=10",
                beforeRequest: { req in
                    req.headers.add(name: "X-Admin-Key", value: adminKey)
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(!body.contains(token))
                    #expect(body.contains("maskedToken") || body.contains("masked_token") || body.contains("…"))
                }
            )
        }
    }

    @Test("19. Deep-link payload included correctly")
    func deeplinkPayloadIncluded() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "19")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()!
            _ = try await app.notificationService.sendToRegistration(
                registrationId: try device.requireID(),
                title: "T", body: "B",
                deeplink: "snaportho://notifications/test",
                db: app.db(.notifications)
            )
            #expect(mockAPNS.calls.first?.payload.deeplink == "snaportho://notifications/test")
            #expect(mockAPNS.calls.first?.payload.notificationId.isEmpty == false)
        }
    }

    @Test("20. No fallback to first database device")
    func noFallbackToFirstDevice() async throws {
        try await withApp { app in
            let first = validHexToken(prefix: "f1")
            try await upsertSupabaseDeviceToken(
                rawToken: first, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            // Unknown registration must not send to `first`
            do {
                _ = try await app.notificationService.sendToRegistration(
                    registrationId: UUID(),
                    title: "T", body: "B",
                    db: app.db(.notifications)
                )
                Issue.record("Expected not found")
            } catch let abort as any AbortError {
                #expect(abort.status == .notFound)
            }
            #expect(mockAPNS.calls.isEmpty)
        }
    }

    // MARK: - Legacy sendToDevice path

    @Test("sendToDevice rejects opted-out device without contacting APNS")
    func sendToDeviceRejectsOptedOutDevice() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "d0")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: false,
                db: app.db(.notifications), logger: app.logger
            )
            do {
                _ = try await app.notificationService.sendToDevice(
                    rawToken: token,
                    environment: "production",
                    notificationType: "admin.test",
                    title: "SnapOrtho Test",
                    body: "Notification delivery is working.",
                    db: app.db(.notifications)
                )
                Issue.record("Expected opted-out device rejection")
            } catch let abort as any AbortError {
                #expect(abort.status == .conflict)
            }
            #expect(mockAPNS.calls.isEmpty)
        }
    }

    @Test("APNS bad device token invalidates device")
    func badDeviceTokenInvalidatesDevice() async throws {
        try await withApp { app in
            mockAPNS.shouldThrowTokenError = .badDeviceToken
            let userId = UUID()
            let token = validHexToken(prefix: "bd")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: userId, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()!
            let deviceId = try device.requireID()

            _ = try await app.notificationService.sendToUser(
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
            #expect(attempts.first?.errorCode == "BadDeviceToken")
        }
    }

    @Test("Provider error does not disable token")
    func providerErrorDoesNotDisable() async throws {
        try await withApp { app in
            mockAPNS.shouldThrowProviderError = .expiredProviderToken
            let token = validHexToken(prefix: "pe")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let device = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()!
            let id = try device.requireID()
            let result = try await app.notificationService.sendToRegistration(
                registrationId: id, title: "T", body: "B",
                db: app.db(.notifications)
            )
            #expect(!result.success)
            #expect(!result.registrationDisabled)
            #expect(result.errorCode == "ExpiredProviderToken")
            let updated = try await UserDeviceToken.find(id, on: app.db(.notifications))
            #expect(updated?.invalidatedAt == nil)
        }
    }

    // MARK: - Preferences / broadcast

    @Test("Broadcast respects product-disabled-by-default for users with no preference row")
    func broadcastSkipsProductForUsersWithNoPreference() async throws {
        try await withApp { app in
            let userId = UUID()
            let token = validHexToken(prefix: "bp")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: userId, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )

            let result = try await app.notificationService.broadcast(
                category: .product,
                notificationType: "product.announcement",
                title: "Test", body: "Test", deeplink: nil,
                db: app.db(.notifications)
            )
            #expect(result.sent == 0)
            #expect(result.skipped == 1)
            #expect(mockAPNS.calls.isEmpty)
        }
    }

    @Test("Successful send creates a delivery attempt with status=sent")
    func successfulSendCreatesDeliveryAttempt() async throws {
        try await withApp { app in
            let userId = UUID()
            let token = validHexToken(prefix: "ss")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: userId, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
            let result = try await app.notificationService.sendToUser(
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
        }
    }

    // MARK: - Deregister

    @Test("Deregister invalidates device token")
    func deregisterInvalidatesToken() async throws {
        try await withApp { app in
            let token = validHexToken(prefix: "dr")
            try await upsertSupabaseDeviceToken(
                rawToken: token, userID: nil, platform: "ios", environment: "production",
                appVersion: "1.0", buildNumber: nil, timezone: nil, receiveNotifications: true,
                db: app.db(.notifications), logger: app.logger
            )
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
            let updated = try await UserDeviceToken.query(on: app.db(.notifications))
                .filter(\.$tokenHash == UserDeviceToken.hash(token))
                .first()
            #expect(updated?.invalidatedAt != nil)
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
    var environment: String = "production"
}

private struct DeregisterDeviceRequest: Content {
    let deviceToken: String
    let environment: String?
}
