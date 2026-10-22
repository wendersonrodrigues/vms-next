import AVFoundation
import Foundation

enum StreamQuality: Int {
    case main = 0
    case sub = 1
}

/// Conexão ao vivo de uma câmera: RTSP → RTP → CMSampleBuffer → display layer,
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

    let displayLayer = AVSampleBufferDisplayLayer()

    private var client: RTSPClient?
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 2
    private var generation = 0

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func start(camera: Camera, quality: StreamQuality, password: String?) {
        stop()
        guard let password else {
            status = .needsPassword
            return
        }
        generation += 1
        let token = generation
        status = .connecting

        let client = RTSPClient(
            url: camera.rtspURL(password: password, quality: quality),
            host: camera.host, port: camera.rtspPort,
            username: camera.username, password: password
        )
        let renderer = displayLayer.sampleBufferRenderer
        var depacketizer: RTPDepacketizer?

        client.onTrack = { track in
            let builder = SampleBufferBuilder(track: track)
            let d = RTPDepacketizer(codec: track.codec)
            d.onAccessUnit = { nalus, corrupted in
                if renderer.status == .failed { renderer.flush() }
                if let sample = builder.makeSampleBuffer(nalus: nalus, corrupted: corrupted) {
                    renderer.enqueue(sample)
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
                self.scheduleRetry(camera: camera, quality: quality, password: password)
            }
        }

        self.client = client
        client.start()
    }

    func stop() {
        generation += 1
        retryWork?.cancel()
        retryWork = nil
        client?.stop()
        client = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        status = .idle
    }

    private func scheduleRetry(camera: Camera, quality: StreamQuality, password: String) {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.start(camera: camera, quality: quality, password: password)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
