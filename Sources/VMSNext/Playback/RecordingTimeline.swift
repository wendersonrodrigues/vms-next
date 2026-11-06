import AppKit
import SwiftUI

extension Recording.Kind {
    /// Cor de cada tipo, na linha do tempo, na legenda e na lista.
    var color: Color {
        switch self {
        case .alarm: return .red
        case .motion: return .orange
        case .manual: return .purple
        case .regular: return .teal
        case .other: return .gray
        }
    }

    /// Ordem das faixas: o que mais interessa (alarme) em cima.
    static let timelineOrder: [Recording.Kind] = [.alarm, .motion, .manual, .regular, .other]
}

/// Posição do mouse sobre a linha do tempo (ObservableObject no lugar de @State, que precisa do Xcode).
final class TimelineHover: ObservableObject {
    @Published var x: CGFloat?
}

/// Parte do dia mostrada na linha do tempo (zoom). Compartilhada pelas linhas dos canais do NVR.
@MainActor
final class TimelineZoom: ObservableObject {
    static let day: TimeInterval = 86_400
    static let minimumSpan: TimeInterval = 10 * 60

    /// Início e duração da janela visível, em segundos desde a meia-noite.
    @Published private(set) var start: TimeInterval = 0
    @Published private(set) var span: TimeInterval = day

    var isZoomed: Bool { span < Self.day - 1 }
    var end: TimeInterval { start + span }

    /// Amplia (fator > 1) ou reduz mantendo parado o ponto `anchor` (0…1 da largura).
    func zoom(by factor: Double, anchor: Double = 0.5) {
        let newSpan = min(max(span / factor, Self.minimumSpan), Self.day)
        let pivot = start + span * anchor
        set(start: pivot - newSpan * anchor, span: newSpan)
    }

    func pan(by seconds: TimeInterval) { set(start: start + seconds, span: span) }

    func reset() { set(start: 0, span: Self.day) }

    /// Mantém o momento à vista (a agulha saiu da janela ampliada).
    func reveal(_ second: TimeInterval) {
        guard isZoomed, second < start || second > end else { return }
        set(start: second - span * 0.25, span: span)
    }

    private func set(start: TimeInterval, span: TimeInterval) {
        self.span = span
        self.start = min(max(start, 0), Self.day - span)
    }
}

/// Recebe a roda do mouse sobre a linha do tempo sem roubar cliques e o passar do mouse (só responde a rolagem).
struct TimelineScrollCatcher: NSViewRepresentable {
    let onScroll: (_ deltaX: CGFloat, _ deltaY: CGFloat, _ fractionX: CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, CGFloat) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let fraction = bounds.width > 0 ? min(max(point.x / bounds.width, 0), 1) : 0.5
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            onScroll?(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale, fraction)
        }
    }
}

/// − / + do zoom da linha do tempo e "dia inteiro".
struct TimelineZoomControls: View {
    @ObservedObject var zoom: TimelineZoom

    var body: some View {
        HStack(spacing: Space.xxs) {
            button("minus.magnifyingglass", help: String(localized: "Reduzir a linha do tempo")) { zoom.zoom(by: 0.5) }
                .disabled(!zoom.isZoomed)
            Text(Self.spanText(zoom.span))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
            button("plus.magnifyingglass", help: String(localized: "Ampliar a linha do tempo (ou role a roda do mouse em cima dela)")) { zoom.zoom(by: 2) }
                .disabled(zoom.span <= TimelineZoom.minimumSpan)
            button("arrow.left.and.right", help: String(localized: "Mostrar o dia inteiro")) { zoom.reset() }
                .disabled(!zoom.isZoomed)
        }
        .padding(Space.xxs)
        .background(RoundedRectangle(cornerRadius: Radius.small + 2).fill(Color.primary.opacity(0.05)))
    }

