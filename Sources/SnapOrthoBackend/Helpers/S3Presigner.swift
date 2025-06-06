import Foundation
import Crypto

struct S3Presigner {
    let accessKey: String
    let secretKey: String
    let region: String
    let bucket: String

    func presignedURL(objectKey: String, expiresIn seconds: Int) throws -> URL {
        let host = "\(bucket).s3.\(region).amazonaws.com"
        let service = "s3"

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = dateFormatter.string(from: now)

        let shortDateFormatter = DateFormatter()
        shortDateFormatter.dateFormat = "yyyyMMdd"
        shortDateFormatter.timeZone = TimeZone(identifier: "UTC")
        let shortDate = shortDateFormatter.string(from: now)

        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let signedHeaders = "host"

        // Canonical request
        let canonicalURI = "/\(objectKey)"
        let canonicalQueryString = [
            "X-Amz-Algorithm": algorithm,
            "X-Amz-Credential": "\(accessKey)/\(credentialScope)",
            "X-Amz-Date": amzDate,
            "X-Amz-Expires": "\(seconds)",
            "X-Amz-SignedHeaders": signedHeaders
        ]
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
        .sorted()
        .joined(separator: "&")

        let canonicalHeaders = "host:\(host)\n"
        let payloadHash = "UNSIGNED-PAYLOAD"

        let canonicalRequest = [
            "GET",
            canonicalURI,
            canonicalQueryString,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        // String to sign
        let canonicalRequestHash = canonicalRequest.data(using: .utf8)!.sha256.hexString

        let stringToSign = [
            algorithm,
            amzDate,
            credentialScope,
            canonicalRequestHash
        ].joined(separator: "\n")

        // Derive signing key
        let dateKey = hmacSHA256("AWS4\(secretKey)", shortDate.data(using: .utf8)!)
        let dateRegionKey = hmacSHA256(dateKey, region.data(using: .utf8)!)
        let dateRegionServiceKey = hmacSHA256(dateRegionKey, service.data(using: .utf8)!)
        let signingKey = hmacSHA256(dateRegionServiceKey, "aws4_request".data(using: .utf8)!)

        // Signature
        let signature = hmacSHA256(signingKey, stringToSign.data(using: .utf8)!).hexString

        // Final URL
        let urlString = "https://\(host)\(canonicalURI)?\(canonicalQueryString)&X-Amz-Signature=\(signature)"
        return URL(string: urlString)!
    }

    private func hmacSHA256(_ key: Data, _ data: Data) -> Data {
        let keySymmetric = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: keySymmetric)
        return Data(signature)
    }

    private func hmacSHA256(_ key: String, _ data: Data) -> Data {
        return hmacSHA256(key.data(using: .utf8)!, data)
    }
}

extension Data {
    var sha256: Data {
        let hash = SHA256.hash(data: self)
        return Data(hash)
    }

    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}
