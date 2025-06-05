import Foundation
import SwiftJWT

struct JWKSet: Codable {
    let keys: [JWK]
}

struct JWK: Codable {
    let kty: String
    let kid: String
    let use: String
    let alg: String
    let n: String
    let e: String

    var rsakey: RSAKey? {
        guard let modulus = Data(base64URLEncoded: n),
              let exponent = Data(base64URLEncoded: e) else {
            return nil
        }
        return try? .public(modulus: modulus, exponent: exponent)
    }
}

extension Data {
    init?(base64URLEncoded: String) {
        var base64 = base64URLEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - base64.count % 4
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        self.init(base64Encoded: base64)
    }
}