    static func spanText(_ span: TimeInterval) -> String {
        span >= 3600 ? String(format: "%.0f h", (span / 3600).rounded()) : String(format: "%.0f min", (span / 60).rounded())
    }

    private func button(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Linha do tempo do dia: régua de 0 h a 24 h e uma faixa por tipo de gravação (alarme, movimento, manual,
/// contínua). Passar o mouse mostra a hora; clicar toca a partir dali. Uma linha marca onde o vídeo está.
struct RecordingTimeline: View {
    let day: Date
    let recordings: [Recording]
    /// Momento do vídeo que está tocando (nil = nada tocando).
    let playhead: Date?
    /// Horário do alerta aberto pelo ▶: marca vermelha com sino.
    var alarm: Date? = nil
    /// Arquivos com tag: ganham uma marquinha em cima do trecho.
    var tagged: Set<String> = []
    /// Arquivos já baixados no Mac: tom mais claro da cor do tipo, com contorno.
    var downloaded: Set<String> = []
    /// Parte do dia à vista; nil = o dia inteiro, sem zoom.
    var zoom: TimelineZoom? = nil
    /// Uma faixa só com todos os tipos (linhas dos canais do NVR).
    var merged = false
    /// Régua das horas em cima (desligada nas linhas de baixo do NVR).
    var showsRuler = true
    /// Clique: o momento, o tipo da faixa clicada (nil fora das faixas) e quantos segundos valem ~8 px, para
    /// acertar trechos curtos (um movimento de poucos segundos) sem precisar de mira perfeita.
    let onSelect: (Date, Recording.Kind?, TimeInterval) -> Void

    @StateObject private var hover = TimelineHover()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rulerHeight: CGFloat { showsRuler ? 20 : 0 }
    private let laneHeight: CGFloat = 12
    private let laneGap: CGFloat = 6

    private var dayStart: Date { Calendar.current.startOfDay(for: day) }
    private var lanes: [Recording.Kind] {
        if merged { return [.other] }
        let present = Set(recordings.map(\.kind))
        let kinds = Recording.Kind.timelineOrder.filter { present.contains($0) }
        return kinds.isEmpty ? [.regular] : kinds
    }
    private var visibleStart: TimeInterval { zoom?.start ?? 0 }
    private var visibleSpan: TimeInterval { zoom?.span ?? TimelineZoom.day }

    private func x(for second: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat((second - visibleStart) / visibleSpan) * width
    }
    private var height: CGFloat { rulerHeight + CGFloat(lanes.count) * (laneHeight + laneGap) + laneGap }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                Canvas { context, size in draw(context, size: size) }
                if let alarm, Calendar.current.isDate(alarm, inSameDayAs: day),
                   case let x = x(for: alarm.timeIntervalSince(dayStart), width: width), x >= 0, x <= width {
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(Color.red.opacity(0.8))
                            .frame(width: 2, height: height - rulerHeight + 2)
                            .offset(y: rulerHeight - 2)
                        Image(systemName: "bell.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(Color.red))
                            .offset(y: rulerHeight - 12)
                    }
                    .frame(width: 16)
                    .offset(x: x - 8)
                    .allowsHitTesting(false)
                    .help(String(localized: "Alerta às \(alarm.formatted(date: .omitted, time: .standard))"))
                }
                if let x = playheadX(width: width) {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 2, height: height - rulerHeight + 4)
                        .offset(x: x - 1, y: rulerHeight - 4)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: x)
                        .allowsHitTesting(false)
                }
                if let x = hover.x {
                    hoverMarker(x: x, width: width)
                }
                if let zoom {
                    TimelineScrollCatcher { dx, dy, fraction in
                        if abs(dx) > abs(dy) {
                            zoom.pan(by: -Double(dx) / Double(max(width, 1)) * zoom.span)
                        } else if dy != 0 {
                            zoom.zoom(by: pow(1.01, Double(dy)), anchor: Double(fraction))
                        }
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): hover.x = min(max(point.x, 0), width)
                case .ended: hover.x = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                let lane = merged ? nil : laneIndex(at: value.location.y)
                onSelect(time(at: value.location.x, width: width), lane.map { lanes[$0] },
                         visibleSpan * 8 / Double(max(width, 1)))
            })
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Linha do tempo das gravações"))
        .accessibilityValue(summary)
    }

    // MARK: - Desenho

    private func draw(_ context: GraphicsContext, size: CGSize) {
        let width = size.width
        if showsRuler { drawRuler(context, width: width) }
        for (index, kind) in lanes.enumerated() {
            let y = laneY(index)
            // Fundo da faixa e os trechos gravados.
            context.fill(Path(roundedRect: CGRect(x: 0, y: y, width: width, height: laneHeight), cornerRadius: laneHeight / 2),
                         with: .color(Color.primary.opacity(0.06)))
            for recording in recordings where merged || recording.kind == kind {
                let start = max(recording.begin.timeIntervalSince(dayStart), 0)
                let end = min(recording.end.timeIntervalSince(dayStart), 86_400)
                guard end >= start, end >= visibleStart, start <= visibleStart + visibleSpan else { continue }
                let kind = recording.kind
                let x0 = x(for: start, width: width)
                // Fotos (início = fim) e trechos curtos ficam com pelo menos 3 px.
                let x1 = max(x(for: end, width: width), x0 + 3)
                let bar = Path(roundedRect: CGRect(x: x0, y: y, width: x1 - x0, height: laneHeight), cornerRadius: laneHeight / 2)
                if downloaded.contains(recording.fileName) {
                    context.fill(bar, with: .color(kind.color.opacity(0.4)))
                    context.stroke(bar, with: .color(kind.color), lineWidth: 1.5)
                } else {
                    context.fill(bar, with: .color(kind.color))
                }
                if tagged.contains(recording.fileName) {
                    // Marquinha de tag: um losango azul no meio do trecho, com borda para destacar da cor da faixa.
                    let mid = (x0 + x1) / 2
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: mid, y: y - 3))
                    diamond.addLine(to: CGPoint(x: mid + 5, y: y + laneHeight / 2))
                    diamond.addLine(to: CGPoint(x: mid, y: y + laneHeight + 3))
                    diamond.addLine(to: CGPoint(x: mid - 5, y: y + laneHeight / 2))
                    diamond.closeSubpath()
                    context.fill(diamond, with: .color(Theme.accent))
                    context.stroke(diamond, with: .color(.white), lineWidth: 1.5)
                }
            }
        }
    }

    /// Régua: o passo das marcas acompanha o zoom (de 2 h no dia inteiro até 1 min bem ampliado).
    private func drawRuler(_ context: GraphicsContext, width: CGFloat) {
        let steps: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 14400]
        // Números com pelo menos ~70 px entre eles; marcas menores a cada metade (ou quarto) do passo.
        let labelStep = steps.first { CGFloat($0 / visibleSpan) * width >= 70 } ?? 14400
        let tickStep = steps.last { $0 <= labelStep / 2 && CGFloat($0 / visibleSpan) * width >= 12 } ?? labelStep
        var second = (visibleStart / tickStep).rounded(.down) * tickStep
        while second <= visibleStart + visibleSpan + 0.5 {
            let x = x(for: second, width: width)
            let major = second.truncatingRemainder(dividingBy: labelStep) == 0
            if x >= -0.5, x <= width + 0.5 {
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: rulerHeight - (major ? 6 : 3)))
                tick.addLine(to: CGPoint(x: x, y: rulerHeight))
                context.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                if major {
                    let total = Int(second)
                    let label = Text(String(format: "%02d:%02d", total / 3600, (total % 3600) / 60)).font(.caption2).foregroundStyle(.secondary)
                    let anchor: UnitPoint = x < 20 ? .topLeading : (x > width - 20 ? .topTrailing : .top)
                    context.draw(label, at: CGPoint(x: x, y: 0), anchor: anchor)
                }
            }
            second += tickStep
        }
    }

    /// Onde o vídeo está: fora do Canvas para deslizar até o novo ponto num salto, em vez de pular.
    private func playheadX(width: CGFloat) -> CGFloat? {
        guard let playhead, Calendar.current.isDate(playhead, inSameDayAs: day) else { return nil }
        let x = x(for: playhead.timeIntervalSince(dayStart), width: width)
        return x >= 0 && x <= width ? x : nil
    }

    private func hoverMarker(x: CGFloat, width: CGFloat) -> some View {
        let label = time(at: x, width: width).formatted(date: .omitted, time: .standard)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.primary.opacity(0.5))
                .frame(width: 1, height: max(height - rulerHeight, 1))
                .offset(x: x, y: rulerHeight)
            Text(label)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs)
                .background(RoundedRectangle(cornerRadius: Radius.small).fill(Theme.surfaceHigh))
                .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(Theme.stroke))
                .fixedSize()
                .offset(x: min(max(x - 30, 0), max(width - 64, 0)), y: -2)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Conversões

    private func laneY(_ index: Int) -> CGFloat { rulerHeight + laneGap + CGFloat(index) * (laneHeight + laneGap) }

    private func laneIndex(at y: CGFloat) -> Int? {
        lanes.indices.first { y >= laneY($0) - laneGap / 2 && y <= laneY($0) + laneHeight + laneGap / 2 }
    }

    private func time(at x: CGFloat, width: CGFloat) -> Date {
        let fraction = width > 0 ? min(max(x / width, 0), 1) : 0
        return dayStart.addingTimeInterval(min(visibleStart + Double(fraction) * visibleSpan, 86_399))
    }

    /// Para o VoiceOver: quantos trechos de cada tipo.
    private var summary: String {
        let parts = (merged ? Recording.Kind.timelineOrder : lanes).compactMap { kind -> String? in
            let count = recordings.filter { $0.kind == kind }.count
            return count > 0 ? "\(kind.label): \(count)" : nil
        }
        return parts.isEmpty ? String(localized: "Nenhuma gravação neste dia.") : parts.joined(separator: ", ")
    }
}

