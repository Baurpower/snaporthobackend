import Vapor
import Fluent
import FluentPostgresDriver
import NIOSSL
import NIOCore
import APNS
import VaporAPNS
import APNSCore

public func configure(_ app: Application) throws {
    app.http.server.configuration.hostname = "0.0.0.0"
    app.logger.logLevel = .info

    // ─────────────  Amazon RDS (primary / legacy DB)  ─────────────
    guard
        let host = Environment.get("DATABASE_HOST"),
        let user = Environment.get("DATABASE_USERNAME"),
        let pass = Environment.get("DATABASE_PASSWORD"),
        let name = Environment.get("DATABASE_NAME")
    else {
        app.logger.critical("❌ Missing Amazon RDS environment variables (DATABASE_HOST/USERNAME/PASSWORD/NAME)")
        throw Abort(.internalServerError)
    }

    var tlsConfig = TLSConfiguration.makeClientConfiguration()
    tlsConfig.certificateVerification = .none   // ⚠️ Use .fullVerification in production

    var postgresConfig = PostgresConfiguration(
        hostname: host,
        port: 5432,
        username: user,
        password: pass,
        database: name
    )
    postgresConfig.tlsConfiguration = tlsConfig

    app.databases.use(
        .postgres(configuration: postgresConfig, maxConnectionsPerEventLoop: 4, connectionPoolTimeout: .seconds(20)),
        as: .psql
    )

    // ─────────────  Supabase Postgres (notification tables)  ─────────────
    if let supabaseURL = Environment.get("SUPABASE_DATABASE_URL") {
        do {
            try app.databases.use(
                .postgres(url: supabaseURL, maxConnectionsPerEventLoop: 2),
                as: .notifications
            )
            app.logger.info("✅ Supabase notifications DB configured")
        } catch {
            app.logger.error("❌ Failed to configure Supabase DB: \(error)")
            if app.environment == .production {
                throw error
            }
        }
    } else {
        if app.environment == .production {
            app.logger.critical("❌ SUPABASE_DATABASE_URL is required in production")
            throw Abort(.internalServerError)
        } else if app.environment == .testing {
            // In tests: reuse Amazon RDS connection for the .notifications database
            // so Fluent migrations and model queries work without a real Supabase URL.
            app.databases.use(
                .postgres(configuration: postgresConfig, maxConnectionsPerEventLoop: 2, connectionPoolTimeout: .seconds(20)),
                as: .notifications
            )
            app.logger.warning("⚠️ SUPABASE_DATABASE_URL not set — using Amazon RDS for .notifications in test mode")
        } else {
            app.logger.warning("⚠️ SUPABASE_DATABASE_URL not set — Supabase notification features disabled in development")
        }
    }

    // ─────────────  Amazon RDS Migrations  ─────────────
    // Only legacy models target the .psql (Amazon) database.
    // New notification models target .notifications (Supabase).
    app.migrations.add(CreateTodo(), to: .psql)
    app.migrations.add(CreateDevice(), to: .psql)
    app.migrations.add(CreateCasePrepLog(), to: .psql)

    // ─────────────  Supabase Notification Migrations  ─────────────
    app.migrations.add(CreateUserDeviceTokens(), to: .notifications)
    app.migrations.add(CreateNotificationPreferences(), to: .notifications)
    app.migrations.add(CreateNotificationDeliveryAttempts(), to: .notifications)

    try app.autoMigrate().wait()

    // ─────────────  Supabase Service Role Key  ─────────────
    guard let supaKey = Environment.get("SUPABASE_SERVICE_ROLE_KEY") else {
        app.logger.critical("❌ SUPABASE_SERVICE_ROLE_KEY is required")
        throw Abort(.internalServerError)
    }
    app.storage[SupabaseServiceKeyStorageKey.self] = supaKey

    // ─────────────  Admin API Key (required in production)  ─────────────
    _ = try ProductionEnvironment.required("ADMIN_API_KEY", in: app)
    if let adminKey = Environment.get("ADMIN_API_KEY"), !adminKey.isEmpty {
        app.logger.info("✅ ADMIN_API_KEY configured")
    } else {
        app.logger.warning("⚠️ ADMIN_API_KEY not set — admin routes will return 503")
    }

    // ─────────────  Supabase JWT verification (JWKS)  ─────────────
    try app.configureSupabaseJWTVerifier()

    // ─────────────  APNS Configuration  ─────────────
    // Production requires all APNS env vars. Dev/test may use documented defaults.
    let apnsKeyPath  = try ProductionEnvironment.value("APNS_KEY_PATH",  default: "/etc/apns/AuthKey_2V7UF5DPS4.p8", in: app)
    let apnsKeyId    = try ProductionEnvironment.value("APNS_KEY_ID",    default: "2V7UF5DPS4", in: app)
    let apnsTeamId   = try ProductionEnvironment.value("APNS_TEAM_ID",   default: "MLMGMULY2P", in: app)
    let apnsEnvStr   = try ProductionEnvironment.value("APNS_ENVIRONMENT", default: "production", in: app)
    let apnsBundleId = try ProductionEnvironment.value("APNS_BUNDLE_ID", default: "com.alexbaur.Snap-Ortho", in: app)

    guard apnsEnvStr == "production" || apnsEnvStr == "sandbox" else {
        app.logger.critical("❌ APNS_ENVIRONMENT must be 'production' or 'sandbox'")
        throw Abort(.internalServerError)
    }

    let apnsEnvironment: APNSEnvironment = apnsEnvStr == "sandbox" ? .sandbox : .production
    app.storage[APNSRuntimeConfigStorageKey.self] = APNSRuntimeConfig(
        bundleId: apnsBundleId,
        environment: apnsEnvStr
    )

    do {
        let keyContent = try String(contentsOfFile: apnsKeyPath)
        let apnsConfig = try APNSClientConfiguration(
            authenticationMethod: .jwt(
                privateKey: try .loadFrom(string: keyContent),
                keyIdentifier: apnsKeyId,
                teamIdentifier: apnsTeamId
            ),
            environment: apnsEnvironment
        )

        app.apns.containers.use(
            apnsConfig,
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder(),
            as: .default
        )
        app.logger.info("✅ APNS configured (environment=\(apnsEnvStr))")
    } catch {
        if app.environment == .production {
            app.logger.critical("❌ Failed to configure APNS: \(error)")
            throw error
        } else {
            app.logger.warning("⚠️ APNS not configured (key file missing or invalid) — push sends will fail: \(error)")
        }
    }

    // ─────────────  Notification Service  ─────────────
    app.configureNotificationService()

    // ─────────────  Custom Commands  ─────────────
    app.asyncCommands.use(BackfillNotificationTokensCommand(), as: BackfillNotificationTokensCommand.name)

    // ─────────────  CORS  ─────────────
    let cors = CORSMiddleware(configuration: .init(
        allowedOrigin: .originBased,
        allowedMethods: [.GET, .POST, .PUT, .DELETE, .OPTIONS],
        allowedHeaders: [
            .accept,
            .authorization,
            .contentType,
            .origin,
            .xRequestedWith,
            HTTPHeaders.Name("x-debug-client"),
            HTTPHeaders.Name("x-admin-key"),
        ]
    ))
    app.middleware.use(cors)

    // ─────────────  Routes  ─────────────
    try routes(app)
}
