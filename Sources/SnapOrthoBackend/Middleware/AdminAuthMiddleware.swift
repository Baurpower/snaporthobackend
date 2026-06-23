import Vapor

/// Guards routes that should only be called by the server operator / internal tooling.
/// Requires the `X-Admin-Key` header to match the `ADMIN_API_KEY` environment variable.
struct AdminAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let configuredKey = Environment.get("ADMIN_API_KEY"), !configuredKey.isEmpty else {
            request.logger.critical("ADMIN_API_KEY env var not set — rejecting all admin requests")
            throw Abort(.serviceUnavailable, reason: "Admin API not configured")
        }

        guard let provided = request.headers.first(name: "X-Admin-Key") else {
            throw Abort(.unauthorized, reason: "Missing X-Admin-Key header")
        }

        // Constant-time comparison to prevent timing attacks
        guard provided == configuredKey else {
            request.logger.warning("🚫 Admin auth failed — incorrect key provided")
            throw Abort(.forbidden, reason: "Invalid admin key")
        }

        return try await next.respond(to: request)
    }
}
