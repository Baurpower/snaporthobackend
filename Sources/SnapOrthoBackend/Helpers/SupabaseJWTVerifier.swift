import Vapor
import JWTKit
import Foundation
import Supabase

// MARK: - Payload

struct SupabaseAccessTokenPayload: JWTPayload {
    var sub: SubjectClaim
    var exp: ExpirationClaim
    var iss: IssuerClaim?
    var role: String?

    func verify(using key: some JWTAlgorithm) throws {
        try exp.verifyNotExpired()
    }
}

// MARK: - Protocol

protocol SupabaseAuthVerifying: Sendable {
    func verifiedUserId(from jwt: String) async throws -> UUID
}

// MARK: - JWKS verifier (production)

final class SupabaseJWKSVerifier: SupabaseAuthVerifying, @unchecked Sendable {
    private let keys: JWTKeyCollection
    private let expectedIssuer: String
    private let logger: Logger

    init(keys: JWTKeyCollection, expectedIssuer: String, logger: Logger) {
        self.keys = keys
        self.expectedIssuer = expectedIssuer
        self.logger = logger
    }

    static func load(supabaseURL: URL, logger: Logger, client: any Client) async throws -> SupabaseJWKSVerifier {
        let jwksURL = supabaseURL
            .appendingPathComponent("auth/v1/.well-known/jwks.json")
        let response = try await client.get(URI(string: jwksURL.absoluteString))
        guard response.status == .ok, var body = response.body else {
            throw Abort(.internalServerError, reason: "Failed to fetch Supabase JWKS (status=\(response.status))")
        }
        guard let jwksJSON = body.readString(length: body.readableBytes) else {
            throw Abort(.internalServerError, reason: "Supabase JWKS response was empty")
        }
        logger.info("✅ Supabase JWKS loaded for JWT verification")
        return try await build(jwksJSON: jwksJSON, supabaseURL: supabaseURL)
    }

    /// Synchronous JWKS load for `configure()` — uses URLSession, safe for startup.
    static func loadBlocking(supabaseURL: URL, logger: Logger) throws -> SupabaseJWKSVerifier {
        let jwksURL = supabaseURL
            .appendingPathComponent("auth/v1/.well-known/jwks.json")
        let sem = DispatchSemaphore(value: 0)
        var jwksJSON: String?
        var fetchError: (any Error)?

        URLSession.shared.dataTask(with: jwksURL) { data, _, error in
            defer { sem.signal() }
            if let error {
                fetchError = error
                return
            }
            guard let data, let json = String(data: data, encoding: .utf8) else {
                fetchError = Abort(.internalServerError, reason: "Supabase JWKS response was empty")
                return
            }
            jwksJSON = json
        }.resume()
        sem.wait()

        if let fetchError { throw fetchError }
        guard let jwksJSON else {
            throw Abort(.internalServerError, reason: "Failed to fetch Supabase JWKS")
        }

        let keySem = DispatchSemaphore(value: 0)
        final class LoadBox: @unchecked Sendable {
            var verifier: SupabaseJWKSVerifier?
            var error: (any Error)?
        }
        let box = LoadBox()

        Task {
            do {
                box.verifier = try await build(jwksJSON: jwksJSON, supabaseURL: supabaseURL)
            } catch {
                box.error = error
            }
            keySem.signal()
        }
        keySem.wait()

        if let error = box.error { throw error }
        guard let verifier = box.verifier else {
            throw Abort(.internalServerError, reason: "Failed to initialize Supabase JWKS verifier")
        }
        logger.info("✅ Supabase JWKS loaded for JWT verification")
        return verifier
    }

    private static func build(jwksJSON: String, supabaseURL: URL) async throws -> SupabaseJWKSVerifier {
        let keys = JWTKeyCollection()
        try await keys.add(jwksJSON: jwksJSON)
        let issuer = supabaseURL.appendingPathComponent("auth/v1").absoluteString
        return SupabaseJWKSVerifier(
            keys: keys,
            expectedIssuer: issuer,
            logger: Logger(label: "supabase.jwt")
        )
    }

