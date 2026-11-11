import CoreImage
import CoreMedia
import Foundation
import VideoToolbox

/// Sensibilidade da detecção de movimento feita no Mac.
enum MacMotionSensitivity: Int, CaseIterable, Identifiable {
    case low = 0, medium = 1, high = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .low: return String(localized: "Baixa")
        case .medium: return String(localized: "Média")
        case .high: return String(localized: "Alta")
        }
    }

    /// Diferença de brilho (0–255) para um pedaço da imagem contar como mudado.
    var cellThreshold: Float {
        switch self {
        case .low: return 30
        case .medium: return 20
        case .high: return 13
        }
    }

    /// Parte da imagem que precisa mudar para virar movimento.
    var minFraction: Float {
        switch self {
        case .low: return 0.025
        case .medium: return 0.01
        case .high: return 0.004
        }
    }
}

/// Detecção de movimento no próprio Mac, para câmeras que só mandam o vídeo (ex.: Yoosee pelo ONVIF): decodifica
/// os quadros e compara cada um com o fundo da cena, em pedaços. Mudança de luz na imagem toda (luz acesa, câmera
/// trocando para o infravermelho) não conta. Movimento vira início de alerta; 8 s parado, o fim.
///
/// Há câmeras (Yoosee) que aceitam um vídeo por vez: com a câmera aberta no mosaico (HD ou SD), a detecção usa
/// esse mesmo vídeo; só com ela fora da tela é que abre o vídeo por conta própria, e solta assim que um quadro abrir.
@MainActor
final class MacMotionWatcher {
    /// true = começou, false = terminou.
    var onMotion: ((Bool) -> Void)?

    let camera: Camera
    private let id = UUID()
    private var engine: MacMotionEngine?
    private var timer: Timer?
    private var password = ""
    private var source = LiveSource.rtsp
    /// Vídeo aberto pela própria detecção (nil = usando o de um quadro).
    private var ownKey: String?
    /// Vídeo de onde vêm os quadros agora.
    private var observedKey: String?
    /// Quando o próprio vídeo foi solto para um quadro (se o do quadro falhar logo em seguida, tenta de novo).
    private var handedOver: (key: String, date: Date)?

    init(camera: Camera) {
        self.camera = camera
    }

    var isRunning: Bool { engine != nil }

    func start(password: String, source: LiveSource, sensitivity: MacMotionSensitivity) {
        guard engine == nil else { return }
        self.password = password
        self.source = source
        let engine = MacMotionEngine(sensitivity: sensitivity)
        engine.onMotion = { [weak self] active in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onMotion?(active) } }
        }
        self.engine = engine
        MacMotion.engines[camera.id] = engine
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let prefix = "\(camera.id)-"
        LiveStreamHub.shared.acquireObservers[id] = { [weak self] key in
            guard key.hasPrefix(prefix) else { return }
            self?.reconcile()
        }
        reconcile()
    }

    func setSensitivity(_ sensitivity: MacMotionSensitivity) {
        engine?.sensitivity = sensitivity
    }

    /// Escolhe de onde vêm os quadros: um vídeo que algum quadro abriu (HD primeiro) ou, sem nenhum, o próprio.
    private func reconcile() {
        guard let engine else { return }
        let hub = LiveStreamHub.shared
        let keys = [StreamQuality.main, .sub].map { LiveStreamHub.key(camera, $0) }
        let shared = keys.first { hub.users($0) - ($0 == ownKey ? 1 : 0) > 0 }
        if let shared {
            observe(shared, engine: engine)
            if let own = ownKey, own != shared {
                // Solta o próprio vídeo para a câmera atender o do quadro.
                ownKey = nil
                hub.release(own)
                handedOver = (shared, Date())
            }
            // O quadro tentou conectar enquanto a câmera ainda estava ocupada com o vídeo da detecção e desistiu
            // (a Yoosee recusa a segunda conexão): conecta de novo, agora com a câmera livre.
            if let handed = handedOver, handed.key == shared, Date().timeIntervalSince(handed.date) < 20,
               case .failed(_, retrying: false) = hub.stream(for: shared).status {
                handedOver = nil
                let quality: StreamQuality = shared == keys[0] ? .main : .sub
                hub.stream(for: shared).start(camera: camera, quality: quality, password: password, source: source)
            }
            return
        }
        if ownKey == nil {
            let key = keys[0]
            let stream = hub.stream(for: key)
            if hub.acquire(key, name: camera.displayName) || stream.status == .idle {
                stream.start(camera: camera, quality: .main, password: password, source: source)
            }
            ownKey = key
        }
        if let ownKey { observe(ownKey, engine: engine) }
    }

    private func observe(_ key: String, engine: MacMotionEngine) {
        guard observedKey != key else { return }
        if let observedKey { LiveStreamHub.shared.stream(for: observedKey).observeFrames(id, nil) }
        observedKey = key
        LiveStreamHub.shared.stream(for: key).observeFrames(id) { sample in engine.push(sample) }
    }

    func stop() {
        guard let engine else { return }
        timer?.invalidate()
        timer = nil
        let hub = LiveStreamHub.shared
        hub.acquireObservers[id] = nil
        if let observedKey { hub.stream(for: observedKey).observeFrames(id, nil) }
        if let ownKey { hub.release(ownKey) }
        observedKey = nil
        ownKey = nil
        engine.close()
        if MacMotion.engines[camera.id] === engine { MacMotion.engines[camera.id] = nil }
        self.engine = nil
    }
}

/// Último quadro visto pela detecção de cada câmera (vira a foto do alerta).
@MainActor
enum MacMotion {
    static var engines: [Camera.ID: MacMotionEngine] = [:]

