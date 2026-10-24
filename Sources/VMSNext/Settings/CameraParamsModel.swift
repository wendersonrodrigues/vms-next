import Foundation

/// "Parâmetros da cam": lê Camera.Param e AVEnc.VideoColor do canal, expõe os campos
/// conhecidos e grava de volta o objeto completo, preservando o que o app não entende.
@MainActor
final class CameraParamsModel: ObservableObject {
    /// Valores de DayNightColor na ordem da lista "Modo dia/noite" do VMS antigo (o índice é o valor).
    /// Os três últimos só existem em câmeras de luz dupla; a capacidade "Camera" diz se a câmera tem.
    struct DayNightMode {
        let value: Int
        let label: String
        let original: String
        let detail: String
        let needsDoubleLight: Bool
    }
    static let knownDayNightModes: [DayNightMode] = [
        // Nomes de 0 a 2 conforme a tradução do próprio VMS antigo (tela IPC Param e English.qm).
        DayNightMode(value: 0, label: "Visão noturna infravermelha", original: "Star IR",
                     detail: "À noite liga o infravermelho; imagem em preto e branco.", needsDoubleLight: false),
        DayNightMode(value: 1, label: "Colorida (luz das estrelas)", original: "Full Color",
                     detail: "Fica colorido também à noite, usando a luz do local ou a luz branca.", needsDoubleLight: false),
        DayNightMode(value: 2, label: "Alerta de luz dupla", original: "BlackAndWhiteMode",
                     detail: "Infravermelho em preto e branco; ao detectar alguém, a luz acende e fica colorido.", needsDoubleLight: false),
        DayNightMode(value: 3, label: "Luz ao detectar movimento", original: "IntellMotionDetect",
                     detail: "Infravermelho à noite; ao detectar movimento, a luz acende e a imagem fica colorida.", needsDoubleLight: true),
        DayNightMode(value: 4, label: "Luz quente", original: "WarmLight",
                     detail: "Usa a luz quente da câmera para a imagem ficar colorida à noite.", needsDoubleLight: true),
        DayNightMode(value: 5, label: "Infravermelho inteligente", original: "IntelligentInfrared",
                     detail: "Infravermelho que se ajusta para não estourar quem está perto da câmera.", needsDoubleLight: true),
    ]
    static let autoDayNightMode = 0

    /// Câmeras de luz dupla (IR + LED branco) controlam a visão noturna por Camera.WhiteLight.WorkMode,
    /// com os mesmos três modos do app iCSee.
    static let nightModes: [(value: String, label: String, detail: String)] = [
        ("Auto", "Visão noturna colorida",
         "Com pouca luz, a luz branca liga automaticamente; imagem colorida."),
        ("Close", "Visão noturna infravermelha",
         "Com pouca luz, o infravermelho liga automaticamente; imagem em preto e branco."),
        ("Intelligent", "Alerta de luz dupla",
         "Infravermelho em preto e branco; ao detectar pessoas, a luz branca acende e a imagem fica colorida."),
    ]
    static let triggerLevels: [(value: Int, label: String)] = [(1, "Baixa"), (3, "Média"), (5, "Alta")]
    static let triggerDurations = [10, 30, 60, 90, 120, 180, 300]

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var diagnosticText: String?

    @Published private(set) var hasImageParams = false
    @Published private(set) var hasColor = false
    @Published private(set) var hasDayNightThreshold = false

    @Published var dayNight = CameraParamsModel.autoDayNightMode { didSet { dayNightChanged = true } }
    private var dayNightChanged = false
    /// Valor lido da câmera, para oferecer de volta um modo que o app não conhece.
    @Published private(set) var deviceDayNight: Int?
    /// Capacidade "Camera" (ABILITY_GET): diz se a câmera tem luz dupla, como o VMS antigo consulta.
    @Published private(set) var cameraAbility: [String: Any]?

    /// Capacidades do equipamento (as mesmas que o VMS antigo usa para esconder opções).
    private(set) var profile = DeviceCapabilities.Profile.empty

    /// Câmera com luz dupla, pela capacidade "Camera".
    var hasDoubleLight: Bool {
        let ability = cameraAbility ?? [:]
        return ConfigValue.int(ability["SupportIntellDoubleLight"]) == 1
            || ConfigValue.int(ability["SupDayNightMotionDetect"]) == 1
    }

    /// SupportHideNormalDLMode: a câmera esconde os modos 0 a 2 (a Frente, por exemplo, só tem os de luz dupla).
    var hidesNormalModes: Bool { profile.has("OtherFunction.SupportHideNormalDLMode") }

    var dayNightOptions: [DayNightMode] {
        var options = Self.knownDayNightModes
        if let device = deviceDayNight, !options.contains(where: { $0.value == device }) {
            options.append(DayNightMode(value: device, label: "Modo do equipamento (\(device))", original: "",
                                        detail: "", needsDoubleLight: false))
        }
        return options
    }