    func verifiedUserId(from jwt: String) async throws -> UUID {
        let payload = try await keys.verify(jwt, as: SupabaseAccessTokenPayload.self)

        if let issuer = payload.iss?.value, issuer != expectedIssuer {
            logger.warning("🚫 JWT issuer mismatch")
            throw Abort(.unauthorized, reason: "Invalid token issuer")
        }

        guard let uuid = UUID(uuidString: payload.sub.value) else {
            throw Abort(.unauthorized, reason: "JWT sub is not a valid UUID")
        }
        return uuid
    }
}

// MARK: - API fallback verifier (testing / JWKS unavailable)

final class SupabaseAPIJWTVerifier: SupabaseAuthVerifying, @unchecked Sendable {
    private let supabaseURL: URL
    private let client: any Client
    private let logger: Logger

    init(supabaseURL: URL, client: any Client, logger: Logger) {
        self.supabaseURL = supabaseURL
        self.client = client
        self.logger = logger
    }

    func verifiedUserId(from jwt: String) async throws -> UUID {
        let userURL = supabaseURL.appendingPathComponent("auth/v1/user")
        let response = try await client.get(URI(string: userURL.absoluteString)) { req in
            req.headers.bearerAuthorization = .init(token: jwt)
        }
        guard response.status == .ok else {
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }
        struct SupabaseUser: Decodable { let id: String }
        let user = try response.content.decode(SupabaseUser.self)
        guard let uuid = UUID(uuidString: user.id) else {
            throw Abort(.unauthorized, reason: "Supabase user id is not a valid UUID")
        }
        return uuid
    }
}

// MARK: - Application storage

struct SupabaseJWTVerifierStorageKey: StorageKey {
    typealias Value = any SupabaseAuthVerifying
}

extension Application {
    var supabaseJWTVerifier: any SupabaseAuthVerifying {
        get {
            guard let verifier = storage[SupabaseJWTVerifierStorageKey.self] else {
                fatalError("SupabaseJWTVerifier not configured. Call app.configureSupabaseJWTVerifier() in configure.swift.")
            }
            return verifier
        }
        set { storage[SupabaseJWTVerifierStorageKey.self] = newValue }
    }

    func configureSupabaseJWTVerifier() throws {
        let supabaseURLString = Environment.get("SUPABASE_URL") ?? "https://geznczcokbgybsseipjg.supabase.co"
        guard let supabaseURL = URL(string: supabaseURLString) else {
            logger.critical("❌ SUPABASE_URL is not a valid URL: \(supabaseURLString)")
            throw Abort(.internalServerError)
        }

        do {
            let verifier = try SupabaseJWKSVerifier.loadBlocking(supabaseURL: supabaseURL, logger: logger)
            storage[SupabaseJWTVerifierStorageKey.self] = verifier
        } catch {
            if environment == .production {
                logger.critical("❌ Failed to load Supabase JWKS in production: \(error)")
                throw error
            }
            logger.warning("⚠️ JWKS load failed — falling back to Supabase API JWT verification: \(error)")
            storage[SupabaseJWTVerifierStorageKey.self] = SupabaseAPIJWTVerifier(
                supabaseURL: supabaseURL,
                client: client,
                logger: logger
            )
        }
    }
}

// MARK: - Request helper

extension Request {
    func verifiedSupabaseUserId() async throws -> UUID {
        guard let bearer = headers.bearerAuthorization?.token else {
            throw Abort(.unauthorized, reason: "Bearer token required")
        }
        return try await application.supabaseJWTVerifier.verifiedUserId(from: bearer)
    }

    /// Returns the verified user ID when a valid JWT is present; nil for anonymous requests.
    func optionalVerifiedSupabaseUserId() async -> UUID? {
        guard let bearer = headers.bearerAuthorization?.token else { return nil }
        return try? await application.supabaseJWTVerifier.verifiedUserId(from: bearer)
    }
}
