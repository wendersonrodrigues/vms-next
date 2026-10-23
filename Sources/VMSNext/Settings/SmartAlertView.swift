import SwiftUI

/// "Detecção inteligente" (Smart alert no VMS antigo): detecção de movimento (Detect.MotionDetect.[canal])
/// e de pessoas (Detect.HumanDetection.[canal]). As ações e o período ficam no EventHandler da detecção
/// de movimento, que vale para os dois. Só aparecem os campos que o equipamento enviar: na câmera há mais
/// opções do que no NVR, como no VMS antigo.
@MainActor
final class SmartAlertModel: ObservableObject {
    enum ActionGroup: String, CaseIterable {
        case record = "Gravar e fotografar"
        case notify = "Avisos"
        case external = "Sirene, relé e PTZ"
        case legacy = "Opções antigas (pouco usadas)"
    }

    struct Spec {
        let key: String
        let title: String
        var original: String?
        let detail: String
        let group: ActionGroup
    }

    struct Action: Identifiable {
        let spec: Spec
        var isOn: Bool
        var id: String { spec.key }
    }

    struct Delay: Identifiable {
        let spec: Spec
        var seconds: Int
        var id: String { spec.key }
    }

    /// Ações do EventHandler, com nomes claros e o que cada uma faz.
    static let actionSpecs: [Spec] = [
        Spec(key: "RecordEnable", title: "Gravar vídeo", original: "Gravação",
             detail: "Grava este canal enquanto o alarme estiver ativo.", group: .record),
        Spec(key: "SnapEnable", title: "Tirar foto", original: "Tirar foto",
             detail: "Salva uma foto do momento em que o alarme disparou.", group: .record),
        Spec(key: "MsgtoNetEnable", title: "Avisar programas no computador", original: "MsgtoNet",
             detail: "Envia o alerta para programas conectados pela rede, como o VMS Next. Deixe ligado para os alertas chegarem aqui.", group: .notify),
        Spec(key: "MessageEnable", title: "Notificação no celular", original: "Notificações",
             detail: "Envia o alerta para o app do celular (iCSee/XMEye).", group: .notify),
        Spec(key: "MailEnable", title: "Enviar e-mail", original: "Enviar e-mail",
             detail: "Manda um e-mail a cada alarme. Precisa de e-mail configurado no equipamento.", group: .notify),
        Spec(key: "FTPEnable", title: "Enviar para servidor FTP", original: "FTP",
             detail: "Envia fotos/vídeos do alarme para um servidor FTP configurado no equipamento.", group: .notify),
        Spec(key: "LogEnable", title: "Registrar no histórico", original: "Escrever log",
             detail: "Anota o alarme no registro de eventos do próprio equipamento.", group: .notify),
        Spec(key: "TipEnable", title: "Aviso na tela do gravador", original: "Tip",
             detail: "Mostra um aviso no monitor ligado ao NVR/câmera.", group: .notify),
        Spec(key: "BeepEnable", title: "Bipe no gravador", original: "Buzzer",
             detail: "Faz o NVR apitar quando o alarme dispara.", group: .notify),
        Spec(key: "VoiceEnable", title: "Aviso sonoro na câmera", original: "Voice",
             detail: "Toca um som pelo alto-falante da câmera, se ela tiver.", group: .notify),
        Spec(key: "AlarmOutEnable", title: "Acionar saída de alarme", original: "Saída de alarme",
             detail: "Liga uma sirene ou relé conectado à saída de alarme do equipamento.", group: .external),
        Spec(key: "PtzEnable", title: "Mover câmera PTZ", original: "Ativação de PTZ",
             detail: "Leva uma câmera PTZ para um preset quando o alarme dispara.", group: .external),
        Spec(key: "TourEnable", title: "Iniciar ronda PTZ", original: "Tour",
             detail: "Faz a câmera PTZ percorrer os presets da ronda.", group: .external),
        Spec(key: "ShortMsgEnable", title: "SMS", original: "ShortMsg",
             detail: "Envio por SMS; só funciona em equipamentos com chip de celular.", group: .legacy),
        Spec(key: "MMSEnable", title: "MMS", original: "MMS",
             detail: "Envio por MMS; só funciona em equipamentos com chip de celular.", group: .legacy),
        Spec(key: "MultimediaMsgEnable", title: "Mensagem multimídia", original: "MultimediaMsg",
             detail: "Recurso antigo de envio de mídia; normalmente sem uso.", group: .legacy),
        Spec(key: "MatrixEnable", title: "Matriz de vídeo", original: "Matrix",
             detail: "Troca a imagem de uma matriz de monitores; normalmente sem uso.", group: .legacy),
        Spec(key: "ShowInfo", title: "Mostrar informação na imagem", original: "ShowInfo",
             detail: "Escreve o tipo de alarme sobre o vídeo.", group: .legacy),
    ]

