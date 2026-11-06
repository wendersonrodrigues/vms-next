import CryptoKit
import Foundation

/// Cliente ONVIF (o padrão que câmeras de outras marcas falam): pergunta à câmera quem ela é e os endereços
/// RTSP do vídeo principal e do secundário. Usa SOAP por HTTP com o login WS-Security (UsernameToken com
/// senha resumida em SHA-1), que é o que o VMS antigo e quase todo programa de câmeras usa.
struct OnvifClient {
    enum Failure: LocalizedError {
        case unreachable(String)
        case auth
        case fault(String)
        case invalid
        case noVideo

        var errorDescription: String? {
            switch self {
            case let .unreachable(detail): return String(localized: "A câmera não respondeu pelo ONVIF (\(detail)).")
            case .auth: return String(localized: "Usuário ou senha recusados pela câmera.")
            case let .fault(reason): return String(localized: "A câmera recusou o pedido: \(reason)")
            case .invalid: return String(localized: "Resposta ONVIF que o app não entendeu.")
            case .noVideo: return String(localized: "A câmera não informou nenhum endereço de vídeo.")
            }
        }
    }

    struct DeviceInfo {
        var manufacturer: String?
        var model: String?
        var firmware: String?
        var serial: String?
    }

    /// Endereços do vídeo, do maior para o menor.
    struct Stream {
        let name: String
        let uri: String
        let width: Int
        let height: Int
    }

    let deviceURL: URL
    let username: String
    let password: String
    /// Diferença entre o relógio da câmera e o do Mac: o login leva a hora e câmeras com o relógio errado recusam.
    var clockOffset: TimeInterval = 0

    init(deviceURL: URL, username: String, password: String) {
        self.deviceURL = deviceURL
        self.username = username
        self.password = password
    }

    init?(camera: Camera, password: String) {
        guard let info = camera.onvif, let url = info.deviceURL(host: camera.host) else { return nil }
        self.init(deviceURL: url, username: camera.username, password: password)
    }

    // MARK: - Pedidos

    /// Acerta a diferença de relógio (pedido sem login). Se a câmera não responder, segue com 0.
    mutating func syncClock() async {
        // Algumas câmeras (Yoosee) nem respondem a este pedido: espera pouco para não atrasar o resto.
        guard let xml = try? await call(deviceURL, body: "<tds:GetSystemDateAndTime/>", auth: false, timeout: 2),
              let utc = xml.first("UTCDateTime") else { return }
        var parts = DateComponents()
        parts.timeZone = TimeZone(identifier: "UTC")
        parts.year = Int(utc.value("Year") ?? "")
        parts.month = Int(utc.value("Month") ?? "")
        parts.day = Int(utc.value("Day") ?? "")
        parts.hour = Int(utc.value("Hour") ?? "")
        parts.minute = Int(utc.value("Minute") ?? "")
        parts.second = Int(utc.value("Second") ?? "")
        if let date = Calendar(identifier: .gregorian).date(from: parts) {
            clockOffset = date.timeIntervalSinceNow
        }
    }

    func deviceInformation() async throws -> DeviceInfo {
        let xml = try await call(deviceURL, body: "<tds:GetDeviceInformation/>")
        return DeviceInfo(manufacturer: xml.value("Manufacturer"), model: xml.value("Model"),
                          firmware: xml.value("FirmwareVersion"), serial: xml.value("SerialNumber"))
    }

    /// Endereço do serviço de mídia (onde ficam os perfis de vídeo). Sem resposta, usa o próprio serviço do equipamento.
    func mediaURL() async -> URL {
        guard let xml = try? await call(deviceURL, body: "<tds:GetCapabilities><tds:Category>Media</tds:Category></tds:GetCapabilities>"),
              let address = xml.first("Media")?.value("XAddr") else { return deviceURL }
        return rehosted(address) ?? deviceURL
    }

