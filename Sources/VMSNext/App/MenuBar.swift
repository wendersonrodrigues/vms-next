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
    @ObservedObject private var vault = Vault.shared
    @Environment(\.openWindow) private var openWindow

    /// Ícones próprios da barra de menus (Resources/Icons/menubar_*.png), como "template": o macOS pinta de
    /// preto ou branco conforme a barra. Normal; lente cheia = alertas novos; riscado = sem receber alertas.
    private static func icon(_ name: String) -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(name).png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
    private static let normal = icon("menubar_normal")
    private static let alert = icon("menubar_alert")
    private static let off = icon("menubar_off")

    private var state: (image: NSImage?, fallback: String, label: String) {
        if !vault.isUnlocked || !alarms.enabled {
            return (Self.off, "video.slash", String(localized: "VMS Next: sem receber alertas"))
        }
        if alarms.unread > 0 {
            return (Self.alert, "video.badge.exclamationmark", String(localized: "VMS Next: alertas novos"))
        }
        return (Self.normal, "video", String(localized: "VMS Next"))
    }

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if let image = state.image { Image(nsImage: image) } else { Image(systemName: state.fallback) }
            }
            .accessibilityLabel(state.label)
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

/// Linha da lista da barra de menus: um alerta, com quantos iguais seguidos ele junta.
private struct MenuBarAlert: Identifiable {
    let event: AlarmEvent
    var count: Int
    var id: UUID { event.id }
}

/// Painel da barra de menus: últimos alertas e, embaixo, botões em ícone (abrir o app, alertas ligados,
/// câmeras silenciadas, opções e sair).
struct MenuBarPanel: View {
    @ObservedObject private var alarms = AlarmCenter.shared
    @ObservedObject private var vault = Vault.shared
    @ObservedObject private var background = BackgroundSettings.shared
    @EnvironmentObject private var store: CameraStore
    @Environment(\.openWindow) private var openWindow

    private var connectedDevices: Int {
        alarms.deviceStatus.values.filter { $0 == String(localized: "Recebendo alertas") }.count
    }

    /// Só o início de cada alerta (o aviso de "terminou" não aparece mais como linha apagada), e alertas
    /// iguais seguidos (mesma câmera e tipo, em até 2 minutos) viram uma linha só, com o ícone de repetido.
    private var rows: [MenuBarAlert] {
        var result: [MenuBarAlert] = []
        for event in alarms.events where event.isStart {
            if let last = result.last, last.event.cameraName == event.cameraName, last.event.event == event.event,
               last.event.date.timeIntervalSince(event.date) < 120 {
                result[result.count - 1].count += 1
                continue
            }
            result.append(MenuBarAlert(event: event, count: 1))
            if result.count == 7 { break }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header

            if !vault.isUnlocked {
                Text("Entre no VMS Next para receber os alertas.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Entrar…") { showMainWindow(openWindow) }
            } else if rows.isEmpty {
                Text("Nenhum alerta nesta sessão.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Space.s)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in alertRow(row) }
                }
            }

            if let error = background.loginError {
                Text(error).font(.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            toolbar
        }
        .padding(Space.l)
        .frame(width: 320)
        .onAppear { alarms.markAllRead() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("VMS Next").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            iconButton("macwindow", String(localized: "Abrir o VMS Next")) { showMainWindow(openWindow) }
        }
    }

    private func alertRow(_ row: MenuBarAlert) -> some View {
        let event = row.event
        let muted = event.cameraID.map(alarms.mutedCameras.contains) ?? false
        return Button {
            alarms.openEventsRequested = true
            showMainWindow(openWindow)
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: event.kind.icon)
                    .frame(width: 18)
                    .foregroundStyle(muted ? Color.secondary : Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).lineLimit(1)
                    HStack(spacing: Space.xxs) {
                        Text(event.cameraName)
                        if muted { Image(systemName: "bell.slash.fill").font(.system(size: 9)) }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if row.count > 1 {
                    // Repetidos juntados: um ícone com quantos.
                    HStack(spacing: 2) {
                        Image(systemName: "square.on.square")
                        Text("\(row.count)")
                    }
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.xs).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .help(String(localized: "\(row.count) alertas iguais seguidos"))
                }
                Text(event.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, Space.xs)
        }
        .buttonStyle(.plain)
        .help("Abrir em Eventos")
    }

    /// Barra de baixo: alertas ligados/desligados, câmeras silenciadas, opções e sair, só com ícones.
    private var toolbar: some View {
        HStack(spacing: Space.s) {
            iconButton(alarms.enabled ? "bell.fill" : "bell.slash",
                       alarms.enabled ? String(localized: "Alertas ligados: clique para desligar")
                                      : String(localized: "Alertas desligados: clique para ligar"),
                       tint: alarms.enabled ? Theme.accent : .secondary) {
                alarms.enabled.toggle()
            }
            .disabled(!vault.isUnlocked)

            cameraMenu

            Menu {
                Toggle("Abrir junto com o Mac", isOn: Binding(
                    get: { background.launchAtLogin },
                    set: { background.setLaunchAtLogin($0) }
                ))
                Toggle("Esconder do Dock com a janela fechada", isOn: $background.hideDockWhenClosed)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Opções")
            .accessibilityLabel("Opções")

            Spacer()

            iconButton("power", String(localized: "Sair do VMS Next")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .font(.system(size: 14))
    }

    /// Lista de câmeras para escolher de quais receber alertas (marcada = recebe).
    private var cameraMenu: some View {
        let mutedCount = store.cameras.filter(alarms.isMuted).count
        return Menu {
            Section("Receber alertas de") {
                ForEach(store.standaloneCameras) { camera in cameraItem(camera) }
            }
            ForEach(store.groups, id: \.self) { group in
                Section(group) {
                    ForEach(store.channels(in: group)) { camera in cameraItem(camera) }
                }
            }
            if mutedCount > 0 {
                Divider()
                Button("Receber de todas") { alarms.mutedCameras.removeAll() }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: mutedCount > 0 ? "video.slash" : "video")
                if mutedCount > 0 { Text("\(mutedCount)").font(.caption.monospacedDigit()) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!vault.isUnlocked)
        .help(mutedCount > 0 ? String(localized: "\(mutedCount) câmera(s) silenciada(s): escolher de quais receber alertas")
                             : String(localized: "Escolher de quais câmeras receber alertas"))
        .accessibilityLabel("Câmeras que avisam")
    }

    private func cameraItem(_ camera: Camera) -> some View {
        Toggle(camera.name, isOn: Binding(
            get: { !alarms.isMuted(camera) },
            set: { alarms.setMuted(camera, !$0) }
        ))
    }

    private func iconButton(_ icon: String, _ help: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help(help)
        .accessibilityLabel(help)
    }

    private var statusText: String {
        guard vault.isUnlocked else { return String(localized: "Sessão fechada") }
        guard alarms.enabled else { return String(localized: "Alertas desligados") }
        let muted = store.cameras.filter(alarms.isMuted).count
        let devices = connectedDevices == 1 ? String(localized: "1 equipamento") : String(localized: "\(connectedDevices) equipamentos")
        return muted > 0 ? String(localized: "\(devices) · \(muted) silenciada(s)") : devices
    }
}
