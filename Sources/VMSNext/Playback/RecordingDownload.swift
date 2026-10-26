import AVFoundation
import Foundation

/// Baixa um arquivo de gravação e salva em MP4 sem recomprimir: os quadros H.264/H.265 do formato
/// da Xiongmai são reempacotados com AVAssetWriter (passthrough), no ritmo de fps do arquivo; o áudio G.711,
/// se houver, vira AAC. Usa uma sessão DVRIP própria, para não interferir na reprodução em andamento.
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
            state = .failed(String(localized: "Senha da câmera não definida."))
            return
        }
        try? FileManager.default.removeItem(at: url)
        let writer = MP4FrameWriter(url: url)
        self.writer = writer
        let expected = max(Double(recording.sizeKB) * 1024, 1)
        let parser = XMMediaParser()
        parser.onFrame = { frame in writer.append(frame, codec: parser.codec, fps: parser.fps) }
        parser.onAudio = { data, codec in writer.appendAudio(data, codec: codec) }

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
            DownloadedRecordings.shared.mark(recording, camera: camera, url: url)
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

/// Escreve quadros em MP4 (vídeo sem recomprimir e, se houver, áudio G.711 convertido para AAC).
/// O arquivo só é criado depois de saber se há áudio: espera o primeiro bloco de áudio ou 2 s de vídeo.
/// Chamado sempre da mesma fila (a da conexão de mídia).
final class MP4FrameWriter: @unchecked Sendable {
    /// O áudio de 8 kHz é dobrado para 16 kHz, taxa que o codificador AAC aceita em qualquer Mac.
    private static let audioRate = 16000

    private let url: URL
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?
    private var builder: SampleBufferBuilder?
    private var videoFormat: CMFormatDescription?
    private var frameIndex: Int64 = 0
    private var fps: Int32 = 25
    private var cancelled = false

    private var audioSeen = false
    private var bufferedVideo: [CMSampleBuffer] = []
    private var pendingAudio: [Int16] = []
    private var audioSampleIndex: Int64 = 0
    private var lastVideoTime: CMTime?

    init(url: URL) {
        self.url = url
    }

    /// `time`: momento real do quadro (gravação ao vivo); sem ele, conta pelo fps do arquivo.
    func append(_ frame: XMMediaParser.Frame, codec: VideoCodec?, fps: Int, time: CMTime? = nil) {
        guard !cancelled, let codec else { return }
        if builder == nil {
            builder = SampleBufferBuilder(track: SDPVideoTrack(codec: codec, payloadType: 0, control: "", parameterSets: []))
            self.fps = Int32(max(fps, 1))
        }
        let pts = time ?? CMTime(value: frameIndex, timescale: self.fps)
        guard lastVideoTime == nil || pts > lastVideoTime! else { return }
        lastVideoTime = pts
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: self.fps),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        guard let sample = builder?.makeSampleBuffer(nalus: frame.nalus, corrupted: false, timing: timing) else { return }
        frameIndex += 1

        guard writer != nil else {
            if videoFormat == nil { videoFormat = CMSampleBufferGetFormatDescription(sample) }
            bufferedVideo.append(sample)
            if audioSeen || bufferedVideo.count >= Int(self.fps) * 2 { startWriter() }
            return
        }
        appendVideo(sample)
    }

    func appendAudio(_ data: Data, codec: AudioCodec) {
        guard !cancelled else { return }
        audioSeen = true
        let samples = Self.upsample(G711.decode(data, codec: codec))
        guard writer != nil else {
            pendingAudio += samples
            return
        }
        appendAudioSamples(samples)
    }

    func finish(_ completion: @escaping @Sendable (String?) -> Void) {
        if writer == nil, !bufferedVideo.isEmpty { startWriter() }
        guard !cancelled, let writer, let videoInput else {
            completion(cancelled ? nil : String(localized: "O equipamento não enviou vídeo para este arquivo."))
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let videoEnd = lastVideoTime.map { $0 + CMTime(value: 1, timescale: fps) } ?? CMTime(value: frameIndex, timescale: fps)
        let audioEnd = CMTime(value: audioSampleIndex, timescale: Int32(Self.audioRate))
        writer.endSession(atSourceTime: CMTimeMaximum(videoEnd, audioEnd))
        writer.finishWriting {
            completion(writer.status == .completed ? nil : (writer.error?.localizedDescription ?? String(localized: "Falha ao salvar o MP4.")))
        }
    }

    func cancel() {
        cancelled = true
        writer?.cancelWriting()
    }

    // MARK: - Escrita

    private func startWriter() {
        guard let videoFormat, let newWriter = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        video.expectsMediaDataInRealTime = true
        newWriter.add(video)
        if audioSeen {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.audioRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000,
            ])
            audio.expectsMediaDataInRealTime = true
            if newWriter.canAdd(audio) {
                newWriter.add(audio)
                audioInput = audio
            }
        }
        guard newWriter.startWriting() else { return }
        newWriter.startSession(atSourceTime: .zero)
        writer = newWriter
        videoInput = video
        bufferedVideo.forEach(appendVideo)
        bufferedVideo.removeAll()
        if !pendingAudio.isEmpty {
            appendAudioSamples(pendingAudio)
            pendingAudio.removeAll()
        }
    }

    private func appendVideo(_ sample: CMSampleBuffer) {
        guard let videoInput else { return }
        Self.waitUntilReady(videoInput)
        videoInput.append(sample)
    }

    private func appendAudioSamples(_ samples: [Int16]) {
        guard let audioInput, !samples.isEmpty, let sample = makeAudioSample(samples) else { return }
        Self.waitUntilReady(audioInput)
        if audioInput.append(sample) { audioSampleIndex += Int64(samples.count) }
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput) {
        var waited = 0
        while !input.isReadyForMoreMediaData, waited < 2000 {
            usleep(1000)
            waited += 1
        }
    }

    /// PCM 16 bits mono como CMSampleBuffer, com o tempo contado em amostras.
    private func makeAudioSample(_ samples: [Int16]) -> CMSampleBuffer? {
        if audioFormat == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(Self.audioRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &audioFormat)
        }
        guard let audioFormat else { return nil }
        let length = samples.count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat,
            sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: audioSampleIndex, timescale: Int32(Self.audioRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }

    /// 8 kHz → 16 kHz: repete cada amostra intercalando a média com a seguinte.
    private static func upsample(_ samples: [Int16]) -> [Int16] {
        var output: [Int16] = []
        output.reserveCapacity(samples.count * 2)
        for (index, value) in samples.enumerated() {
            output.append(value)
            let next = index + 1 < samples.count ? samples[index + 1] : value
            output.append(Int16((Int(value) + Int(next)) / 2))
        }
        return output
    }
}