    /// Perfis de vídeo e o endereço RTSP de cada um, do maior para o menor.
    func streams() async throws -> [Stream] {
        let media = await mediaURL()
        let profiles = try await call(media, body: "<trt:GetProfiles/>").all("Profiles")
        var result: [Stream] = []
        for profile in profiles {
            guard let token = profile.attribute("token") else { continue }
            let body = """
            <trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup>\
            <trt:ProfileToken>\(token.xmlEscaped)</trt:ProfileToken></trt:GetStreamUri>
            """
            guard let uri = try? await call(media, body: body).value("Uri") else { continue }
            let resolution = profile.first("VideoEncoderConfiguration")?.first("Resolution")
            result.append(Stream(name: profile.value("Name") ?? token, uri: uri,
                                 width: Int(resolution?.value("Width") ?? "") ?? 0,
                                 height: Int(resolution?.value("Height") ?? "") ?? 0))
        }
        guard !result.isEmpty else { throw Failure.noVideo }
        return result.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// O endereço que a câmera devolve às vezes traz outro IP (o da rede interna dela): troca pelo IP usado.
    private func rehosted(_ address: String) -> URL? {
        let first = address.split(separator: " ").first.map(String.init) ?? address
        guard var parts = URLComponents(string: first) else { return nil }
        parts.host = deviceURL.host
        if parts.port == nil { parts.port = deviceURL.port }
        return parts.url
    }

    // MARK: - SOAP

    func call(_ url: URL, body: String, auth: Bool = true, timeout: TimeInterval = 6) async throws -> OnvifXML {
        let envelope = """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" \
        xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">\
        <s:Header>\(auth ? security() : "")</s:Header><s:Body>\(body)</s:Body></s:Envelope>
        """
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(envelope.utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let xml = OnvifXML.parse(data) else {
            throw status == 401 ? Failure.auth : Failure.invalid
        }
        if let fault = xml.first("Fault") {
            let reason = fault.first("Reason")?.value("Text") ?? fault.value("Text") ?? fault.value("Value") ?? ""
            let lower = (reason + (fault.value("Subcode") ?? "") + (fault.first("Subcode")?.value("Value") ?? "")).lowercased()
            if status == 401 || lower.contains("notauthorized") || lower.contains("not authorized") || lower.contains("authority")
                || lower.contains("authenticat") || lower.contains("password") || lower.contains("sender not") {
                throw Failure.auth
            }
            throw Failure.fault(reason.isEmpty ? String(localized: "erro \(status)") : reason)
        }
        if status == 401 { throw Failure.auth }
        return xml
    }

    /// WS-Security: resumo = Base64(SHA1(nonce + hora + senha)).
    private func security() -> String {
        var nonce = Data(count: 16)
        for index in nonce.indices { nonce[index] = UInt8.random(in: 0 ... 255) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let created = formatter.string(from: Date().addingTimeInterval(clockOffset))
        var material = nonce
        material.append(Data(created.utf8))
        material.append(Data(password.utf8))
        let digest = Data(Insecure.SHA1.hash(data: material)).base64EncodedString()
        return """
        <wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" \
        xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken>\
        <wsse:Username>\(username.xmlEscaped)</wsse:Username>\
        <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest)</wsse:Password>\
        <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonce.base64EncodedString())</wsse:Nonce>\
        <wsu:Created>\(created)</wsu:Created></wsse:UsernameToken></wsse:Security>
        """
    }
}

/// Câmera de outra marca, ligada pelo ONVIF: onde fica o serviço dela e os endereços do vídeo lidos ao adicionar.
struct OnvifInfo: Codable, Hashable {
    /// Porta e caminho do serviço ONVIF do equipamento (http://IP:porta/caminho).
    var port: Int = 80
    var path: String = "/onvif/device_service"
    /// Endereços RTSP do vídeo principal e do secundário, sem usuário e senha (o app manda no login do RTSP).
    var mainURI: String?
    var subURI: String?
    var manufacturer: String?
    var model: String?

    func deviceURL(host: String) -> URL? {
        URL(string: "http://\(host):\(port)\(path.hasPrefix("/") ? path : "/" + path)")
    }

    /// Endereço RTSP da qualidade pedida, apontando para o IP salvo da câmera (sem usuário e senha no endereço).
    func rtspURL(host: String, sub: Bool) -> String? {
        guard let raw = (sub ? subURI ?? mainURI : mainURI ?? subURI), var parts = URLComponents(string: raw) else { return nil }
        parts.user = nil
        parts.password = nil
        parts.host = host
        return parts.string
    }

    /// Porta RTSP do endereço salvo (554 se não vier).
    var rtspPort: Int {
        (mainURI ?? subURI).flatMap { URLComponents(string: $0)?.port } ?? 554
    }

    /// Lê da câmera quem ela é e os endereços do vídeo.
    static func fetch(host: String, port: Int, path: String, username: String, password: String) async throws -> OnvifInfo {
        var info = OnvifInfo(port: port, path: path)
        guard let url = info.deviceURL(host: host) else { throw OnvifClient.Failure.invalid }
        var client = OnvifClient(deviceURL: url, username: username, password: password)
        await client.syncClock()
        if let device = try? await client.deviceInformation() {
            info.manufacturer = device.manufacturer
            info.model = device.model
        }
        let streams = try await client.streams()
        info.mainURI = streams.first?.uri
        info.subURI = streams.count > 1 ? streams.last?.uri : nil
        return info
    }
}
