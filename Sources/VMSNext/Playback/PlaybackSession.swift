import AVFoundation
import Foundation

/// Reproduz um arquivo de gravação: Claim na conexão de mídia, Start na sessão principal,
/// e os quadros são exibidos no ritmo do fps gravado (com velocidade ajustável).
///
/// Para pular para um ponto, a transmissão recomeça pedindo o arquivo a partir dele. Se o equipamento
/// mandar desde o início mesmo assim, os quadros anteriores são descartados aqui, e a exibição começa
/// no quadro-chave (I) mais próximo antes do ponto.
@MainActor
final class PlaybackSession: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case playing
        case paused
        case finished
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var recording: Recording?
    @Published private(set) var clock: Date?
    @Published private(set) var info = ""
    @Published var speed: Double = 1
    /// Enquanto o usuário arrasta a barra, ela mostra `scrubPosition` em vez do relógio.
    @Published var scrubbing = false
    @Published var scrubPosition: Double = 0

    let displayLayer = AVSampleBufferDisplayLayer()

    private var camera: Camera?
    private var client: DVRIPClient?
    private var media: DVRIPMediaConnection?
    private var parser = XMMediaParser()
    private var builder: SampleBufferBuilder?
    private var queue: [XMMediaParser.Frame] = []
    private var pacer: Timer?
    private var framesShown = 0
    private var lastKeyTime: Date?
    private var framesSinceKey = 0
    private var streamEnded = false
    private var generation = 0
    private var stopAction = "Stop"
    /// Ponto pedido num salto; quadros anteriores ao GOP que o contém são descartados.
    private var seekTarget: Date?
    /// Quadros desde o último quadro-chave, guardados enquanto se procura o ponto do salto.
    private var gop: [XMMediaParser.Frame] = []

    var duration: TimeInterval {
        guard let recording else { return 0 }
        return max(recording.end.timeIntervalSince(recording.begin), 1)
    }

    /// Segundos desde o início do arquivo, pelo relógio do vídeo.
    var position: TimeInterval {
        guard let recording, let clock else { return 0 }
        return min(max(clock.timeIntervalSince(recording.begin), 0), duration)
    }

    private let maxQueued = 300
    private let resumeBelow = 100

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func play(_ recording: Recording, camera: Camera, from start: Date? = nil) async {
        stop(keepImage: start != nil)
        generation += 1
        let token = generation
        self.recording = recording
        self.camera = camera
        status = .connecting
        if start == nil { info = "" }
        seekTarget = start
        clock = start

        let parser = XMMediaParser()
        self.parser = parser
        // O parser roda na main queue (FIFO), então a ordem dos quadros e do fim do arquivo é preservada.
        parser.onFrame = { [weak self] frame in
            MainActor.assumeIsolated { self?.enqueue(frame, token: token) }
        }

        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            self.client = client
            let media = DVRIPMediaConnection(host: camera.host, port: camera.dvripPort, kind: .playback)
            self.media = media
            media.onData = { data in DispatchQueue.main.async { parser.push(data) } }
            media.onEnd = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamDidEnd(token: token) } }
            }
            media.onFailure = { [weak self] error in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(error.localizedDescription, token: token) } }
            }

            let playback = playbackParameters(recording, from: start)
            try await media.claim(session: client.sessionValue, sessionString: client.sessionString, parameters: playback)
            // DownloadStart envia o arquivo o mais rápido que o TCP permitir; o ritmo (e a velocidade)
            // fica por conta do pacer. Se o equipamento não aceitar, usa Start (tempo real).
            var start = playback
            start["Action"] = "DownloadStart"
            do {
                try await client.command(code: 1420, name: "OPPlayBack", payload: start)
                stopAction = "DownloadStop"
            } catch DVRIPError.device {
                start["Action"] = "Start"
                try await client.command(code: 1420, name: "OPPlayBack", payload: start)
                stopAction = "Stop"
            }
            guard token == generation else { return }
            status = .playing
            startPacer()
        } catch {
            fail(error.localizedDescription, token: token)
        }
    }

    func togglePause() {
        switch status {
        case .playing:
            status = .paused
            pacer?.invalidate()
        case .paused:
            status = .playing
            startPacer()
        default:
            break
        }
    }

    /// Pula para `offset` segundos do início do arquivo.
    func seek(to offset: TimeInterval) {
        guard let recording, let camera else { return }
        let clamped = min(max(offset, 0), max(duration - 1, 0))
        let target = recording.begin.addingTimeInterval(clamped)
        Task { await play(recording, camera: camera, from: target) }
    }

    func skip(by seconds: TimeInterval) {
        seek(to: position + seconds)
    }

    func stop(keepImage: Bool = false) {
        generation += 1
        pacer?.invalidate()
        pacer = nil
        media?.close()
        media = nil
        if let client, let recording {
            var stop = playbackParameters(recording)
            stop["Action"] = stopAction
            Task { _ = try? await client.command(code: 1420, name: "OPPlayBack", payload: stop) }
        }
        client = nil
        queue.removeAll()
        builder = nil
        framesShown = 0
        lastKeyTime = nil
        framesSinceKey = 0
        streamEnded = false
        seekTarget = nil
        gop.removeAll()
        clock = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: !keepImage, completionHandler: nil)
        status = .idle
    }

    func setSpeed(_ value: Double) {
        speed = value
        if status == .playing { startPacer() }
    }

    // MARK: - Recebimento e exibição

    private func playbackParameters(_ recording: Recording, from start: Date? = nil) -> [String: Any] {
        [
            "Parameter": [
                "PlayMode": "ByName",
                "FileName": recording.fileName,
                "StreamType": 0,
                "Value": 0,
                "TransMode": "TCP",
                "IntelligentPlayBack": 0,
            ] as [String: Any],
            "StartTime": DeviceTime.string(start ?? recording.begin),
            "EndTime": DeviceTime.string(recording.end),
        ]
    }

    private func enqueue(_ frame: XMMediaParser.Frame, token: Int) {
        guard token == generation else { return }
        if let target = seekTarget {
            // Procurando o ponto do salto: guarda o GOP atual e começa quando o próximo I passar do alvo.
            if frame.isKeyframe, let time = frame.timestamp {
                if time >= target {
                    queue += (time == target || gop.isEmpty) ? [frame] : gop + [frame]
                    gop.removeAll()
                    seekTarget = nil
                } else {
                    gop = [frame]
                }
            } else if !gop.isEmpty {
                gop.append(frame)
            }
            return
        }
        queue.append(frame)
        if queue.count > maxQueued { media?.pause() }
    }

    private func startPacer() {
        pacer?.invalidate()
        let interval = 1.0 / (Double(max(parser.fps, 1)) * speed)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pacer = timer
    }

    private func tick() {
        guard status == .playing else { return }
        guard !queue.isEmpty else {
            if streamEnded { finish() }
            return
        }
        let frame = queue.removeFirst()
        if queue.count < resumeBelow { media?.resume() }

        if builder == nil, let codec = parser.codec {
            builder = SampleBufferBuilder(track: SDPVideoTrack(codec: codec, payloadType: 0, control: "", parameterSets: []))
            if let size = parser.resolution {
                info = "\(codec == .h265 ? "H.265" : "H.264") · \(size.width)×\(size.height) · \(parser.fps) fps"
            }
        }
        guard let builder else { return }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        if let sample = builder.makeSampleBuffer(nalus: frame.nalus, corrupted: false) {
            renderer.enqueue(sample)
            framesShown += 1
        }

        if frame.isKeyframe, let time = frame.timestamp {
            lastKeyTime = time
            framesSinceKey = 0
        } else {
            framesSinceKey += 1
        }
        if let key = lastKeyTime {
            clock = key.addingTimeInterval(Double(framesSinceKey) / Double(max(parser.fps, 1)))
        }
        // Se a pausa entre lotes for longa, ajusta o ritmo ao fps real informado.
        if framesShown == 30 { startPacer() }
    }

    private func streamDidEnd(token: Int) {
        guard token == generation else { return }
        streamEnded = true
        if seekTarget != nil {
            // O ponto ficou no último GOP do arquivo.
            queue += gop
            gop.removeAll()
            seekTarget = nil
        }
        if queue.isEmpty { finish() }
    }

    private func finish() {
        pacer?.invalidate()
        pacer = nil
        status = framesShown > 0 ? .finished : .failed("O equipamento não enviou vídeo para este arquivo.")
    }

    private func fail(_ message: String, token: Int) {
        guard token == generation else { return }
        pacer?.invalidate()
        pacer = nil
        status = .failed(message)
    }
}