    static func latestImage(for camera: Camera) -> CGImage? {
        engines[camera.id]?.latestImage()
    }
}

/// Decodificador e comparação de quadros. Recebe os quadros na fila da conexão e trabalha na própria fila.
final class MacMotionEngine: @unchecked Sendable {
    var onMotion: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "vmsnext.macmotion", qos: .utility)
    private let lock = NSLock()
    private var _sensitivity: MacMotionSensitivity
    var sensitivity: MacMotionSensitivity {
        get { lock.withLock { _sensitivity } }
        set { lock.withLock { _sensitivity = newValue } }
    }

    // Só mexidos na fila.
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var closed = false
    private var lastAnalysis = Date.distantPast
    private var background: [Float] = []
    private var warmup = 0
    private var hits = 0
    private var active = false
    private var lastMotion = Date.distantPast
    private var pending = 0

    // Lido de fora (foto do alerta).
    private var latest: CVPixelBuffer?
    private var latestDate = Date.distantPast

    /// Pedaços da imagem comparados (colunas × linhas).
    private static let columns = 64
    private static let rows = 36
    /// Comparações por segundo.
    private static let interval: TimeInterval = 0.4

    init(sensitivity: MacMotionSensitivity) {
        _sensitivity = sensitivity
    }

    func push(_ sample: CMSampleBuffer) {
        // Sem fila crescendo: se o Mac estiver atrasado, quadros novos esperam o próximo quadro-chave.
        let busy = lock.withLock { () -> Bool in
            if pending > 30 { return true }
            pending += 1
            return false
        }
        if busy { return }
        queue.async { [self] in
            lock.withLock { pending -= 1 }
            decode(sample)
        }
    }

    func close() {
        queue.async { [self] in
            closed = true
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            if active { active = false; onMotion?(false) }
        }
        lock.withLock { latest = nil }
    }

    /// Último quadro analisado, se for recente.
    func latestImage() -> CGImage? {
        let (buffer, date) = lock.withLock { (latest, latestDate) }
        guard let buffer, Date().timeIntervalSince(date) < 5 else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(image, from: image.extent)
    }

    // MARK: - Decodificação

    private func decode(_ sample: CMSampleBuffer) {
        guard !closed, let description = CMSampleBufferGetFormatDescription(sample) else { return }
        if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: description) }) ?? true {
            makeSession(description)
        }
        guard let session else { return }
        var info = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: &info) {
            [weak self] status, _, image, _, _ in
            guard status == noErr, let image, let self else { return }
            // O decodificador pode responder em outra thread: a comparação fica sempre na fila.
            self.queue.async { self.received(image) }
        }
        if status == kVTInvalidSessionErr { self.session = nil }
    }

    private func makeSession(_ description: CMFormatDescription) {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = description
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &created)
        if status == noErr { session = created }
        // Vídeo recomeçou (outro formato): o fundo da cena é refeito.
        background = []
        warmup = 0
    }

    // MARK: - Comparação

    private func received(_ buffer: CVPixelBuffer) {
        guard !closed else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= Self.interval else { return }
        lastAnalysis = now
        lock.withLock { latest = buffer; latestDate = now }
        guard let cells = Self.cells(buffer) else { return }
        analyze(cells, now: now)
    }

    /// Brilho médio de cada pedaço da imagem (amostras do plano Y).
    private static func cells(_ buffer: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        guard width >= columns, height >= rows else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let cellWidth = width / columns
        let cellHeight = height / rows
        // Até 4×4 amostras por pedaço: rápido e suficiente para um brilho médio.
        let stepX = max(cellWidth / 4, 1)
        let stepY = max(cellHeight / 4, 1)
        var result = [Float](repeating: 0, count: columns * rows)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                var sum = 0
                var count = 0
                var y = row * cellHeight
                while y < (row + 1) * cellHeight {
                    var x = column * cellWidth
                    let line = pixels + y * stride
                    while x < (column + 1) * cellWidth {
                        sum += Int(line[x])
                        count += 1
                        x += stepX
                    }
                    y += stepY
                }
                result[row * columns + column] = count > 0 ? Float(sum) / Float(count) : 0
            }
        }
        return result
    }

    private func analyze(_ cells: [Float], now: Date) {
        guard background.count == cells.count else {
            background = cells
            warmup = 0
            return
        }
        warmup += 1
        let count = Float(cells.count)
        // Mudança de luz por igual na imagem toda não é movimento: desconta a diferença média.
        let shift = zip(cells, background).reduce(Float(0)) { $0 + ($1.0 - $1.1) } / count
        let sensitivity = self.sensitivity
        var changed = 0
        for index in cells.indices where abs(cells[index] - background[index] - shift) > sensitivity.cellThreshold {
            changed += 1
        }
        let fraction = Float(changed) / count
        if fraction > 0.55 {
            // A imagem toda mudou (infravermelho, câmera virou): recomeça o fundo.
            background = cells
            hits = 0
            return
        }
        // O fundo acompanha a cena devagar (mais devagar ainda com movimento, para quem parou não sumir na hora).
        let rate: Float = fraction >= sensitivity.minFraction ? 0.02 : 0.08
        for index in cells.indices { background[index] += (cells[index] - background[index]) * rate }
        // Os primeiros segundos só aprendem a cena.
        guard warmup > 8 else { return }
        if fraction >= sensitivity.minFraction {
            hits += 1
            if hits >= 2 {
                lastMotion = now
                if !active {
                    active = true
                    onMotion?(true)
                }
            }
        } else {
            hits = 0
            if active, now.timeIntervalSince(lastMotion) > 8 {
                active = false
                onMotion?(false)
            }
        }
    }
}
