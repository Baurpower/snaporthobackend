import Foundation
import SwiftJWT
import Security

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

    var jwtVerifier: JWTVerifier? {
        guard let modulus = Data(base64URLEncoded: n),
              let exponent = Data(base64URLEncoded: e) else {
            return nil
        }

        let keyData = rsaPublicKeyData(modulus: modulus, exponent: exponent)
        return JWTVerifier.rs256(publicKey: keyData)
    }
}


// Helper to build SecKey from modulus and exponent
private func createRSAPublicKey(modulus: Data, exponent: Data) -> SecKey? {
    // ASN.1 DER encoding for RSA public key (SubjectPublicKeyInfo)
    let pubKeyData = rsaPublicKeyData(modulus: modulus, exponent: exponent)
    
    let options: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        kSecAttrKeySizeInBits as String: modulus.count * 8,
        kSecReturnPersistentRef as String: true
    ]
    
    return SecKeyCreateWithData(pubKeyData as CFData, options as CFDictionary, nil)
}

// Encodes modulus and exponent in DER format for RSA public key
private func rsaPublicKeyData(modulus: Data, exponent: Data) -> Data {
    // DER structure: SEQUENCE { modulus, exponent }
    func encodeLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        } else {
            let lengthBytes = withUnsafeBytes(of: UInt32(length).bigEndian, Array.init).drop(while: { $0 == 0 })
            return Data([0x80 | UInt8(lengthBytes.count)] + lengthBytes)
        }
    }

    func encodeInteger(_ intData: Data) -> Data {
        var data = intData
        if data.first ?? 0 >= 0x80 {
            data.insert(0x00, at: 0)
        }
        return Data([0x02]) + encodeLength(data.count) + data
    }

    let sequence = encodeInteger(modulus) + encodeInteger(exponent)
    return Data([0x30]) + encodeLength(sequence.count) + sequence
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
