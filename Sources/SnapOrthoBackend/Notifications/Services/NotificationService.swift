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

/// Detailed result for an exact-device admin test push.
struct ExactDevicePushResult: Content {
    let success: Bool
    let registrationId: UUID
    let environment: String
    let topic: String
    let apnsId: String?
    let status: String
    let maskedToken: String
    let userId: UUID?
    let errorCode: String?
    let errorMessage: String?
    let registrationDisabled: Bool
    let deliveryAttemptId: UUID?
}

struct MaskedDeviceRegistrationDTO: Content {
    let registrationId: UUID
    let maskedToken: String
    let userId: UUID?
    let deviceId: UUID?          // same as registrationId; reserved for future device table FK
    let environment: String
    let topic: String
    let enabled: Bool
    let receiveNotifications: Bool
    let createdAt: Date?
    let updatedAt: Date?
    let lastSeenAt: Date
    let lastSendStatus: String?
    let lastSendAt: Date?
    let appVersion: String?
    let platform: String
}

// MARK: - Service

/// Central service for all push notification sends.
/// Never scatter APNS calls across route handlers — always go through here.
struct NotificationService: Sendable {
    let apnsSender: any APNSSenderProtocol
    let bundleId: String
    /// Default / primary APNs environment from `APNS_ENVIRONMENT`.
    let apnsEnvironment: String
    /// Environments with a live client container.
    let configuredEnvironments: Set<String>
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
                    environment: device.environment,
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
        // Prefer devices in any configured environment; fall back to default env only.
        let devices = try await UserDeviceToken.query(on: db)
            .filter(\.$receiveNotifications == true)
            .filter(\.$invalidatedAt == .null)
            .all()
            .filter { configuredEnvironments.contains($0.environment) }

