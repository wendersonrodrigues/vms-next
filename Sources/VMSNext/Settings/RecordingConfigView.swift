import SwiftUI

/// "Config. de gravação": Record.[canal] com modo, duração dos arquivos, pré-gravação e agenda semanal.
/// A agenda tem uma máscara por período (bit 0 normal, bit 1 detecção, bit 2 alarme) e é editada no ScheduleGrid.
/// Gravação (Record) e foto (Storage.Snapshot) usam o mesmo formato de agenda; mudam o nome e os campos.
struct ScheduleKind {
    let title: String
    /// Nomes tentados em ordem para o canal (base 0).
    let configNames: (Int) -> [String]
    let modeKey: String
    let modes: [(value: String, label: String)]
    let scheduledMode: String
    let packetKey: String?
    let preKey: String
    let preLabel: String
    let preUnit: String

    static let recording = ScheduleKind(
        title: "gravação",
        configNames: { ["Record.[\($0)]"] },
        modeKey: "RecordMode",
        modes: [("ConfigRecord", "Por agenda"), ("ManualRecord", "Sempre gravando"), ("ClosedRecord", "Desligado")],
        scheduledMode: "ConfigRecord",
        packetKey: "PacketLength",
        preKey: "PreRecord",
        preLabel: "Pré-gravação",
        preUnit: " s"
    )

    static let snapshot = ScheduleKind(
        title: "foto",
        configNames: { ["Storage.Snapshot.[\($0)]", "Snapshot.[\($0)]"] },
        modeKey: "SnapMode",
        modes: [("ConfigSnap", "Por agenda"), ("ManualSnap", "Sempre"), ("ClosedSnap", "Desligado")],
        scheduledMode: "ConfigSnap",
        packetKey: nil,
        preKey: "PreSnap",
        preLabel: "Pré-captura",
        preUnit: " foto(s) antes do evento"
    )
}

@MainActor
final class RecordingConfigModel: ObservableObject {

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var loaded = false
    @Published var diagnosticText: String?

    @Published var mode = ""
    @Published private(set) var hasPacket = false
    @Published var packetMinutes = 60
    @Published var preRecordSeconds = 5
    @Published private(set) var hasRedundancy = false
    @Published var redundancy = false
    /// slots[dia][bloco] = máscara (1 normal, 2 detecção, 4 alarme)
    @Published var slots: [[Int]] = ScheduleCodec.emptyWeek()

    let camera: Camera
    let kind: ScheduleKind
    private var raw: Any?
    private var sectionsPerDay = 6
    private var name: String

    init(camera: Camera, kind: ScheduleKind = .recording) {
        self.camera = camera
        self.kind = kind
        name = kind.configNames(camera.channel - 1)[0]
        mode = kind.scheduledMode
    }

    var isScheduled: Bool { mode == kind.scheduledMode }

    var modeOptions: [(value: String, label: String)] {
        var options = kind.modes
        if !options.contains(where: { $0.value == mode }) { options.append((mode, "Modo do equipamento (\(mode))")) }
        return options
    }

