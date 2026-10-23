import Foundation

/// Lê configurações da câmera e devolve o JSON legível, para comparar modelos. Não inclui senhas.
enum ConfigDiagnostics {
    /// (código, nome): 1042 = CONFIG_GET, 1360 = ABILITY_GET
    @MainActor
    static func dump(camera: Camera, requests: [(UInt16, String)]) async -> String {
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
}
