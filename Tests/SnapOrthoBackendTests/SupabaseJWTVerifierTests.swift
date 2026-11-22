@testable import SnapOrthoBackend
import Foundation
import Logging
import Testing
import Vapor

private struct StubVerifier: SupabaseAuthVerifying {
    let result: Result<UUID, Abort>
    let calls: CallCounter

    func verifiedUserId(from jwt: String) async throws -> UUID {
        await calls.increment()
        return try result.get()
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Suite("Supabase JWT verification")
struct SupabaseJWTVerifierTests {
    private let logger = Logger(label: "test.supabase.jwt")

    @Test("Empty JWKS (legacy HS256 project) reports zero keys")
    func emptyJWKSHasNoKeys() {
        #expect(SupabaseJWKSVerifier.publishedKeyCount(in: #"{"keys":[]}"#) == 0)
        #expect(SupabaseJWKSVerifier.publishedKeyCount(in: "not json") == 0)
        #expect(SupabaseJWKSVerifier.publishedKeyCount(in: #"{}"#) == 0)
    }

    @Test("Published JWKS keys are counted")
    func publishedKeysAreCounted() {
        let jwks = #"{"keys":[{"kty":"EC","kid":"a","alg":"ES256"},{"kty":"EC","kid":"b","alg":"ES256"}]}"#
        #expect(SupabaseJWKSVerifier.publishedKeyCount(in: jwks) == 2)
    }

    @Test("Without a local verifier, Supabase Auth decides")
    func remoteOnlyWhenNoLocal() async throws {
        let user = UUID()
        let remoteCalls = CallCounter()
        let verifier = SupabaseCompositeJWTVerifier(
            local: nil,
            remote: StubVerifier(result: .success(user), calls: remoteCalls),
            logger: logger
        )

        #expect(try await verifier.verifiedUserId(from: "token") == user)
        #expect(await remoteCalls.count == 1)
    }

    @Test("A token the JWKS cannot verify falls back to Supabase Auth")
    func fallsBackWhenLocalFails() async throws {
        let user = UUID()
        let localCalls = CallCounter()
        let remoteCalls = CallCounter()
        let verifier = SupabaseCompositeJWTVerifier(
            local: StubVerifier(result: .failure(Abort(.unauthorized)), calls: localCalls),
            remote: StubVerifier(result: .success(user), calls: remoteCalls),
            logger: logger
        )

        #expect(try await verifier.verifiedUserId(from: "hs256-token") == user)
        #expect(await localCalls.count == 1)
        #expect(await remoteCalls.count == 1)
    }

    @Test("A token the JWKS verifies never calls Supabase Auth")
    func localSuccessSkipsRemote() async throws {
        let user = UUID()
        let remoteCalls = CallCounter()
        let verifier = SupabaseCompositeJWTVerifier(
            local: StubVerifier(result: .success(user), calls: CallCounter()),
            remote: StubVerifier(result: .failure(Abort(.unauthorized)), calls: remoteCalls),
            logger: logger
        )

        #expect(try await verifier.verifiedUserId(from: "es256-token") == user)
        #expect(await remoteCalls.count == 0)
    }

    @Test("A token both paths reject is rejected")
    func rejectsWhenBothFail() async {
        let verifier = SupabaseCompositeJWTVerifier(
            local: StubVerifier(result: .failure(Abort(.unauthorized)), calls: CallCounter()),
            remote: StubVerifier(result: .failure(Abort(.unauthorized)), calls: CallCounter()),
            logger: logger
        )

        await #expect(throws: (any Error).self) {
            _ = try await verifier.verifiedUserId(from: "forged")
        }
    }
}
