import Foundation

/// Lê configurações da câmera e devolve o JSON legível, para comparar modelos. Não inclui senhas.
enum ConfigDiagnostics {
    /// (código, nome): 1042 = CONFIG_GET, 1360 = ABILITY_GET
    @MainActor
    static func dump(camera: Camera, requests: [(UInt16, String)]) async -> String {
        var output = "Câmera: \(camera.displayName) · canal \(camera.channel)\n"
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            for (code, name) in requests {
                output += "\n== \(name)\(code == 1360 ? " (capacidade)" : "")\n"
                do {
                    let response = try await client.command(code: code, name: name, payload: nil)
                    guard let value = response[name] else { throw DVRIPError.invalidResponse }
                    let data = try JSONSerialization.data(withJSONObject: redacted(value), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
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

    /// Campos com senha ou hash de senha nunca saem no diagnóstico.
    private static let secretKeys: Set<String> = ["password", "passwordv2", "newpassword", "deraup", "nomd5", "passwd", "pwd"]

    static func redacted(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var clean: [String: Any] = [:]
            for (key, item) in dict {
                clean[key] = secretKeys.contains(key.lowercased()) || key.lowercased().contains("password") ? "(oculto)" : redacted(item)
            }
            return clean
        }
        if let list = value as? [Any] { return list.map(redacted) }
        return value
    }
}
