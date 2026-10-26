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

    /// Zoom mirando um ponto (posição do mouse dentro da imagem, eixo y para cima, como a camada): o que está
    /// embaixo do mouse continua embaixo dele depois do zoom.
    func zoom(by factor: CGFloat, at point: CGPoint, in area: CGSize) {
        let old = scale
        let new = min(max(old * factor, 1), Self.maximum)
        guard new != old else { return }
        if new < 1.02 { reset(); return }
        let current = clampedPan(in: area)
        let offset = CGPoint(x: point.x - area.width / 2, y: point.y - area.height / 2)
        scale = new
        pan = CGSize(width: offset.x - (offset.x - current.width) * new / old,
                     height: offset.y - (offset.y - current.height) * new / old)
        pan = clampedPan(in: area)
        commit()
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

    /// Só a pinça (no mosaico, enquanto a imagem não está ampliada, arrastar continua trocando o quadro de lugar).
    var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { self.magnify(by: $0.magnification) }
            .onEnded { _ in self.commit() }
    }

    /// Deslocamento efetivo: o mesmo limite usado pela camada do vídeo (a imagem não sai do quadro).
    func clampedPan(in area: CGSize) -> CGSize {
        let limitX = (scale - 1) * area.width / 2
        let limitY = (scale - 1) * area.height / 2
        return CGSize(width: min(max(pan.width, -limitX), limitX), height: min(max(pan.height, -limitY), limitY))
    }
}

/// Zoom digital por cima do vídeo, na lateral direita: lupa + em cima, o tamanho no meio e lupa − embaixo.
/// Fica quase transparente para não atrapalhar a imagem e acende em branco quando o mouse passa por cima.
struct ZoomControls: View {
    @ObservedObject var zoom: DigitalZoom
    var enabled = true
    /// Versão menor, para os quadros do mosaico.
    var compact = false
    @StateObject private var hover = HoverFlag()

    private var button: CGSize { compact ? CGSize(width: 30, height: 26) : CGSize(width: 48, height: 44) }

    var body: some View {
        VStack(spacing: compact ? 2 : 6) {
            Button { zoom.step(1) } label: { Image(systemName: "plus.magnifyingglass").frame(width: button.width, height: button.height) }
                .disabled(!enabled || zoom.scale >= DigitalZoom.maximum)
                .help("Zoom digital: amplia a imagem no Mac (qualquer câmera). Também: roda do mouse ou pinça no trackpad, mirando onde o mouse está; arraste para mover.")
                .accessibilityLabel("Aumentar o zoom digital")
            Button { zoom.reset() } label: {
                Text(String(format: "%.1f×", zoom.scale))
                    .font(.system(size: compact ? 11 : 15, weight: .bold)).monospacedDigit()
                    .frame(width: compact ? 34 : 52, height: compact ? 16 : 24)
            }
            .disabled(zoom.scale <= 1)
            .help("Voltar ao tamanho normal")
            Button { zoom.step(-1) } label: { Image(systemName: "minus.magnifyingglass").frame(width: button.width, height: button.height) }
                .disabled(!enabled || zoom.scale <= 1)
                .help("Diminuir o zoom digital")
                .accessibilityLabel("Diminuir o zoom digital")
        }
        .buttonStyle(.plain)
        .font(.system(size: compact ? 16 : 26, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.vertical, compact ? Space.xs : Space.s)
        .background(.black.opacity(hover.on ? 0.6 : 0.2), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(hover.on ? 0.35 : 0.1)))
        .opacity(hover.on ? 1 : 0.35)
        .contentShape(Capsule())
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.15), value: hover.on)
        .padding(.trailing, compact ? Space.s : Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}
