import Vapor
import Fluent
import Supabase

struct SupabaseServiceKeyStorageKey: StorageKey {
    typealias Value = String
}

extension Application {
    var supabaseServiceKey: String {
        self.storage[SupabaseServiceKeyStorageKey.self]!
    }
}



func routes(_ app: Application) throws {
    print("SERVICE ROLE KEY PREFIX: \(Environment.get("SUPABASE_SERVICE_ROLE_KEY")?.prefix(10) ?? "MISSING")")

    // MARK: - Public Health Check
    app.get { req async in "It works!" }
    app.get("hello") { req async -> String in "Hello, world!" }

    try app.register(collection: TodoController())
    try app.register(collection: YoutubeController())
    
    app.get { req async in
            "SnapOrtho Backend is live!"
        }

    // MARK: - Supabase Auth + Device Registration

    /// Check login + register/update device
    app.post("device", "register") { req async throws -> String in
        struct DeviceRegistrationRequest: Content {
            let deviceToken: String
            let platform: String
            let appVersion: String
        }

        guard let token = req.headers.bearerAuthorization?.token else {
            throw Abort(.unauthorized, reason: "Missing Bearer token")
        }

        let body = try req.content.decode(DeviceRegistrationRequest.self)

        // 1. Get Supabase user info
        let supabase = SupabaseClient(
            supabaseURL: URL(string: "https://geznczcokbgybsseipjg.supabase.co")!,
            supabaseKey: Environment.get("SUPABASE_SERVICE_ROLE_KEY")!
        )

        let uri = URI(string: "https://geznczcokbgybsseipjg.supabase.co/auth/v1/user")

        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(token)")

        let res = try await req.client.get(uri, headers: headers)

        guard res.status == .ok else {
            return "❌ Supabase token is invalid or expired"
        }

        struct SupabaseUser: Content { let id: String }
        let user = try res.content.decode(SupabaseUser.self)

        // 2. Upsert into your Device table
        let now = Date()

        if let existing = try await Device.query(on: req.db)
            .filter(\.$deviceToken == body.deviceToken)
            .first()
        {
            existing.learnUserId = user.id
            existing.platform = body.platform
            existing.appVersion = body.appVersion
            existing.lastSeen = now
            try await existing.save(on: req.db)
            return "✅ Updated existing device for user \(user.id)"
        } else {
            let device = Device(
                deviceToken: body.deviceToken,
                learnUserId: user.id,
                platform: body.platform,
                appVersion: body.appVersion,
                lastSeen: now
            )
            try await device.save(on: req.db)
            return "✅ Registered new device for user \(user.id)"
        }
    }

    // MARK: - Supabase Login Status Check

    app.get("auth", "status") { req async throws -> String in
        guard let token = req.headers.bearerAuthorization?.token else {
            throw Abort(.unauthorized, reason: "Missing Bearer token")
        }

        let uri = URI(string: "https://<your-project-id>.supabase.co/auth/v1/user")

        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(token)")

        let res = try await req.client.get(uri, headers: headers)

        if res.status == .ok {
            struct SupabaseUser: Content { let id: String }
            let user = try res.content.decode(SupabaseUser.self)
            return "✅ Device is logged in as Supabase user: \(user.id)"
        } else {
            return "❌ Device is NOT logged in"
        }
    }
}
