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
            cameras = saved
        }
    }

    func password(for camera: Camera) -> String? {
        Keychain.password(for: camera.keychainAccount)
    }

    func setPassword(_ password: String, for camera: Camera) {
        Keychain.setPassword(password, for: camera.keychainAccount)
        passwordRevision += 1
    }

    func upsert(_ camera: Camera) {
        if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras[index] = camera
        } else {
            cameras.append(camera)
        }
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
