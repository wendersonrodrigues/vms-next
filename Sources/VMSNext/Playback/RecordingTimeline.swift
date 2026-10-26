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

/// Linha do tempo do dia: régua de 0 h a 24 h e uma faixa por tipo de gravação (alarme, movimento, manual,
/// contínua). Passar o mouse mostra a hora; clicar toca a partir dali. Uma linha marca onde o vídeo está.
struct RecordingTimeline: View {
    let day: Date
    let recordings: [Recording]
    /// Momento do vídeo que está tocando (nil = nada tocando).
    let playhead: Date?
    /// Arquivos com tag: ganham uma marquinha em cima do trecho.
    var tagged: Set<String> = []
    /// Arquivos já baixados no Mac: tom mais claro da cor do tipo, com contorno.
    var downloaded: Set<String> = []
    /// Clique: o momento escolhido e, se o clique foi numa faixa, o tipo dela.
    let onSelect: (Date, Recording.Kind?) -> Void

    @StateObject private var hover = TimelineHover()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rulerHeight: CGFloat = 20
    private let laneHeight: CGFloat = 12
    private let laneGap: CGFloat = 6

    private var dayStart: Date { Calendar.current.startOfDay(for: day) }
    private var lanes: [Recording.Kind] {
        let present = Set(recordings.map(\.kind))
        let kinds = Recording.Kind.timelineOrder.filter { present.contains($0) }
        return kinds.isEmpty ? [.regular] : kinds
    }
    private var height: CGFloat { rulerHeight + CGFloat(lanes.count) * (laneHeight + laneGap) + laneGap }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                Canvas { context, size in draw(context, size: size) }
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
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): hover.x = min(max(point.x, 0), width)
                case .ended: hover.x = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                let lane = laneIndex(at: value.location.y)
                onSelect(time(at: value.location.x, width: width), lane.map { lanes[$0] })
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
        // Régua: marca a cada hora, número a cada 2 h (a cada 4 h se estiver estreito).
        let labelStep = width < 520 ? 4 : 2
        for hour in 0 ... 24 {
            let x = CGFloat(hour) / 24 * width
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: rulerHeight - (hour % labelStep == 0 ? 6 : 3)))
            tick.addLine(to: CGPoint(x: x, y: rulerHeight))
            context.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            if hour % labelStep == 0 {
                let label = Text(String(format: "%02d:00", hour)).font(.caption2).foregroundStyle(.secondary)
                let anchor: UnitPoint = hour == 0 ? .topLeading : (hour == 24 ? .topTrailing : .top)
                context.draw(label, at: CGPoint(x: x, y: 0), anchor: anchor)
            }
        }
        for (index, kind) in lanes.enumerated() {
            let y = laneY(index)
            // Fundo da faixa e os trechos gravados.
            context.fill(Path(roundedRect: CGRect(x: 0, y: y, width: width, height: laneHeight), cornerRadius: laneHeight / 2),
                         with: .color(Color.primary.opacity(0.06)))
            for recording in recordings where recording.kind == kind {
                let start = max(recording.begin.timeIntervalSince(dayStart), 0)
                let end = min(recording.end.timeIntervalSince(dayStart), 86_400)
                guard end > start else { continue }
                let x0 = CGFloat(start / 86_400) * width
                let x1 = max(CGFloat(end / 86_400) * width, x0 + 2)
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

    /// Onde o vídeo está: fora do Canvas para deslizar até o novo ponto num salto, em vez de pular.
    private func playheadX(width: CGFloat) -> CGFloat? {
        guard let playhead, Calendar.current.isDate(playhead, inSameDayAs: day) else { return nil }
        return CGFloat(playhead.timeIntervalSince(dayStart) / 86_400) * width
    }

    private func hoverMarker(x: CGFloat, width: CGFloat) -> some View {
        let label = time(at: x, width: width).formatted(date: .omitted, time: .standard)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.primary.opacity(0.5))
                .frame(width: 1, height: height - rulerHeight)
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
        return dayStart.addingTimeInterval(Double(fraction) * 86_399)
    }

    /// Para o VoiceOver: quantos trechos de cada tipo.
    private var summary: String {
        let parts = lanes.compactMap { kind -> String? in
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
