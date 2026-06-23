import Vapor
import Fluent
import FluentPostgresDriver

/// Generates Phase 2B candidates: `learning.daily_pearl`, `learning.oite_question`, and
/// `brobot.first_try`. Writes only to `notification_candidates` — never touches
/// `notification_delivery_attempts` directly and never sends anything. Dispatch happens
/// later, via `ProcessScheduledNotificationsCommand`.
///
/// Design decision — type selection is mutually exclusive per user per run (at most one
/// candidate created per eligible user), chosen by priority:
///   1. `brobot.first_try`      — zero BroBot conversations ever, brobot category eligible
///   2. `learning.oite_question` — has a usable `training_level`, learning category eligible
///   3. `learning.daily_pearl`   — generic fallback, learning category eligible
///
/// Note this places `oite_question` above the generic `daily_pearl` for users who have a
/// training_level, which is the opposite of the literal numbered order in the originating
/// spec ("1. first_try, 2. daily_pearl, 3. oite_question"). Taking that list as strict
/// always-prefer-lower-number priority would make `oite_question` effectively unreachable,
/// since anyone who qualifies for it (device + profile + training_level) is a strict subset
/// of who qualifies for `daily_pearl` (device + profile) — the higher-priority type would
/// always win and `oite_question` would never fire. Preferring the more personalized type
/// when the data to personalize exists is the only reading that makes both types reachable.
/// See NOTIFICATION_PHASE2B_IMPLEMENTATION.md for the full rationale — flagged there in case
/// this interpretation should be overridden.
struct LearningCandidateGenerator {
    let apnsEnvironment: String
    let logger: Logger

    // MARK: - Result

    struct Result: Sendable {
        var evaluated = 0
        var created = 0
        var wouldCreate = 0
        var skippedNoActiveToken = 0
        var skippedNoProfile = 0
        var skippedHoldout = 0
        var skippedPreferenceDisabled = 0
        var skippedCooldown = 0
        var skippedCapReached = 0
        var skippedNoEligibleType = 0
        var skippedMissingTemplate = 0

        var byType: [String: Int] = [:]

        mutating func recordType(_ notificationType: String, dryRun: Bool) {
            byType[notificationType, default: 0] += 1
            if dryRun { wouldCreate += 1 } else { created += 1 }
        }
    }

    // MARK: - Entry point

    func run(
        db: any Database,
        dryRun: Bool,
        limit: Int?,
        specificUserId: UUID?,
        now: Date = Date()
    ) async throws -> Result {
        var result = Result()

        let candidateUserIds = try await eligibleUserIds(
            db: db, limit: limit, specificUserId: specificUserId
        )

        for userId in candidateUserIds {
            result.evaluated += 1
            try await evaluate(userId: userId, db: db, dryRun: dryRun, now: now, result: &result)
        }

        logger.info("""
        📊 Learning candidate generation \(dryRun ? "(DRY RUN)" : "(COMMITTED)"):
           evaluated=\(result.evaluated) created=\(result.created) wouldCreate=\(result.wouldCreate)
           skipped: noToken=\(result.skippedNoActiveToken) noProfile=\(result.skippedNoProfile) \
        holdout=\(result.skippedHoldout) prefDisabled=\(result.skippedPreferenceDisabled) \
        cooldown=\(result.skippedCooldown) capReached=\(result.skippedCapReached) \
        noEligibleType=\(result.skippedNoEligibleType) missingTemplate=\(result.skippedMissingTemplate)
           byType=\(result.byType)
        """)

        return result
    }

    // MARK: - Audience query

    /// Distinct user_ids with at least one active, opted-in device token matching the
    /// configured APNS environment. Never selects by raw token — only ever joins on user_id.
    private func eligibleUserIds(
        db: any Database, limit: Int?, specificUserId: UUID?
    ) async throws -> [UUID] {
        var query = UserDeviceToken.query(on: db)
            .filter(\.$invalidatedAt == .null)
            .filter(\.$receiveNotifications == true)
            .filter(\.$environment == apnsEnvironment)
            .filter(\.$userId != .null)

        if let specificUserId {
            query = query.filter(\.$userId == specificUserId)
        }

        let tokens = try await query.all()
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for token in tokens {
            guard let uid = token.userId, !seen.contains(uid) else { continue }
            seen.insert(uid)
            ordered.append(uid)
            if let limit, ordered.count >= limit { break }
        }
        return ordered
    }

