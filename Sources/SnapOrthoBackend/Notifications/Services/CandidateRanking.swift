import Foundation

/// Every candidate source type this notification system knows how to generate, with its
/// static priority score and category. Generators in Phase 2B/2C/2D produce candidates
/// tagged with one of these; this phase only defines the lookup table they'll use.
enum CandidateSourceType: String, CaseIterable, Sendable {
    case brobotAbandoned        = "brobot_abandoned"
    case brobotFollowup24h      = "brobot_followup_24h"
    case brobotRecall72h        = "brobot_recall_72h"
    case conversionUsageLimit   = "conversion_usage_limit"
    case learningRecentTopic    = "learning_recent_topic"
    case brobotFirstTrial       = "brobot_first_trial"
    case learningDaily          = "learning_daily"
    case conversionHighEngagement = "conversion_high_engagement"

    /// Static priority score from the strategy doc's ranking model (Part 6).
    /// Higher fires first when multiple candidates are eligible for one user on one day.
    var priorityScore: Int {
        switch self {
        case .brobotAbandoned:          return 100
        case .brobotFollowup24h:        return 90
        case .brobotRecall72h:          return 70
        case .conversionUsageLimit:     return 60
        case .learningRecentTopic:      return 50
        case .brobotFirstTrial:         return 45
        case .learningDaily:            return 40
        case .conversionHighEngagement: return 15
        }
    }

    var category: NotificationCategory {
        switch self {
        case .brobotAbandoned, .brobotFollowup24h, .brobotRecall72h, .brobotFirstTrial:
            return .brobot
        case .conversionUsageLimit, .conversionHighEngagement:
            return .product
        case .learningRecentTopic, .learningDaily:
            return .learning
        }
    }

    var isConversionType: Bool {
        self == .conversionUsageLimit || self == .conversionHighEngagement
    }
}

/// Pure decision functions for candidate selection. No I/O — callers are responsible for
/// fetching whatever state (NotificationUserState, recent delivery history) these functions
/// need as plain values. Kept this way so the rules are unit-testable without a database
/// and so Phase 2B+ generators share one implementation instead of re-deriving the rules.
enum CandidateRanking {

    // MARK: - Priority

    /// Looks up the static priority score for a raw `source_type` string as stored in
    /// `notification_candidates.source_type`. Unknown source types sort last (score 0)
    /// rather than crashing, since this may run against future source types this version
    /// of the ranking table doesn't yet know about.
    static func priorityScore(forSourceType sourceType: String) -> Int {
        CandidateSourceType(rawValue: sourceType)?.priorityScore ?? 0
    }

    /// Selects the single highest-priority candidate from a list of otherwise-eligible
    /// candidates (already filtered for preferences/quiet-hours/expiration by the caller).
    /// Ties break by earliest `eligibleAt` (oldest opportunity wins), then by insertion
    /// order as a final deterministic tiebreaker.
    static func selectTop<T>(
        from candidates: [T],
        priorityScore: (T) -> Int,
        eligibleAt: (T) -> Date
    ) -> T? {
        candidates.enumerated().min { lhs, rhs in
            let lhsScore = priorityScore(lhs.element)
            let rhsScore = priorityScore(rhs.element)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            let lhsDate = eligibleAt(lhs.element)
            let rhsDate = eligibleAt(rhs.element)
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.offset < rhs.offset
        }?.element
    }

    // MARK: - Cooldowns

    /// 48h minimum between two sends of the same source type to the same user.
    static let sameSourceTypeCooldown: TimeInterval = 48 * 3600

    /// 12h minimum between any two `brobot` category sends to the same user.
    static let brobotCategoryCooldown: TimeInterval = 12 * 3600

    /// 7 days minimum between any two conversion-type sends to the same user.
    static let conversionCooldown: TimeInterval = 7 * 24 * 3600

    static func isWithinCooldown(lastSentAt: Date?, cooldown: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastSentAt else { return false }
        return now.timeIntervalSince(lastSentAt) < cooldown
    }

    /// True if sending `sourceType` to a user right now would violate any applicable cooldown.
    /// `lastSentAtForSameSourceType` / `lastSentAtForCategory` / `lastSentAtForConversionType`
    /// should be the most recent successful (status=sent) send matching each scope, or nil
    /// if none exists — callers fetch these from `notification_delivery_attempts`/
    /// `NotificationUserState`, this function makes no queries itself.
    static func isBlockedByCooldown(
        sourceType: CandidateSourceType,
        lastSentAtForSameSourceType: Date?,
        lastSentAtForCategory: Date?,
        lastSentAtForConversionType: Date?,
        now: Date = Date()
    ) -> Bool {
        if isWithinCooldown(lastSentAt: lastSentAtForSameSourceType, cooldown: sameSourceTypeCooldown, now: now) {
            return true
        }
        if sourceType.category == .brobot,
           isWithinCooldown(lastSentAt: lastSentAtForCategory, cooldown: brobotCategoryCooldown, now: now) {
            return true
        }
        if sourceType.isConversionType,
           isWithinCooldown(lastSentAt: lastSentAtForConversionType, cooldown: conversionCooldown, now: now) {
            return true
        }
        return false
    }

    // MARK: - Caps

    static let maxSendsPerDay = 1
    static let maxSendsPerWeek = 3
    static let maxConversionSendsPerWeek = 1

    /// system bypasses every cap, matching `NotificationCategory.bypassesFrequencyCap`.
    static func canSendRespectingDailyCap(category: NotificationCategory, sendsToday: Int) -> Bool {
        if category.bypassesFrequencyCap { return true }
        return sendsToday < maxSendsPerDay
    }

    static func canSendRespectingWeeklyCap(
        category: NotificationCategory,
        isConversionType: Bool,
        sendsThisWeek: Int,
        conversionSendsThisWeek: Int
    ) -> Bool {
        if category.bypassesFrequencyCap { return true }
        if isConversionType && conversionSendsThisWeek >= maxConversionSendsPerWeek { return false }
        return sendsThisWeek < maxSendsPerWeek
    }
}
