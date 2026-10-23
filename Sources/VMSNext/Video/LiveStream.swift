import AVFoundation
import Foundation

enum StreamQuality: Int {
    case main = 0
    case sub = 1
}

/// Origem do vídeo ao vivo.
enum LiveSource: String, Codable, CaseIterable {
    /// RTSP, exceto câmeras de várias lentes (o RTSP delas ignora o canal), que usam DVRIP.
    case auto
    case rtsp
    /// Protocolo da Xiongmai (OPMonitor), o mesmo do VMS antigo.
    case dvrip
}

/// Conexão ao vivo de uma câmera: RTSP → RTP (ou DVRIP → quadros Xiongmai) → CMSampleBuffer → display layer,
/// com reconexão automática (exceto em erro de senha, para não bloquear a conta na câmera).
final class LiveStream: ObservableObject {
    enum Status: Equatable {
        case idle
        case needsPassword
        case connecting
        case playing
        case failed(String, retrying: Bool)
    }

    @Published private(set) var status: Status = .idle
    /// Dimensões do vídeo decodificado (para desenhar sobre a imagem na proporção certa).
    @Published private(set) var videoSize: CGSize?
    /// A câmera está mandando áudio (mostra o botão de alto-falante).
    @Published private(set) var hasAudio = false

    /// Identifica este vídeo no AudioFocus (só um toca por vez).
    let audioID = UUID()
    private let audio = AudioOutput()
    private let audioGate = AudioGate()

    let displayLayer = AVSampleBufferDisplayLayer()
    /// Todos os quadros vão para estes renderizadores: o principal e, no split virtual, o espelho.
    private let fanout = RendererFanout()
    /// Cópia dos quadros e do áudio para a gravação no Mac (LocalRecorder).
    let tap = FrameTap()
    private var mirror: AVSampleBufferDisplayLayer?

    /// Segunda camada com o mesmo vídeo (split virtual): a câmera continua mandando um vídeo só.
    func mirrorLayer() -> AVSampleBufferDisplayLayer {
        if let mirror { return mirror }
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        mirror = layer
        fanout.add(layer.sampleBufferRenderer)
        return layer
    }

