import SwiftUI

/// Ações de um EventHandler (gravar, foto, avisos, saída de alarme…), tempos e período semanal.
/// Mesmos nomes e explicações da Detecção inteligente.
struct HandlerState {
    /// Canais acionados por uma ação (bit 0 = canal 1). No NVR o VMS antigo mostra como botões 1…N.
    struct ChannelMask: Identifiable {
        let key: String
        let title: String
        let original: String
        let detail: String
        var channels: Set<Int>
        var id: String { key }
    }

    static let maskSpecs: [(key: String, title: String, original: String, detail: String)] = [
        ("RecordMask", String(localized: "Gravar os canais"), String(localized: "Gravação"), String(localized: "Quais canais gravam quando este alarme dispara.")),
        ("SnapShotMask", String(localized: "Fotografar os canais"), String(localized: "Tirar foto"), String(localized: "Quais canais tiram foto quando este alarme dispara.")),
        ("TourMask", String(localized: "Ronda nos canais"), "Tour", String(localized: "Canais mostrados em sequência no monitor do NVR durante o alarme.")),
    ]

    var masks: [ChannelMask] = []
    var actions: [SmartAlertModel.Action] = []
    var delays: [SmartAlertModel.Delay] = []
    var ptzLink: SmartAlertModel.PTZLink?
    var hasPeriod = false
    var period: [[Int]] = ScheduleCodec.emptyWeek()
    var sectionsPerDay = 6

    init() {}

    init(handler: [String: Any], channelCount: Int = 1) {
        if channelCount > 1 {
            masks = Self.maskSpecs.compactMap { spec in
                guard let value = handler[spec.key] else { return nil }
                let bits = Self.firstWord(value)
                return ChannelMask(key: spec.key, title: spec.title, original: spec.original, detail: spec.detail,
                                   channels: Set((0 ..< channelCount).filter { bits & (1 << UInt32($0)) != 0 }))
            }
        }
        let knownKeys = Set(SmartAlertModel.actionSpecs.map(\.key))
        actions = SmartAlertModel.actionSpecs.compactMap { spec in
            (handler[spec.key] as? Bool).map { SmartAlertModel.Action(spec: spec, isOn: $0) }
        } + handler.keys.sorted().compactMap { key in
            guard !knownKeys.contains(key), key.hasSuffix("Enable"), let value = handler[key] as? Bool else { return nil }
            return SmartAlertModel.Action(
                spec: SmartAlertModel.Spec(key: key, title: key, detail: String(localized: "Opção do equipamento sem descrição conhecida."), group: .legacy),
                isOn: value)
        }
        delays = SmartAlertModel.delaySpecs.compactMap { spec in
            ConfigValue.int(handler[spec.key]).map { SmartAlertModel.Delay(spec: spec, seconds: $0) }
        }
        ptzLink = SmartAlertModel.readPTZLink(handler, index: 0)
        if let sections = handler["TimeSection"] as? [[String]] {
            hasPeriod = true
            sectionsPerDay = sections.first?.count ?? 6
            period = ScheduleCodec.decode(sections: sections, masks: nil)
        }
    }

    func write(into handler: inout [String: Any]) {
        for mask in masks {
            let bits = mask.channels.reduce(UInt32(0)) { $0 | (1 << UInt32($1)) }
            handler[mask.key] = Self.replacingFirstWord(handler[mask.key], with: bits)
        }
        for action in actions { handler[action.spec.key] = action.isOn }
        for delay in delays { ConfigValue.set(&handler, delay.spec.key, delay.seconds) }
        SmartAlertModel.writePTZLink(ptzLink, into: &handler, index: 0)
        if hasPeriod, var sections = handler["TimeSection"] as? [[String]] {
            var noMasks: [[Any]]? = nil
            ScheduleCodec.encode(period, sections: &sections, masks: &noMasks)
            handler["TimeSection"] = sections
        }
    }

    var validationError: String? {
        hasPeriod ? ScheduleCodec.validate(period, maxSections: sectionsPerDay) : nil
    }

    /// Máscaras vêm como "0x00000001" ou "0x00000001000000000000000000000000" (vários grupos de 32 bits);
    /// os canais 1–32 ficam no primeiro grupo.
    static func firstWord(_ value: Any?) -> UInt32 {
        if let number = value as? NSNumber { return number.uint32Value }
        guard let text = value as? String else { return 0 }
        let hex = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return UInt32(hex.prefix(8), radix: 16) ?? 0
    }

    static func replacingFirstWord(_ original: Any?, with bits: UInt32) -> Any {
        guard let text = original as? String else { return Int(bits) }
        let hex = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return "0x" + String(format: "%08X", bits) + hex.dropFirst(min(8, hex.count))
    }
}

/// Telas de eventos que seguem o formato {Enable, Level?, EventHandler}: perda de vídeo, câmera bloqueada
/// e os problemas do equipamento (Anormalidade no VMS antigo). Mostra só o que o equipamento responder.
enum EventScreen {
    case videoLoss
    case blind
    case vehicle
    case face
    case abnormality
    /// Alarme de rede (Alarm.NetAlarm): disparado pelo app com OPNetAlarm, faz o que o EventHandler mandar.
    case manualAlarm

    struct Definition {
        /// Nomes tentados em ordem (modelos diferentes usam prefixos diferentes).
        let names: (Int) -> [String]
        let title: String
        let original: String
        let detail: String
        /// Ações mostradas (nil = todas). A Anormalidade do VMS antigo mostra só algumas.
        var allowedActions: [String]? = nil
        /// Nome da opção como aparece no VMS antigo, quando difere do padrão.
        var originalNames: [String: String] = [:]
        /// Tempos mostrados (nil = os padrão). "CheckDiskInterval" só aparece nos itens de disco.
        var allowedDelays: [String]? = nil
        /// Função em SystemFunction que o equipamento precisa ter (o VMS antigo esconde o item sem ela).
        var requires: String? = nil
    }

