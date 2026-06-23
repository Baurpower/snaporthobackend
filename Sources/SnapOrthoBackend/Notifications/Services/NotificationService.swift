import Vapor
import Fluent

// MARK: - Results

struct NotificationSendResult: Sendable {
    let deviceTokenId: UUID
    let status: NotificationDeliveryAttempt.DeliveryStatus
    let apnsId: String?
    let skipReason: String?
    let errorCode: String?
}

struct NotificationBroadcastResult: Content {
    let sent: Int
    let failed: Int
    let skipped: Int
    let total: Int
}

// MARK: - Service

/// Central service for all push notification sends.
/// Never scatter APNS calls across route handlers — always go through here.
struct NotificationService: Sendable {
    let apnsSender: any APNSSenderProtocol
    let bundleId: String
    let apnsEnvironment: String    // "production" | "sandbox"
    let logger: Logger

    // MARK: - Send to a single authenticated user (all active devices)

    func sendToUser(
        userID: UUID,
        category: NotificationCategory,
        notificationType: String,
        title: String,
        body: String,
        deeplink: String?,
        metadata: [String: String] = [:],
        db: any Database
    ) async throws -> NotificationBroadcastResult {
        let devices = try await activeDevices(for: userID, db: db)
        guard !devices.isEmpty else {
            logger.info("ℹ️ No active devices for user \(userID) — skipping send")
            return NotificationBroadcastResult(sent: 0, failed: 0, skipped: 0, total: 0)
        }

        let prefEnabled = try await isCategoryEnabled(for: userID, category: category, db: db)
        guard prefEnabled else {
            logger.info("🔕 Category \(category.rawValue) disabled for user \(userID) — skipping")
            for device in devices {
                try await logAttempt(
                    userId: userID,
                    deviceTokenId: device.id,
                    category: category,
                    notificationType: notificationType,
                    title: title, body: body, deeplink: deeplink,
                    metadata: metadata,
                    status: .skipped,
                    skipReason: "category_disabled",
                    db: db
                )
            }
            return NotificationBroadcastResult(sent: 0, failed: 0, skipped: devices.count, total: devices.count)
        }

        return try await dispatch(
            to: devices,
            userId: userID,
            category: category,
            notificationType: notificationType,
            title: title, body: body, deeplink: deeplink,
            metadata: metadata, db: db
        )
    }

    // MARK: - Broadcast to all opted-in users

    func broadcast(
        category: NotificationCategory,
        notificationType: String,
        title: String,
        body: String,
        deeplink: String?,
        metadata: [String: String] = [:],
        db: any Database
    ) async throws -> NotificationBroadcastResult {
        let devices = try await UserDeviceToken.query(on: db)
            .filter(\.$receiveNotifications == true)
            .filter(\.$environment == apnsEnvironment)
            .filter(\.$invalidatedAt == .null)
            .all()

        return try await dispatch(
            to: devices,
            userId: nil,
            category: category,
            notificationType: notificationType,
            title: title, body: body, deeplink: deeplink,
            metadata: metadata, db: db
        )
    }

    // MARK: - Send to a single registered device (admin test / targeted send)

    /// Looks up a device by raw token + environment, logs delivery, sends APNS, and invalidates bad tokens.
    /// `allowCrossEnvironment` lets admin test sends target a device registered under a different APNS environment.
    func sendToDevice(
        rawToken: String,
        environment: String,
        category: NotificationCategory = .system,
        notificationType: String,
        title: String,
        body: String,
        deeplink: String? = nil,
        metadata: [String: String] = [:],
        allowCrossEnvironment: Bool = false,
        db: any Database
    ) async throws -> NotificationBroadcastResult {
        let tokenHash = UserDeviceToken.hash(rawToken)
        guard let device = try await UserDeviceToken.query(on: db)
            .filter(\.$tokenHash == tokenHash)
            .filter(\.$environment == environment)
            .first()
        else {
            throw Abort(.notFound, reason: "Device token not found for environment=\(environment)")
        }

        guard device.isActive else {
            throw Abort(.conflict, reason: "Device token has been invalidated")
        }

        return try await dispatch(
            to: [device],
            userId: device.userId,
            category: category,
            notificationType: notificationType,
            title: title,
            body: body,
            deeplink: deeplink,
            metadata: metadata,
            enforceServerEnvironment: !allowCrossEnvironment,
            db: db
        )
    }

