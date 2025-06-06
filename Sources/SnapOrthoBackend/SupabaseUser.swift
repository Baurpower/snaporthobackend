import Vapor

struct SupabaseUser: Content {
    let id: String
}

enum SupabaseAPI {
    static let supabaseURL = "https://hzxdyyjjbiqwdzwhjqoz.supabase.co"
    static let serviceRoleKey = Environment.get("SUPABASE_SERVICE_ROLE_KEY")!

    static func getUser(from accessToken: String, app: Application) async throws -> SupabaseUser? {
        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(accessToken)")

        app.logger.info("Using access token: \(accessToken)")

        let res = try await app.client.get("\(supabaseURL)/auth/v1/user", headers: headers)
        app.logger.info("Supabase /auth/v1/user response status: \(res.status)")

        if let bodyBuffer = res.body {
            let data = bodyBuffer.getData(at: 0, length: bodyBuffer.readableBytes) ?? Data()
            let bodyString = String(data: data, encoding: .utf8) ?? "empty"
            app.logger.info("Supabase /auth/v1/user response body: \(bodyString)")
        } else {
            app.logger.warning("Failed to read response body from /auth/v1/user")
        }

        if res.status == .ok {
            let decoded = try res.content.decode(SupabaseUser.self)
            app.logger.info("Decoded user id: \(decoded.id)")
            return decoded
        } else {
            app.logger.warning("Failed to verify user: \(res.status)")
            return nil
        }
    }

    static func deleteUser(id: String, app: Application) async throws -> Bool {
        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(serviceRoleKey)")
        headers.add(name: .contentType, value: "application/json")

        app.logger.info("Deleting user with id: \(id)")

        let res = try await app.client.delete("\(supabaseURL)/auth/v1/admin/users/\(id)", headers: headers)
        app.logger.info("Supabase delete user response status: \(res.status)")

        if let bodyBuffer = res.body {
            let data = bodyBuffer.getData(at: 0, length: bodyBuffer.readableBytes) ?? Data()
            let bodyString = String(data: data, encoding: .utf8) ?? "empty"
            app.logger.info("Supabase delete user response body: \(bodyString)")
        }

        return res.status == .noContent || res.status == .ok
    }
}
