import SwiftUI

/// "Saída de alarme": Alarm.AlarmOut.[n], uma por borne de saída (sirene, luz, relé). O total vem de
/// SystemInfo.AlarmOutChannel. AlarmOutType é o modo (AUTO = Schedule, MANUAL, CLOSE = Fechado) e
/// AlarmOutStatus é o "Estado" do VMS antigo (OPEN = ligada, CLOSE = desligada), usado no modo manual.
@MainActor
final class AlarmOutputModel: ObservableObject {
    struct Output: Identifiable {
        let index: Int
        let name: String
        var raw: Any
        var mode: String
        var isOn: Bool
        var hasState: Bool
        var id: Int { index }
    }

    static let modes: [(value: String, label: String, detail: String)] = [
        ("AUTO", String(localized: "Automático (Schedule)"), String(localized: "Liga sozinha quando um alarme configurado para \"Acionar saída de alarme\" dispara.")),
        ("MANUAL", "Manual", String(localized: "Você liga e desliga pela opção \"Ligada agora\" abaixo.")),
        ("CLOSE", String(localized: "Desligada (Fechado)"), String(localized: "Nunca liga, mesmo com alarmes.")),
    ]

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var diagnosticText: String?
    @Published var outputs: [Output] = []
    @Published private(set) var outputCount: Int?

    let camera: Camera

    init(camera: Camera) {
        self.camera = camera
    }

    func options(for output: Output) -> [(value: String, label: String, detail: String)] {
        var options = Self.modes
        if !options.contains(where: { $0.value == output.mode }) {
            options.append((output.mode, String(localized: "Modo do equipamento (\(output.mode))"), ""))
        }
        return options
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let info = try? await client.command(code: 1020, name: "SystemInfo", payload: nil)
            let count = ConfigValue.int((info?["SystemInfo"] as? [String: Any])?["AlarmOutChannel"]) ?? 0
            outputCount = count
            var result: [Output] = []
            for index in 0 ..< count {
                let name = "Alarm.AlarmOut.[\(index)]"
                guard let raw = try? await client.getConfig(name), let config = ConfigValue.object(in: raw) else { continue }
                let state = (config["AlarmOutStatus"] as? String)?.uppercased()
                result.append(Output(index: index, name: name, raw: raw,
                                     mode: (config["AlarmOutType"] as? String ?? "AUTO").uppercased(),
                                     isOn: state == "OPEN", hasState: state != nil))
            }
            outputs = result
            if count == 0 {
                error = String(localized: "Este equipamento não tem saída de alarme (nenhum borne de sirene ou relé).")
            } else if outputs.isEmpty {
                error = String(localized: "O equipamento informou \(count) saída(s), mas não respondeu à configuração. Use \"Diagnóstico…\" e me envie o resultado.")
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
            for index in outputs.indices {
                let output = outputs[index]
                guard var config = ConfigValue.object(in: output.raw) else { continue }
                config["AlarmOutType"] = output.mode
                if output.hasState { config["AlarmOutStatus"] = output.isOn ? "OPEN" : "CLOSE" }
                let updated = ConfigValue.replacingObject(in: output.raw, with: config)
                try await client.setConfig(output.name, updated)
                outputs[index].raw = updated
            }
            notice = String(localized: "Saída de alarme aplicada.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        let count = max(outputCount ?? 1, 1)
        return await ConfigDiagnostics.dump(camera: camera, requests:
            (0 ..< count).map { (UInt16(1042), "Alarm.AlarmOut.[\($0)]") } + [(1042, "Alarm.AlarmOut")])
    }
}

struct AlarmOutputView: View {
    @StateObject private var model: AlarmOutputModel

    init(camera: Camera) {
        _model = StateObject(wrappedValue: AlarmOutputModel(camera: camera))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if !model.outputs.isEmpty {
                        Section {
                            Text("A saída de alarme liga um aparelho conectado aos bornes ALARM OUT do equipamento: sirene, luz ou relé (portão, fechadura). Quais alarmes acionam a saída se escolhe em cada alarme, na opção \"Acionar saída de alarme\".")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach($model.outputs) { $output in
                        Section("Saída \(output.index + 1)") {
                            Picker(selection: $output.mode) {
                                ForEach(model.options(for: output), id: \.value) { option in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                        if !option.detail.isEmpty {
                                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .tag(option.value)
                                }
                            } label: {
                                FieldLabel(String(localized: "Modo"), original: "Modo de alarme")
                            }
                            .pickerStyle(.radioGroup)
                            if output.hasState {
                                Toggle(isOn: $output.isOn) {
                                    FieldLabel(String(localized: "Ligada agora"), original: "Estado",
                                               detail: output.mode == "MANUAL"
                                                   ? String(localized: "Liga ou desliga a saída na hora ao aplicar.")
                                                   : String(localized: "Estado atual da saída. Para ligar e desligar por aqui, use o modo Manual."))
                                }
                                .disabled(output.mode != "MANUAL")
                            }
                        }
                    }
                    if let message = model.error {
                        Section {
                            Label(message, systemImage: model.outputCount == 0 ? "info.circle" : "exclamationmark.triangle.fill")
                                .foregroundStyle(model.outputCount == 0 ? Color.secondary : Theme.warning)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            SettingsFooter(notice: model.notice, busy: model.loading || model.saving, applyDisabled: model.outputs.isEmpty,
                           onDiagnostic: { model.diagnosticText = await model.diagnostic() },
                           onReload: { await model.load() },
                           onApply: { Task { await model.apply() } })
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }
}