    static let delaySpecs: [Spec] = [
        Spec(key: "EventLatch", title: "Intervalo entre alarmes", original: "Intervalo",
             detail: "Tempo mínimo entre dois alarmes seguidos. Evita uma enxurrada de avisos.", group: .notify),
        Spec(key: "RecordLatch", title: "Continuar gravando por", original: "Record Delay",
             detail: "Segundos de gravação depois que o movimento termina.", group: .record),
        Spec(key: "AlarmOutLatch", title: "Manter a saída ligada por", original: "Atraso",
             detail: "Segundos que a sirene/relé fica ligada depois do alarme.", group: .external),
        Spec(key: "Dejitter", title: "Filtro de oscilação", original: "Dejitter",
             detail: "Ignora disparos muito curtos. 0 = desligado.", group: .legacy),
    ]

    static let levelNames = [1: "Mínima", 2: "Baixa", 3: "Média", 4: "Alta", 5: "Muito alta", 6: "Máxima"]

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var diagnosticText: String?

    @Published private(set) var hasMotion = false
    @Published var motionEnabled = false
    @Published var motionLevel = 3

    @Published private(set) var hasHuman = false
    @Published var humanEnabled = false
    @Published private(set) var hasHumanSensitivity = false
    @Published var humanSensitivity = 2
    @Published private(set) var hasShowTrack = false
    @Published var showTrack = false
    @Published private(set) var hasShowRule = false
    @Published var showRule = false
    @Published private(set) var ruleSummary: String?

    @Published var actions: [Action] = []
    @Published var delays: [Delay] = []
    @Published private(set) var hasPeriod = false
    @Published var period: [[Int]] = ScheduleCodec.emptyWeek()

    let camera: Camera
    private var motionRaw: Any?
    private var humanRaw: Any?
    private var sectionsPerDay = 6
    private var motionName: String { "Detect.MotionDetect.[\(camera.channel - 1)]" }
    private var humanName: String { "Detect.HumanDetection.[\(camera.channel - 1)]" }

    init(camera: Camera) {
        self.camera = camera
    }

    var validationError: String? {
        hasPeriod ? ScheduleCodec.validate(period, maxSections: sectionsPerDay) : nil
    }

    var levelOptions: [Int] { Array(Set(Array(1 ... 6) + [motionLevel])).sorted() }
    var humanSensitivityOptions: [Int] { Array(Set(Array(1 ... 3) + [humanSensitivity])).sorted() }

    func actions(in group: ActionGroup) -> [Binding<Action>] {
        actions.indices.filter { actions[$0].spec.group == group }.map { index in
            Binding(get: { self.actions[index] }, set: { self.actions[index] = $0 })
        }
    }

