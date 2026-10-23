import SwiftUI

struct NetworkView: View {
    @EnvironmentObject private var store: CameraStore
    @StateObject private var model: NetworkModel

    init(camera: Camera) {
        _model = StateObject(wrappedValue: NetworkModel(camera: camera))
    }

    private var editable: Bool { model.decodingVerified && !model.saving }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        if model.hasDHCP {
                            Toggle("Obter IP automaticamente (DHCP)", isOn: $model.dhcp)
                        }
                        field("Endereço IP", text: $model.ip)
                        field("Máscara de sub-rede", text: $model.mask)
                        field("Gateway", text: $model.gateway)
                    } header: {
                        Text("Endereço")
                    } footer: {
                        Text("Com DHCP o roteador escolhe o IP e ele pode mudar. Para câmeras de segurança, um IP fixo é mais confiável.")
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!editable)

                    if model.hasDNS {
                        Section("DNS") {
                            TextField("DNS primário", text: $model.dns1)
                            TextField("DNS secundário", text: $model.dns2)
                        }
                        .disabled(!editable)
                    }

                    Section("Portas") {
                        TextField("Porta HTTP", value: $model.httpPort, format: .number.grouping(.never))
                            .disabled(!editable)
                        LabeledContent("Porta de controle (DVRIP)", value: String(model.tcpPort))
                    }

                    Section("Equipamento") {
                        LabeledContent("Endereço MAC", value: model.mac.isEmpty ? "—" : model.mac)
                        LabeledContent("Nome", value: model.hostName.isEmpty ? "—" : model.hostName)
                    }

                    if let message = model.error ?? (editable ? model.validationError : nil) {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        .lineLimit(2)
                }
                Spacer()
                Button("Diagnóstico…") { Task { model.diagnosticText = await model.diagnostic() } }
                    .disabled(model.loading || model.saving)
                Button("Recarregar") { Task { await model.load() } }
                    .disabled(model.loading || model.saving)
                Button("Aplicar") {
                    if model.changesAddress {
                        model.confirmingAddressChange = true
                    } else {
                        Task { await model.apply() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!editable || model.loading || model.validationError != nil)
            }
            .padding(12)
        }
        .task {
            let store = store
            model.onAddressChanged = { [weak store] old, new in store?.changeHost(from: old, to: new) }
            await model.load()
        }
        .confirmationDialog(
            "Mudar o endereço da câmera?",
            isPresented: $model.confirmingAddressChange
        ) {
            Button("Mudar endereço", role: .destructive) { Task { await model.apply() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(model.dhcp
                ? "A câmera vai pedir um IP ao roteador e sair de \(model.camera.host). Você vai precisar descobrir o novo IP (no roteador ou no iCSee) para voltar a acessá-la."
                : "A câmera vai passar a responder em \(model.ip). Se o endereço estiver fora da sua rede, ela só volta pelo iCSee ou por reset de fábrica.")
        }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .font(.system(.body, design: .monospaced))
            .disabled(model.dhcp)
    }
}
