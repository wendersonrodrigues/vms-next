import SwiftUI

/// Configurações de uma câmera ONVIF (outra marca): o que o app sabe dela. Os ajustes de imagem, detecção e
/// rede dessas câmeras ficam no aplicativo da própria marca.
struct OnvifInfoView: View {
    let camera: Camera

    @EnvironmentObject private var store: CameraStore
    @StateObject private var model = OnvifInfoModel()

    var body: some View {
        Form {
            Section {
                LabeledContent("Fabricante", value: model.info?.manufacturer ?? camera.onvif?.manufacturer ?? "—")
                LabeledContent("Modelo", value: model.info?.model ?? camera.onvif?.model ?? "—")
                if let firmware = model.info?.firmware { LabeledContent("Firmware", value: firmware) }
                if let serial = model.info?.serial { LabeledContent("Número de série", value: serial) }
                LabeledContent("Endereço IP", value: camera.host)
                LabeledContent("Serviço ONVIF", value: camera.onvif?.deviceURL(host: camera.host)?.absoluteString ?? "—")
                    .textSelection(.enabled)
            } header: {
                Text("Câmera ONVIF")
            } footer: {
                if model.loading {
                    ProgressView().controlSize(.small)
                } else if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
            }
            Section("Vídeo") {
                LabeledContent("Principal (HD)", value: camera.onvif?.rtspURL(host: camera.host, sub: false) ?? "—")
                    .textSelection(.enabled)
                LabeledContent("Secundário (SD)", value: camera.onvif?.subURI == nil ? String(localized: "igual ao principal")
                                                            : camera.onvif?.rtspURL(host: camera.host, sub: true) ?? "—")
                    .textSelection(.enabled)
            }
            Section {
                Button("Diagnóstico ONVIF…") { Task { model.diagnosticText = await model.diagnostic(camera: camera) } }
                    .help("Testa os serviços, o PTZ e os alertas desta câmera e mostra o resultado (sem a senha)")
            }
            Section {
                Text("Esta câmera é de outra marca e está ligada pelo ONVIF. No VMS Next ela tem ao vivo, HD/SD, foto e gravação no Mac. Imagem, detecção, rede e as gravações do cartão dela se ajustam no aplicativo da própria marca.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: camera.id) { await model.load(camera: camera, password: store.password(for: camera)) }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }
}

@MainActor
final class OnvifInfoModel: ObservableObject {
    @Published private(set) var info: OnvifClient.DeviceInfo?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var diagnosticText: String?

    /// Lê de novo os serviços e testa o PTZ (lista de presets) e os alertas (assinatura), mostrando o que respondeu.
    func diagnostic(camera: Camera) async -> String {
        var out = "ONVIF: \(camera.displayName) · \(camera.host)\n"
        OnvifServices.shared.invalidate(camera)
        do {
            let entry = try await OnvifServices.shared.entry(for: camera)
            out += "\nServiço: \(entry.client.deviceURL.absoluteString)\nDiferença de relógio: \(Int(entry.client.clockOffset)) s\n"
            out += "Mídia: \(entry.media.absoluteString)\nPTZ: \(entry.ptz?.absoluteString ?? "—")\nEventos: \(entry.events?.absoluteString ?? "—")\n"
            out += "Perfil: \(entry.profile ?? "—")\nFoto: \(entry.snapshot?.absoluteString ?? "—")\n"
            out += "PTZ (endereços tentados): " + entry.ptzCandidates.map(\.path).joined(separator: ", ") + "\n"
            if entry.profile != nil {
                do {
                    _ = try await OnvifServices.shared.ptz(camera, action: "GetNodes") { _ in "<tptz:GetNodes/>" }
                    out += "\n== PTZ: respondeu ao GetNodes\n"
                    let presets = OnvifPTZ.presetList(try await OnvifServices.shared.ptz(camera, action: "GetPresets") { OnvifPTZ.presets(profile: $0) })
                    out += "== PTZ: \(presets.count) presets\n" + presets.map { "  \($0.token) · \($0.name)" }.joined(separator: "\n") + "\n"
                } catch {
                    out += "\n== PTZ: \(error.localizedDescription)\n"
                }
            }
            for url in [entry.events, entry.client.deviceURL].compactMap({ $0 }) {
                do {
                    let reply = try await entry.client.call(url, body: "<tev:CreatePullPointSubscription><tev:InitialTerminationTime>PT60S</tev:InitialTerminationTime></tev:CreatePullPointSubscription>")
                    out += "\n== Alertas em \(url.path): assinatura criada (\(reply.first("SubscriptionReference")?.value("Address") ?? "sem endereço"))\n"
                } catch {
                    out += "\n== Alertas em \(url.path): \(error.localizedDescription)\n"
                }
            }
            if let data = await OnvifServices.shared.snapshot(camera) {
                out += "\n== Foto: \(data.count / 1024) KB\n"
            } else {
                out += "\n== Foto: não veio\n"
            }
        } catch {
            out += "\nFalhou: \(error.localizedDescription)\n"
        }
        return out
    }

    func load(camera: Camera, password: String?) async {
        info = nil
        error = nil
        guard let password, var client = OnvifClient(camera: camera, password: password) else {
            error = String(localized: "Senha não definida")
            return
        }
        loading = true
        defer { loading = false }
        await client.syncClock()
        do {
            info = try await client.deviceInformation()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
