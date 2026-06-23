import Foundation
import Crypto

/// Deterministic, permanent assignment of users to a holdout group that never receives any
/// notification. Required before any real send ships (Phase 2B+) — clean D7/D30 retention
/// measurement is impossible to retrofit after the fact, so this must exist from Phase 2A.
///
/// "Deterministic" means the same `userId` always produces the same result, with no stored
/// state required to reproduce it — `NotificationUserState.isHoldout` caches this value for
/// query convenience, but the source of truth is this pure function.
enum HoldoutAssignment {
    /// Fraction of users permanently excluded from all notification sends. Kept within the
    /// 5–10% range specified for Phase 2A.
    static let holdoutFraction: Double = 0.08

    /// Returns whether `userId` belongs to the permanent holdout group.
    /// Pure function — same input always produces the same output, no I/O.
    static func isHoldout(userId: UUID, fraction: Double = HoldoutAssignment.holdoutFraction) -> Bool {
        bucket(for: userId) < fraction
    }

    /// Maps a user id to a stable value in [0, 1) via SHA-256. Exposed separately from
    /// `isHoldout` so tests can assert on the underlying distribution, not just one threshold.
    static func bucket(for userId: UUID) -> Double {
        let digest = SHA256.hash(data: Data(userId.uuidString.utf8))
        // Use the first 8 bytes as a UInt64 and normalize to [0, 1).
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Double(value) / Double(UInt64.max)
    }
}
