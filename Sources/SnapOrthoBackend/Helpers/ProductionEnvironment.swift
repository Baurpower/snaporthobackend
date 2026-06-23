import Vapor

enum ProductionEnvironment {
    /// Returns the env var value, or throws in production when missing/empty.
    static func required(_ name: String, in app: Application) throws -> String {
        if let value = Environment.get(name), !value.isEmpty {
            return value
        }
        if app.environment == .production {
            app.logger.critical("❌ \(name) is required in production")
            throw Abort(.internalServerError)
        }
        return ""
    }

    /// Returns the env var value, using `defaultValue` only outside production.
    static func value(_ name: String, default defaultValue: String, in app: Application) throws -> String {
        if let value = Environment.get(name), !value.isEmpty {
            return value
        }
        if app.environment == .production {
            app.logger.critical("❌ \(name) is required in production")
            throw Abort(.internalServerError)
        }
        return defaultValue
    }
}