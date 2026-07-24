import Vapor
import APNS
import VaporAPNS
import APNSCore

// MARK: - Payload

/// The custom data block merged into every APNS payload alongside the standard `aps` dict.
/// Properties appear at the root level of the APNS JSON body (not nested under any key).
struct SnapOrthoAPNSPayload: Codable, Sendable {
    /// UUID of the corresponding notification_delivery_attempts row.
    let notificationId: String
    let category: String
    /// Fine-grained type within the category, e.g. "caseprep_reminder".
    let type: String
    /// snaportho:// deep link URI. Nil if the notification has no specific destination.
    let deeplink: String?
    /// Arbitrary non-PHI metadata the iOS app may need. Never include patient identifiers.
    let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case notificationId = "notification_id"
        case category
        case type
        case deeplink
        case metadata
    }
}

// MARK: - Send result

struct APNSSendResult: Sendable {
    let apnsId: String?          // APNS-ID from the response header, if present
    let environment: String
    let topic: String
}

// MARK: - Errors

/// Permanent token failures — the registration should be disabled.
enum APNSTokenError: Error, Sendable, Equatable {
    case badDeviceToken
    case deviceTokenNotForTopic
    case unregistered

    var reasonCode: String {
        switch self {
        case .badDeviceToken: return "BadDeviceToken"
        case .deviceTokenNotForTopic: return "DeviceTokenNotForTopic"
        case .unregistered: return "Unregistered"
        }
    }
}

/// Provider / configuration failures — do NOT disable the device token.
enum APNSProviderError: Error, Sendable, Equatable {
    case expiredProviderToken
    case invalidProviderToken
    case missingTopic
    case topicDisallowed
    case tooManyProviderTokenUpdates
    case badCertificate
    case badCertificateEnvironment
    case environmentNotConfigured(String)
    case other(reason: String, httpStatus: Int?)

    var reasonCode: String {
        switch self {
        case .expiredProviderToken: return "ExpiredProviderToken"
        case .invalidProviderToken: return "InvalidProviderToken"
        case .missingTopic: return "MissingTopic"
        case .topicDisallowed: return "TopicDisallowed"
        case .tooManyProviderTokenUpdates: return "TooManyProviderTokenUpdates"
        case .badCertificate: return "BadCertificate"
        case .badCertificateEnvironment: return "BadCertificateEnvironment"
        case .environmentNotConfigured(let env): return "EnvironmentNotConfigured:\(env)"
        case .other(let reason, _): return reason
        }
    }

    var isPermanentTokenFailure: Bool { false }
}

/// Transient infrastructure failures — do NOT disable the device token.
enum APNSTransientError: Error, Sendable {
    case network(String)
    case timeout
    case serverError(httpStatus: Int, reason: String?)
    case rateLimited
    case unknown(String)

    var reasonCode: String {
        switch self {
        case .network: return "NetworkFailure"
        case .timeout: return "Timeout"
        case .serverError(let status, _): return "APNSServerError:\(status)"
        case .rateLimited: return "TooManyRequests"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Protocol

protocol APNSSenderProtocol: Sendable {
    /// Sends an alert notification using the APNs client for `environment`.
    /// Throws `APNSTokenError` for permanently invalid tokens,
    /// `APNSProviderError` for credential/topic misconfiguration,
    /// or `APNSTransientError` for network/5xx failures.
    func sendAlert(
        title: String,
        body: String,
        to token: String,
        payload: SnapOrthoAPNSPayload,
        bundleId: String,
        environment: String
    ) async throws -> APNSSendResult
}

// MARK: - Real VaporAPNS implementation

struct VaporAPNSSender: APNSSenderProtocol, @unchecked Sendable {
    let application: Application

    func sendAlert(
        title: String,
        body: String,
        to token: String,
        payload: SnapOrthoAPNSPayload,
        bundleId: String,
        environment: String
    ) async throws -> APNSSendResult {
        guard let env = APNSDeviceEnvironment.parse(environment) else {
            throw APNSProviderError.other(reason: "UnknownEnvironment", httpStatus: nil)
        }

        let config = application.storage[APNSRuntimeConfigStorageKey.self]
        if let config, !config.isConfigured(env.rawValue) {
            throw APNSProviderError.environmentNotConfigured(env.rawValue)
        }

        let notification = APNSAlertNotification(
            alert: .init(
                title: .raw(title),
                body: .raw(body)
            ),
            expiration: .immediately,
            priority: .immediately,
            topic: bundleId,
            payload: payload
        )

        do {
            let response = try await application.apns.client(env.containerID).sendAlertNotification(
                notification,
                deviceToken: token
            )
            return APNSSendResult(
                apnsId: response.apnsID?.uuidString.lowercased(),
                environment: env.rawValue,
                topic: bundleId
            )
        } catch let error as APNSError {
            throw classifyAPNSError(error)
        } catch {
            throw APNSTransientError.network(String(describing: type(of: error)))
        }
    }

    private func classifyAPNSError(_ error: APNSError) -> any Error {
        guard let reason = error.reason else {
            if error.responseStatus >= 500 {
                return APNSTransientError.serverError(httpStatus: error.responseStatus, reason: nil)
            }
            return APNSTransientError.unknown("APNSError status=\(error.responseStatus)")
        }

        // Permanent token failures
        if reason == .badDeviceToken { return APNSTokenError.badDeviceToken }
        if reason == .deviceTokenNotForTopic { return APNSTokenError.deviceTokenNotForTopic }
        if reason == .unregistered { return APNSTokenError.unregistered }

        // Provider / config failures — never disable the device
        if reason == .expiredProviderToken { return APNSProviderError.expiredProviderToken }
        if reason == .invalidProviderToken { return APNSProviderError.invalidProviderToken }
        if reason == .missingTopic { return APNSProviderError.missingTopic }
        if reason == .topicDisallowed { return APNSProviderError.topicDisallowed }
        if reason == .tooManyProviderTokenUpdates { return APNSProviderError.tooManyProviderTokenUpdates }
        if reason == .badCertificate { return APNSProviderError.badCertificate }
        if reason == .badCertificateEnvironment { return APNSProviderError.badCertificateEnvironment }

        // Transient
        if reason == .tooManyRequests { return APNSTransientError.rateLimited }
        if reason == .internalServerError || reason == .serviceUnavailable || reason == .shutdown {
            return APNSTransientError.serverError(httpStatus: error.responseStatus, reason: reason.reason)
        }
        if reason == .idleTimeout {
            return APNSTransientError.timeout
        }

        if error.responseStatus >= 500 {
            return APNSTransientError.serverError(httpStatus: error.responseStatus, reason: reason.reason)
        }

        return APNSProviderError.other(reason: reason.reason, httpStatus: error.responseStatus)
    }
}

// MARK: - Application storage for the sender

private struct APNSSenderKey: StorageKey {
    typealias Value = any APNSSenderProtocol
}

extension Application {
    var apnsSender: any APNSSenderProtocol {
        get {
            if let stored = storage[APNSSenderKey.self] { return stored }
            return VaporAPNSSender(application: self)
        }
        set { storage[APNSSenderKey.self] = newValue }
    }
}
