import Vapor
import Fluent


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
    try app.register(collection: VideoController())
    
    // MARK: - 🔐 Authenticated Action: Delete Supabase User
    // Define request body struct at the top of routes.swift
    struct DeleteUserRequest: Content {
        let userId: String
    }
    
    app.post("delete-user") { req async throws -> Response in
        guard let bearer = req.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing Bearer token")
        }
        
        // Decode userId from request body (frontend sends it)
        let deleteRequest = try req.content.decode(DeleteUserRequest.self)
        
        app.logger.info("Processing delete-user request for userId: \(deleteRequest.userId)")
        
        // Attempt user deletion
        let deleted = try await SupabaseAPI.deleteUser(id: deleteRequest.userId, app: app)
        if deleted {
            app.logger.info("User \(deleteRequest.userId) deleted successfully")
            return Response(status: .ok, body: .init(string: "User deleted"))
        } else {
            app.logger.warning("Failed to delete user \(deleteRequest.userId)")
            throw Abort(.internalServerError, reason: "Failed to delete user")
        }
    }
}
