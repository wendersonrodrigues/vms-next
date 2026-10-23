import SwiftUI

/// Histórico de alarmes e preferências de notificação.
struct EventsView: View {
    @ObservedObject var center: AlarmCenter
    let onOpenCamera: (Camera.ID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            preferences
                .frame(width: 300)
            Divider()
            history
        }
        .onAppear { center.markAllRead() }
        .onChange(of: center.events.count) { center.markAllRead() }
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
            if !center.deviceStatus.isEmpty {
                Section("Equipamentos") {
                    ForEach(center.deviceStatus.keys.sorted(), id: \.self) { name in
                        LabeledContent(name) {
                            Text(center.deviceStatus[name] ?? "")
                                .font(.caption)
                                .foregroundStyle(center.deviceStatus[name] == "Recebendo alertas" ? .green : .orange)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var notificationPermission: some View {
        switch center.notificationsAllowed {
        case .some(true):
            Label("Notificações do macOS permitidas", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .some(false):
            VStack(alignment: .leading, spacing: 6) {
                Label("Notificações do macOS bloqueadas", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
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
                    EventRow(event: event)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if let id = event.cameraID { onOpenCamera(id) }
                        }
                        .contextMenu {
                            if let id = event.cameraID {
                                Button("Ver ao vivo") { onOpenCamera(id) }
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
            .padding(10)
        }
    }
}

private struct EventRow: View {
    let event: AlarmEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.kind.icon)
                .frame(width: 24)
                .foregroundStyle(event.isStart ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.kind == .other ? event.event : event.kind.label)
                    .fontWeight(event.isStart ? .semibold : .regular)
                Text(event.cameraName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                Text(event.isStart ? "início · \(event.event)" : "fim · \(event.event)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(event.isStart ? 1 : 0.6)
    }
}
