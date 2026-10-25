import SwiftUI

/// Agendas semanais da Xiongmai: 7 dias × N períodos ("1 00:00:00-10:30:00" = ativo + intervalo),
/// opcionalmente com uma máscara por período. Na tela, cada dia vira 48 blocos de meia hora.
enum ScheduleCodec {
    static let slotsPerDay = 48
    static let minutesPerSlot = 30
    static let dayNames = [String(localized: "Domingo"), String(localized: "Segunda"), String(localized: "Terça"), String(localized: "Quarta"), String(localized: "Quinta"), String(localized: "Sexta"), String(localized: "Sábado")]

    static func emptyWeek() -> [[Int]] {
        Array(repeating: Array(repeating: 0, count: slotsPerDay), count: 7)
    }

    /// Sem `masks`, todo período ativo vale 1 (agenda de uma faixa, como o período de alarme).
    static func decode(sections: [[String]], masks: [[Any]]?) -> [[Int]] {
        (0 ..< 7).map { day in
            var row = Array(repeating: 0, count: slotsPerDay)
            guard day < sections.count else { return row }
            for (index, section) in sections[day].enumerated() {
                let mask: Int
                if let masks {
                    mask = day < masks.count && index < masks[day].count ? ConfigValue.int(masks[day][index]) ?? 0 : 0
                } else {
                    mask = 1
                }
                guard mask != 0, let range = parse(section) else { continue }
                for slot in range { row[slot] |= mask & 7 }
            }
            return row
        }
    }

    /// Grava os blocos de volta nos períodos existentes (mesmo tamanho e mesmo tipo de máscara).
    static func encode(_ slots: [[Int]], sections: inout [[String]], masks: inout [[Any]]?) {
        let hexMasks = masks?.first?.first is String
        for day in 0 ..< min(7, sections.count) {
            let dayRuns = runs(slots[day])
            for index in sections[day].indices {
                let run = index < dayRuns.count ? dayRuns[index] : nil
                sections[day][index] = run.map { "1 \(time($0.start)):00-\(time($0.end)):00" } ?? "0 00:00:00-24:00:00"
                if var dayMasks = masks?[day], index < dayMasks.count {
                    let value = run?.mask ?? 0
                    dayMasks[index] = hexMasks ? String(format: "0x%08X", value) : value
                    masks?[day] = dayMasks
                }
            }
        }
    }

    /// Mensagem de erro se algum dia tiver mais trechos do que o equipamento aceita.
    static func validate(_ slots: [[Int]], maxSections: Int) -> String? {
        for day in 0 ..< 7 where runs(slots[day]).count > maxSections {
            return String(localized: "\(dayNames[day]) tem mais de \(maxSections) trechos diferentes; o equipamento aceita no máximo \(maxSections) por dia.")
        }
        return nil
    }

    /// Trechos contínuos com a mesma máscara (máscara 0 não vira período).
    static func runs(_ row: [Int]) -> [(start: Int, end: Int, mask: Int)] {
        var result: [(Int, Int, Int)] = []
        var i = 0
        while i < row.count {
            let mask = row[i]
            var j = i
            while j < row.count, row[j] == mask { j += 1 }
            if mask != 0 { result.append((i, j, mask)) }
            i = j
        }
        return result
    }

    /// "1 08:00:00-18:30:00" → blocos 16..<37 (arredondado para a meia hora mais próxima).
    private static func parse(_ section: String) -> Range<Int>? {
        let parts = section.split(separator: " ", maxSplits: 1)
        guard parts.first == "1", parts.count > 1 else { return nil }
        let range = parts[1].split(separator: "-")
        guard range.count == 2, let start = slot(String(range[0])), let end = slot(String(range[1])), start < end else { return nil }
        return start ..< end
    }

    private static func slot(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let minutes = parts[0] * 60 + parts[1]
        return min(slotsPerDay, Int((Double(minutes) / Double(minutesPerSlot)).rounded()))
    }

    private static func time(_ slot: Int) -> String {
        let minutes = slot * minutesPerSlot
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

/// Uma faixa do quadro (um bit da máscara).
struct ScheduleRow {
    let bit: Int
    let label: String
    let color: Color

    static let green = Color(red: 0.05, green: 0.73, blue: 0.27)

    /// Gravação e foto: normal, detecção e alarme, nas cores do VMS antigo.
    static let recording = [
        ScheduleRow(bit: 1, label: "Normal", color: green),
        ScheduleRow(bit: 2, label: String(localized: "Detecção"), color: Color(red: 0.88, green: 0.95, blue: 0.35)),
        ScheduleRow(bit: 4, label: String(localized: "Alarme"), color: Color(red: 0.95, green: 0.12, blue: 0.12)),
    ]

    /// Período de alarme: uma faixa só.
    static let period = [ScheduleRow(bit: 1, label: String(localized: "Ativo"), color: green)]
}

struct ScheduleLegend: View {
    let rows: [ScheduleRow]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(rows, id: \.bit) { row in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: Radius.small).fill(row.color).frame(width: 12, height: 12)
                    Text(row.label)
                }
            }
        }
        .font(.caption)
        .textCase(nil)
    }
}

/// Valor que está sendo "pintado" durante um arraste (marcar ou desmarcar), decidido no primeiro bloco tocado.
private final class PaintState: ObservableObject {
    var value: Bool?
    var row: Int?
}

/// Quadro semanal pintável: clique e arraste marca ou desmarca blocos de meia hora em uma faixa.
struct ScheduleGrid: View {
    @Binding var slots: [[Int]]
    let rows: [ScheduleRow]
    /// Atalhos do menu do dia: (rótulo, máscara para o dia inteiro).
    var presets: [(label: String, mask: Int)] = []

