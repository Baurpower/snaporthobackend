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
