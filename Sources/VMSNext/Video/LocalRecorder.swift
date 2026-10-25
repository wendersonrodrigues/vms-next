import AVFoundation
import Foundation

/// Gravação no disco do Mac ("Config. de gravação" do VMS antigo): grava o vídeo principal da câmera em
/// MP4, em arquivos de N minutos, respeitando a reserva de espaço (para ou apaga os mais antigos).
/// Pode ser manual (botão de gravar) ou automática num intervalo de horário.
@MainActor
final class LocalRecorder: ObservableObject {
    static let shared = LocalRecorder()

    /// Câmeras gravando agora (manual ou automática).
    @Published private(set) var recording: Set<Camera.ID> = []
    @Published private(set) var lastError: String?

    private final class Session: @unchecked Sendable {
        let camera: Camera
        let key: String
        let automatic: Bool
        var writer: MP4FrameWriter?
        var url: URL?
        var started = Date()
        var clockStart: CFTimeInterval?
        var waitingKeyframe = true
        let queue = DispatchQueue(label: "vmsnext.record")

        init(camera: Camera, key: String, automatic: Bool) {
            self.camera = camera
            self.key = key
            self.automatic = automatic
        }
    }

    private var sessions: [Camera.ID: Session] = [:]
    private var timer: Timer?
    private weak var store: CameraStore?

    func isRecording(_ camera: Camera) -> Bool { recording.contains(camera.id) }

