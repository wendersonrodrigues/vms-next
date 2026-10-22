import Foundation

struct Camera: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var rtspPort: Int = 554
    /// Canal começando em 1 (NVRs têm vários canais no mesmo IP).
    var channel: Int = 1
    var username: String = "admin"
    /// Caminho RTSP com marcadores {user}, {password}, {channel} e {stream}.
    var pathTemplate: String = Camera.xiongmaiPathTemplate

    static let xiongmaiPathTemplate = "/user={user}&password={password}&channel={channel}&stream={stream}.sdp?real_stream"

    /// A senha fica no Keychain por usuário@host, então todos os canais de um NVR a compartilham.
    var keychainAccount: String { "\(username)@\(host)" }

    func rtspURL(password: String, quality: StreamQuality) -> String {
        var path = pathTemplate
            .replacingOccurrences(of: "{user}", with: username)
            .replacingOccurrences(of: "{password}", with: password)
            .replacingOccurrences(of: "{channel}", with: String(channel))
            .replacingOccurrences(of: "{stream}", with: String(quality.rawValue))
        if !path.hasPrefix("/") { path = "/" + path }
        return "rtsp://\(host):\(rtspPort)\(path)"
    }
}
