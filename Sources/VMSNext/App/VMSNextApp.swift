import AppKit
import SwiftUI

@main
struct VMSNextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: CameraStore
    @ObservedObject private var vault = Vault.shared
    @ObservedObject private var background = BackgroundSettings.shared

    init() {
        let store = CameraStore()
        _store = StateObject(wrappedValue: store)
        // Com "Lembrar senha", os alertas começam já ao abrir o app, mesmo sem janela.
        if Vault.shared.unlockWithRememberedLogin() {
            AlarmCenter.shared.start(store: store)
        }
    }

    var body: some Scene {
        WindowGroup("VMS Next", id: "main") {
            Group {
                if vault.isUnlocked {
                    ContentView()
                        .frame(minWidth: 960, minHeight: 600)
                        // Listas e formulários sem o fundo do sistema: aparece o fundo do tema.
                        .scrollContentBackground(.hidden)
                        .background(Theme.background)
                } else {
                    LoginView(vault: vault)
                }
            }
            .environmentObject(store)
            .tint(Theme.accent)
            .onAppear { background.windowOpened() }
            .onDisappear { background.windowClosed() }
        }
        .windowResizability(.contentSize)
        .commands {
            AppCommands()
            CommandGroup(replacing: .appInfo) {
                Button("Sobre o VMS Next") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: "Criado por Wenderson Rodrigues\nCódigo aberto, licença MIT\ngithub.com/wendersonrodrigues/vms-next"),
                    ])
                }
            }
            CommandGroup(replacing: .help) {
                HelpMenuItems()
            }
            CommandGroup(after: .appInfo) {
                Button("Sair da sessão") { vault.lock(forget: true) }
                    .disabled(!vault.isUnlocked)
            }
        }

        Window("Ajuda do VMS Next", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Mantém o app rodando com a janela fechada (alertas continuam chegando).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Fecha os arquivos das gravações no Mac para não ficarem corrompidos.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { LocalRecorder.shared.stopAll() }
        Thread.sleep(forTimeInterval: 1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppearanceSettings.shared.apply() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Itens do menu Ajuda (precisam do openWindow do ambiente).
struct HelpMenuItems: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Ajuda do VMS Next") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
        Link("Projeto no GitHub", destination: NavigationRail.githubURL)
    }
}
