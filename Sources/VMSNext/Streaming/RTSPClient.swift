import Foundation
import Network

enum RTSPError: LocalizedError {
    case unauthorized
    case badStatus(Int, String)
    case noVideoTrack
    case unsupportedCodec(String)
    case connection(String)
    case closed
    case stalled

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Usuário ou senha incorretos"
        case let .badStatus(code, method): return "\(method) recusado (RTSP \(code))"
        case .noVideoTrack: return "A câmera não anunciou vídeo"
        case let .unsupportedCodec(name): return "Codec não suportado: \(name)"
        case let .connection(message): return "Falha de conexão: \(message)"
        case .closed: return "A câmera encerrou a conexão"
        case .stalled: return "Sem vídeo há mais de 10 s"
        }
    }
}

struct RTSPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Cliente RTSP mínimo: OPTIONS → DESCRIBE → SETUP (TCP interleaved) → PLAY,
/// com keep-alive por GET_PARAMETER. Todos os callbacks rodam na fila interna.
final class RTSPClient {
    var onTrack: ((SDPVideoTrack) -> Void)?
    var onRTP: ((Data) -> Void)?
    var onPlaying: (() -> Void)?
    var onFailure: ((RTSPError) -> Void)?

    let queue = DispatchQueue(label: "vmsnext.rtsp", qos: .userInitiated)

    private let url: String
    private let host: String
    private let port: UInt16
    private let username: String
    private let password: String

    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var cseq = 0
    private var pending: [Int: (RTSPResponse) -> Void] = [:]
    private var auth: RTSPAuth?
    private var session: String?
    private var sessionTimeout: TimeInterval = 60
    private var timer: DispatchSourceTimer?
    private var lastPacket = Date()
    private var lastKeepAlive = Date()
    private var finished = false

    init(url: String, host: String, port: Int, username: String, password: String) {
        self.url = url
        self.host = host
        self.port = UInt16(clamping: port)
        self.username = username
        self.password = password
    }