    @StateObject private var paint = PaintState()

    private let labelWidth: CGFloat = 76
    private let rulerHeight: CGFloat = 22
    private let rowHeight: CGFloat = 13
    private let rowGap: CGFloat = 2
    private var dayGap: CGFloat { rows.count > 1 ? 12 : 8 }
    private var dayHeight: CGFloat { CGFloat(rows.count) * (rowHeight + rowGap) - rowGap + dayGap }
    private var totalHeight: CGFloat { rulerHeight + 7 * dayHeight }

    var body: some View {
        GeometryReader { proxy in
            let cell = (proxy.size.width - labelWidth) / CGFloat(ScheduleCodec.slotsPerDay)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(context, cell: cell) }
                    .contentShape(Rectangle())
                    // O desenho é só para o mouse; o VoiceOver e o teclado usam o menu de cada dia.
                    .accessibilityHidden(true)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { paintAt($0.location, cell: cell) }
                            .onEnded { _ in paint.value = nil; paint.row = nil }
                    )
                ForEach(0 ..< 7, id: \.self) { day in
                    // Nome do dia = menu com as mesmas opções do botão direito (dá para usar com Tab e VoiceOver).
                    Menu {
                        dayMenu(day)
                    } label: {
                        Text(ScheduleCodec.dayNames[day]).font(.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: labelWidth - 8, height: dayHeight - dayGap, alignment: .leading)
                    .contentShape(Rectangle())
                    .offset(y: rulerHeight + CGFloat(day) * dayHeight)
                    .contextMenu { dayMenu(day) }
                    .help("Opções de \(ScheduleCodec.dayNames[day]): copiar para os outros dias, dia inteiro, limpar")
                    .accessibilityLabel(ScheduleCodec.dayNames[day])
                    .accessibilityValue(summary(day))
                }
            }
        }
        .frame(height: totalHeight)
    }

    @ViewBuilder
    private func dayMenu(_ day: Int) -> some View {
        Button("Copiar \(ScheduleCodec.dayNames[day]) para todos os dias") {
            slots = Array(repeating: slots[day], count: 7)
        }
        Divider()
        ForEach(presets, id: \.label) { preset in
            Button(preset.label) { fill(day, preset.mask) }
        }
        Button("Dia inteiro") { fill(day, rows.reduce(0) { $0 | $1.bit }) }
        Button("Limpar o dia") { fill(day, 0) }
    }

    /// Resumo falado do dia: "Normal 08:00–18:00; Alarme dia inteiro" ou "nada marcado".
    private func summary(_ day: Int) -> String {
        let parts: [String] = rows.compactMap { row in
            let marked = slots[day].map { $0 & row.bit != 0 ? 1 : 0 }
            let ranges = ScheduleCodec.runs(marked)
            guard !ranges.isEmpty else { return nil }
            if ranges.count == 1, ranges[0].start == 0, ranges[0].end == ScheduleCodec.slotsPerDay {
                return rows.count > 1 ? String(localized: "\(row.label) dia inteiro") : String(localized: "dia inteiro")
            }
            let text = ranges.map { "\(Self.clock($0.start))–\(Self.clock($0.end))" }.joined(separator: ", ")
            return rows.count > 1 ? "\(row.label) \(text)" : text
        }
        return parts.isEmpty ? String(localized: "nada marcado") : parts.joined(separator: "; ")
    }

    private static func clock(_ slot: Int) -> String {
        let minutes = slot * ScheduleCodec.minutesPerSlot
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func fill(_ day: Int, _ mask: Int) {
        slots[day] = Array(repeating: mask, count: ScheduleCodec.slotsPerDay)
    }

    private func draw(_ context: GraphicsContext, cell: CGFloat) {
        for hour in 0 ... 24 {
            let x = labelWidth + CGFloat(hour * 2) * cell
            context.draw(Text("\(hour)").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: x, y: 7))
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: rulerHeight - 7))
            tick.addLine(to: CGPoint(x: x, y: rulerHeight - 2))
            context.stroke(tick, with: .color(.secondary), lineWidth: 1)
        }
        let off = Color.gray.opacity(0.35)
        for day in 0 ..< 7 {
            for (rowIndex, row) in rows.enumerated() {
                let y = rulerHeight + CGFloat(day) * dayHeight + CGFloat(rowIndex) * (rowHeight + rowGap)
                for slot in 0 ..< ScheduleCodec.slotsPerDay {
                    let rect = CGRect(x: labelWidth + CGFloat(slot) * cell, y: y, width: max(cell - 1, 1), height: rowHeight)
                    let on = slots[day][slot] & row.bit != 0
                    context.fill(Path(rect), with: .color(on ? row.color : off))
                }
            }
        }
    }

    private func paintAt(_ point: CGPoint, cell: CGFloat) {
        guard point.x >= labelWidth, point.y >= rulerHeight, cell > 0 else { return }
        let slot = Int((point.x - labelWidth) / cell)
        let day = Int((point.y - rulerHeight) / dayHeight)
        let inner = point.y - rulerHeight - CGFloat(day) * dayHeight
        let rowIndex = Int(inner / (rowHeight + rowGap))
        guard (0 ..< ScheduleCodec.slotsPerDay).contains(slot), (0 ..< 7).contains(day), rows.indices.contains(rowIndex) else { return }
        // O arraste fica na faixa em que começou.
        if paint.row == nil { paint.row = rowIndex }
        guard rowIndex == paint.row else { return }
        let bit = rows[rowIndex].bit
        let isOn = slots[day][slot] & bit != 0
        if paint.value == nil { paint.value = !isOn }
        guard let value = paint.value, value != isOn else { return }
        slots[day][slot] ^= bit
    }
}
