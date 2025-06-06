import Vapor
import AWSS3
import AWSClientRuntime
import SmithyHTTPAuth

struct VideoController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("video-access", ":id", use: signedVideoURL)
    }

    func signedVideoURL(req: Request) async throws -> Response {
        guard let videoID = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing video ID")
        }

        // AWS S3 Client
        let client = try S3Client(region: "us-east-1")
        
        // Build object key — map id param to your exact path in S3
        let key = "videos/trauma/\(videoID).mp4"

        let presignConfig = S3Client.PresignGetObjectInput(
            bucket: "snaportho-learn",
            key: key,
            expiresIn: 300 // URL valid for 5 min
        )

        let presignedURL = try await client.presignGetObject(presignConfig)

        struct VideoResponse: Content {
            let id: String
            let signedUrl: String
        }

        return try Response(
            status: .ok,
            body: .init(data: JSONEncoder().encode(VideoResponse(id: videoID, signedUrl: presignedURL)))
        )
    }
}
