import Foundation

/// Endereços dos serviços (mídia, PTZ, eventos), o perfil de vídeo e a foto de cada câmera ONVIF, lidos uma vez
/// por câmera e reaproveitados pelo PTZ, pelos alertas e pela foto do alerta.
@MainActor
final class OnvifServices {
    struct Entry {
        var client: OnvifClient
        let media: URL
        let ptz: URL?
        /// Endereços para tentar o PTZ: o que a câmera informa no lugar do PTZ (mesmo que pareça trocado, é o que o
        /// NVR usa) e o que tem "ptz" no caminho.
        var ptzCandidates: [URL] = []
        let events: URL?
        let profile: String?
        let snapshot: URL?
    }

    static let shared = OnvifServices()

    private var cache: [Camera.ID: Entry] = [:]
    /// Resultado do teste de PTZ de cada câmera (há câmeras que anunciam PTZ e derrubam a conexão ao usar).
    private var ptzWorks: [Camera.ID: Bool] = [:]
    private var pending: [Camera.ID: Task<Entry, Error>] = [:]
    /// Endereço e login que deram certo no PTZ de cada câmera.
    private var ptzRoute: [Camera.ID: (url: URL, auth: Bool)] = [:]
    /// Câmeras que não aceitam o Stop (Yoosee): param com um ContinuousMove de velocidade zero.
    private var stopsWithZeroMove: Set<Camera.ID> = []

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
            let named = address("PTZ", keyword: "ptz", namespace: "/ptz/")
            let reported = caps?.first("Capabilities")?.children.first { $0.name == "PTZ" }?.value("XAddr").flatMap(client.rehosted)
            var candidates: [URL] = []
            for url in [reported, named].compactMap({ $0 }) where !candidates.contains(url) { candidates.append(url) }
            return Entry(client: client, media: media, ptz: named ?? reported, ptzCandidates: candidates,
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
        ptzRoute[camera.id] = nil
        stopsWithZeroMove.remove(camera.id)
    }

    /// Para o movimento. Tenta o Stop e, se a câmera não aceitar, um ContinuousMove com velocidade zero.
    func stopPTZ(_ camera: Camera, panTilt: Bool, zoom: Bool) async throws {
        if !stopsWithZeroMove.contains(camera.id) {
            do {
                try await ptz(camera, action: "Stop", attempts: 2) { OnvifPTZ.stop(profile: $0, panTilt: panTilt, zoom: zoom) }
                return
            } catch {}
        }
        try await ptz(camera, action: "ContinuousMove", attempts: 4) {
            OnvifPTZ.continuousMove(profile: $0, x: 0, y: 0, zoom: 0, zeroAxes: (panTilt, zoom))
        }
        stopsWithZeroMove.insert(camera.id)
    }

