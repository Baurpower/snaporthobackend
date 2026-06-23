import Vapor
import Fluent
import FluentPostgresDriver

/// One-time backfill command: reads Amazon RDS `devices` table and upserts into
/// Supabase `user_device_tokens`.
///
/// Usage:
///   swift run SnapOrthoBackend backfill-notification-tokens
///   swift run SnapOrthoBackend backfill-notification-tokens --dry-run
///   swift run SnapOrthoBackend backfill-notification-tokens --batch-size 500
///
/// The command is idempotent — safe to run multiple times. It upserts by
/// (token_hash, environment) so duplicate tokens are never created.
struct BackfillNotificationTokensCommand: AsyncCommand {
    static let name = "backfill-notification-tokens"

    struct Signature: CommandSignature {
        @Flag(name: "dry-run", short: "d", help: "Print what would be migrated without writing")
        var dryRun: Bool

        @Option(name: "batch-size", short: "b", help: "Rows per batch (default: 200)")
        var batchSize: Int?
    }

    var help: String {
        "Backfill Amazon RDS device tokens into Supabase user_device_tokens (idempotent)."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let logger = app.logger
        let dryRun = signature.dryRun
        let batchSize = signature.batchSize ?? 200

        logger.info("🚀 Starting notification token backfill (dry-run=\(dryRun), batchSize=\(batchSize))")

        let amazonDB = app.db(.psql)
        let supabaseDB = app.db(.notifications)

        // Fetch all Amazon devices in batches
        var offset = 0
        var totalProcessed = 0
        var totalInserted = 0
        var totalUpdated = 0
        var totalSkipped = 0
        var invalidUIDCount = 0

        while true {
            let batch = try await Device.query(on: amazonDB)
                .sort(\.$createdAt, .ascending)
                .offset(offset)
                .limit(batchSize)
                .all()

            if batch.isEmpty { break }

            logger.info("📦 Processing batch offset=\(offset) count=\(batch.count)")

            for device in batch {
                let tokenHash = UserDeviceToken.hash(device.deviceToken)
                let environment = "production" // existing tokens are all production

                // Resolve user_id: must be a valid UUID (Supabase UID), else null
                let userId: UUID?
                if let uuid = UUID(uuidString: device.learnUserId) {
                    userId = uuid
                } else {
                    userId = nil
                    if device.learnUserId != "anonymous" {
                        invalidUIDCount += 1
                        // Log count only — never log raw token or raw UID
                        logger.warning("⚠️ Non-UUID learn_user_id encountered (not logging value) — inserting with user_id=NULL")
                    }
                }

                if dryRun {
                    logger.info("  [DRY-RUN] Would upsert token_hash=\(tokenHash.prefix(12)) user_id=\(userId?.uuidString ?? "NULL") env=\(environment)")
                    totalProcessed += 1
                    continue
                }

                do {
                    if let existing = try await UserDeviceToken.query(on: supabaseDB)
                        .filter(\.$tokenHash == tokenHash)
                        .filter(\.$environment == environment)
                        .first()
                    {
                        // Update to pick up any changes in timezone/version
                        existing.userId = userId ?? existing.userId
                        existing.appVersion = device.appVersion
                        existing.timezone = device.timezone
                        existing.receiveNotifications = device.receiveNotifications
                        if let lastSeen = device.lastSeen as Date? {
                            if lastSeen > existing.lastSeenAt {
                                existing.lastSeenAt = lastSeen
                            }
                        }
                        try await existing.update(on: supabaseDB)
                        totalUpdated += 1
                    } else {
                        let newToken = UserDeviceToken(
                            userId: userId,
                            token: device.deviceToken,
                            platform: device.platform.isEmpty ? "ios" : device.platform,
                            environment: environment,
                            appVersion: device.appVersion.isEmpty ? nil : device.appVersion,
                            timezone: device.timezone,
                            receiveNotifications: device.receiveNotifications,
                            lastSeenAt: device.lastSeen
                        )
                        try await newToken.create(on: supabaseDB)
                        totalInserted += 1
                    }
                } catch {
                    logger.error("❌ Failed to upsert token_hash=\(tokenHash.prefix(12)): \(error)")
                    totalSkipped += 1
                }

                totalProcessed += 1
            }

            offset += batch.count
            if batch.count < batchSize { break }
        }

        logger.info("""
        ✅ Backfill complete
           Total processed : \(totalProcessed)
           Inserted        : \(totalInserted)
           Updated         : \(totalUpdated)
           Skipped (errors): \(totalSkipped)
           Invalid UIDs    : \(invalidUIDCount) (inserted with user_id=NULL)
           Dry run         : \(dryRun)
        """)
    }
}
