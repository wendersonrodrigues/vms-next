import CryptoKit
import Foundation
import Network

enum DVRIPError: LocalizedError {
    case connection(String)
    case closed
    case timeout
    case authFailed
    case device(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .connection(message): return "Falha de conexão: \(message)"
        case .closed: return "A câmera encerrou a sessão"
        case .timeout: return "A câmera não respondeu"
        case .authFailed: return "Usuário ou senha incorretos"
        case let .device(code): return "A câmera recusou o comando (código \(code))"
        case .invalidResponse: return "Resposta inválida da câmera"
        }
    }

    /// A conexão caiu ou a câmera parou de responder (ex.: depois de trocar de IP).
    var isDisconnect: Bool {
        switch self {
        case .closed, .timeout, .connection: return true
        default: return false
        }
    }
}

/// Sessão no protocolo DVRIP ("Sofia") da Xiongmai, porta 34567.
///
/// Cada mensagem tem um cabeçalho de 20 bytes (little-endian) seguido de JSON terminado em "\n\0":
/// 0xFF, versão, 2 reservados, SessionID (u32), sequência (u32), 2 reservados, código (u16), tamanho (u32).
/// A resposta de um comando vem com o código + 1.
/// Todo o estado mutável é acessado apenas na fila serial `queue`.
final class DVRIPClient: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "vmsnext.dvrip")

    private var connection: NWConnection?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var buffer: [UInt8] = []
    private var sessionID: UInt32 = 0
    private var sequence: UInt32 = 0
    private var waiters: [(id: Int, code: UInt16, continuation: CheckedContinuation<[String: Any], Error>)] = []
    private var nextWaiterID = 0
    private var keepAlive: DispatchSourceTimer?
    private var closed = false

    /// Mensagens enviadas pelo equipamento sem pedido (ex.: alarmes, código 1504). Chamado na fila interna.
    var onPush: ((_ code: UInt16, _ json: [String: Any]) -> Void)?

    init(host: String, port: Int) {
        self.host = host
        self.port = UInt16(clamping: port)
    }

    var isClosed: Bool { queue.sync { closed } }

    // MARK: - Conexão e login

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                connectContinuation = continuation
                let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 34567, using: .tcp)
                connection = conn
                conn.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        connectContinuation?.resume()
                        connectContinuation = nil
                        receive()
                    case let .waiting(error), let .failed(error):
                        shutdown(.connection(error.localizedDescription))
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, connectContinuation != nil else { return }
                    shutdown(.timeout)
                }
            }
        }
    }

    func login(username: String, password: String) async throws {
        let response = try await send(code: 1000, json: [
            "EncryptType": "MD5",
            "LoginType": "DVRIP-Web",
            "UserName": username,
            "PassWord": Self.sofiaHash(password),
        ])
        let ret = response["Ret"] as? Int ?? 0
        guard ret == 100 else {
            close()
            throw (ret == 203 || ret == 205) ? DVRIPError.authFailed : DVRIPError.device(ret)
        }
        let alive = response["AliveInterval"] as? Int ?? 20
        if let text = response["SessionID"] as? String {
            let hex = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
            let id = UInt32(hex, radix: 16) ?? 0
            queue.async { [self] in
                sessionID = id
                startKeepAlive(every: max(5, alive))
            }
        }
    }

    // MARK: - Comandos

    /// Envia um comando no formato {"Name": nome, "SessionID": ..., nome: payload}.
    @discardableResult
    func command(code: UInt16, name: String, payload: Any?, accepted: Set<Int> = [100]) async throws -> [String: Any] {
        var json: [String: Any] = ["Name": name, "SessionID": sessionString]
        if let payload { json[name] = payload }
        let response = try await send(code: code, json: json)
        let ret = response["Ret"] as? Int ?? 0
        guard accepted.contains(ret) else {
            throw DVRIPError.device(ret)
        }
        return response
    }

    /// Pede ao equipamento para enviar os alarmes nesta sessão (GUARD, código 1500).
    /// Depois disso, cada alarme chega como mensagem 1504 com "AlarmInfo".
    func subscribeAlarms() async throws {
        try await command(code: 1500, name: "", payload: nil)
    }

    /// Lê uma configuração (CONFIG_GET, código 1042), ex.: "Camera.Param.[0]".
    func getConfig(_ name: String) async throws -> Any {
        let response = try await command(code: 1042, name: name, payload: nil)
        guard let value = response[name] else { throw DVRIPError.invalidResponse }
        return value
    }

    /// Grava uma configuração (CONFIG_SET, código 1040). 603 = salvo, efetivo após reiniciar.
    func setConfig(_ name: String, _ value: Any) async throws {
        try await command(code: 1040, name: name, payload: value, accepted: [100, 603])
    }

    func close() {
        queue.async { [self] in shutdown(.closed) }
    }

    // MARK: - Envio e recepção

    /// SessionID do login, usado também pela conexão de mídia da reprodução (Claim).
    var sessionValue: UInt32 { queue.sync { sessionID } }

    var sessionString: String { String(format: "0x%08X", sessionValue) }

    private func send(code: UInt16, json: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !closed, let connection else {
                    continuation.resume(throwing: DVRIPError.closed)
                    return
                }
                nextWaiterID += 1
                let id = nextWaiterID
                waiters.append((id, code + 1, continuation))
                connection.send(content: frame(code: code, body: body), completion: .contentProcessed { _ in })
                queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, waiters.contains(where: { $0.id == id }) else { return }
                    shutdown(.timeout)
                }
            }
        }
    }

    private func frame(code: UInt16, body: Data) -> Data {
        let data = Self.makeFrame(session: sessionID, sequence: sequence, code: code, body: body)
        sequence &+= 1
        return data
    }

    static func makeFrame(session: UInt32, sequence: UInt32, code: UInt16, body: Data) -> Data {
        var data = Data([0xFF, 0x00, 0x00, 0x00])
        appendLE(&data, session)
        appendLE(&data, sequence)
        data.append(contentsOf: [0x00, 0x00])
        appendLE(&data, code)
        appendLE(&data, UInt32(body.count + 2))
        data.append(body)
        data.append(contentsOf: [0x0A, 0x00])
        return data
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !closed else { return }
            if let data, !data.isEmpty {
                buffer.append(contentsOf: data)
                parseBuffer()
            }
            if let error { return shutdown(.connection(error.localizedDescription)) }
            if isComplete { return shutdown(.closed) }
            receive()
        }
    }

    private func parseBuffer() {
        while buffer.count >= 20 {
            guard buffer[0] == 0xFF else {
                buffer.removeFirst()
                continue
            }
            let code = UInt16(buffer[14]) | UInt16(buffer[15]) << 8
            let length = Int(buffer[16]) | Int(buffer[17]) << 8 | Int(buffer[18]) << 16 | Int(buffer[19]) << 24
            guard buffer.count >= 20 + length else { return }
            var body = Array(buffer[20 ..< 20 + length])
            buffer.removeFirst(20 + length)

            while let last = body.last, last == 0x00 || last == 0x0A { body.removeLast() }
            guard let index = waiters.firstIndex(where: { $0.code == code }) else {
                if let json = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] {
                    onPush?(code, json)
                }
                continue
            }
            let waiter = waiters.remove(at: index)
            if let json = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] {
                waiter.continuation.resume(returning: json)
            } else {
                waiter.continuation.resume(throwing: DVRIPError.invalidResponse)
            }
        }
    }

    private func startKeepAlive(every seconds: Int) {
        keepAlive?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
        timer.setEventHandler { [weak self] in
            guard let self, !closed else { return }
            let session = String(format: "0x%08X", sessionID)
            Task { _ = try? await self.send(code: 1006, json: ["Name": "KeepAlive", "SessionID": session]) }
        }
        timer.resume()
        keepAlive = timer
    }

    private func shutdown(_ error: DVRIPError) {
        guard !closed else { return }
        closed = true
        keepAlive?.cancel()
        keepAlive = nil
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume(throwing: error) }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    // MARK: - Hash de senha

    /// Hash de 8 caracteres usado no login DVRIP: MD5 da senha, bytes somados aos pares, mapeados em [0-9A-Za-z].
    static func sofiaHash(_ password: String) -> String {
        let digest = Array(Insecure.MD5.hash(data: Data(password.utf8)))
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return String((0 ..< 8).map { i in alphabet[(Int(digest[2 * i]) + Int(digest[2 * i + 1])) % 62] })
    }
}
