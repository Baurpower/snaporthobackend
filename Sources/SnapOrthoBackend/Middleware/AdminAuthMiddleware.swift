import Vapor

/// Guards routes that should only be called by the server operator / internal tooling.
/// Accepts either:
/// - `X-Admin-Key: <ADMIN_API_KEY>` (preferred / existing)
/// - `Authorization: Bearer <ADMIN_API_KEY>` (documented contract alternative)
///
/// Does not weaken authorization — missing or wrong credentials are rejected.
struct AdminAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let configuredKey = Environment.get("ADMIN_API_KEY"), !configuredKey.isEmpty else {
            request.logger.critical("ADMIN_API_KEY env var not set — rejecting all admin requests")
            throw Abort(.serviceUnavailable, reason: "Admin API not configured")
        }

        let provided: String?
        if let headerKey = request.headers.first(name: "X-Admin-Key"), !headerKey.isEmpty {
            provided = headerKey
        } else if let bearer = request.headers.bearerAuthorization?.token, !bearer.isEmpty {
            provided = bearer
        } else {
            throw Abort(.unauthorized, reason: "Missing X-Admin-Key header or Authorization Bearer admin token")
        }

        guard let provided, constantTimeEquals(provided, configuredKey) else {
            request.logger.warning("🚫 Admin auth failed — incorrect key provided")
            throw Abort(.forbidden, reason: "Invalid admin key")
        }

        return try await next.respond(to: request)
    }

    /// Best-effort constant-time string compare for admin key material.
    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
