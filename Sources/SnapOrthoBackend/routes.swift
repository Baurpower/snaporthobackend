import Vapor
import Fluent



func routes(_ app: Application) throws {
    
        print("SERVICE ROLE KEY PREFIX: \(Environment.get("SUPABASE_SERVICE_ROLE_KEY")?.prefix(10) ?? "MISSING")")
        
   
    
    // MARK: - 🔓 Public Routes
    
    app.get { req async in
        "It works!"
    }
    
    app.get("hello") { req async -> String in
        "Hello, world!"
    }
    
    try app.register(collection: TodoController())
    
    // Register VideoController for signed URL access
    try app.register(collection: VideoController())
    

        // STEP 2: User clicks email link → hits /auth/confirm
    app.get("auth", "confirm") { req async throws -> Response in
        // 1) Extract token_hash & type
        guard
            let tokenHash: String = try? req.query.get(String.self, at: "token_hash"),
            let type:      String = try? req.query.get(String.self, at: "type")
        else {
            throw Abort(.badRequest, reason: "Missing token_hash or type")
        }

        // 2) Make sure your service‐role key is present
        guard Environment.get("SUPABASE_SERVICE_ROLE_KEY") != nil else {
            req.logger.critical("❌ SUPABASE_SERVICE_ROLE_KEY not set")
            throw Abort(.internalServerError)
        }

        let redirectPath = (try? req.query.get(String.self, at: "next")) ?? "/"
        req.logger.info("🔑 /auth/confirm → token_hash=\(tokenHash.prefix(10))…, type=\(type), next=\(redirectPath)")

        // 3) Init client (it will pull URL+KEY from the env)
        let supabase = SupabaseClient(httpClient: req.client, logger: req.logger)

        // 4) Verify OTP and redirect
        do {
            _ = try await supabase.verifyOtp(type: type, tokenHash: tokenHash)
            req.logger.info("✅ OTP OK → \(redirectPath)")
            return req.redirect(to: redirectPath)
        } catch {
            req.logger.warning("⚠️ OTP failed: \(error.localizedDescription)")
            return req.redirect(to: "/auth/auth-code-error")
        }
    }
    }

