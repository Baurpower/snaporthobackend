import Vapor
import XMLCoder

private struct S3ListResponse: Decodable {
    enum CodingKeys: String, CodingKey { case contents = "Contents", nextToken = "NextContinuationToken" }
    let contents: [S3Object]?
    let nextToken: String?
}

private struct S3Object: Decodable {
    enum CodingKeys: String, CodingKey { case key = "Key" }
    let key: String
}



struct PublicS3Crawler {
    let bucket = "snaportho-practice"
    let baseURL = "https://snaportho-practice.s3.amazonaws.com"

    func fetchAll(on req: Request) async throws -> [ImageMetadata] {

        var images: [ImageMetadata] = []
        var token: String? = nil
        let decoder = XMLDecoder()

        repeat {
            var url = "https://\(bucket).s3.amazonaws.com?list-type=2"
            if let t = token { url += "&continuation-token=\(t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }

            let res = try await req.client.get(URI(string: url))
            guard res.status == .ok, let body = res.body else {
                throw Abort(.internalServerError, reason: "S3 listing failed")
            }

            let list = try decoder.decode(S3ListResponse.self, from: Data(buffer: body))
            for object in list.contents ?? [] {
                let keyParts = object.key.split(separator: "/")
                guard keyParts.count == 3 else { continue }

                let region  = String(keyParts[0])
                let caseId  = String(keyParts[1])
                let file    = keyParts[2]

                // diag_1.jpg → ["diag","1"]
                let name    = file.replacingOccurrences(of: ".jpg", with: "")
                                 .replacingOccurrences(of: ".png", with: "")
                let parts   = name.split(separator: "_")
                guard parts.count == 2, let idx = Int(parts[1]) else { continue }

                let img = ImageMetadata(
                    region: region,
                    caseId: caseId,
                    imageType: String(parts[0]),
                    index: idx,
                    url: "\(baseURL)/\(object.key)"
                )
                images.append(img)
            }
            token = list.nextToken
        } while token != nil

        // Optional: stable sorting
        return images.sorted {
            ($0.region, $0.caseId, $0.imageType, $0.index)
            <
            ($1.region, $1.caseId, $1.imageType, $1.index)
        }
    }
}