    /// Itens de disco: no VMS antigo aparecem "Timed Alarm" (aviso na tela) e "Notificações".
    private static let storageActions = ["TipEnable", "MailEnable", "MessageEnable", "VoiceEnable", "MsgtoNetEnable"]
    private static let storageNames = ["MailEnable": String(localized: "Enviar e-mail"),
                                       "MessageEnable": String(localized: "Notificações"), "VoiceEnable": String(localized: "Alarm Sound")]
    private static let storageDelays = ["CheckDiskInterval"]

    /// Uma só detecção (com ações em seções próprias) ou vários itens curtos na mesma tela.
    var isSingle: Bool { definitions.count == 1 }

    var definitions: [Definition] {
        switch self {
        case .videoLoss:
            return [Definition(names: { ["Detect.LossDetect.[\($0)]"] }, title: String(localized: "Perda de vídeo"), original: "Video Loss",
                               detail: String(localized: "Alarme quando a imagem do canal some: câmera desligada, cabo solto ou fora da rede."))]
        case .blind:
            return [Definition(names: { ["Detect.BlindDetect.[\($0)]"] }, title: String(localized: "Câmera bloqueada"), original: "Video Blind",
                               detail: String(localized: "Alarme quando a lente é coberta, pintada ou a imagem escurece de repente."))]
        case .vehicle:
            return [Definition(names: { ["Detect.CarShapeDetection.[\($0)]"] }, title: String(localized: "Detecção de veículos"), original: "CarShape Detect",
                               detail: String(localized: "Alarme quando a câmera reconhece um carro ou moto. Só funciona em câmeras com essa função."))]
        case .face:
            return [Definition(names: { ["Detect.FaceDetection.[\($0)]", "Detect.FaceDetect.[\($0)]"] }, title: String(localized: "Detecção de rosto"),
                               original: "Face Detection",
                               detail: String(localized: "Alarme quando a própria câmera reconhece um rosto na imagem. Só funciona em câmeras com essa função."))]
        case .manualAlarm:
            return [Definition(names: { ["Alarm.NetAlarm.[\($0)]", "Alarm.NetAlarm"] }, title: String(localized: "Alarme manual"), original: "NetAlarm",
                               detail: String(localized: "Quando você dispara o alarme pelo VMS Next, a câmera faz as ações escolhidas abaixo: voz, sirene, gravar, foto."))]
        case .abnormality:
            return [
                Definition(names: { _ in ["Storage.StorageNotExist", "Alarm.StorageNotExist"] }, title: String(localized: "Sem disco ou cartão"), original: "Nenhum disco",
                           detail: String(localized: "Avisa quando o equipamento não encontra onde gravar."),
                           allowedActions: Self.storageActions, originalNames: Self.storageNames, allowedDelays: Self.storageDelays,
                           requires: "AlarmFunction.StorageNotExist"),
                Definition(names: { _ in ["Storage.StorageFailure", "Alarm.StorageFailure"] }, title: String(localized: "Erro no disco"), original: "Falha de armazenamento",
                           detail: String(localized: "Avisa quando o disco ou cartão falha ao ler ou gravar."),
                           allowedActions: Self.storageActions, originalNames: Self.storageNames, allowedDelays: Self.storageDelays,
                           requires: "AlarmFunction.StorageFailure"),
                Definition(names: { _ in ["Storage.StorageLowSpace", "Alarm.StorageLowSpace"] }, title: String(localized: "Disco quase cheio"), original: "Espaço de armazenamento",
                           detail: String(localized: "Avisa quando o espaço livre cai abaixo do limite escolhido."),
                           allowedActions: Self.storageActions, originalNames: Self.storageNames, allowedDelays: Self.storageDelays,
                           requires: "AlarmFunction.StorageLowSpace"),
                Definition(names: { _ in ["Alarm.NetAbort"] }, title: String(localized: "Rede desconectada"), original: "Internet desconectada",
                           detail: String(localized: "Avisa quando o equipamento perde a conexão com a rede."), allowedActions: [],
                           requires: "AlarmFunction.NetAbort"),
                Definition(names: { _ in ["Alarm.NetIPConflict"] }, title: String(localized: "Conflito de IP"), original: "Conflito de IP",
                           detail: String(localized: "Avisa quando outro aparelho da rede usa o mesmo endereço IP."), allowedActions: [],
                           requires: "AlarmFunction.NetIpConflict"),
            ]
        }
    }
}

/// Tamanho do rosto aceito (em 1/8192 da largura), mostrar o quadro em volta e a área onde procurar.
struct FaceFields {
    var minWidth: Int?
    var maxWidth: Int?
    var showTrack: Bool?
    /// X1/Y1/X2/Y2 da FaceDetectArea, de 0 a 8191.
    var area: [String: Int]?
    /// Detect.FaceDetection (NVRs mais novos): números simples, por chave (MatchRate, sharpness, ângulos, tamanho).
    var numbers: [String: Int] = [:]

    /// Campos numéricos do Detect.FaceDetection, na ordem da tela.
    static let numberKeys = ["MatchRate", "sharpness", "faceAngleYaw", "faceAnglePitch", "faceAngleRoll", "picWidth", "picHeight"]

