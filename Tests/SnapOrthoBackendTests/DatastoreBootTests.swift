@testable import SnapOrthoBackend
import VaporTesting
import Testing
import Vapor
import Fluent

@Suite("Datastore Boot Tests", .serialized)
struct DatastoreBootTests {

    private struct DeviceRegistrationPayload: Content {
        let deviceToken: String
        let platform: String
        let appVersion: String
        let environment: String
        let timezone: String?
        let receiveNotifications: Bool
    }

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try configure(app)
            try await test(app)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("Startup logs Supabase-primary datastore config")
    func startupDatastoreConfigPresent() async throws {
        try await withApp { app in
            let config = app.datastoreConfig
            #expect(config.supabaseConfigured == true)
            #expect(config.rdsMode == .fallback || config.rdsMode == .disabled)
        }
    }

    @Test("Device registration succeeds when Supabase is configured")
    func deviceRegistrationRequiresSupabase() async throws {
        try await withApp { app in
        let token = String(repeating: "e", count: 64)
        try await app.testing().test(
            .POST, "device/register",
            beforeRequest: { req in
                try req.content.encode(DeviceRegistrationPayload(
                    deviceToken: token,
                    platform: "ios",
                    appVersion: "2.0.0",
                    environment: "production",
                    timezone: "America/Chicago",
                    receiveNotifications: true
                ))
            },
            afterResponse: { res async in
                #expect(res.status == .ok)
            }
        )

        let stored = try await UserDeviceToken.query(on: app.db(.notifications))
            .filter(\.$tokenHash == UserDeviceToken.hash(token))
            .first()
        #expect(stored != nil)
        #expect(stored?.timezone == "America/Chicago")
        }
    }

    @Test("Anonymous device registration stores null user_id")
    func anonymousDeviceRegistration() async throws {
        try await withApp { app in
        let token = String(repeating: "f", count: 64)
        try await app.testing().test(
            .POST, "device/register",
            beforeRequest: { req in
                try req.content.encode(DeviceRegistrationPayload(
                    deviceToken: token,
                    platform: "ios",
                    appVersion: "1.0.0",
                    environment: "production",
                    timezone: nil,
                    receiveNotifications: true
                ))
            },
            afterResponse: { res async in
                #expect(res.status == .ok)
            }
        )

        let stored = try await UserDeviceToken.query(on: app.db(.notifications))
            .filter(\.$tokenHash == UserDeviceToken.hash(token))
            .first()
        #expect(stored?.userId == nil)
        }
    }
}
