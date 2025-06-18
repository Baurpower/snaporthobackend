import NIOSSL
import Fluent
import FluentPostgresDriver
import Vapor

public func configure(_ app: Application) async throws {
    
    // MARK: - 📦 Database via Environment
    guard
        let dbHost     = Environment.get("DATABASE_HOST"),
        let dbUsername = Environment.get("DATABASE_USERNAME"),
        let dbPassword = Environment.get("DATABASE_PASSWORD"),
        let dbName     = Environment.get("DATABASE_NAME")
    else {
        app.logger.critical("❌ Missing one or more database environment variables")
        throw Abort(.internalServerError, reason: "Missing database config")
    }

    // ✅ NEW PostgresConfiguration (Vapor 4+)
    let postgresConfig = PostgresConfiguration(
        url: "postgres://\(dbUsername):\(dbPassword)@\(dbHost):5432/\(dbName)"
    )!

    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)

    // MARK: - 📚 Migrations
    app.migrations.add(CreateTodo())
    app.migrations.add(CreateDevice())

    // MARK: - 🔐 Supabase Service Role Key
    guard let supaKey = Environment.get("SUPABASE_SERVICE_ROLE_KEY") else {
        app.logger.critical("❌ Missing SUPABASE_SERVICE_ROLE_KEY in environment")
        throw Abort(.internalServerError, reason: "Missing Supabase service role key")
    }

    app.storage[SupabaseServiceKeyStorageKey.self] = supaKey
    app.logger.info("✅ Supabase service role key loaded")

    // MARK: - 🌐 Routes
    try routes(app)
}