    init?(config: [String: Any]) {
        minWidth = ConfigValue.int(config["FaceMinWid"])
        maxWidth = ConfigValue.int(config["FaceMaxWid"])
        showTrack = (config["ShowTrack"] as? Bool) ?? ConfigValue.int(config["ShowTrack"]).map { $0 != 0 }
        if let box = config["FaceDetectArea"] as? [String: Any] {
            area = Dictionary(uniqueKeysWithValues: ["X1", "Y1", "X2", "Y2"].compactMap { key in ConfigValue.int(box[key]).map { (key, $0) } })
        }
        for key in Self.numberKeys { if let value = ConfigValue.int(config[key]) { numbers[key] = value } }
        if minWidth == nil, maxWidth == nil, area == nil, numbers.isEmpty { return nil }
    }

    func write(into config: inout [String: Any]) {
        for (key, value) in numbers { ConfigValue.set(&config, key, value) }
        if let minWidth { ConfigValue.set(&config, "FaceMinWid", minWidth) }
        if let maxWidth { ConfigValue.set(&config, "FaceMaxWid", maxWidth) }
        if let showTrack, config["ShowTrack"] != nil {
            config["ShowTrack"] = config["ShowTrack"] is Bool ? showTrack as Any : (showTrack ? 1 : 0) as Any
        }
        if let area, var box = config["FaceDetectArea"] as? [String: Any] {
            for (key, value) in area { box[key] = value }
            config["FaceDetectArea"] = box
        }
    }

    /// Área em 0…1 (para o desenho sobre a imagem).
    var rect: CGRect {
        let scale = RuleDraft.scale
        let x1 = CGFloat(area?["X1"] ?? 0) / scale, y1 = CGFloat(area?["Y1"] ?? 0) / scale
        let x2 = CGFloat(area?["X2"] ?? 8191) / scale, y2 = CGFloat(area?["Y2"] ?? 8191) / scale
        return CGRect(x: x1, y: y1, width: max(x2 - x1, 0), height: max(y2 - y1, 0))
    }

    mutating func setRect(_ rect: CGRect) {
        area = ["X1": RuleDraft.device(rect.minX), "Y1": RuleDraft.device(rect.minY),
                "X2": min(RuleDraft.device(rect.maxX), 8191), "Y2": min(RuleDraft.device(rect.maxY), 8191)]
    }
}

@MainActor
final class EventConfigModel: ObservableObject {
    struct Entry: Identifiable {
        let definition: EventScreen.Definition
        let name: String
        var raw: Any
        var enabled: Bool
        /// Enable vem null quando o canal não tem a função (ex.: câmera sem detecção de veículos).
        var supported = true
        var level: Int?
        var lowerLimit: Int?
        var loiter: Int?
        /// Campos da detecção de rosto (FaceMotionDetectConfig do VMS antigo), quando a câmera manda.
        var face: FaceFields?
        /// Storage.StorageFailure.RebootEnable: reiniciar o equipamento quando o disco/cartão falha.
        var rebootOnFailure: Bool?
        var hasHandler: Bool
        var handler: HandlerState
        var id: String { name }
    }

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var diagnosticText: String?
    @Published var entries: [Entry] = []
    /// Desenho da área do rosto aberto (índice do item e o rascunho).
    @Published var faceDraft: RuleDraft?
    /// Capacidades do equipamento: escondem as ações que ele não tem.
    @Published private(set) var profile = DeviceCapabilities.Profile.empty
    /// NVR: canal em edição (nil = todos os canais recebem a mesma configuração).
    @Published private(set) var selectedChannel: Int?
    @Published private(set) var channelCount = 1

    let camera: Camera
    let screen: EventScreen
    /// Tela do NVR: carrega todos os canais e mostra o seletor de canal, como no VMS antigo.
    let allChannels: Bool
    /// Configuração de cada canal (só no modo NVR).
    private var perChannel: [Int: Entry] = [:]
    /// Canais com câmera conectada, lidos de NetWork.ChnStatus; nil se o NVR não informar.
    @Published private(set) var connected: Set<Int>?
    private var edited: Set<Int> = []
    private var allTemplate: Entry?

    init(camera: Camera, screen: EventScreen, allChannels: Bool = false) {
        self.camera = camera
        self.screen = screen
        self.allChannels = allChannels && screen.isSingle
    }

    var availableChannels: [Int] { perChannel.keys.sorted() }

    @Published private(set) var triggering = false
    @Published private(set) var alarmActive = false

    /// OPNetAlarm (código 1506, como H264_DVR_SendNetAlarmMsg do SDK): State 1 dispara, 0 para.
    func setNetAlarm(_ on: Bool) async {
        triggering = true
        error = nil
        notice = nil
        defer { triggering = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            try await client.command(code: 1506, name: "OPNetAlarm", payload: ["Event": 0, "State": on ? 1 : 0])
            alarmActive = on
            notice = on ? String(localized: "Alarme disparado.") : String(localized: "Alarme parado.")
            AppLog.record(.device, on ? String(localized: "Alarme manual disparado") : String(localized: "Alarme manual parado"), device: camera.host)
        } catch DVRIPError.device(102) {
            self.error = String(localized: "Este equipamento não tem alarme manual.")
        } catch {
            self.error = String(localized: "A câmera não aceitou o alarme: \(error.localizedDescription)")
        }
    }

    /// O canal tem a função: respondeu com a configuração e o "Enable" não veio vazio.
    func isSupported(_ channel: Int) -> Bool {
        perChannel[channel]?.supported ?? false
    }

    func hasConfig(_ channel: Int) -> Bool {
        perChannel[channel] != nil
    }

    /// false só quando o NVR informou que não há câmera conectada no canal.
    func isConnected(_ channel: Int) -> Bool {
        connected?.contains(channel) ?? true
    }

    /// Troca o canal em edição, guardando o que foi alterado no anterior.
    func selectChannel(_ channel: Int?) {
        guard allChannels, let current = entries.first else { return }
        if let old = selectedChannel {
            perChannel[old] = current
            edited.insert(old)
        } else {
            allTemplate = current
        }
        selectedChannel = channel
        if let channel, let entry = perChannel[channel] {
            entries = [entry]
        } else if let template = allTemplate {
            entries = [template]
        }
    }

