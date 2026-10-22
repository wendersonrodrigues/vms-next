import CryptoKit
import Foundation

/// Autenticação RTSP (Digest RFC 2617 ou Basic) a partir do cabeçalho WWW-Authenticate.
struct RTSPAuth {
    private let isDigest: Bool
    private let params: [String: String]
    private let username: String
    private let password: String
    private var nonceCount = 0

    init?(challenge: String, username: String, password: String) {
        let trimmed = challenge.trimmingCharacters(in: .whitespaces)
        let scheme = trimmed.prefix { $0 != " " }.lowercased()
        guard scheme == "digest" || scheme == "basic" else { return nil }
        isDigest = scheme == "digest"
        params = Self.parseParams(String(trimmed.dropFirst(scheme.count)))
        self.username = username
        self.password = password
    }

    mutating func header(method: String, uri: String) -> String {
        guard isDigest else {
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        }
        let realm = params["realm"] ?? ""
        let nonce = params["nonce"] ?? ""
        let ha1 = Self.md5("\(username):\(realm):\(password)")
        let ha2 = Self.md5("\(method):\(uri)")

        var fields = [
            "username=\"\(username)\"",
            "realm=\"\(realm)\"",
            "nonce=\"\(nonce)\"",
            "uri=\"\(uri)\"",
        ]
        let qopOffered = (params["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if qopOffered.contains("auth") {
            nonceCount += 1
            let nc = String(format: "%08x", nonceCount)
            let cnonce = String(format: "%08x", UInt32.random(in: 0 ... .max))
            let response = Self.md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
            fields += ["response=\"\(response)\"", "qop=auth", "nc=\(nc)", "cnonce=\"\(cnonce)\""]
        } else {
            fields.append("response=\"\(Self.md5("\(ha1):\(nonce):\(ha2)"))\"")
        }
        if let opaque = params["opaque"] { fields.append("opaque=\"\(opaque)\"") }
        return "Digest " + fields.joined(separator: ", ")
    }

    private static func parseParams(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let regex = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*(?:"([^"]*)"|([^,\s]*))"#)
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let quoted = match.range(at: 2)
            let value = quoted.location != NSNotFound ? ns.substring(with: quoted) : ns.substring(with: match.range(at: 3))
            result[key] = value
        }
        return result
    }

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
