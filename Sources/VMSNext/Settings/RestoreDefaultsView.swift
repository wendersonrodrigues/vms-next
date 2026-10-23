import SwiftUI

/// "Restaurar padrão" (Padrão no VMS antigo): OPDefaultConfig (código 1450) com uma chave por categoria.
/// Tudo começa desmarcado; rede e contas têm aviso porque fazem o app perder o acesso.
@MainActor
final class RestoreDefaultsModel: ObservableObject {
    struct Category: Identifiable {
        let key: String
        let title: String
        let detail: String
        /// Restaurar faz o app perder o acesso (IP ou senha mudam).
        let dangerous: Bool
        var selected = false
        var id: String { key }
    }

    @Published var categories: [Category] = [
        Category(key: "CameraPARAM", title: "Imagem", detail: "Brilho, cores, visão noturna, espelhar.", dangerous: false),
        Category(key: "Encode", title: "Qualidade do vídeo", detail: "Resolução, quadros por segundo e taxa de bits.", dangerous: false),
        Category(key: "Record", title: "Gravação", detail: "Agenda e modo de gravação.", dangerous: false),
        Category(key: "Alarm", title: "Alarmes", detail: "Detecção de movimento, pessoas, bloqueio e ações.", dangerous: false),
        Category(key: "CommPtz", title: "PTZ", detail: "Protocolo e presets de câmeras motorizadas.", dangerous: false),
        Category(key: "Preview", title: "Exibição no monitor", detail: "Divisão de tela e ronda no monitor do NVR.", dangerous: false),
        Category(key: "General", title: "Sistema", detail: "Data, idioma, padrão de vídeo, disco cheio.", dangerous: false),
        Category(key: "NetServer", title: "Serviços de rede", detail: "Nuvem, e-mail, FTP, DDNS e portas extras.", dangerous: false),
        Category(key: "NetCommon", title: "Rede", detail: "IP, máscara, gateway e portas. Pode trocar o IP e o app perder a câmera.", dangerous: true),
        Category(key: "Account", title: "Contas e senhas", detail: "Volta a senha de fábrica e apaga contas criadas. O app perde o acesso.", dangerous: true),
    ]
    @Published private(set) var running = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var confirming = false
    @Published private(set) var exporting = false

    let camera: Camera

    init(camera: Camera) {
        self.camera = camera
    }

    var selected: [Category] { categories.filter(\.selected) }

    func exportBackup() async {
        let name = (camera.group ?? camera.displayName).replacingOccurrences(of: "/", with: "-")
        guard let url = ConfigBackup.savePanel(suggested: "VMS Next - \(name) - antes do padrão.json") else { return }
        exporting = true
        defer { exporting = false }
        do {
            let summary = try await ConfigBackup.export(camera: camera, to: url)
            notice = "Cópia salva com \(summary.saved) configurações."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restore() async {
        let chosen = selected
        guard !chosen.isEmpty else { return }
        running = true
        error = nil
        notice = nil
        defer { running = false }
        var payload: [String: Any] = [:]
        for category in categories { payload[category.key] = category.selected }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            do {
                try await client.command(code: 1450, name: "OPDefaultConfig", payload: payload, accepted: [100, 150, 603])
            } catch let failure as DVRIPError where failure.isDisconnect {
                // O equipamento reiniciou antes de responder: esperado em algumas categorias.
            }
            DeviceSessions.shared.invalidate(account: camera.keychainAccount)
            for index in categories.indices { categories[index].selected = false }
            notice = "Restaurado: \(chosen.map(\.title).joined(separator: ", ")). O equipamento pode reiniciar."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RestoreDefaultsView: View {
    @StateObject private var model: RestoreDefaultsModel

    init(camera: Camera) {
        _model = StateObject(wrappedValue: RestoreDefaultsModel(camera: camera))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent {
                        Button {
                            Task { await model.exportBackup() }
                        } label: {
                            Label("Exportar cópia…", systemImage: "square.and.arrow.up")
                        }
                        .disabled(model.exporting)
                    } label: {
                        FieldLabel("Antes de restaurar, salve uma cópia",
                                   detail: "Com ela dá para voltar tudo depois em Manutenção → Importar cópia.")
                    }
                }
                Section {
                    ForEach($model.categories) { $category in
                        if !category.dangerous {
                            Toggle(isOn: $category.selected) {
                                FieldLabel(category.title, original: category.key, detail: category.detail)
                            }
                        }
                    }
                } header: {
                    Text("O que voltar ao padrão de fábrica")
                }
                Section {
                    ForEach($model.categories) { $category in
                        if category.dangerous {
                            Toggle(isOn: $category.selected) {
                                FieldLabel(category.title, original: category.key, detail: category.detail)
                            }
                            .tint(.red)
                        }
                    }
                } header: {
                    Label("Cuidado: o app perde o acesso", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } footer: {
                    Text("Depois de restaurar a rede, descubra o novo IP pelo roteador ou pelo iCSee. Depois de restaurar as contas, a senha volta a ser a de fábrica (normalmente vazia) e precisa ser definida de novo.")
                        .foregroundStyle(.secondary)
                }
                if let error = model.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(2)
                }
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button("Restaurar…", role: .destructive) { model.confirming = true }
                    .disabled(model.selected.isEmpty || model.running)
            }
            .padding(12)
        }
        .confirmationDialog("Restaurar o padrão de fábrica?", isPresented: $model.confirming) {
            Button("Restaurar", role: .destructive) { Task { await model.restore() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            let titles = model.selected.map(\.title).joined(separator: ", ")
            let danger = model.selected.contains(where: \.dangerous)
            Text("Vai apagar as configurações de: \(titles). Isso não pode ser desfeito sem uma cópia." + (danger ? " O app vai perder o acesso ao equipamento." : ""))
        }
    }
}
