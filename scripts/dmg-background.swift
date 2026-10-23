// Desenha o fundo da janela do instalador (DMG): 660 × 400, nas cores do app,
// com uma seta do ícone do app até a pasta Aplicativos. Gera também a versão @2x.
// Uso: swift scripts/dmg-background.swift Resources/DMG
import AppKit

let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(scale: CGFloat) -> Data {
    let size = NSSize(width: 660 * scale, height: 400 * scale)
    let image = NSImage(size: size)
    image.lockFocus()
    let rect = NSRect(origin: .zero, size: size)
    NSGradient(colors: [NSColor(srgbRed: 0.04, green: 0.05, blue: 0.09, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.22, alpha: 1)])!.draw(in: rect, angle: -35)
    // Brilho azul-violeta.
    let center = NSPoint(x: size.width / 2, y: size.height * 0.45)
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.49, blue: 1, alpha: 0.30),
                        NSColor(srgbRed: 0.36, green: 0.49, blue: 1, alpha: 0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: size.width * 0.45, options: [])
    // Seta entre os dois ícones (ícones ficam em x = 170 e 490, y = 200 de cima).
    let y = size.height - 200 * scale
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 255 * scale, y: y))
    arrow.line(to: NSPoint(x: 395 * scale, y: y))
    arrow.lineWidth = 5 * scale
    arrow.lineCapStyle = .round
    NSColor(srgbRed: 0.64, green: 0.36, blue: 1, alpha: 0.9).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 395 * scale, y: y + 16 * scale))
    head.line(to: NSPoint(x: 420 * scale, y: y))
    head.line(to: NSPoint(x: 395 * scale, y: y - 16 * scale))
    head.close()
    NSColor(srgbRed: 0.64, green: 0.36, blue: 1, alpha: 0.9).setFill()
    head.fill()
    // Textos.
    func text(_ string: String, _ fontSize: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat, _ top: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize * scale, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: style,
        ]
        (string as NSString).draw(in: NSRect(x: 0, y: size.height - (top + fontSize * 1.6) * scale, width: size.width, height: fontSize * 1.6 * scale),
                                  withAttributes: attributes)
    }
    text("Instalar o VMS Next", 26, .bold, 1, 42)
    text("Arraste o app para a pasta Aplicativos", 15, .medium, 0.75, 84)
    text("Na primeira abertura: botão direito no app → Abrir", 12, .regular, 0.55, 330)
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: "\(folder)/background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: "\(folder)/background@2x.png"))
print("Fundo salvo em \(folder)")
