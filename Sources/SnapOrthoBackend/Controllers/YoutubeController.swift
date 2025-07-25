import Vapor

// MARK: - Controller
struct YoutubeController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let video = routes.grouped("video-access")
        video.get(use: getAllVideos)
        video.get(":id", use: getVideoByID)
    }

    private let videos: [Video] = [
        .init(
            id: "distal-radius",
            title: "Distal Radius Fractures",
            description: "Classification and operative treatment pearls for DR fractures.",
            youtubeURL: "https://youtu.be/nSqiWf5Z-B0",
            category: "Trauma",
            isPreview: true
        ),
        .init(
            id: "it-fractures",
            title: "Intertrochanteric (IT) Hip Fractures",
            description: "Classification and operative treatment pearls for IT fractures.",
            youtubeURL: "https://youtu.be/m5-ioOLLcp8?si=LU_drrVnpvKBWAqz",
            category: "Trauma",
            isPreview: true
        )
    ]

    func getAllVideos(req: Request) async throws -> [Video] {
        return videos
    }

    func getVideoByID(req: Request) async throws -> Video {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing video ID")
        }

        guard let video = videos.first(where: { $0.id == id }) else {
            throw Abort(.notFound, reason: "Video not found")
        }

        return video
    }
}
