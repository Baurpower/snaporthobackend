import NIOSSL
import Fluent
import FluentPostgresDriver
import Vapor

public func configure(_ app: Application) async throws {


    // Add migrations (e.g., CreateTodo)
    app.migrations.add(CreateTodo())

    // ✅ Register routes
    try routes(app)
}
