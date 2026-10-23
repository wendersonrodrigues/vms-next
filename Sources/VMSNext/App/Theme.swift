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

// MARK: - Reação ao mouse

final class HoverFlag: ObservableObject {
    @Published var on = false
}

/// Botão que reage ao mouse: clareia, ganha um fundo leve e cresce um pouco; ao clicar, encolhe.
struct HoverButtonStyle: ButtonStyle {
    var radius: CGFloat = 10

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
            .padding(.horizontal, title == nil ? 8 : 11)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(active ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.surfaceHigh)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
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