    // MARK: - Per-user evaluation

    private func evaluate(
        userId: UUID, db: any Database, dryRun: Bool, now: Date, result: inout Result
    ) async throws {
        // Re-verify there's still at least one active token for this exact user (defensive —
        // the audience query already guarantees this, but keeps this function correct if
        // ever called directly with an arbitrary user id, e.g. from --user-id).
        let hasActiveToken = try await UserDeviceToken.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$invalidatedAt == .null)
            .filter(\.$receiveNotifications == true)
            .filter(\.$environment == apnsEnvironment)
            .count() > 0
        guard hasActiveToken else {
            result.skippedNoActiveToken += 1
            return
        }

        guard let profile = try await fetchProfile(userId: userId, db: db) else {
            result.skippedNoProfile += 1
            return
        }

        let state = try await fetchOrCreateUserState(userId: userId, db: db)

        if state.isHoldout || state.isAllGrowthHoldout {
            result.skippedHoldout += 1
            return
        }

        guard CandidateRanking.canSendRespectingDailyCap(category: .learning, sendsToday: state.sendsToday),
              CandidateRanking.canSendRespectingWeeklyCap(
                category: .learning, isConversionType: false,
                sendsThisWeek: state.sendsThisWeek, conversionSendsThisWeek: 0
              )
        else {
            result.skippedCapReached += 1
            return
        }

        guard let selection = try await selectCandidateType(
            userId: userId, profile: profile, state: state, db: db, now: now
        ) else {
            result.skippedNoEligibleType += 1
            return
        }

        guard let template = try await NotificationTemplate.query(on: db)
            .filter(\.$notificationType == selection.notificationType)
            .filter(\.$isActive == true)
            .first()
        else {
            logger.warning("⚠️ No active template for \(selection.notificationType) — skipping user \(userId)")
            result.skippedMissingTemplate += 1
            return
        }

        let alreadyScheduled = try await existingCandidateWithinCooldown(
            userId: userId,
            notificationType: selection.notificationType,
            cooldown: selection.cooldown,
            db: db,
            now: now
        )
        guard !alreadyScheduled else {
            result.skippedCooldown += 1
            return
        }

