import Vapor
import Fluent
import Supabase
import APNS
import APNSCore
import PostgresKit


// MARK: – Supabase service-role key storage
struct SupabaseServiceKeyStorageKey: StorageKey { typealias Value = String }

extension Application {
    var supabaseServiceKey: String {
        storage[SupabaseServiceKeyStorageKey.self]!
    }
}

// MARK: – Main routes
func routes(_ app: Application) throws {

    // Sanity log — only prefix, never the full key
    let keyPrefix = Environment.get("SUPABASE_SERVICE_ROLE_KEY")?.prefix(10) ?? "MISSING"
    app.logger.info("SERVICE ROLE KEY PREFIX: \(keyPrefix)")

    // ───────── 1. Basic public routes ─────────
    app.get { _ async in "SnapOrtho Backend is live!" }
    app.get("hello") { _ async -> String in "Hello, world!" }

    try app.register(collection: TodoController())
    try app.register(collection: YoutubeController())

    let supabaseURL = URL(string: "https://geznczcokbgybsseipjg.supabase.co")!
    let serviceKey  = Environment.get("SUPABASE_SERVICE_ROLE_KEY")!

    // ───────── 2. /auth/confirm (OTP redirect) ─────────
    app.get("auth", "confirm") { req async throws -> Response in
        guard
            let tokenHash: String = try? req.query.get(String.self, at: "token_hash"),
            let type: String      = try? req.query.get(String.self, at: "type")
        else {
            throw Abort(.badRequest, reason: "Missing token_hash or type")
        }

        let redirectPath = (try? req.query.get(String.self, at: "next")) ?? "/"
        req.logger.info("🔑 /auth/confirm → \(tokenHash.prefix(10))…, type=\(type)")

        struct OTPPayload: Content {
            let type: String
            let token: String
        }

        let verifyURI = URI(string: "\(supabaseURL)/auth/v1/verify")
        let resp = try await req.client.post(verifyURI) { post in
            try post.content.encode(OTPPayload(type: type, token: tokenHash))
            post.headers.bearerAuthorization = .init(token: serviceKey)
        }

        if resp.status == .ok {
            req.logger.info("✅ OTP verified")
            return req.redirect(to: redirectPath)
        } else {
            req.logger.warning("❌ OTP failed (\(resp.status))")
            return req.redirect(to: "/auth/auth-code-error")
        }
    }

    // ───────── 3. POST /device/register (dual-write) ─────────
    //
    // Phase 1 dual-write:
    //   1. Write to Amazon RDS `devices` (backward compat — existing app behavior)
    //   2. Write to Supabase `user_device_tokens` (new source of truth for notifications)
    //
    // Do not trust any client-supplied user ID. User ID is always derived from the
    // verified Bearer JWT token.

    struct RegisterDevicePayload: Content {
        let deviceToken: String
        let platform: String
        let appVersion: String
        let buildNumber: String?
        let environment: String?            // "production" | "sandbox" — defaults to "production"
        let isAuthenticated: Bool?

        // Optional extras
        let language: String?
        let timezone: String?
        let receiveNotifications: Bool?     // defaults to true
    }

    app.post("device", "register") { req async throws -> HTTPStatus in
        let ts = Date()
        req.logger.info("🔥 /device/register HIT at \(ts.ISO8601Format())")

        let payload = try req.content.decode(RegisterDevicePayload.self)
        // Never log the raw token
        req.logger.info("📦 token_hash=\(UserDeviceToken.hash(payload.deviceToken).prefix(12))… platform=\(payload.platform)")

        let environment = payload.environment ?? "production"
        guard environment == "production" || environment == "sandbox" else {
            throw Abort(.badRequest, reason: "environment must be 'production' or 'sandbox'")
        }

        // Derive user ID from cryptographically verified JWT — never from client body.
        let (learnUserId, supabaseUserId): (String, UUID?) = await {
            if let uid = await req.optionalVerifiedSupabaseUserId() {
                req.logger.info("🔑 Authenticated user \(uid)")
                return (uid.uuidString, uid)
            }
            if req.headers.bearerAuthorization != nil {
                req.logger.warning("⚠️ Invalid or unverifiable Bearer token — registering as anonymous")
            } else {
                req.logger.info("👤 No Bearer token — anonymous registration")
            }
            return ("anonymous", nil)
        }()

        let now = Date()
        let receiveNotifications = payload.receiveNotifications ?? true

        // ── Write 1: Amazon RDS legacy `devices` table ──
        do {
            if let existing = try await Device.query(on: req.db)
                .filter(\.$deviceToken == payload.deviceToken)
                .first()
            {
                existing.learnUserId = learnUserId
                existing.lastSeen = now
                existing.language = payload.language
                existing.timezone = payload.timezone
                try await existing.update(on: req.db)
                req.logger.info("♻️ [Amazon] Updated device")
            } else {
                let new = Device(
                    deviceToken: payload.deviceToken,
                    learnUserId: learnUserId,
                    platform: payload.platform,
                    appVersion: payload.appVersion,
                    lastSeen: now,
                    language: payload.language,
                    timezone: payload.timezone,
                    receiveNotifications: receiveNotifications,
                    lastNotified: nil
                )
                try await new.create(on: req.db)
                req.logger.info("🆕 [Amazon] Created device")
            }
        } catch {
            req.logger.error("❌ [Amazon] Device write failed: \(error)")
            throw Abort(.internalServerError, reason: "Failed to register device")
        }

        // ── Write 2: Supabase `user_device_tokens` table ──
        if app.databases.ids().contains(.notifications) {
            do {
                try await upsertSupabaseDeviceToken(
                    rawToken: payload.deviceToken,
                    userID: supabaseUserId,
                    platform: payload.platform,
                    environment: environment,
                    appVersion: payload.appVersion,
                    buildNumber: payload.buildNumber,
                    timezone: payload.timezone,
                    receiveNotifications: receiveNotifications,
                    db: req.db(.notifications),
                    logger: req.logger
                )
            } catch {
                // Phase 1: Supabase write is secondary — log but don't fail the request.
                // Phase 2: Supabase will become primary and this will be promoted to a hard failure.
                req.logger.error("⚠️ [Supabase] Device write failed (non-fatal in Phase 1): \(error)")
            }
        }

        return .ok
    }

    // ───────── 4. /auth/status ─────────
    app.get("auth", "status") { req async throws -> String in
        guard let bearer = req.headers.bearerAuthorization?.token
        else { throw Abort(.unauthorized, reason: "Missing Bearer token") }

        let userInfoURL = URI(string: "\(supabaseURL)/auth/v1/user")
        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(bearer)")

        let resp = try await req.client.get(userInfoURL, headers: headers)

        if resp.status == .ok {
            struct SupabaseUser: Content { let id: String }
            let user = try resp.content.decode(SupabaseUser.self)
            return "✅ Logged in as Supabase user \(user.id)"
        } else {
            return "❌ Not logged in"
        }
    }

    // ───────── 5. Notification routes ─────────
    try registerNotificationRoutes(app)

    // ───────── 6. Deprecated admin push routes (now POST, require admin key) ─────────
    //
    // These old paths are kept for operator convenience during Phase 1 transition.
    // They are now authenticated and route through NotificationService.
    // After Phase 2, migrate callers to POST /admin/notifications/broadcast.

    let legacyAdmin = app.grouped(AdminAuthMiddleware())

    legacyAdmin.post("send-test-push") { req async throws -> String in
        req.logger.warning("⚠️ Deprecated: use POST /admin/notifications/test instead")

        let db = req.db(.notifications)
        let apnsEnv = req.application.storage[APNSRuntimeConfigStorageKey.self]?.environment ?? "production"
        guard let device = try await UserDeviceToken.query(on: db)
            .filter(\.$environment == apnsEnv)
            .filter(\.$invalidatedAt == .null)
            .first()
        else {
            return "⚠️ No registered devices found for test push"
        }

        let svc = req.application.notificationService
        let result = try await svc.sendToDevice(
            rawToken: device.token,
            environment: device.environment,
            category: .system,
            notificationType: "admin.test",
            title: "SnapOrtho Test",
            body: "Push notification test 🩻",
            allowCrossEnvironment: true,
            db: db
        )
        return "✅ Test push sent (deprecated). Sent=\(result.sent) Failed=\(result.failed) Skipped=\(result.skipped)"
    }

    legacyAdmin.post("send-broadcast-push") { req async throws -> String in
        req.logger.warning("⚠️ Deprecated: use POST /admin/notifications/broadcast instead")
        let db = req.db(.notifications)
        let svc = req.application.notificationService
        let result = try await svc.broadcast(
            category: .product,
            notificationType: "product.announcement",
            title: "SnapOrtho",
            body: "New content available — open the app to see what's new.",
            deeplink: nil,
            metadata: [:],
            db: db
        )
        return "Broadcast complete (deprecated). Sent=\(result.sent) Failed=\(result.failed) Skipped=\(result.skipped)"
    }

    legacyAdmin.post("send-missed-users-push") { req async throws -> String in
        req.logger.warning("⚠️ Deprecated: use POST /admin/notifications/broadcast with inactiveDaysOnly instead")
        let db = req.db(.notifications)
        let svc = req.application.notificationService
        let result = try await svc.broadcastToInactiveUsers(
            inactiveDays: 7,
            category: .product,
            notificationType: "product.reactivation",
            title: "We miss you!",
            body: "Get back in and crush your next ortho rotation 💪.",
            deeplink: "snaportho://home",
            metadata: [:],
            db: db
        )
        return "Missed-users push complete (deprecated). Sent=\(result.sent) Failed=\(result.failed) Skipped=\(result.skipped)"
    }

    // ───────── 7. /debug/devices — REMOVED ─────────
    // This endpoint exposed raw device tokens and had no authentication.
    // It has been removed. Use the Supabase dashboard or admin-authenticated
    // queries for device inspection.

    // ───────── 8. Images / S3 ─────────
    let crawler = PublicS3Crawler()
    app.get("images") { req async throws -> [ImageMetadata] in
        try await crawler.fetchAll(on: req)
    }

    // ───────── 9. BroBot config ─────────
    struct BrobotAvgTimeResponse: Content { let avgMs: Int }
    app.get("brobot", "avg-time") { req async throws -> BrobotAvgTimeResponse in
        let raw = Environment.get("BROBOT_AVG_MS")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ms = Int(raw) ?? 3000
        return BrobotAvgTimeResponse(avgMs: min(max(ms, 500), 120_000))
    }

    // ───────── 10. Stripe webhook ─────────
    app.post("stripe-webhook") { req async throws -> HTTPStatus in
        guard let secret = Environment.get("STRIPE_WEBHOOK_SECRET"), !secret.isEmpty else {
            req.logger.critical("Missing STRIPE_WEBHOOK_SECRET")
            throw Abort(.internalServerError)
        }

        let rawBody = req.body.data ?? ByteBuffer()

        guard let sigHeader = req.headers.first(name: "Stripe-Signature") else {
            throw Abort(.badRequest, reason: "Missing Stripe-Signature header.")
        }

        try StripeWebhook.verifySignature(payload: rawBody, signatureHeader: sigHeader, secret: secret)

        let event = try StripeWebhook.decodeEvent(from: rawBody)
        guard event.type == "payment_intent.succeeded" else { return .ok }

        let pi = event.data.object
        if let status = pi.status, status != "succeeded" { return .ok }

        let md = pi.metadata ?? [:]
        let billing = (md["billing_name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let display = (md["display_name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let anonStr = (md["anonymous"] ?? "false").lowercased()
        let anonymous = (anonStr == "true" || anonStr == "1" || anonStr == "yes")
        let email = (md["email"] ?? pi.receipt_email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = (md["message"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !email.isEmpty else {
            req.logger.warning("Webhook PI \(pi.id) missing email; skipping insert.")
            return .ok
        }

        // Donations stay in Amazon RDS — intentionally using req.db (not .notifications)
        try await (req.db as! any PostgresDatabase).sql().raw("""
            INSERT INTO donations
                (billing_name, display_name, anonymous, email, message, amount, stripe_id, status)
            VALUES
                (\(bind: billing),
                 \(bind: display),
                 \(bind: anonymous),
                 \(bind: email),
                 \(bind: msg),
                 \(bind: pi.amount),
                 \(bind: pi.id),
                 'paid')
            ON CONFLICT (stripe_id) DO NOTHING
        """).run()

        return .ok
    }

    // ───────── 11. Donations API ─────────
    struct DonationDTO: Content {
        let name: String; let amount: Int; let dateISO: String; let via: String; let note: String?
    }
    struct DonationTotalsDTO: Content { let sumCents: Int; let sumDollars: Int; let count: Int }
    struct DonationsResponseDTO: Content { let source: String; let donations: [DonationDTO]; let totals: DonationTotalsDTO }

    app.get("donations") { req async throws -> DonationsResponseDTO in
        let limit = min(max((try? req.query.get(Int.self, at: "limit")) ?? 80, 1), 200)
        req.logger.info("📥 GET /donations limit=\(limit)")
        let sql = (req.db as! any PostgresDatabase).sql()

        let totalsRow = try await sql.raw("""
            SELECT COALESCE(SUM(amount), 0)::bigint AS sum_cents, COUNT(*)::bigint AS count
            FROM donations WHERE status = 'paid'
        """).first()

        let sumCents = Int((try? totalsRow?.decode(column: "sum_cents", as: Int64.self)) ?? 0)
        let count    = Int((try? totalsRow?.decode(column: "count",     as: Int64.self)) ?? 0)

        let rows = try await sql.raw("""
            SELECT display_name, anonymous, message, amount, created_at
            FROM donations WHERE status = 'paid'
            ORDER BY created_at DESC NULLS LAST LIMIT \(bind: limit)
        """).all()

        let donations: [DonationDTO] = rows.map { row in
            let display = ((try? row.decode(column: "display_name", as: String?.self)) ?? nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = ((try? row.decode(column: "message", as: String?.self)) ?? nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let amountCents = (try? row.decode(column: "amount", as: Int64.self)) ?? 0
            let createdAt = (try? row.decode(column: "created_at", as: Date?.self)) ?? nil
            return DonationDTO(
                name: display,
                amount: Int((amountCents + 50) / 100),
                dateISO: createdAt?.ISO8601Format() ?? "",
                via: "Stripe",
                note: (message?.isEmpty == false) ? message : nil
            )
        }

        return DonationsResponseDTO(
            source: "db:donations",
            donations: donations,
            totals: DonationTotalsDTO(
                sumCents: sumCents,
                sumDollars: Int((Int64(sumCents) + 50) / 100),
                count: count
            )
        )
    }

    // ───────── 12. CasePrepLog ─────────
    app.post("case-prep-log") { req async throws -> HTTPStatus in
        let log = try req.content.decode(CasePrepLog.self)
        try await log.save(on: req.db)
        return .created
    }
}


// MARK: – JWT decoder for Supabase UID (legacy — preserved for backward compatibility)
func decodeSupabaseUID(from jwt: String) throws -> String {
    struct Claims: Decodable { let sub: String }
    let parts = jwt.split(separator: ".")
    guard parts.count == 3,
          let payloadData = Data(base64URLEncoded: String(parts[1])) else {
        throw Abort(.unauthorized, reason: "Malformed JWT")
    }
    return try JSONDecoder().decode(Claims.self, from: payloadData).sub
}

private extension Data {
    init?(base64URLEncoded input: String) {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}
