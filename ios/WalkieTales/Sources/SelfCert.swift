import Foundation
import Security

/// A home-made certificate for the player's https address (port 8490): browsers only allow the microphone, for voice
/// messages, on a secure address. Same idea as the Android player: an RSA key made on the phone (kept in its keychain)
/// and a self-signed X.509 certificate written out by hand, made again if the phone's address changes. The browser
/// warns about it once. If anything here fails, the player just carries on without https.
enum SelfCert {
    private static let tag = Data("app.walkietales.https".utf8)
    private static let label = "WalkieTales player"

    static func identity(ip: String?) -> SecIdentity? {
        let want = ip ?? ""
        if Store.ud.string(forKey: "https_ip") == want, let id = find() { return id }
        remove()
        guard let id = make(ip: want) else { return nil }
        Store.ud.set(want, forKey: "https_ip")
        return id
    }

    private static func find() -> SecIdentity? {
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label, kSecReturnRef as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let o = out else { return nil }
        return (o as! SecIdentity)
    }

    private static func remove() {
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
    }

    private static func make(ip: String) -> SecIdentity? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag,
                                            kSecAttrLabel as String: label],
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err), let pub = SecKeyCopyPublicKey(priv),
              let pkcs1 = SecKeyCopyExternalRepresentation(pub, &err) as Data? else { NSLog("WalkieTales https key: \(String(describing: err))"); return nil }

        // SubjectPublicKeyInfo around the PKCS#1 key
        let rsaAlg = tlv(0x30, [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        let keyBits: [UInt8] = [0x00] + [UInt8](pkcs1)
        let spki = tlv(0x30, rsaAlg + tlv(0x03, keyBits))
        let sigAlg = tlv(0x30, [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
        let cnOid: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
        let name = tlv(0x30, tlv(0x31, tlv(0x30, cnOid + tlv(0x0C, Array(label.utf8)))))
        let now = Date()
        let from: [UInt8] = time(now.addingTimeInterval(-86_400)), until: [UInt8] = time(now.addingTimeInterval(3650 * 86_400))
        let validity = tlv(0x30, from + until)
        var names = tlv(0x82, Array("localhost".utf8))
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 { names += tlv(0x87, octets) }
        let sanOid: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x11]
        let ext = tlv(0xA3, tlv(0x30, tlv(0x30, sanOid + tlv(0x04, tlv(0x30, names)))))
        var serial = (0..<8).map { _ in UInt8.random(in: 0...255) }
        serial[0] &= 0x7F; serial[0] |= 0x01
        var body: [UInt8] = [0xA0, 0x03, 0x02, 0x01, 0x02] // version 3
        body += tlv(0x02, serial)
        body += sigAlg
        body += name
        body += validity
        body += name
        body += spki
        body += ext
        let tbs = tlv(0x30, body)
        guard let sig = SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, &err) as Data?,
              let cert = SecCertificateCreateWithData(nil, Data(certDER(tbs, sigAlg, sig)) as CFData) else {
            NSLog("WalkieTales https cert: \(String(describing: err))"); return nil
        }
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert, kSecAttrLabel as String: label]
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess || st == errSecDuplicateItem else { NSLog("WalkieTales https keychain: \(st)"); return nil }
        return find()
    }

    private static func certDER(_ tbs: [UInt8], _ alg: [UInt8], _ sig: Data) -> [UInt8] {
        var bits: [UInt8] = [0x00]
        bits += [UInt8](sig)
        var all = tbs
        all += alg
        all += tlv(0x03, bits)
        return tlv(0x30, all)
    }

    /// UTCTime (dates before 2050) or GeneralizedTime.
    private static func time(_ d: Date) -> [UInt8] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        let utc = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: d).year! < 2050
        f.dateFormat = utc ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return tlv(utc ? 0x17 : 0x18, Array(f.string(from: d).utf8))
    }

    private static func tlv(_ tag: UInt8, _ v: [UInt8]) -> [UInt8] {
        let n = v.count
        var out: [UInt8] = [tag]
        if n < 0x80 { out.append(UInt8(n)) }
        else if n < 0x100 { out += [0x81, UInt8(n)] }
        else if n < 0x10000 { out += [0x82, UInt8(n >> 8), UInt8(n & 0xFF)] }
        else { out += [0x83, UInt8(n >> 16), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }
        return out + v
    }
}
