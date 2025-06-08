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
        app.get("auth", "confirm") { req -> EventLoopFuture<Response> in
            guard let tokenHash = try? req.query.get(String.self, at: "token_hash"),
                  let type = try? req.query.get(String.self, at: "type"),
                  let redirectURL = try? req.query.get(String.self, at: "redirectUrl") else {
                throw Abort(.badRequest, reason: "Missing query parameters.")
            }

            let supabase = SupabaseClient(httpClient: app.client, logger: req.logger)
            return supabase.verifyOtp(type: type, tokenHash: tokenHash).flatMapThrowing { session in
                // You could set cookies here if you want to store access token
                req.logger.info("✅ Verified OTP, redirecting to \(redirectURL)")
                return req.redirect(to: redirectURL)
            }
        }

        // STEP 3: Frontend calls this to set the new password
        app.post("auth", "update-password") { req -> EventLoopFuture<HTTPStatus> in
            struct PasswordUpdateRequest: Content {
                let newPassword: String
            }

            let updateReq = try req.content.decode(PasswordUpdateRequest.self)

            let supabase = SupabaseClient(httpClient: app.client, logger: req.logger)
            return supabase.updatePassword(newPassword: updateReq.newPassword).map {
                req.logger.info("✅ Password updated successfully")
                return .ok
            }
        }

    }

