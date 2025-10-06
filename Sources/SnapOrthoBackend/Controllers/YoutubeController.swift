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
        ),
        .init(
            id: "open-fractures",
            title: "Open Fractures",
            description: "Classification and operative treatment pearls for open fractures.",
            youtubeURL: "https://youtu.be/lmonzQ08tjA?si=ufckVR0aBjk5iG7",
            category: "Trauma",
            isPreview: true
        ),
        .init(
            id: "tlics",
            title: "Thoracolumbar Injury Classification and Severity Scale",
            description: "Classification and treatment for thoracolumbar spine injuries based on morphology, neurologic status, and PLC integrity.",
            youtubeURL: "https://youtu.be/AgFEs0Cl-H0",
            category: "Trauma",
            isPreview: true
        ),
        .init(
            id: "vancouver",
            title: "Vancouver Classification Periprosthetic Hip Fractures",
            description: "Classification and treatment for periprosthetic hip fractures.",
            youtubeURL: "https://youtu.be/zmVSJGWz00s?si=WG-IJJVnbUEXBx49",
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