    func start() {
        queue.async { [self] in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 554, using: .tcp)
            connection = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    receive()
                    sendOptions()
                case let .waiting(error), let .failed(error):
                    fail(.connection(error.localizedDescription))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            if session != nil { send(method: "TEARDOWN", uri: url) }
            shutdown()
        }
    }

    // MARK: - Sequência RTSP

    private func sendOptions() {
        request("OPTIONS", uri: url) { [weak self] _ in self?.sendDescribe() }
    }

    private func sendDescribe() {
        request("DESCRIBE", uri: url, headers: ["Accept": "application/sdp"]) { [weak self] response in
            guard let self else { return }
            let sdp = String(decoding: response.body, as: UTF8.self)
            do {
                let track = try SDPParser.videoTrack(from: sdp)
                let base = response.header("Content-Base") ?? response.header("Content-Location") ?? url
                onTrack?(track)
                sendSetup(uri: Self.resolve(control: track.control, base: base))
            } catch let error as RTSPError {
                fail(error)
            } catch {
                fail(.noVideoTrack)
            }
        }
    }

    private func sendSetup(uri: String) {
        request("SETUP", uri: uri, headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]) { [weak self] response in
            guard let self else { return }
            if let value = response.header("Session") {
                let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                session = parts.first
                for part in parts.dropFirst() where part.lowercased().hasPrefix("timeout=") {
                    sessionTimeout = TimeInterval(part.dropFirst("timeout=".count)) ?? sessionTimeout
                }
            }
            sendPlay()
        }
    }

    private func sendPlay() {
        request("PLAY", uri: url, headers: ["Range": "npt=0.000-"]) { [weak self] _ in
            guard let self else { return }
            lastPacket = Date()
            lastKeepAlive = Date()
            startTimer()
            onPlaying?()
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, !finished else { return }
            if Date().timeIntervalSince(lastPacket) > 10 {
                fail(.stalled)
                return
            }
            if Date().timeIntervalSince(lastKeepAlive) > max(10, sessionTimeout / 2) {
                lastKeepAlive = Date()
                send(method: "GET_PARAMETER", uri: url)
            }
        }
        t.resume()
        timer = t
    }

    // MARK: - Envio

    /// Envia a requisição e, se receber 401 com desafio, repete uma vez autenticado.
    private func request(_ method: String, uri: String, headers: [String: String] = [:], retried: Bool = false,
                         completion: @escaping (RTSPResponse) -> Void)
    {
        let seq = send(method: method, uri: uri, headers: headers)
        pending[seq] = { [weak self] response in
            guard let self else { return }
            switch response.status {
            case 200:
                completion(response)
            case 401 where !retried:
                guard let challenge = response.header("WWW-Authenticate"),
                      let newAuth = RTSPAuth(challenge: challenge, username: username, password: password)
                else { return fail(.unauthorized) }
                auth = newAuth
                request(method, uri: uri, headers: headers, retried: true, completion: completion)
            case 401:
                fail(.unauthorized)
            default:
                fail(.badStatus(response.status, method))
            }
        }
    }

    @discardableResult
    private func send(method: String, uri: String, headers: [String: String] = [:]) -> Int {
        cseq += 1
        var text = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: VMSNext/0.1\r\n"
        if var a = auth {
            text += "Authorization: \(a.header(method: method, uri: uri))\r\n"
            auth = a
        }
        if let session { text += "Session: \(session)\r\n" }
        for (key, value) in headers { text += "\(key): \(value)\r\n" }
        text += "\r\n"
        connection?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        return cseq
    }

    // MARK: - Recepção

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !finished else { return }
            if let data, !data.isEmpty {
                buffer.append(contentsOf: data)
                parseBuffer()
            }
            if let error { return fail(.connection(error.localizedDescription)) }
            if isComplete { return fail(.closed) }
            receive()
        }
    }

    private func parseBuffer() {
        var i = 0
        let n = buffer.count
        while i < n, !finished {
            if buffer[i] == 0x24 { // '$' = pacote interleaved
                guard n - i >= 4 else { break }
                let channel = buffer[i + 1]
                let length = Int(buffer[i + 2]) << 8 | Int(buffer[i + 3])
                guard n - i - 4 >= length else { break }
                if channel == 0 {
                    lastPacket = Date()
                    onRTP?(Data(buffer[(i + 4) ..< (i + 4 + length)]))
                }
                i += 4 + length
            } else if Self.isLetter(buffer[i]) {
                guard let headerEnd = Self.findHeaderEnd(buffer, from: i) else { break }
                let headerText = String(decoding: buffer[i ..< headerEnd], as: UTF8.self)
                var lines = headerText.components(separatedBy: "\r\n")
                let statusLine = lines.removeFirst()
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let bodyStart = headerEnd + 4
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                guard n - bodyStart >= contentLength else { break }
                let body = Data(buffer[bodyStart ..< (bodyStart + contentLength)])
                i = bodyStart + contentLength

                // Requisições enviadas pelo servidor (não começam com "RTSP/") são ignoradas.
                guard statusLine.hasPrefix("RTSP/") else { continue }
                let parts = statusLine.split(separator: " ")
                let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                if let seq = headers["cseq"].flatMap({ Int($0) }), let handler = pending.removeValue(forKey: seq) {
                    handler(RTSPResponse(status: status, headers: headers, body: body))
                }
            } else {
                i += 1
            }
        }
        if i > 0 { buffer.removeFirst(min(i, buffer.count)) }
    }

    // MARK: - Encerramento

    private func fail(_ error: RTSPError) {
        guard !finished else { return }
        finished = true
        shutdown()
        onFailure?(error)
    }

    private func shutdown() {
        timer?.cancel()
        timer = nil
        pending.removeAll()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    // MARK: - Utilidades

    static func resolve(control: String, base: String) -> String {
        if control.isEmpty || control == "*" { return base }
        if control.lowercased().hasPrefix("rtsp://") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }

    private static func isLetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    private static func findHeaderEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var j = start
        while j + 3 < bytes.count {
            if bytes[j] == 0x0D, bytes[j + 1] == 0x0A, bytes[j + 2] == 0x0D, bytes[j + 3] == 0x0A { return j }
            j += 1
        }
        return nil
    }
}
