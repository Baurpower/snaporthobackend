//
//  SupabaseClient.swift
//  SnapOrthoBackend
//
//  Created by Alex Baur on 6/8/25.
//


import Vapor

struct SupabaseClient {
    let httpClient: Client
    let logger: Logger

    let supabaseURL = "https://geznczcokbgybsseipjg.supabase.co"
    let supabaseServiceRoleKey = Environment.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""

    // STEP 2: Verify OTP token
    func verifyOtp(type: String, tokenHash: String) -> EventLoopFuture<VerifyOtpResponse> {
        let body = VerifyOtpRequest(type: type, token: tokenHash)

        return httpClient.post(URI(string: "\(supabaseURL)/auth/v1/verify")) { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: supabaseServiceRoleKey)
            try req.content.encode(body)
        }.flatMapThrowing { res in
            guard res.status == .ok else {
                throw Abort(.badRequest, reason: "Failed to verify OTP: \(res.status)")
            }
            return try res.content.decode(VerifyOtpResponse.self)
        }
    }

    // STEP 3: Update password
    func updatePassword(newPassword: String) -> EventLoopFuture<Void> {
        let body = UpdateUserRequest(password: newPassword)

        return httpClient.put(URI(string: "\(supabaseURL)/auth/v1/user")) { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: supabaseServiceRoleKey)
            try req.content.encode(body)
        }.flatMapThrowing { res in
            guard res.status == .ok else {
                throw Abort(.badRequest, reason: "Failed to update password: \(res.status)")
            }
        }
    }
}

// MARK: - Models

struct VerifyOtpRequest: Content {
    let type: String
    let token: String
}

struct VerifyOtpResponse: Content {
    let session: SupabaseSession
    let user: SupabaseUser
}

struct SupabaseSession: Content {
    let access_token: String
    let refresh_token: String
}

struct SupabaseUser: Content {
    let id: String
    let email: String?
}

struct UpdateUserRequest: Content {
    let password: String
}
