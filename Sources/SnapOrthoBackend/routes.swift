import Vapor
import Fluent
import Supabase
import APNS
import APNSCore

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
        let timestamp = Date().description
        print("🔥 [\(timestamp)] /device/register HIT")
        req.logger.info("🔥 /device/register HIT at \(timestamp)")

        let payload = try req.content.decode(RegisterDevicePayload.self)

        print("📦 Payload deviceToken: \(payload.deviceToken.prefix(10))..., platform: \(payload.platform), appVersion: \(payload.appVersion)")
        req.logger.info("📦 deviceToken=\(payload.deviceToken.prefix(10))..., platform=\(payload.platform), version=\(payload.appVersion)")

        // Optional: decode Supabase UID from JWT
        let learnUserId: String
        if let authHeader = req.headers.bearerAuthorization {
            do {
                learnUserId = try decodeSupabaseUID(from: authHeader.token)
                print("🔑 Decoded Supabase UID: \(learnUserId)")
                req.logger.info("🔑 Decoded Supabase UID: \(learnUserId)")
            } catch {
                print("❌ Failed to decode JWT")
                req.logger.error("❌ JWT decode failed: \(error)")
                throw Abort(.unauthorized, reason: "Invalid token")
            }
        } else {
            learnUserId = "anonymous"
            print("👤 No token provided. Using: anonymous")
            req.logger.info("👤 No token → using anonymous")
        }

        let now = Date()

        if let existing = try await Device.query(on: req.db)
            .filter(\.$deviceToken == payload.deviceToken)
            .first()
        {
            print("♻️ Updating existing device: \(existing.id?.uuidString ?? "nil")")
            req.logger.info("♻️ Updating existing device for user: \(learnUserId)")

            existing.learnUserId = learnUserId
            existing.lastSeen = now
            existing.language = payload.language
            existing.timezone = payload.timezone
            try await existing.update(on: req.db)
        } else {
            print("🆕 Creating new device record...")
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
            try await new.create(on: req.db)
        }

        print("✅ [\(timestamp)] Registered device for \(learnUserId)")
        req.logger.info("✅ Registered device for \(learnUserId)")
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
        let token = "bf848b3b4722372799f11dbe7dc1a465b11f1124c93f2fd79ab2b6270702316f"

        let payload = TestPayload(acme1: "Hello", acme2: 2)

        let notification = APNSAlertNotification(
            alert: .init(
                title: .raw("SnapOrtho"),
                subtitle: .raw("Your test push worked 🚀")
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

            let payload = BroadcastPayload(message: "Time to sharpen your skills!")

            let notification = APNSAlertNotification(
                alert: .init(
                    title: .raw("Ready for ortho rotations?"),
                    subtitle: .raw("Sharpen your fracture conference skills in Practice 🦴📊")
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
