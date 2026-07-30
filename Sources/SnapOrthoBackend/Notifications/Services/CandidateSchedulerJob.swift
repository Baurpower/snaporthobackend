import Vapor
import Fluent
import NIOCore
import FluentPostgresDriver

struct NotificationAutomationConfig: Sendable {
    let enabled: Bool
    let dryRun: Bool
    let generationLimit: Int
    let dispatchLimit: Int
    let interval: TimeAmount

    static func load() -> Self {
        Self(
            enabled: parseBool(Environment.get("NOTIFICATION_AUTOMATION_ENABLED"), default: false),
            dryRun: parseBool(Environment.get("NOTIFICATION_AUTOMATION_DRY_RUN"), default: true),
            generationLimit: parsePositiveInt(
                Environment.get("NOTIFICATION_GENERATION_LIMIT"), default: 100
            ),
            dispatchLimit: parsePositiveInt(
                Environment.get("NOTIFICATION_DISPATCH_LIMIT"), default: 50
            ),
            interval: .minutes(Int64(parsePositiveInt(
                Environment.get("NOTIFICATION_AUTOMATION_INTERVAL_MINUTES"), default: 15
            )))
        )
    }

    private static func parseBool(_ value: String?, default defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return defaultValue
        }
    }

    private static func parsePositiveInt(_ value: String?, default defaultValue: Int) -> Int {
        guard let value, let parsed = Int(value), parsed > 0 else { return defaultValue }
        return parsed
    }
}

struct NotificationAutomationConfigStorageKey: StorageKey {
    typealias Value = NotificationAutomationConfig
}

/// Maintains notification counters and, when explicitly enabled, generates learning
/// candidates and dispatches due candidates. Automation is disabled by default and starts in
/// dry-run mode when enabled without an explicit dry-run setting.
///
/// Each active automation cycle runs under a Postgres transaction-scoped advisory lock. This
/// ensures horizontally-scaled Vapor instances cannot run the same cycle concurrently. The
/// lock is released automatically on commit, rollback, connection loss, or process exit.
final class CandidateSchedulerJob: LifecycleHandler, Sendable {
    static let advisoryLockKey: Int64 = 6_002_807_166_515_434_568

    private let interval: TimeAmount
    private let box: TaskBox

    init(interval: TimeAmount = .minutes(15)) {
        self.interval = interval
        self.box = TaskBox()
    }

    func didBootAsync(_ application: Application) async throws {
        let interval = self.interval
        let box = self.box
        let task = Task {
            while !Task.isCancelled {
                await CandidateSchedulerJob.tick(application: application)
                let nanoseconds = UInt64(max(interval.nanoseconds, 0))
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
        await box.set(task)
    }

    func shutdownAsync(_ application: Application) async {
        await box.cancel()
    }

    // MARK: - Tick

    static func tick(application: Application) async {
        let logger = application.logger
        guard application.databases.ids().contains(.notifications) else {
            logger.warning("⏭ Candidate scheduler tick skipped — .notifications database not configured")
            return
        }
        let db = application.db(.notifications)
        let config = application.storage[NotificationAutomationConfigStorageKey.self]
            ?? NotificationAutomationConfig(
                enabled: false,
                dryRun: true,
                generationLimit: 100,
                dispatchLimit: 50,
                interval: .minutes(15)
            )

        do {
            let pendingCount = try await NotificationCandidate.query(on: db)
                .filter(\.$status == .pending)
                .count()
            logger.info("📋 Candidate scheduler tick: \(pendingCount) pending candidate(s)")
        } catch {
            logger.error("❌ Candidate scheduler tick failed to count pending candidates: \(error)")
        }

        do {
            try await resetCountersIfNeeded(db: db, now: Date(), logger: logger)
        } catch {
            logger.error("❌ Candidate scheduler tick failed to reset counters: \(error)")
        }

        guard config.enabled else {
            logger.debug("⏸ Notification automation disabled")
            return
        }

        do {
            try await runAutomatedCycle(application: application, database: db, config: config)
        } catch {
            logger.error("❌ Notification automation cycle failed: \(error)")
        }
    }

    private struct AdvisoryLockRow: Decodable {
        let acquired: Bool
    }

    /// Public to the module for focused integration tests.
    static func runAutomatedCycle(
        application: Application,
        database: any Database,
        config: NotificationAutomationConfig
    ) async throws {
        guard database is any PostgresDatabase else {
            application.logger.error("❌ Notification automation requires Postgres advisory locking")
            return
        }

        try await database.transaction { transaction in
            guard let transactionPostgres = transaction as? any PostgresDatabase else {
                throw Abort(.internalServerError, reason: "Notification transaction is not Postgres")
            }

            // Stable application-specific key. Transaction scope guarantees automatic release.
            let lock = try await transactionPostgres.sql().raw("""
                SELECT pg_try_advisory_xact_lock(\(bind: advisoryLockKey)) AS acquired
            """).first(decoding: AdvisoryLockRow.self)

            guard lock?.acquired == true else {
                application.logger.info("⏭ Notification automation skipped — another instance holds the scheduler lock")
                return
            }

            let runtime = application.storage[APNSRuntimeConfigStorageKey.self]
            let environment = runtime?.defaultEnvironment ?? "production"
            let generator = LearningCandidateGenerator(
                apnsEnvironment: environment,
                logger: application.logger
            )

            let result = try await generator.run(
                db: transaction,
                dryRun: config.dryRun,
                limit: config.generationLimit,
                specificUserId: nil
            )

            if config.dryRun {
                application.logger.info(
                    "🔎 Notification automation dry run complete — evaluated=\(result.evaluated) wouldCreate=\(result.wouldCreate); dispatch skipped"
                )
                return
            }

            try await ProcessScheduledNotificationsCommand.process(
                application: application,
                limit: config.dispatchLimit,
                database: transaction
            )
        }
    }

    /// Resets `sendsToday`/`sendsThisWeek` for any `NotificationUserState` row whose stored
    /// bucket no longer matches the current day/week. Idempotent — safe to run every tick.
    static func resetCountersIfNeeded(db: any Database, now: Date, logger: Logger) async throws {
        let calendar = Calendar(identifier: .gregorian)
        let todayBucket = calendar.startOfDay(for: now)
        let weekBucket = startOfWeek(containing: now, calendar: calendar)

        let states = try await NotificationUserState.query(on: db).all()
        for state in states {
            var changed = false

            if state.dayBucket == nil || !calendar.isDate(state.dayBucket!, inSameDayAs: todayBucket) {
                state.sendsToday = 0
                state.dayBucket = todayBucket
                changed = true
            }

            if state.weekBucket == nil || state.weekBucket! != weekBucket {
                state.sendsThisWeek = 0
                state.weekBucket = weekBucket
                changed = true
            }

            if changed {
                try await state.update(on: db)
            }
        }

        if !states.isEmpty {
            logger.debug("🔄 Candidate scheduler: checked \(states.count) user state row(s) for day/week rollover")
        }
    }

    static func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }
}

/// Actor box holding the looping Task so it can be cancelled cleanly on shutdown.
/// Kept separate from `CandidateSchedulerJob` itself so the job type can be a plain
/// `Sendable` class without needing `@unchecked Sendable`.
private actor TaskBox {
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
