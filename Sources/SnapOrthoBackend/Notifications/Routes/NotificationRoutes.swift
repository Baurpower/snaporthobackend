import Vapor
import Fluent

// MARK: - Request/Response types

struct RegisterDeviceRequest: Content {
    let deviceToken: String
    let platform: String?
    let appVersion: String?
    let buildNumber: String?
    let environment: String?   // "production" | "sandbox" — optional for legacy callers
    let timezone: String?
    let receiveNotifications: Bool?

    // Legacy fields accepted for backward compatibility with existing iOS app
    let isAuthenticated: Bool?
    let language: String?      // stored in Amazon legacy table only
}

struct DeregisterDeviceRequest: Content {
    let deviceToken: String
    let environment: String?   // required for unambiguous invalidation; defaults rejected if ambiguous
}

struct UpdatePreferencesRequest: Content {
    let preferences: [PreferenceUpdate]

    struct PreferenceUpdate: Content {
        let category: String
        let enabled: Bool
    }
}

struct AdminBroadcastRequest: Content {
    let category: String
    let notificationType: String
    let title: String
    let body: String
    let deeplink: String?
    let metadata: [String: String]?
    let inactiveDaysOnly: Int?  // if set, only send to users inactive for N+ days
}

/// Legacy admin test: requires exact raw token + environment.
struct AdminTestPushRequest: Content {
    let deviceToken: String
    let environment: String
    let title: String?
    let body: String?
    let deeplink: String?
}

/// Exact-device admin test: requires registration UUID (preferred).
struct AdminExactPushTestRequest: Content {
    let registrationId: UUID?
    let title: String?
    let body: String?
    let deeplink: String?
}

struct MaskedRegistrationsListResponse: Content {
    let count: Int
    let topic: String
    let configuredEnvironments: [String]
    let registrations: [MaskedDeviceRegistrationDTO]
}

// MARK: - Route registration

