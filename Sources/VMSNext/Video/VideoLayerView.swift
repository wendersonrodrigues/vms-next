import AppKit
import AVFoundation
import SwiftUI

/// Hospeda o AVSampleBufferDisplayLayer de um LiveStream dentro do SwiftUI.
struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.host(layer)
        return view
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        view.host(layer)
    }
}

final class LayerHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    func host(_ video: AVSampleBufferDisplayLayer) {
        guard video.superlayer !== layer else { return }
        video.removeFromSuperlayer()
        layer?.addSublayer(video)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.frame = bounds }
        CATransaction.commit()
    }
}
