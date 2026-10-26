import Foundation

/// Registro do próprio VMS Next ("Cliente" no VMS antigo): entradas e saídas, configurações alteradas,
/// reinícios, downloads, fotos e gravações no Mac. Guardado em applog.json pelo tempo escolhido.
@MainActor
final class AppLog: ObservableObject {
    enum Category: String, Codable, CaseIterable, Identifiable {
        case login, config, device, alarm, recording, file

        var id: String { rawValue }
        var label: String {
            switch self {
            case .login: return String(localized: "Entrada e saída")
            case .config: return String(localized: "Configuração")
            case .device: return String(localized: "Equipamento")
            case .alarm: return String(localized: "Alertas")
            case .recording: return String(localized: "Gravação no Mac")
            case .file: return String(localized: "Fotos e downloads")
            }
        }
    }

    struct Entry: Identifiable, Codable {
        var id = UUID()
        let date: Date
        let category: Category
        let text: String
        var device: String?
    }

    static let shared = AppLog()

    @Published private(set) var entries: [Entry] = []
    private var saveWork: DispatchWorkItem?
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VMSNext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("applog.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
        prune()
    }

    func add(_ category: Category, _ text: String, device: String? = nil) {
        entries.insert(Entry(date: Date(), category: category, text: text, device: device), at: 0)
        prune()
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// Apaga o que passou do tempo escolhido em Preferências (e limita o tamanho do arquivo).
    private func prune() {
        let days = AppPreferences.shared.logDays
        let limit = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        entries.removeAll { $0.date < limit }
        if entries.count > 20000 { entries.removeLast(entries.count - 20000) }
    }

    private func save() {
        saveWork?.cancel()
        let snapshot = entries
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Para chamar de fora da thread principal (ex.: o cliente DVRIP).
    nonisolated static func record(_ category: Category, _ text: String, device: String? = nil) {
        Task { @MainActor in AppLog.shared.add(category, text, device: device) }
    }
}
