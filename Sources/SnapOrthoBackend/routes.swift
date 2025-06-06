import Fluent
import Vapor
import AWSS3
import AWSClientRuntime
import SmithyHTTPAuth

struct VideoController: RouteCollection {
    let app: Application
    let s3Client: S3Client

    init(app: Application) throws {
        self.app = app                   // Initialize app here
        self.s3Client = try S3Client(region: "us-east-1")
    }

    func boot(routes: RoutesBuilder) throws {
        routes.get("video-access", ":id", use: signedVideoURL)
    }


    func signedVideoURL(req: Request) async throws -> Response {
        guard let videoID = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing video ID")
        }

        let key = "videos/trauma/\(videoID).mp4"
        let presignConfig = S3Client.PresignGetObjectInput(
            bucket: "snaportho-learn",
            key: key,
            expiresIn: 300 // URL valid for 5 min
        )

        do {
            let presignedURL = try await s3Client.presignGetObject(presignConfig)
            struct VideoResponse: Content {
                let id: String
                let signedUrl: String
            }

            let response = try Response(
                status: .ok,
                body: .init(data: JSONEncoder().encode(VideoResponse(id: videoID, signedUrl: presignedURL)))
            )
            response.headers.replaceOrAdd(name: .contentType, value: "application/json")
            return response
        } catch {
            req.logger.error("Failed to generate presigned URL: \(error.localizedDescription)")
            throw Abort(.internalServerError, reason: "Unable to generate signed URL")
        }
    }
}


func routes(_ app: Application) throws {
    // MARK: - 🔓 Public Routes

    app.get { req async in
        "It works!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    try app.register(collection: TodoController())

    // Register VideoController for signed URL access
    try app.register(collection: VideoController(app: app))

    // MARK: - 🔐 Authenticated Action: Delete Supabase User

    app.post("delete-user") { req async throws -> Response in
        guard let bearer = req.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing Bearer token")
        }

        // Fetch user info using access token
        let userResponse = try await SupabaseAPI.getUser(from: bearer.token, app: app)
        guard let userId = userResponse?.id else {
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }

        // Attempt user deletion
        let deleted = try await SupabaseAPI.deleteUser(id: userId, app: app)
        if deleted {
            return Response(status: .ok, body: .init(string: "User deleted"))
        } else {
            throw Abort(.internalServerError, reason: "Failed to delete user")
        }
    }
}