/// Legenda das cores, só com os tipos que aparecem no dia.
struct RecordingLegend: View {
    let recordings: [Recording]

    var body: some View {
        let present = Set(recordings.map(\.kind))
        HStack(spacing: Space.m) {
            ForEach(Recording.Kind.timelineOrder.filter { present.contains($0) }, id: \.self) { kind in
                HStack(spacing: Space.xs) {
                    Circle().fill(kind.color).frame(width: 8, height: 8)
                    Text(kind.label)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Pular para o trecho anterior ou seguinte de um tipo: ‹ ● Contínua › (como o controle de Foco do PTZ).
struct RecordingKindStepper: View {
    let kind: Recording.Kind
    let canGoBack: Bool
    let canGoForward: Bool
    let onStep: (_ forward: Bool) -> Void

    var body: some View {
        HStack(spacing: Space.xxs) {
            arrow("chevron.left", forward: false, enabled: canGoBack,
                  help: String(localized: "\(kind.label): trecho anterior"))
            HStack(spacing: Space.xs) {
                Circle().fill(kind.color).frame(width: 8, height: 8)
                Text(kind.label).foregroundStyle(kind.color)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Space.xxs)
            arrow("chevron.right", forward: true, enabled: canGoForward,
                  help: String(localized: "\(kind.label): próximo trecho"))
        }
        .padding(Space.xxs)
        .background(RoundedRectangle(cornerRadius: Radius.small + 2).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
    }

    private func arrow(_ icon: String, forward: Bool, enabled: Bool, help: String) -> some View {
        Button { onStep(forward) } label: {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: Radius.small).fill(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}
