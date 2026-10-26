import SwiftUI
import UniformTypeIdentifiers

/// Histórico de alarmes e preferências de notificação.
struct EventsView: View {
    @ObservedObject var center: AlarmCenter
    @EnvironmentObject private var store: CameraStore
    let onOpenCamera: (Camera.ID) -> Void
    /// Abre a gravação da câmera no momento do alerta.
    let onOpenRecording: (Camera.ID, Date) -> Void

    @StateObject private var state = EventsUIState()

    var body: some View {
        Group {
            if state.tab == .log {
                LogsView()
            } else {
                alertsPane
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mostrar", selection: $state.tab) {
                    Text("Alertas").tag(EventsUIState.Tab.alerts)
                    Text("Registro").tag(EventsUIState.Tab.log)
                }
                .pickerStyle(.segmented)
                .help("Alertas das câmeras ou o registro de tudo o que aconteceu (no app e nos equipamentos)")
            }
        }
        .onAppear { center.markAllRead() }
        .onChange(of: center.events.count) { center.markAllRead() }
    }

    private var alertsPane: some View {
        history
            .inspector(isPresented: $state.showSettings) {
                preferences
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        state.showSettings.toggle()
                    } label: {
                        Label("Ajustes dos alertas", systemImage: "slider.horizontal.3")
                    }
                    .help("Ajustes dos alertas: notificações, sons, alertas repetidos e mesma câmera no NVR")
                }
            }
    }

    private var preferences: some View {
        Form {
            Section {
                Toggle(isOn: $center.enabled) {
                    FieldLabel(String(localized: "Receber alertas das câmeras"),
                               detail: String(localized: "O VMS Next precisa estar aberto (pode ficar minimizado) para receber os alertas."))
                }
                notificationPermission
            }
            Section {
                Toggle(isOn: $center.mergeDuplicates) {
                    FieldLabel(String(localized: "Juntar alertas repetidos"),
                               detail: String(localized: "Quando a mesma câmera avisa por ela e pelo NVR, mostra um alerta só, com o nome da câmera."))
                }
            }
            .disabled(!center.enabled)
            if center.mergeDuplicates, !store.groups.isEmpty {
                Section {
                    ForEach(store.standaloneCameras) { camera in
                        Picker(selection: Binding(
                            get: { store.linkedChannel(for: camera)?.id },
                            set: { store.link(camera, to: $0) }
                        )) {
                            Text("Não está no NVR").tag(Camera.ID?.none)
                            ForEach(store.groups, id: \.self) { group in
                                Section(group) {
                                    ForEach(store.channels(in: group)) { channel in
                                        Text(channel.displayName).tag(Optional(channel.id))
                                    }
                                }
                            }
                        } label: {
                            Label { Text(camera.name) } icon: { CameraGlyph() }
                        }
                    }
                } header: {
                    Text("Mesma câmera no NVR")
                } footer: {
                    Text("Escolha o canal do NVR que mostra a mesma câmera. Assim o alerta que chega pelos dois aparece uma vez só, com o nome da câmera.")
                        .foregroundStyle(.secondary)
                }
                .disabled(!center.enabled)
            }
            Section {
                Toggle(isOn: $center.analyzeWithAI) {
                    FieldLabel(String(localized: "Analisar a foto de cada alerta com IA"),
                               detail: String(localized: "Antes de avisar, o Mac pega uma foto da câmera e procura pessoas, rostos, veículos e animais com o Vision do macOS. Tudo no Mac, sem internet."))
                }
                Toggle(isOn: $center.notifyOnlyWhenFound) {
                    FieldLabel(String(localized: "Só notificar quando a IA achar algo"),
                               detail: String(localized: "Movimento sem pessoa, veículo ou animal na foto fica só no histórico, marcado como provável falso alarme."))
                }
                .disabled(!center.analyzeWithAI)
            } header: {
                Text("IA no Mac")
            }
            .disabled(!center.enabled)
            Section("Notificar no macOS") {
                ForEach(AlarmKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { center.notifyKinds.contains(kind) },
                        set: { on in
                            if on { center.notifyKinds.insert(kind) } else { center.notifyKinds.remove(kind) }
                        }
                    )) {
                        Label(kind.label, systemImage: kind.icon)
                    }
                }
            }
            .disabled(!center.enabled)
            Section {
                ForEach(AlarmKind.allCases) { kind in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { center.soundKinds.contains(kind) },
                            set: { on in if on { center.soundKinds.insert(kind) } else { center.soundKinds.remove(kind) } }
                        )) {
                            Label(kind.label, systemImage: kind.icon)
                        }
                        Spacer()
                        Menu(soundTitle(kind)) {
                            ForEach(AlarmCenter.systemSounds, id: \.self) { name in
                                Button(name) { center.sounds[kind.rawValue] = name; center.playSound(for: kind) }
                            }
                            Divider()
                            Button("Arquivo de som…") { chooseSound(for: kind) }
                        }
                        .fixedSize()
                        .disabled(!center.soundKinds.contains(kind))
                        Button { center.playSound(for: kind) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless)
                            .help("Ouvir")
                            .accessibilityLabel("Ouvir o som")
                    }
                }
            } header: {
                Text("Som no Mac (Configurações de alarme)")
            } footer: {
                Text("Toca um som quando o alerta chega, mesmo com a janela fechada. Dá para usar um som do macOS ou um arquivo seu (WAV, MP3, AIFF).")
                    .foregroundStyle(.secondary)
            }
            .disabled(!center.enabled)
            if !center.deviceStatus.isEmpty {
                Section("Equipamentos") {
                    ForEach(center.deviceStatus.keys.sorted(), id: \.self) { name in
                        LabeledContent(name) {
                            Text(center.deviceStatus[name] ?? "")
                                .font(.caption)
                                .foregroundStyle(center.deviceStatus[name] == String(localized: "Recebendo alertas") ? Theme.success : Theme.warning)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func soundTitle(_ kind: AlarmKind) -> String {
        let name = center.sound(for: kind)
        return name.hasPrefix("/") ? URL(fileURLWithPath: name).lastPathComponent : name
    }

    private func chooseSound(for kind: AlarmKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        center.sounds[kind.rawValue] = url.path
        center.playSound(for: kind)
    }

    @ViewBuilder
    private var notificationPermission: some View {
        switch center.notificationsAllowed {
        case .some(true):
            Label("Notificações do macOS permitidas", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
        case .some(false):
            VStack(alignment: .leading, spacing: 6) {
                Label("Notificações do macOS bloqueadas", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                Text("Os alertas continuam aparecendo aqui e no sino. Para receber os avisos do macOS, libere o VMS Next nos Ajustes de Notificações.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Abrir Ajustes de Notificações") { center.openNotificationSettings() }
            }
        case .none:
            Label("Verificando notificações do macOS…", systemImage: "bell")
                .foregroundStyle(.secondary)
        }
    }

    /// Só o início de cada alerta (o fim fica como duração), com o filtro de gravidade escolhido.
    private var visibleEvents: [AlarmEvent] {
        center.events.filter { event in
            event.isStart
                && (state.severity == nil || event.severity == state.severity)
                && !(state.hideFalse && event.probablyFalse)
                && (!state.withNotes || event.note != nil)
        }
    }

    private var history: some View {
        VStack(spacing: 0) {
            filterBar
            if !center.activeSnoozes.isEmpty { snoozeBar }
            Divider()
            if center.events.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum alerta ainda", systemImage: "bell.slash")
                } description: {
                    Text("Os alarmes das câmeras e do NVR aparecem aqui assim que acontecem.")
                }
            } else if visibleEvents.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum alerta com esse filtro", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Troque a gravidade ou desligue os filtros acima.")
                }
            } else {
                List(visibleEvents) { event in
                    let camera = event.cameraID.flatMap { id in store.cameras.first { $0.id == id } }
                    AlarmCard(event: event, camera: camera, center: center, state: state,
                              onLive: { if let id = event.cameraID { onOpenCamera(id) } },
                              onPlay: { if let id = event.cameraID { onOpenRecording(id, event.date) } })
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if let id = event.cameraID { onOpenRecording(id, event.date) }
                        }
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(visibleEvents.count) alerta(s)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Limpar") { center.clear() }
                    .disabled(center.events.isEmpty)
            }
            .padding(Space.m)
        }
    }

    /// Gravidade (Todas, Alta, Média, Baixa) e filtros rápidos.
    private var filterBar: some View {
        HStack(spacing: Space.m) {
            Picker("Gravidade", selection: $state.severity) {
                Text("Todas").tag(AlarmSeverity?.none)
                ForEach(AlarmSeverity.allCases.reversed()) { severity in
                    Text(severity.label).tag(Optional(severity))
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Mostrar só os alertas desta gravidade")
            Toggle("Esconder prováveis falsos alarmes", isOn: $state.hideFalse)
                .toggleStyle(.checkbox)
                .help("Movimento em que a IA não achou pessoa, veículo nem animal")
            Toggle("Com nota", isOn: $state.withNotes)
                .toggleStyle(.checkbox)
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
    }

    /// Sonecas valendo agora, com o botão para acordar.
    private var snoozeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(Theme.accent)
                ForEach(center.activeSnoozes, id: \.key) { snooze in
                    let name = store.cameras.first { $0.id == snooze.cameraID }?.displayName ?? "?"
                    HStack(spacing: Space.xs) {
                        Text("\(name) · \(snooze.kind?.label ?? String(localized: "todos os tipos")) · até \(snooze.until.formatted(date: .omitted, time: .shortened))")
                        Button {
                            center.cancelSnooze(snooze.key)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Acordar: voltar a avisar")
                        .accessibilityLabel("Acordar")
                    }
                    .font(.caption)
                    .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.s)
        }
    }
}

final class EventsUIState: ObservableObject {
    enum Tab { case alerts, log }
    @Published var showSettings = false
    @Published var tab: Tab = .alerts
    @Published var severity: AlarmSeverity?
    @Published var hideFalse = false
    @Published var withNotes = false
    /// Alerta com a nota aberta para editar, e o texto sendo digitado.
    @Published var editingNote: AlarmEvent.ID?
    @Published var noteText = ""
}

extension AlarmSeverity {
    var color: Color {
        switch self {
        case .low: return .secondary
        case .medium: return Theme.warning
        case .high: return .red
        }
    }
}

/// Um alerta no gerenciador: foto, o que a IA achou, gravidade, duração, nota e ações (▶ gravação, ao vivo,
/// nota, soneca e mudar a gravidade).
private struct AlarmCard: View {
    let event: AlarmEvent
    let camera: Camera?
    @ObservedObject var center: AlarmCenter
    @ObservedObject var state: EventsUIState
    let onLive: () -> Void
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            thumbnail
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(event.title).font(.headline).lineLimit(1)
                    severityPill
                    if event.probablyFalse {
                        Label("Provável falso alarme", systemImage: "questionmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if event.analyzing == true {
                    HStack(spacing: Space.xs) {
                        ProgressView().controlSize(.mini)
                        Text("Analisando a foto…")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else if let chips = event.analysis?.chips, !chips.isEmpty {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .padding(.horizontal, Space.s).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accent.opacity(0.12)))
                        }
                    }
                    .font(.caption)
                }
                if let note = event.note {
                    Label(note, systemImage: "note.text")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Space.m)
            actions
        }
        .padding(.vertical, Space.xs)
        .frame(maxWidth: 1100, alignment: .leading)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.small).fill(Color.primary.opacity(0.06))
            if event.hasPhoto == true, let image = NSImage(contentsOf: AlarmPhotos.url(for: event.id)) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if event.analyzing == true {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: event.kind.icon).font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(width: 120, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: Radius.small))
        .overlay(alignment: .topLeading) {
            Text(event.date.formatted(date: .omitted, time: .standard))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, Space.xs).padding(.vertical, 1)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(Space.xxs)
        }
        .accessibilityHidden(true)
    }

    private var severityPill: some View {
        Text(event.severity.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Space.s).padding(.vertical, 1)
            .background(Capsule().fill(event.severity.color.opacity(0.16)))
            .foregroundStyle(event.severity.color)
            .accessibilityLabel(String(localized: "Gravidade \(event.severity.label)"))
    }

    private var actions: some View {
        HStack(spacing: Space.xs) {
            if event.cameraID != nil {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Abrir a gravação no momento deste alerta")
                Button(action: onLive) {
                    Image(systemName: "video")
                }
                .help("Abrir esta câmera ao vivo")
                .accessibilityLabel("Ao vivo")
            }
            Button {
                state.noteText = event.note ?? ""
                state.editingNote = event.id
            } label: {
                Image(systemName: event.note == nil ? "square.and.pencil" : "note.text")
            }
            .help(event.note == nil ? String(localized: "Escrever uma nota") : String(localized: "Editar a nota"))
            .accessibilityLabel("Nota")
            .popover(isPresented: Binding(get: { state.editingNote == event.id },
                                          set: { if !$0 { state.editingNote = nil } })) {
                noteEditor
            }
            if let cameraID = event.cameraID { snoozeMenu(cameraID) }
            Menu {
                Section("Gravidade") {
                    ForEach(AlarmSeverity.allCases.reversed()) { severity in
                        Button {
                            center.setSeverity(severity, for: event.id)
                        } label: {
                            if event.severity == severity { Label(severity.label, systemImage: "checkmark") } else { Text(severity.label) }
                        }
                    }
                    if event.severityOverride != nil {
                        Button("Voltar à automática") { center.setSeverity(nil, for: event.id) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Mais opções")
            .accessibilityLabel("Mais opções")
        }
        .controlSize(.small)
    }

    private func snoozeMenu(_ cameraID: Camera.ID) -> some View {
        Menu {
            Section(String(localized: "Só \(event.kind.label)")) {
                snoozeButtons(cameraID, kind: event.kind)
            }
            Section("Todos os alertas desta câmera") {
                snoozeButtons(cameraID, kind: nil)
            }
        } label: {
            Image(systemName: center.isSnoozed(cameraID, event.kind) ? "moon.zzz.fill" : "moon.zzz")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Soneca: não avisar desta câmera por um tempo")
        .accessibilityLabel("Soneca")
    }

    @ViewBuilder
    private func snoozeButtons(_ cameraID: Camera.ID, kind: AlarmKind?) -> some View {
        Button("15 minutos") { center.snooze(cameraID, kind: kind, until: Date().addingTimeInterval(15 * 60)) }
        Button("1 hora") { center.snooze(cameraID, kind: kind, until: Date().addingTimeInterval(3600)) }
        Button("8 horas") { center.snooze(cameraID, kind: kind, until: Date().addingTimeInterval(8 * 3600)) }
        Button("Até amanhã") {
            let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400)).addingTimeInterval(7 * 3600)
            center.snooze(cameraID, kind: kind, until: tomorrow)
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Nota do alerta").font(.headline)
            TextEditor(text: $state.noteText)
                .font(.body)
                .frame(width: 280, height: 90)
                .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(Theme.stroke))
            HStack {
                if event.note != nil {
                    Button("Apagar", role: .destructive) {
                        center.setNote("", for: event.id)
                        state.editingNote = nil
                    }
                }
                Spacer()
                Button("Cancelar") { state.editingNote = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar") {
                    center.setNote(state.noteText, for: event.id)
                    state.editingNote = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.l)
    }

    /// Câmera e canal, hora, duração e, se a IA mudou o título, o que a câmera tinha avisado.
    private var details: String {
        var parts = [camera?.displayName ?? event.cameraName]
        if let camera, camera.group != nil || camera.channel > 1 { parts.append(String(localized: "canal \(camera.channel)")) }
        parts.append(event.date.formatted(date: .abbreviated, time: .standard))
        if let end = event.endDate {
            let seconds = max(Int(end.timeIntervalSince(event.date)), 1)
            parts.append(seconds < 60 ? String(localized: "durou \(seconds) s") : String(localized: "durou \(seconds / 60) min"))
        }
        if event.analysis?.title != nil {
            parts.append(String(localized: "câmera avisou: \(event.kind == .other ? event.event : event.kind.label)"))
        } else {
            parts.append(event.event)
        }
        return parts.joined(separator: " · ")
    }
}
