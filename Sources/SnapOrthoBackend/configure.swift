import Vapor
import Fluent
import FluentPostgresDriver   // ✅ Required for .postgres & DatabaseID.psql
import NIOSSL                 // ✅ TLSConfiguration
import NIOCore                // ✅ TimeAmount
import APNS
import VaporAPNS
import APNSCore

public func configure(_ app: Application) throws {
    app.http.server.configuration.hostname = "0.0.0.0"

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

    // ───── APNs CONFIG (VaporAPNS) ─────
//    let privateKeyString = try String(contentsOfFile: "/etc/apns/AuthKey_2V7UF5DPS4.p8", encoding: .utf8)
//
//    
//    let apnsConfig = try APNSClientConfiguration(
//        authenticationMethod: .jwt(
//            privateKey: try .loadFrom(string: "/etc/apns/AuthKey_2V7UF5DPS4.p8"),
//            keyIdentifier: "2V7UF5DPS4",
//            teamIdentifier: "MLMGMULY2P"
//        ),
//        environment: .production
//    )
//
//
//    // Register the configuration with Vapor’s APNS container
//    app.apns.containers.use(
//        apnsConfig,
//        eventLoopGroupProvider: .shared(app.eventLoopGroup),
//        responseDecoder: JSONDecoder(),
//        requestEncoder: JSONEncoder(),
//        as: .default
//    )
//    // ───── End APN

        try routes(app)
    }
