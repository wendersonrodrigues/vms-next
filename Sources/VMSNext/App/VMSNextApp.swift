import SwiftUI

@main
struct VMSNextApp: App {
    @StateObject private var store = CameraStore()
    @ObservedObject private var vault = Vault.shared

    init() {
        _ = Vault.shared.unlockWithRememberedLogin()
    }

    var body: some Scene {
        WindowGroup("VMS Next") {
            Group {
                if vault.isUnlocked {
                    ContentView()
                        .frame(minWidth: 960, minHeight: 600)
                } else {
                    LoginView(vault: vault)
                }
            }
            .environmentObject(store)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Sair da sessão") { vault.lock(forget: true) }
                    .disabled(!vault.isUnlocked)
            }
        }
    }
}