    /// Modos que a câmera tem, como no VMS antigo; o modo atual sempre aparece.
    var visibleDayNightOptions: [DayNightMode] {
        dayNightOptions.filter { mode in
            if mode.value == deviceDayNight { return true }
            if mode.needsDoubleLight { return cameraAbility == nil || hasDoubleLight }
            return mode.value > 5 || !hidesNormalModes
        }
    }
    @Published var dayNightThreshold: Double = 30
    /// "Ajuste dia e noite" do VMS antigo (Camera.ParamEx.AutomaticAdjustment, de 1 a 5).
    @Published private(set) var hasDayNightAdjust = false
    @Published var dayNightAdjust: Double = 3 { didSet { dayNightAdjustChanged = true } }
    private var dayNightAdjustChanged = false
    @Published var mirror = false
    @Published var flip = false
    @Published var backlight = false
    @Published var antiFlicker = false

    @Published var brightness: Double = 50
    @Published var contrast: Double = 50
    @Published var saturation: Double = 50
    @Published var hue: Double = 50

    @Published private(set) var hasWhiteLight = false
    @Published var nightMode = "Close"
    @Published var lightBrightness: Double = 50
    @Published var triggerLevel = 3
    @Published var triggerDuration = 60

    /// Opções incluindo valores lidos que o app não conhece, para não perdê-los.
    var nightModeOptions: [(value: String, label: String, detail: String)] {
        var options = Self.nightModes
        if !options.contains(where: { $0.value == nightMode }) {
            options.append((nightMode, "Modo do equipamento (\(nightMode))", ""))
        }
        return options
    }
    var triggerLevelOptions: [(value: Int, label: String)] {
        var options = Self.triggerLevels
        if !options.contains(where: { $0.value == triggerLevel }) {
            options.append((triggerLevel, "Nível \(triggerLevel)"))
            options.sort { $0.value < $1.value }
        }
        return options
    }
    var triggerDurationOptions: [Int] {
        Array(Set(Self.triggerDurations + [triggerDuration])).sorted()
    }

    let camera: Camera
    private var paramRaw: Any?
    private var colorRaw: Any?
    private var paramExRaw: Any?
    private var whiteLightRaw: [String: Any]?
    /// Camera.WhiteLight não leva índice de canal nessas câmeras.
    private let whiteLightName = "Camera.WhiteLight"

    private var paramName: String { "Camera.Param.[\(camera.channel - 1)]" }
    private var colorName: String { "AVEnc.VideoColor.[\(camera.channel - 1)]" }
    private var paramExName: String { "Camera.ParamEx.[\(camera.channel - 1)]" }

