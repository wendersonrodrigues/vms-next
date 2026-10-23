import Foundation

/// Lista de câmeras salva em ~/Library/Application Support/VMSNext/cameras.json.
final class CameraStore: ObservableObject {
    @Published var cameras: [Camera] = [] {
        didSet { save() }
    }

    /// Incrementado quando uma senha muda, para os mosaicos reconectarem.
    @Published private(set) var passwordRevision = 0

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VMSNext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cameras.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Camera].self, from: data)
        {
            cameras = Self.migrateGroups(saved)
            if cameras != saved { save() }
        }
    }

    /// Câmeras avulsas (fora de NVR), na ordem da lista.
    var standaloneCameras: [Camera] { cameras.filter { $0.group == nil } }

    /// NVRs na ordem em que aparecem na lista.
    var groups: [String] {
        var seen = Set<String>()
        return cameras.compactMap(\.group).filter { seen.insert($0).inserted }
    }

    /// No automático, câmeras avulsas com mais de um canal (várias lentes) usam DVRIP,
    /// porque o RTSP delas devolve a mesma lente para todos os canais.
    func resolvedLiveSource(for camera: Camera) -> LiveSource {
        guard camera.liveSource == .auto else { return camera.liveSource }
        let siblings = cameras.filter { $0.group == nil && $0.host == camera.host && $0.dvripPort == camera.dvripPort }
        return camera.group == nil && siblings.count > 1 ? .dvrip : .rtsp
    }

    func channels(in group: String) -> [Camera] {
        cameras.filter { $0.group == group }.sorted { $0.channel < $1.channel }
    }

    func removeGroup(_ group: String) {
        cameras.removeAll { $0.group == group }
    }

    /// Versões anteriores salvavam os canais do NVR como câmeras soltas ("NVR · Canal 2").
    /// Agrupa os itens cujo IP é um NVR no banco do VMS antigo.
    private static func migrateGroups(_ list: [Camera]) -> [Camera] {
        let recorders = LegacyVMSImporter.recorderHosts()
        return list.map { camera in
            guard camera.group == nil, recorders.contains(camera.host) else { return camera }
            var updated = camera
            let parts = camera.name.components(separatedBy: " · ")
            updated.group = parts.count > 1 ? parts[0] : camera.host
            updated.name = "Canal \(camera.channel)"
            return updated
        }
    }

    func password(for camera: Camera) -> String? {
        Keychain.password(for: camera.keychainAccount)
    }

    func setPassword(_ password: String, for camera: Camera) {
        Keychain.setPassword(password, for: camera.keychainAccount)
        passwordRevision += 1
        let account = camera.keychainAccount
        Task { @MainActor in DeviceSessions.shared.invalidate(account: account) }
    }

    func upsert(_ camera: Camera) {
        if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras[index] = camera
        } else {
            cameras.append(camera)
        }
    }

    /// Atualiza todas as câmeras de um IP (ex.: canais de um NVR) e leva a senha junto no Keychain.
    func changeHost(from old: String, to new: String) {
        guard old != new else { return }
        for index in cameras.indices where cameras[index].host == old {
            let before = cameras[index]
            cameras[index].host = new
            if let password = Keychain.password(for: before.keychainAccount),
               Keychain.password(for: cameras[index].keychainAccount) == nil
            {
                Keychain.setPassword(password, for: cameras[index].keychainAccount)
            }
        }
        passwordRevision += 1
    }

    func remove(_ camera: Camera) {
        cameras.removeAll { $0.id == camera.id }
    }

    /// Importa do VMS antigo as câmeras que ainda não existem (mesmo host e canal). Retorna quantas entraram.
    func importLegacy() throws -> Int {
        let existing = Set(cameras.map { "\($0.host)#\($0.channel)" })
        let new = try LegacyVMSImporter.load().filter { !existing.contains("\($0.host)#\($0.channel)") }
        cameras.append(contentsOf: new)
        return new.count
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cameras) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