    /// Pedido de PTZ. Há câmeras (Yoosee) que só aceitam o PTZ no endereço que informam no GetCapabilities e sem
    /// login, e que às vezes derrubam a conexão: tenta cada endereço com e sem login, de novo quando a conexão cai, e
    /// guarda o que funcionou.
    @discardableResult
    func ptz(_ camera: Camera, action: String, attempts: Int = 2, body: (String) -> String) async throws -> OnvifXML {
        let entry = try await entry(for: camera)
        guard let profile = entry.profile, !entry.ptzCandidates.isEmpty else {
            throw OnvifClient.Failure.fault(String(localized: "a câmera não informou o PTZ"))
        }
        var routes: [(url: URL, auth: Bool)] = ptzRoute[camera.id].map { [$0] } ?? []
        for url in entry.ptzCandidates {
            for auth in [true, false] where !routes.contains(where: { $0.url == url && $0.auth == auth }) {
                routes.append((url, auth))
            }
        }
        var lastError: Error = OnvifClient.Failure.invalid
        for route in routes {
            for attempt in 0 ..< max(attempts, 1) {
                // A Yoosee derruba pedidos enquanto o motor anda: espera um pouco antes de tentar de novo.
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(300 * attempt)) }
                do {
                    let xml = try await entry.client.call(route.url, body: body(profile), auth: route.auth, timeout: 4,
                                                          action: "http://www.onvif.org/ver20/ptz/wsdl/\(action)")
                    ptzRoute[camera.id] = route
                    return xml
                } catch let error as OnvifClient.Failure {
                    lastError = error
                    if case .unreachable = error { continue }
                    break
                }
            }
        }
        throw lastError
    }

    /// Tem PTZ de verdade: anuncia o serviço e responde à lista de presets. A Yoosee, por exemplo, anuncia PTZ
    /// mas só responde ao vídeo; o PTZ dela é pelo protocolo da própria marca.
    func hasPTZ(_ camera: Camera) async -> Bool {
        if let known = ptzWorks[camera.id] { return known }
        // GetNodes; se não, um ContinuousMove parado (velocidade zero), que é tudo o que a Yoosee aceita do PTZ.
        var works = (try? await ptz(camera, action: "GetNodes", attempts: 2) { _ in "<tptz:GetNodes/>" }) != nil
        if !works {
            works = (try? await ptz(camera, action: "ContinuousMove", attempts: 3) {
                OnvifPTZ.continuousMove(profile: $0, x: 0, y: 0, zoom: 0, zeroAxes: (true, false))
            }) != nil
        }
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

/// Corpo dos pedidos de PTZ (o endereço e o login ficam com OnvifServices.ptz).
enum OnvifPTZ {
    private static func number(_ value: Double) -> String { String(format: "%.6f", value) }

    /// Movimento contínuo: x, y e zoom de -1 a 1 (0 = parado naquele eixo). Só manda os eixos em uso, como o NVR.
    /// `zeroAxes`: eixos mandados mesmo com velocidade zero (para parar).
    static func continuousMove(profile: String, x: Double, y: Double, zoom: Double, zeroAxes: (Bool, Bool) = (false, false)) -> String {
        var velocity = ""
        if x != 0 || y != 0 || zeroAxes.0 { velocity += "<tt:PanTilt x=\"\(number(x))\" y=\"\(number(y))\"></tt:PanTilt>" }
        if zoom != 0 || zeroAxes.1 { velocity += "<tt:Zoom x=\"\(number(zoom))\"></tt:Zoom>" }
        return "<tptz:ContinuousMove><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken><tptz:Velocity>\(velocity)</tptz:Velocity></tptz:ContinuousMove>"
    }

    static func stop(profile: String, panTilt: Bool, zoom: Bool) -> String {
        "<tptz:Stop><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken>"
            + (panTilt ? "<tptz:PanTilt>true</tptz:PanTilt>" : "") + (zoom ? "<tptz:Zoom>true</tptz:Zoom>" : "") + "</tptz:Stop>"
    }

    static func presets(profile: String) -> String {
        "<tptz:GetPresets><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken></tptz:GetPresets>"
    }

    static func gotoPreset(profile: String, token: String) -> String {
        "<tptz:GotoPreset><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken><tptz:PresetToken>\(token.xmlEscaped)</tptz:PresetToken></tptz:GotoPreset>"
    }

    static func setPreset(profile: String, name: String, token: String?) -> String {
        let tokenXML = token.map { "<tptz:PresetToken>\($0.xmlEscaped)</tptz:PresetToken>" } ?? ""
        return "<tptz:SetPreset><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken><tptz:PresetName>\(name.xmlEscaped)</tptz:PresetName>\(tokenXML)</tptz:SetPreset>"
    }

    static func removePreset(profile: String, token: String) -> String {
        "<tptz:RemovePreset><tptz:ProfileToken>\(profile.xmlEscaped)</tptz:ProfileToken><tptz:PresetToken>\(token.xmlEscaped)</tptz:PresetToken></tptz:RemovePreset>"
    }

    static func presetList(_ xml: OnvifXML) -> [(token: String, name: String)] {
        xml.all("Preset").compactMap { node in node.attribute("token").map { ($0, node.value("Name") ?? $0) } }
    }
}
