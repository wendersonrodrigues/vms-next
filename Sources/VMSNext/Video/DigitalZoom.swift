import SwiftUI

/// Zoom digital (ao vivo e gravações): só amplia a imagem no Mac, a câmera não muda.
@MainActor
final class DigitalZoom: ObservableObject {
    static let maximum: CGFloat = 8

    @Published private(set) var scale: CGFloat = 1
    @Published private(set) var pan: CGSize = .zero
    /// Tamanho do quadro na tela, para saber que parte da imagem está aparecendo (foto do zoom).
    var viewSize: CGSize = .zero
    private var baseScale: CGFloat = 1
    private var basePan: CGSize = .zero

    func magnify(by factor: CGFloat) {
        scale = min(max(baseScale * factor, 1), Self.maximum)
        if scale == 1 { pan = .zero }
    }

    /// Arrastar move a imagem; o eixo y da camada cresce para cima, ao contrário do gesto.
    func drag(by translation: CGSize) {
        guard scale > 1 else { return }
        pan = CGSize(width: basePan.width + translation.width, height: basePan.height - translation.height)
    }

    func commit() {
        baseScale = scale
        basePan = pan
    }

    func step(_ direction: Int) {
        scale = min(max(direction > 0 ? scale * 1.5 : scale / 1.5, 1), Self.maximum)
        if scale < 1.05 { reset() }
        commit()
    }

    func reset() {
        scale = 1
        pan = .zero
        commit()
    }

    /// Pinça amplia; arrastar move a imagem ampliada.
    var gesture: some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .onChanged { self.magnify(by: $0.magnification) }
                .onEnded { _ in self.commit() },
            DragGesture(minimumDistance: 4)
                .onChanged { self.drag(by: $0.translation) }
                .onEnded { _ in self.commit() }
        )
    }

    /// Deslocamento efetivo: o mesmo limite usado pela camada do vídeo (a imagem não sai do quadro).
    func clampedPan(in area: CGSize) -> CGSize {
        let limitX = (scale - 1) * area.width / 2
        let limitY = (scale - 1) * area.height / 2
        return CGSize(width: min(max(pan.width, -limitX), limitX), height: min(max(pan.height, -limitY), limitY))
    }
}

/// Botões − / tamanho / + do zoom digital, no canto de cima do vídeo.
struct ZoomControls: View {
    @ObservedObject var zoom: DigitalZoom

    var body: some View {
        VStack {
            HStack(spacing: 4) {
                Spacer()
                Button { zoom.step(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(zoom.scale <= 1)
                    .help("Diminuir o zoom digital")
                if zoom.scale > 1 {
                    Button { zoom.reset() } label: { Text(String(format: "%.1f×", zoom.scale)).monospacedDigit() }
                        .help("Voltar ao tamanho normal")
                }
                Button { zoom.step(1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(zoom.scale >= DigitalZoom.maximum)
                    .help("Zoom digital: amplia a imagem no Mac (funciona em qualquer câmera). Também dá para usar a pinça no trackpad e arrastar para mover.")
            }
            .buttonStyle(.plain)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
            Spacer()
        }
    }
}
