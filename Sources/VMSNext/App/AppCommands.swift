import SwiftUI

/// Menus do app com atalhos de teclado, como nos apps do Mac: Preferências no ⌘, ; as telas no menu Visualizar
/// (⌘1 a ⌘6); e o menu Mosaico (páginas, voltar ao mosaico e rodízio). Leem o estado da janela em foco.
struct AppCommands: Commands {
    @FocusedObject private var ui: ContentUIState?
    @ObservedObject private var rotation = RotationStore.shared

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Preferências…") { ui?.mode = .preferences }
                .keyboardShortcut(",")
                .disabled(ui == nil)
        }
        CommandGroup(before: .sidebar) {
            screen(.home, "1")
            screen(.live, "2")
            screen(.recordings, "3")
            screen(.events, "4")
            screen(.devices, "5")
            screen(.settings, "6")
            Divider()
        }
        CommandMenu("Mosaico") {
            let onMosaic = ui?.mode == .live && ui?.gridSelection == nil
            Button("Página anterior") { ui?.page = max(0, (ui?.page ?? 0) - 1) }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
                .disabled(!onMosaic || (ui?.page ?? 0) == 0)
            Button("Próxima página") { if let ui { ui.page = min(ui.pageCount - 1, ui.page + 1) } }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
                .disabled(!onMosaic || (ui?.page ?? 0) >= (ui?.pageCount ?? 1) - 1)
            Button("Voltar ao mosaico") { if let ui, let back = ui.gridSelection { ui.selection = back } }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(ui?.mode != .live || ui?.gridSelection == nil)
            Divider()
            Button(rotation.running ? "Parar o rodízio" : "Começar o rodízio") {
                if rotation.steps.isEmpty { ui?.editingRotation = true } else { rotation.toggle() }
            }
            .keyboardShortcut("r", modifiers: [.option, .command])
            .disabled(ui == nil)
        }
    }

    private func screen(_ mode: ViewMode, _ key: KeyEquivalent) -> some View {
        Button(mode.title) { ui?.mode = mode }
            .keyboardShortcut(key)
            .disabled(ui == nil)
    }
}
