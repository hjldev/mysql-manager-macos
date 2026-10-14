import CryptoKit
import Foundation
import Security

/// Password scrambles for the authentication plugins MySQL 5.7–9.x use.
enum Auth {
    static let nativePassword = "mysql_native_password"
    static let cachingSha2 = "caching_sha2_password"
    static let sha256Password = "sha256_password"

    static func response(plugin: String, password: String, nonce: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        switch plugin {
        case nativePassword: return native(password, nonce)
        case cachingSha2: return sha2(password, nonce)
        // sha256_password sends the password RSA-encrypted (or in clear over TLS)
        // after the server's reply; the first response just asks for the key.
        case sha256Password: return [1]
        default: return sha2(password, nonce)
        }
    }

    /// SHA1(pw) XOR SHA1(nonce + SHA1(SHA1(pw)))
    static func native(_ password: String, _ nonce: [UInt8]) -> [UInt8] {
        let p1 = Array(Insecure.SHA1.hash(data: Data(password.utf8)))
        let p2 = Array(Insecure.SHA1.hash(data: Data(p1)))
        let p3 = Array(Insecure.SHA1.hash(data: Data(nonce.prefix(20) + p2)))
        return zip(p1, p3).map { $0 ^ $1 }
    }

    /// SHA256(pw) XOR SHA256(SHA256(SHA256(pw)) + nonce)
    static func sha2(_ password: String, _ nonce: [UInt8]) -> [UInt8] {
        let p1 = Array(SHA256.hash(data: Data(password.utf8)))
        let p2 = Array(SHA256.hash(data: Data(p1)))
        let p3 = Array(SHA256.hash(data: Data(p2 + nonce.prefix(20))))
        return zip(p1, p3).map { $0 ^ $1 }
    }

    /// NUL-terminated password XOR the nonce, as sent for full authentication.
    static func xorPassword(_ password: String, _ nonce: [UInt8]) -> [UInt8] {
        let pw = Array(password.utf8) + [0]
        let n = Array(nonce.prefix(20))
        return pw.enumerated().map { $1 ^ n[$0 % n.count] }
    }

    /// RSA-OAEP encryption with the server's PEM public key.
    static func rsaEncrypt(_ data: [UInt8], pem: String) throws -> [UInt8] {
        let body = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body) else { throw MySQLError.protocolViolation("无法解析服务器公钥") }
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1(fromSPKI: [UInt8](der))) as CFData, attrs as CFDictionary, &error),
              let out = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(data) as CFData, &error)
        else {
            let reason = error?.takeRetainedValue().localizedDescription ?? ""
            throw MySQLError.message("RSA 加密失败：\(reason)")
        }
        return [UInt8](out as Data)
    }

    /// `BEGIN PUBLIC KEY` is SubjectPublicKeyInfo; Security wants the PKCS#1
    /// RSAPublicKey inside its BIT STRING. PKCS#1 input is returned unchanged.
    static func pkcs1(fromSPKI der: [UInt8]) -> [UInt8] {
        var p = 0
        func header() -> (tag: UInt8, length: Int)? {
            guard p + 2 <= der.count else { return nil }
            let tag = der[p]
            var len = Int(der[p + 1])
            p += 2
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard n <= 4, p + n <= der.count else { return nil }
                len = der[p..<p + n].reduce(0) { $0 << 8 | Int($1) }
                p += n
            }
            return (tag, len)
        }
        guard let outer = header(), outer.tag == 0x30 else { return der }
        let afterOuter = p
        guard let first = header() else { return der }
        if first.tag != 0x30 {
            p = afterOuter
            return der // already PKCS#1: SEQUENCE { INTEGER, INTEGER }
        }
        p += first.length // skip AlgorithmIdentifier
        guard let bits = header(), bits.tag == 0x03, p + bits.length <= der.count, bits.length > 1 else { return der }
        return Array(der[(p + 1)..<(p + bits.length)]) // drop the unused-bits byte
    }
}
