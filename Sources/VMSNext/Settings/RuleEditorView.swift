import SwiftUI

/// Área ou linha de aviso da detecção de pessoas (PedRule), em coordenadas normalizadas 0…1.
/// No equipamento os pontos vão de 0 a 8192 nos dois eixos, independente da resolução.
final class RuleDraft: ObservableObject, Identifiable {
    enum Kind: Int {
        case line = 0
        case area = 1
    }

    static let scale: CGFloat = 8192

    let id = UUID()
    let index: Int
    @Published var kind: Kind
    @Published var area: [CGPoint] {
        didSet { if rectangle { keepRectangle(old: oldValue) } }
    }
    /// Só retângulo (área do rosto): mover um canto leva junto os dois vizinhos.
    var rectangle = false
    private var adjusting = false
    @Published var line: [CGPoint]
    @Published var direction: Int

    init(index: Int, kind: Kind, area: [CGPoint], line: [CGPoint], direction: Int) {
        self.index = index
        self.kind = kind
        self.area = area
        self.line = line
        self.direction = direction
    }

    /// Polígono regular com `sides` lados no centro da imagem (ou retângulo, para 4).
    func applyShape(sides: Int) {
        if sides == 4 {
            area = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.8)]
            return
        }
        area = (0 ..< sides).map { i in
            let angle = -Double.pi / 2 + Double(i) * 2 * Double.pi / Double(sides)
            return CGPoint(x: 0.5 + 0.32 * cos(angle), y: 0.5 + 0.32 * sin(angle))
        }
    }

    /// Cantos em ordem: 0 em cima à esquerda, 1 em cima à direita, 2 embaixo à direita, 3 embaixo à esquerda.
    private func keepRectangle(old: [CGPoint]) {
        guard !adjusting, area.count == 4, old.count == 4,
              let moved = area.indices.first(where: { area[$0] != old[$0] }) else { return }
        adjusting = true
        defer { adjusting = false }
        let point = area[moved]
        let sameX = [3, 2, 1, 0][moved]
        let sameY = [1, 0, 3, 2][moved]
        area[sameX].x = point.x
        area[sameY].y = point.y
    }

    /// Retângulo que cobre os pontos (0…1), para gravar como X1/Y1/X2/Y2.
    var bounds: CGRect {
        let xs = area.map(\.x), ys = area.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func coverWholeImage() {
        area = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    }

    static func point(x: Any?, y: Any?) -> CGPoint {
        CGPoint(x: CGFloat(ConfigValue.int(x) ?? 0) / scale, y: CGFloat(ConfigValue.int(y) ?? 0) / scale)
    }

    static func device(_ value: CGFloat) -> Int {
        Int((min(max(value, 0), 1) * scale).rounded())
    }
}

/// Tela de desenho, como o "Regulation Painting" do VMS antigo: imagem ao vivo com a área ou a linha
/// por cima; os pontos são arrastáveis.
struct RuleEditorView: View {
    @ObservedObject var draft: RuleDraft
    let camera: Camera
    let onSave: (RuleDraft) async -> String?

    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var stream = LiveStream()
    @StateObject private var state = EditorState()

    final class EditorState: ObservableObject {
        @Published var saving = false
        @Published var error: String?
    }

