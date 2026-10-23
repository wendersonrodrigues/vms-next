import AVFoundation
import Foundation

/// Reproduz um arquivo de gravação: Claim na conexão de mídia, Start na sessão principal,
/// e os quadros são exibidos no ritmo do fps gravado (com velocidade ajustável).
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

    private let maxQueued = 300
    private let resumeBelow = 100

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func play(_ recording: Recording, camera: Camera) async {
        stop()
        generation += 1
        let token = generation
        self.recording = recording
        self.camera = camera
        status = .connecting
        info = ""

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

            let playback = playbackParameters(recording)
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

    func stop() {
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
        clock = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        status = .idle
    }

    func setSpeed(_ value: Double) {
        speed = value
        if status == .playing { startPacer() }
    }

    // MARK: - Recebimento e exibição

    private func playbackParameters(_ recording: Recording) -> [String: Any] {
        [
            "Parameter": [
                "PlayMode": "ByName",
                "FileName": recording.fileName,
                "StreamType": 0,
                "Value": 0,
                "TransMode": "TCP",
                "IntelligentPlayBack": 0,
            ] as [String: Any],
            "StartTime": DeviceTime.string(recording.begin),
            "EndTime": DeviceTime.string(recording.end),
        ]
    }

    private func enqueue(_ frame: XMMediaParser.Frame, token: Int) {
        guard token == generation else { return }
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
