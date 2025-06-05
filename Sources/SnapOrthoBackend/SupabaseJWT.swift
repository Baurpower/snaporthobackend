import Vapor
import SwiftJWT

struct SupabaseJWTPayload: JWTPayload {
    let sub: String
    let email: String?

    func verify(using signer: JWTSigner) throws {
        // Basic signature check. You can do more if needed.
    }
}

struct SupabaseJWTMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let authHeader = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing Authorization header")
        }

        let jwtToken = authHeader.token
        let jwksURL = URI(string: "https://hzxdyyjjbiqwdzwhjqoz.supabase.co/auth/v1/keys")

        let jwksResponse = try await request.client.get(jwksURL)
        let jwksData = jwksResponse.body ?? ByteBuffer()
        guard let jsonData = jwksData.getData(at: 0, length: jwksData.readableBytes) else {
            throw Abort(.internalServerError, reason: "Failed to load JWKs")
        }

        let jwks = try JSONDecoder().decode(JWKSet.self, from: jsonData)

        guard let jwk = jwks.keys.first,
              let rsaPublicKey = try? jwk.rsakey else {
            throw Abort(.unauthorized, reason: "No valid JWK")
        }

        let jwtVerifier = JWTVerifier.rs256(publicKey: rsaPublicKey)
        let jwt = try JWT<SupabaseJWTPayload>(jwtString: jwtToken)
        try jwt.verify(using: jwtVerifier)

        request.auth.login(jwt.claims)

        return try await next.respond(to: request)
    }
}