    private let shapes: [(sides: Int, icon: String, label: String)] = [
        (3, "triangle", String(localized: "Triângulo")), (4, "rectangle", String(localized: "Retângulo")), (5, "pentagon", String(localized: "Pentágono")),
        (6, "hexagon", String(localized: "Hexágono")), (8, "octagon", String(localized: "Octógono")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.rectangle ? String(localized: "Área de detecção de rosto · \(camera.displayName)")
                                 : String(localized: "Área ou linha de aviso · \(camera.displayName)")).font(.headline)

            canvas
                .frame(maxWidth: .infinity)

            if draft.rectangle {
                HStack(spacing: 8) {
                    Button("Imagem toda") { draft.coverWholeImage() }
                    Text("A câmera só procura rostos dentro do retângulo. Arraste os cantos brancos para ajustar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
            Picker(selection: $draft.kind) {
                Text("Área de aviso").tag(RuleDraft.Kind.area)
                Text("Linha de aviso").tag(RuleDraft.Kind.line)
            } label: {
                FieldLabel(String(localized: "Tipo"), original: "alertArea / Cordão")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            if draft.kind == .area {
                HStack(spacing: 8) {
                    Text("Forma:").foregroundStyle(.secondary)
                    ForEach(shapes, id: \.sides) { shape in
                        Button { draft.applyShape(sides: shape.sides) } label: { Image(systemName: shape.icon) }
                            .help(shape.label)
                            .accessibilityLabel(shape.label)
                    }
                    Button("Imagem toda") { draft.coverWholeImage() }
                }
                Text("Alerta quando uma pessoa estiver dentro da área. Arraste os pontos brancos para ajustar.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker(selection: $draft.direction) {
                    Text("Nos dois sentidos").tag(2)
                    Text("Sentido 1").tag(0)
                    Text("Sentido 2").tag(1)
                } label: {
                    FieldLabel("Cruzamento", original: "AlarmDirect")
                }
                .frame(maxWidth: 420)
                Text("Alerta quando uma pessoa cruzar a linha. Arraste as pontas para ajustar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }

            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.rectangle ? String(localized: "Usar esta área") : String(localized: "Salvar na câmera")) {
                    Task {
                        state.saving = true
                        state.error = await onSave(draft)
                        state.saving = false
                        if state.error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.saving)
            }
        }
        .padding(Space.xl)
        .frame(width: 860)
        .onAppear {
            stream.displayLayer.videoGravity = .resize
            stream.start(camera: camera, quality: .sub, password: store.password(for: camera),
                         source: store.resolvedLiveSource(for: camera))
        }
        .onDisappear { stream.stop() }
    }

    /// Vídeo na proporção real, com a forma desenhada por cima nas mesmas coordenadas.
    private var canvas: some View {
        let size = stream.videoSize ?? CGSize(width: 16, height: 9)
        return ZStack {
            VideoLayerView(layer: stream.displayLayer)
                .accessibilityElement()
                .accessibilityLabel(draft.kind == .area ? String(localized: "Área de aviso com \(draft.area.count) pontos sobre a imagem")
                                                        : String(localized: "Linha de aviso sobre a imagem"))
            GeometryReader { proxy in
                let frame = proxy.size
                ZStack {
                    shapePath(in: frame)
                        .fill(Color.blue.opacity(draft.kind == .area ? 0.18 : 0))
                    shapePath(in: frame)
                        .stroke(Color.blue, lineWidth: 2.5)
                    ForEach(handles.indices, id: \.self) { index in
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(Color.blue, lineWidth: 2))
                            .frame(width: 14, height: 14)
                            // Teclado: Tab escolhe o ponto, setas movem 1% (5% com Shift).
                            .focusable()
                            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                                let step: CGFloat = press.modifiers.contains(.shift) ? 0.05 : 0.01
                                switch press.key {
                                case .leftArrow: nudge(index, dx: -step, dy: 0)
                                case .rightArrow: nudge(index, dx: step, dy: 0)
                                case .upArrow: nudge(index, dx: 0, dy: -step)
                                default: nudge(index, dx: 0, dy: step)
                                }
                                return .handled
                            }
                            .position(x: handles[index].x * frame.width, y: handles[index].y * frame.height)
                            .gesture(
                                DragGesture(coordinateSpace: .named("rule"))
                                    .onChanged { value in
                                        move(index, to: CGPoint(x: value.location.x / frame.width, y: value.location.y / frame.height))
                                    }
                            )
                            .accessibilityElement()
                            .accessibilityLabel(draft.kind == .area ? String(localized: "Ponto \(index + 1) de \(handles.count) da área")
                                                                    : (index == 0 ? String(localized: "Começo da linha") : String(localized: "Fim da linha")))
                            .accessibilityValue("\(Int((handles[index].x * 100).rounded()))% da esquerda, \(Int((handles[index].y * 100).rounded()))% do topo")
                            .accessibilityAction(named: "Mover para a esquerda") { nudge(index, dx: -0.05, dy: 0) }
                            .accessibilityAction(named: "Mover para a direita") { nudge(index, dx: 0.05, dy: 0) }
                            .accessibilityAction(named: "Mover para cima") { nudge(index, dx: 0, dy: -0.05) }
                            .accessibilityAction(named: "Mover para baixo") { nudge(index, dx: 0, dy: 0.05) }
                    }
                }
            }
            .coordinateSpace(name: "rule")
            if stream.videoSize == nil {
                ProgressView("Carregando imagem…").tint(.white).foregroundStyle(.white)
            }
        }
        .aspectRatio(size, contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Radius.small))
    }

    private var handles: [CGPoint] { draft.kind == .area ? draft.area : draft.line }

    private func shapePath(in frame: CGSize) -> Path {
        var path = Path()
        let points = handles.map { CGPoint(x: $0.x * frame.width, y: $0.y * frame.height) }
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        if draft.kind == .area { path.closeSubpath() }
        return path
    }

    private func nudge(_ index: Int, dx: CGFloat, dy: CGFloat) {
        let current = handles.indices.contains(index) ? handles[index] : .zero
        move(index, to: CGPoint(x: current.x + dx, y: current.y + dy))
    }

    private func move(_ index: Int, to point: CGPoint) {
        let clamped = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        if draft.kind == .area {
            guard draft.area.indices.contains(index) else { return }
            draft.area[index] = clamped
        } else {
            guard draft.line.indices.contains(index) else { return }
            draft.line[index] = clamped
        }
    }
}
