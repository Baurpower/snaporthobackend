import Vapor
import SwiftJWT

// MARK: - JWT Claims
struct SupabaseJWTPayload: Claims {
    let sub: String
    let email: String?
}

// MARK: - Middleware
struct SupabaseJWTMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let authHeader = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing Authorization header")
        }

        let jwtToken = authHeader.token
        let jwksURL = URI(string: "https://hzxdyyjjbiqwdzwhjqoz.supabase.co/auth/v1/keys")
        let jwksResponse = try await request.client.get(jwksURL)

        guard let jwksData = jwksResponse.body?.getData(at: 0, length: jwksResponse.body?.readableBytes ?? 0) else {
            throw Abort(.internalServerError, reason: "Failed to load JWKs")
        }

        let jwks = try JSONDecoder().decode(JWKSet.self, from: jwksData)

        guard let jwk = jwks.keys.first,
              let jwtVerifier = jwk.jwtVerifier else {
            throw Abort(.unauthorized, reason: "No valid JWK verifier")
        }

        let jwt = try JWT<SupabaseJWTPayload>(jwtString: jwtToken, verifier: jwtVerifier)

        // Optionally store the user ID in request.auth or a custom extension here
        // request.auth.login(jwt.claims)

        return try await next.respond(to: request)
    }
}
