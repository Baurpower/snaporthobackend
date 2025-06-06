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

    // Register VideoController for signed URL access
    try app.register(collection: VideoController(app: app))

    // MARK: - 🔐 Authenticated Action: Delete Supabase User

    app.post("delete-user") { req async throws -> Response in
        guard let bearer = req.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing Bearer token")
        }

        // Fetch user info using access token
        let userResponse = try await SupabaseAPI.getUser(from: bearer.token, app: app)
        guard let userId = userResponse?.id else {
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }

        // Attempt user deletion
        let deleted = try await SupabaseAPI.deleteUser(id: userId, app: app)
        if deleted {
            return Response(status: .ok, body: .init(string: "User deleted"))
        } else {
            throw Abort(.internalServerError, reason: "Failed to delete user")
        }
    }
}
