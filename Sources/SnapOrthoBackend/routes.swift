import Vapor
import Fluent
import Supabase

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
        let payload = try req.content.decode(RegisterDevicePayload.self)

        // Optional: decode Supabase UID from JWT
        let learnUserId: String
        if let authHeader = req.headers.bearerAuthorization {
            learnUserId = try decodeSupabaseUID(from: authHeader.token)
        } else {
            learnUserId = "anonymous"
        }

        let now = Date()

        if let existing = try await Device.query(on: req.db)
            .filter(\.$deviceToken == payload.deviceToken)
            .first()
        {
            existing.learnUserId = learnUserId
            existing.lastSeen = now
            existing.updatedAt = now
            existing.language = payload.language
            existing.timezone = payload.timezone
            try await existing.update(on: req.db)
        } else {
            let new = Device(
                deviceToken: payload.deviceToken,
                learnUserId: learnUserId,
                platform: payload.platform,
                appVersion: payload.appVersion,
                lastSeen: now,
                language: payload.language,
                timezone: payload.timezone,
                receiveNotifications: true,
                lastNotified: nil,
                createdAt: now,
                updatedAt: now
            )
            try await new.create(on: req.db)
        }

        req.logger.info("📬 Registered \(payload.deviceToken.prefix(10))… for \(learnUserId)")
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
