import SwiftUI

struct CameraEditor: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var form: EditorForm

    init(camera: Camera) {
        _form = StateObject(wrappedValue: EditorForm(camera: camera))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Câmera") {
                    TextField("Nome", text: $form.camera.name)
                    TextField("Endereço IP", text: $form.camera.host)
                    TextField("Porta RTSP", value: $form.camera.rtspPort, format: .number.grouping(.never))
                    Stepper("Canal: \(form.camera.channel)", value: $form.camera.channel, in: 1 ... 64)
                }
                Section {
                    TextField("Usuário", text: $form.camera.username)
                    SecureField("Senha", text: $form.password)
                } header: {
                    Text("Acesso")
                } footer: {
                    Text("A senha fica no Keychain do macOS e vale para todos os canais do mesmo IP e usuário.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("Caminho RTSP", text: $form.camera.pathTemplate)
                        .font(.system(.body, design: .monospaced))
                    Button("Restaurar padrão Xiongmai") { form.camera.pathTemplate = Camera.xiongmaiPathTemplate }
                } header: {
                    Text("Avançado")
                } footer: {
                    Text("Marcadores: {user}, {password}, {channel}, {stream} (0 = principal, 1 = extra).")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.camera.name.isEmpty || form.camera.host.isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 520)
        .onAppear { form.password = store.password(for: form.camera) ?? "" }
    }

    private func save() {
        form.camera.name = form.camera.name.trimmingCharacters(in: .whitespaces)
        form.camera.host = form.camera.host.trimmingCharacters(in: .whitespaces)
        store.upsert(form.camera)
        store.setPassword(form.password, for: form.camera)
        dismiss()
    }
}

final class EditorForm: ObservableObject {
    @Published var camera: Camera
    @Published var password = ""

    init(camera: Camera) {
        self.camera = camera
    }
}