        let deviceTimezone = try await UserDeviceToken.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$timezone != .null)
            .first()?
            .timezone

        let scheduledFor = NextMorningScheduler.nextMorning(timezone: deviceTimezone, now: now)
        let expiresAt = scheduledFor.addingTimeInterval(12 * 3600)

        let payload: [String: String] = [
            "title": template.titleTemplate,
            "body": template.bodyTemplate,
            "deeplink": template.deeplinkTemplate ?? "",
            "template_id": template.id?.uuidString ?? "",
            "template_type": template.notificationType,
            "source": selection.analyticsSource,
            "version": String(template.version),
        ]

        let candidate = NotificationCandidate(
            userId: userId,
            sourceType: selection.sourceType.rawValue,
            sourceRefId: selection.sourceRefId,
            category: selection.sourceType.category,
            notificationType: selection.notificationType,
            priorityScore: selection.sourceType.priorityScore,
            payload: payload,
            eligibleAt: scheduledFor,
            expiresAt: expiresAt
        )

        if dryRun {
            result.recordType(selection.notificationType, dryRun: true)
            logger.info("🔎 [DRY RUN] Would create \(selection.notificationType) for user \(userId), scheduled_for=\(scheduledFor)")
            return
        }

        do {
            try await candidate.create(on: db)
            result.recordType(selection.notificationType, dryRun: false)
            logger.info("✅ Created \(selection.notificationType) candidate for user \(userId)")
        } catch {
            // Most likely the unique index catching a race with another concurrent run —
            // treat as "already scheduled" rather than failing the whole batch.
            logger.warning("⚠️ Failed to create candidate for user \(userId) (likely duplicate): \(error)")
            result.skippedCooldown += 1
        }
    }

    // MARK: - Type selection

    private struct CandidateSelection {
        let sourceType: CandidateSourceType
        let notificationType: String
        let sourceRefId: UUID?
        let cooldown: TimeInterval
        let analyticsSource: String
    }

    private func selectCandidateType(
        userId: UUID, profile: Profile, state: NotificationUserState, db: any Database, now: Date
    ) async throws -> CandidateSelection? {
        // 1. brobot.first_try — zero BroBot conversations ever, brobot category eligible
        if !state.isBrobotHoldout, try await isCategoryEnabled(.brobot, userId: userId, db: db) {
            let conversationCount = try await brobotConversationCount(userId: userId, db: db)
            if conversationCount == 0 {
                let bucketKey = DeterministicCandidateRef.multiDayBucketKey(for: now, days: 14)
                return CandidateSelection(
                    sourceType: .brobotFirstTrial,
                    notificationType: "brobot.first_try",
                    sourceRefId: DeterministicCandidateRef.forBucket(
                        userId: userId, sourceType: CandidateSourceType.brobotFirstTrial.rawValue, bucketKey: bucketKey
                    ),
                    cooldown: 14 * 24 * 3600,
                    analyticsSource: "first_brobot_try"
                )
            }
        }

        // 2/3. Learning — oite_question (personalized) preferred over daily_pearl (generic)
        guard !state.isLearningHoldout, try await isCategoryEnabled(.learning, userId: userId, db: db) else {
            return nil
        }

        let dayKey = DeterministicCandidateRef.dayBucketKey(for: now)

        if let trainingLevel = profile.trainingLevel,
           !trainingLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CandidateSelection(
                sourceType: .learningOiteQuestion,
                notificationType: "learning.oite_question",
                sourceRefId: DeterministicCandidateRef.forBucket(
                    userId: userId, sourceType: CandidateSourceType.learningOiteQuestion.rawValue, bucketKey: dayKey
                ),
                cooldown: 24 * 3600,
                analyticsSource: "oite_question"
            )
        }

        return CandidateSelection(
            sourceType: .learningDaily,
            notificationType: "learning.daily_pearl",
            sourceRefId: DeterministicCandidateRef.forBucket(
                userId: userId, sourceType: CandidateSourceType.learningDaily.rawValue, bucketKey: dayKey
            ),
            cooldown: 24 * 3600,
            analyticsSource: "daily_pearl"
        )
    }

    // MARK: - Preferences

    private func isCategoryEnabled(_ category: NotificationCategory, userId: UUID, db: any Database) async throws -> Bool {
        let pref = try await NotificationPreference.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$category == category.rawValue)
            .first()
        return pref?.enabled ?? category.defaultEnabled
    }

    // MARK: - Cooldown / idempotency pre-check

    private func existingCandidateWithinCooldown(
        userId: UUID, notificationType: String, cooldown: TimeInterval, db: any Database, now: Date
    ) async throws -> Bool {
        let cutoff = now.addingTimeInterval(-cooldown)
        let count = try await NotificationCandidate.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$notificationType == notificationType)
            .filter(\.$createdAt >= cutoff)
            .count()
        return count > 0
    }

    // MARK: - NotificationUserState fetch-or-create

    private func fetchOrCreateUserState(userId: UUID, db: any Database) async throws -> NotificationUserState {
        if let existing = try await NotificationUserState.query(on: db)
            .filter(\.$userId == userId)
            .first()
        {
            return existing
        }
        let created = NotificationUserState(
            userId: userId,
            isHoldout: HoldoutAssignment.isHoldout(userId: userId)
        )
        try await created.create(on: db)
        return created
    }

    // MARK: - Read-only access to pre-existing product tables
    //
    // user_profiles and brobot_conversations are owned by other parts of the product and are
    // never written to here — raw read-only SQL, no Fluent model, no migration, matching this
    // codebase's convention for tables this service doesn't own (see routes.swift donations
    // queries for the same pattern).

    struct Profile: Sendable {
        let trainingLevel: String?
    }

    private func fetchProfile(userId: UUID, db: any Database) async throws -> Profile? {
        guard let pg = db as? any PostgresDatabase else { return nil }
        let row = try await pg.sql().raw("""
            SELECT training_level FROM user_profiles WHERE user_id = \(bind: userId) LIMIT 1
        """).first()
        guard let row else { return nil }
        let trainingLevel = try? row.decode(column: "training_level", as: String?.self)
        return Profile(trainingLevel: trainingLevel ?? nil)
    }

    private func brobotConversationCount(userId: UUID, db: any Database) async throws -> Int {
        guard let pg = db as? any PostgresDatabase else { return 0 }
        let row = try await pg.sql().raw("""
            SELECT COUNT(*) AS cnt FROM brobot_conversations WHERE user_id = \(bind: userId)
        """).first()
        guard let row else { return 0 }
        return Int((try? row.decode(column: "cnt", as: Int64.self)) ?? 0)
    }
}
