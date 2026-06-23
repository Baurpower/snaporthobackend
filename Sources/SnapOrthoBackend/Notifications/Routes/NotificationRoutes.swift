import Vapor
import Fluent

// MARK: - Request/Response types

struct RegisterDeviceRequest: Content {
    let deviceToken: String
    let platform: String?
    let appVersion: String?
    let buildNumber: String?
    let environment: String?   // "production" | "sandbox" — defaults to "production"
    let timezone: String?
    let receiveNotifications: Bool?

    // Legacy fields accepted for backward compatibility with existing iOS app
    let isAuthenticated: Bool?
    let language: String?      // stored in Amazon legacy table only
}

struct DeregisterDeviceRequest: Content {
    let deviceToken: String
    let environment: String?   // defaults to "production"
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

struct AdminTestPushRequest: Content {
    let deviceToken: String
    let environment: String?
    let title: String?
    let body: String?
}

// MARK: - Route registration

func registerNotificationRoutes(_ app: Application) throws {

    // ───────── Device registration (dual-write) ─────────

    // This replaces the existing POST /device/register handler in routes.swift.
    // The old handler is kept in routes.swift as a deprecated compatibility wrapper
    // that calls this logic. This function is the canonical implementation.

    // ───────── DELETE /notifications/device-token ─────────
    app.delete("notifications", "device-token") { req async throws -> HTTPStatus in
        let payload = try req.content.decode(DeregisterDeviceRequest.self)
        let tokenHash = UserDeviceToken.hash(payload.deviceToken)
        let environment = payload.environment ?? "production"

        let db = req.db(.notifications)
        let device = try await UserDeviceToken.query(on: db)
            .filter(\.$tokenHash == tokenHash)
            .filter(\.$environment == environment)
            .first()

        if let device = device, device.invalidatedAt == nil {
            device.invalidatedAt = Date()
            try await device.update(on: db)
            req.logger.info("🗑 Deregistered device token_hash=\(tokenHash.prefix(12))")
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
            // Validate category
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

        // Return full updated state
        let all = try await NotificationPreference.query(on: db)
            .filter(\.$userId == userID)
            .all()
        return NotificationPreferencesResponseDTO(preferences: all.map { $0.toDTO() })
    }

    // ───────── Admin routes (require X-Admin-Key) ─────────
    let admin = app.grouped(AdminAuthMiddleware())

    // POST /admin/notifications/test
    admin.post("admin", "notifications", "test") { req async throws -> NotificationBroadcastResult in
        let payload = try req.content.decode(AdminTestPushRequest.self)
        let environment = payload.environment ?? "production"
        let title = payload.title ?? "SnapOrtho Test"
        let body = payload.body ?? "Push notification test 🩻"

        let svc = req.application.notificationService
        let result = try await svc.sendToDevice(
            rawToken: payload.deviceToken,
            environment: environment,
            category: .system,
            notificationType: "admin.test",
            title: title,
            body: body,
            allowCrossEnvironment: true,
            db: req.db(.notifications)
        )

        let tokenHash = UserDeviceToken.hash(payload.deviceToken)
        if result.sent == 1 {
            req.logger.info("✅ Admin test push sent to token_hash=\(tokenHash.prefix(12))")
        } else if result.failed == 1 {
            throw Abort(.gone, reason: "Token is invalid or unregistered — it has been invalidated")
        } else if result.skipped == 1 {
            throw Abort(.conflict, reason: "Device token could not be sent (skipped)")
        }
        return result
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

// MARK: - Dual-write device registration helper

/// Called from the existing POST /device/register handler to write into Supabase.
/// This is the Phase 1 dual-write path: Amazon legacy write happens in routes.swift,
/// then this is called for the Supabase write.
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
    let tokenHash = UserDeviceToken.hash(rawToken)
    let now = Date()

    if let existing = try await UserDeviceToken.query(on: db)
        .filter(\.$tokenHash == tokenHash)
        .filter(\.$environment == environment)
        .first()
    {
        // Update in place — preserve invalidation state if already marked
        existing.userId = userID
        existing.appVersion = appVersion
        existing.buildNumber = buildNumber
        existing.timezone = timezone
        existing.receiveNotifications = receiveNotifications
        existing.lastSeenAt = now
        // Re-activate if app registered again (user re-installed)
        existing.invalidatedAt = nil
        try await existing.update(on: db)
        logger.info("♻️ Updated Supabase device token_hash=\(tokenHash.prefix(12))")
    } else {
        let device = UserDeviceToken(
            userId: userID,
            token: rawToken,
            platform: platform,
            environment: environment,
            appVersion: appVersion,
            buildNumber: buildNumber,
            timezone: timezone,
            receiveNotifications: receiveNotifications,
            lastSeenAt: now
        )
        try await device.create(on: db)
        logger.info("🆕 Created Supabase device token_hash=\(tokenHash.prefix(12))")
    }
}


