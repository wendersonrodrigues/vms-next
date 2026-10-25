import SwiftUI

/// Config. de foto dos NVRs: Snap.SnapConfig.[canal], igual à tela do VMS antigo.
/// SnapType 0 = Intervalo (uma foto a cada N s por destino; 0 s = destino desligado),
/// 1 = Tempo de captura (horários fixos em TriggerSnap: triggerTime "0000-00-00 HH:MM:SS" + Email/FTP/Storage),
/// 2 = Fechar.
@MainActor
final class SnapConfigModel: ObservableObject {
    enum Availability {
        case unknown
        case available
        /// O equipamento não tem Snap.SnapConfig: usa a agenda (Storage.Snapshot).
        case unsupported
    }

    struct Trigger: Identifiable {
        let id = UUID()
        var time: String
        var email: Bool
        var ftp: Bool
        var storage: Bool
    }

    struct Destination: Identifiable {
        let key: String
        let label: String
        var enabled: Bool
        var seconds: Int
        var id: String { key }
    }

    static let types: [(value: Int, label: String)] = [(0, "Intervalo"), (1, "Tempo de captura"), (2, "Fechar")]
    static let defaultSeconds = 40

    @Published private(set) var availability = Availability.unknown
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var diagnosticText: String?

    @Published var snapType = 2
    @Published var destinations: [Destination] = []
    @Published var triggers: [Trigger] = []

    let camera: Camera
    private var raw: Any?
    private var name: String { "Snap.SnapConfig.[\(camera.channel - 1)]" }

    init(camera: Camera) {
        self.camera = camera
    }

    var validationError: String? {
        switch snapType {
        case 0:
            if !destinations.contains(where: \.enabled) { return "Marque pelo menos um destino para as fotos por intervalo." }
            if let bad = destinations.first(where: { $0.enabled && !(1 ... 86_400).contains($0.seconds) }) {
                return "\(bad.label): intervalo entre 1 e 86400 segundos."
            }
        case 1:
            if triggers.isEmpty { return "Adicione pelo menos um horário de captura." }
            for (index, trigger) in triggers.enumerated() {
                if Self.normalizedTime(trigger.time) == nil { return "Horário \(index + 1): use HH:MM:SS (ex.: 23:30:00)." }
                if !(trigger.email || trigger.ftp || trigger.storage) { return "Horário \(index + 1): marque pelo menos um destino." }
            }
        default:
            break
        }
        return nil
    }

    func addTrigger() {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        triggers.append(Trigger(time: String(format: "%02d:%02d:00", now.hour ?? 0, now.minute ?? 0),
                                email: false, ftp: false, storage: true))
    }

    func removeTrigger(_ id: Trigger.ID) {
        triggers.removeAll { $0.id == id }
    }

    /// "8:5" ou "08:05" → "08:05:00"; nil se inválido.
    static func normalizedTime(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard (2 ... 3).contains(parts.count), !parts.contains(nil) else { return nil }
        let h = parts[0]!, m = parts[1]!, sec = parts.count == 3 ? parts[2]! : 0
        guard (0 ... 23).contains(h), (0 ... 59).contains(m), (0 ... 59).contains(sec) else { return nil }
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            raw = try await client.getConfig(name)
            guard let config = ConfigValue.object(in: raw) else {
                availability = .unsupported
                return
            }
            availability = .available
            snapType = ConfigValue.int(config["SnapType"]) ?? 2
            let interval = config["IntervalSnap"] as? [String: Any] ?? [:]
            destinations = [("EmailTime", "E-mail"), ("FTPTime", "FTP"), ("StorageTime", "Disco")].map { key, label in
                let seconds = ConfigValue.int(interval[key]) ?? 0
                return Destination(key: key, label: label, enabled: seconds > 0, seconds: seconds > 0 ? seconds : Self.defaultSeconds)
            }
            triggers = (config["TriggerSnap"] as? [[String: Any]] ?? []).map { item in
                let stamp = item["triggerTime"] as? String ?? ""
                return Trigger(time: String(stamp.split(separator: " ").last ?? "00:00:00"),
                               email: item["Email"] as? Bool ?? false,
                               ftp: item["FTP"] as? Bool ?? false,
                               storage: item["Storage"] as? Bool ?? false)
            }
        } catch DVRIPError.device(607) {
            availability = .unsupported
        } catch {
            availability = .available
            self.error = error.localizedDescription
        }
    }

    func apply() async {
        if let validationError {
            error = validationError
            return
        }
        guard let raw, var config = ConfigValue.object(in: raw) else { return }
        saving = true
        error = nil
        notice = nil
        defer { saving = false }

        config["SnapType"] = snapType
        var interval = config["IntervalSnap"] as? [String: Any] ?? [:]
        for destination in destinations {
            interval[destination.key] = snapType == 0 && destination.enabled ? destination.seconds : 0
        }
        config["IntervalSnap"] = interval
        if snapType == 1 {
            config["TriggerSnap"] = triggers.map { trigger -> [String: Any] in
                ["triggerTime": "0000-00-00 \(Self.normalizedTime(trigger.time) ?? trigger.time)",
                 "Email": trigger.email, "FTP": trigger.ftp, "Storage": trigger.storage]
            }
        }

        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let updated = ConfigValue.replacingObject(in: raw, with: config)
            try await client.setConfig(name, updated)
            self.raw = updated
            let check = ConfigValue.object(in: try await client.getConfig(name))
            if let applied = ConfigValue.int(check?["SnapType"]), applied != snapType {
                error = "O equipamento aceitou o comando mas manteve o modo anterior."
                return
            }
            notice = "Configuração de foto aplicada."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: [(1042, name), (1042, "Snap.Breviary")])
    }
}