    private var client: RTSPClient?
    private var media: DVRIPMediaConnection?
    private var monitorStop: (() -> Void)?
    private var watchdog: Timer?
    private let frameClock = FrameClock()
    private lazy var sizeReporter = SizeReporter { [weak self] size in
        DispatchQueue.main.async { self?.videoSize = size }
    }
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 2
    private var generation = 0

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        fanout.add(displayLayer.sampleBufferRenderer)
    }

    func start(camera: Camera, quality: StreamQuality, password: String?, source: LiveSource = .rtsp) {
        stop()
        guard let password else {
            status = .needsPassword
            return
        }
        generation += 1
        let token = generation
        status = .connecting

        if source == .dvrip {
            startMonitor(camera: camera, quality: quality, password: password, token: token)
            return
        }

        let client = RTSPClient(
            url: camera.rtspURL(password: password, quality: quality),
            host: camera.host, port: camera.rtspPort,
            username: camera.username, password: password
        )
        let renderer = fanout
        let reporter = sizeReporter
        let audio = self.audio
        let gate = audioGate
        var depacketizer: RTPDepacketizer?
        var audioTrack: SDPAudioTrack?
        client.onAudioTrack = { track in audioTrack = track }
        let tap = self.tap
        client.onAudioRTP = { [weak self] packet in
            guard let track = audioTrack, let payload = AudioGate.rtpPayload(packet) else { return }
            tap.audio(payload, track.codec)
            if gate.markSeen() { DispatchQueue.main.async { self?.hasAudio = true } }
            if gate.isOn { audio.play(G711.decode(payload, codec: track.codec), sampleRate: track.sampleRate) }
        }

        client.onTrack = { track in
            let builder = SampleBufferBuilder(track: track)
            let d = RTPDepacketizer(codec: track.codec)
            d.onAccessUnit = { nalus, corrupted in
                if !corrupted { tap.video(nalus, track.codec) }
                if let sample = builder.makeSampleBuffer(nalus: nalus, corrupted: corrupted) {
                    renderer.enqueue(sample)
                    reporter.report(sample)
                }
            }
            depacketizer = d
        }
        client.onRTP = { packet in depacketizer?.push(packet) }
        client.onPlaying = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.status = .playing
                self.retryDelay = 2
            }
        }
        client.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.client = nil
                if case .unauthorized = error {
                    self.status = .failed(error.localizedDescription, retrying: false)
                    return
                }
                self.status = .failed(error.localizedDescription, retrying: true)
                self.scheduleRetry(camera: camera, quality: quality, password: password, source: .rtsp)
            }
        }

        self.client = client
        client.start()
    }

    /// Liga ou desliga o som deste vídeo.
    func setAudio(_ on: Bool) {
        audioGate.isOn = on
        if !on { audio.stop() }
    }

    func stop() {
        audio.stop()
        generation += 1
        retryWork?.cancel()
        retryWork = nil
        client?.stop()
        client = nil
        watchdog?.invalidate()
        watchdog = nil
        media?.close()
        media = nil
        monitorStop?()
        monitorStop = nil
        fanout.flush()
        status = .idle
    }

    private func scheduleRetry(camera: Camera, quality: StreamQuality, password: String, source: LiveSource) {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.start(camera: camera, quality: quality, password: password, source: source)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Ao vivo pelo protocolo da Xiongmai (OPMonitor)

    /// Claim (1413) numa conexão de mídia, Start (1410) na sessão principal; o vídeo chega em 1412
    /// no mesmo formato de quadros da reprodução.
    private func startMonitor(camera: Camera, quality: StreamQuality, password: String, token: Int) {
        let parameters: [String: Any] = [
            "Channel": camera.channel - 1,
            "CombinMode": "NONE",
            "StreamType": quality == .main ? "Main" : "Extra1",
            "TransMode": "TCP",
        ]
        let renderer = fanout
        let reporter = sizeReporter
        let parser = XMMediaParser()
        let audio = self.audio
        let gate = audioGate
        let tap = self.tap
        parser.onAudio = { [weak self] data, codec in
            tap.audio(data, codec)
            if gate.markSeen() { DispatchQueue.main.async { self?.hasAudio = true } }
            if gate.isOn { audio.play(G711.decode(data, codec: codec), sampleRate: 8000) }
        }
        var builder: SampleBufferBuilder?
        let clock = frameClock
        clock.touch()
        // O parser roda na fila da conexão de mídia, sempre a mesma.
        parser.onFrame = { frame in
            if builder == nil, let codec = parser.codec {
                builder = SampleBufferBuilder(track: SDPVideoTrack(codec: codec, payloadType: 0, control: "", parameterSets: []))
            }
            guard let builder else { return }
            if let codec = parser.codec { tap.video(frame.nalus, codec) }
            if let sample = builder.makeSampleBuffer(nalus: frame.nalus, corrupted: false) {
                renderer.enqueue(sample)
                reporter.report(sample)
                clock.touch()
            }
        }

        let media = DVRIPMediaConnection(host: camera.host, port: camera.dvripPort, kind: .monitor)
        self.media = media
        media.onData = { parser.push($0) }
        let failure: (DVRIPError) -> Void = { [weak self] error in
            DispatchQueue.main.async { self?.monitorFailed(error, camera: camera, quality: quality, password: password, token: token) }
        }
        media.onEnd = { failure(.closed) }
        media.onFailure = failure

        Task { @MainActor [weak self] in
            do {
                let client = try await DeviceSessions.shared.client(for: camera)
                try await media.claim(session: client.sessionValue, sessionString: client.sessionString,
                                      parameters: ["Parameter": parameters])
                try await client.command(code: 1410, name: "OPMonitor", payload: ["Action": "Start", "Parameter": parameters])
                guard let self, self.generation == token else { return }
                self.monitorStop = {
                    Task { _ = try? await client.command(code: 1410, name: "OPMonitor", payload: ["Action": "Stop", "Parameter": parameters]) }
                }
                self.status = .playing
                self.retryDelay = 2
                self.startWatchdog(camera: camera, quality: quality, password: password, token: token)
            } catch let error as DVRIPError {
                failure(error)
            } catch {
                failure(.connection(error.localizedDescription))
            }
        }
    }

    private func startWatchdog(camera: Camera, quality: StreamQuality, password: String, token: Int) {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.generation == token else { return }
            if self.frameClock.secondsSinceLast > 12 {
                self.monitorFailed(.timeout, camera: camera, quality: quality, password: password, token: token)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func monitorFailed(_ error: DVRIPError, camera: Camera, quality: StreamQuality, password: String, token: Int) {
        guard generation == token else { return }
        watchdog?.invalidate()
        watchdog = nil
        media?.close()
        media = nil
        if case .authFailed = error {
            status = .failed(error.localizedDescription, retrying: false)
            return
        }
        status = .failed(error.localizedDescription, retrying: true)
        scheduleRetry(camera: camera, quality: quality, password: password, source: .dvrip)
    }
}

/// Momento do último quadro exibido, acessado de filas diferentes.
final class FrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() {
        lock.lock(); last = Date(); lock.unlock()
    }

    var secondsSinceLast: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

/// Avisa as dimensões do vídeo uma vez por mudança, a partir da fila de decodificação.
final class SizeReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: CGSize?
    private let onChange: (CGSize) -> Void

    init(onChange: @escaping (CGSize) -> Void) {
        self.onChange = onChange
    }

    func report(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        lock.lock()
        let changed = size != last
        last = size
        lock.unlock()
        if changed { onChange(size) }
    }
}

/// Estado do áudio acessado das filas de rede: ligado/desligado e "já chegou áudio".
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    private var seen = false

    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); on = newValue; lock.unlock() }
    }

    /// true só na primeira vez (para avisar a interface uma vez).
    func markSeen() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if seen { return false }
        seen = true
        return true
    }

    /// Conteúdo de um pacote RTP (sem cabeçalho, CSRC, extensão e padding).
    static func rtpPayload(_ packet: Data) -> Data? {
        let p = [UInt8](packet)
        guard p.count > 12, p[0] >> 6 == 2 else { return nil }
        var offset = 12 + Int(p[0] & 0x0F) * 4
        if p[0] & 0x10 != 0 {
            guard p.count >= offset + 4 else { return nil }
            offset += 4 + (Int(p[offset + 2]) << 8 | Int(p[offset + 3])) * 4
        }
        var end = p.count
        if p[0] & 0x20 != 0, let pad = p.last { end -= Int(pad) }
        guard offset < end else { return nil }
        return Data(p[offset ..< end])
    }
}

