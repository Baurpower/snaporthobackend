import Vapor
import Fluent



func routes(_ app: Application) throws {
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
    
    app.get("auth", "confirm") { req -> EventLoopFuture<Response> in
        guard
            let tokenHash = try? req.query.get(String.self, at: "token_hash"),
            let type = try? req.query.get(String.self, at: "type"),
            let next = try? req.query.get(String.self, at: "next") ?? "/"
        else {
            let errorRedirect = URI(string: "/auth/auth-code-error")
            return req.eventLoop.makeSucceededFuture(req.redirect(to: errorRedirect.string))
        }

        // REST API call to Supabase verifyOtp
        let verifyUrl = URI(string: "https://YOUR_SUPABASE_URL/auth/v1/verify")
        var headers = HTTPHeaders()
        headers.add(name: "apikey", value: "YOUR_SUPABASE_SERVICE_ROLE_KEY")
        headers.add(name: "Content-Type", value: "application/json")

        let payload = VerifyOtpPayload(token_hash: tokenHash, type: type)

        return req.client.post(verifyUrl, headers: headers) { postReq in
            try postReq.content.encode(payload, as: .json)
        }.map { response in
            if response.status == .ok {
                // ✅ Success → redirect to next
                return req.redirect(to: next)
            } else {
                // ❌ Failure → redirect to error page
                let errorRedirect = URI(string: "/auth/auth-code-error")
                return req.redirect(to: errorRedirect.string)
            }
        }
    }

    // MARK: - Payload Struct
    struct VerifyOtpPayload: Content {
        let token_hash: String
        let type: String
    }

}