    // MARK: - Broadcast to inactive users (last seen > N days ago)

    func broadcastToInactiveUsers(
        inactiveDays: Int,
        category: NotificationCategory,
        notificationType: String,
        title: String,
        body: String,
        deeplink: String?,
        metadata: [String: String] = [:],
        db: any Database
    ) async throws -> NotificationBroadcastResult {
        let cutoff = Calendar.current.date(byAdding: .day, value: -inactiveDays, to: Date())!
        let devices = try await UserDeviceToken.query(on: db)
            .filter(\.$receiveNotifications == true)
            .filter(\.$environment == apnsEnvironment)
            .filter(\.$invalidatedAt == .null)
            .filter(\.$lastSeenAt < cutoff)
            .all()

        return try await dispatch(
            to: devices,
            userId: nil,
            category: category,
            notificationType: notificationType,
            title: title, body: body, deeplink: deeplink,
            metadata: metadata, db: db
        )
    }

    // MARK: - Internal dispatch

    private func dispatch(
        to devices: [UserDeviceToken],
        userId: UUID?,
        category: NotificationCategory,
        notificationType: String,
        title: String,
        body: String,
        deeplink: String?,
        metadata: [String: String],
        enforceServerEnvironment: Bool = true,
        db: any Database
    ) async throws -> NotificationBroadcastResult {
        var sent = 0
        var failed = 0
        var skipped = 0

        for device in devices {
            let effectiveUserId = userId ?? device.userId
            let notificationId = UUID()

            if enforceServerEnvironment && device.environment != apnsEnvironment {
                logger.debug("⏭ Skipping \(UserDeviceToken.logSafePrefix(of: device.tokenHash)): environment mismatch")
                try await logAttempt(
                    id: notificationId,
                    userId: effectiveUserId,
                    deviceTokenId: device.id,
                    category: category,
                    notificationType: notificationType,
                    title: title, body: body, deeplink: deeplink,
                    metadata: metadata,
                    status: .skipped,
                    skipReason: "environment_mismatch",
                    db: db
                )
                skipped += 1
                continue
            }

            let apnsPayload = SnapOrthoAPNSPayload(
                notificationId: notificationId.uuidString,
                category: category.rawValue,
                type: notificationType,
                deeplink: deeplink,
                metadata: metadata.isEmpty ? nil : metadata
            )

            do {
                let result = try await apnsSender.sendAlert(
                    title: title,
                    body: body,
                    to: device.token,
                    payload: apnsPayload,
                    bundleId: bundleId
                )

                try await logAttempt(
                    id: notificationId,
                    userId: effectiveUserId,
                    deviceTokenId: device.id,
                    category: category,
                    notificationType: notificationType,
                    title: title, body: body, deeplink: deeplink,
                    metadata: metadata,
                    status: .sent,
                    apnsId: result.apnsId,
                    sentAt: Date(),
                    db: db
                )

                logger.info("✅ Sent \(notificationType) → \(UserDeviceToken.logSafePrefix(of: device.tokenHash))")
                sent += 1

            } catch APNSTokenError.badDeviceToken, APNSTokenError.unregistered {
                // Permanent failure — invalidate the token so it won't be retried
                logger.warning("⚠️ Token permanently invalid, invalidating: \(UserDeviceToken.logSafePrefix(of: device.tokenHash))")
                device.invalidatedAt = Date()
                try? await device.update(on: db)

                try await logAttempt(
                    id: notificationId,
                    userId: effectiveUserId,
                    deviceTokenId: device.id,
                    category: category,
                    notificationType: notificationType,
                    title: title, body: body, deeplink: deeplink,
                    metadata: metadata,
                    status: .failed,
                    errorCode: "invalid_token",
                    errorMessage: "APNS rejected token as invalid or unregistered",
                    db: db
                )
                failed += 1

            } catch {
                // Transient failure — log and continue
                logger.error("❌ APNS send failed for \(UserDeviceToken.logSafePrefix(of: device.tokenHash)): \(error)")

                try await logAttempt(
                    id: notificationId,
                    userId: effectiveUserId,
                    deviceTokenId: device.id,
                    category: category,
                    notificationType: notificationType,
                    title: title, body: body, deeplink: deeplink,
                    metadata: metadata,
                    status: .failed,
                    errorCode: "transient",
                    errorMessage: error.localizedDescription,
                    db: db
                )
                failed += 1
            }
        }

        return NotificationBroadcastResult(sent: sent, failed: failed, skipped: skipped, total: devices.count)
    }

