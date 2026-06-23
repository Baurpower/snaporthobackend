import Vapor
import Fluent
import NIOCore

/// Phase 2A scheduler foundation. Runs on a fixed interval for the lifetime of the process and,
/// in this phase, ONLY:
///   1. Logs the count of pending `notification_candidates` rows (zero today — no generator
///      exists yet; Phase 2B/2C/2D add candidate generation).
///   2. Rolls over `NotificationUserState.sendsToday`/`sendsThisWeek` when the day/week changes.
///
/// It does not generate candidates and does not send anything. This validates the scheduler
/// loop itself runs reliably — starts on boot, stops cleanly on shutdown, survives errors in
/// one tick without crashing the process — before any dispatch logic is layered on top.
final class CandidateSchedulerJob: LifecycleHandler, Sendable {
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