    /// Começa a rotina: troca de arquivo, reserva de disco e o horário da gravação automática.
    func start(store: CameraStore) {
        self.store = store
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { LocalRecorder.shared.tick() }
        }
        tick()
    }

    func toggle(_ camera: Camera) {
        if sessions[camera.id] != nil { stop(camera.id) } else { begin(camera, automatic: false) }
    }

    // MARK: - Sessões

    private func begin(_ camera: Camera, automatic: Bool) {
        guard sessions[camera.id] == nil, let store, let password = store.password(for: camera) else {
            if store?.password(for: camera) == nil { lastError = String(localized: "Senha de \(camera.displayName) não definida.") }
            return
        }
        let key = LiveStreamHub.key(camera, .main)
        let hub = LiveStreamHub.shared
        let stream = hub.stream(for: key)
        if hub.acquire(key, name: camera.displayName) || stream.status == .idle {
            stream.start(camera: camera, quality: .main, password: password, source: store.resolvedLiveSource(for: camera))
        }
        let session = Session(camera: camera, key: key, automatic: automatic)
        sessions[camera.id] = session
        recording.insert(camera.id)
        guard openFile(session) else { return }
        stream.tap.set(
            video: { [weak session] nalus, codec in
                guard let session else { return }
                session.queue.async { Self.write(nalus, codec: codec, to: session) }
            },
            audio: { [weak session] data, codec in
                guard let session else { return }
                session.queue.async { session.writer?.appendAudio(data, codec: codec) }
            })
        AppLog.shared.add(.recording, "Gravação no Mac iniciada\(automatic ? " (automática)" : "")", device: camera.displayName)
    }

    private func stop(_ id: Camera.ID, reason: String? = nil) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        recording.remove(id)
        let hub = LiveStreamHub.shared
        hub.stream(for: session.key).tap.set(video: nil, audio: nil)
        hub.release(session.key)
        session.queue.async { session.writer?.finish { _ in } }
        AppLog.shared.add(.recording, reason ?? "Gravação no Mac parada", device: session.camera.displayName)
    }

    func stopAll() {
        for id in sessions.keys { stop(id) }
    }

    /// Novo arquivo: <pasta>/<câmera>/<câmera> <data hora>.mp4
    @discardableResult
    private func openFile(_ session: Session) -> Bool {
        let prefs = AppPreferences.shared
        guard ensureSpace() else {
            stop(session.camera.id, reason: String(localized: "Gravação no Mac parada: disco do Mac com pouco espaço (reserva de \(prefs.recordReserveMB) MB)"))
            lastError = String(localized: "Pouco espaço no Mac: a gravação parou.")
            return false
        }
        let folder = prefs.recordingFolder.appendingPathComponent(session.camera.displayName.replacingOccurrences(of: "/", with: "-"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(session.camera.displayName) \(AppPreferences.stamp(Date())).mp4".replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(name)
        let writer = MP4FrameWriter(url: url)
        let old = session.writer
        session.queue.async {
            old?.finish { _ in }
            session.writer = writer
            session.url = url
            session.clockStart = nil
            session.waitingKeyframe = true
        }
        session.started = Date()
        return true
    }

    /// Roda na fila da sessão. Só começa num quadro completo (com SPS/VPS), como o arquivo exige.
    nonisolated private static func write(_ nalus: [Data], codec: VideoCodec, to session: Session) {
        guard let writer = session.writer else { return }
        if session.waitingKeyframe {
            let hasParameters = nalus.contains { nal in
                guard let first = nal.first else { return false }
                return codec == .h265 ? (first >> 1) & 0x3F == 32 : first & 0x1F == 7
            }
            guard hasParameters else { return }
            session.waitingKeyframe = false
        }
        let now = CACurrentMediaTime()
        if session.clockStart == nil { session.clockStart = now }
        let time = CMTime(seconds: now - (session.clockStart ?? now), preferredTimescale: 1000)
        writer.append(XMMediaParser.Frame(nalus: nalus, isKeyframe: false, timestamp: nil), codec: codec, fps: 25, time: time)
    }

    // MARK: - Rotina

    private func tick() {
        let prefs = AppPreferences.shared
        // Troca de arquivo a cada N minutos.
        for session in sessions.values where Date().timeIntervalSince(session.started) >= Double(prefs.recordFileMinutes * 60) {
            openFile(session)
        }
        // Gravação automática no intervalo de horário.
        guard let store else { return }
        let inWindow = prefs.autoRecord && Self.isInside(prefs.autoRecordFrom, prefs.autoRecordTo)
        let wanted = Set(store.cameras.filter { prefs.autoRecordAll || prefs.autoRecordCameras.contains($0.id) }.map(\.id))
        for (id, session) in sessions where session.automatic && (!inWindow || !wanted.contains(id)) {
            stop(id, reason: String(localized: "Gravação automática parada (fora do horário)"))
        }
        if inWindow {
            for camera in store.cameras where wanted.contains(camera.id) && sessions[camera.id] == nil {
                begin(camera, automatic: true)
            }
        }
    }

    /// Minutos desde a meia-noite; intervalos que passam da meia-noite também valem (ex.: 22:00 às 06:00).
    static func isInside(_ from: Int, _ to: Int, now: Date = Date()) -> Bool {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return from <= to ? (minute >= from && minute <= to) : (minute >= from || minute <= to)
    }

    /// Garante a reserva de espaço no disco do Mac. Com "Sobrescrever", apaga as gravações mais antigas.
    private func ensureSpace() -> Bool {
        let prefs = AppPreferences.shared
        let folder = prefs.recordingFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func freeMB() -> Int {
            let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return Int((values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_048_576)
        }
        if freeMB() >= prefs.recordReserveMB { return true }
        guard prefs.recordOverwrite else { return false }
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.creationDateKey])?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "mp4" }
            .sorted { (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast) ?? .distantPast
                < (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast) ?? .distantPast }
        let open = Set(sessions.values.compactMap(\.url))
        for file in files where !open.contains(file) {
            try? FileManager.default.removeItem(at: file)
            AppLog.shared.add(.recording, "Gravação antiga apagada para liberar espaço: \(file.lastPathComponent)")
            if freeMB() >= prefs.recordReserveMB { return true }
        }
        return freeMB() >= prefs.recordReserveMB
    }
}
