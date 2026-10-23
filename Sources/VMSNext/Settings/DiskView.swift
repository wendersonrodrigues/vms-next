import SwiftUI

/// "Gerenciamento de disco": StorageInfo (código 1020) com capacidade, espaço livre, estado e período gravado
/// de cada partição, e o que fazer quando o disco enche (General.General.OverWrite).
@MainActor
final class DiskModel: ObservableObject {
    struct Partition: Identifiable {
        let id: String
        let title: String
        let totalMB: Int
        let freeMB: Int
        let status: Int
        let isCurrent: Bool
        let oldest: String?
        let newest: String?

        var usedFraction: Double { totalMB > 0 ? Double(totalMB - freeMB) / Double(totalMB) : 0 }
    }

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var partitions: [Partition] = []
    @Published private(set) var hasOverwrite = false
    @Published var overwrite = true
    @Published var diagnosticText: String?

    let camera: Camera
    private var generalRaw: [String: Any]?

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
            let response = try await client.command(code: 1020, name: "StorageInfo", payload: nil)
            partitions = Self.parse(response["StorageInfo"])
            if partitions.isEmpty { error = "Nenhum disco ou cartão encontrado neste equipamento." }

            generalRaw = ConfigValue.object(in: try? await client.getConfig("General.General"))
            if let mode = generalRaw?["OverWrite"] as? String {
                hasOverwrite = true
                overwrite = mode == "OverWrite"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func applyOverwrite() async {
        guard var general = generalRaw else { return }
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            general["OverWrite"] = overwrite ? "OverWrite" : "StopRecord"
            try await client.setConfig("General.General", general)
            generalRaw = general
            notice = "Configuração aplicada."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: [(1020, "StorageInfo"), (1042, "General.General")])
    }

    /// StorageInfo: lista de discos físicos, cada um com "Partition" (TotalSpace/RemainSpace em MB, hex).
    static func parse(_ raw: Any?) -> [Partition] {
        let disks = raw as? [[String: Any]] ?? []
        var result: [Partition] = []
        for (diskIndex, disk) in disks.enumerated() {
            let physical = ConfigValue.int(disk["PlysicalNo"]) ?? diskIndex
            let parts = disk["Partition"] as? [[String: Any]] ?? []
            for (partIndex, part) in parts.enumerated() {
                let total = ConfigValue.int(part["TotalSpace"]) ?? 0
                guard total > 0 else { continue }
                let oldest = (part["OldStartTime"] as? String).flatMap(Self.validTime)
                let newest = (part["NewEndTime"] as? String).flatMap(Self.validTime)
                result.append(Partition(
                    id: "\(physical)-\(partIndex)",
                    title: parts.count > 1 ? "Disco \(physical + 1) · partição \(partIndex + 1)" : "Disco \(physical + 1)",
                    totalMB: total,
                    freeMB: ConfigValue.int(part["RemainSpace"]) ?? 0,
                    status: ConfigValue.int(part["Status"]) ?? 0,
                    isCurrent: part["IsCurrent"] as? Bool ?? false,
                    oldest: oldest,
                    newest: newest
                ))
            }
        }
        return result
    }

    /// Datas zeradas ("2000-00-00 00:00:00") significam que ainda não há gravação.
    private static func validTime(_ text: String) -> String? {
        DeviceTime.date(text) == nil || text.hasPrefix("2000-00") ? nil : text
    }
}

struct DiskView: View {
    @StateObject private var model: DiskModel

    init(camera: Camera) {
        _model = StateObject(wrappedValue: DiskModel(camera: camera))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    ForEach(model.partitions) { part in
                        Section(part.title) {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: part.usedFraction)
                                    .tint(part.usedFraction > 0.95 ? .orange : .accentColor)
                                Text("\(Self.size(part.totalMB - part.freeMB)) usados de \(Self.size(part.totalMB)) · \(Self.size(part.freeMB)) livres")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            LabeledContent("Estado", value: part.status == 0 ? "Normal" : "Com problema (\(part.status))")
                            LabeledContent("Em gravação", value: part.isCurrent ? "Sim" : "Não")
                            if let oldest = part.oldest, let newest = part.newest {
                                LabeledContent("Gravações de", value: "\(oldest) até \(newest)")
                            }
                        }
                    }
                    if model.hasOverwrite {
                        Section {
                            Picker(selection: $model.overwrite) {
                                Text("Sobrescrever as mais antigas").tag(true)
                                Text("Parar de gravar").tag(false)
                            } label: {
                                FieldLabel("Quando o disco encher", original: "Disco cheio",
                                           detail: "Sobrescrever mantém sempre os dias mais recentes; parar guarda o que já foi gravado, mas deixa de gravar.")
                            }
                        } footer: {
                            Text("Formatar o disco ainda não está disponível aqui; use o menu do equipamento.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Diagnóstico…") { Task { model.diagnosticText = await model.diagnostic() } }
                    .disabled(model.loading || model.saving)
                Button("Recarregar") { Task { await model.load() } }
                    .disabled(model.loading || model.saving)
                Button("Aplicar") { Task { await model.applyOverwrite() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasOverwrite || model.loading || model.saving)
            }
            .padding(12)
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    private static func size(_ megabytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1_048_576, countStyle: .binary)
    }
}
