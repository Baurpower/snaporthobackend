import Vapor
import Fluent

/// Best-effort legacy Amazon RDS writes kept during the Supabase cutover.
enum LegacyRDSWrites {

    static func upsertLegacyDevice(
        payload: LegacyDevicePayload,
        learnUserId: String,
        receiveNotifications: Bool,
        now: Date,
        db: any Database,
        logger: Logger
    ) async {
        do {
            if let existing = try await Device.query(on: db)
                .filter(\.$deviceToken == payload.deviceToken)
                .first()
            {
                existing.learnUserId = learnUserId
                existing.lastSeen = now
                existing.language = payload.language
                existing.timezone = payload.timezone
                try await existing.update(on: db)
                logger.info("♻️ [datastore] primary=supabase rds_fallback=success action=update")
            } else {
                let new = Device(
                    deviceToken: payload.deviceToken,
                    learnUserId: learnUserId,
                    platform: payload.platform,
                    appVersion: payload.appVersion,
                    lastSeen: now,
                    language: payload.language,
                    timezone: payload.timezone,
                    receiveNotifications: receiveNotifications,
                    lastNotified: nil
                )
                try await new.create(on: db)
                logger.info("🆕 [datastore] primary=supabase rds_fallback=success action=create")
            }
        } catch {
            logger.warning("⚠️ [datastore] primary=supabase rds_fallback=failure error=\(String(describing: error))")
        }
    }

    static func insertLegacyCasePrepLog(
        prompt: String,
        responseJSON: String,
        wasHelpful: Bool?,
        userFeedback: String?,
        db: any Database,
        logger: Logger
    ) async {
        do {
            let log = CasePrepLog(
                prompt: prompt,
                responseJSON: responseJSON,
                wasHelpful: wasHelpful,
                userFeedback: userFeedback
            )
            try await log.save(on: db)
            logger.info("✅ [datastore] primary=supabase case_prep_rds_fallback=success")
        } catch {
            logger.warning("⚠️ [datastore] primary=supabase case_prep_rds_fallback=failure error=\(String(describing: error))")
        }
    }
}

struct LegacyDevicePayload: Sendable {
    let deviceToken: String
    let platform: String
    let appVersion: String
    let language: String?
    let timezone: String?
}