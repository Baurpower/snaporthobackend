@testable import SnapOrthoBackend
import VaporTesting
import Testing
import Vapor
import Fluent
import FluentPostgresDriver

@Suite("Notification Phase 2B Tests (Learning + First-BroBot-Try Candidates)", .serialized)
struct NotificationPhase2BTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await seedTemplates(app: app)
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func seedTemplates(app: Application) async throws {
        try await SeedNotificationTemplatesCommand.seed(application: app)
    }

    /// Inserts a minimal `user_profiles` row via raw SQL since this app never models that
    /// table with Fluent (read-only, owned elsewhere) — see LearningCandidateGenerator.
    private func insertProfile(userId: UUID, trainingLevel: String?, db: any Database) async throws {
        guard let pg = db as? any PostgresDatabase else {
            Issue.record("Test requires a Postgres database for .notifications")
            return
        }
        try await pg.sql().raw("""
            CREATE TABLE IF NOT EXISTS user_profiles (
                user_id uuid PRIMARY KEY,
                training_level text
            )
        """).run()
        try await pg.sql().raw("""
            INSERT INTO user_profiles (user_id, training_level)
            VALUES (\(bind: userId), \(bind: trainingLevel))
            ON CONFLICT (user_id) DO UPDATE SET training_level = EXCLUDED.training_level
        """).run()
    }

    /// Inserts a minimal `brobot_conversations` row via raw SQL for the same reason.
    private func insertBrobotConversation(userId: UUID, db: any Database) async throws {
        guard let pg = db as? any PostgresDatabase else {
            Issue.record("Test requires a Postgres database for .notifications")
            return
        }
        try await pg.sql().raw("""
            CREATE TABLE IF NOT EXISTS brobot_conversations (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                user_id uuid NOT NULL
            )
        """).run()
        try await pg.sql().raw("""
            INSERT INTO brobot_conversations (user_id) VALUES (\(bind: userId))
        """).run()
    }

    private func ensureBrobotConversationsTableExists(db: any Database) async throws {
        guard let pg = db as? any PostgresDatabase else { return }
        try await pg.sql().raw("""
            CREATE TABLE IF NOT EXISTS brobot_conversations (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                user_id uuid NOT NULL
            )
        """).run()
    }

    private func makeEligibleUser(
        app: Application,
        trainingLevel: String? = nil,
        withBrobotHistory: Bool = false
    ) async throws -> UUID {
        let userId = UUID()
        let db = app.db(.notifications)

        let device = UserDeviceToken(
            userId: userId, token: "test-token-\(UUID().uuidString)",
            platform: "ios", environment: "production", timezone: "America/Chicago"
        )
        try await device.create(on: db)

        try await insertProfile(userId: userId, trainingLevel: trainingLevel, db: db)
        try await ensureBrobotConversationsTableExists(db: db)
        if withBrobotHistory {
            try await insertBrobotConversation(userId: userId, db: db)
        }

        return userId
    }

    private var generator: LearningCandidateGenerator {
        LearningCandidateGenerator(apnsEnvironment: "production", logger: Logger(label: "test"))
    }

    // MARK: - Dry-run / commit

    @Test("Dry-run creates no rows")
    func dryRunCreatesNoRows() async throws {
        try await withApp { app in
            let userId = try await makeEligibleUser(app: app)
            let db = app.db(.notifications)

            let result = try await generator.run(db: db, dryRun: true, limit: nil, specificUserId: userId)

            #expect(result.wouldCreate == 1)
            #expect(result.created == 0)

            let count = try await NotificationCandidate.query(on: db).count()
            #expect(count == 0)
        }
    }

    @Test("Commit creates rows")
    func commitCreatesRows() async throws {
        try await withApp { app in
            let userId = try await makeEligibleUser(app: app)
            let db = app.db(.notifications)

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)

            #expect(result.created == 1)

            let count = try await NotificationCandidate.query(on: db)
                .filter(\.$userId == userId)
                .count()
            #expect(count == 1)
        }
    }

    @Test("Rerunning the same day does not duplicate")
    func rerunIsIdempotent() async throws {
        try await withApp { app in
            let userId = try await makeEligibleUser(app: app)
            let db = app.db(.notifications)

            let now = Date()
            _ = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId, now: now)
            let second = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId, now: now)

            #expect(second.created == 0)
            #expect(second.skippedCooldown == 1)

            let count = try await NotificationCandidate.query(on: db)
                .filter(\.$userId == userId)
                .count()
            #expect(count == 1)
        }
    }

    // MARK: - Eligibility

    @Test("User without active token is skipped")
    func userWithoutActiveTokenSkipped() async throws {
        try await withApp { app in
            let userId = UUID()
            let db = app.db(.notifications)
            try await insertProfile(userId: userId, trainingLevel: nil, db: db)
            // No device token created at all.

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)

            #expect(result.evaluated == 0) // never even entered the eligible-user list
        }
    }

    @Test("Invalidated token is not eligible")
    func invalidatedTokenSkipped() async throws {
        try await withApp { app in
            let userId = UUID()
            let db = app.db(.notifications)
            let device = UserDeviceToken(userId: userId, token: "invalid-\(UUID().uuidString)", platform: "ios", environment: "production")
            device.invalidatedAt = Date()
            try await device.create(on: db)
            try await insertProfile(userId: userId, trainingLevel: nil, db: db)

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)
            #expect(result.evaluated == 0)
        }
    }

    @Test("Holdout user is skipped")
    func holdoutUserSkipped() async throws {
        try await withApp { app in
            let userId = try await makeEligibleUser(app: app)
            let db = app.db(.notifications)

            let state = NotificationUserState(userId: userId, isHoldout: true)
            try await state.create(on: db)

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)
            #expect(result.skippedHoldout == 1)
            #expect(result.created == 0)
        }
    }

    @Test("Disabled learning preference skips learning candidate")
    func disabledLearningPreferenceSkipped() async throws {
        try await withApp { app in
            // Has brobot history so first_try doesn't apply — isolates the learning path.
            let userId = try await makeEligibleUser(app: app, withBrobotHistory: true)
            let db = app.db(.notifications)

            let pref = NotificationPreference(userId: userId, category: .learning, enabled: false)
            try await pref.create(on: db)

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)
            #expect(result.created == 0)
            #expect(result.skippedNoEligibleType == 1)
        }
    }

    @Test("Disabled brobot preference skips first_try, falls back to learning")
    func disabledBrobotPreferenceFallsBackToLearning() async throws {
        try await withApp { app in
            // No brobot history (would otherwise qualify for first_try), but brobot disabled.
            let userId = try await makeEligibleUser(app: app)
            let db = app.db(.notifications)

            let pref = NotificationPreference(userId: userId, category: .brobot, enabled: false)
            try await pref.create(on: db)

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)
            #expect(result.created == 1)
            #expect(result.byType["learning.daily_pearl"] == 1)
        }
    }

    @Test("Disabled brobot AND learning preferences yields no candidate")
    func disabledBothPreferencesYieldsNoCandidate() async throws {
        try await withApp { app in
            let userId = try await makeEligibleUser(app: app)
            let db = app.db(.notifications)

            try await NotificationPreference(userId: userId, category: .brobot, enabled: false).create(on: db)
            try await NotificationPreference(userId: userId, category: .learning, enabled: false).create(on: db)

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)
            #expect(result.created == 0)
            #expect(result.skippedNoEligibleType == 1)
        }
    }

    // MARK: - Priority

    @Test("User with no BroBot history gets first_try priority")
    func userWithNoBrobotHistoryGetsFirstTry() async throws {
        try await withApp { app in
            let userId = try await makeEligibleUser(app: app, trainingLevel: "MD/DO Resident")
            let db = app.db(.notifications)

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)
            #expect(result.byType["brobot.first_try"] == 1)
        }
    }

    @Test("User with BroBot history and training level gets oite_question, not first_try")
    func userWithHistoryAndTrainingLevelGetsOiteQuestion() async throws {
        try await withApp { app in
            let userId = try await makeEligibleUser(app: app, trainingLevel: "MD/DO Resident", withBrobotHistory: true)
            let db = app.db(.notifications)

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)
            #expect(result.byType["learning.oite_question"] == 1)
        }
    }

    @Test("User with BroBot history and no training level gets daily_pearl")
    func userWithHistoryAndNoTrainingLevelGetsDailyPearl() async throws {
        try await withApp { app in
            let userId = try await makeEligibleUser(app: app, trainingLevel: nil, withBrobotHistory: true)
            let db = app.db(.notifications)

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)
            #expect(result.byType["learning.daily_pearl"] == 1)
        }
    }

    @Test("User with no profile row is skipped entirely")
    func userWithNoProfileSkipped() async throws {
        try await withApp { app in
            let userId = UUID()
            let db = app.db(.notifications)
            let device = UserDeviceToken(userId: userId, token: "no-profile-\(UUID().uuidString)", platform: "ios", environment: "production")
            try await device.create(on: db)
            try await ensureBrobotConversationsTableExists(db: db)
            // Deliberately no user_profiles row.

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)
            #expect(result.skippedNoProfile == 1)
            #expect(result.created == 0)
        }
    }

    // MARK: - Caps

    @Test("Daily cap suppresses extra candidate")
    func dailyCapSuppressesExtraCandidate() async throws {
        try await withApp { app in
            let userId = try await makeEligibleUser(app: app, withBrobotHistory: true)
            let db = app.db(.notifications)

            let state = NotificationUserState(userId: userId, sendsToday: 1, isHoldout: false)
            try await state.create(on: db)

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId)
            #expect(result.skippedCapReached == 1)
            #expect(result.created == 0)
        }
    }

    // MARK: - Command-level behavior

    @Test("Limit is respected across multiple eligible users")
    func limitIsRespected() async throws {
        try await withApp { app in
            let db = app.db(.notifications)
            for _ in 0..<3 {
                _ = try await makeEligibleUser(app: app, withBrobotHistory: true)
            }

            let result = try await generator.run(db: db, dryRun: false, limit: 2, specificUserId: nil)
            #expect(result.evaluated == 2)
            #expect(result.created == 2)
        }
    }

    @Test("Single-user targeting only creates a candidate for that user")
    func singleUserTargetingWorks() async throws {
        try await withApp { app in
            let db = app.db(.notifications)
            let targetUser = try await makeEligibleUser(app: app, withBrobotHistory: true)
            _ = try await makeEligibleUser(app: app, withBrobotHistory: true) // a second, untargeted user

            let result = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: targetUser)
            #expect(result.evaluated == 1)
            #expect(result.created == 1)

            let totalCandidates = try await NotificationCandidate.query(on: db).count()
            #expect(totalCandidates == 1)

            let targetCandidates = try await NotificationCandidate.query(on: db)
                .filter(\.$userId == targetUser)
                .count()
            #expect(targetCandidates == 1)
        }
    }

    // MARK: - Templates

    @Test("Templates are seeded without duplicate rows")
    func templatesAreSeededWithoutDuplicates() async throws {
        try await withApp { app in
            let db = app.db(.notifications)
            // seedTemplates() already ran once in withApp's setup — run it again explicitly.
            try await seedTemplates(app: app)
            try await seedTemplates(app: app)

            let count = try await NotificationTemplate.query(on: db).count()
            #expect(count == 3)
        }
    }

    // MARK: - process-scheduled-notifications

    @Test("process-scheduled-notifications command is registered")
    func processScheduledNotificationsIsRegistered() async throws {
        try await withApp { app in
            #expect(app.asyncCommands.commands.keys.contains(ProcessScheduledNotificationsCommand.name))
            #expect(app.asyncCommands.commands.keys.contains(GenerateLearningCandidatesCommand.name))
            #expect(app.asyncCommands.commands.keys.contains(SeedNotificationTemplatesCommand.name))
        }
    }

    @Test("process-scheduled-notifications sends a due candidate and creates a delivery attempt")
    func processScheduledNotificationsSendsDueCandidate() async throws {
        try await withApp { app in
            let userId = try await makeEligibleUser(app: app, withBrobotHistory: true)
            let db = app.db(.notifications)

            let now = Date()
            _ = try await generator.run(db: db, dryRun: false, limit: nil, specificUserId: userId, now: now.addingTimeInterval(-86400))
            // Force the candidate to be due now regardless of the computed morning schedule.
            if let candidate = try await NotificationCandidate.query(on: db).filter(\.$userId == userId).first() {
                candidate.eligibleAt = now.addingTimeInterval(-60)
                candidate.expiresAt = now.addingTimeInterval(3600)
                try await candidate.update(on: db)
            }

            try await ProcessScheduledNotificationsCommand.process(application: app, limit: 50)

            let updated = try await NotificationCandidate.query(on: db).filter(\.$userId == userId).first()
            #expect(updated?.status == .sent)

            let attempts = try await NotificationDeliveryAttempt.query(on: db)
                .filter(\.$userId == userId)
                .count()
            #expect(attempts > 0)
        }
    }
}
