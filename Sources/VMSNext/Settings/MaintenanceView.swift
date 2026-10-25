import SwiftUI

/// "Manutenção": reiniciar agora (OPMachine, código 1450, Action "Reboot"), reinício automático
/// (General.AutoMaintain: AutoRebootDay, AutoRebootHour e AutoDeleteFilesDays), atualização on-line
/// (NetWork.OnlineUpgrade) e cópia das configurações (ConfigBackup).
@MainActor
final class MaintenanceModel: ObservableObject {
    static let days: [(value: String, label: String)] = [
        ("Never", String(localized: "Nunca")), ("Everyday", String(localized: "Todos os dias")),
        ("Sunday", String(localized: "Aos domingos")), ("Monday", String(localized: "Às segundas")), ("Tuesday", String(localized: "Às terças")),
        ("Wednesday", String(localized: "Às quartas")), ("Thursday", String(localized: "Às quintas")), ("Friday", String(localized: "Às sextas")), ("Saturday", String(localized: "Aos sábados")),
    ]

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var rebooting = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var diagnosticText: String?
    @Published var confirmingReboot = false

    @Published private(set) var hasAutoMaintain = false
    @Published var rebootDay = "Never"
    @Published var rebootHour = 3
    @Published private(set) var hasAutoDelete = false
    @Published var deleteDays = 0

    struct Flag: Identifiable {
        let key: String
        let title: String
        let original: String
        let detail: String
        var isOn: Bool
        var id: String { key }
    }

    /// Opções de NetWork.OnlineUpgrade (só as booleanas que o equipamento enviar).
    @Published var upgradeFlags: [Flag] = []
    private var upgradeRaw: Any?

    @Published var includeNetwork = false
    @Published var pendingImport: (url: URL, model: String, configs: [String: Any])?
    @Published var confirmingImport = false
    @Published private(set) var backupBusy = false

    let camera: Camera
    private var raw: Any?

    init(camera: Camera) {
        self.camera = camera
    }