/// Entrega cada quadro a vários renderizadores (o decodificador do Mac trabalha uma vez por camada).
final class RendererFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var renderers: [AVSampleBufferVideoRenderer] = []

    func add(_ renderer: AVSampleBufferVideoRenderer) {
        lock.lock()
        renderers.append(renderer)
        lock.unlock()
    }

    func enqueue(_ sample: CMSampleBuffer) {
        lock.lock()
        let list = renderers
        lock.unlock()
        for renderer in list {
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        }
    }

    func flush() {
        lock.lock()
        let list = renderers
        lock.unlock()
        list.forEach { $0.flush(removingDisplayedImage: true, completionHandler: nil) }
    }
}

/// Entrega os quadros (NALUs) e o áudio do vídeo ao vivo a quem estiver gravando. Thread-safe.
final class FrameTap: @unchecked Sendable {
    private let lock = NSLock()
    private var videoHandler: (([Data], VideoCodec) -> Void)?
    private var audioHandler: ((Data, AudioCodec) -> Void)?

    func set(video: (([Data], VideoCodec) -> Void)?, audio: ((Data, AudioCodec) -> Void)?) {
        lock.lock()
        videoHandler = video
        audioHandler = audio
        lock.unlock()
    }

    func video(_ nalus: [Data], _ codec: VideoCodec) {
        lock.lock()
        let handler = videoHandler
        lock.unlock()
        handler?(nalus, codec)
    }

    func audio(_ data: Data, _ codec: AudioCodec) {
        lock.lock()
        let handler = audioHandler
        lock.unlock()
        handler?(data, codec)
    }
}
