import AppKit
import Foundation
import UniformTypeIdentifiers

/// Preferências gerais do app (a "Config. básica" do VMS antigo): pastas de fotos e downloads,
/// retomar onde parou, captura automática, relógio das câmeras e histórico de alertas.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private let defaults = UserDefaults.standard

    @Published var photoFolder: URL { didSet { defaults.set(photoFolder.path, forKey: "prefs.photoFolder") } }
    @Published var downloadFolder: URL { didSet { defaults.set(downloadFolder.path, forKey: "prefs.downloadFolder") } }
    /// Perguntar onde salvar cada foto e download (desligado = salva direto nas pastas acima).
    @Published var askWhereToSave: Bool { didSet { defaults.set(askWhereToSave, forKey: "prefs.ask") } }
    /// Ao abrir, volta para a mesma tela, câmera e modelo de tela de quando o app foi fechado.
    @Published var restoreState: Bool { didSet { defaults.set(restoreState, forKey: "prefs.restore") } }
    /// Qualidade ao abrir uma câmera em tela cheia (o mosaico usa sempre o vídeo extra).
    @Published var singleQualityHD: Bool { didSet { defaults.set(singleQualityHD, forKey: "prefs.singleHD") } }
    /// Acerta o relógio das câmeras com o do Mac ao abrir o app.
    @Published var syncDeviceClock: Bool { didSet { defaults.set(syncDeviceClock, forKey: "prefs.syncClock") } }
    /// Foto automática das câmeras na tela a cada `autoSnapshotSeconds`.
    @Published var autoSnapshot: Bool { didSet { defaults.set(autoSnapshot, forKey: "prefs.autoSnap"); AutoSnapshot.shared.reschedule() } }
    @Published var autoSnapshotSeconds: Int { didSet { defaults.set(autoSnapshotSeconds, forKey: "prefs.autoSnapSeconds"); AutoSnapshot.shared.reschedule() } }
    /// Quantos alertas o histórico guarda.
    @Published var maxEvents: Int { didSet { defaults.set(maxEvents, forKey: "prefs.maxEvents") } }
    // Gravação no Mac ("Config. de gravação" do VMS antigo).
    @Published var recordingFolder: URL { didSet { defaults.set(recordingFolder.path, forKey: "prefs.recFolder") } }
    /// Espaço que sempre fica livre no disco do Mac, em MB.
    @Published var recordReserveMB: Int { didSet { defaults.set(recordReserveMB, forKey: "prefs.recReserve") } }
    /// Duração de cada arquivo, em minutos.
    @Published var recordFileMinutes: Int { didSet { defaults.set(recordFileMinutes, forKey: "prefs.recMinutes") } }
    /// Disco cheio: true = apaga as gravações mais antigas; false = para de gravar.
    @Published var recordOverwrite: Bool { didSet { defaults.set(recordOverwrite, forKey: "prefs.recOverwrite") } }
    @Published var autoRecord: Bool { didSet { defaults.set(autoRecord, forKey: "prefs.autoRec") } }
    /// Intervalo da gravação automática, em minutos desde a meia-noite.
    @Published var autoRecordFrom: Int { didSet { defaults.set(autoRecordFrom, forKey: "prefs.autoRecFrom") } }
    @Published var autoRecordTo: Int { didSet { defaults.set(autoRecordTo, forKey: "prefs.autoRecTo") } }
    @Published var autoRecordAll: Bool { didSet { defaults.set(autoRecordAll, forKey: "prefs.autoRecAll") } }
    @Published var autoRecordCameras: Set<UUID> {
        didSet { defaults.set(autoRecordCameras.map(\.uuidString), forKey: "prefs.autoRecCameras") }
    }
    /// Por quantos dias o Registro do app é guardado.
    @Published var logDays: Int { didSet { defaults.set(logDays, forKey: "prefs.logDays") } }

    private init() {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("VMS Next")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("VMS Next")
        photoFolder = defaults.string(forKey: "prefs.photoFolder").map { URL(fileURLWithPath: $0) } ?? pictures
        downloadFolder = defaults.string(forKey: "prefs.downloadFolder").map { URL(fileURLWithPath: $0) } ?? downloads
        askWhereToSave = defaults.bool(forKey: "prefs.ask")
        restoreState = defaults.object(forKey: "prefs.restore") as? Bool ?? true
        singleQualityHD = defaults.object(forKey: "prefs.singleHD") as? Bool ?? true
        syncDeviceClock = defaults.bool(forKey: "prefs.syncClock")
        autoSnapshot = defaults.bool(forKey: "prefs.autoSnap")
        autoSnapshotSeconds = defaults.object(forKey: "prefs.autoSnapSeconds") as? Int ?? 300
        maxEvents = defaults.object(forKey: "prefs.maxEvents") as? Int ?? 500
        logDays = defaults.object(forKey: "prefs.logDays") as? Int ?? 30
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("VMS Next")
        recordingFolder = defaults.string(forKey: "prefs.recFolder").map { URL(fileURLWithPath: $0) } ?? movies
        recordReserveMB = defaults.object(forKey: "prefs.recReserve") as? Int ?? 5000
        recordFileMinutes = defaults.object(forKey: "prefs.recMinutes") as? Int ?? 30
        recordOverwrite = defaults.bool(forKey: "prefs.recOverwrite")
        autoRecord = defaults.bool(forKey: "prefs.autoRec")
        autoRecordFrom = defaults.object(forKey: "prefs.autoRecFrom") as? Int ?? 0
        autoRecordTo = defaults.object(forKey: "prefs.autoRecTo") as? Int ?? 23 * 60 + 59
        autoRecordAll = defaults.object(forKey: "prefs.autoRecAll") as? Bool ?? true
        autoRecordCameras = Set((defaults.stringArray(forKey: "prefs.autoRecCameras") ?? []).compactMap(UUID.init(uuidString:)))
    }

    /// Escolhe uma pasta pelo Finder.
    func chooseFolder(current: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = current
        panel.prompt = String(localized: "Escolher")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Onde salvar um arquivo: direto na pasta (com nome único) ou perguntando, conforme a preferência.
    /// Devolve nil se a pessoa cancelar.
    func destination(named name: String, in folder: URL, type: UTType) -> URL? {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let ext = type.preferredFilenameExtension ?? "dat"
        if askWhereToSave {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [type]
            panel.canCreateDirectories = true
            panel.directoryURL = folder
            panel.nameFieldStringValue = "\(clean).\(ext)"
            return panel.runModal() == .OK ? panel.url : nil
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(clean).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(clean) \(counter).\(ext)")
            counter += 1
        }
        return url
    }

    /// Data e hora para nomes de arquivo: 2026-10-23 10h17m15s.
    static func stamp(_ date: Date) -> String {
        date.formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))h\(minute: .twoDigits)m\(second: .twoDigits)s",
            timeZone: .current, calendar: .current))
    }
}