func registerNotificationRoutes(_ app: Application) throws {

    // ───────── DELETE /notifications/device-token ─────────
    app.delete("notifications", "device-token") { req async throws -> HTTPStatus in
        let payload = try req.content.decode(DeregisterDeviceRequest.self)
        let tokenHash = UserDeviceToken.hash(payload.deviceToken)
        guard let environment = payload.environment.flatMap({ APNSDeviceEnvironment.parse($0)?.rawValue }) else {
            throw Abort(.badRequest, reason: "environment must be 'production' or 'sandbox'")
        }

        let db = req.db(.notifications)
        let device = try await UserDeviceToken.query(on: db)
            .filter(\.$tokenHash == tokenHash)
            .filter(\.$environment == environment)
            .first()

        if let device = device, device.invalidatedAt == nil {
            device.invalidatedAt = Date()
            try await device.update(on: db)
            req.logger.info("🗑 Deregistered device token_hash=\(tokenHash.prefix(12)) env=\(environment)")
        }

        return .ok  // idempotent — success even if already invalidated or not found
    }

    // ───────── GET /notifications/preferences ─────────
    app.get("notifications", "preferences") { req async throws -> NotificationPreferencesResponseDTO in
        let userID = try await req.verifiedSupabaseUserId()
        let db = req.db(.notifications)

        let existing = try await NotificationPreference.query(on: db)
            .filter(\.$userId == userID)
            .all()

        // Lazy-create defaults for any missing categories
        let existingCategories = Set(existing.map { $0.category })
        var all = existing

        for category in NotificationCategory.allCases {
            if !existingCategories.contains(category.rawValue) {
                let pref = NotificationPreference(
                    userId: userID,
                    category: category,
                    enabled: category.defaultEnabled
                )
                try await pref.create(on: db)
                all.append(pref)
            }
        }

        return NotificationPreferencesResponseDTO(preferences: all.map { $0.toDTO() })
    }

    // ───────── PUT /notifications/preferences ─────────
    app.put("notifications", "preferences") { req async throws -> NotificationPreferencesResponseDTO in
        let userID = try await req.verifiedSupabaseUserId()
        let update = try req.content.decode(UpdatePreferencesRequest.self)
        let db = req.db(.notifications)

        for change in update.preferences {
            guard NotificationCategory(rawValue: change.category) != nil else {
                throw Abort(.badRequest, reason: "Unknown notification category: \(change.category)")
            }

            if let existing = try await NotificationPreference.query(on: db)
                .filter(\.$userId == userID)
                .filter(\.$category == change.category)
                .first()
            {
                existing.enabled = change.enabled
                try await existing.update(on: db)
            } else {
                let pref = NotificationPreference(
                    userId: userID,
                    category: NotificationCategory(rawValue: change.category)!,
                    enabled: change.enabled
                )
                try await pref.create(on: db)
            }
        }

        let all = try await NotificationPreference.query(on: db)
            .filter(\.$userId == userID)
            .all()
        return NotificationPreferencesResponseDTO(preferences: all.map { $0.toDTO() })
    }

    // ───────── Admin routes (require X-Admin-Key) ─────────
    let admin = app.grouped(AdminAuthMiddleware())

    // GET /admin/notifications/registrations
    // Safe listing of candidate devices — never exposes complete tokens.
    admin.get("admin", "notifications", "registrations") { req async throws -> MaskedRegistrationsListResponse in
        let environment = try? req.query.get(String.self, at: "environment")
        let userIdString = try? req.query.get(String.self, at: "userId")
        let userId = userIdString.flatMap(UUID.init(uuidString:))
        let enabledOnly = (try? req.query.get(Bool.self, at: "enabledOnly")) ?? true
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 50

        let svc = req.application.notificationService
        let registrations = try await svc.listMaskedRegistrations(
            environment: environment,
            userId: userId,
            enabledOnly: enabledOnly,
            limit: limit,
            db: req.db(.notifications)
        )

        return MaskedRegistrationsListResponse(
            count: registrations.count,
            topic: svc.bundleId,
            configuredEnvironments: svc.configuredEnvironments.sorted(),
            registrations: registrations
        )
    }

    // POST /admin/push/test  (preferred exact-registration contract)
    admin.post("admin", "push", "test") { req async throws -> ExactDevicePushResult in
        try await handleExactDeviceTest(req)
    }

    // POST /admin/notifications/test
    // Accepts either:
    //   { "registrationId": "..." }  — preferred exact-device path
    //   { "deviceToken": "...", "environment": "..." }  — legacy path
    admin.post("admin", "notifications", "test") { req async throws -> Response in
        // Try exact registration path first
        if let exact = try? req.content.decode(AdminExactPushTestRequest.self),
           let registrationId = exact.registrationId {
            let result = try await req.application.notificationService.sendToRegistration(
                registrationId: registrationId,
                category: .system,
                notificationType: "admin.test",
                title: exact.title ?? "SnapOrtho Test",
                body: exact.body ?? "APNs test notification",
                deeplink: exact.deeplink ?? "snaportho://notifications/test",
                db: req.db(.notifications)
            )
            if !result.success {
                // Still return structured body so operators can inspect status without
                // guessing; use 409 for permanent token disable, 502 for other failures.
                let status: HTTPStatus = result.registrationDisabled ? .gone : .badGateway
                return try await result.encodeResponse(status: status, for: req)
            }
            return try await result.encodeResponse(status: .ok, for: req)
        }

        // Legacy: exact raw token + environment
        let payload = try req.content.decode(AdminTestPushRequest.self)
        guard let environment = APNSDeviceEnvironment.parse(payload.environment)?.rawValue else {
            throw Abort(.badRequest, reason: "environment must be 'production' or 'sandbox'")
        }
        guard req.application.notificationService.configuredEnvironments.contains(environment) else {
            throw Abort(.conflict, reason: "Requested environment does not match a configured APNS endpoint")
        }
        let title = payload.title ?? "SnapOrtho Test"
        let body = payload.body ?? "Push notification test 🩻"
        let deeplink = payload.deeplink ?? "snaportho://notifications/test"

        let svc = req.application.notificationService
        let result = try await svc.sendToDevice(
            rawToken: payload.deviceToken,
            environment: environment,
            category: .system,
            notificationType: "admin.test",
            title: title,
            body: body,
            deeplink: deeplink,
            db: req.db(.notifications)
        )

        let tokenHash = UserDeviceToken.hash(payload.deviceToken)
        if result.sent == 1 {
            req.logger.info("✅ Admin test push sent to token_hash=\(tokenHash.prefix(12)) env=\(environment)")
            return try await result.encodeResponse(status: .ok, for: req)
        } else if result.failed == 1 {
            throw Abort(.gone, reason: "Token is invalid or unregistered — it has been invalidated")
        } else if result.skipped == 1 {
            throw Abort(.conflict, reason: "Device token could not be sent (skipped)")
        }
        return try await result.encodeResponse(status: .ok, for: req)
    }

    // POST /admin/notifications/broadcast
    admin.post("admin", "notifications", "broadcast") { req async throws -> NotificationBroadcastResult in
        let payload = try req.content.decode(AdminBroadcastRequest.self)

        guard let category = NotificationCategory(rawValue: payload.category) else {
            throw Abort(.badRequest, reason: "Unknown category: \(payload.category)")
        }

        let db = req.db(.notifications)
        let svc = req.application.notificationService

        if let inactiveDays = payload.inactiveDaysOnly {
            return try await svc.broadcastToInactiveUsers(
                inactiveDays: inactiveDays,
                category: category,
                notificationType: payload.notificationType,
                title: payload.title,
                body: payload.body,
                deeplink: payload.deeplink,
                metadata: payload.metadata ?? [:],
                db: db
            )
        } else {
            return try await svc.broadcast(
                category: category,
                notificationType: payload.notificationType,
                title: payload.title,
                body: payload.body,
                deeplink: payload.deeplink,
                metadata: payload.metadata ?? [:],
                db: db
            )
        }
    }
}

