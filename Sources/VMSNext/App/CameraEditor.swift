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
                if form.camera.isOnvif {
                    onvifSections
                } else {
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
                            FieldLabel(String(localized: "Mesma câmera que"),
                                       detail: String(localized: "Câmera avulsa que este canal mostra; junta os alertas repetidos. Também dá para ligar em Eventos."))
                        }
                    }
                }
                if form.camera.group == nil, !store.groups.isEmpty {
                    recordingsSection
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
                        .help(form.showPassword ? String(localized: "Esconder a senha") : String(localized: "Mostrar a senha salva"))
                        .accessibilityLabel(form.showPassword ? String(localized: "Esconder a senha") : String(localized: "Mostrar a senha"))
                    }
                } header: {
                    Text("Acesso")
                } footer: {
                    Text("A senha fica no cofre criptografado do VMS Next e vale para todos os canais do mesmo IP e usuário.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker(selection: $form.camera.ptz) {
                        ForEach(PTZSupport.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: {
                        FieldLabel("PTZ (motor)", detail: String(localized: "Mostra o botão PTZ no mosaico. No automático, segue o que a câmera informa."))
                    }
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
            }
            .formStyle(.grouped)

            HStack {
                if form.checking { ProgressView().controlSize(.small) }
                if let error = form.onvifError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .lineLimit(3)
                }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.camera.name.isEmpty || form.camera.host.isEmpty || form.checking)
            }
            .padding()
        }
        .frame(width: 460, height: 520)
        .onAppear {
            form.password = store.password(for: form.camera) ?? ""
            form.onvifKey = "\(form.camera.host)|\(form.camera.onvif?.port ?? 0)|\(form.camera.onvif?.path ?? "")|\(form.camera.username)|\(form.password)"
            form.originalChannel = store.linkedChannel(for: form.camera)?.id
            form.nvrChannel = form.originalChannel
        }
    }

    // MARK: - Gravações no NVR

    /// Câmera avulsa Xiongmai: cartão, NVR ou os dois, e o canal do NVR que mostra esta câmera.
    @ViewBuilder
    private var recordingsSection: some View {
            Section {
                Picker(selection: $form.camera.recordingsFrom) {
                    ForEach(RecordingSource.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    FieldLabel(String(localized: "Gravações vêm de"),
                               detail: String(localized: "Sem cartão: Gravações e o ▶ dos alertas buscam o vídeo no NVR, no canal que mostra esta câmera. Com os dois, as Gravações começam pelo NVR e têm uma chave para trocar."))
                }
                if form.camera.recordingsFrom != .camera {
                    Picker(selection: $form.nvrChannel) {
                        Text("Escolha o canal").tag(Camera.ID?.none)
                        ForEach(store.groups, id: \.self) { group in
                            Section(group) {
                                ForEach(store.channels(in: group)) { channel in
                                    Text(channel.displayName).tag(Optional(channel.id))
                                }
                            }
                        }
                    } label: {
                        FieldLabel(String(localized: "Canal do NVR"),
                                   detail: String(localized: "O mesmo canal ligado em Eventos (\"Mesma câmera no NVR\"); também junta os alertas repetidos."))
                    }
                    if form.nvrChannel == nil {
                        Label("Sem um canal escolhido, as gravações continuam vindo do cartão da câmera.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                }
            } header: {
                Text("Gravações")
            }
    }

    private var nvrChannelPicker: some View {
        Picker(selection: $form.nvrChannel) {
            Text("Não está no NVR").tag(Camera.ID?.none)
            ForEach(store.groups, id: \.self) { group in
                Section(group) {
                    ForEach(store.channels(in: group)) { channel in
                        Text(channel.displayName).tag(Optional(channel.id))
                    }
                }
            }
        } label: {
            FieldLabel(String(localized: "Canal do NVR"),
                       detail: String(localized: "O canal do NVR que mostra esta câmera. As Gravações e o ▶ dos alertas buscam o vídeo nele, e os alertas repetidos são juntados."))
        }
    }

    // MARK: - ONVIF

    private var passwordField: some View {
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
            .help(form.showPassword ? String(localized: "Esconder a senha") : String(localized: "Mostrar a senha salva"))
            .accessibilityLabel(form.showPassword ? String(localized: "Esconder a senha") : String(localized: "Mostrar a senha"))
        }
    }

    /// Câmera de outra marca: só o que o ONVIF precisa. Os endereços do vídeo são lidos da câmera ao salvar.
    @ViewBuilder
    private var onvifSections: some View {
        let info = Binding(get: { form.camera.onvif ?? OnvifInfo() }, set: { form.camera.onvif = $0 })
        Section {
            TextField("Nome", text: $form.camera.name)
            TextField("Endereço IP", text: $form.camera.host)
            TextField("Porta ONVIF", value: info.port, format: .number.grouping(.never))
                .help("Porta do serviço ONVIF da câmera (a busca na rede já preenche). Comuns: 80, 8899, 5000.")
        } header: {
            Text("Câmera ONVIF (outra marca)")
        }
        Section {
            TextField("Usuário", text: $form.camera.username)
            passwordField
        } header: {
            Text("Acesso")
        } footer: {
            Text("O usuário e a senha do ONVIF da câmera (muitas marcas usam \"admin\" e a senha do aplicativo delas). A senha fica no cofre criptografado do VMS Next.")
                .foregroundStyle(.secondary)
        }
        Section {
            Picker(selection: $form.camera.ptz) {
                ForEach(PTZSupport.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                FieldLabel("PTZ (motor)", detail: String(localized: "No automático, aparece se a câmera aceitar o PTZ pelo ONVIF ou se estiver ligada a um canal do NVR (aí o PTZ vai pelo NVR)."))
            }
        }
        if !store.groups.isEmpty {
            Section {
                nvrChannelPicker
            } header: {
                Text("Gravações")
            } footer: {
                Text("O app não lê o cartão de câmeras ONVIF. Se o NVR grava esta câmera, escolha o canal dela para ver as gravações pelo NVR.")
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            LabeledContent("Principal (HD)", value: form.camera.onvif?.mainURI ?? String(localized: "lido ao salvar"))
                .textSelection(.enabled)
            if let sub = form.camera.onvif?.subURI {
                LabeledContent("Secundário (SD)", value: sub).textSelection(.enabled)
            }
            if let maker = form.camera.onvif?.manufacturer {
                LabeledContent("Fabricante", value: [maker, form.camera.onvif?.model].compactMap { $0 }.joined(separator: " · "))
            }
            Button("Ler da câmera agora") { Task { _ = await readOnvif() } }
                .disabled(form.checking || form.camera.host.isEmpty)
            TextField("Caminho do serviço", text: info.path)
                .font(.system(.body, design: .monospaced))
        } header: {
            Text("Vídeo")
        } footer: {
            Text("Ao salvar, o app pede à câmera os endereços RTSP do vídeo principal e do secundário. O caminho do serviço quase sempre é /onvif/device_service.")
                .foregroundStyle(.secondary)
        }
    }

    /// Lê da câmera o fabricante e os endereços do vídeo. Devolve false (com o motivo na tela) se não deu.
    private func readOnvif() async -> Bool {
        guard let current = form.camera.onvif else { return true }
        form.checking = true
        form.onvifError = nil
        defer { form.checking = false }
        do {
            let fetched = try await OnvifInfo.fetch(host: form.camera.host.trimmingCharacters(in: .whitespaces),
                                                    port: current.port, path: current.path,
                                                    username: form.camera.username, password: form.password)
            form.camera.onvif = fetched
            form.camera.rtspPort = fetched.rtspPort
            return true
        } catch {
            form.onvifError = error.localizedDescription
            return false
        }
    }

    private func save() {
        form.camera.name = form.camera.name.trimmingCharacters(in: .whitespaces)
        form.camera.host = form.camera.host.trimmingCharacters(in: .whitespaces)
        if form.camera.isOnvif {
            // Endereço, porta, usuário ou senha mudaram (ou o vídeo nunca foi lido): pergunta à câmera antes de salvar.
            let key = "\(form.camera.host)|\(form.camera.onvif?.port ?? 0)|\(form.camera.onvif?.path ?? "")|\(form.camera.username)|\(form.password)"
            if form.camera.onvif?.mainURI == nil || key != form.onvifKey {
                Task {
                    if await readOnvif() {
                        form.onvifKey = key
                        finishSave()
                    }
                }
                return
            }
        }
        finishSave()
    }

    private func finishSave() {
        if form.camera.isOnvif { OnvifServices.shared.invalidate(form.camera) }
        // ONVIF: as gravações só podem vir do NVR (o cartão dela não é lido).
        if form.camera.isOnvif { form.camera.recordingsFrom = form.nvrChannel == nil ? .camera : .nvr }
        store.upsert(form.camera)
        if form.camera.group == nil, form.nvrChannel != form.originalChannel { store.link(form.camera, to: form.nvrChannel) }
        store.setPassword(form.password, for: form.camera)
        dismiss()
    }
}

final class EditorForm: ObservableObject {
    @Published var camera: Camera
    @Published var password = ""
    @Published var showPassword = false
    /// Canal do NVR que é esta câmera (o link fica guardado no canal, por isso é editado à parte).
    @Published var nvrChannel: Camera.ID?
    var originalChannel: Camera.ID?
    /// ONVIF: lendo os endereços do vídeo da câmera, e o motivo se não deu.
    @Published var checking = false
    @Published var onvifError: String?
    /// Endereço, porta, usuário e senha da última leitura que deu certo (mudou = lê de novo ao salvar).
    var onvifKey = ""

    init(camera: Camera) {
        self.camera = camera
    }
}
