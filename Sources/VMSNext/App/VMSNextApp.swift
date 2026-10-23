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
                } else {
                    LoginView(vault: vault)
                }
            }
            .environmentObject(store)
            .onAppear { background.windowOpened() }
            .onDisappear { background.windowClosed() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Sair da sessão") { vault.lock(forget: true) }
                    .disabled(!vault.isUnlocked)
            }
        }

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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
