import Foundation

/// "Parâmetros da cam": lê Camera.Param e AVEnc.VideoColor do canal, expõe os campos
/// conhecidos e grava de volta o objeto completo, preservando o que o app não entende.
@MainActor
final class CameraParamsModel: ObservableObject {
    /// Valores de DayNightColor no SDK da Xiongmai: 0 colorido, 1 automático, 2 preto e branco.
    /// Alguns modelos usam valores extras (ex.: 3); eles aparecem como "modo do equipamento" e são preservados.
    static let knownDayNightModes: [(value: Int, label: String)] = [
        (1, "Automático"),
        (0, "Sempre colorido"),
        (2, "Sempre preto e branco"),
    ]
    static let autoDayNightMode = 1

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

    @Published var dayNight = CameraParamsModel.autoDayNightMode
    /// Valor lido da câmera, para oferecer de volta um modo que o app não conhece.
    @Published private(set) var deviceDayNight: Int?

    var dayNightOptions: [(value: Int, label: String)] {
        var options = Self.knownDayNightModes
        if let device = deviceDayNight, !options.contains(where: { $0.value == device }) {
            options.append((device, "Modo do equipamento (\(device))"))
        }
        return options
    }
    @Published var dayNightThreshold: Double = 30
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
    private var whiteLightRaw: [String: Any]?
    /// Camera.WhiteLight não leva índice de canal nessas câmeras.
    private let whiteLightName = "Camera.WhiteLight"

    private var paramName: String { "Camera.Param.[\(camera.channel - 1)]" }
    private var colorName: String { "AVEnc.VideoColor.[\(camera.channel - 1)]" }

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
            whiteLightRaw = try await optionalConfig(client, whiteLightName) as? [String: Any]
            readParams()
            readColor()
            readWhiteLight()
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
                if !hasWhiteLight { ConfigValue.set(&dict, "DayNightColor", dayNight) }
                ConfigValue.set(&dict, "DncThr", Int(dayNightThreshold))
                ConfigValue.set(&dict, "PictureMirror", mirror ? 1 : 0)
                ConfigValue.set(&dict, "PictureFlip", flip ? 1 : 0)
                ConfigValue.set(&dict, "BLCMode", backlight ? 1 : 0)
                ConfigValue.set(&dict, "RejectFlicker", antiFlicker ? 1 : 0)
                let updated = ConfigValue.replacingObject(in: raw, with: dict)
                try await client.setConfig(paramName, updated)
                paramRaw = updated
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
            } else if hasImageParams {
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
            notice = "Configurações aplicadas."
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Configurações relacionadas a imagem e dia/noite, em JSON legível, para comparar modelos de câmera.
    /// Não inclui senhas.
    func diagnostic() async -> String {
        let ch = camera.channel - 1
        // (código, nome): 1042 = CONFIG_GET, 1360 = ABILITY_GET
        let requests: [(UInt16, String)] = [
            (1042, paramName), (1042, "Camera.ParamEx.[\(ch)]"), (1042, colorName),
            (1042, "Camera.WhiteLight"), (1042, "Camera.WhiteLight.[\(ch)]"),
            (1042, "CameraDayLightModes"), (1360, "CameraDayLightModes"),
            (1360, "ChannelSystemFunction"),
        ]
        var output = "Câmera: \(camera.name) · canal \(camera.channel)\n"
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            for (code, name) in requests {
                output += "\n== \(name)\(code == 1360 ? " (capacidade)" : "")\n"
                do {
                    let response = try await client.command(code: code, name: name, payload: nil)
                    guard let value = response[name] else { throw DVRIPError.invalidResponse }
                    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                    output += String(decoding: data, as: UTF8.self) + "\n"
                } catch {
                    output += "(não suportado: \(error.localizedDescription))\n"
                }
            }
        } catch {
            output += "\nFalha ao conectar: \(error.localizedDescription)\n"
        }
        return output
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

    private func readWhiteLight() {
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
