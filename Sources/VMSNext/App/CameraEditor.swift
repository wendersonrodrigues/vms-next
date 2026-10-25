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
                    TextField("Porta de controle", value: $form.camera.dvripPort, format: .number.grouping(.never))
                    TextField("CloudID (número de série)", text: Binding(
                        get: { form.camera.cloudID ?? "" },
                        set: { form.camera.cloudID = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    ))
                    .help("Só para consulta. O VMS Next conecta pelo IP; o acesso pela nuvem (CloudID) não é suportado.")
                    Stepper("Canal: \(form.camera.channel)", value: $form.camera.channel, in: 1 ... 64)
                    TextField("NVR (vazio = câmera avulsa)", text: Binding(
                        get: { form.camera.group ?? "" },
                        set: { form.camera.group = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    ))
                    if form.camera.group != nil {
                        Picker(selection: $form.camera.sameAs) {
                            Text("Nenhuma").tag(Camera.ID?.none)
                            ForEach(store.standaloneCameras) { Text($0.name).tag(Optional($0.id)) }
                        } label: {
                            FieldLabel("Mesma câmera que",
                                       detail: "Câmera avulsa que este canal mostra; junta os alertas repetidos. Também dá para ligar em Eventos.")
                        }
                    }
                }
                Section {
                    TextField("Usuário", text: $form.camera.username)
                    HStack {
                        if form.showPassword {
                            TextField("Senha", text: $form.password)
                                .textSelection(.enabled)
                        } else {
                            SecureField("Senha", text: $form.password)
                        }
                        Button {
                            form.showPassword.toggle()
                        } label: {
                            Image(systemName: form.showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(form.showPassword ? "Esconder a senha" : "Mostrar a senha salva")
                        .accessibilityLabel(form.showPassword ? "Esconder a senha" : "Mostrar a senha")
                    }
                } header: {
                    Text("Acesso")
                } footer: {
                    Text("A senha fica no cofre criptografado do VMS Next e vale para todos os canais do mesmo IP e usuário.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker("Vídeo ao vivo", selection: $form.camera.liveSource) {
                        Text("Automático").tag(LiveSource.auto)
                        Text("RTSP").tag(LiveSource.rtsp)
                        Text("Protocolo Xiongmai").tag(LiveSource.dvrip)
                    }
                    TextField("Caminho RTSP", text: $form.camera.pathTemplate)
                        .font(.system(.body, design: .monospaced))
                    Button("Restaurar padrão Xiongmai") { form.camera.pathTemplate = Camera.xiongmaiPathTemplate }
                } header: {
                    Text("Avançado")
                } footer: {
                    Text("Automático usa RTSP, exceto em câmeras de várias lentes, que usam o protocolo Xiongmai. Marcadores do caminho: {user}, {password}, {channel}, {stream} (0 = principal, 1 = extra).")
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
    @Published var showPassword = false

    init(camera: Camera) {
        self.camera = camera
    }
}
