import Fluent
import Vapor

func routes(_ app: Application) throws {
    // MARK: - 🔓 Public Routes

    app.get { req async in
        "It works!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    try app.register(collection: TodoController())

    // MARK: - 🔐 Protected Supabase-authenticated Routes

    let protected = app.grouped(SupabaseJWTMiddleware())

    protected.get("video-access", ":id") { req -> Response in
        let videoID = req.parameters.get("id") ?? ""

        struct VideoResponse: Content {
            let id: String
            let signedUrl: String
        }

        let signedUrl = "https://example.com/videos/\(videoID).mp4?token=secure"

        return try Response(
            status: .ok,
            body: .init(data: JSONEncoder().encode(VideoResponse(id: videoID, signedUrl: signedUrl)))
        )
    }

    protected.post("delete-user") { req async throws -> Response in
        guard let bearer = req.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing Bearer token")
        }

        // Get user info using the access token
        let userResponse = try await SupabaseAPI.getUser(from: bearer.token, app: app)
        guard let userId = userResponse?.id else {
            throw Abort(.unauthorized, reason: "Could not authenticate user")
        }

        // Delete user by ID using Admin API
        let deleted = try await SupabaseAPI.deleteUser(id: userId, app: app)
        if deleted {
            return Response(status: .ok, body: .init(string: "User deleted"))
        } else {
            throw Abort(.internalServerError, reason: "Failed to delete user")
        }
    }
}
