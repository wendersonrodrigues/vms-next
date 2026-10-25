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
                    FieldLabel("Receber alertas das câmeras",
                               detail: "O VMS Next precisa estar aberto (pode ficar minimizado) para receber os alertas.")
                }
                notificationPermission
            }
            Section {
                Toggle(isOn: $center.mergeDuplicates) {
                    FieldLabel("Juntar alertas repetidos",
                               detail: "Quando a mesma câmera avisa por ela e pelo NVR, mostra um alerta só, com o nome da câmera.")
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
                            Label(camera.name, systemImage: "video")
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
                                .foregroundStyle(center.deviceStatus[name] == "Recebendo alertas" ? Theme.success : Theme.warning)
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

    private var history: some View {
        VStack(spacing: 0) {
            if center.events.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum alerta ainda", systemImage: "bell.slash")
                } description: {
                    Text("Os alarmes das câmeras e do NVR aparecem aqui assim que acontecem.")
                }
            } else {
                List(center.events) { event in
                    EventRow(event: event,
                             camera: event.cameraID.flatMap { id in store.cameras.first { $0.id == id } },
                             onLive: { if let id = event.cameraID { onOpenCamera(id) } },
                             onRecording: { if let id = event.cameraID { onOpenRecording(id, event.date) } })
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if let id = event.cameraID { onOpenCamera(id) }
                        }
                        .contextMenu {
                            if let id = event.cameraID {
                                Button("Ver ao vivo") { onOpenCamera(id) }
                                Button("Ver gravação deste momento") { onOpenRecording(id, event.date) }
                            }
                        }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(center.events.count) alerta(s) nesta sessão").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Limpar") { center.clear() }
                    .disabled(center.events.isEmpty)
            }
            .padding(Space.m)
        }
    }
}

final class EventsUIState: ObservableObject {
    enum Tab { case alerts, log }
    @Published var showSettings = false
    @Published var tab: Tab = .alerts
}

/// Linha do histórico, compacta: hora, o que aconteceu e onde, e atalhos para o ao vivo e a gravação.
private struct EventRow: View {
    let event: AlarmEvent
    let camera: Camera?
    let onLive: () -> Void
    let onRecording: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(event.date.formatted(date: .omitted, time: .standard))
                .monospacedDigit()
                .fontWeight(event.isStart ? .semibold : .regular)
                .frame(width: 70, alignment: .leading)
            Image(systemName: event.kind.icon)
                .frame(width: 20)
                .foregroundStyle(event.isStart ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.kind == .other ? event.event : event.kind.label)
                        .fontWeight(event.isStart ? .semibold : .regular)
                    Text(event.isStart ? "início" : "fim")
                        .font(.caption2)
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, Space.xxs)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(.secondary)
                }
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 220, alignment: .leading)
            Spacer(minLength: 12)
            if event.cameraID != nil {
                Button(action: onLive) {
                    Label("Ao vivo", systemImage: "video")
                }
                .help("Abrir esta câmera ao vivo")
                Button(action: onRecording) {
                    Label("Gravação", systemImage: "play.rectangle")
                }
                .help("Abrir a gravação no momento deste alerta")
            }
        }
        .controlSize(.small)
        .frame(maxWidth: 980, alignment: .leading)
        .opacity(event.isStart ? 1 : 0.6)
    }

    /// Câmera, NVR/canal e o nome técnico do evento.
    private var details: String {
        var parts = [camera?.displayName ?? event.cameraName]
        if let camera, camera.group == nil, camera.channel > 1 { parts.append("canal \(camera.channel)") }
        if let camera, camera.group != nil { parts.append("canal \(camera.channel)") }
        parts.append(event.event)
        return parts.joined(separator: " · ")
    }
}
