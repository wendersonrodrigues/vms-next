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
        /// Números usados pelo OPStorageManager para escolher o disco e a partição.
        let serial: Int
        let partNo: Int
        /// DirverType do StorageInfo: 0 leitura/gravação, 1 somente leitura, 3 redundante, 4 fotos.
        let type: Int?

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
    /// Ação de disco esperando confirmação.
    @Published var pendingAction: DiskAction?

    /// Ações da tela "Gerenciamento de disco" do VMS antigo (OPStorageManager).
    struct DiskAction: Identifiable {
        let id = UUID()
        let partition: Partition
        let action: String
        let type: String?
        let title: String
        let warning: String
    }

    static let types: [(value: String, code: Int, label: String)] = [
        ("ReadWrite", 0, String(localized: "Leitura e gravação (Leit/grav)")), ("ReadOnly", 1, String(localized: "Somente leitura")),
        ("Redundant", 3, String(localized: "Redundante (cópia de segurança)")), ("SnapShot", 4, String(localized: "Fotos (Foto)")),
    ]

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
            if partitions.isEmpty { error = String(localized: "Nenhum disco ou cartão encontrado neste equipamento.") }

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
            notice = String(localized: "Configuração aplicada.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: [
            (1020, "StorageInfo"), (1042, "General.General"), (1042, "Storage.StorageFailure"), (1042, "Storage.StorageLowSpace"),
            (1042, "Storage.StorageNotExist"), (1042, "Storage.StoragePosition"), (1042, "Status.RecordState"), (1020, "Status.RecordState"),
            (1042, "NetWork.NetNAS"), (1042, "Record.[0]"),
        ])
    }

    /// Executa a ação confirmada (código 1460, OPStorageManager) e lê o disco de novo.
    func run(_ action: DiskAction) async {
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            var payload: [String: Any] = ["Action": action.action, "PartNo": action.partition.partNo,
                                          "SerialNo": action.partition.serial]
            if let type = action.type { payload["Type"] = type }
            try await client.command(code: 1460, name: "OPStorageManager", payload: payload)
            AppLog.shared.add(.device, "Disco: \(action.title)", device: camera.displayName)
            notice = String(localized: "\(action.title): pedido enviado ao equipamento.")
            await load()
        } catch {
            self.error = error.localizedDescription
        }
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
                    title: parts.count > 1 ? String(localized: "Disco \(physical + 1) · partição \(partIndex + 1)") : "Disco \(physical + 1)",
                    totalMB: total,
                    freeMB: ConfigValue.int(part["RemainSpace"]) ?? 0,
                    status: ConfigValue.int(part["Status"]) ?? 0,
                    isCurrent: part["IsCurrent"] as? Bool ?? false,
                    oldest: oldest,
                    newest: newest,
                    serial: physical,
                    partNo: partIndex,
                    type: ConfigValue.int(part["DirverType"])
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
                                    .tint(part.usedFraction > 0.95 ? .orange : Theme.accent)
                                Text("\(Self.size(part.totalMB - part.freeMB)) usados de \(Self.size(part.totalMB)) · \(Self.size(part.freeMB)) livres")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            LabeledContent("Estado", value: part.status == 0 ? "Normal" : String(localized: "Com problema (\(part.status))"))
                            LabeledContent("Em gravação", value: part.isCurrent ? "Sim" : String(localized: "Não"))
                            if let oldest = part.oldest, let newest = part.newest {
                                LabeledContent("Gravações de", value: String(localized: "\(oldest) até \(newest)"))
                            }
                            if let type = part.type {
                                LabeledContent("Uso", value: DiskModel.types.first { $0.code == type }?.label ?? "Tipo \(type)")
                            }
                            HStack {
                                Menu("Usar para") {
                                    ForEach(DiskModel.types, id: \.value) { option in
                                        Button(option.label) {
                                            model.pendingAction = .init(partition: part, action: "SetType", type: option.value,
                                                                        title: "Usar \(part.title) para \(option.label.lowercased())",
                                                                        warning: String(localized: "O equipamento passa a usar este disco assim. Em \"Somente leitura\" ele para de gravar nele."))
                                        }
                                        .disabled(option.code == part.type)
                                    }
                                }
                                .fixedSize()
                                Button("Recuperar…") {
                                    model.pendingAction = .init(partition: part, action: "Recover", type: nil,
                                                                title: "Recuperar \(part.title)",
                                                                warning: String(localized: "Tenta corrigir erros do disco. Pode levar alguns minutos e a gravação pode parar enquanto isso."))
                                }
                                Spacer()
                                Button("Formatar…", role: .destructive) {
                                    model.pendingAction = .init(partition: part, action: "Clear", type: String(localized: "Data"),
                                                                title: "Formatar \(part.title)",
                                                                warning: String(localized: "Apaga TODAS as gravações e fotos deste disco. Não dá para desfazer."))
                                }
                            }
                            .disabled(model.saving)
                        }
                    }
                    if model.hasOverwrite {
                        Section {
                            Picker(selection: $model.overwrite) {
                                Text("Sobrescrever as mais antigas").tag(true)
                                Text("Parar de gravar").tag(false)
                            } label: {
                                FieldLabel(String(localized: "Quando o disco encher"), original: "Disco cheio",
                                           detail: String(localized: "Sobrescrever mantém sempre os dias mais recentes; parar guarda o que já foi gravado, mas deixa de gravar."))
                            }
                        } footer: {
                            Text("Particionar o disco ainda não está disponível aqui; use o VMS antigo ou o menu do equipamento.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            SettingsFooter(notice: model.notice, busy: model.loading || model.saving, applyDisabled: !model.hasOverwrite,
                           onDiagnostic: { model.diagnosticText = await model.diagnostic() },
                           onReload: { await model.load() },
                           onApply: { Task { await model.applyOverwrite() } })
        }
        .task { await model.load() }
        .confirmationDialog(model.pendingAction?.title ?? "", isPresented: Binding(
            get: { model.pendingAction != nil }, set: { if !$0 { model.pendingAction = nil } }
        ), presenting: model.pendingAction) { action in
            Button(action.action == "Clear" ? String(localized: "Apagar tudo e formatar") : "Confirmar", role: action.action == "Clear" ? .destructive : nil) {
                Task { await model.run(action) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { action in
            Text(action.warning)
        }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    private static func size(_ megabytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1_048_576, countStyle: .binary)
    }
}
