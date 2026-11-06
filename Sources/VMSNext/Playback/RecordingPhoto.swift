import AppKit
import Foundation

/// Fotos guardadas no cartão/HD (OPFileQuery com Type "jpg"): o arquivo vem pelo mesmo caminho do download
/// de vídeo (OPPlayBack DownloadStart, dados em 1426), numa sessão DVRIP própria.
enum RecordingPhoto {
    enum Failure: LocalizedError {
        case noPassword, empty

        var errorDescription: String? {
            switch self {
            case .noPassword: return String(localized: "Senha da câmera não definida.")
            case .empty: return String(localized: "O equipamento não mandou a foto.")
            }
        }
    }

    /// Bytes da foto (JPEG). Os dados podem vir com cabeçalho de mídia na frente: guarda do primeiro FFD8 ao último FFD9.
    @MainActor
    static func fetch(_ recording: Recording, camera: Camera) async throws -> Data {
        guard let password = Vault.shared.password(for: camera.keychainAccount) else { throw Failure.noPassword }
        let client = DVRIPClient(host: camera.host, port: camera.dvripPort)
        try await client.connect()
        defer { client.close() }
        try await client.login(username: camera.username, password: password)

        let media = DVRIPMediaConnection(host: camera.host, port: camera.dvripPort, kind: .playback)
        let collector = Collector()
        let parameters: [String: Any] = [
            "Parameter": [
                "PlayMode": "ByName", "FileName": recording.fileName, "StreamType": recording.stream,
                "Value": 0, "TransMode": "TCP", "IntelligentPlayBack": 0,
            ] as [String: Any],
            "StartTime": DeviceTime.string(recording.begin),
            "EndTime": DeviceTime.string(recording.end),
        ]
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            collector.continuation = continuation
            media.onData = { collector.append($0) }
            media.onEnd = { collector.finish(nil) }
            media.onFailure = { collector.finish($0) }
            Task { @MainActor in
                do {
                    try await media.claim(session: client.sessionValue, sessionString: client.sessionString, parameters: parameters)
                    var start = parameters
                    start["Action"] = "DownloadStart"
                    try await client.command(code: 1420, name: "OPPlayBack", payload: start)
                    // Alguns equipamentos não mandam a mensagem de fim para fotos: 10 s bastam para um JPEG.
                    try? await Task.sleep(for: .seconds(10))
                    collector.finish(nil)
                } catch {
                    collector.finish(error)
                }
            }
        }
        media.close()
        guard let jpeg = Self.jpeg(in: data) else { throw Failure.empty }
        return jpeg
    }

    static func jpeg(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let start = bytes.indices.dropLast().first(where: { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 }) else { return nil }
        let end = bytes.indices.dropLast().last(where: { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD9 }).map { $0 + 2 } ?? bytes.count
        guard end > start else { return nil }
        return Data(bytes[start ..< end])
    }

    /// Junta os bytes e devolve uma vez só (fim da transmissão, falha ou tempo esgotado).
    private final class Collector: @unchecked Sendable {
        var continuation: CheckedContinuation<Data, Error>?
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func finish(_ error: Error?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            let result = data
            lock.unlock()
            guard let pending else { return }
            if let error, result.isEmpty { pending.resume(throwing: error) } else { pending.resume(returning: result) }
        }
    }
}
