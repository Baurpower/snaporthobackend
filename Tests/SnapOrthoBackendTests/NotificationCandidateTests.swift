@testable import SnapOrthoBackend
import VaporTesting
import Testing
import Vapor
import Fluent

@Suite("Notification Candidate / Scheduler Tests (Phase 2A)", .serialized)
struct NotificationCandidateTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    // MARK: - Migration idempotency

    @Test("Full migrate/revert/migrate cycle succeeds without error")
    func migrationCycleIsRepeatable() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)

            // First cycle already ran inside configure(). Revert and migrate again to prove
            // the schema can be torn down and recreated cleanly — this is the idempotency
            // guarantee that actually matters for this app (Fluent's _fluent_migrations
            // tracking, not the raw DDL, is what prevents double-apply in normal boots).
            try await app.autoRevert()
            try await app.autoMigrate()

            let count = try await NotificationCandidate.query(on: app.db(.notifications)).count()
            #expect(count == 0)

            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Re-applying a single migration's prepare() without reverting throws, not crashes")
    func reapplyingPrepareThrowsCleanly() async throws {
        try await withApp { app in
            // The table already exists from configure()'s autoMigrate(). Calling prepare()
            // again directly (bypassing Fluent's tracking) must fail loudly with a thrown
            // error rather than silently corrupting state or crashing the process.
            await #expect(throws: (any Error).self) {
                try await CreateNotificationCandidates().prepare(on: app.db(.notifications))
            }
        }
    }

    // MARK: - Uniqueness / dedup

    @Test("Duplicate (user_id, source_type, nil source_ref_id) is rejected")
    func duplicateCandidateWithNilRefIdRejected() async throws {
        try await withApp { app in
            let userId = UUID()
            let db = app.db(.notifications)

            let first = NotificationCandidate(
                userId: userId,
                sourceType: CandidateSourceType.learningDaily.rawValue,
                sourceRefId: nil,
                category: .learning,
                priorityScore: CandidateSourceType.learningDaily.priorityScore,
                eligibleAt: Date(),
                expiresAt: Date().addingTimeInterval(3600)
            )
            try await first.create(on: db)

            let second = NotificationCandidate(
                userId: userId,
                sourceType: CandidateSourceType.learningDaily.rawValue,
                sourceRefId: nil,
                category: .learning,
                priorityScore: CandidateSourceType.learningDaily.priorityScore,
                eligibleAt: Date(),
                expiresAt: Date().addingTimeInterval(3600)
            )
            await #expect(throws: (any Error).self) {
                try await second.create(on: db)
            }
        }
    }

    @Test("Duplicate (user_id, source_type, same source_ref_id) is rejected")
    func duplicateCandidateWithSameRefIdRejected() async throws {
        try await withApp { app in
            let userId = UUID()
            let conversationId = UUID()
            let db = app.db(.notifications)

            let first = NotificationCandidate(
                userId: userId,
                sourceType: CandidateSourceType.brobotFollowup24h.rawValue,
                sourceRefId: conversationId,
                category: .brobot,
                priorityScore: CandidateSourceType.brobotFollowup24h.priorityScore,
                eligibleAt: Date(),
                expiresAt: Date().addingTimeInterval(3600)
            )
            try await first.create(on: db)

            let second = NotificationCandidate(
                userId: userId,
                sourceType: CandidateSourceType.brobotFollowup24h.rawValue,
                sourceRefId: conversationId,
                category: .brobot,
                priorityScore: CandidateSourceType.brobotFollowup24h.priorityScore,
                eligibleAt: Date(),
                expiresAt: Date().addingTimeInterval(3600)
            )
            await #expect(throws: (any Error).self) {
                try await second.create(on: db)
            }
        }
    }

    @Test("Different source_ref_id values for same user/source_type are allowed")
    func differentRefIdsAreNotDuplicates() async throws {
        try await withApp { app in
            let userId = UUID()
            let db = app.db(.notifications)

            for _ in 0..<2 {
                let candidate = NotificationCandidate(
                    userId: userId,
                    sourceType: CandidateSourceType.brobotFollowup24h.rawValue,
                    sourceRefId: UUID(),
                    category: .brobot,
                    priorityScore: CandidateSourceType.brobotFollowup24h.priorityScore,
                    eligibleAt: Date(),
                    expiresAt: Date().addingTimeInterval(3600)
                )
                try await candidate.create(on: db)
            }

            let count = try await NotificationCandidate.query(on: db)
                .filter(\.$userId == userId)
                .count()
            #expect(count == 2)
        }
    }

    // MARK: - CandidateRanking: priority scores

    @Test("Priority scores match the strategy doc's ranking model")
    func priorityScoresAreCorrect() {
        #expect(CandidateSourceType.brobotAbandoned.priorityScore == 100)
        #expect(CandidateSourceType.brobotFollowup24h.priorityScore == 90)
        #expect(CandidateSourceType.brobotRecall72h.priorityScore == 70)
        #expect(CandidateSourceType.conversionUsageLimit.priorityScore == 60)
        #expect(CandidateSourceType.learningRecentTopic.priorityScore == 50)
        #expect(CandidateSourceType.brobotFirstTrial.priorityScore == 45)
        #expect(CandidateSourceType.learningDaily.priorityScore == 40)
        #expect(CandidateSourceType.conversionHighEngagement.priorityScore == 15)
    }

    @Test("Unknown source type strings score 0 rather than crashing")
    func unknownSourceTypeScoresZero() {
        #expect(CandidateRanking.priorityScore(forSourceType: "not_a_real_type") == 0)
    }

    @Test("selectTop picks the highest-priority candidate, breaking ties by earliest eligibleAt")
    func selectTopPicksHighestPriority() {
        struct Stub { let score: Int; let eligibleAt: Date }
        let now = Date()
        let candidates = [
            Stub(score: 40, eligibleAt: now),
            Stub(score: 90, eligibleAt: now.addingTimeInterval(10)),
            Stub(score: 90, eligibleAt: now), // same score as above, earlier eligibleAt should win
            Stub(score: 15, eligibleAt: now),
        ]
        let winner = CandidateRanking.selectTop(
            from: candidates,
            priorityScore: { $0.score },
            eligibleAt: { $0.eligibleAt }
        )
        #expect(winner?.score == 90)
        #expect(winner?.eligibleAt == now)
    }

    // MARK: - CandidateRanking: cooldowns

    @Test("Same source type within 48h is blocked by cooldown")
    func sameSourceTypeCooldownBlocks() {
        let now = Date()
        let recentSend = now.addingTimeInterval(-3600) // 1h ago
        #expect(CandidateRanking.isWithinCooldown(
            lastSentAt: recentSend, cooldown: CandidateRanking.sameSourceTypeCooldown, now: now
        ))
    }

    @Test("Same source type after 48h is not blocked by cooldown")
    func sameSourceTypeCooldownExpires() {
        let now = Date()
        let oldSend = now.addingTimeInterval(-49 * 3600) // 49h ago
        #expect(!CandidateRanking.isWithinCooldown(
            lastSentAt: oldSend, cooldown: CandidateRanking.sameSourceTypeCooldown, now: now
        ))
    }

    @Test("isBlockedByCooldown enforces brobot category cooldown across different brobot source types")
    func brobotCategoryCooldownAppliesAcrossSourceTypes() {
        let now = Date()
        let recentBrobotSend = now.addingTimeInterval(-3600 * 6) // 6h ago, within 12h brobot cooldown

        let blocked = CandidateRanking.isBlockedByCooldown(
            sourceType: .brobotRecall72h,
            lastSentAtForSameSourceType: nil, // no prior recall_72h sent
            lastSentAtForCategory: recentBrobotSend, // but a followup_24h fired 6h ago
            lastSentAtForConversionType: nil,
            now: now
        )
        #expect(blocked)
    }

    @Test("isBlockedByCooldown enforces 7-day conversion cooldown")
    func conversionCooldownBlocks() {
        let now = Date()
        let recentConversionSend = now.addingTimeInterval(-3 * 24 * 3600) // 3 days ago

        let blocked = CandidateRanking.isBlockedByCooldown(
            sourceType: .conversionHighEngagement,
            lastSentAtForSameSourceType: nil,
            lastSentAtForCategory: nil,
            lastSentAtForConversionType: recentConversionSend,
            now: now
        )
        #expect(blocked)
    }

    @Test("isBlockedByCooldown allows send when no cooldowns apply")
    func noCooldownAllowsSend() {
        let blocked = CandidateRanking.isBlockedByCooldown(
            sourceType: .learningDaily,
            lastSentAtForSameSourceType: nil,
            lastSentAtForCategory: nil,
            lastSentAtForConversionType: nil,
            now: Date()
        )
        #expect(!blocked)
    }

    // MARK: - CandidateRanking: caps

    @Test("Daily cap blocks a second non-system send the same day")
    func dailyCapBlocksSecondSend() {
        #expect(CandidateRanking.canSendRespectingDailyCap(category: .learning, sendsToday: 0))
        #expect(!CandidateRanking.canSendRespectingDailyCap(category: .learning, sendsToday: 1))
    }

    @Test("System category bypasses the daily cap")
    func systemBypassesDailyCap() {
        #expect(CandidateRanking.canSendRespectingDailyCap(category: .system, sendsToday: 99))
    }

    @Test("Weekly cap blocks the 4th non-system send")
    func weeklyCapBlocksFourthSend() {
        #expect(CandidateRanking.canSendRespectingWeeklyCap(
            category: .learning, isConversionType: false, sendsThisWeek: 2, conversionSendsThisWeek: 0
        ))
        #expect(!CandidateRanking.canSendRespectingWeeklyCap(
            category: .learning, isConversionType: false, sendsThisWeek: 3, conversionSendsThisWeek: 0
        ))
    }

    @Test("Conversion category capped at 1/week even if general weekly cap has room")
    func conversionWeeklyCapIsStricter() {
        #expect(!CandidateRanking.canSendRespectingWeeklyCap(
            category: .product, isConversionType: true, sendsThisWeek: 1, conversionSendsThisWeek: 1
        ))
        #expect(CandidateRanking.canSendRespectingWeeklyCap(
            category: .product, isConversionType: true, sendsThisWeek: 0, conversionSendsThisWeek: 0
        ))
    }

    // MARK: - Holdout assignment

    @Test("Holdout assignment is deterministic for the same user id")
    func holdoutAssignmentIsDeterministic() {
        let userId = UUID()
        let first = HoldoutAssignment.isHoldout(userId: userId)
        for _ in 0..<10 {
            #expect(HoldoutAssignment.isHoldout(userId: userId) == first)
        }
    }

    @Test("Holdout fraction is approximately correct across many users")
    func holdoutFractionIsApproximatelyCorrect() {
        let sampleSize = 5000
        let holdoutCount = (0..<sampleSize).filter { _ in
            HoldoutAssignment.isHoldout(userId: UUID())
        }.count
        let observedFraction = Double(holdoutCount) / Double(sampleSize)
        // Statistical — allow a generous tolerance band around the configured 8% target.
        #expect(observedFraction > 0.04 && observedFraction < 0.13)
    }

    @Test("bucket(for:) returns a value in [0, 1)")
    func bucketIsInUnitRange() {
        for _ in 0..<100 {
            let bucket = HoldoutAssignment.bucket(for: UUID())
            #expect(bucket >= 0 && bucket < 1)
        }
    }

    // MARK: - Scheduler job

    @Test("Scheduler tick runs without error against an empty candidates table")
    func schedulerTickRunsCleanlyWhenEmpty() async throws {
        try await withApp { app in
            // Should not throw, crash, or hang — Phase 2A's tick is read-only/counter-reset only.
            await CandidateSchedulerJob.tick(application: app)
        }
    }

    @Test("Scheduler tick resets stale day/week buckets on NotificationUserState")
    func schedulerTickResetsStaleBuckets() async throws {
        try await withApp { app in
            let db = app.db(.notifications)
            let userId = UUID()

            let staleDay = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
            let staleWeek = Calendar.current.date(byAdding: .day, value: -14, to: Date())!

            let state = NotificationUserState(
                userId: userId,
                sendsToday: 1,
                sendsThisWeek: 3,
                dayBucket: staleDay,
                weekBucket: staleWeek,
                isHoldout: false
            )
            try await state.create(on: db)

            try await CandidateSchedulerJob.resetCountersIfNeeded(db: db, now: Date(), logger: app.logger)

            let updated = try await NotificationUserState.query(on: db)
                .filter(\.$userId == userId)
                .first()
            #expect(updated?.sendsToday == 0)
            #expect(updated?.sendsThisWeek == 0)
        }
    }

    @Test("Scheduler tick does not touch a NotificationUserState row already on the current day/week")
    func schedulerTickLeavesCurrentBucketsAlone() async throws {
        try await withApp { app in
            let db = app.db(.notifications)
            let userId = UUID()
            let calendar = Calendar(identifier: .gregorian)
            let today = calendar.startOfDay(for: Date())
            let thisWeek = CandidateSchedulerJob.startOfWeek(containing: Date(), calendar: calendar)

            let state = NotificationUserState(
                userId: userId,
                sendsToday: 1,
                sendsThisWeek: 2,
                dayBucket: today,
                weekBucket: thisWeek,
                isHoldout: false
            )
            try await state.create(on: db)

            try await CandidateSchedulerJob.resetCountersIfNeeded(db: db, now: Date(), logger: app.logger)

            let updated = try await NotificationUserState.query(on: db)
                .filter(\.$userId == userId)
                .first()
            #expect(updated?.sendsToday == 1)
            #expect(updated?.sendsThisWeek == 2)
        }
    }

    @Test("NotificationUserState enforces one row per user")
    func userStateUniquePerUser() async throws {
        try await withApp { app in
            let db = app.db(.notifications)
            let userId = UUID()

            let first = NotificationUserState(userId: userId, isHoldout: false)
            try await first.create(on: db)

            let second = NotificationUserState(userId: userId, isHoldout: true)
            await #expect(throws: (any Error).self) {
                try await second.create(on: db)
            }
        }
    }
}
