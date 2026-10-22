import Foundation

/// Uma sessão DVRIP por equipamento (usuário@host:porta), compartilhada entre os canais de um NVR.
@MainActor
final class DeviceSessions {
    static let shared = DeviceSessions()

    private var sessions: [String: Task<DVRIPClient, Error>] = [:]
    /// Equipamentos que recusaram a senha: não tentamos de novo até a senha mudar,
    /// para a câmera não bloquear o usuário por tentativas repetidas.
    private var rejected: Set<String> = []

    func client(for camera: Camera) async throws -> DVRIPClient {
        let key = "\(camera.keychainAccount):\(camera.dvripPort)"
        guard !rejected.contains(key) else { throw DVRIPError.authFailed }
        if let existing = sessions[key] {
            if let client = try? await existing.value, !client.isClosed { return client }
            sessions[key] = nil
        }
        guard let password = Keychain.password(for: camera.keychainAccount) else {
            throw DVRIPError.connection("defina a senha da câmera primeiro")
        }
        let task = Task { () throws -> DVRIPClient in
            let client = DVRIPClient(host: camera.host, port: camera.dvripPort)
            try await client.connect()
            try await client.login(username: camera.username, password: password)
            return client
        }
        sessions[key] = task
        do {
            return try await task.value
        } catch {
            sessions[key] = nil
            if case DVRIPError.authFailed = error { rejected.insert(key) }
            throw error
        }
    }

    /// Fecha as sessões de um usuário@host (por exemplo, quando a senha muda).
    func invalidate(account: String) {
        rejected = rejected.filter { !$0.hasPrefix(account + ":") }
        for (key, task) in sessions where key.hasPrefix(account + ":") {
            sessions[key] = nil
            Task { try? await task.value.close() }
        }
    }
}