// MARK: - Exact device test handler

private func handleExactDeviceTest(_ req: Request) async throws -> ExactDevicePushResult {
    let payload = try req.content.decode(AdminExactPushTestRequest.self)

    guard let registrationId = payload.registrationId else {
        throw Abort(.badRequest, reason: "registrationId is required — never falls back to another device")
    }

    let result = try await req.application.notificationService.sendToRegistration(
        registrationId: registrationId,
        category: .system,
        notificationType: "admin.test",
        title: payload.title ?? "SnapOrtho Test",
        body: payload.body ?? "APNs test notification",
        deeplink: payload.deeplink ?? "snaportho://notifications/test",
        db: req.db(.notifications)
    )

    if result.success {
        req.logger.info(
            "✅ Admin exact-device test accepted registration_id=\(registrationId) env=\(result.environment) apns_id=\(result.apnsId ?? "nil")"
        )
    } else {
        req.logger.warning(
            "⚠️ Admin exact-device test failed registration_id=\(registrationId) status=\(result.status) error=\(result.errorCode ?? "nil") disabled=\(result.registrationDisabled)"
        )
    }

    // Throw HTTP errors for hard failures while still allowing the caller to
    // decode a body when using the structured success path above.
    if !result.success {
        if result.registrationDisabled {
            throw Abort(.gone, reason: result.errorMessage ?? "Registration permanently invalid and disabled")
        }
        if result.status == "skipped" {
            throw Abort(.conflict, reason: result.errorMessage ?? "Send skipped")
        }
        throw Abort(.badGateway, reason: result.errorMessage ?? "APNs delivery failed")
    }

    return result
}

// MARK: - Dual-write device registration helper

/// Called from POST /device/register to write into Supabase (primary datastore).
/// Amazon RDS legacy write is optional best-effort fallback in routes.swift.
func upsertSupabaseDeviceToken(
    rawToken: String,
    userID: UUID?,
    platform: String,
    environment: String,
    appVersion: String?,
    buildNumber: String?,
    timezone: String?,
    receiveNotifications: Bool,
    db: any Database,
    logger: Logger
) async throws {
    let normalizedToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalizedToken.count == 64,
          normalizedToken.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
        throw Abort(.badRequest, reason: "deviceToken must be a 64-character hexadecimal APNS token")
    }
    guard APNSDeviceEnvironment.parse(environment) != nil else {
        throw Abort(.badRequest, reason: "environment must be 'production' or 'sandbox'")
    }
    let tokenHash = UserDeviceToken.hash(normalizedToken)
    let now = Date()

    if let existing = try await UserDeviceToken.query(on: db)
        .filter(\.$tokenHash == tokenHash)
        .filter(\.$environment == environment)
        .first()
    {
        // Ownership rules:
        // - Authenticated registration always reassigns the device to that user.
        // - Anonymous registration clears user association (logout / pre-auth path)
        //   so the device is not left attached to a prior account.
        // - Never merge sandbox into production or vice versa (unique on hash+env).
        existing.userId = userID
        existing.token = normalizedToken
        existing.platform = platform
        existing.appVersion = appVersion
        existing.buildNumber = buildNumber
        existing.timezone = timezone
        existing.receiveNotifications = receiveNotifications
        existing.lastSeenAt = now
        // Re-activate if app registered again (user re-installed or token recovered)
        existing.invalidatedAt = nil
        try await existing.update(on: db)
        logger.info(
            "♻️ [datastore] primary=supabase device_upsert=update token_hash=\(tokenHash.prefix(12)) env=\(environment) user=\(userID?.uuidString.prefix(8) ?? "anonymous")"
        )
    } else {
        let device = UserDeviceToken(
            userId: userID,
            token: normalizedToken,
            platform: platform,
            environment: environment,
            appVersion: appVersion,
            buildNumber: buildNumber,
            timezone: timezone,
            receiveNotifications: receiveNotifications,
            lastSeenAt: now
        )
        try await device.create(on: db)
        logger.info(
            "🆕 [datastore] primary=supabase device_upsert=create token_hash=\(tokenHash.prefix(12)) env=\(environment) user=\(userID?.uuidString.prefix(8) ?? "anonymous")"
        )
    }
}
