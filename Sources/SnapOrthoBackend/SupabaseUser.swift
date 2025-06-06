//
//  SupabaseUser.swift
//  SnapOrthoBackend
//
//  Created by Alex Baur on 6/5/25.
//


import Vapor

struct SupabaseUser: Content {
    let id: String
}

struct SupabaseGetUserResponse: Content {
    let user: SupabaseUser
}

enum SupabaseAPI {
    static let supabaseURL = "https://hzxdyyjjbiqwdzwhjqoz.supabase.co"
    static let serviceRoleKey = Environment.get("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6eGR5eWpqYmlxd2R6d2hqcW96Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDkwNTgwMjUsImV4cCI6MjA2NDYzNDAyNX0.93xTu4zhoFXbzhTHHfGiMNlo8m9akPCi2n0QFNfFtuc")!

    static func getUser(from accessToken: String, app: Application) async throws -> SupabaseUser? {
        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(accessToken)")

        let res = try await app.client.get("\(supabaseURL)/auth/v1/user", headers: headers)
        if res.status == .ok {
            let decoded = try res.content.decode(SupabaseGetUserResponse.self)
            return decoded.user
        } else {
            app.logger.warning("Failed to verify user: \(res.status)")
            return nil
        }
    }

    static func deleteUser(id: String, app: Application) async throws -> Bool {
        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(serviceRoleKey)")
        headers.add(name: .contentType, value: "application/json")

        let res = try await app.client.delete("\(supabaseURL)/auth/v1/admin/users/\(id)", headers: headers)
        return res.status == .noContent || res.status == .ok
    }
}
