import Foundation

/// Endereços dos serviços (mídia, PTZ, eventos), o perfil de vídeo e a foto de cada câmera ONVIF, lidos uma vez
/// por câmera e reaproveitados pelo PTZ, pelos alertas e pela foto do alerta.
@MainActor
final class OnvifServices {
    struct Entry {
        var client: OnvifClient
        let media: URL
        let ptz: URL?
        let events: URL?
        let profile: String?
        let snapshot: URL?
    }

    static let shared = OnvifServices()

    private var cache: [Camera.ID: Entry] = [:]
    /// Resultado do teste de PTZ de cada câmera (há câmeras que anunciam PTZ e derrubam a conexão ao usar).
    private var ptzWorks: [Camera.ID: Bool] = [:]
    private var pending: [Camera.ID: Task<Entry, Error>] = [:]

    func entry(for camera: Camera) async throws -> Entry {
        if let entry = cache[camera.id] { return entry }
        if let task = pending[camera.id] { return try await task.value }
        guard let password = Vault.shared.password(for: camera.keychainAccount),
              let base = OnvifClient(camera: camera, password: password) else { throw OnvifClient.Failure.auth }
        let task = Task { () throws -> Entry in
            var client = base
            await client.syncClock()
            let caps = try? await client.call(client.deviceURL,
                                              body: "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>")
            let services = try? await client.call(client.deviceURL,
                                                  body: "<tds:GetServices><tds:IncludeCapability>false</tds:IncludeCapability></tds:GetServices>")
            // Endereços de todos os serviços. Há firmware (Yoosee) que troca a ordem no GetCapabilities: Eventos com o
            // endereço da mídia, Mídia com o do PTZ… Por isso vale, nesta ordem: o GetServices (pelo namespace), um
            // endereço com o nome do serviço no caminho e, por último, o que veio no lugar do serviço.
            let all = (caps?.all("XAddr") ?? []).compactMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            func address(_ service: String, keyword: String, namespace: String) -> URL? {
                if let listed = services?.all("Service").first(where: { ($0.value("Namespace") ?? "").contains(namespace) })?.value("XAddr"),
                   let url = client.rehosted(listed), url.path.lowercased().contains(keyword) || service == "Events" { return url }
                if let named = all.first(where: { (URLComponents(string: $0)?.path.lowercased() ?? "").contains(keyword) }) {
                    return client.rehosted(named)
                }
                return caps?.first("Capabilities")?.children.first { $0.name == service }?.value("XAddr").flatMap(client.rehosted)
            }
            let media = address("Media", keyword: "media", namespace: "/media/") ?? client.deviceURL
            let profile = try? await client.call(media, body: "<trt:GetProfiles/>").all("Profiles").first?.attribute("token")
            var snapshot: URL?
            if let profile {
                let uri = try? await client.call(media, body: "<trt:GetSnapshotUri><trt:ProfileToken>\(profile.xmlEscaped)</trt:ProfileToken></trt:GetSnapshotUri>").value("Uri")
                snapshot = uri.flatMap(client.rehosted)
            }
            return Entry(client: client, media: media, ptz: address("PTZ", keyword: "ptz", namespace: "/ptz/"),
                         events: address("Events", keyword: "event", namespace: "/events/"), profile: profile, snapshot: snapshot)
        }
        pending[camera.id] = task
        defer { pending[camera.id] = nil }
        let entry = try await task.value
        cache[camera.id] = entry
        return entry
    }

    /// Esquece o que foi lido (a câmera mudou de IP ou de senha).
    func invalidate(_ camera: Camera) {
        cache[camera.id] = nil
        ptzWorks[camera.id] = nil
    }

    /// Tem PTZ de verdade: anuncia o serviço e responde à lista de presets. A Yoosee, por exemplo, anuncia PTZ
    /// mas só responde ao vídeo; o PTZ dela é pelo protocolo da própria marca.
    func hasPTZ(_ camera: Camera) async -> Bool {
        if let known = ptzWorks[camera.id] { return known }
        guard let entry = try? await entry(for: camera), let url = entry.ptz, let profile = entry.profile else { return false }
        let works = (try? await entry.client.presets(url, profile: profile)) != nil
        ptzWorks[camera.id] = works
        return works
    }

    /// Foto atual (GetSnapshotUri), com o login HTTP Digest/Basic da câmera.
    func snapshot(_ camera: Camera) async -> Data? {
        guard let entry = try? await entry(for: camera), let url = entry.snapshot else { return nil }
        let delegate = HTTPLogin(username: entry.client.username, password: entry.client.password)
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 6), delegate: delegate),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private final class HTTPLogin: NSObject, URLSessionTaskDelegate {
        let username: String
        let password: String

        init(username: String, password: String) {
            self.username = username
            self.password = password
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.previousFailureCount == 0 else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
        }
    }
}

// MARK: - PTZ

extension OnvifClient {
    /// Movimento contínuo: x, y e zoom de -1 a 1 (0 = parado naquele eixo).
    func continuousMove(_ url: URL, profile: String, x: Double, y: Double, zoom: Double) async throws {
        var velocity = ""
        if x != 0 || y != 0 { velocity += "<tt:PanTilt x=\"\(x)\" y=\"\(y)\"/>" }
        if zoom != 0 { velocity += "<tt:Zoom x=\"\(zoom)\"/>" }
        _ = try await call(url, body: "<tptz:ContinuousMove><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken><tptz:Velocity>\(velocity)</tptz:Velocity></tptz:ContinuousMove>")
    }

    func stopMove(_ url: URL, profile: String) async throws {
        _ = try await call(url, body: "<tptz:Stop><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken><tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>")
    }

    /// Presets da câmera: token e nome.
    func presets(_ url: URL, profile: String) async throws -> [(token: String, name: String)] {
        try await call(url, body: "<tptz:GetPresets><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken></tptz:GetPresets>")
            .all("Preset").compactMap { node in
                node.attribute("token").map { ($0, node.value("Name") ?? $0) }
            }
    }

    func gotoPreset(_ url: URL, profile: String, token: String) async throws {
        _ = try await call(url, body: "<tptz:GotoPreset><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken><tptz:PresetToken>\(token.xmlEscaped)</tptz:PresetToken></tptz:GotoPreset>")
    }

    /// Grava a posição atual no preset (com o token, sobrescreve o que já existe).
    func setPreset(_ url: URL, profile: String, name: String, token: String?) async throws {
        let tokenXML = token.map { "<tptz:PresetToken>\($0.xmlEscaped)</tptz:PresetToken>" } ?? ""
        _ = try await call(url, body: "<tptz:SetPreset><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken><tptz:PresetName>\(name.xmlEscaped)</tptz:PresetName>\(tokenXML)</tptz:SetPreset>")
    }

    func removePreset(_ url: URL, profile: String, token: String) async throws {
        _ = try await call(url, body: "<tptz:RemovePreset><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken><tptz:PresetToken>\(token.xmlEscaped)</tptz:PresetToken></tptz:RemovePreset>")
    }
}
