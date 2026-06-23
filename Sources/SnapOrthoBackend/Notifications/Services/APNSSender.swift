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
}

// MARK: - Errors that indicate the token is permanently invalid

enum APNSTokenError: Error, Sendable {
    case badDeviceToken
    case unregistered
}

// MARK: - Protocol

protocol APNSSenderProtocol: Sendable {
    /// Sends an alert notification. Throws `APNSTokenError` for permanently invalid tokens,
    /// or another error for transient/network failures.
    func sendAlert(
        title: String,
        body: String,
        to token: String,
        payload: SnapOrthoAPNSPayload,
        bundleId: String
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
        bundleId: String
    ) async throws -> APNSSendResult {
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
            try await application.apns.client.sendAlertNotification(
                notification,
                deviceToken: token
            )
            return APNSSendResult(apnsId: nil)
        } catch let error as APNSError {
            throw classifyAPNSError(error)
        }
    }

    private func classifyAPNSError(_ error: APNSError) -> any Error {
        // APNSError.ErrorReason has static properties conforming to Hashable — compare directly
        if error.reason == .badDeviceToken { return APNSTokenError.badDeviceToken }
        if error.reason == .unregistered   { return APNSTokenError.unregistered }
        return error
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
            // Default to real VaporAPNS implementation
            return VaporAPNSSender(application: self)
        }
        set { storage[APNSSenderKey.self] = newValue }
    }
}
