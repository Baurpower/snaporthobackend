import Vapor
import Fluent

/// Processes due `notification_candidates` once and exits. This is the dispatch step that
/// Phase 2A's scheduler lifecycle job deliberately deferred (2A only counted pending rows
/// and reset day/week buckets — it never sent anything). Phase 2B adds this manual command
/// rather than wiring dispatch into the always-on lifecycle job, so production rollout can
/// stay deliberate: dry-run a generation, commit one candidate, run this command once to
/// verify the send + delivery-attempt row, and only then consider a larger batch.
///
/// For each user with one or more due candidates, picks the single highest-priority one via
/// `CandidateRanking.selectTop`, checks daily/weekly caps and holdouts via
/// `NotificationUserState`, sends it through the existing `NotificationService` (which already
/// re-checks category preferences and handles token invalidation), and marks the loser
/// candidates (if any) `superseded`.
///
/// Usage:
///   swift run SnapOrthoBackend process-scheduled-notifications
///   swift run SnapOrthoBackend process-scheduled-notifications --limit 10
struct ProcessScheduledNotificationsCommand: AsyncCommand {
    static let name = "process-scheduled-notifications"

    struct Signature: CommandSignature {
        @Option(name: "limit", help: "Maximum number of due candidate rows to fetch in this run (default 50).")
        var limit: Int?
    }

    var help: String {
        "Processes due (eligible_at <= now, not expired, status=pending) notification candidates once and exits."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        try await Self.process(application: context.application, limit: signature.limit ?? 50)
    }

    /// Testable core, separate from the thin CLI wrapper above (matches the pattern used by
    /// `CandidateSchedulerJob.tick` in Phase 2A) — avoids constructing a `CommandSignature`
    /// directly in tests.
    static func process(application app: Application, limit: Int) async throws {
        let logger = app.logger

        guard app.databases.ids().contains(.notifications) else {
            logger.critical("❌ .notifications database not configured — cannot process candidates")
            throw Abort(.internalServerError)
        }

        let db = app.db(.notifications)
        let now = Date()

        let due = try await NotificationCandidate.query(on: db)
            .filter(\.$status == .pending)
            .filter(\.$eligibleAt <= now)
            .filter(\.$expiresAt > now)
            .sort(\.$eligibleAt, .ascending)
            .limit(limit)
            .all()

        logger.info("🚀 process-scheduled-notifications: \(due.count) due candidate(s) fetched (limit=\(limit))")

        var sent = 0
        var supersededCount = 0
        var blockedByCap = 0
        var blockedByHoldout = 0
        var failedToSend = 0

        let byUser = Dictionary(grouping: due, by: { $0.userId })

        for (userId, candidates) in byUser {
            let state = try await fetchOrCreateUserState(userId: userId, db: db)

            if state.isHoldout || state.isAllGrowthHoldout {
                for candidate in candidates {
                    candidate.status = .superseded
                    try await candidate.update(on: db)
                }
                blockedByHoldout += candidates.count
                logger.info("🔕 User \(userId): \(candidates.count) candidate(s) superseded — holdout")
                continue
            }

            guard let winner = CandidateRanking.selectTop(
                from: candidates,
                priorityScore: { $0.priorityScore },
                eligibleAt: { $0.eligibleAt }
            ) else { continue }

            let winnerCategory = NotificationCategory(rawValue: winner.category) ?? .system

            let withinDailyCap = CandidateRanking.canSendRespectingDailyCap(
                category: winnerCategory, sendsToday: state.sendsToday
            )
            let withinWeeklyCap = CandidateRanking.canSendRespectingWeeklyCap(
                category: winnerCategory, isConversionType: false,
                sendsThisWeek: state.sendsThisWeek, conversionSendsThisWeek: 0
            )

            guard withinDailyCap, withinWeeklyCap else {
                for candidate in candidates {
                    candidate.status = .cooldownBlocked
                    try await candidate.update(on: db)
                }
                blockedByCap += candidates.count
                logger.info("🚫 User \(userId): \(candidates.count) candidate(s) blocked — daily/weekly cap reached")
                continue
            }

            let title = winner.payload["title"] ?? ""
            let body = winner.payload["body"] ?? ""
            let deeplink = winner.payload["deeplink"]?.isEmpty == false ? winner.payload["deeplink"] : nil
            let notificationType = winner.notificationType ?? winner.sourceType

            do {
                let svc = app.notificationService
                let sendResult = try await svc.sendToUser(
                    userID: userId,
                    category: winnerCategory,
                    notificationType: notificationType,
                    title: title,
                    body: body,
                    deeplink: deeplink,
                    db: db
                )

                winner.status = .sent
                try await winner.update(on: db)

                state.sendsToday += 1
                state.sendsThisWeek += 1
                state.lastSentAt = now
                state.lastSentCategory = winner.category
                try await state.update(on: db)

                if sendResult.sent > 0 {
                    sent += 1
                    logger.info("✅ User \(userId): sent \(notificationType) (delivered to \(sendResult.sent) device(s))")
                } else {
                    // sendToUser may legitimately deliver to zero devices (e.g. all skipped by
                    // preference re-check, or no active devices at send time) — the candidate
                    // is still marked sent because dispatch was attempted; the reason is
                    // visible in notification_delivery_attempts.
                    failedToSend += 1
                    logger.warning("⚠️ User \(userId): dispatched \(notificationType) but 0 devices received it (sent=0 failed=\(sendResult.failed) skipped=\(sendResult.skipped))")
                }
            } catch {
                failedToSend += 1
                logger.error("❌ User \(userId): failed to dispatch \(notificationType): \(error)")
            }

            for loser in candidates where loser.id != winner.id {
                loser.status = .superseded
                try await loser.update(on: db)
                supersededCount += 1
            }
        }

        logger.info("""
        ✅ process-scheduled-notifications complete:
           users=\(byUser.count) sent=\(sent) superseded=\(supersededCount) \
        blockedByCap=\(blockedByCap) blockedByHoldout=\(blockedByHoldout) failedToSend=\(failedToSend)
        """)
    }

    private static func fetchOrCreateUserState(userId: UUID, db: any Database) async throws -> NotificationUserState {
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
}
