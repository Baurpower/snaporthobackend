import Vapor
import VaporAPNS

// MARK: - Canonical APNs environment strings

/// Canonical storage / API values for APNs environments.
/// These match the CHECK constraint on `user_device_tokens.environment`.
enum APNSDeviceEnvironment: String, Codable, Sendable, CaseIterable {
    case production
    case sandbox

    /// VaporAPNS container ID for this environment.
    /// Note: VaporAPNS names the sandbox container `.development`.
    var containerID: APNSContainers.ID {
        switch self {
        case .production: return .production
        case .sandbox: return .development
        }
    }

    static func parse(_ raw: String?) -> APNSDeviceEnvironment? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept common aliases used by Apple entitlements / docs.
        switch normalized {
        case "production", "prod": return .production
        case "sandbox", "development", "dev": return .sandbox
        default: return nil
        }
    }
}

// MARK: - Runtime configuration

/// Explicit APNs runtime configuration stored on the Application.
/// Credentials may be shared across environments; endpoint selection is always explicit.
struct APNSRuntimeConfig: Sendable {
    let bundleId: String
    /// Value of `APNS_ENVIRONMENT` — used as the default broadcast filter and default container.
    let defaultEnvironment: String
    /// Environments that have a live APNs client container configured.
    let configuredEnvironments: Set<String>

    var supportsSandbox: Bool { configuredEnvironments.contains(APNSDeviceEnvironment.sandbox.rawValue) }
    var supportsProduction: Bool { configuredEnvironments.contains(APNSDeviceEnvironment.production.rawValue) }

    func isConfigured(_ environment: String) -> Bool {
        configuredEnvironments.contains(environment)
    }
}

struct APNSRuntimeConfigStorageKey: StorageKey {
    typealias Value = APNSRuntimeConfig
}

// MARK: - Token presentation helpers

extension UserDeviceToken {
    /// Mask a raw APNs token for API responses / logs: `abcd1234…89ef`
    static func maskedToken(_ rawToken: String) -> String {
        let normalized = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count >= 12 else { return "****" }
        return "\(normalized.prefix(8))…\(normalized.suffix(4))"
    }

    var maskedToken: String { UserDeviceToken.maskedToken(token) }
}

// MARK: - Private key loading

enum APNSKeyMaterial {
    /// Loads the APNs .p8 private key from either:
    /// 1. `APNS_PRIVATE_KEY` — PEM contents (multiline or escaped `\n`)
    /// 2. `APNS_KEY_PATH` — filesystem path to the .p8 file
    ///
    /// Never returns or logs the raw key. Throws a sanitized error on failure.
    static func loadPEM(from app: Application) throws -> String {
        if let inline = Environment.get("APNS_PRIVATE_KEY"), !inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = normalizePEM(inline)
            try validatePEMShape(normalized)
            app.logger.info("✅ APNS private key loaded from APNS_PRIVATE_KEY (inline)")
            return normalized
        }

        let keyPath = try ProductionEnvironment.value(
            "APNS_KEY_PATH",
            default: "/etc/apns/AuthKey_2V7UF5DPS4.p8",
            in: app
        )
        do {
            let content = try String(contentsOfFile: keyPath)
            let normalized = normalizePEM(content)
            try validatePEMShape(normalized)
            app.logger.info("✅ APNS private key loaded from file path (APNS_KEY_PATH)")
            return normalized
        } catch {
            throw Abort(
                .internalServerError,
                reason: "Failed to read APNS private key from APNS_KEY_PATH (file missing or unreadable)"
            )
        }
    }

    /// Accepts real multiline PEM or single-line env values with literal `\n`.
    static func normalizePEM(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Common deployment pattern: store PEM as a single line with escaped newlines
        if value.contains("\\n") && !value.contains("\n") {
            value = value.replacingOccurrences(of: "\\n", with: "\n")
        }
        // Some secrets managers base64-encode the entire PEM
        if !value.contains("BEGIN"), let decoded = Data(base64Encoded: value),
           let asString = String(data: decoded, encoding: .utf8),
           asString.contains("BEGIN") {
            value = asString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    static func validatePEMShape(_ pem: String) throws {
        let hasBegin = pem.contains("BEGIN PRIVATE KEY") || pem.contains("BEGIN EC PRIVATE KEY")
        let hasEnd = pem.contains("END PRIVATE KEY") || pem.contains("END EC PRIVATE KEY")
        guard hasBegin, hasEnd else {
            throw Abort(
                .internalServerError,
                reason: "APNS private key is malformed — expected a PEM block (BEGIN/END PRIVATE KEY). Never log key contents."
            )
        }
    }
}
