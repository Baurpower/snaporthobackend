import Vapor
import Fluent

/// Generates Phase 2B candidates (learning.daily_pearl, learning.oite_question,
/// brobot.first_try) and writes them to `notification_candidates`. Never sends anything —
/// dispatch is a separate, explicit step (`process-scheduled-notifications`).
///
/// Defaults to dry-run. `--commit` is required to actually write rows.
///
/// Usage:
///   swift run SnapOrthoBackend generate-learning-candidates
///   swift run SnapOrthoBackend generate-learning-candidates --commit --limit 100
///   swift run SnapOrthoBackend generate-learning-candidates --user-id <uuid> --dry-run
///   swift run SnapOrthoBackend generate-learning-candidates --user-id <uuid> --commit
struct GenerateLearningCandidatesCommand: AsyncCommand {
    static let name = "generate-learning-candidates"

    struct Signature: CommandSignature {
        @Flag(name: "commit", help: "Actually write candidate rows. Without this, the command only reports counts.")
        var commit: Bool

        @Option(name: "limit", help: "Maximum number of users to evaluate/create candidates for.")
        var limit: Int?

        @Option(name: "user-id", help: "Restrict to a single user (for testing with your own device first).")
        var userId: String?
    }

    var help: String {
        "Generates Phase 2B learning/brobot.first_try notification candidates. Dry-run by default — pass --commit to write."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let logger = app.logger
        let dryRun = !signature.commit

        guard app.databases.ids().contains(.notifications) else {
            logger.critical("❌ .notifications database not configured — cannot generate candidates")
            throw Abort(.internalServerError)
        }

        var specificUserId: UUID?
        if let raw = signature.userId {
            guard let parsed = UUID(uuidString: raw) else {
                logger.critical("❌ --user-id must be a valid UUID")
                throw Abort(.badRequest)
            }
            specificUserId = parsed
        }

        let apnsEnvironment = app.storage[APNSRuntimeConfigStorageKey.self]?.environment ?? "production"

        logger.info("🚀 generate-learning-candidates starting (dryRun=\(dryRun), limit=\(signature.limit.map(String.init) ?? "none"), userId=\(specificUserId?.uuidString ?? "all"), env=\(apnsEnvironment))")

        let generator = LearningCandidateGenerator(apnsEnvironment: apnsEnvironment, logger: logger)
        let result = try await generator.run(
            db: app.db(.notifications),
            dryRun: dryRun,
            limit: signature.limit,
            specificUserId: specificUserId
        )

        if dryRun {
            logger.info("ℹ️ Dry run complete — no rows written. Re-run with --commit to write \(result.wouldCreate) candidate(s).")
        } else {
            logger.info("✅ Commit complete — \(result.created) candidate(s) written.")
        }
    }
}