    var validationError: String? {
        entries.lazy.compactMap { $0.handler.validationError.map { message in message } }.first
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            profile = await DeviceCapabilities.profile(for: camera)
            if allChannels {
                try await loadAllChannels(client)
                return
            }
            var result: [Entry] = []
            for definition in screen.definitions where definition.requires.map(profile.supports) ?? true {
                var found: (name: String, raw: Any)?
                for candidate in definition.names(camera.channel - 1) {
                    if let raw = try await optional(client, candidate) {
                        found = (candidate, raw)
                        break
                    }
                }
                guard let (name, raw) = found, let entry = Self.entry(definition, name: name, raw: raw, channelCount: 1) else { continue }
                result.append(entry)
            }
            entries = result
            // Sem Alarm.NetAlarm o equipamento recusa o OPNetAlarm (código 102), mesmo dizendo
            // AlarmFunction.NetAlarm = true (Frente e Sala); a tela explica isso em vez de dar erro.
            if entries.isEmpty, screen != .manualAlarm {
                error = String(localized: "Este equipamento não informou essas configurações. Use \"Diagnóstico…\" e me envie o resultado.")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply() async {
        if let validationError {
            error = validationError
            return
        }
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            if allChannels {
                try await applyAllChannels(client)
                return
            }
            for index in entries.indices {
                let entry = entries[index]
                let updated = Self.merge(entry, into: entry.raw)
                try await client.setConfig(entry.name, updated)
                entries[index].raw = updated
            }
            notice = String(localized: "Configuração aplicada.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - NVR: todos os canais

    private func loadAllChannels(_ client: DVRIPClient) async throws {
        let info = try? await client.command(code: 1020, name: "SystemInfo", payload: nil)
        let system = info?["SystemInfo"] as? [String: Any]
        let count = max(1, (ConfigValue.int(system?["DigChannel"]) ?? 0) + (ConfigValue.int(system?["VideoInChannel"]) ?? 0))
        channelCount = count
        connected = await Self.connectedChannels(client, count: count)
        perChannel = [:]
        edited = []
        allTemplate = nil
        selectedChannel = nil
        guard let definition = screen.definitions.first else { return }
        for channel in 0 ..< count {
            for candidate in definition.names(channel) {
                if let raw = try await optional(client, candidate),
                   let entry = Self.entry(definition, name: candidate, raw: raw, channelCount: count) {
                    perChannel[channel] = entry
                    break
                }
            }
        }
        if let first = availableChannels.first, let entry = perChannel[first] {
            allTemplate = entry
            entries = [entry]
        } else {
            entries = []
            error = String(localized: "O NVR não informou essa configuração. Use \"Diagnóstico…\" e me envie o resultado.")
        }
    }

    /// "Todos os canais" copia a configuração mostrada para cada canal; um canal específico grava só os alterados.
    private func applyAllChannels(_ client: DVRIPClient) async throws {
        guard let current = entries.first else { return }
        var targets: [(Int, Entry)] = []
        if let channel = selectedChannel {
            perChannel[channel] = current
            edited.insert(channel)
            targets = edited.compactMap { ch in perChannel[ch].map { (ch, $0) } }
        } else {
            targets = availableChannels.compactMap { ch in
                perChannel[ch].map { original in
                    var copy = current
                    copy.raw = original.raw
                    copy.supported = original.supported
                    return (ch, Entry(definition: copy.definition, name: original.name, raw: original.raw,
                                      enabled: copy.enabled, supported: original.supported, level: copy.level,
                                      lowerLimit: copy.lowerLimit, loiter: copy.loiter,
                                      hasHandler: copy.hasHandler, handler: copy.handler))
                }
            }
        }
        for (channel, entry) in targets {
            let updated = Self.merge(entry, into: entry.raw)
            try await client.setConfig(entry.name, updated)
            var saved = entry
            saved.raw = updated
            perChannel[channel] = saved
        }
        edited = []
        notice = selectedChannel == nil ? String(localized: "Aplicado em todos os canais.") : String(localized: "Configuração aplicada.")
    }

    /// Lê o estado de conexão de cada canal. Aceita os formatos mais comuns (lista de objetos com um campo de
    /// estado booleano, numérico ou texto); se não entender, devolve nil e as cores ignoram a conexão.
    private static func connectedChannels(_ client: DVRIPClient, count: Int) async -> Set<Int>? {
        var value: Any?
        if let config = try? await client.getConfig("NetWork.ChnStatus") {
            value = config
        } else if let response = try? await client.command(code: 1020, name: "NetWork.ChnStatus", payload: nil) {
            value = response["NetWork.ChnStatus"]
        }
        guard let items = value as? [Any], !items.isEmpty else { return nil }
        var result = Set<Int>()
        var understood = false
        for (index, item) in items.enumerated() where index < count {
            guard let dict = item as? [String: Any],
                  let key = dict.keys.first(where: { $0.lowercased().contains("status") || $0.lowercased().contains("state") })
            else { continue }
            understood = true
            let raw = dict[key]
            let isOn: Bool
            if let flag = raw as? Bool {
                isOn = flag
            } else if let number = ConfigValue.int(raw) {
                isOn = number != 0
            } else if let text = (raw as? String)?.lowercased() {
                isOn = text.contains("connect") && !text.contains("dis") && !text.contains("un") && !text.contains("no")
            } else {
                continue
            }
            if isOn { result.insert(index) }
        }
        return understood ? result : nil
    }

    // MARK: - Conversão

    private static func entry(_ definition: EventScreen.Definition, name: String, raw: Any, channelCount: Int) -> Entry? {
        guard let config = ConfigValue.object(in: raw) else { return nil }
        let handler = config["EventHandler"] as? [String: Any]
        var entry = Entry(
            definition: definition, name: name, raw: raw,
            enabled: (config["Enable"] as? Bool) ?? (ConfigValue.int(config["Enable"]) == 1),
            level: ConfigValue.int(config["Level"]),
            lowerLimit: ConfigValue.int(config["LowerLimit"]),
            hasHandler: handler != nil,
            handler: handler.map { HandlerState(handler: $0, channelCount: channelCount) } ?? HandlerState()
        )
        entry.supported = !(config["Enable"] is NSNull)
        entry.loiter = ConfigValue.int(config["LoiterLatch"])
        entry.face = FaceFields(config: config)
        entry.rebootOnFailure = config["RebootEnable"].map { ($0 as? Bool) ?? (ConfigValue.int($0) == 1) }
        return entry
    }

    private static func merge(_ entry: Entry, into raw: Any) -> Any {
        guard var config = ConfigValue.object(in: raw) else { return raw }
        if entry.supported { config["Enable"] = entry.enabled }
        if let loiter = entry.loiter { ConfigValue.set(&config, "LoiterLatch", loiter) }
        if let level = entry.level { ConfigValue.set(&config, "Level", level) }
        if let limit = entry.lowerLimit { ConfigValue.set(&config, "LowerLimit", limit) }
        entry.face?.write(into: &config)
        if let reboot = entry.rebootOnFailure, let old = config["RebootEnable"] {
            let isBool = (old as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            config["RebootEnable"] = isBool ? reboot as Any : (reboot ? 1 : 0) as Any
        }
        if entry.hasHandler, var handler = config["EventHandler"] as? [String: Any] {
            entry.handler.write(into: &handler)
            config["EventHandler"] = handler
        }
        return ConfigValue.replacingObject(in: raw, with: config)
    }

    func diagnostic() async -> String {
        var requests = screen.definitions.flatMap { $0.names(camera.channel - 1).map { (UInt16(1042), $0) } }
        if allChannels || camera.group != nil {
            // Estado de conexão dos canais do NVR (para as cores) e telas do NVR sem formato conhecido.
            requests += [(1042, "NetWork.ChnStatus"), (1020, "NetWork.ChnStatus"), (1042, "NetWork.RemoteDeviceV3"),
                         (1042, "NetWork.RemoteDeviceV3.[7]"), (1042, "NetWork.RemoteDevice"), (1042, "NetWork.RemoteDevice.[7]")]
        }
        return await ConfigDiagnostics.dump(camera: camera, requests: requests)
    }

    private func optional(_ client: DVRIPClient, _ name: String) async throws -> Any? {
        do {
            let value = try await client.getConfig(name)
            return value is NSNull ? nil : value
        } catch DVRIPError.device, DVRIPError.invalidResponse {
            return nil
        }
    }
}

struct EventConfigView: View {
    @StateObject private var model: EventConfigModel

    @EnvironmentObject private var store: CameraStore

    init(camera: Camera, screen: EventScreen, allChannels: Bool = false) {
        _model = StateObject(wrappedValue: EventConfigModel(camera: camera, screen: screen, allChannels: allChannels))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if model.allChannels, !model.entries.isEmpty {
                        channelPicker
                    }
                    if model.screen == .manualAlarm {
                        manualAlarmSection
                    }
                    if model.screen.isSingle, !model.entries.isEmpty {
                        singleSections($model.entries[0])
                    } else {
                        ForEach($model.entries) { $entry in
                            compactSection($entry)
                        }
                    }
                    if let message = model.error ?? model.validationError {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            SettingsFooter(notice: model.notice, busy: model.loading || model.saving, applyDisabled: model.entries.isEmpty || model.validationError != nil,
                           onDiagnostic: { model.diagnosticText = await model.diagnostic() },
                           onReload: { await model.load() },
                           onApply: { Task { await model.apply() } })
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    // MARK: - Alarme manual

    @ViewBuilder
    private var manualAlarmSection: some View {
        if model.entries.isEmpty {
            Section {
                Label("Este equipamento não tem alarme manual (NetAlarm). Nas câmeras com sirene, luz ou relé, use \"Saída de alarme\" no modo manual.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Disparar agora")
            }
        } else {
            manualAlarmControls
        }
    }

    private var manualAlarmControls: some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    Task { await model.setNetAlarm(true) }
                } label: {
                    Label("Disparar alarme", systemImage: "bell.and.waves.left.and.right.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.warning)
                Button {
                    Task { await model.setNetAlarm(false) }
                } label: {
                    Label("Parar", systemImage: "bell.slash")
                }
                if model.triggering { ProgressView().controlSize(.small) }
                Spacer()
                if model.alarmActive {
                    Label("Alarme ligado", systemImage: "circle.fill")
                        .foregroundStyle(Theme.warning)
                        .font(.callout)
                }
            }
            .disabled(model.triggering)
        } header: {
            Text("Disparar agora")
        } footer: {
            Text("Use para testar a voz de alarme, a sirene ou a luz. As ações e o tempo do alarme ficam nas seções abaixo; aplique antes de disparar.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - NVR

    /// Botões de canal: verde = a câmera do canal tem a função; vermelho = não tem ou não respondeu.
    private var channelPicker: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                FieldLabel(String(localized: "Canal"), original: "Canal / ChannelNo",
                           detail: String(localized: "Em \"Todos\", o que você ajustar aqui vale para todos os canais ao aplicar."))
                HStack(spacing: 6) {
                    channelButton(title: String(localized: "Todos"), channel: nil, color: Theme.accent)
                    ForEach(0 ..< model.channelCount, id: \.self) { channel in
                        let status = channelStatus(channel)
                        channelButton(title: "\(channel + 1)", channel: channel, color: status.color)
                            .help("\(channelName(channel)) · \(status.text)")
                            .disabled(!model.hasConfig(channel))
                    }
                }
                HStack(spacing: 14) {
                    legend(.green, String(localized: "Tem a função"))
                    legend(.red, String(localized: "A câmera não tem"))
                    legend(.gray, String(localized: "Sem câmera conectada"))
                }
                .font(.caption)
                if let channel = model.selectedChannel {
                    Text(channelName(channel)).font(.callout.weight(.medium))
                }
            }
        }
    }

    /// Canais com câmera: o que o NVR informar; se não informar, os canais cadastrados no app.
    private var connectedChannels: Set<Int> {
        model.connected ?? Set(store.cameras
            .filter { $0.host == model.camera.host && $0.group == model.camera.group }
            .map { $0.channel - 1 })
    }

    private func channelStatus(_ channel: Int) -> (color: Color, text: String) {
        if !connectedChannels.contains(channel) { return (.gray, String(localized: "sem câmera conectada")) }
        return model.isSupported(channel) ? (.green, String(localized: "tem a função")) : (.red, String(localized: "a câmera não tem a função"))
    }

    private func channelButton(title: String, channel: Int?, color: Color) -> some View {
        let selected = model.selectedChannel == channel
        return Button {
            model.selectChannel(channel)
        } label: {
            Text(title)
                .font(.callout.weight(.semibold).monospacedDigit())
                .frame(minWidth: title.count > 2 ? 56 : 30, minHeight: 26)
                .foregroundStyle(.white)
                .background(color.opacity(selected ? 1 : 0.75), in: RoundedRectangle(cornerRadius: Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(Color.primary, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: Radius.small).fill(color).frame(width: 12, height: 12)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func channelName(_ channel: Int) -> String {
        let camera = store.cameras.first { $0.host == model.camera.host && $0.channel == channel + 1 && $0.group == model.camera.group }
        return camera.map { "Canal \(channel + 1) · \($0.name)" } ?? "Canal \(channel + 1)"
    }

    @ViewBuilder
    private func maskSection(_ entry: Binding<EventConfigModel.Entry>) -> some View {
        if !entry.wrappedValue.handler.masks.isEmpty {
            Section("Canais acionados") {
                ForEach(entry.wrappedValue.handler.masks.indices, id: \.self) { index in
                    let mask = entry.wrappedValue.handler.masks[index]
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(mask.title, original: mask.original, detail: mask.detail)
                        HStack(spacing: 4) {
                            ForEach(0 ..< model.channelCount, id: \.self) { channel in
                                Toggle("\(channel + 1)", isOn: Binding(
                                    get: { entry.wrappedValue.handler.masks[index].channels.contains(channel) },
                                    set: { on in
                                        if on { entry.wrappedValue.handler.masks[index].channels.insert(channel) }
                                        else { entry.wrappedValue.handler.masks[index].channels.remove(channel) }
                                    }
                                ))
                                .toggleStyle(.button)
                                .controlSize(.small)
                            }
                            Button("Todos") {
                                entry.wrappedValue.handler.masks[index].channels = Set(0 ..< model.channelCount)
                            }
                            .controlSize(.small)
                            Button("Nenhum") { entry.wrappedValue.handler.masks[index].channels = [] }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Detecção única (perda de vídeo, câmera bloqueada): seções como na Detecção inteligente

    @ViewBuilder
    private func singleSections(_ entry: Binding<EventConfigModel.Entry>) -> some View {
        let definition = entry.wrappedValue.definition
        // Como no VMS antigo, com "Ativar" desligado o resto fica apagado.
        let off = !entry.wrappedValue.enabled
        Section(definition.title) {
            enableToggle(entry)
            levelPicker(entry).disabled(off)
        }
        if entry.wrappedValue.face != nil {
            faceSection(entry).disabled(off)
        }
        maskSection(entry).disabled(off)
        ForEach([SmartAlertModel.ActionGroup.record, .notify, .external], id: \.self) { group in
            let actions = actionIndices(entry.wrappedValue, group: group)
            let delays = entry.wrappedValue.handler.delays.indices.filter {
                entry.wrappedValue.handler.delays[$0].spec.group == group && entry.wrappedValue.handler.delays[$0].spec.key != "CheckDiskInterval"
                    && SmartAlertModel.isShown(entry.wrappedValue.handler.delays[$0].spec, profile: model.profile)
            }
            if !actions.isEmpty || !delays.isEmpty {
                Section("Ao detectar · \(group.rawValue.lowercased())") {
                    actionToggles(entry, indices: actions)
                    delaySteppers(entry, indices: delays)
                    if group == .external, entry.wrappedValue.handler.ptzLink != nil,
                       entry.wrappedValue.handler.actions.contains(where: { $0.spec.key == "PtzEnable" && $0.isOn }) {
                        PTZLinkRow(link: Binding(get: { entry.wrappedValue.handler.ptzLink! },
                                                 set: { entry.wrappedValue.handler.ptzLink = $0 }))
                    }
                }
                .disabled(off)
            }
        }
        advancedSection(entry).disabled(off)
        if entry.wrappedValue.handler.hasPeriod {
            Section {
                ScheduleGrid(slots: entry.handler.period, rows: ScheduleRow.period)
            } header: {
                Text("Horários em que o alarme fica ativo (Período)")
            } footer: {
                Text("Fora dos horários marcados, o alarme não dispara.").foregroundStyle(.secondary)
            }
            .disabled(off)
        }
    }

    /// "Opções avançadas", igual à Detecção inteligente: só as antigas que valem a pena (SmartAlertModel.advancedKeys).
    @ViewBuilder
    private func advancedSection(_ entry: Binding<EventConfigModel.Entry>) -> some View {
        let actions = actionIndices(entry.wrappedValue, group: .legacy)
        let delays = entry.wrappedValue.handler.delays.indices.filter {
            entry.wrappedValue.handler.delays[$0].spec.group == .legacy
                && SmartAlertModel.isShown(entry.wrappedValue.handler.delays[$0].spec, profile: model.profile)
        }
        if !actions.isEmpty || !delays.isEmpty {
            Section {
                DisclosureGroup("Opções avançadas") {
                    actionToggles(entry, indices: actions)
                    delaySteppers(entry, indices: delays)
                }
            }
        }
    }

    // MARK: - Vários itens curtos (problemas no equipamento)

    private func compactSection(_ entry: Binding<EventConfigModel.Entry>) -> some View {
        Section(entry.wrappedValue.definition.title) {
            enableToggle(entry)
            if let limit = entry.wrappedValue.lowerLimit {
                Stepper(value: Binding(get: { limit }, set: { entry.wrappedValue.lowerLimit = $0 }), in: 1 ... 99) {
                    FieldLabel(String(localized: "Avisar com menos de \(limit)% livre"), original: "Limite inferior")
                }
            }
            if let reboot = entry.wrappedValue.rebootOnFailure {
                Toggle(isOn: Binding(get: { reboot }, set: { entry.wrappedValue.rebootOnFailure = $0 })) {
                    FieldLabel(String(localized: "Reiniciar quando o cartão falhar"), original: "RebootEnable",
                               detail: String(localized: "A câmera reinicia sozinha se o disco ou cartão parar de responder. Muitas vezes isso faz a gravação voltar."))
                }
            }
            // As opções avançadas (informação na imagem, filtro de oscilação) não valem para problemas no equipamento.
            actionToggles(entry, indices: actionIndices(entry.wrappedValue, group: nil).filter {
                entry.wrappedValue.handler.actions[$0].spec.group != .legacy
            })
            let allowedDelays = entry.wrappedValue.definition.allowedDelays ?? []
            delaySteppers(entry, indices: entry.wrappedValue.handler.delays.indices.filter {
                allowedDelays.contains(entry.wrappedValue.handler.delays[$0].spec.key)
            })
        }
    }

    // MARK: - Rosto

    /// Tamanhos em % da largura da imagem (no equipamento: 1/8192 da largura).
    private static let minSizes = [2, 3, 4, 5, 6, 8, 10, 15, 20]
    private static let maxSizes = [15, 20, 25, 30, 40, 50, 60, 80, 100]

    private static func percent(_ device: Int) -> Int { Int((Double(device) / 8192 * 100).rounded()) }
    private static func device(_ percent: Int) -> Int { min(Int((Double(percent) / 100 * 8192).rounded()), 8191) }

    @ViewBuilder
    private func faceSection(_ entry: Binding<EventConfigModel.Entry>) -> some View {
        let face = entry.wrappedValue.face!
        Section {
            if let minWidth = face.minWidth {
                sizePicker(String(localized: "Menor rosto"), original: "FaceMinWid",
                           detail: String(localized: "Rostos menores que isso (mais longe da câmera) são ignorados."),
                           value: minWidth, options: Self.minSizes) { entry.wrappedValue.face?.minWidth = $0 }
            }
            if let maxWidth = face.maxWidth {
                sizePicker(String(localized: "Maior rosto"), original: "FaceMaxWid",
                           detail: String(localized: "Evita confundir com rosto algo muito perto da lente."),
                           value: maxWidth, options: Self.maxSizes) { entry.wrappedValue.face?.maxWidth = $0 }
            }
            if let showTrack = face.showTrack {
                Toggle(isOn: Binding(get: { showTrack }, set: { entry.wrappedValue.face?.showTrack = $0 })) {
                    FieldLabel(String(localized: "Mostrar o quadro do rosto"), original: "ShowTrack",
                               detail: String(localized: "Desenha um quadro em volta do rosto no vídeo da câmera."))
                }
            }
            ForEach(FaceFields.numberKeys.filter { face.numbers[$0] != nil }, id: \.self) { key in
                faceNumberRow(key, value: face.numbers[key]!) { entry.wrappedValue.face?.numbers[key] = $0 }
            }
            if face.area != nil {
                HStack {
                    FieldLabel(String(localized: "Área de detecção"), original: "FaceDetectArea",
                               detail: areaText(face.rect))
                    Spacer()
                    Button("Desenhar…") {
                        let rect = face.rect
                        let draft = RuleDraft(index: 0, kind: .area,
                                              area: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                                                     CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)],
                                              line: [], direction: 2)
                        draft.rectangle = true
                        model.faceDraft = draft
                    }
                }
            }
        } header: {
            Text("Rosto")
        } footer: {
            Text("Os ajustes valem depois de Aplicar.").foregroundStyle(.secondary)
        }
        .sheet(item: $model.faceDraft) { draft in
            RuleEditorView(draft: draft, camera: model.camera) { saved in
                entry.wrappedValue.face?.setRect(saved.bounds)
                return nil
            }
        }
    }

    /// Faixa, passo e textos de cada número do Detect.FaceDetection.
    private static let numberSpecs: [String: (title: String, detail: String, range: ClosedRange<Int>, step: Int, unit: String)] = [
        "MatchRate": (String(localized: "Semelhança para reconhecer"),
                      String(localized: "Quanto um rosto precisa parecer com um rosto cadastrado no NVR para contar como a mesma pessoa. Mais alto = menos enganos, mas pode não reconhecer."),
                      0 ... 100, 5, "%"),
        "sharpness": (String(localized: "Nitidez mínima"),
                      String(localized: "Ignora rostos borrados (pessoa em movimento, fora de foco). Mais alto = só fotos bem nítidas."),
                      0 ... 100, 1, ""),
        "faceAngleYaw": (String(localized: "Rosto virado para o lado, até"),
                         String(localized: "Quanto a cabeça pode estar virada para a esquerda ou a direita e ainda contar como rosto."),
                         0 ... 90, 5, "°"),
        "faceAnglePitch": (String(localized: "Rosto para cima ou para baixo, até"),
                           String(localized: "Quanto a cabeça pode estar levantada ou abaixada."),
                           0 ... 90, 5, "°"),
        "faceAngleRoll": (String(localized: "Cabeça inclinada, até"),
                          String(localized: "Quanto a cabeça pode estar tombada para um lado."),
                          0 ... 90, 5, "°"),
        "picWidth": (String(localized: "Largura mínima do rosto"),
                     String(localized: "Rostos menores que isso, em pixels, são ignorados (muito longe da câmera)."),
                     20 ... 400, 10, " px"),
        "picHeight": (String(localized: "Altura mínima do rosto"),
                      String(localized: "Rostos menores que isso, em pixels, são ignorados (muito longe da câmera)."),
                      20 ... 400, 10, " px"),
    ]

    private func faceNumberRow(_ key: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        let spec = Self.numberSpecs[key] ?? (key, "", 0 ... 1000, 1, "")
        return Stepper(value: Binding(get: { value }, set: set), in: min(spec.range.lowerBound, value) ... max(spec.range.upperBound, value),
                       step: spec.step) {
            FieldLabel("\(spec.title): \(value)\(spec.unit)", original: key, detail: spec.detail)
        }
    }

    private func sizePicker(_ title: String, original: String, detail: String, value: Int, options: [Int],
                            set: @escaping (Int) -> Void) -> some View {
        let current = Self.percent(value)
        return Picker(selection: Binding(get: { current }, set: { set(Self.device($0)) })) {
            ForEach(Array(Set(options + [current])).sorted(), id: \.self) { Text("\($0)% da largura").tag($0) }
        } label: {
            FieldLabel(title, original: original, detail: detail)
        }
    }

    private func areaText(_ rect: CGRect) -> String {
        if rect.width > 0.98, rect.height > 0.98 { return String(localized: "Imagem toda.") }
        return String(localized: "\(Int(rect.width * 100))% × \(Int(rect.height * 100))% da imagem.")
    }

    // MARK: - Peças

    @ViewBuilder
    private func enableToggle(_ entry: Binding<EventConfigModel.Entry>) -> some View {
        let definition = entry.wrappedValue.definition
        Toggle(isOn: entry.enabled) {
            FieldLabel("Ativar", original: definition.original,
                       detail: entry.wrappedValue.supported ? definition.detail : String(localized: "Este canal não tem essa função (a câmera não oferece)."))
        }
        .disabled(!entry.wrappedValue.supported)
        if let loiter = entry.wrappedValue.loiter {
            Stepper(value: Binding(get: { loiter }, set: { entry.wrappedValue.loiter = $0 }), in: 0 ... 600) {
                FieldLabel(String(localized: "Tempo de permanência: \(loiter) s"), original: "LoiterLatch",
                           detail: String(localized: "Só avisa se o veículo continuar na imagem por esse tempo; 0 avisa na hora."))
            }
        }
    }

    @ViewBuilder
    private func levelPicker(_ entry: Binding<EventConfigModel.Entry>) -> some View {
        if let level = entry.wrappedValue.level {
            Picker(selection: Binding(get: { level }, set: { entry.wrappedValue.level = $0 })) {
                ForEach(Array(Set(Array(1 ... 6) + [level])).sorted(), id: \.self) {
                    Text(SmartAlertModel.levelNames[$0] ?? String(localized: "Nível \($0)")).tag($0)
                }
            } label: {
                FieldLabel("Sensibilidade", detail: String(localized: "Mais alta dispara com bloqueios menores, mas pode dar alarme falso à noite."))
            }
        }
    }

    /// Índices das ações visíveis: filtradas pelo grupo e pela lista permitida do item (na ordem dessa lista).
    private func actionIndices(_ entry: EventConfigModel.Entry, group: SmartAlertModel.ActionGroup?) -> [Int] {
        let actions = entry.handler.actions
        if let allowed = entry.definition.allowedActions {
            return allowed.compactMap { key in actions.firstIndex { $0.spec.key == key } }
        }
        return actions.indices.filter {
            (group == nil || actions[$0].spec.group == group) && SmartAlertModel.isShown(actions[$0].spec, profile: model.profile)
        }
    }

    // Ações e tempos ficam na mesma seção: identificadores com prefixo para o SwiftUI não confundir a
    // ação 1 com o tempo 1 (isso mostrava "Tirar foto" duas vezes no lugar de "Continuar gravando por").
    private func actionToggles(_ entry: Binding<EventConfigModel.Entry>, indices: [Int]) -> some View {
        ForEach(indices, id: \.self) { index in
            let action = entry.wrappedValue.handler.actions[index]
            Toggle(isOn: entry.handler.actions[index].isOn) {
                FieldLabel(action.spec.title,
                           original: entry.wrappedValue.definition.originalNames[action.spec.key] ?? action.spec.original,
                           detail: action.spec.detail)
            }
        }
    }

    private func delaySteppers(_ entry: Binding<EventConfigModel.Entry>, indices: [Int]) -> some View {
        ForEach(indices.map { -1 - $0 }, id: \.self) { key in
            let index = -1 - key
            let delay = entry.wrappedValue.handler.delays[index]
            Stepper(value: entry.handler.delays[index].seconds, in: delay.spec.range) {
                FieldLabel("\(delay.spec.title): \(delay.seconds) s", original: delay.spec.original, detail: delay.spec.detail)
            }
        }
    }
}
