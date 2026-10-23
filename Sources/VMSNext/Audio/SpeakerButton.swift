import SwiftUI

/// Botão de som (alto-falante). Só uma fonte toca por vez: ligar aqui desliga a câmera ou gravação anterior.
struct SpeakerButton: View {
    let id: UUID
    let setAudio: (Bool) -> Void

    @ObservedObject private var focus = AudioFocus.shared

    var body: some View {
        let on = focus.owner == id
        Button {
            focus.toggle(id)
        } label: {
            Image(systemName: on ? "speaker.wave.2.fill" : "speaker.slash.fill")
        }
        .help(on ? "Desligar o som" : "Ligar o som (desliga o som de outra câmera)")
        .onChange(of: focus.owner) { setAudio(focus.owner == id) }
        .onDisappear { focus.release(id) }
    }
}
