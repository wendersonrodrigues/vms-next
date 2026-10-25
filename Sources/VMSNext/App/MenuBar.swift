import AppKit
import ServiceManagement
import SwiftUI

/// Preferências do funcionamento em segundo plano: abrir junto com o Mac e esconder do Dock sem janela.
@MainActor
final class BackgroundSettings: ObservableObject {
    static let shared = BackgroundSettings()

    @Published var hideDockWhenClosed: Bool {
        didSet {
            UserDefaults.standard.set(hideDockWhenClosed, forKey: "background.hideDock")
            applyDockPolicy()
        }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginError: String?

    private var openWindows = 0

    private init() {
        hideDockWhenClosed = UserDefaults.standard.bool(forKey: "background.hideDock")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func windowOpened() {
        openWindows += 1
        applyDockPolicy()
    }

    func windowClosed() {
        openWindows = max(0, openWindows - 1)
        applyDockPolicy()
    }

    /// Ícone no Dock só enquanto houver janela aberta (se a opção estiver ligada).
    private func applyDockPolicy() {
        let policy: NSApplication.ActivationPolicy = hideDockWhenClosed && openWindows == 0 ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = String(localized: "O macOS não aceitou: \(error.localizedDescription). Coloque o VMS Next na pasta Aplicativos e tente de novo.")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginError = String(localized: "Autorize o VMS Next em Ajustes do Sistema → Geral → Itens de Início.")
        }
    }
}

/// Ícone na barra de menus: câmera com o número de alertas novos. Também reabre a janela
/// quando uma notificação é clicada com o app sem janela.
struct MenuBarLabel: View {
    @ObservedObject private var alarms = AlarmCenter.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: alarms.unread > 0 ? "video.badge.exclamationmark" : "video")
            if alarms.unread > 0 {
                Text(alarms.unread > 99 ? "99+" : "\(alarms.unread)")
                    .monospacedDigit()
            }
        }
        .onChange(of: alarms.openEventsRequested) {
            if alarms.openEventsRequested { showMainWindow(openWindow) }
        }
    }
}

@MainActor
func showMainWindow(_ openWindow: OpenWindowAction) {
    NSApp.setActivationPolicy(.regular)
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
        window.makeKeyAndOrderFront(nil)
    } else {
        openWindow(id: "main")
    }
    NSApp.activate(ignoringOtherApps: true)
}

/// Painel da barra de menus: últimos alertas e atalhos.
struct MenuBarPanel: View {
    @ObservedObject private var alarms = AlarmCenter.shared
    @ObservedObject private var vault = Vault.shared
    @ObservedObject private var background = BackgroundSettings.shared
    @Environment(\.openWindow) private var openWindow

    private var connectedDevices: Int {
        alarms.deviceStatus.values.filter { $0 == String(localized: "Recebendo alertas") }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VMS Next").font(.headline)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }

            if !vault.isUnlocked {
                Text("Entre no VMS Next para receber os alertas.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Entrar…") { showMainWindow(openWindow) }
            } else if alarms.events.isEmpty {
                Text("Nenhum alerta nesta sessão.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Space.s)
            } else {
                VStack(spacing: 0) {
                    ForEach(alarms.events.prefix(6)) { event in
                        Button {
                            alarms.openEventsRequested = true
                            showMainWindow(openWindow)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: event.kind.icon)
                                    .frame(width: 18)
                                    .foregroundStyle(event.isStart ? Theme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.kind == .other ? event.event : event.kind.label).lineLimit(1)
                                    Text(event.cameraName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(event.date.formatted(date: .omitted, time: .shortened))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, Space.xs)
                        }
                        .buttonStyle(.plain)
                        .opacity(event.isStart ? 1 : 0.6)
                    }
                }
            }

            Divider()

            HStack {
                Button("Abrir VMS Next") { showMainWindow(openWindow) }
                Button("Ver eventos") {
                    alarms.openEventsRequested = true
                    showMainWindow(openWindow)
                }
                .disabled(!vault.isUnlocked)
            }

            Toggle("Receber alertas das câmeras", isOn: $alarms.enabled)
                .disabled(!vault.isUnlocked)
            Toggle("Abrir junto com o Mac", isOn: Binding(
                get: { background.launchAtLogin },
                set: { background.setLaunchAtLogin($0) }
            ))
            Toggle("Esconder do Dock com a janela fechada", isOn: $background.hideDockWhenClosed)
            if let error = background.loginError {
                Text(error).font(.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Sair do VMS Next") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(Space.l)
        .frame(width: 320)
        .onAppear { alarms.markAllRead() }
    }

    private var statusText: String {
        guard vault.isUnlocked else { return String(localized: "Sessão fechada") }
        guard alarms.enabled else { return String(localized: "Alertas desligados") }
        return connectedDevices == 1 ? "1 equipamento" : "\(connectedDevices) equipamentos"
    }
}
