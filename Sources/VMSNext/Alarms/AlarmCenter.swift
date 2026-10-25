import AppKit
import Foundation
import UserNotifications

/// Um alarme recebido de uma câmera ou NVR.
struct AlarmEvent: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let deviceTime: String?
    let cameraName: String
    let cameraID: Camera.ID?
    let channel: Int
    /// Nome do evento como o equipamento envia (ex.: "VideoMotion", "HumanDetect").
    let event: String
    let isStart: Bool

    var kind: AlarmKind { AlarmKind(event: event) }
}

/// Tipos de alarme agrupados para as preferências de notificação.
enum AlarmKind: String, CaseIterable, Identifiable {
    case person, motion, videoLoss, blind, storage, other

    var id: String { rawValue }

    init(event: String) {
        let name = event.lowercased()
        if name.contains("human") || name.contains("humanoid") || name.contains("person") || name.contains("people") || name.contains("pedestrian") || name.contains("face") {
            self = .person
        } else if name.contains("motion") || name.contains("pir") {
            self = .motion
        } else if name.contains("loss") {
            self = .videoLoss
        } else if name.contains("blind") || name.contains("cover") {
            self = .blind
        } else if name.contains("storage") || name.contains("disk") || name.contains("hdd") {
            self = .storage
        } else {
            self = .other
        }
    }

    var label: String {
        switch self {
        case .person: return "Pessoa detectada"
        case .motion: return "Movimento"
        case .videoLoss: return "Perda de vídeo"
        case .blind: return "Câmera bloqueada"
        case .storage: return "Problema no disco"
        case .other: return "Outros alarmes"
        }
    }

    var icon: String {
        switch self {
        case .person: return "figure.walk"
        case .motion: return "wave.3.right"
        case .videoLoss: return "video.slash"
        case .blind: return "eye.slash"
        case .storage: return "internaldrive"
        case .other: return "bell"
        }
    }
}

/// Recebe os alarmes de todos os equipamentos, guarda o histórico e envia notificações do macOS.
@MainActor
final class AlarmCenter: ObservableObject {
    static let shared = AlarmCenter()