    // MARK: - Helpers

    private func activeDevices(for userID: UUID, db: any Database) async throws -> [UserDeviceToken] {
        try await UserDeviceToken.query(on: db)
            .filter(\.$userId == userID)
            .filter(\.$receiveNotifications == true)
            .filter(\.$environment == apnsEnvironment)
            .filter(\.$invalidatedAt == .null)
            .all()
    }

    private func isCategoryEnabled(for userID: UUID, category: NotificationCategory, db: any Database) async throws -> Bool {
        // system bypasses all preference checks
        if category.bypassesFrequencyCap { return true }

        let pref = try await NotificationPreference.query(on: db)
            .filter(\.$userId == userID)
            .filter(\.$category == category.rawValue)
            .first()

        return pref?.enabled ?? category.defaultEnabled
    }

    // MARK: - Delivery logging

    private func logAttempt(
        id: UUID = UUID(),
        userId: UUID?,
        deviceTokenId: UUID?,
        category: NotificationCategory,
        notificationType: String,
        title: String,
        body: String,
        deeplink: String?,
        metadata: [String: String],
        status: NotificationDeliveryAttempt.DeliveryStatus,
        apnsId: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        skipReason: String? = nil,
        sentAt: Date? = nil,
        db: any Database
    ) async throws {
        let attempt = NotificationDeliveryAttempt(
            id: id,
            userId: userId,
            deviceTokenId: deviceTokenId,
            category: category,
            notificationType: notificationType,
            title: title,
            body: body,
            deeplink: deeplink,
            metadata: metadata,
            status: status,
            apnsId: apnsId,
            errorCode: errorCode ?? skipReason,
            errorMessage: errorMessage,
            sentAt: sentAt
        )
        do {
            try await attempt.create(on: db)
        } catch {
            // Never let logging failure break the send path
            logger.error("⚠️ Failed to log delivery attempt: \(error)")
        }
    }
}

// MARK: - Application storage

private struct NotificationServiceKey: StorageKey {
    typealias Value = NotificationService
}

extension Application {
    var notificationService: NotificationService {
        get {
            guard let svc = storage[NotificationServiceKey.self] else {
                fatalError("NotificationService not configured. Call app.configureNotificationService() in configure.swift.")
            }
            return svc
        }
        set { storage[NotificationServiceKey.self] = newValue }
    }

    func configureNotificationService() {
        let config = storage[APNSRuntimeConfigStorageKey.self]
            ?? APNSRuntimeConfig(bundleId: "com.alexbaur.Snap-Ortho", environment: "production")
        storage[NotificationServiceKey.self] = NotificationService(
            apnsSender: apnsSender,
            bundleId: config.bundleId,
            apnsEnvironment: config.environment,
            logger: logger
        )
    }
}

// MARK: - APNS runtime config (set during configure)

struct APNSRuntimeConfig: Sendable {
    let bundleId: String
    let environment: String
}

struct APNSRuntimeConfigStorageKey: StorageKey {
    typealias Value = APNSRuntimeConfig
}
