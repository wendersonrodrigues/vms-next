import SwiftUI

/// Miniatura de um modelo de tela, desenhada a partir dos próprios quadros do modelo (vale também para os
/// modelos personalizados), no estilo do app: vidro azul-violeta com brilho quando selecionado.
struct TemplateThumbnail: View {
    /// nil = Auto.
    let template: ViewTemplate?
    var selected = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                if let template {
                    let gap: CGFloat = 1.5
                    let cw = (size.width - gap * CGFloat(template.columns - 1)) / CGFloat(template.columns)
                    let ch = (size.height - gap * CGFloat(template.rows - 1)) / CGFloat(template.rows)
                    ForEach(template.cells.indices, id: \.self) { index in
                        let cell = template.cells[index]
                        cellShape
                            .frame(width: cw * CGFloat(cell.w) + gap * CGFloat(cell.w - 1),
                                   height: ch * CGFloat(cell.h) + gap * CGFloat(cell.h - 1))
                            .offset(x: CGFloat(cell.x) * (cw + gap), y: CGFloat(cell.y) * (ch + gap))
                    }
                } else {
                    cellShape
                    Text("AUTO")
                        .font(.system(size: size.height * 0.32, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: size.width, height: size.height)
                }
            }
        }
        .frame(width: 34, height: 22)
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.22) : Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent.opacity(0.8) : Theme.stroke))
        .shadow(color: selected ? Theme.accent.opacity(0.6) : .clear, radius: 6)
    }

    private var cellShape: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.55)))
    }
}
