//
//  VideoController.swift
//  SnapOrthoBackend
//
//  Created by Alex Baur on 6/6/25.
//

import Fluent
import Vapor

struct VideoController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("video-access", ":id", use: signedVideoURL)
    }

    func signedVideoURL(req: Request) async throws -> Response {
        guard let videoID = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing video ID")
        }

        let bucket = "snaportho-learn"
        let region = "us-east-1" // your AWS region as a String

        // You will want to store these in environment variables or Secrets, not hardcoded!
        let accessKey = Environment.get("AWS_ACCESS_KEY_ID") ?? "YOUR_ACCESS_KEY"
        let secretKey = Environment.get("AWS_SECRET_ACCESS_KEY") ?? "YOUR_SECRET_KEY"

        let presigner = S3Presigner(
            accessKey: accessKey,
            secretKey: secretKey,
            region: region,
            bucket: bucket
        )

        do {
            let signedURL = try presigner.presignedURL(objectKey: "videos/trauma/\(videoID).mp4", expiresIn: 300)

            struct VideoResponse: Content {
                let id: String
                let signedUrl: String
            }

            let response = try Response(
                status: .ok,
                body: .init(data: JSONEncoder().encode(VideoResponse(id: videoID, signedUrl: signedURL.absoluteString)))
            )
            response.headers.replaceOrAdd(name: HTTPHeaders.Name.contentType, value: "application/json")
            return response
        } catch {
            req.logger.error("Failed to generate presigned URL: \(error.localizedDescription)")
            throw Abort(.internalServerError, reason: "Unable to generate signed URL")
        }
    }
}
