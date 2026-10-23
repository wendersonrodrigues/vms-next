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
    /// Porta do protocolo DVRIP da Xiongmai (PTZ e configurações).
    var dvripPort: Int = 34567
    /// Nome do NVR quando a câmera é um canal dele; nil para câmera avulsa.
    var group: String?
    var liveSource: LiveSource = .auto
    /// Canal de NVR que é a mesma câmera física de uma câmera avulsa (ligado manualmente em Eventos ou em Editar câmera).
    var sameAs: Camera.ID?
    /// Número de série (CloudID) do equipamento, só para consulta; o acesso pela nuvem não é suportado.
    var cloudID: String?
    /// Split virtual: câmera dupla (uma imagem em cima da outra) mostrada como dois quadros no app.
    var split: CameraSplit?

    /// Nome completo para mosaico e listas: "NVR · Canal 2" ou "Frente".
    var displayName: String { group.map { "\($0) · \(name)" } ?? name }

    static let xiongmaiPathTemplate = "/user={user}&password={password}&channel={channel}&stream={stream}.sdp?real_stream"

    /// A senha fica no cofre (Vault) por usuário@host, então todos os canais de um NVR a compartilham.
    var keychainAccount: String { "\(username)@\(host)" }

    init(name: String, host: String, channel: Int = 1, username: String = "admin", group: String? = nil) {
        self.name = name
        self.host = host
        self.channel = channel
        self.username = username
        self.group = group
    }

    /// Campos novos usam decodeIfPresent para abrir o cameras.json de versões anteriores.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        rtspPort = try c.decodeIfPresent(Int.self, forKey: .rtspPort) ?? 554
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? 1
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? "admin"
        pathTemplate = try c.decodeIfPresent(String.self, forKey: .pathTemplate) ?? Camera.xiongmaiPathTemplate
        dvripPort = try c.decodeIfPresent(Int.self, forKey: .dvripPort) ?? 34567
        group = try c.decodeIfPresent(String.self, forKey: .group)
        liveSource = try c.decodeIfPresent(LiveSource.self, forKey: .liveSource) ?? .auto
        sameAs = try c.decodeIfPresent(UUID.self, forKey: .sameAs)
        cloudID = try c.decodeIfPresent(String.self, forKey: .cloudID)
        split = try c.decodeIfPresent(CameraSplit.self, forKey: .split)
    }

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

/// Nomes das duas metades de uma câmera dividida (só no app; a câmera continua uma só).
struct CameraSplit: Codable, Hashable {
    var topName: String
    var bottomName: String
}

/// Parte da imagem mostrada num quadro.
enum SplitPart: String, Hashable, Codable {
    case full, top, bottom
}

extension Camera {
    /// Nome do quadro: o nome dado à metade, ou o nome normal.
    func title(for part: SplitPart) -> String {
        switch part {
        case .full: return displayName
        case .top: return split?.topName ?? displayName
        case .bottom: return split?.bottomName ?? displayName
        }
    }
}