    var dayOptions: [(value: String, label: String)] {
        var options = Self.days
        if !options.contains(where: { $0.value == rebootDay }) { options.append((rebootDay, rebootDay)) }
        return options
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            raw = try? await client.getConfig("General.AutoMaintain")
            if let config = ConfigValue.object(in: raw) {
                hasAutoMaintain = true
                rebootDay = config["AutoRebootDay"] as? String ?? "Never"
                rebootHour = ConfigValue.int(config["AutoRebootHour"]) ?? 3
                if let days = ConfigValue.int(config["AutoDeleteFilesDays"]) {
                    hasAutoDelete = true
                    deleteDays = days
                }
            }
            upgradeRaw = try? await client.getConfig("NetWork.OnlineUpgrade")
            if let upgrade = ConfigValue.object(in: upgradeRaw) {
                // Valores vêm como 0/1 (ou true/false). Os "Ignore…" e o servidor ficam como estão.
                let known: [(key: String, title: String, original: String, detail: String)] = [
                    ("Enable", String(localized: "Atualização on-line ligada"), String(localized: "Atualização on-line"),
                     String(localized: "Desligado, o equipamento não procura atualizações na internet.")),
                    ("AutoUpgradeImp", String(localized: "Instalar atualizações sozinho"), String(localized: "Atualização automática"),
                     String(localized: "Baixa e instala sozinho as atualizações importantes do fabricante.")),
                    ("AutoCheck", String(localized: "Avisar sobre novas versões"), String(localized: "Prompt for latest updates"),
                     String(localized: "Procura versões novas e avisa, sem instalar.")),
                ]
                upgradeFlags = known.compactMap { spec in
                    guard let value = upgrade[spec.key] else { return nil }
                    let isOn = (value as? Bool) ?? ((ConfigValue.int(value) ?? 0) != 0)
                    return Flag(key: spec.key, title: spec.title, original: spec.original, detail: spec.detail, isOn: isOn)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply() async {
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            if let raw, var config = ConfigValue.object(in: raw) {
                config["AutoRebootDay"] = rebootDay
                ConfigValue.set(&config, "AutoRebootHour", rebootHour)
                if hasAutoDelete { ConfigValue.set(&config, "AutoDeleteFilesDays", deleteDays) }
                let updated = ConfigValue.replacingObject(in: raw, with: config)
                try await client.setConfig("General.AutoMaintain", updated)
                self.raw = updated
            }
            if let raw = upgradeRaw, var upgrade = ConfigValue.object(in: raw), !upgradeFlags.isEmpty {
                // Mantém o tipo original (0/1 ou true/false).
                for flag in upgradeFlags {
                    // NSNumber 0/1 também passa em "is Bool"; o tipo CFBoolean distingue true/false de número.
                    let isBoolean = upgrade[flag.key].map { CFGetTypeID($0 as CFTypeRef) == CFBooleanGetTypeID() } ?? false
                    upgrade[flag.key] = isBoolean ? flag.isOn as Any : (flag.isOn ? 1 : 0) as Any
                }
                let updated = ConfigValue.replacingObject(in: raw, with: upgrade)
                try await client.setConfig("NetWork.OnlineUpgrade", updated)
                upgradeRaw = updated
            }
            notice = String(localized: "Manutenção aplicada.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Cópia das configurações

    func exportBackup() async {
        let name = (camera.group ?? camera.displayName).replacingOccurrences(of: "/", with: "-")
        let date = DeviceTime.string(Date()).prefix(10)
        guard let url = ConfigBackup.savePanel(suggested: "VMS Next - \(name) - \(date).json") else { return }
        backupBusy = true
        error = nil
        notice = nil
        defer { backupBusy = false }
        do {
            let summary = try await ConfigBackup.export(camera: camera, to: url)
            notice = String(localized: "Cópia salva com \(summary.saved) configurações.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func chooseImport() {
        guard let url = ConfigBackup.openPanel() else { return }
        do {
            let (model, configs) = try ConfigBackup.read(url)
            pendingImport = (url, model, configs)
            confirmingImport = true
        } catch {
            self.error = String(localized: "Arquivo inválido: não é uma cópia do VMS Next.")
        }
    }

    func runImport() async {
        guard let pending = pendingImport else { return }
        backupBusy = true
        error = nil
        notice = nil
        defer { backupBusy = false; pendingImport = nil }
        do {
            let result = try await ConfigBackup.restore(camera: camera, configs: pending.configs, includeNetwork: includeNetwork)
            notice = String(localized: "\(result.applied) configurações restauradas.")
            if !result.failed.isEmpty {
                error = String(localized: "O equipamento recusou: \(result.failed.joined(separator: ", ")).")
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reinicia o equipamento. A conexão cai logo em seguida, então "fechou a conexão" também conta como sucesso.
    func reboot() async {
        rebooting = true
        error = nil
        notice = nil
        defer { rebooting = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            do {
                try await client.command(code: 1450, name: "OPMachine", payload: ["Action": "Reboot"])
            } catch let failure as DVRIPError where failure.isDisconnect {
                // O equipamento desligou antes de responder: esperado.
            }
            DeviceSessions.shared.invalidate(account: camera.keychainAccount)
            notice = String(localized: "Reiniciando. O equipamento volta em cerca de 1 a 2 minutos; o vídeo reconecta sozinho.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: [(1042, "General.AutoMaintain"), (1042, "NetWork.OnlineUpgrade")])
    }
}

struct MaintenanceView: View {
    let isRecorder: Bool
    @StateObject private var model: MaintenanceModel

    init(camera: Camera, isRecorder: Bool) {
        self.isRecorder = isRecorder
        _model = StateObject(wrappedValue: MaintenanceModel(camera: camera))
    }

    private var deviceWord: String { isRecorder ? String(localized: "o NVR") : String(localized: "a câmera") }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo do equipamento…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        LabeledContent {
                            Button(role: .destructive) {
                                model.confirmingReboot = true
                            } label: {
                                Label("Reiniciar agora", systemImage: "arrow.clockwise.circle")
                            }
                            .disabled(model.rebooting)
                        } label: {
                            FieldLabel("Reiniciar \(deviceWord)", original: "Reiniciar",
                                       detail: String(localized: "Resolve travamentos. Durante 1 a 2 minutos não há vídeo nem gravação."))
                        }
                        if model.rebooting {
                            ProgressView().controlSize(.small)
                        }
                    } header: {
                        Text("Reiniciar")
                    }

                    if model.hasAutoMaintain {
                        Section {
                            Picker(selection: $model.rebootDay) {
                                ForEach(model.dayOptions, id: \.value) { Text($0.label).tag($0.value) }
                            } label: {
                                FieldLabel(String(localized: "Reiniciar automaticamente"), original: "Auto reboot",
                                           detail: String(localized: "Um reinício programado evita travamentos depois de muitos dias ligado."))
                            }
                            Picker(selection: $model.rebootHour) {
                                ForEach(0 ..< 24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                            } label: {
                                FieldLabel(String(localized: "Horário"), detail: String(localized: "Escolha um horário de pouco movimento, como de madrugada."))
                            }
                            .disabled(model.rebootDay == "Never")
                            if model.hasAutoDelete {
                                Stepper(value: $model.deleteDays, in: 0 ... 365) {
                                    FieldLabel(model.deleteDays == 0 ? String(localized: "Apagar gravações antigas: nunca")
                                                                     : String(localized: "Apagar gravações com mais de \(model.deleteDays) dias"),
                                               original: "Auto delete",
                                               detail: String(localized: "Apaga sozinho as gravações mais velhas que esse número de dias. 0 = nunca (o disco cheio já sobrescreve as mais antigas)."))
                                }
                            }
                        } header: {
                            Text("Manutenção automática")
                        }
                    }

                    if !model.upgradeFlags.isEmpty {
                        Section("Atualização on-line") {
                            ForEach($model.upgradeFlags) { $flag in
                                Toggle(isOn: $flag.isOn) {
                                    FieldLabel(flag.title, original: flag.original, detail: flag.detail)
                                }
                            }
                        }
                    }

                    Section {
                        HStack {
                            Button {
                                Task { await model.exportBackup() }
                            } label: {
                                Label("Exportar cópia…", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                model.chooseImport()
                            } label: {
                                Label("Importar cópia…", systemImage: "square.and.arrow.down")
                            }
                            if model.backupBusy { ProgressView().controlSize(.small) }
                        }
                        .disabled(model.backupBusy)
                        Toggle(isOn: $model.includeNetwork) {
                            FieldLabel(String(localized: "Incluir a rede ao importar"),
                                       detail: String(localized: "Restaura também IP, DNS e DHCP. Deixe desligado ao copiar para outro equipamento, para não repetir o IP."))
                        }
                    } header: {
                        Text("Cópia das configurações (Importar e exportar configuração)")
                    } footer: {
                        Text("Salva imagem, gravação, alarmes, sistema e rede de todos os canais num arquivo .json. Use antes de restaurar o padrão ou de trocar o equipamento.")
                            .foregroundStyle(.secondary)
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
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success).lineLimit(2)
                }
                Spacer()
                Button("Diagnóstico…") { Task { model.diagnosticText = await model.diagnostic() } }
                    .disabled(model.loading || model.saving)
                Button("Recarregar") { Task { await model.load() } }
                    .keyboardShortcut("r")
                    .disabled(model.loading || model.saving)
                Button("Aplicar") { Task { await model.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.loading || model.saving || (!model.hasAutoMaintain && model.upgradeFlags.isEmpty))
            }
            .padding(Space.m)
        }
        .task { await model.load() }
        .confirmationDialog("Reiniciar \(deviceWord) agora?", isPresented: $model.confirmingReboot) {
            Button("Reiniciar", role: .destructive) { Task { await model.reboot() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(isRecorder
                ? String(localized: "Todas as câmeras do NVR ficam sem gravação e sem vídeo por 1 a 2 minutos.")
                : String(localized: "A câmera fica sem vídeo e sem gravação por 1 a 2 minutos."))
        }
        .confirmationDialog("Restaurar esta cópia em \(deviceWord)?", isPresented: $model.confirmingImport) {
            Button("Restaurar", role: .destructive) { Task { await model.runImport() } }
            Button("Cancelar", role: .cancel) { model.pendingImport = nil }
        } message: {
            let count = model.pendingImport?.configs.count ?? 0
            let origin = model.pendingImport?.model ?? ""
            Text("\(count) configurações serão gravadas\(origin.isEmpty ? "" : " (cópia de um \(origin))"). \(model.includeNetwork ? "A rede também será restaurada." : "A rede não será alterada.")")
        }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }
}