    /// Cada dia precisa caber nos períodos que o equipamento aceita.
    var validationError: String? {
        guard isScheduled else { return nil }
        return ScheduleCodec.validate(slots, maxSections: sectionsPerDay)
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            raw = nil
            for candidate in kind.configNames(camera.channel - 1) {
                do {
                    raw = try await client.getConfig(candidate)
                    name = candidate
                    break
                } catch DVRIPError.device(607) {
                    continue
                }
            }
            guard let record = ConfigValue.object(in: raw) else {
                error = "Este equipamento não tem configuração de \(kind.title) para o canal \(camera.channel)."
                return
            }
            mode = record[kind.modeKey] as? String ?? kind.scheduledMode
            if let key = kind.packetKey, let value = ConfigValue.int(record[key]) {
                hasPacket = true
                packetMinutes = value
            }
            preRecordSeconds = ConfigValue.int(record[kind.preKey]) ?? 0
            if let value = record["Redundancy"] as? Bool {
                hasRedundancy = true
                redundancy = value
            }
            let sections = record["TimeSection"] as? [[String]] ?? []
            let masks = record["Mask"] as? [[Any]] ?? []
            sectionsPerDay = sections.first?.count ?? 6
            slots = ScheduleCodec.decode(sections: sections, masks: masks)
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply() async {
        if let validationError {
            error = validationError
            return
        }
        guard let raw, var record = ConfigValue.object(in: raw) else { return }
        saving = true
        error = nil
        notice = nil
        defer { saving = false }

        record[kind.modeKey] = mode
        if let key = kind.packetKey { ConfigValue.set(&record, key, packetMinutes) }
        ConfigValue.set(&record, kind.preKey, preRecordSeconds)
        if hasRedundancy { record["Redundancy"] = redundancy }

        var sections = record["TimeSection"] as? [[String]] ?? []
        var masks: [[Any]]? = record["Mask"] as? [[Any]] ?? []
        ScheduleCodec.encode(slots, sections: &sections, masks: &masks)
        record["TimeSection"] = sections
        record["Mask"] = masks

        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let updated = ConfigValue.replacingObject(in: raw, with: record)
            try await client.setConfig(name, updated)
            self.raw = updated
            let check = ConfigValue.object(in: try await client.getConfig(name))
            if let applied = check?[kind.modeKey] as? String, applied != mode {
                error = "O equipamento aceitou o comando mas manteve o modo \(applied)."
                return
            }
            notice = "Configuração de \(kind.title) aplicada."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        let ch = camera.channel - 1
        var names = kind.configNames(ch)
        if kind.modeKey == ScheduleKind.snapshot.modeKey {
            // Tela de foto do VMS antigo (intervalo / horários fixos com e-mail, FTP e disco).
            names += ["Snap.SnapConfig", "Snap.SnapConfig.[\(ch)]", "Snap.Breviary", "Snap.Breviary.[\(ch)]"]
        }
        return await ConfigDiagnostics.dump(camera: camera, requests: names.map { (1042, $0) })
    }
}

struct RecordingConfigView: View {
    @StateObject private var model: RecordingConfigModel

    init(camera: Camera, kind: ScheduleKind = .recording) {
        _model = StateObject(wrappedValue: RecordingConfigModel(camera: camera, kind: kind))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if model.loaded {
                        Section(model.kind.title.capitalized) {
                            Picker(selection: $model.mode) {
                                ForEach(model.modeOptions, id: \.value) { Text($0.label).tag($0.value) }
                            } label: {
                                FieldLabel("Modo", detail: "Por agenda segue o quadro abaixo; Sempre ignora o quadro; Desligado não faz nada.")
                            }
                            .pickerStyle(.segmented)
                            if model.hasPacket {
                                Stepper(value: $model.packetMinutes, in: 1 ... 120) {
                                    FieldLabel("Tamanho de cada arquivo: \(model.packetMinutes) min", original: "Tamanho do pacote",
                                               detail: "A gravação contínua é dividida em arquivos desta duração.")
                                }
                            }
                            Stepper(value: $model.preRecordSeconds, in: 0 ... 30) {
                                FieldLabel("\(model.kind.preLabel): \(model.preRecordSeconds)\(model.kind.preUnit)",
                                           detail: "Guarda também o que aconteceu logo antes do alarme.")
                            }
                            if model.hasRedundancy {
                                Toggle(isOn: $model.redundancy) {
                                    FieldLabel("Cópia de segurança", original: "Redundância",
                                               detail: "Grava em dois discos ao mesmo tempo. Só funciona com um disco extra reservado para isso.")
                                }
                            }
                        }
                        if model.isScheduled {
                            Section {
                                ScheduleGrid(slots: $model.slots, rows: ScheduleRow.recording,
                                             presets: [("Dia inteiro: só detecção + alarme", 6)])
                            } header: {
                                HStack {
                                    Text("Agenda semanal")
                                    Spacer()
                                    ScheduleLegend(rows: ScheduleRow.recording)
                                }
                            } footer: {
                                Text("Clique e arraste nas faixas para marcar ou desmarcar meia hora. Botão direito no nome do dia para copiar, preencher ou limpar.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let message = model.error ?? model.validationError {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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
                Button("Aplicar") { Task { await model.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.loaded || model.loading || model.saving || model.validationError != nil)
            }
            .padding(12)
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }
}
