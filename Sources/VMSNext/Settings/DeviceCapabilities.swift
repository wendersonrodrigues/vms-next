import Foundation

/// Capacidades que o equipamento informa (ABILITY_GET, código 1360): o que ele suporta, como resoluções,
/// funções de alarme e de rede. O VMS antigo usa estas mesmas listas para montar as telas.
enum DeviceCapabilities {
    /// Nomes pedidos pelo VMS antigo, mais alguns comuns na Xiongmai. Os não suportados aparecem
    /// como "não suportado" no diagnóstico.
    static let names = [
        "SystemFunction", "EncodeCapability", "BlindCapability", "NetAbility", "EthernetAbility",
        "ChnDAModeAbility", "Camera", "MotionArea", "PTZProtocol", "UartProtocol", "TalkAudioFormat",
        "MultiLanguage", "MultiVstd", "DDNSService", "NetOrder",
    ]

    /// Configurações de capacidade lidas com CONFIG_GET.
    static let configNames = ["AVEnc.H264Ability", "NetUse.DigitalAbility", "NetUse.DigitalHumanAbility"]

    /// Função ligada em SystemFunction, ex.: "AlarmFunction.LossDetect". Sem a lista, considera suportada.
    static func supports(_ functions: [String: Any]?, _ path: String) -> Bool {
        guard let functions else { return true }
        let parts = path.split(separator: ".").map(String.init)
        guard parts.count == 2, let group = functions[parts[0]] as? [String: Any] else { return false }
        return (group[parts[1]] as? Bool) ?? ((group[parts[1]] as? NSNumber)?.boolValue ?? false)
    }

    private static var cache: [String: [String: Any]] = [:]
    private static var profiles: [String: Profile] = [:]

    /// Tudo o que o VMS antigo consulta para montar as telas de um equipamento: SystemFunction,
    /// a capacidade "Camera" (modos dia/noite, luz dupla) e o SystemInfo (saídas de alarme).
    /// Campos nil = o equipamento não informou; nesse caso as telas mostram tudo, como antes.
    struct Profile {
        var functions: [String: Any]?
        var camera: [String: Any]?
        var system: [String: Any]?

        static let empty = Profile()

        /// Função em SystemFunction, ex.: "OtherFunction.SupportCameraWhiteLight".
        func supports(_ path: String) -> Bool { DeviceCapabilities.supports(functions, path) }

        /// Função que só vale se o equipamento disser que tem (sem a lista, considera que não tem).
        func has(_ path: String) -> Bool { functions != nil && supports(path) }

        /// Campo da capacidade "Camera" ligado (1 ou true).
        func cameraFlag(_ key: String) -> Bool {
            guard let value = camera?[key] else { return false }
            if let bool = value as? Bool { return bool }
            return ConfigValue.int(value) == 1
        }

        /// Saídas de alarme (sirene/relé). nil quando o equipamento não informou.
        var alarmOutputs: Int? { system.flatMap { ConfigValue.int($0["AlarmOutChannel"]) } }
    }

    /// Perfil do equipamento (guardado por endereço; lido uma vez por abertura do app).
    @MainActor
    static func profile(for camera: Camera) async -> Profile {
        let key = "\(camera.host):\(camera.dvripPort)"
        if let cached = profiles[key] { return cached }
        guard let client = try? await DeviceSessions.shared.client(for: camera) else { return .empty }
        var profile = Profile()
        profile.functions = await systemFunction(for: camera)
        profile.camera = (try? await client.command(code: 1360, name: "Camera", payload: nil))?["Camera"] as? [String: Any]
        profile.system = (try? await client.command(code: 1020, name: "SystemInfo", payload: nil))?["SystemInfo"] as? [String: Any]
        if profile.functions != nil { profiles[key] = profile }
        return profile
    }

    /// Funções que só câmeras com motor informam (ronda, posição de repouso, retomar posição).
    static let ptzFunctions = ["OtherFunction.SupportPTZTour", "OtherFunction.SupportPtzIdleState",
                               "OtherFunction.SupportResumePtzState"]

    /// A câmera tem PTZ? Escolha manual vence; senão, as capacidades da própria câmera (ou da câmera avulsa
    /// ligada ao canal do NVR). Sem informação nenhuma, considera que não tem.
    @MainActor
    static func hasPTZ(_ camera: Camera, in cameras: [Camera]) async -> Bool {
        switch camera.ptz {
        case .yes: return true
        case .no: return false
        case .auto: break
        }
        var source = camera
        if camera.group != nil {
            guard let id = camera.sameAs, let linked = cameras.first(where: { $0.id == id }) else { return false }
            if linked.ptz != .auto { return linked.ptz == .yes }
            source = linked
        }
        guard let functions = await systemFunction(for: source) else { return false }
        return ptzFunctions.contains { supports(functions, $0) }
    }

    /// SystemFunction do equipamento (guardado por endereço). nil quando ele não informa.
    @MainActor
    static func systemFunction(for camera: Camera) async -> [String: Any]? {
        let key = "\(camera.host):\(camera.dvripPort)"
        if let cached = cache[key] { return cached }
        guard let client = try? await DeviceSessions.shared.client(for: camera),
              let response = try? await client.command(code: 1360, name: "SystemFunction", payload: nil),
              let value = response["SystemFunction"] as? [String: Any] else { return nil }
        cache[key] = value
        return value
    }

    @MainActor
    static func diagnostic(camera: Camera) async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests:
            names.map { (UInt16(1360), $0) } + configNames.map { (UInt16(1042), $0) })
    }
}
