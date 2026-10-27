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
                        Picker(selection: .constant(model.connectedByWifi ? 1 : 0)) {
                            Text("Interface cabeada").tag(0)
                            Text("Wi-Fi").tag(1)
                        } label: {
                            FieldLabel(String(localized: "Interface"), original: "Interface",
                                       detail: String(localized: "Por onde o VMS Next está falando com a câmera agora."))
                        }
                        .disabled(true)
                        if model.hasDHCP {
                            Toggle(isOn: $model.dhcp) {
                                FieldLabel(String(localized: "Habilitar DHCP"), original: "Habilitar DHCP",
                                           detail: String(localized: "O roteador escolhe o endereço. Pode mudar sozinho, o que faz o app perder a câmera."))
                            }
                            .disabled(!editable)
                        }
                        field(String(localized: "Endereço IP"), text: $model.ip)
                        field(String(localized: "Máscara de sub-rede"), text: $model.mask)
                        field("Gateway", text: $model.gateway)
                        if model.hasDNS {
                            TextField("DNS primário", text: $model.dns1)
                                .font(.system(.body, design: .monospaced))
                                .disabled(!editable)
                            TextField("DNS secundário", text: $model.dns2)
                                .font(.system(.body, design: .monospaced))
                                .disabled(!editable)
                        }
                    } header: {
                        Text("TCP/IP")
                    } footer: {
                        Text(model.connectedByWifi
                            ? String(localized: "Estes endereços são do cabo de rede. Os do Wi-Fi ficam na tela Wi-Fi.")
                            : String(localized: "Com DHCP o roteador escolhe o IP e ele pode mudar. Para câmeras de segurança, um IP fixo é mais confiável."))
                            .foregroundStyle(.secondary)
                    }

                    Section("Portas") {
                        LabeledContent("Porta TCP (DVRIP)", value: String(model.tcpPort))
                        TextField("Porta HTTP", value: $model.httpPort, format: .number.grouping(.never))
                            .disabled(!editable)
                        if model.onvifPort != nil {
                            TextField("Porta ONVIF", value: Binding(get: { model.onvifPort ?? 0 }, set: { model.onvifPort = $0 }),
                                      format: .number.grouping(.never))
                                .disabled(!editable)
                        } else if model.onvifProtect != nil {
                            // A Frente só manda o Enable; a porta fica no padrão da Xiongmai e não pode ser trocada.
                            LabeledContent {
                                Text("8899")
                            } label: {
                                FieldLabel(String(localized: "Porta ONVIF"), original: "Porta onvif",
                                           detail: String(localized: "Padrão da câmera; este modelo não deixa trocar."))
                            }
                        }
                    }

                    Section {
                        LabeledContent("Endereço MAC", value: model.mac.isEmpty ? "—" : model.mac)
                        if model.onvifProtect != nil {
                            Toggle(isOn: Binding(get: { model.onvifProtect ?? false }, set: { model.onvifProtect = $0 })) {
                                FieldLabel(String(localized: "Exigir senha no ONVIF"), original: "OnvifProtect",
                                           detail: String(localized: "Desligado, qualquer aparelho da rede consegue ver a câmera pelo ONVIF sem senha."))
                            }
                        }
                        if model.highSpeedDownload != nil {
                            Toggle(isOn: Binding(get: { model.highSpeedDownload ?? false }, set: { model.highSpeedDownload = $0 })) {
                                FieldLabel(String(localized: "Download rápido"), original: "Habilitar alta velocidade de download",
                                           detail: String(localized: "Baixa gravações mais rápido, usando mais da rede."))
                            }
                        }
                        if model.transferPlan != nil {
                            Picker(selection: Binding(get: { model.transferPlan ?? "" }, set: { model.transferPlan = $0 })) {
                                Text("Prioriza a qualidade (Pré qualidade)").tag("Quality")
                                Text("Prioriza a fluidez (Pré fluência)").tag("Fluency")
                                Text("Automático (Adaptativo)").tag("AutoAdapt")
                                Text("Prioriza a transmissão").tag("Transmission")
                                if let plan = model.transferPlan, !Self.plans.contains(plan) {
                                    Text(plan).tag(plan)
                                }
                            } label: {
                                FieldLabel(String(localized: "Política de transmissão"), original: "Política de transmissão de rede",
                                           detail: String(localized: "Em rede lenta, a fluidez reduz a qualidade para o vídeo não travar."))
                            }
                        }
                        if !model.hostName.isEmpty {
                            LabeledContent("Nome", value: model.hostName)
                        }
                    }
                    .disabled(!editable)

                    if let message = model.error ?? (editable ? model.validationError : nil) {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warning)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            SettingsFooter(notice: model.notice, busy: model.loading || model.saving,
                           applyDisabled: !editable || model.validationError != nil,
                           onDiagnostic: { model.diagnosticText = await model.diagnostic() },
                           onReload: { await model.load() },
                           onApply: {
                               if model.changesAddress {
                                   model.confirmingAddressChange = true
                               } else {
                                   Task { await model.apply() }
                               }
                           })
        }
        .task {
            let store = store
            model.onAddressChanged = { [weak store] old, new in store?.changeHost(from: old, to: new) }
            await model.load()
        }
        .confirmationDialog(
            String(localized: "Mudar o endereço da câmera?"),
            isPresented: $model.confirmingAddressChange
        ) {
            Button("Mudar endereço", role: .destructive) { Task { await model.apply() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(model.dhcp
                ? String(localized: "A câmera vai pedir um IP ao roteador e sair de \(model.camera.host). Você vai precisar descobrir o novo IP (no roteador ou no iCSee) para voltar a acessá-la.")
                : String(localized: "A câmera vai passar a responder em \(model.ip). Se o endereço estiver fora da sua rede, ela só volta pelo iCSee ou por reset de fábrica."))
        }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    private static let plans: Set<String> = ["Quality", "Fluency", "AutoAdapt", "Transmission"]

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .font(.system(.body, design: .monospaced))
            .disabled(model.dhcp || !editable)
    }
}
