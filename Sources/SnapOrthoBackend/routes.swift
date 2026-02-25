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
    
    // Sanity log
    print("SERVICE ROLE KEY PREFIX:",
          Environment.get("SUPABASE_SERVICE_ROLE_KEY")?.prefix(10) ?? "MISSING")
    
    // ───────── 1. Basic public routes ─────────
    app.get { _ async in "SnapOrtho Backend is live!" }
    app.get("hello") { _ async -> String in "Hello, world!" }
    
    // Register your other controllers
    try app.register(collection: TodoController())
    try app.register(collection: YoutubeController())
    
    // Supabase constants
    let supabaseURL  = URL(string: "https://geznczcokbgybsseipjg.supabase.co")!
    let serviceKey   = Environment.get("SUPABASE_SERVICE_ROLE_KEY")!
    
    // ───────── 2. /auth/confirm (OTP redirect) ─────────
    app.get("auth", "confirm") { req async throws -> Response in
        guard
            let tokenHash: String = try? req.query.get(String.self, at: "token_hash"),
            let type: String = try? req.query.get(String.self, at: "type")
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
    
    // ───────── 3. /device/register ─────────
    struct RegisterDevicePayload: Content {
        let deviceToken: String
        let platform: String
        let appVersion: String
        let isAuthenticated: Bool?
        
        // Optional extras
        let language: String?
        let timezone: String?
    }
    
    app.post("device", "register") { req async throws -> HTTPStatus in
        let timestamp = Date()
        req.logger.info("🔥 /device/register HIT at \(timestamp.ISO8601Format())")
        
        // Decode request payload
        let payload = try req.content.decode(RegisterDevicePayload.self)
        req.logger.info("📦 token=\(payload.deviceToken.prefix(8))… platform=\(payload.platform) version=\(payload.appVersion)")
        
        // Determine user ID from JWT (if provided)
        let learnUserId: String
        if let authHeader = req.headers.bearerAuthorization {
            do {
                learnUserId = try decodeSupabaseUID(from: authHeader.token)
                req.logger.info("🔑 Supabase UID decoded: \(learnUserId)")
            } catch {
                req.logger.error("❌ Failed to decode JWT: \(error.localizedDescription)")
                throw Abort(.unauthorized, reason: "Invalid token")
            }
        } else {
            learnUserId = "anonymous"
            req.logger.info("👤 No token found; defaulting to anonymous")
        }
        
        let now = Date()
        
        // Check for existing device entry
        if let existing = try await Device.query(on: req.db)
            .filter(\.$deviceToken == payload.deviceToken)
            .first()
        {
            req.logger.info("♻️ Updating existing device ID=\(existing.id?.uuidString ?? "nil") for user \(learnUserId)")
            
            existing.learnUserId = learnUserId
            existing.lastSeen = now
            existing.language = payload.language
            existing.timezone = payload.timezone
            
            do {
                try await existing.update(on: req.db)
                req.logger.info("✅ Device updated successfully")
            } catch {
                req.logger.error("❌ Failed to update device: \(error.localizedDescription)")
                throw Abort(.internalServerError, reason: "Failed to update device")
            }
        } else {
            req.logger.info("🆕 Creating new device for user \(learnUserId)")
            
            let new = Device(
                deviceToken: payload.deviceToken,
                learnUserId: learnUserId,
                platform: payload.platform,
                appVersion: payload.appVersion,
                lastSeen: now,
                language: payload.language,
                timezone: payload.timezone,
                receiveNotifications: true,
                lastNotified: nil
            )
            
            do {
                try await new.create(on: req.db)
                req.logger.info("✅ Device created successfully")
            } catch {
                req.logger.error("❌ Failed to create device: \(error.localizedDescription)")
                throw Abort(.internalServerError, reason: "Failed to save device")
            }
        }
        
        return .ok
    }
    
    // ───────── 4. /auth/status (user fetch) ─────────
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
    
    // ───────── 5. /send-test-push ─────────
    struct TestPayload: Codable {
        let acme1: String
        let acme2: Int
    }
    
    app.get("send-test-push") { req async throws -> String in
        let token = "7943f1aa1c5b717f67cac9956be0926cfc9190f5887b38afb032849576ecd711"
        
        let payload = TestPayload(acme1: "Hello", acme2: 2)
        
        let notification = APNSAlertNotification(
            alert: .init(
                title: .raw("New Learn Sketch!"),
                subtitle: .raw("Out Now - TLCS classification 🍦")
            ),
            expiration: .immediately,
            priority: .immediately,
            topic: "com.alexbaur.Snap-Ortho", // <-- Replace with your bundle ID
            payload: payload
        )
        
        try await req.apns.client.sendAlertNotification(
            notification,
            deviceToken: token
        )
        
        return "✅ Sent push to token: \(token.prefix(8))..."
    }
    // ───────── 6. /send-missed-users-push ─────────
    app.get("send-missed-users-push") { req async throws -> String in
        let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        
        let inactiveDevices = try await Device.query(on: req.db)
            .filter(\.$lastSeen < oneWeekAgo)
            .filter(\.$receiveNotifications == true)
            .all()
        
        var successCount = 0
        var failureCount = 0
        
        for device in inactiveDevices {
            guard !device.deviceToken.isEmpty else { continue }
            
            struct ReminderPayload: Codable {
                let reminder: String
            }
            
            let payload = ReminderPayload(reminder: "We miss you!")
            
            let notification = APNSAlertNotification(
                alert: .init(
                    title: .raw("We miss you!"),
                    subtitle: .raw("Get back in and crush your next ortho rotation 💪.")),
                expiration: .immediately,
                priority: .immediately,
                topic: "com.alexbaur.Snap-Ortho",
                payload: payload
            )
            
            do {
                try await req.apns.client.sendAlertNotification(notification, deviceToken: device.deviceToken)
                req.logger.info("✅ Push sent to: \(device.deviceToken.prefix(10))")
                successCount += 1
            } catch {
                req.logger.error("❌ Push failed to \(device.deviceToken.prefix(10)): \(error.localizedDescription)")
                failureCount += 1
            }
        }
        
        return "Push attempt finished. Success: \(successCount), Failures: \(failureCount)"
    }
    
    app.get("send-broadcast-push") { req async throws -> String in
        let devices = try await Device.query(on: req.db)
            .filter(\.$receiveNotifications == true)
            .all()
        
        var successCount = 0
        var failureCount = 0
        
        for device in devices {
            guard !device.deviceToken.isEmpty else { continue }
            
            struct BroadcastPayload: Codable {
                let message: String
            }
            
            let payload = BroadcastPayload(message: "New Learn Sketch!")
            
            let notification = APNSAlertNotification(
                alert: .init(
                    title: .raw("New Learn Sketch!"),
                    subtitle: .raw("Out Now - Open fractures 🏍️")
                ),
                expiration: .immediately,
                priority: .immediately,
                topic: "com.alexbaur.Snap-Ortho",
                payload: payload
            )
            
            
            do {
                try await req.apns.client.sendAlertNotification(notification, deviceToken: device.deviceToken)
                req.logger.info("✅ Broadcast push sent to: \(device.deviceToken.prefix(10))")
                successCount += 1
            } catch {
                req.logger.error("❌ Broadcast push failed to \(device.deviceToken.prefix(10)): \(error.localizedDescription)")
                failureCount += 1
            }
        }
        
        return "Broadcast complete. Success: \(successCount), Failures: \(failureCount)"
    }
    
    
    //Database debug
    
    app.get("debug", "devices") { req async throws -> String in
        let devices = try await Device.query(on: req.db).all()
        
        var result = "📱 Registered Devices:\n"
        for device in devices {
            result += """
            - Token: \(device.deviceToken.prefix(10))...
              UserID: \(device.learnUserId)
              Last Seen: \(device.lastSeen)
              Notifications: \(device.receiveNotifications ? "✅" : "❌")
              Platform: \(device.platform)
              App Version: \(device.appVersion)
              Timezone: \(device.timezone ?? "N/A")
            
            """
        }
        
        return result.isEmpty ? "❌ No devices found." : result
    }
    
    let crawler = PublicS3Crawler()
    
    /// GET /images -- all images in the bucket
    app.get("images") { req async throws -> [ImageMetadata] in
        try await crawler.fetchAll(on: req)
    }
    
    
    
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
    
    // ───────── Donations API (for website) ─────────

    struct DonationDTO: Content {
        let name: String
        let amount: Int           // dollars for UI
        let dateISO: String
        let via: String
        let note: String?
    }

    struct DonationTotalsDTO: Content {
        let sumCents: Int
        let sumDollars: Int
        let count: Int
    }

    struct DonationsResponseDTO: Content {
        let source: String
        let donations: [DonationDTO]
        let totals: DonationTotalsDTO
    }

    app.get("donations") { req async throws -> DonationsResponseDTO in
        // limit=80 default, clamp to 1...200
        let limit = min(max((try? req.query.get(Int.self, at: "limit")) ?? 80, 1), 200)

        req.logger.info("📥 GET /donations limit=\(limit)")

        // Make sure we're on Postgres
        let sql = (req.db as! any PostgresDatabase).sql()

        // 1) Totals
        let totalsRow = try await sql.raw("""
            SELECT
              COALESCE(SUM(amount), 0)::bigint AS sum_cents,
              COUNT(*)::bigint AS count
            FROM donations
            WHERE status = 'paid'
        """).first()

        let sumCents = Int((try? totalsRow?.decode(column: "sum_cents", as: Int64.self)) ?? 0)
        let count = Int((try? totalsRow?.decode(column: "count", as: Int64.self)) ?? 0)

        // 2) Recent list
        let rows = try await sql.raw("""
            SELECT
              display_name,
              anonymous,
              message,
              amount,
              created_at
            FROM donations
            WHERE status = 'paid'
            ORDER BY created_at DESC NULLS LAST
            LIMIT \(bind: limit)
        """).all()

        let donations: [DonationDTO] = rows.map { row in
            let display = ((try? row.decode(column: "display_name", as: String?.self)) ?? nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let anonymous = (try? row.decode(column: "anonymous", as: Bool?.self)) ?? nil
            let message = ((try? row.decode(column: "message", as: String?.self)) ?? nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let amountCents64 = (try? row.decode(column: "amount", as: Int64.self)) ?? 0
            let amountDollars = Int((amountCents64 + 50) / 100) // rounded dollars

            let createdAt = (try? row.decode(column: "created_at", as: Date?.self)) ?? nil
            let dateISO = createdAt?.ISO8601Format() ?? ""

            let isAnon = (anonymous ?? false) || display.isEmpty
            let name = isAnon ? "" : display

            return DonationDTO(
                name: name,
                amount: amountDollars,
                dateISO: dateISO,
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
    
    //Bro logs
    app.post("case-prep-log") { req async throws -> HTTPStatus in
        let log = try req.content.decode(CasePrepLog.self)
        try await log.save(on: req.db)
        return .created
    }
}




// MARK: – JWT decoder for Supabase UID
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
        while base64.count % 4 != 0 {
            base64 += "="
        }
        self.init(base64Encoded: base64)
    }
}
