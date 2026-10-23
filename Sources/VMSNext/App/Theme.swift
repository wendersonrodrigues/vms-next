import AppKit
import SwiftUI

/// Cores do app. No modo escuro: fundo quase preto azulado, cards em grafite com borda sutil e destaque
/// azul-violeta, combinando com os ícones. No modo claro, tons equivalentes mais claros.
enum Theme {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    /// Fundo da janela.
    static let background = dynamic(dark: hex(0x0A0B10), light: hex(0xF2F3F7))
    /// Lista de câmeras e painéis laterais.
    static let sidebar = dynamic(dark: hex(0x0F1117), light: hex(0xE9EBF1))
    /// Cards e barras.
    static let surface = dynamic(dark: hex(0x15171F), light: hex(0xFFFFFF))
    /// Cards dentro de cards, botões e o painel de PTZ.
    static let surfaceHigh = dynamic(dark: hex(0x1D202A), light: hex(0xF6F7FA))
    /// Borda sutil dos cards.
    static let stroke = dynamic(dark: NSColor.white.withAlphaComponent(0.07), light: NSColor.black.withAlphaComponent(0.08))
    /// Destaque (botões, seleção, interruptores).
    static let accent = Color(nsColor: hex(0x5B7CFF))
    static let accentEnd = Color(nsColor: hex(0xA35BFF))
    static let accentGradient = LinearGradient(colors: [accent, accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Fundo de card: grafite com um leve brilho no alto, como nos painéis de referência.
    static var cardFill: some ShapeStyle {
        LinearGradient(colors: [surfaceHigh, surface], startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    /// Card padrão do app (cantos arredondados, fundo grafite e borda sutil).
    func themedCard(radius: CGFloat = 20) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.stroke))
    }
}
