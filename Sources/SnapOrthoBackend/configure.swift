import Vapor
import Fluent
import FluentPostgresDriver   // ✅ Required for .postgres & DatabaseID.psql
import NIOSSL                 // ✅ TLSConfiguration
import NIOCore                // ✅ TimeAmount

public func configure(_ app: Application) throws {

    // ─────────────  ENV  ─────────────
    guard
        let host = Environment.get("DATABASE_HOST"),
        let user = Environment.get("DATABASE_USERNAME"),
        let pass = Environment.get("DATABASE_PASSWORD"),
        let name = Environment.get("DATABASE_NAME")
    else {
        app.logger.critical("❌ Missing DB environment variables")
        throw Abort(.internalServerError)
    }

    // ─────────────  TLS  ─────────────
    var tlsConfig = TLSConfiguration.makeClientConfiguration()
    tlsConfig.certificateVerification = .none   // ⚠️ Disable only in dev/testing

    // 👇 FluentPostgresDriver config with TLS
    var postgresConfig = PostgresConfiguration(
        hostname: host,
        port: 5432,
        username: user,
        password: pass,
        database: name
    )
    postgresConfig.tlsConfiguration = tlsConfig

    // ─────────────  Register DB with pooling  ─────────────
    app.databases.use(.postgres(
        configuration: postgresConfig,
        maxConnectionsPerEventLoop: 4,
        connectionPoolTimeout: TimeAmount.seconds(20)
    ), as: .psql)

    // ─────────────  Migrations  ─────────────
    app.migrations.add(CreateTodo())
    app.migrations.add(CreateDevice())

    // ─────────────  Supabase Key  ─────────────
    guard let supaKey = Environment.get("SUPABASE_SERVICE_ROLE_KEY") else {
        throw Abort(.internalServerError)
    }
    app.storage[SupabaseServiceKeyStorageKey.self] = supaKey

    // ─────────────  Routes  ─────────────
    try routes(app)
}
