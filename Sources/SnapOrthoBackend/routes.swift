import Vapor
import Fluent
import Supabase

// MARK: – Service-role key storage
struct SupabaseServiceKeyStorageKey: StorageKey { typealias Value = String }

extension Application {
    var supabaseServiceKey: String { storage[SupabaseServiceKeyStorageKey.self]! }
}

// MARK: – Main routes
func routes(_ app: Application) throws {

    // Quick sanity print
    print("SERVICE ROLE KEY PREFIX:",
          Environment.get("SUPABASE_SERVICE_ROLE_KEY")?.prefix(10) ?? "MISSING")

    // ───────── 1. Public endpoints ─────────
    app.get { _ async in "SnapOrtho Backend is live!" }
    app.get("hello") { _ async -> String in "Hello, world!" }

    // Controllers
    try app.register(collection: TodoController())
    try app.register(collection: YoutubeController())

    // Constants
    let supabaseURL  = URL(string: "https://geznczcokbgybsseipjg.supabase.co")!
    let serviceKey   = Environment.get("SUPABASE_SERVICE_ROLE_KEY")!

    // ───────── 2. /auth/confirm (OTP) ─────────
    app.get("auth", "confirm") { req async throws -> Response in
        guard
            let tokenHash: String = try? req.query.get(String.self, at: "token_hash"),
            let type:      String = try? req.query.get(String.self, at: "type")
        else { throw Abort(.badRequest, reason: "Missing token_hash or type") }

        let redirectPath = (try? req.query.get(String.self, at: "next")) ?? "/"
        req.logger.info("🔑 /auth/confirm → \(tokenHash.prefix(10))…, type=\(type)")

        struct OTPPayload: Content { let type: String; let token: String }
        let verifyURI = URI(string: "\(supabaseURL)/auth/v1/verify")

        // Send OTP-verify request
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
    struct DeviceRegistration: Content {
        let deviceToken: String
        let platform:    String
        let appVersion:  String
        let isAuthenticated: Bool
    }

    app.post("device", "register") { req async throws -> String in
        let body = try req.content.decode(DeviceRegistration.self)
        let bearer = req.headers.bearerAuthorization?.token

        var userId = "anonymous"

        if body.isAuthenticated, let token = bearer {
            let userInfoURL = URI(string: "\(supabaseURL)/auth/v1/user")
            var hdrs = HTTPHeaders()
            hdrs.add(name: .authorization, value: "Bearer \(token)")

            let userResp = try await req.client.get(userInfoURL, headers: hdrs)
            if userResp.status == .ok {
                struct SupabaseUser: Content { let id: String }
                userId = try userResp.content.decode(SupabaseUser.self).id
            }
        }

        print("📬 Registering device: \(body.deviceToken.prefix(10))… for user: \(userId)")

        let now = Date()
        if let existing = try await Device.query(on: req.db)
            .filter(\.$deviceToken == body.deviceToken)
            .first()
        {
            existing.learnUserId = userId
            existing.platform    = body.platform
            existing.appVersion  = body.appVersion
            existing.lastSeen    = now
            try await existing.save(on: req.db)
            return "✅ Updated device"
        } else {
            let device = Device(
                deviceToken: body.deviceToken,
                learnUserId: userId,
                platform:    body.platform,
                appVersion:  body.appVersion,
                lastSeen:    now
            )
            try await device.save(on: req.db)
            return "✅ Registered new device"
        }
    }


    // ───────── 4. /auth/status ─────────
    app.get("auth", "status") { req async throws -> String in
        guard let bearer = req.headers.bearerAuthorization?.token
        else { throw Abort(.unauthorized, reason: "Missing Bearer token") }

        let userInfoURL = URI(string: "\(supabaseURL)/auth/v1/user")
        var hdrs = HTTPHeaders()
        hdrs.add(name: .authorization, value: "Bearer \(bearer)")
        let resp = try await req.client.get(userInfoURL, headers: hdrs)

        if resp.status == .ok {
            struct SupabaseUser: Content { let id: String }
            let user = try resp.content.decode(SupabaseUser.self)
            return "✅ Logged in as Supabase user \(user.id)"
        } else {
            return "❌ Not logged in"
        }
    }
}
