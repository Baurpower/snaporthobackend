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
    app.post("auth", "send-reset-email") { req -> EventLoopFuture<HTTPStatus> in
        struct ResetRequest: Content {
            let email: String
        }

        let resetRequest = try req.content.decode(ResetRequest.self)

        let supabaseURL = "https://geznczcokbgybsseipjg.supabase.co/auth/v1/recover"
        let serviceRoleKey = Environment.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""

        let body = [
            "email": resetRequest.email,
            "redirect_to": "https://api.snap-ortho.com/auth/confirm?redirectUrl=https://myortho-solutions.com/learnpasswordreset"
        ]

        return req.client.post(URI(string: supabaseURL)) { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: serviceRoleKey)
            try req.content.encode(body, as: .json)
        }.map { response in
            if response.status == .ok {
                req.logger.info("✅ Sent reset password email for \(resetRequest.email)")
                return .ok
            } else {
                req.logger.warning("❌ Failed to send reset password email: \(response.status)")
                return .internalServerError
            }
        }
    }

    }
