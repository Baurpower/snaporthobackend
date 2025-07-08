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
    tlsConfig.certificateVerification = .none   // ⚠️ Use .fullVerification in production

    var postgresConfig = PostgresConfiguration(
        hostname: host,
        port: 5432,
        username: user,
        password: pass,
        database: name
    )
    postgresConfig.tlsConfiguration = tlsConfig

    // ─────────────  Register DB  ─────────────
    app.databases.use(
        .postgres(configuration: postgresConfig, maxConnectionsPerEventLoop: 4, connectionPoolTimeout: .seconds(20)),
        as: .psql
    )

    // ─────────────  Migrations  ─────────────
    app.migrations.add(CreateTodo())
    app.migrations.add(CreateDevice())
    app.migrations.add(CreateCasePrepLog())


    // ✅ Run migrations
    try app.autoMigrate().wait()

    // ─────────────  Supabase Key  ─────────────
    guard let supaKey = Environment.get("SUPABASE_SERVICE_ROLE_KEY") else {
        throw Abort(.internalServerError)
    }
    app.storage[SupabaseServiceKeyStorageKey.self] = supaKey

    // ─────────────  APNs CONFIG  ─────────────
    let apnsConfig = try APNSClientConfiguration(
        authenticationMethod: .jwt(
            privateKey: try .loadFrom(string: String(contentsOfFile: "/etc/apns/AuthKey_2V7UF5DPS4.p8")),
            keyIdentifier: "2V7UF5DPS4",
            teamIdentifier: "MLMGMULY2P"
        ),
        environment: .production
    )

    app.apns.containers.use(
        apnsConfig,
        eventLoopGroupProvider: .shared(app.eventLoopGroup),
        responseDecoder: JSONDecoder(),
        requestEncoder: JSONEncoder(),
        as: .default
    )

    // ─────────────  CORS  ─────────────
    let cors = CORSMiddleware(
        configuration: .init(
            allowedOrigin: .originBased,
            allowedMethods: [.GET, .POST, .OPTIONS],
            allowedHeaders: [.accept, .authorization, .contentType, .origin]
        )
    )
    app.middleware.use(cors)

    // ─────────────  ROUTES  ─────────────
    try routes(app)
}