/// Escolhe a tela de foto: a do NVR (intervalo / horários) quando existe, senão a agenda da câmera.
struct PhotoConfigView: View {
    let camera: Camera
    @StateObject private var model: SnapConfigModel

    init(camera: Camera) {
        self.camera = camera
        _model = StateObject(wrappedValue: SnapConfigModel(camera: camera))
    }

    var body: some View {
        Group {
            switch model.availability {
            case .unknown:
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unsupported:
                RecordingConfigView(camera: camera, kind: .snapshot)
            case .available:
                SnapConfigForm(model: model)
            }
        }
        .task { await model.load() }
    }
}

private struct SnapConfigForm: View {
    @ObservedObject var model: SnapConfigModel

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section("Foto") {
                        Picker(selection: $model.snapType) {
                            ForEach(SnapConfigModel.types, id: \.value) { Text($0.label).tag($0.value) }
                        } label: {
                            FieldLabel("Modo", detail: "Intervalo tira fotos repetidamente; Tempo de captura tira nos horários da lista; Fechar desliga.")
                        }
                        .pickerStyle(.segmented)
                    }

                    if model.snapType == 0 {
                        Section {
                            ForEach($model.destinations) { $destination in
                                HStack {
                                    Toggle(destination.label, isOn: $destination.enabled)
                                        .toggleStyle(.checkbox)
                                        .frame(width: 120, alignment: .leading)
                                    TextField("", value: $destination.seconds, format: .number.grouping(.never))
                                        .labelsHidden()
                                        .textFieldStyle(.roundedBorder)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 80)
                                        .disabled(!destination.enabled)
                                    Text("segundos").foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                        } header: {
                            Text("Intervalo")
                        } footer: {
                            Text("Uma foto a cada intervalo, para cada destino marcado.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if model.snapType == 1 {
                        Section {
                            if model.triggers.isEmpty {
                                Text("Nenhum horário cadastrado.").foregroundStyle(.secondary)
                            } else {
                                Grid(alignment: .center, horizontalSpacing: 18, verticalSpacing: 8) {
                                    GridRow {
                                        Text("Nº")
                                        Text("Horário")
                                        Text("E-mail")
                                        Text("FTP")
                                        Text("Disco")
                                        Text("")
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    ForEach(Array($model.triggers.enumerated()), id: \.element.id) { index, $trigger in
                                        GridRow {
                                            Text("\(index + 1)").monospacedDigit()
                                            TextField("", text: $trigger.time)
                                                .labelsHidden()
                                                .textFieldStyle(.roundedBorder)
                                                .multilineTextAlignment(.center)
                                                .monospacedDigit()
                                                .frame(width: 90)
                                            Toggle("", isOn: $trigger.email).labelsHidden().toggleStyle(.checkbox)
                                            Toggle("", isOn: $trigger.ftp).labelsHidden().toggleStyle(.checkbox)
                                            Toggle("", isOn: $trigger.storage).labelsHidden().toggleStyle(.checkbox)
                                            Button(role: .destructive) {
                                                model.removeTrigger(trigger.id)
                                            } label: {
                                                Image(systemName: "minus.circle")
                                            }
                                            .buttonStyle(.borderless)
                                            .help("Remover horário")
                                            .accessibilityLabel("Remover horário")
                                        }
                                    }
                                }
                            }
                            Button {
                                model.addTrigger()
                            } label: {
                                Label("Adicionar horário", systemImage: "plus")
                            }
                        } header: {
                            Text("Tempo de captura")
                        } footer: {
                            Text("Uma foto por dia em cada horário (HH:MM:SS), enviada aos destinos marcados.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let message = model.error ?? model.validationError {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                }
                Spacer()
                Button("Diagnóstico…") { Task { model.diagnosticText = await model.diagnostic() } }
                    .disabled(model.loading || model.saving)
                Button("Recarregar") { Task { await model.load() } }
                    .disabled(model.loading || model.saving)
                Button("Aplicar") { Task { await model.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.loading || model.saving || model.validationError != nil)
            }
            .padding(Space.m)
        }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }
}
