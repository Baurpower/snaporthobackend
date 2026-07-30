import Vapor
import Fluent
import FluentPostgresDriver
import NIOSSL
import NIOCore
import APNS
import VaporAPNS
import APNSCore
import Crypto

public func configure(_ app: Application) throws {
    app.http.server.configuration.hostname = "0.0.0.0"
    app.logger.logLevel = .info

    var rdsConfigured = false
    var legacyPostgresConfig: PostgresConfiguration?

    // ─────────────  Amazon RDS (optional legacy fallback)  ─────────────
    if
        let host = Environment.get("DATABASE_HOST"),
        let user = Environment.get("DATABASE_USERNAME"),
        let pass = Environment.get("DATABASE_PASSWORD"),
        let name = Environment.get("DATABASE_NAME")
    {
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
        legacyPostgresConfig = postgresConfig

        app.databases.use(
            .postgres(configuration: postgresConfig, maxConnectionsPerEventLoop: 4, connectionPoolTimeout: .seconds(20)),
            as: .psql
        )
        rdsConfigured = true
    } else {
        app.logger.warning("⚠️ Amazon RDS env vars not set — legacy RDS fallback disabled")
    }

    var supabaseConfigured = false

    // ─────────────  Supabase Postgres (notification + analytics tables)  ─────────────
    if let supabaseURL = Environment.get("SUPABASE_DATABASE_URL") {
        do {
            var supabaseTLS = TLSConfiguration.makeClientConfiguration()
            supabaseTLS.certificateVerification = .none

            guard var supabaseConfig = PostgresConfiguration(url: supabaseURL) else {
                throw Abort(.internalServerError, reason: "Invalid SUPABASE_DATABASE_URL")
            }
            supabaseConfig.tlsConfiguration = supabaseTLS

            app.databases.use(
                .postgres(
                    configuration: supabaseConfig,
                    maxConnectionsPerEventLoop: 2,
                    connectionPoolTimeout: .seconds(20)
                ),
                as: .notifications
            )

            supabaseConfigured = true
            app.logger.info("✅ Supabase notifications DB configured")
        } catch {
            app.logger.error("❌ Failed to configure Supabase DB: \(error)")
            if app.environment == .production {
                throw error
            }
        }
    } else if app.environment == .testing, let legacyPostgresConfig {
        // Local/CI testing without a separate Supabase project:
        // reuse the legacy Postgres connection so notification migrations/models still work.
        app.databases.use(
            .postgres(configuration: legacyPostgresConfig, maxConnectionsPerEventLoop: 2, connectionPoolTimeout: .seconds(20)),
            as: .notifications
        )
        supabaseConfigured = true
        app.logger.warning("⚠️ SUPABASE_DATABASE_URL not set — using legacy Postgres for .notifications in test mode")
    } else if app.environment == .production {
        app.logger.critical("❌ SUPABASE_DATABASE_URL is required in production")
        throw Abort(.internalServerError)
    } else {
        app.logger.warning("⚠️ SUPABASE_DATABASE_URL not set — Supabase features disabled in development")
    }

    let rdsMode: RDSMode = rdsConfigured ? .fallback : .disabled
    app.storage[DatastoreConfigStorageKey.self] = DatastoreConfig(
        supabaseConfigured: supabaseConfigured,
        rdsConfigured: rdsConfigured,
        rdsMode: rdsMode
    )

    app.logger.info(
        """
        [datastore] startup \
        supabase_configured=\(supabaseConfigured ? "yes" : "no") \
        rds_configured=\(rdsConfigured ? "yes" : "no") \
        rds_mode=\(rdsMode.rawValue)
        """
    )

    // ─────────────  Amazon RDS Migrations (legacy fallback only)  ─────────────
    if rdsConfigured {
        app.migrations.add(CreateDevice(), to: .psql)
        app.migrations.add(CreateCasePrepLog(), to: .psql)
    }

    // ─────────────  Supabase Notification Migrations  ─────────────
    if supabaseConfigured {
        app.migrations.add(CreateUserDeviceTokens(), to: .notifications)
        app.migrations.add(CreateNotificationPreferences(), to: .notifications)
        app.migrations.add(CreateNotificationDeliveryAttempts(), to: .notifications)
        app.migrations.add(CreateNotificationCandidates(), to: .notifications)
        app.migrations.add(CreateNotificationTemplates(), to: .notifications)
        app.migrations.add(CreateNotificationInteractions(), to: .notifications)
        app.migrations.add(CreateNotificationUserState(), to: .notifications)
        app.migrations.add(AddNotificationTypeToCandidates(), to: .notifications)
        app.migrations.add(AddGranularHoldoutColumns(), to: .notifications)
    }

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
    //
    // Credentials are shared across sandbox + production. Endpoint selection is
    // explicit via separate named VaporAPNS containers (.production / .development).
    // Device rows store "sandbox" | "production"; send paths pick the matching client.
    //
    // APNS_ENVIRONMENT remains the default/primary environment for ops defaults.
    // Never print the private key or raw device tokens.

    let apnsKeyId    = try ProductionEnvironment.value("APNS_KEY_ID",    default: "2V7UF5DPS4", in: app)
    let apnsTeamId   = try ProductionEnvironment.value("APNS_TEAM_ID",   default: "MLMGMULY2P", in: app)
    let apnsEnvStr   = try ProductionEnvironment.value("APNS_ENVIRONMENT", default: "production", in: app)
    let apnsBundleId = try ProductionEnvironment.value("APNS_BUNDLE_ID", default: "com.alexbaur.Snap-Ortho", in: app)

    guard let defaultDeviceEnv = APNSDeviceEnvironment.parse(apnsEnvStr) else {
        app.logger.critical("❌ APNS_ENVIRONMENT must be 'production' or 'sandbox' (got non-empty invalid value)")
        throw Abort(.internalServerError)
    }
    if app.environment == .production && apnsBundleId != "com.alexbaur.Snap-Ortho" {
        app.logger.critical("❌ APNS_BUNDLE_ID does not match the production iOS app")
        throw Abort(.internalServerError)
    }

    var configuredEnvironments: Set<String> = []

    do {
        let keyContent = try APNSKeyMaterial.loadPEM(from: app)
        // P256.Signing.PrivateKey.loadFrom is provided by APNSwift
        let privateKey = try P256.Signing.PrivateKey.loadFrom(string: keyContent)

        // Production client
        let productionConfig = APNSClientConfiguration(
            authenticationMethod: .jwt(
                privateKey: privateKey,
                keyIdentifier: apnsKeyId,
                teamIdentifier: apnsTeamId
            ),
            environment: .production
        )
        app.apns.containers.use(
            productionConfig,
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder(),
            as: .production,
            isDefault: defaultDeviceEnv == .production
        )
        configuredEnvironments.insert(APNSDeviceEnvironment.production.rawValue)

        // Sandbox / development client (same signing credentials, different host)
        let sandboxConfig = APNSClientConfiguration(
            authenticationMethod: .jwt(
                privateKey: privateKey,
                keyIdentifier: apnsKeyId,
                teamIdentifier: apnsTeamId
            ),
            environment: .development
        )
        app.apns.containers.use(
            sandboxConfig,
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder(),
            as: .development,
            isDefault: defaultDeviceEnv == .sandbox
        )
        configuredEnvironments.insert(APNSDeviceEnvironment.sandbox.rawValue)

        // Keep .default as an alias of the primary environment for any legacy call sites
        // that still use application.apns.client without an explicit container ID.
        let defaultConfig = defaultDeviceEnv == .sandbox ? sandboxConfig : productionConfig
        app.apns.containers.use(
            defaultConfig,
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder(),
            as: .default,
            isDefault: false
        )

        app.logger.info(
            "✅ APNS configured default=\(defaultDeviceEnv.rawValue) configured=[\(configuredEnvironments.sorted().joined(separator: ","))] topic=\(apnsBundleId) team_id_set=yes key_id_set=yes"
        )
    } catch {
        if app.environment == .production {
            app.logger.critical("❌ Failed to configure APNS: \(error)")
            throw error
        } else {
            // Dev/test may boot without a key; mark default env as "configured" for mock-based tests.
            configuredEnvironments = [defaultDeviceEnv.rawValue, APNSDeviceEnvironment.sandbox.rawValue, APNSDeviceEnvironment.production.rawValue]
            app.logger.warning("⚠️ APNS clients not fully configured (key missing/invalid) — live pushes will fail: \(error)")
        }
    }

    app.storage[APNSRuntimeConfigStorageKey.self] = APNSRuntimeConfig(
        bundleId: apnsBundleId,
        defaultEnvironment: defaultDeviceEnv.rawValue,
        configuredEnvironments: configuredEnvironments
    )

    // ─────────────  Notification Service  ─────────────
    app.configureNotificationService()

    // ─────────────  Custom Commands  ─────────────
    app.asyncCommands.use(BackfillNotificationTokensCommand(), as: BackfillNotificationTokensCommand.name)
    app.asyncCommands.use(SeedNotificationTemplatesCommand(), as: SeedNotificationTemplatesCommand.name)
    app.asyncCommands.use(GenerateLearningCandidatesCommand(), as: GenerateLearningCandidatesCommand.name)
    app.asyncCommands.use(ProcessScheduledNotificationsCommand(), as: ProcessScheduledNotificationsCommand.name)

    let notificationAutomation = NotificationAutomationConfig.load()
    app.storage[NotificationAutomationConfigStorageKey.self] = notificationAutomation
    app.logger.info(
        """
        [notification-automation] enabled=\(notificationAutomation.enabled) \
        dry_run=\(notificationAutomation.dryRun) \
        interval_minutes=\(notificationAutomation.interval.nanoseconds / 60_000_000_000) \
        generation_limit=\(notificationAutomation.generationLimit) \
        dispatch_limit=\(notificationAutomation.dispatchLimit)
        """
    )
    app.lifecycle.use(CandidateSchedulerJob(interval: notificationAutomation.interval))

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