        return try await dispatchRespectingPreferences(
            to: devices,
            category: category,
            notificationType: notificationType,
            title: title, body: body, deeplink: deeplink,
            metadata: metadata, db: db
        )
    }

    // MARK: - Exact registration send (admin test path)

    /// Sends to one exact `user_device_tokens` row by registration UUID.
    /// Never falls back to another device. Never selects the first row in the table.
    func sendToRegistration(
        registrationId: UUID,
        category: NotificationCategory = .system,
        notificationType: String = "admin.test",
        title: String,
        body: String,
        deeplink: String? = nil,
        metadata: [String: String] = [:],
        db: any Database
    ) async throws -> ExactDevicePushResult {
        guard let device = try await UserDeviceToken.find(registrationId, on: db) else {
            throw Abort(.notFound, reason: "Unknown registrationId")
        }

        guard APNSDeviceEnvironment.parse(device.environment) != nil else {
            throw Abort(.conflict, reason: "Registration has unknown APNs environment '\(device.environment)'")
        }
        guard configuredEnvironments.contains(device.environment) else {
            throw Abort(
                .conflict,
                reason: "Registration environment '\(device.environment)' is not configured on this server (configured: \(configuredEnvironments.sorted().joined(separator: ",")))"
            )
        }
        guard device.isActive else {
            throw Abort(.conflict, reason: "Registration is disabled (invalidated)")
        }
        guard device.receiveNotifications else {
            throw Abort(.conflict, reason: "Registration has notifications disabled (receive_notifications=false)")
        }

        logger.info(
            "notification_presend target_count=1 registration_id=\(registrationId) token_hash=\(UserDeviceToken.logSafePrefix(of: device.tokenHash)) environment=\(device.environment) topic=\(bundleId)"
        )

        let broadcast = try await dispatch(
            to: [device],
            userId: device.userId,
            category: category,
            notificationType: notificationType,
            title: title,
            body: body,
            deeplink: deeplink,
            metadata: metadata,
            db: db
        )

        // Reload device + latest attempt for the structured response.
        let reloaded = try await UserDeviceToken.find(registrationId, on: db)
        let latestAttempt = try await NotificationDeliveryAttempt.query(on: db)
            .filter(\.$deviceToken.$id == registrationId)
            .sort(\.$createdAt, .descending)
            .first()

        let success = broadcast.sent == 1
        let status: String
        if success {
            status = "accepted"
        } else if broadcast.failed == 1 {
            status = "failed"
        } else {
            status = "skipped"
        }

        if broadcast.failed == 1, latestAttempt?.errorCode == "invalid_token" || latestAttempt?.errorCode?.hasPrefix("BadDevice") == true {
            // Permanent failure path already disabled the registration in dispatch.
        }

        return ExactDevicePushResult(
            success: success,
            registrationId: registrationId,
            environment: device.environment,
            topic: bundleId,
            apnsId: latestAttempt?.apnsId,
            status: status,
            maskedToken: device.maskedToken,
            userId: device.userId,
            errorCode: latestAttempt?.errorCode,
            errorMessage: latestAttempt?.errorMessage,
            registrationDisabled: reloaded?.invalidatedAt != nil,
            deliveryAttemptId: latestAttempt?.id
        )
    }

    // MARK: - Send to a single registered device by raw token (legacy admin path)

    /// Looks up a device by raw token + environment, logs delivery, sends APNS, and invalidates bad tokens.
    func sendToDevice(
        rawToken: String,
        environment: String,
        category: NotificationCategory = .system,
        notificationType: String,
        title: String,
        body: String,
        deeplink: String? = nil,
        metadata: [String: String] = [:],
        db: any Database
    ) async throws -> NotificationBroadcastResult {
        guard APNSDeviceEnvironment.parse(environment) != nil else {
            throw Abort(.badRequest, reason: "environment must be 'production' or 'sandbox'")
        }
        guard configuredEnvironments.contains(environment) else {
            throw Abort(
                .conflict,
                reason: "Requested environment '\(environment)' is not configured on this server"
            )
        }

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
        guard device.receiveNotifications else {
            throw Abort(.conflict, reason: "Device has notifications disabled")
        }

        logger.info("notification_presend target_count=1 token_hash=\(UserDeviceToken.logSafePrefix(of: device.tokenHash)) environment=\(device.environment) topic=\(bundleId)")

        return try await dispatch(
            to: [device],
            userId: device.userId,
            category: category,
            notificationType: notificationType,
            title: title,
            body: body,
            deeplink: deeplink,
            metadata: metadata,
            db: db
        )
    }

    // MARK: - List masked registrations (admin)

    func listMaskedRegistrations(
        environment: String? = nil,
        userId: UUID? = nil,
        enabledOnly: Bool = true,
        limit: Int = 50,
        db: any Database
    ) async throws -> [MaskedDeviceRegistrationDTO] {
        let capped = min(max(limit, 1), 200)
        var query = UserDeviceToken.query(on: db)
            .sort(\.$lastSeenAt, .descending)
            .limit(capped)

        if let environment {
            guard APNSDeviceEnvironment.parse(environment) != nil else {
                throw Abort(.badRequest, reason: "environment must be 'production' or 'sandbox'")
            }
            query = query.filter(\.$environment == environment)
        }
        if let userId {
            query = query.filter(\.$userId == userId)
        }
        if enabledOnly {
            query = query.filter(\.$invalidatedAt == .null)
        }

        let devices = try await query.all()

        var results: [MaskedDeviceRegistrationDTO] = []
        for device in devices {
            guard let id = device.id else { continue }
            let lastAttempt = try await NotificationDeliveryAttempt.query(on: db)
                .filter(\.$deviceToken.$id == id)
                .sort(\.$createdAt, .descending)
                .first()

            results.append(MaskedDeviceRegistrationDTO(
                registrationId: id,
                maskedToken: device.maskedToken,
                userId: device.userId,
                deviceId: id,
                environment: device.environment,
                topic: bundleId,
                enabled: device.isActive,
                receiveNotifications: device.receiveNotifications,
                createdAt: device.createdAt,
                updatedAt: device.updatedAt,
                lastSeenAt: device.lastSeenAt,
                lastSendStatus: lastAttempt?.status.rawValue,
                lastSendAt: lastAttempt?.sentAt ?? lastAttempt?.createdAt,
                appVersion: device.appVersion,
                platform: device.platform
            ))
        }
        return results
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
            .filter(\.$invalidatedAt == .null)
            .filter(\.$lastSeenAt < cutoff)
            .all()
            .filter { configuredEnvironments.contains($0.environment) }

        return try await dispatchRespectingPreferences(
            to: devices,
            category: category,
            notificationType: notificationType,
            title: title, body: body, deeplink: deeplink,
            metadata: metadata, db: db
        )
    }

    // MARK: - Preference-aware batch dispatch (used by broadcast paths)

    /// Splits a device list by per-user category preference before sending.
    /// Devices with no `userId` (anonymous registrations) are always included —
    /// anonymous devices have no preference row to check against.
    private func dispatchRespectingPreferences(
        to devices: [UserDeviceToken],
        category: NotificationCategory,
        notificationType: String,
        title: String,
        body: String,
        deeplink: String?,
        metadata: [String: String],
        db: any Database
    ) async throws -> NotificationBroadcastResult {
        guard !category.bypassesFrequencyCap else {
            return try await dispatch(
                to: devices, userId: nil, category: category,
                notificationType: notificationType, title: title, body: body,
                deeplink: deeplink, metadata: metadata, db: db
            )
        }

        let userIds = Set(devices.compactMap { $0.userId })
        var disabledUserIds: Set<UUID> = []
        if !userIds.isEmpty {
            let disabledPrefs = try await NotificationPreference.query(on: db)
                .filter(\.$userId ~~ Array(userIds))
                .filter(\.$category == category.rawValue)
                .filter(\.$enabled == false)
                .all()
            disabledUserIds = Set(disabledPrefs.map { $0.userId })
        }

        var sendable: [UserDeviceToken] = []
        var blocked: [UserDeviceToken] = []
        let usersWithPref = Set(try await NotificationPreference.query(on: db)
            .filter(\.$userId ~~ Array(userIds))
            .filter(\.$category == category.rawValue)
            .all()
            .map { $0.userId })

        for device in devices {
            guard let uid = device.userId else {
                sendable.append(device)
                continue
            }
            if disabledUserIds.contains(uid) {
                blocked.append(device)
            } else if !usersWithPref.contains(uid) && !category.defaultEnabled {
                blocked.append(device)
            } else {
                sendable.append(device)
            }
        }

        for device in blocked {
            try await logAttempt(
                userId: device.userId,
                deviceTokenId: device.id,
                category: category,
                notificationType: notificationType,
                title: title, body: body, deeplink: deeplink,
                metadata: metadata,
                status: .skipped,
                skipReason: "category_disabled",
                environment: device.environment,
                db: db
            )
        }

        let result = try await dispatch(
            to: sendable, userId: nil, category: category,
            notificationType: notificationType, title: title, body: body,
            deeplink: deeplink, metadata: metadata, db: db
        )

        return NotificationBroadcastResult(
            sent: result.sent,
            failed: result.failed,
            skipped: result.skipped + blocked.count,
            total: result.total + blocked.count
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
        db: any Database
    ) async throws -> NotificationBroadcastResult {
        var sent = 0
        var failed = 0
        var skipped = 0

        for device in devices {
            let effectiveUserId = userId ?? device.userId
            let notificationId = UUID()

            guard APNSDeviceEnvironment.parse(device.environment) != nil else {
                logger.warning("⏭ Skipping \(UserDeviceToken.logSafePrefix(of: device.tokenHash)): unknown environment '\(device.environment)'")
                try await logAttempt(
                    id: notificationId,
                    userId: effectiveUserId,
                    deviceTokenId: device.id,
                    category: category,
                    notificationType: notificationType,
                    title: title, body: body, deeplink: deeplink,
                    metadata: metadata,
                    status: .skipped,
                    skipReason: "unknown_environment",
                    environment: device.environment,
                    db: db
                )
                skipped += 1
                continue
            }

            guard configuredEnvironments.contains(device.environment) else {
                logger.debug("⏭ Skipping \(UserDeviceToken.logSafePrefix(of: device.tokenHash)): environment '\(device.environment)' not configured")
                try await logAttempt(
                    id: notificationId,
                    userId: effectiveUserId,
                    deviceTokenId: device.id,
                    category: category,
                    notificationType: notificationType,
                    title: title, body: body, deeplink: deeplink,
                    metadata: metadata,
                    status: .skipped,
                    skipReason: "environment_not_configured",
                    environment: device.environment,
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
                    bundleId: bundleId,
                    environment: device.environment
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
                    environment: device.environment,
                    registrationDisabled: false,
                    db: db
                )

                logger.info("✅ Sent \(notificationType) → \(UserDeviceToken.logSafePrefix(of: device.tokenHash)) env=\(device.environment) apns_id=\(result.apnsId ?? "nil")")
                sent += 1

            } catch let tokenError as APNSTokenError {
                // Permanent failure — disable this exact registration only
                logger.warning("⚠️ Token permanently invalid (\(tokenError.reasonCode)), disabling registration \(device.id?.uuidString ?? "?"): \(UserDeviceToken.logSafePrefix(of: device.tokenHash))")
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
                    errorCode: tokenError.reasonCode,
                    errorMessage: "APNS permanent token failure: \(tokenError.reasonCode)",
                    environment: device.environment,
                    registrationDisabled: true,
                    db: db
                )
                failed += 1

            } catch let providerError as APNSProviderError {
                logger.error("❌ APNS provider error for \(UserDeviceToken.logSafePrefix(of: device.tokenHash)): \(providerError.reasonCode)")
                try await logAttempt(
                    id: notificationId,
                    userId: effectiveUserId,
                    deviceTokenId: device.id,
                    category: category,
                    notificationType: notificationType,
                    title: title, body: body, deeplink: deeplink,
                    metadata: metadata,
                    status: .failed,
                    errorCode: providerError.reasonCode,
                    errorMessage: "APNS provider/config error: \(providerError.reasonCode)",
                    environment: device.environment,
                    registrationDisabled: false,
                    db: db
                )
                failed += 1

            } catch let transient as APNSTransientError {
                logger.error("❌ APNS transient failure for \(UserDeviceToken.logSafePrefix(of: device.tokenHash)): \(transient.reasonCode)")
                try await logAttempt(
                    id: notificationId,
                    userId: effectiveUserId,
                    deviceTokenId: device.id,
                    category: category,
                    notificationType: notificationType,
                    title: title, body: body, deeplink: deeplink,
                    metadata: metadata,
                    status: .failed,
                    errorCode: transient.reasonCode,
                    errorMessage: "APNS transient failure: \(transient.reasonCode)",
                    environment: device.environment,
                    registrationDisabled: false,
                    db: db
                )
                failed += 1

            } catch {
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
                    environment: device.environment,
                    registrationDisabled: false,
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
            .filter(\.$invalidatedAt == .null)
            .all()
            .filter { configuredEnvironments.contains($0.environment) }
    }

    private func isCategoryEnabled(for userID: UUID, category: NotificationCategory, db: any Database) async throws -> Bool {
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
        environment: String? = nil,
        registrationDisabled: Bool = false,
        db: any Database
    ) async throws {
        var enriched = metadata
        if let environment {
            enriched["apns_environment"] = environment
        }
        enriched["apns_topic"] = bundleId
        if registrationDisabled {
            enriched["registration_disabled"] = "true"
        }

        let attempt = NotificationDeliveryAttempt(
            id: id,
            userId: userId,
            deviceTokenId: deviceTokenId,
            category: category,
            notificationType: notificationType,
            title: title,
            body: body,
            deeplink: deeplink,
            metadata: enriched,
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
            ?? APNSRuntimeConfig(
                bundleId: "com.alexbaur.Snap-Ortho",
                defaultEnvironment: "production",
                configuredEnvironments: ["production"]
            )
        storage[NotificationServiceKey.self] = NotificationService(
            apnsSender: apnsSender,
            bundleId: config.bundleId,
            apnsEnvironment: config.defaultEnvironment,
            configuredEnvironments: config.configuredEnvironments,
            logger: logger
        )
    }
}
