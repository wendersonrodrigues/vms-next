import AVFoundation
import Foundation

/// Baixa um arquivo de gravação e salva em MP4 sem recomprimir: os quadros H.264/H.265 do formato
/// da Xiongmai são reempacotados com AVAssetWriter (passthrough), no ritmo de fps do arquivo.
/// Usa uma sessão DVRIP própria, para não interferir na reprodução em andamento. Sem áudio.
@MainActor
final class RecordingDownload: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let recording: Recording
    let camera: Camera
    let url: URL

    @Published private(set) var state = State.running
    @Published private(set) var progress: Double = 0

    private var client: DVRIPClient?
    private var media: DVRIPMediaConnection?
    private var writer: MP4FrameWriter?

    init(recording: Recording, camera: Camera, url: URL) {
        self.recording = recording
        self.camera = camera
        self.url = url
    }

    var title: String { url.lastPathComponent }

    func start() async {
        guard let password = Vault.shared.password(for: camera.keychainAccount) else {
            state = .failed("Senha da câmera não definida.")
            return
        }
        try? FileManager.default.removeItem(at: url)
        let writer = MP4FrameWriter(url: url)
        self.writer = writer
        let expected = max(Double(recording.sizeKB) * 1024, 1)
        let parser = XMMediaParser()
        parser.onFrame = { frame in writer.append(frame, codec: parser.codec, fps: parser.fps) }

        do {
            let client = DVRIPClient(host: camera.host, port: camera.dvripPort)
            self.client = client
            try await client.connect()
            try await client.login(username: camera.username, password: password)

            let media = DVRIPMediaConnection(host: camera.host, port: camera.dvripPort, kind: .playback)
            self.media = media
            var received = 0
            var reported = 0
            media.onData = { [weak self] data in
                parser.push(data)
                received += data.count
                if received - reported > 256 * 1024 {
                    reported = received
                    let value = min(Double(received) / expected, 0.99)
                    DispatchQueue.main.async { self?.progress = value }
                }
            }
            media.onEnd = { [weak self] in
                writer.finish { error in
                    DispatchQueue.main.async { self?.writerDidFinish(error) }
                }
            }
            media.onFailure = { [weak self] error in
                writer.cancel()
                DispatchQueue.main.async { self?.end(.failed(error.localizedDescription)) }
            }

            let parameters: [String: Any] = [
                "Parameter": [
                    "PlayMode": "ByName", "FileName": recording.fileName, "StreamType": 0,
                    "Value": 0, "TransMode": "TCP", "IntelligentPlayBack": 0,
                ] as [String: Any],
                "StartTime": DeviceTime.string(recording.begin),
                "EndTime": DeviceTime.string(recording.end),
            ]
            try await media.claim(session: client.sessionValue, sessionString: client.sessionString, parameters: parameters)
            var start = parameters
            start["Action"] = "DownloadStart"
            try await client.command(code: 1420, name: "OPPlayBack", payload: start)
        } catch {
            writer.cancel()
            end(.failed(error.localizedDescription))
        }
    }

    func cancel() {
        guard state == .running else { return }
        media?.close()
        writer?.cancel()
        try? FileManager.default.removeItem(at: url)
        end(.cancelled)
    }

    private func writerDidFinish(_ error: String?) {
        if let error {
            try? FileManager.default.removeItem(at: url)
            end(.failed(error))
        } else {
            progress = 1
            end(.finished)
        }
    }

    private func end(_ state: State) {
        guard self.state == .running else { return }
        self.state = state
        client?.close()
        client = nil
        media = nil
    }
}

/// Escreve quadros em MP4. Chamado sempre da mesma fila (a da conexão de mídia).
final class MP4FrameWriter: @unchecked Sendable {
    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var builder: SampleBufferBuilder?
    private var frameIndex: Int64 = 0
    private var fps: Int32 = 25
    private var cancelled = false

    init(url: URL) {
        self.url = url
    }

    func append(_ frame: XMMediaParser.Frame, codec: VideoCodec?, fps: Int) {
        guard !cancelled, let codec else { return }
        if builder == nil {
            builder = SampleBufferBuilder(track: SDPVideoTrack(codec: codec, payloadType: 0, control: "", parameterSets: []))
            self.fps = Int32(max(fps, 1))
        }
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: self.fps),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: self.fps),
            decodeTimeStamp: .invalid
        )
        guard let sample = builder?.makeSampleBuffer(nalus: frame.nalus, corrupted: false, timing: timing) else { return }

        if writer == nil {
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  let newWriter = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
            let newInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            newInput.expectsMediaDataInRealTime = false
            newWriter.add(newInput)
            guard newWriter.startWriting() else { return }
            newWriter.startSession(atSourceTime: .zero)
            writer = newWriter
            input = newInput
        }
        guard let input else { return }
        var waited = 0
        while !input.isReadyForMoreMediaData, waited < 2000 {
            usleep(1000)
            waited += 1
        }
        if input.append(sample) { frameIndex += 1 }
    }

    func finish(_ completion: @escaping @Sendable (String?) -> Void) {
        guard !cancelled, let writer, let input else {
            completion(cancelled ? nil : "O equipamento não enviou vídeo para este arquivo.")
            return
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: frameIndex, timescale: fps))
        writer.finishWriting {
            completion(writer.status == .completed ? nil : (writer.error?.localizedDescription ?? "Falha ao salvar o MP4."))
        }
    }

    func cancel() {
        cancelled = true
        writer?.cancelWriting()
    }
}
