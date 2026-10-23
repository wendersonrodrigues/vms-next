import Foundation
import Network

/// Segunda conexão TCP que recebe vídeo: é "reivindicada" (Claim) com o SessionID da sessão principal,
/// e o vídeo chega em mensagens de dados. Uma mensagem vazia marca o fim (reprodução).
final class DVRIPMediaConnection: @unchecked Sendable {
    /// Códigos de cada tipo de transmissão.
    struct Kind {
        let name: String
        let claimCode: UInt16
        let dataCode: UInt16

        /// Ao vivo: Claim 1413 (resposta 1414), dados 1412.
        static let monitor = Kind(name: "OPMonitor", claimCode: 1413, dataCode: 1412)
        /// Reprodução/download: Claim 1424 (resposta 1425), dados 1426.
        static let playback = Kind(name: "OPPlayBack", claimCode: 1424, dataCode: 1426)
    }

    var onData: ((Data) -> Void)?
    var onEnd: (() -> Void)?
    var onFailure: ((DVRIPError) -> Void)?

    private let host: String
    private let port: UInt16
    private let kind: Kind
    private let queue = DispatchQueue(label: "vmsnext.dvrip.media")
    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var claimContinuation: CheckedContinuation<Void, Error>?
    private var paused = false
    private var receiving = false
    private var finished = false
    private(set) var bytesReceived = 0

    init(host: String, port: Int, kind: Kind = .playback) {
        self.host = host
        self.port = UInt16(clamping: port)
        self.kind = kind
    }

    /// Conecta e envia o Claim; retorna quando o equipamento aceitar.
    func claim(session: UInt32, sessionString: String, parameters: [String: Any]) async throws {
        var payload = parameters
        payload["Action"] = "Claim"
        let body = try JSONSerialization.data(withJSONObject: [
            "Name": kind.name, "SessionID": sessionString, kind.name: payload,
        ])
        let claimCode = kind.claimCode
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                claimContinuation = continuation
                let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 34567, using: .tcp)
                connection = conn
                conn.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let frame = DVRIPClient.makeFrame(session: session, sequence: 0, code: claimCode, body: body)
                        conn.send(content: frame, completion: .contentProcessed { _ in })
                        receive()
                    case let .waiting(error), let .failed(error):
                        fail(.connection(error.localizedDescription))
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, claimContinuation != nil else { return }
                    fail(.timeout)
                }
            }
        }
    }

    /// Pausa a leitura do socket (o TCP segura o envio do equipamento) até `resume()`.
    func pause() { queue.async { [self] in paused = true } }

    func resume() {
        queue.async { [self] in
            paused = false
            if !receiving { receive() }
        }
    }

    func close() {
        queue.async { [self] in
            finished = true
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
        }
    }

    private func receive() {
        guard !finished, !paused, let connection else { return }
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !finished else { return }
            receiving = false
            if let data, !data.isEmpty {
                buffer.append(contentsOf: data)
                parse()
            }
            if let error { return fail(.connection(error.localizedDescription)) }
            if isComplete { return end() }
            receive()
        }
    }

    private func parse() {
        while buffer.count >= 20, !finished {
            guard buffer[0] == 0xFF else {
                buffer.removeFirst()
                continue
            }
            let code = UInt16(buffer[14]) | UInt16(buffer[15]) << 8
            let length = Int(buffer[16]) | Int(buffer[17]) << 8 | Int(buffer[18]) << 16 | Int(buffer[19]) << 24
            guard buffer.count >= 20 + length else { return }
            let body = Data(buffer[20 ..< 20 + length])
            buffer.removeFirst(20 + length)

            switch code {
            case kind.claimCode + 1: // resposta do Claim
                var json = [UInt8](body)
                while let last = json.last, last == 0 || last == 0x0A { json.removeLast() }
                let ret = (try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any])?["Ret"] as? Int ?? 0
                if ret == 100 {
                    claimContinuation?.resume()
                    claimContinuation = nil
                } else {
                    fail(.device(ret))
                }
            case kind.dataCode:
                if length == 0 { return end() }
                bytesReceived += length
                onData?(body)
            default:
                break
            }
        }
    }

    private func end() {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        onEnd?()
    }

    private func fail(_ error: DVRIPError) {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        if let continuation = claimContinuation {
            claimContinuation = nil
            continuation.resume(throwing: error)
        } else {
            onFailure?(error)
        }
    }
}
