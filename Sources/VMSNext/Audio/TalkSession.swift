import AVFoundation
import Foundation

/// Conversa: o som do microfone do Mac sai no alto-falante da câmera. Como o SDK do VMS antigo:
/// Claim "OPTalk" numa conexão de mídia (1434), "Start" na sessão principal (1430) e o áudio em
/// blocos G.711 lei A de 8 kHz, cada um com o cabeçalho de áudio Xiongmai (00 00 01 FA), na mensagem 1432.
@MainActor
final class TalkSession: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case talking
        case failed(String)
    }

    static let shared = TalkSession()

    @Published private(set) var status: Status = .idle
    /// Câmera com a conversa aberta (só uma por vez).
    @Published private(set) var cameraID: Camera.ID?
    /// Nível do microfone (0…1), para o botão mostrar que está captando.
    @Published private(set) var level: Float = 0

    private var client: DVRIPClient?
    private var media: DVRIPMediaConnection?
    private var engine: AVAudioEngine?
    private var format: [String: Any] = [:]
    private var pending: [UInt8] = []

    /// Bloco enviado: 320 amostras = 40 ms a 8 kHz.
    private static let chunk = 320

    func isTalking(_ camera: Camera) -> Bool { cameraID == camera.id && status != .idle }

    func toggle(_ camera: Camera) {
        if cameraID == camera.id, status != .idle { stop() } else { Task { await start(camera) } }
    }

    func start(_ camera: Camera) async {
        stop()
        cameraID = camera.id
        status = .connecting
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            status = .failed(String(localized: "Sem acesso ao microfone. Libere o VMS Next em Ajustes do Sistema → Privacidade e Segurança → Microfone."))
            return
        }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            self.client = client
            // Formato que a própria câmera informa (TalkAudioFormat); padrão G.711 lei A, 8 kHz.
            var format: [String: Any] = ["EncodeType": "G711_ALAW", "BitRate": 128, "SampleRate": 8000, "SampleBit": 16]
            if let reported = (try? await client.command(code: 1360, name: "TalkAudioFormat", payload: nil))?["TalkAudioFormat"] as? [[String: Any]],
               let first = reported.first {
                for key in ["BitRate", "SampleRate", "SampleBit"] { if let value = first[key] { format[key] = value } }
                if let types = first["EncodeType"] as? [String], let type = types.first { format["EncodeType"] = type }
            }
            self.format = format
            let media = DVRIPMediaConnection(host: camera.host, port: camera.dvripPort, kind: .talk)
            self.media = media
            try await media.claim(session: client.sessionValue, sessionString: client.sessionString,
                                  parameters: ["AudioFormat": format])
            try await client.command(code: 1430, name: "OPTalk", payload: ["Action": "Start", "AudioFormat": format])
            try startMicrophone()
            status = .talking
            AppLog.shared.add(.device, "Conversa iniciada", device: camera.displayName)
        } catch {
            let message = error.localizedDescription
            stop()
            cameraID = camera.id
            status = .failed(String(localized: "Não foi possível falar com a câmera: \(message)"))
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let client, status == .talking {
            let format = format
            Task { _ = try? await client.command(code: 1430, name: "OPTalk", payload: ["Action": "Stop", "AudioFormat": format]) }
        }
        media?.close()
        media = nil
        client = nil
        pending.removeAll()
        level = 0
        status = .idle
        cameraID = nil
    }

    // MARK: - Microfone

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw DVRIPError.invalidResponse
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            let ratio = target.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let samples = output.int16ChannelData?[0] else { return }
            let pcm = Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            let peak = pcm.reduce(0) { max($0, abs(Int($1))) }
            let encoded = pcm.map(G711.alaw)
            DispatchQueue.main.async { self?.push(encoded, peak: Float(peak) / 32768) }
        }
        try engine.start()
        self.engine = engine
    }

    private func push(_ bytes: [UInt8], peak: Float) {
        guard status == .talking || status == .connecting, let media else { return }
        level = level * 0.6 + peak * 0.4
        pending += bytes
        while pending.count >= Self.chunk {
            let block = Array(pending.prefix(Self.chunk))
            pending.removeFirst(Self.chunk)
            // Cabeçalho de áudio: 00 00 01 FA, tipo 0x0E (G.711 lei A), taxa 0x02 (8 kHz), tamanho (2 bytes).
            var frame: [UInt8] = [0x00, 0x00, 0x01, 0xFA, 0x0E, 0x02, UInt8(block.count & 0xFF), UInt8(block.count >> 8)]
            frame += block
            media.send(code: 1432, body: Data(frame))
        }
    }
}

/// Codificação G.711 lei A (o inverso da decodificação que toca o som das câmeras).
extension G711 {
    static func alaw(_ sample: Int16) -> UInt8 {
        var pcm = Int(sample) >> 3
        let sign: Int
        if pcm >= 0 { sign = 0xD5 } else { sign = 0x55; pcm = -pcm - 1 }
        let segments = [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF]
        let segment = segments.firstIndex { pcm <= $0 } ?? 8
        if segment >= 8 { return UInt8(0x7F ^ sign) }
        var value = segment << 4
        value |= segment < 2 ? (pcm >> 1) & 0x0F : (pcm >> segment) & 0x0F
        return UInt8((value ^ sign) & 0xFF)
    }
}
