//
//  ChatGPTPlanTestSigningKey.swift
//  elfhubTests
//
//  A throwaway RSA key that signs ID tokens and publishes them as a JWKS,
//  shared by the sign-in and account tests.
//

import Foundation
import Security
@testable import elfhub

struct ChatGPTPlanTestSigningKey {
    let privateKey: SecKey
    let jwksData: Data

    init(keyIdentifier: String = "test-key") throws {
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var creationError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &creationError),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw TestKeyError.couldNotMakeKey
        }
        self.privateKey = privateKey
        let (modulus, exponent) = try Self.modulusAndExponent(fromPKCS1DER: publicKeyDER)
        let jwks: [String: Any] = ["keys": [[
            "kty": "RSA", "kid": keyIdentifier, "alg": "RS256", "use": "sig",
            "n": ChatGPTPlanBase64URL.encode(modulus),
            "e": ChatGPTPlanBase64URL.encode(exponent),
        ]]]
        self.jwksData = try JSONSerialization.data(withJSONObject: jwks)
    }

    enum TestKeyError: Error { case couldNotMakeKey, badDER }

    /// Reads SEQUENCE { INTEGER modulus, INTEGER exponent }.
    static func modulusAndExponent(fromPKCS1DER der: Data) throws -> (Data, Data) {
        let bytes = [UInt8](der)
        var position = 0
        func readLength() throws -> Int {
            guard position < bytes.count else { throw TestKeyError.badDER }
            let firstByte = bytes[position]; position += 1
            if firstByte < 0x80 { return Int(firstByte) }
            let lengthByteCount = Int(firstByte & 0x7F)
            var length = 0
            for _ in 0..<lengthByteCount {
                guard position < bytes.count else { throw TestKeyError.badDER }
                length = (length << 8) | Int(bytes[position]); position += 1
            }
            return length
        }
        func readInteger() throws -> Data {
            guard position < bytes.count, bytes[position] == 0x02 else { throw TestKeyError.badDER }
            position += 1
            let length = try readLength()
            var integerBytes = Array(bytes[position..<(position + length)])
            position += length
            while integerBytes.count > 1, integerBytes.first == 0 { integerBytes.removeFirst() }
            return Data(integerBytes)
        }
        guard bytes.first == 0x30 else { throw TestKeyError.badDER }
        position = 1
        _ = try readLength()
        return (try readInteger(), try readInteger())
    }

    func signedToken(claims: [String: Any], keyIdentifier: String = "test-key", algorithm: String = "RS256") throws -> String {
        let header: [String: Any] = ["alg": algorithm, "kid": keyIdentifier, "typ": "JWT"]
        let encodedHeader = ChatGPTPlanBase64URL.encode(try JSONSerialization.data(withJSONObject: header))
        let encodedClaims = ChatGPTPlanBase64URL.encode(try JSONSerialization.data(withJSONObject: claims))
        let signingInput = Data("\(encodedHeader).\(encodedClaims)".utf8)
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, nil) as Data? else {
            throw TestKeyError.couldNotMakeKey
        }
        return "\(encodedHeader).\(encodedClaims).\(ChatGPTPlanBase64URL.encode(signature))"
    }
}