    init(camera: Camera) {
        self.camera = camera
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            paramRaw = try await optionalConfig(client, paramName)
            colorRaw = try await optionalConfig(client, colorName)
            paramExRaw = try await optionalConfig(client, paramExName)
            profile = await DeviceCapabilities.profile(for: camera)
            cameraAbility = profile.camera
            whiteLightRaw = try await optionalConfig(client, whiteLightName) as? [String: Any]
            readParams()
            readColor()
            readWhiteLight()
            readParamEx()
            if !hasImageParams && !hasColor && !hasWhiteLight {
                error = "Este equipamento não informou parâmetros de imagem para o canal \(camera.channel)."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply() async {
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            if let raw = paramRaw, var dict = ConfigValue.object(in: raw) {
                // Em câmeras de luz dupla o DayNightColor não controla a visão noturna; fica como está.
                // Só grava o modo dia/noite se ele foi mudado aqui, para não mexer no que a câmera já usa.
                if dayNightChanged { ConfigValue.set(&dict, "DayNightColor", dayNight) }
                ConfigValue.set(&dict, "DncThr", Int(dayNightThreshold))
                ConfigValue.set(&dict, "PictureMirror", mirror ? 1 : 0)
                ConfigValue.set(&dict, "PictureFlip", flip ? 1 : 0)
                ConfigValue.set(&dict, "BLCMode", backlight ? 1 : 0)
                ConfigValue.set(&dict, "RejectFlicker", antiFlicker ? 1 : 0)
                let updated = ConfigValue.replacingObject(in: raw, with: dict)
                try await client.setConfig(paramName, updated)
                paramRaw = updated
            }
            if dayNightAdjustChanged, let raw = paramExRaw, var dict = ConfigValue.object(in: raw) {
                ConfigValue.set(&dict, "AutomaticAdjustment", Int(dayNightAdjust))
                let updated = ConfigValue.replacingObject(in: raw, with: dict)
                try await client.setConfig(paramExName, updated)
                paramExRaw = updated
                dayNightAdjustChanged = false
            }
            if let raw = colorRaw as? [Any] {
                let updated = raw.map { section -> Any in
                    guard var entry = section as? [String: Any],
                          var color = entry["VideoColorParam"] as? [String: Any] else { return section }
                    ConfigValue.set(&color, "Brightness", Int(brightness))
                    ConfigValue.set(&color, "Contrast", Int(contrast))
                    ConfigValue.set(&color, "Saturation", Int(saturation))
                    ConfigValue.set(&color, "Hue", Int(hue))
                    entry["VideoColorParam"] = color
                    return entry
                }
                try await client.setConfig(colorName, updated)
                colorRaw = updated
            }

            if var light = whiteLightRaw {
                light["WorkMode"] = nightMode
                ConfigValue.set(&light, "Brightness", Int(lightBrightness))
                if var trigger = light["MoveTrigLight"] as? [String: Any] {
                    ConfigValue.set(&trigger, "Level", triggerLevel)
                    ConfigValue.set(&trigger, "Duration", triggerDuration)
                    light["MoveTrigLight"] = trigger
                }
                try await client.setConfig(whiteLightName, light)
                whiteLightRaw = light

                let check = try await optionalConfig(client, whiteLightName) as? [String: Any]
                if let applied = check?["WorkMode"] as? String, applied != nightMode {
                    error = "A câmera aceitou o comando mas manteve a visão noturna anterior (\(applied))."
                    return
                }
            } else if hasImageParams && dayNightChanged {
                // Algumas câmeras aceitam o comando mas ignoram o modo dia/noite: confere lendo de volta.
                let check = ConfigValue.object(in: try await optionalConfig(client, paramName))
                let applied = ConfigValue.int(check?["DayNightColor"])
                if applied == nil {
                    error = "Este modelo não tem o campo DayNightColor; o modo dia/noite fica em outra configuração. Use \"Diagnóstico…\" e me envie o resultado."
                    return
                } else if applied != dayNight {
                    error = "A câmera aceitou o comando mas manteve o modo dia/noite anterior (\(applied!)). Use \"Diagnóstico…\" e me envie o resultado."
                    return
                }
            }
            dayNightChanged = false
            notice = "Configurações aplicadas."
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Configurações relacionadas a imagem e dia/noite, em JSON legível, para comparar modelos de câmera.
    /// Não inclui senhas.
    func diagnostic() async -> String {
        let ch = camera.channel - 1
        return await ConfigDiagnostics.dump(camera: camera, requests: [
            (1042, paramName), (1042, "Camera.ParamEx.[\(ch)]"), (1042, colorName),
            (1042, whiteLightName),
        ])
    }

    /// Retorna nil quando o equipamento recusa o nome (configuração não suportada).
    private func optionalConfig(_ client: DVRIPClient, _ name: String) async throws -> Any? {
        do {
            return try await client.getConfig(name)
        } catch DVRIPError.device, DVRIPError.invalidResponse {
            return nil
        }
    }

    private func readParams() {
        guard let dict = ConfigValue.object(in: paramRaw) else {
            hasImageParams = false
            return
        }
        hasImageParams = true
        deviceDayNight = ConfigValue.int(dict["DayNightColor"])
        dayNight = deviceDayNight ?? Self.autoDayNightMode
        dayNightChanged = false
        if let threshold = ConfigValue.int(dict["DncThr"]) {
            hasDayNightThreshold = true
            dayNightThreshold = Double(threshold)
        }
        mirror = ConfigValue.int(dict["PictureMirror"]) == 1
        flip = ConfigValue.int(dict["PictureFlip"]) == 1
        backlight = (ConfigValue.int(dict["BLCMode"]) ?? 0) != 0
        antiFlicker = (ConfigValue.int(dict["RejectFlicker"]) ?? 0) != 0
    }

    private func readColor() {
        guard let first = (colorRaw as? [Any])?.first as? [String: Any],
              let color = first["VideoColorParam"] as? [String: Any]
        else {
            hasColor = false
            return
        }
        hasColor = true
        brightness = Double(ConfigValue.int(color["Brightness"]) ?? 50)
        contrast = Double(ConfigValue.int(color["Contrast"]) ?? 50)
        saturation = Double(ConfigValue.int(color["Saturation"]) ?? 50)
        hue = Double(ConfigValue.int(color["Hue"]) ?? 50)
    }

    private func readParamEx() {
        guard let dict = ConfigValue.object(in: paramExRaw), let value = ConfigValue.int(dict["AutomaticAdjustment"]) else {
            hasDayNightAdjust = false
            return
        }
        hasDayNightAdjust = true
        dayNightAdjust = Double(min(max(value, 1), 5))
        dayNightAdjustChanged = false
    }

    private func readWhiteLight() {
        // Como no VMS antigo: luz branca só em câmeras com SupportCameraWhiteLight (a Sala responde a
        // configuração, mas não tem a luz). Escondida, ela também não é regravada.
        if profile.functions != nil && !profile.has("OtherFunction.SupportCameraWhiteLight") { whiteLightRaw = nil }
        guard let light = whiteLightRaw, let mode = light["WorkMode"] as? String else {
            hasWhiteLight = false
            return
        }
        hasWhiteLight = true
        nightMode = mode
        lightBrightness = Double(ConfigValue.int(light["Brightness"]) ?? 50)
        if let trigger = light["MoveTrigLight"] as? [String: Any] {
            triggerLevel = ConfigValue.int(trigger["Level"]) ?? 3
            triggerDuration = ConfigValue.int(trigger["Duration"]) ?? 60
        }
    }
}
