import Vapor
import Crypto

enum StripeWebhook {
    // MARK: Signature verification
    static func verifySignature(
        payload: ByteBuffer,
        signatureHeader: String,
        secret: String,
        toleranceSeconds: Int = 300
    ) throws {
        var timestamp: Int?
        var v1Signatures: [String] = []

        for part in signatureHeader.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if key == "t" { timestamp = Int(value) }
            if key == "v1" { v1Signatures.append(value) }
        }

        guard let t = timestamp, !v1Signatures.isEmpty else {
            throw Abort(.badRequest, reason: "Missing Stripe signature components.")
        }

        let now = Int(Date().timeIntervalSince1970)
        if abs(now - t) > toleranceSeconds {
            throw Abort(.badRequest, reason: "Stripe signature timestamp outside tolerance.")
        }

        // Raw bytes
        let bytes = payload.getBytes(at: payload.readerIndex, length: payload.readableBytes) ?? []
        let payloadData = Data(bytes)

        // signed_payload = "\(t).\(payload)"
        var signed = Data("\(t).".utf8)
        signed.append(payloadData)

        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: signed, using: key)
        let expected = Data(mac).map { String(format: "%02x", $0) }.joined()

        if !v1Signatures.contains(where: { $0.lowercased() == expected.lowercased() }) {
            throw Abort(.badRequest, reason: "Invalid Stripe signature.")
        }
    }

    // MARK: Minimal event decoding
    struct Event: Content {
        let id: String
        let type: String
        let data: EventData
    }

    struct EventData: Content {
        let object: PaymentIntentObject
    }

    struct PaymentIntentObject: Content {
        let id: String
        let amount: Int
        let currency: String?
        let status: String?
        let receipt_email: String?
        let metadata: [String: String]?
    }

    static func decodeEvent(from payload: ByteBuffer) throws -> Event {
        let bytes = payload.getBytes(at: payload.readerIndex, length: payload.readableBytes) ?? []
        let data = Data(bytes)
        return try JSONDecoder().decode(Event.self, from: data)
    }
}
