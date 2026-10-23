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