    func delays(in group: ActionGroup) -> [Binding<Delay>] {
        delays.indices.filter { delays[$0].spec.group == group }.map { index in
            Binding(get: { self.delays[index] }, set: { self.delays[index] = $0 })
        }
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            motionRaw = try await optional(client, motionName)
            humanRaw = try await optional(client, humanName)
            readMotion()
            readHuman()
            if !hasMotion && !hasHuman {
                error = "Este equipamento não informou detecção de movimento nem de pessoas para o canal \(camera.channel). Use \"Diagnóstico…\" e me envie o resultado."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply() async {
        if let validationError {
            error = validationError
            return
        }
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            if let raw = motionRaw, var motion = ConfigValue.object(in: raw) {
                motion["Enable"] = motionEnabled
                ConfigValue.set(&motion, "Level", motionLevel)
                if var handler = motion["EventHandler"] as? [String: Any] {
                    for action in actions { handler[action.spec.key] = action.isOn }
                    for delay in delays { ConfigValue.set(&handler, delay.spec.key, delay.seconds) }
                    if hasPeriod, var sections = handler["TimeSection"] as? [[String]] {
                        var noMasks: [[Any]]? = nil
                        ScheduleCodec.encode(period, sections: &sections, masks: &noMasks)
                        handler["TimeSection"] = sections
                    }
                    motion["EventHandler"] = handler
                }
                let updated = ConfigValue.replacingObject(in: raw, with: motion)
                try await client.setConfig(motionName, updated)
                motionRaw = updated
            }
            if let raw = humanRaw, var human = ConfigValue.object(in: raw) {
                human["Enable"] = humanEnabled
                if hasHumanSensitivity { ConfigValue.set(&human, "Sensitivity", humanSensitivity) }
                if hasShowTrack { ConfigValue.set(&human, "ShowTrack", showTrack ? 1 : 0) }
                if hasShowRule { human["ShowRule"] = showRule }
                let updated = ConfigValue.replacingObject(in: raw, with: human)
                try await client.setConfig(humanName, updated)
                humanRaw = updated
            }
            notice = "Detecção inteligente aplicada."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        let ch = camera.channel - 1
        return await ConfigDiagnostics.dump(camera: camera, requests: [
            (1042, motionName), (1042, humanName),
            (1042, "Detect.BlindDetect.[\(ch)]"), (1042, "Detect.LossDetect.[\(ch)]"),
        ])
    }

    // MARK: - Leitura

    private func readMotion() {
        guard let motion = ConfigValue.object(in: motionRaw) else {
            hasMotion = false
            return
        }
        hasMotion = true
        motionEnabled = Self.bool(motion["Enable"])
        motionLevel = ConfigValue.int(motion["Level"]) ?? 3

        let handler = motion["EventHandler"] as? [String: Any] ?? [:]
        let knownKeys = Set(Self.actionSpecs.map(\.key))
        actions = Self.actionSpecs.compactMap { spec in
            (handler[spec.key] as? Bool).map { Action(spec: spec, isOn: $0) }
        } + handler.keys.sorted().compactMap { key in
            guard !knownKeys.contains(key), key.hasSuffix("Enable"), let value = handler[key] as? Bool else { return nil }
            return Action(spec: Spec(key: key, title: key, detail: "Opção do equipamento sem descrição conhecida.", group: .legacy), isOn: value)
        }
        delays = Self.delaySpecs.compactMap { spec in
            ConfigValue.int(handler[spec.key]).map { Delay(spec: spec, seconds: $0) }
        }
        if let sections = handler["TimeSection"] as? [[String]] {
            hasPeriod = true
            sectionsPerDay = sections.first?.count ?? 6
            period = ScheduleCodec.decode(sections: sections, masks: nil)
        }
    }

    private func readHuman() {
        guard let human = ConfigValue.object(in: humanRaw) else {
            hasHuman = false
            return
        }
        hasHuman = true
        humanEnabled = Self.bool(human["Enable"])
        if let value = ConfigValue.int(human["Sensitivity"]) {
            hasHumanSensitivity = true
            humanSensitivity = value
        }
        if let value = ConfigValue.int(human["ShowTrack"]) {
            hasShowTrack = true
            showTrack = value != 0
        }
        if let value = human["ShowRule"] as? Bool {
            hasShowRule = true
            showRule = value
        }
        if let rules = human["PedRule"] as? [[String: Any]] {
            let active = rules.filter { Self.bool($0["Enable"]) }
            let areas = active.filter { ConfigValue.int($0["RuleType"]) == 1 }.count
            let lines = active.count - areas
            var parts: [String] = []
            if areas > 0 { parts.append("\(areas) área(s)") }
            if lines > 0 { parts.append("\(lines) linha(s)") }
            ruleSummary = parts.isEmpty ? "Nenhuma — detecta na imagem toda" : parts.joined(separator: " e ")
        }
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? Bool) ?? (ConfigValue.int(value) == 1)
    }

    private func optional(_ client: DVRIPClient, _ name: String) async throws -> Any? {
        do {
            return try await client.getConfig(name)
        } catch DVRIPError.device, DVRIPError.invalidResponse {
            return nil
        }
    }
}

struct SmartAlertView: View {
    @StateObject private var model: SmartAlertModel