/// Captura automática: a cada intervalo, salva uma foto de cada câmera que está na tela em
/// <pasta de fotos>/Captura automática/<câmera>/.
@MainActor
final class AutoSnapshot {
    static let shared = AutoSnapshot()
    private var timer: Timer?

    func reschedule() {
        timer?.invalidate()
        timer = nil
        let prefs = AppPreferences.shared
        guard prefs.autoSnapshot else { return }
        let interval = TimeInterval(max(prefs.autoSnapshotSeconds, 10))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { AutoSnapshot.shared.captureAll() }
        }
    }

    private func captureAll() {
        let base = AppPreferences.shared.photoFolder.appendingPathComponent(String(localized: "Captura automática"))
        let stamp = AppPreferences.stamp(Date())
        for (name, stream) in LiveStreamHub.shared.active where stream.status == .playing {
            let folder = base.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = FrameSnapshot.jpeg(from: stream.displayLayer.sampleBufferRenderer, zoom: nil) else { continue }
            try? data.write(to: folder.appendingPathComponent("\(name) \(stamp).jpg".replacingOccurrences(of: "/", with: "-")))
        }
    }
}

/// Acerta o relógio de cada equipamento com o do Mac (uma vez ao abrir o app, se ligado).
@MainActor
enum ClockSync {
    private static var done = false

    static func runIfEnabled(store: CameraStore) {
        guard AppPreferences.shared.syncDeviceClock, !done else { return }
        done = true
        var seen = Set<String>()
        let devices = store.cameras.filter { seen.insert("\($0.host):\($0.dvripPort)").inserted }
        Task {
            for camera in devices where store.password(for: camera) != nil {
                guard let client = try? await DeviceSessions.shared.client(for: camera) else { continue }
                _ = try? await client.command(code: 1450, name: "OPTimeSetting", payload: DeviceTime.string(Date()))
            }
        }
    }
}
