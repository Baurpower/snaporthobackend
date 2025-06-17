import NIOSSL
import Fluent
import FluentPostgresDriver
import Vapor

public func configure(_ app: Application) async throws {
   

    // MARK: - 📦 Database (via .env)
    guard
        let dbHost = Environment.get("DATABASE_HOST"),
        let dbUsername = Environment.get("DATABASE_USERNAME"),
        let dbPassword = Environment.get("DATABASE_PASSWORD"),
        let dbName = Environment.get("DATABASE_NAME")
    else {
        app.logger.critical("❌ Missing one or more database environment variables")
        throw Abort(.internalServerError, reason: "Missing database config")
    }

    app.databases.use(.postgres(
        hostname: dbHost,
        port: 5432,
        username: dbUsername,
        password: dbPassword,
        database: dbName
    ), as: .psql)

    // MARK: - 📚 Migrations
    app.migrations.add(CreateTodo())
    app.migrations.add(CreateDevice())

    // MARK: - 🔐 Supabase Service Role Key
    if let supabaseServiceKey = Environment.get("SUPABASE_SERVICE_ROLE_KEY") {
        app.storage[SupabaseServiceKeyStorageKey.self] = supabaseServiceKey
        app.logger.info("✅ Supabase service role key loaded")
    } else {
        app.logger.critical("❌ Missing SUPABASE_SERVICE_ROLE_KEY in environment")
        throw Abort(.internalServerError, reason: "Missing Supabase service role key")
    }

    // MARK: - 🌐 Routes
    try routes(app)
}
