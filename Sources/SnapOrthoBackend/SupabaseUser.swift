import Vapor

struct SupabaseUser: Content {
    let id: String
}

struct SupabaseGetUserResponse: Content {
    let user: SupabaseUser
}

enum SupabaseAPI {
    static let supabaseURL = "https://hzxdyyjjbiqwdzwhjqoz.supabase.co"
    static let serviceRoleKey = Environment.get("SUPABASE_SERVICE_ROLE_KEY")!

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