    /// Histórico de alertas, guardado no Mac (events.json) para continuar depois de fechar o app.
    @Published private(set) var events: [AlarmEvent] = [] {
        didSet { scheduleSave() }
    }
    private var saveWork: DispatchWorkItem?
    private static let historyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VMSNext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.json")
    }()

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = events
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.historyURL, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }
    /// Estado da inscrição por equipamento (usuário@host:porta) para exibir na tela.
    @Published private(set) var deviceStatus: [String: String] = [:]
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "alarms.enabled")
            if enabled { refresh() } else { stopAll() }
        }
    }
    @Published var notifyKinds: Set<AlarmKind> {
        didSet { defaults.set(notifyKinds.map(\.rawValue), forKey: "alarms.notify") }
    }
    /// Alertas ainda não vistos: aparecem no sino da barra e no ícone do Dock.
    @Published private(set) var unread = 0 {
        didSet { NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil }
    }
    /// Situação da permissão de notificações do macOS, para mostrar na tela de Eventos.
    @Published private(set) var notificationsAllowed: Bool?
    /// Pedido para abrir a tela de Eventos (ao clicar numa notificação).
    @Published var openEventsRequested = false
    /// Junta o alerta que chega pela câmera e pelo NVR (mesma câmera física) em um só.
    @Published var mergeDuplicates: Bool {
        didSet { defaults.set(mergeDuplicates, forKey: "alarms.merge") }
    }

    private let defaults = UserDefaults.standard
    private weak var store: CameraStore?
    private var subscribed: [String: DVRIPClient] = [:]
    private var timer: Timer?
    private var lastNotified: [String: Date] = [:]
    private var maxEvents: Int { AppPreferences.shared.maxEvents }
    private let notificationDelegate = NotificationDelegate()
    /// Último alerta por câmera física + tipo + início/fim, para juntar os repetidos.
    private var recent: [String: (date: Date, host: String)] = [:]

    private init() {
        enabled = defaults.object(forKey: "alarms.enabled") as? Bool ?? true
        let saved = defaults.stringArray(forKey: "alarms.notify")
        notifyKinds = Set((saved ?? [AlarmKind.person.rawValue, AlarmKind.videoLoss.rawValue, AlarmKind.storage.rawValue])
            .compactMap(AlarmKind.init(rawValue:)))
        mergeDuplicates = defaults.object(forKey: "alarms.merge") as? Bool ?? true
        loadSoundSettings()
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode([AlarmEvent].self, from: data) {
            events = saved
        }
    }

    func start(store: CameraStore) {
        self.store = store
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        notificationDelegate.onOpen = { [weak self] in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self?.openEventsRequested = true
            }
        }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.notificationsAllowed = granted }
        }
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func clear() {
        events.removeAll()
        AppLog.shared.add(.alarm, "Lista de alertas limpa")
        unread = 0
    }

    func markAllRead() {
        unread = 0
    }

    /// Abre os ajustes de notificações do macOS (para liberar o VMS Next se estiver bloqueado).
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Inscreve-se nos alarmes de cada equipamento (um por IP) e refaz a inscrição se a sessão caiu.
    func refresh() {
        guard enabled, let store else { return }
        var devices: [String: Camera] = [:]
        for camera in store.cameras where devices[deviceKey(camera)] == nil {
            devices[deviceKey(camera)] = camera
        }
        for (key, camera) in devices {
            if let client = subscribed[key], !client.isClosed { continue }
            subscribed[key] = nil
            Task { await subscribe(key: key, camera: camera) }
        }
    }

    // MARK: - Mesma câmera pela câmera e pelo NVR

    /// Câmera avulsa que é a mesma câmera física de um canal de NVR, ligada em Eventos ou em Editar câmera.
    /// (O NVR registra o próprio IP nos canais, então não dá para descobrir sozinho.)
    func physicalCamera(for camera: Camera) -> Camera? {
        guard camera.group != nil, let manual = camera.sameAs else { return nil }
        return store?.cameras.first { $0.id == manual }
    }

    private func stopAll() {
        subscribed.values.forEach { $0.onPush = nil }
        subscribed.removeAll()
        deviceStatus.removeAll()
    }

    private func deviceKey(_ camera: Camera) -> String {
        "\(camera.keychainAccount):\(camera.dvripPort)"
    }

    private func subscribe(key: String, camera: Camera) async {
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let host = camera.host
            client.onPush = { [weak self] code, json in
                guard code == 1504 else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(json, host: host) }
                }
            }
            try await client.subscribeAlarms()
            subscribed[key] = client
            deviceStatus[camera.group ?? camera.host] = String(localized: "Recebendo alertas")
        } catch {
            deviceStatus[camera.group ?? camera.host] = error.localizedDescription
        }
    }

    private func handle(_ json: [String: Any], host: String) {
        guard let info = json["AlarmInfo"] as? [String: Any] else { return }
        let channel = (ConfigValue.int(info["Channel"]) ?? 0) + 1
        let event = info["Event"] as? String ?? "Desconhecido"
        let isStart = (info["Status"] as? String ?? "Start").lowercased() != "stop"
        let source = store?.cameras.first { $0.host == host && $0.channel == channel }
            ?? store?.cameras.first { $0.host == host && $0.group == nil }
        // Com "juntar repetidos", o canal do NVR aparece como a câmera avulsa (ex.: "Sala") e o segundo aviso some.
        let physical = mergeDuplicates ? source.flatMap(physicalCamera(for:)) : nil
        let camera = physical ?? source
        if mergeDuplicates, let camera {
            let key = "\(camera.id)|\(AlarmKind(event: event).rawValue)|\(isStart)"
            if let last = recent[key], last.host != host, Date().timeIntervalSince(last.date) < 20 { return }
            recent[key] = (Date(), host)
        }
        let alarm = AlarmEvent(
            date: Date(),
            deviceTime: info["StartTime"] as? String,
            cameraName: camera?.displayName ?? "\(host) · canal \(channel)",
            cameraID: camera?.id,
            channel: channel,
            event: event,
            isStart: isStart
        )
        events.insert(alarm, at: 0)
        if events.count > maxEvents { events.removeLast(events.count - maxEvents) }
        if isStart {
            unread += 1
            notify(alarm)
        }
    }

    /// No máximo uma notificação por câmera e tipo a cada 60 s.
    // MARK: - Som no Mac

    /// Tipos que tocam um som no Mac quando chegam (como os sons de alarme do VMS antigo).
    @Published var soundKinds: Set<AlarmKind> = [] {
        didSet { defaults.set(soundKinds.map(\.rawValue), forKey: "alarms.soundKinds") }
    }
    /// Som de cada tipo: nome de um som do macOS ou caminho de um arquivo escolhido.
    @Published var sounds: [String: String] = [:] {
        didSet { defaults.set(sounds, forKey: "alarms.sounds") }
    }
    private var lastSound: [AlarmKind: Date] = [:]

    static let systemSounds = ["Glass", "Ping", "Sosumi", "Submarine", "Funk", "Hero", "Basso", "Blow", "Bottle", "Frog", "Morse", "Pop", "Purr", "Tink"]

    func sound(for kind: AlarmKind) -> String { sounds[kind.rawValue] ?? "Glass" }

    func playSound(for kind: AlarmKind) {
        let name = sound(for: kind)
        let sound = name.hasPrefix("/") ? NSSound(contentsOfFile: name, byReference: true) : NSSound(named: NSSound.Name(name))
        sound?.play()
    }

    private func loadSoundSettings() {
        soundKinds = Set((defaults.stringArray(forKey: "alarms.soundKinds") ?? []).compactMap(AlarmKind.init(rawValue:)))
        sounds = defaults.dictionary(forKey: "alarms.sounds") as? [String: String] ?? [:]
    }

    private func notify(_ alarm: AlarmEvent) {
        if soundKinds.contains(alarm.kind), Date().timeIntervalSince(lastSound[alarm.kind] ?? .distantPast) > 3 {
            lastSound[alarm.kind] = Date()
            playSound(for: alarm.kind)
        }
        guard notifyKinds.contains(alarm.kind) else { return }
        let throttleKey = "\(alarm.cameraName)|\(alarm.kind.rawValue)"
        if let last = lastNotified[throttleKey], Date().timeIntervalSince(last) < 60 { return }
        lastNotified[throttleKey] = Date()

        let content = UNMutableNotificationContent()
        content.title = alarm.kind == .other ? alarm.event : alarm.kind.label
        content.body = "\(alarm.cameraName) · \(alarm.date.formatted(date: .omitted, time: .standard))"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alarm.id.uuidString, content: content, trigger: nil))
    }
}

/// Mostra as notificações mesmo com o app em primeiro plano (o macOS esconde por padrão)
/// e abre a tela de Eventos ao clicar.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onOpen: (() -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        onOpen?()
        completionHandler()
    }
}