    init(camera: Camera) {
        _model = StateObject(wrappedValue: SmartAlertModel(camera: camera))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if model.hasHuman { humanSection }
                    if model.hasMotion { motionSection }
                    ForEach([SmartAlertModel.ActionGroup.record, .notify, .external], id: \.self) { group in
                        actionSection(group)
                    }
                    if model.hasPeriod { periodSection }
                    legacySection
                    if let message = model.error ?? model.validationError {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Diagnóstico…") { Task { model.diagnosticText = await model.diagnostic() } }
                    .disabled(model.loading || model.saving)
                Button("Recarregar") { Task { await model.load() } }
                    .disabled(model.loading || model.saving)
                Button("Aplicar") { Task { await model.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.loading || model.saving || model.validationError != nil || (!model.hasMotion && !model.hasHuman))
            }
            .padding(12)
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    private var humanSection: some View {
        Section("Detecção de pessoas") {
            Toggle(isOn: $model.humanEnabled) {
                FieldLabel("Detectar pessoas", original: "HumanoidDetect",
                           detail: "Só dispara quando reconhece o formato de uma pessoa. Gera bem menos alarmes falsos que a detecção de movimento.")
            }
            if model.hasHumanSensitivity {
                Picker(selection: $model.humanSensitivity) {
                    ForEach(model.humanSensitivityOptions, id: \.self) { value in
                        Text([1: "Baixa", 2: "Média", 3: "Alta"][value] ?? "Nível \(value)").tag(value)
                    }
                } label: {
                    FieldLabel("Sensibilidade", detail: "Mais alta reconhece pessoas mais longe ou parcialmente escondidas, mas erra mais.")
                }
            }
            if model.hasShowTrack {
                Toggle(isOn: $model.showTrack) {
                    FieldLabel("Mostrar rastro", original: "Mostrar traços",
                               detail: "Desenha uma moldura e o caminho da pessoa no vídeo ao vivo.")
                }
            }
            if model.hasShowRule {
                Toggle(isOn: $model.showRule) {
                    FieldLabel("Mostrar área/linha no vídeo", original: "ShowRule",
                               detail: "Exibe a área ou linha de aviso desenhada sobre a imagem.")
                }
            }
            if let summary = model.ruleSummary {
                LabeledContent {
                    Text(summary)
                } label: {
                    FieldLabel("Área ou linha de aviso", original: "Rule",
                               detail: "Limita o alerta a uma região da imagem ou a quem cruzar uma linha. O desenho ainda é feito no VMS antigo ou no iCSee.")
                }
            }
        }
    }

    private var motionSection: some View {
        Section("Detecção de movimento") {
            Toggle(isOn: $model.motionEnabled) {
                FieldLabel("Detectar movimento", original: "Habilitar",
                           detail: "Dispara com qualquer mudança na imagem (pessoas, carros, animais, sombras, chuva). Precisa estar ligado para as ações abaixo funcionarem.")
            }
            Picker(selection: $model.motionLevel) {
                ForEach(model.levelOptions, id: \.self) { Text(SmartAlertModel.levelNames[$0] ?? "Nível \($0)").tag($0) }
            } label: {
                FieldLabel("Sensibilidade", detail: "Mais alta dispara com movimentos menores, mas aumenta os alarmes falsos.")
            }
        }
    }

    @ViewBuilder
    private func actionSection(_ group: SmartAlertModel.ActionGroup) -> some View {
        let actions = model.actions(in: group)
        let delays = model.delays(in: group)
        if !actions.isEmpty || !delays.isEmpty {
            Section("Ao detectar · \(group.rawValue.lowercased())") {
                ForEach(actions, id: \.wrappedValue.id) { $action in
                    Toggle(isOn: $action.isOn) {
                        FieldLabel(action.spec.title, original: action.spec.original, detail: action.spec.detail)
                    }
                }
                ForEach(delays, id: \.wrappedValue.id) { $delay in
                    Stepper(value: $delay.seconds, in: 0 ... 600) {
                        FieldLabel("\(delay.spec.title): \(delay.seconds) s", original: delay.spec.original, detail: delay.spec.detail)
                    }
                }
            }
        }
    }

    private var periodSection: some View {
        Section {
            ScheduleGrid(slots: $model.period, rows: ScheduleRow.period)
        } header: {
            Text("Horários em que o alarme fica ativo (Período)")
        } footer: {
            Text("Fora dos horários marcados, as detecções não disparam alarme. Clique e arraste para marcar ou desmarcar meia hora; botão direito no dia para copiar ou limpar.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var legacySection: some View {
        let actions = model.actions(in: .legacy)
        let delays = model.delays(in: .legacy)
        if !actions.isEmpty || !delays.isEmpty {
            Section {
                DisclosureGroup("Opções antigas (pouco usadas)") {
                    ForEach(actions, id: \.wrappedValue.id) { $action in
                        Toggle(isOn: $action.isOn) {
                            FieldLabel(action.spec.title, original: action.spec.original, detail: action.spec.detail)
                        }
                    }
                    ForEach(delays, id: \.wrappedValue.id) { $delay in
                        Stepper(value: $delay.seconds, in: 0 ... 60) {
                            FieldLabel("\(delay.spec.title): \(delay.seconds) s", original: delay.spec.original, detail: delay.spec.detail)
                        }
                    }
                }
            }
        }
    }
}
