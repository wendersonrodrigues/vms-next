import AppKit
import AVFoundation
import SwiftUI

/// Hospeda o AVSampleBufferDisplayLayer de um LiveStream dentro do SwiftUI.
struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    /// Split virtual: mostra só a metade de cima ou de baixo da imagem.
    var crop: SplitPart = .full
    /// Tamanho do vídeo, para centralizar a metade cortada.
    var videoSize: CGSize?
    /// Zoom digital (1 = sem zoom) e deslocamento da imagem ampliada, em pontos.
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// Roda do mouse (ou rolagem no trackpad): fator de zoom, ponto do mouse dentro da imagem e tamanho dela.
    var onScrollZoom: ((CGFloat, CGPoint, CGSize) -> Void)?

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        view.crop = crop
        view.videoSize = videoSize
        view.zoom = zoom
        view.pan = pan
        view.onScrollZoom = onScrollZoom
        view.host(layer)
    }
}

final class LayerHostView: NSView {
    var crop: SplitPart = .full {
        didSet { if crop != oldValue { needsLayout = true } }
    }
    var videoSize: CGSize? {
        didSet { if videoSize != oldValue { needsLayout = true } }
    }
    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { needsLayout = true } }
    }
    var pan: CGSize = .zero {
        didSet { if pan != oldValue { needsLayout = true } }
    }

    var onScrollZoom: ((CGFloat, CGPoint, CGSize) -> Void)?

    /// Roda do mouse: para cima amplia, para baixo diminui, mirando onde o mouse está. Sem zoom, rolar para
    /// baixo segue adiante (para quem estiver em volta poder rolar).
    override func scrollWheel(with event: NSEvent) {
        guard let onScrollZoom, event.scrollingDeltaY != 0 else { return super.scrollWheel(with: event) }
        let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        // Mouse: cada "clique" da roda é um passo; trackpad: proporcional ao movimento.
        let factor = event.hasPreciseScrollingDeltas ? exp(delta * 0.01) : (delta > 0 ? 1.2 : 1 / 1.2)
        if zoom <= 1, factor < 1 { return super.scrollWheel(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        onScrollZoom(factor, CGPoint(x: point.x - clip.frame.minX, y: point.y - clip.frame.minY), clip.bounds.size)
    }

    /// Recorte: só o que está dentro dele aparece (no split, a metade escolhida).
    private let clip = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        clip.masksToBounds = true
        layer?.addSublayer(clip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    func host(_ video: AVSampleBufferDisplayLayer) {
        guard video.superlayer !== clip else { return }
        video.removeFromSuperlayer()
        clip.sublayers?.forEach { $0.removeFromSuperlayer() }
        clip.addSublayer(video)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let (visible, inner) = cropFrames()
        clip.frame = visible
        var frame = inner
        // Zoom digital: amplia em volta do centro do recorte e desloca, sem deixar a imagem sair dele.
        if zoom > 1 {
            let area = clip.bounds
            let center = CGPoint(x: area.midX, y: area.midY)
            let limitX = (zoom - 1) * area.width / 2
            let limitY = (zoom - 1) * area.height / 2
            let dx = min(max(pan.width, -limitX), limitX)
            let dy = min(max(pan.height, -limitY), limitY)
            frame = CGRect(x: center.x + (frame.minX - center.x) * zoom + dx,
                           y: center.y + (frame.minY - center.y) * zoom + dy,
                           width: frame.width * zoom, height: frame.height * zoom)
        }
        clip.sublayers?.forEach { $0.frame = frame }
        CATransaction.commit()
    }

    /// Recorte visível (no quadro) e posição do vídeo dentro dele. No split, o recorte tem o tamanho
    /// exato da metade, centralizado; o vídeo inteiro fica dentro dele deslocado para mostrar só essa metade.
    private func cropFrames() -> (visible: CGRect, video: CGRect) {
        guard crop != .full else { return (bounds, CGRect(origin: .zero, size: bounds.size)) }
        guard let size = videoSize, size.width > 0, size.height > 0 else {
            // Sem o tamanho ainda: dobra a altura e mostra a metade.
            return (bounds, CGRect(x: 0, y: crop == .top ? -bounds.height : 0, width: bounds.width, height: bounds.height * 2))
        }
        let scale = min(bounds.width / size.width, bounds.height / (size.height / 2))
        let width = size.width * scale
        let half = size.height * scale / 2
        let visible = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - half) / 2, width: width, height: half)
        // A camada não é invertida (y cresce para cima): a metade de cima da imagem é a parte de cima do vídeo.
        let video = CGRect(x: 0, y: crop == .top ? -half : 0, width: width, height: half * 2)
        return (visible, video)
    }
}
