import AppKit
import SwiftUI

/// Cores do app. No modo escuro: fundo quase preto azulado, cards em grafite com borda sutil e destaque
/// azul-violeta, combinando com os ícones. No modo claro, tons equivalentes mais claros; as cores usadas em texto
/// são mais escuras no claro para passar de 4,5:1 de contraste (WCAG). Com "Aumentar contraste" ligado no macOS,
/// bordas e textos coloridos ficam mais fortes.
enum Theme {
    private static func dynamic(dark: NSColor, light: NSColor,
                                darkHighContrast: NSColor? = nil, lightHighContrast: NSColor? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua,
                                               .accessibilityHighContrastAqua]) {
            case .accessibilityHighContrastDarkAqua: return darkHighContrast ?? dark
            case .accessibilityHighContrastAqua: return lightHighContrast ?? light
            case .darkAqua: return dark
            default: return light
            }
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
    /// Borda sutil dos cards (bem marcada com "Aumentar contraste").
    static let stroke = dynamic(dark: NSColor.white.withAlphaComponent(0.07), light: NSColor.black.withAlphaComponent(0.08),
                                darkHighContrast: NSColor.white.withAlphaComponent(0.5),
                                lightHighContrast: NSColor.black.withAlphaComponent(0.5))
    /// Destaque (botões, seleção, interruptores, links). É o único destaque do app: não usar `Color.accentColor`,
    /// que segue a cor escolhida no macOS. Claro #3550D8 (5,8:1 no fundo claro); escuro #5B7CFF (4,9:1).
    static let accent = dynamic(dark: hex(0x5B7CFF), light: hex(0x3550D8),
                                darkHighContrast: hex(0x8FA6FF), lightHighContrast: hex(0x2A40B0))
    static let accentEnd = dynamic(dark: hex(0xA35BFF), light: hex(0x7A3FD6))
    /// Avisos e erros em texto. O laranja do sistema dá só 2,2:1 no fundo claro; aqui #B25000 (5,2:1).
    static let warning = dynamic(dark: hex(0xFF9F0A), light: hex(0xB25000),
                                 darkHighContrast: hex(0xFFB340), lightHighContrast: hex(0x8F4000))
    /// "Deu certo" em texto. O verde do sistema dá 2,2:1 no fundo claro; aqui #1E7B34 (5,3:1).
    static let success = dynamic(dark: hex(0x30D158), light: hex(0x1E7B34),
                                 darkHighContrast: hex(0x5BE37D), lightHighContrast: hex(0x155F27))
    static let accentGradient = LinearGradient(colors: [accent, accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Fundo de card: grafite com um leve brilho no alto, como nos painéis de referência.
    static var cardFill: some ShapeStyle {
        LinearGradient(colors: [surfaceHigh, surface], startPoint: .top, endPoint: .bottom)
    }
}

/// Escala de margens do app (passos de 4 pt, como no macOS). Use só estes valores em `.padding`.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

/// Arredondamentos do app: controles pequenos, botões e miniaturas, cards, e banner/coluna.
enum Radius {
    static let small: CGFloat = 6
    static let control: CGFloat = 10
    static let card: CGFloat = 16
    static let large: CGFloat = 22
}

extension View {
    /// Card padrão do app (cantos arredondados, fundo grafite e borda sutil).
    func themedCard(radius: CGFloat = Radius.card) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.stroke))
    }
}

// MARK: - Reação ao mouse

final class HoverFlag: ObservableObject {
    @Published var on = false
}

/// Botão que reage ao mouse: clareia, ganha um fundo leve e cresce um pouco; ao clicar, encolhe.
struct HoverButtonStyle: ButtonStyle {
    var radius: CGFloat = Radius.control

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, radius: radius)
    }
}

private struct HoverBody: View {
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat
    @StateObject private var hover = HoverFlag()
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let active = hover.on && enabled
        configuration.label
            .background(RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(active ? 0.08 : 0)))
            .brightness(active ? 0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.95 : (active ? 1.04 : 1))
            .shadow(color: active ? Theme.accent.opacity(0.35) : .clear, radius: 8)
            .opacity(enabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.15), value: active)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hover.on = $0 }
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}

/// Botão das barras de baixo (ao vivo e gravações): ícone, texto opcional e destaque quando ligado.
struct BarButton: View {
    let icon: String
    var title: String?
    var active = false
    var tint: Color = Theme.accent
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
            }
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.85))
            .padding(.horizontal, title == nil ? Space.s : Space.m)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(active ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.surfaceHigh)))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Theme.stroke))
        }
        .buttonStyle(.hover)
        .help(help)
    }
}

/// Logo do app: versão escura no modo escuro (Resources/Icons/logo_dark.png), clara no modo claro.
struct AppLogo: View {
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    private static func load(_ name: String) -> NSImage? {
        Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent("Icons/\(name).png")) }
    }
    private static let dark = load("logo_dark")
    private static let light = load("logo_light")

    var body: some View {
        Image(nsImage: (scheme == .dark ? Self.dark : Self.light) ?? NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
