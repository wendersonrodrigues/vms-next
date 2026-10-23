import AppKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

/// Foto do quadro que está na tela: inteira, ou só a parte ampliada pelo zoom digital.
/// Usa o quadro já decodificado pelo Mac, então não pede nada à câmera.
@MainActor
enum FrameSnapshot {
    enum Failure: LocalizedError {
        case noFrame
        case encode

        var errorDescription: String? {
            switch self {
            case .noFrame: return "Ainda não há imagem na tela para fotografar."
            case .encode: return "Não foi possível gerar a foto."
            }
        }
    }

    /// Grava um JPEG na pasta de fotos das Preferências (ou pergunta onde, se estiver configurado assim).
    /// Com `zoom`, salva só a parte visível da imagem ampliada. Devolve nil se a pessoa cancelar.
    static func save(from renderer: AVSampleBufferVideoRenderer, name: String, zoom: DigitalZoom?, crop: SplitPart = .full) throws -> URL? {
        guard let data = jpeg(from: renderer, zoom: zoom, crop: crop) else { throw Failure.noFrame }
        let prefs = AppPreferences.shared
        guard let url = prefs.destination(named: name, in: prefs.photoFolder, type: .jpeg) else { return nil }
        try data.write(to: url)
        AppLog.shared.add(.file, "Foto salva: \(url.lastPathComponent)")
        return url
    }

    /// JPEG do quadro na tela (inteiro ou só a parte ampliada). nil se ainda não há imagem.
    /// `crop`: metade de cima ou de baixo (split virtual); a foto sai só com essa metade.
    static func jpeg(from renderer: AVSampleBufferVideoRenderer, zoom: DigitalZoom?, crop: SplitPart = .full) -> Data? {
        guard #available(macOS 14.4, *), let buffer = renderer.displayedPixelBuffer() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let full = image.extent
        // A imagem do CoreImage tem origem embaixo: a metade de cima é a de y maior.
        let base: CGRect
        switch crop {
        case .full: base = full
        case .top: base = CGRect(x: full.minX, y: full.midY, width: full.width, height: full.height / 2)
        case .bottom: base = CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height / 2)
        }
        var region = base
        if let zoom, zoom.scale > 1, zoom.viewSize.width > 0 {
            region = visibleRegion(view: zoom.viewSize, image: base.size, zoom: zoom.scale,
                                   pan: zoom.clampedPan(in: zoom.viewSize))
                .offsetBy(dx: base.minX, dy: base.minY).integral.intersection(base)
        }
        guard !region.isEmpty, let cgImage = CIContext().createCGImage(image, from: region) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    /// Parte da imagem (em pixels, origem embaixo) que aparece no quadro com zoom. Mesmo cálculo da
    /// camada: o vídeo cabe no quadro (resizeAspect) e o quadro inteiro é ampliado em volta do centro.
    static func visibleRegion(view: CGSize, image: CGSize, zoom: CGFloat, pan: CGSize) -> CGRect {
        let fit = min(view.width / image.width, view.height / image.height)
        let fitted = CGRect(x: (view.width - image.width * fit) / 2, y: (view.height - image.height * fit) / 2,
                            width: image.width * fit, height: image.height * fit)
        let layerOrigin = CGPoint(x: view.width / 2 * (1 - zoom) + pan.width, y: view.height / 2 * (1 - zoom) + pan.height)
        let shown = CGRect(x: layerOrigin.x + fitted.minX * zoom, y: layerOrigin.y + fitted.minY * zoom,
                           width: fitted.width * zoom, height: fitted.height * zoom)
        let visible = shown.intersection(CGRect(origin: .zero, size: view))
        let pixels = fit * zoom
        return CGRect(x: (visible.minX - shown.minX) / pixels, y: (visible.minY - shown.minY) / pixels,
                      width: visible.width / pixels, height: visible.height / pixels)
    }
}
