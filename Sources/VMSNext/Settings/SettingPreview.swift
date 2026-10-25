import AppKit
import SwiftUI

/// Ilustração de exemplo para os ajustes de imagem (não é a câmera de verdade): fotos de exemplo geradas
/// no Magnific (Resources/Previews: dia, noite colorida, infravermelho e contraluz), com o efeito do ajuste
/// aplicado na hora. Sem as fotos, usa uma cena simples desenhada pelo app.
struct SettingPreview: View {
    enum Night { case none, color, infrared, dualLight }

    var night: Night = .none
    var brightness: Double = 50
    var contrast: Double = 50
    var saturation: Double = 50
    var hue: Double = 50
    var mirror = false
    var flip = false
    /// Compensação de contraluz: com ela, a pessoa na frente do portão claro aparece.
    var backlight: Bool?
    var caption = "Exemplo ilustrativo"

    var body: some View {
        VStack(spacing: 4) {
            scene
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Color.primary.opacity(0.15)))
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Fotos de exemplo do pacote do app.
    private static let photos: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Previews") else { return result }
        for name in ["day", "night_color", "night_ir", "backlight"] {
            if let image = NSImage(contentsOf: folder.appendingPathComponent("\(name).jpg")) { result[name] = image }
        }
        return result
    }()

    @ViewBuilder
    private var photo: some View {
        let photos = Self.photos
        switch night {
        case .color: Image(nsImage: photos["night_color"]!).resizable()
        case .infrared: Image(nsImage: photos["night_ir"]!).resizable()
        case .dualLight:
            // Luz dupla: a cena em infravermelho e, em volta da pessoa, a luz branca acesa e a cor.
            ZStack {
                Image(nsImage: photos["night_ir"]!).resizable()
                Image(nsImage: photos["night_color"]!).resizable()
                    .mask(RadialGradient(colors: [.white, .white, .clear], center: UnitPoint(x: 0.58, y: 0.45),
                                         startRadius: 0, endRadius: 70))
            }
        case .none:
            Image(nsImage: (backlight == false ? photos["backlight"] : photos["day"])!).resizable()
        }
    }

    private var hasPhotos: Bool { Self.photos.count == 4 }

    private var scene: some View {
        ZStack {
            if hasPhotos {
                photo
            } else {
                Canvas { context, size in draw(context, size) }
            }
            if !hasPhotos, night == .infrared || night == .dualLight {
                // Ruído leve do infravermelho.
                Canvas { context, size in
                    var generator = SplitMix(seed: 7)
                    for _ in 0 ..< 500 {
                        let x = Double(generator.next() % 1000) / 1000 * size.width
                        let y = Double(generator.next() % 1000) / 1000 * size.height
                        context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.15)))
                    }
                }
            }
        }
        .saturation(night == .infrared || night == .dualLight ? (hasPhotos && night == .dualLight ? saturation / 50 : 0) : saturation / 50)
        .brightness((brightness - 50) / 120)
        .contrast(0.4 + contrast / 83)
        .hueRotation(.degrees((hue - 50) * 3.6))
        .scaleEffect(x: mirror ? -1 : 1, y: flip ? -1 : 1)
        .animation(.easeOut(duration: 0.2), value: [brightness, contrast, saturation, hue])
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let isNight = night != .none
        let ir = night == .infrared
        // Céu e chão.
        let sky: [Color] = ir ? [.gray.opacity(0.55), .gray.opacity(0.35)]
            : isNight ? [Color(red: 0.05, green: 0.07, blue: 0.18), Color(red: 0.12, green: 0.12, blue: 0.25)]
            : [Color(red: 0.45, green: 0.72, blue: 0.95), Color(red: 0.78, green: 0.9, blue: 1)]
        context.fill(Path(CGRect(x: 0, y: 0, width: w, height: h * 0.6)),
                     with: .linearGradient(Gradient(colors: sky), startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.6)))
        let ground = ir ? Color.gray.opacity(0.6) : isNight ? Color(red: 0.1, green: 0.17, blue: 0.1) : Color(red: 0.35, green: 0.62, blue: 0.3)
        context.fill(Path(CGRect(x: 0, y: h * 0.6, width: w, height: h * 0.4)), with: .color(ground))
        // Sol ou lua (indica direção: fica sempre à esquerda).
        context.fill(Path(ellipseIn: CGRect(x: w * 0.08, y: h * 0.1, width: h * 0.16, height: h * 0.16)),
                     with: .color(isNight ? .white.opacity(0.85) : .yellow))
        // Casa com portão claro (contraluz).
        let house = CGRect(x: w * 0.52, y: h * 0.28, width: w * 0.36, height: h * 0.4)
        context.fill(Path(house), with: .color(ir ? .gray.opacity(0.8) : isNight ? Color(red: 0.3, green: 0.25, blue: 0.22) : Color(red: 0.85, green: 0.55, blue: 0.4)))
        var roof = Path()
        roof.move(to: CGPoint(x: house.minX - 6, y: house.minY))
        roof.addLine(to: CGPoint(x: house.midX, y: house.minY - h * 0.16))
        roof.addLine(to: CGPoint(x: house.maxX + 6, y: house.minY))
        context.fill(roof, with: .color(ir ? .gray : isNight ? Color(red: 0.35, green: 0.1, blue: 0.08) : Color(red: 0.7, green: 0.15, blue: 0.1)))
        let gate = CGRect(x: house.midX - w * 0.06, y: house.maxY - h * 0.24, width: w * 0.12, height: h * 0.24)
        context.fill(Path(gate), with: .color(backlight != nil ? .white : (ir ? .gray.opacity(0.4) : Color(red: 0.4, green: 0.3, blue: 0.25))))
        // Árvore.
        context.fill(Path(CGRect(x: w * 0.22, y: h * 0.4, width: w * 0.03, height: h * 0.25)), with: .color(ir ? .gray.opacity(0.5) : .brown))
        context.fill(Path(ellipseIn: CGRect(x: w * 0.14, y: h * 0.2, width: w * 0.19, height: h * 0.28)),
                     with: .color(ir ? .gray.opacity(0.75) : isNight ? Color(red: 0.05, green: 0.25, blue: 0.08) : Color(red: 0.15, green: 0.5, blue: 0.2)))
        // Pessoa na frente do portão.
        let personLit = night == .dualLight || night == .color || night == .none
        let personColor: Color = backlight == false ? .black
            : ir ? .gray.opacity(0.95) : personLit ? Color(red: 0.15, green: 0.35, blue: 0.85) : .black
        let person = CGRect(x: gate.midX - w * 0.025, y: gate.minY + h * 0.04, width: w * 0.05, height: h * 0.2)
        context.fill(Path(ellipseIn: CGRect(x: person.minX + person.width * 0.15, y: person.minY - h * 0.07, width: person.width * 0.7, height: h * 0.07)),
                     with: .color(backlight == false ? .black : (ir ? .gray : Color(red: 0.9, green: 0.7, blue: 0.55))))
        context.fill(Path(roundedRect: person, cornerRadius: Radius.small), with: .color(personColor))
        // Luz branca da câmera (visão noturna colorida e luz dupla).
        if night == .color || night == .dualLight {
            context.fill(Path(ellipseIn: CGRect(x: gate.midX - w * 0.2, y: h * 0.45, width: w * 0.4, height: h * 0.45)),
                         with: .radialGradient(Gradient(colors: [.white.opacity(0.35), .clear]),
                                               center: CGPoint(x: gate.midX, y: h * 0.68), startRadius: 0, endRadius: w * 0.2))
        }
        // Na luz dupla, o resto da cena fica em infravermelho (cinza) e só a área iluminada ganha cor.
        if night == .dualLight {
            context.fill(Path(CGRect(x: 0, y: 0, width: w * 0.42, height: h)), with: .color(.gray.opacity(0.55)))
            context.draw(Text("IR").font(.caption2.weight(.bold)).foregroundColor(.white), at: CGPoint(x: w * 0.05, y: h * 0.92))
            context.draw(Text("luz acesa ao detectar").font(.caption2).foregroundColor(.white), at: CGPoint(x: w * 0.72, y: h * 0.94))
        }
        // Marca para mostrar o espelhamento: "1" sempre no canto superior esquerdo da cena.
        context.draw(Text("1").font(.system(size: 12, weight: .heavy)).foregroundColor(.white), at: CGPoint(x: w * 0.93, y: h * 0.1))
    }
}

/// Gerador simples e fixo (o ruído não muda a cada redesenho).
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
