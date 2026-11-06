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
                Text("Esta câmera é de outra marca e está ligada pelo ONVIF. No VMS Next ela tem ao vivo, HD/SD, foto e gravação no Mac. Imagem, detecção, rede e as gravações do cartão dela se ajustam no aplicativo da própria marca.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: camera.id) { await model.load(camera: camera, password: store.password(for: camera)) }
    }
}

@MainActor
final class OnvifInfoModel: ObservableObject {
    @Published private(set) var info: OnvifClient.DeviceInfo?
    @Published private(set) var loading = false
    @Published private(set) var error: String?

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
