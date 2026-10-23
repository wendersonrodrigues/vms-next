import SwiftUI

/// "Config. de gravação": Record.[canal] com modo, duração dos arquivos, pré-gravação e agenda semanal.
/// No equipamento, cada dia tem 6 períodos ("1 00:00:00-10:30:00" = ativo + intervalo) e uma máscara por período
/// (bit 0 normal, bit 1 detecção, bit 2 alarme). Na tela, a agenda é um quadro de 48 blocos de meia hora por dia,
/// como no VMS antigo; ao aplicar, blocos vizinhos iguais viram um período.
@MainActor
final class RecordingConfigModel: ObservableObject {
    static let slotsPerDay = 48
    static let minutesPerSlot = 30
    static let modes: [(value: String, label: String)] = [
        ("ConfigRecord", "Por agenda"),
        ("ManualRecord", "Sempre gravando"),
        ("ClosedRecord", "Desligado"),
    ]
    static let dayNames = ["Domingo", "Segunda", "Terça", "Quarta", "Quinta", "Sexta", "Sábado"]

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var loaded = false
    @Published var diagnosticText: String?

    @Published var mode = "ConfigRecord"
    @Published var packetMinutes = 60
    @Published var preRecordSeconds = 5
    @Published private(set) var hasRedundancy = false
    @Published var redundancy = false
    /// slots[dia][bloco] = máscara (1 normal, 2 detecção, 4 alarme)
    @Published var slots: [[Int]] = Array(repeating: Array(repeating: 0, count: 48), count: 7)

    let camera: Camera
    private var raw: Any?
    private var sectionsPerDay = 6
    private var name: String { "Record.[\(camera.channel - 1)]" }

    init(camera: Camera) {
        self.camera = camera
    }

    var modeOptions: [(value: String, label: String)] {
        var options = Self.modes
        if !options.contains(where: { $0.value == mode }) { options.append((mode, "Modo do equipamento (\(mode))")) }
        return options
    }

    /// Cada dia precisa caber nos períodos que o equipamento aceita.
    var validationError: String? {
        guard mode == "ConfigRecord" else { return nil }
        for day in 0 ..< 7 where Self.runs(slots[day]).count > sectionsPerDay {
            return "\(Self.dayNames[day]) tem mais de \(sectionsPerDay) trechos diferentes; o equipamento aceita no máximo \(sectionsPerDay) por dia."
        }
        return nil
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            raw = try await client.getConfig(name)
            guard let record = ConfigValue.object(in: raw) else {
                error = "Este equipamento não informou a configuração de gravação do canal \(camera.channel)."
                return
            }
            mode = record["RecordMode"] as? String ?? "ConfigRecord"
            packetMinutes = ConfigValue.int(record["PacketLength"]) ?? 60
            preRecordSeconds = ConfigValue.int(record["PreRecord"]) ?? 5
            if let value = record["Redundancy"] as? Bool {
                hasRedundancy = true
                redundancy = value
            }
            let sections = record["TimeSection"] as? [[String]] ?? []
            let masks = record["Mask"] as? [[Any]] ?? []
            sectionsPerDay = sections.first?.count ?? 6
            slots = (0 ..< 7).map { day in
                var row = Array(repeating: 0, count: Self.slotsPerDay)
                guard day < sections.count else { return row }
                for (index, section) in sections[day].enumerated() {
                    let mask = day < masks.count && index < masks[day].count ? ConfigValue.int(masks[day][index]) ?? 0 : 0
                    guard mask != 0, let range = Self.parse(section) else { continue }
                    for slot in range { row[slot] |= mask & 7 }
                }
                return row
            }
            loaded = true
        } catch DVRIPError.device(let code) where code == 607 {
            error = "Este equipamento não tem configuração de gravação para o canal \(camera.channel)."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply() async {
        if let validationError {
            error = validationError
            return
        }
        guard let raw, var record = ConfigValue.object(in: raw) else { return }
        saving = true
        error = nil
        notice = nil
        defer { saving = false }

        record["RecordMode"] = mode
        ConfigValue.set(&record, "PacketLength", packetMinutes)
        ConfigValue.set(&record, "PreRecord", preRecordSeconds)
        if hasRedundancy { record["Redundancy"] = redundancy }

        var sections = record["TimeSection"] as? [[String]] ?? []
        var masks = record["Mask"] as? [[Any]] ?? []
        let hexMasks = masks.first?.first is String
        for day in 0 ..< min(7, sections.count, masks.count) {
            let runs = Self.runs(slots[day])
            for index in sections[day].indices {
                if index < runs.count {
                    let run = runs[index]
                    sections[day][index] = "1 \(Self.time(run.start)):00-\(Self.time(run.end)):00"
                    if index < masks[day].count { masks[day][index] = hexMasks ? String(format: "0x%08X", run.mask) : run.mask }
                } else {
                    sections[day][index] = "0 00:00:00-24:00:00"
                    if index < masks[day].count { masks[day][index] = hexMasks ? "0x00000000" : 0 }
                }
            }
        }
        record["TimeSection"] = sections
        record["Mask"] = masks

        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let updated = ConfigValue.replacingObject(in: raw, with: record)
            try await client.setConfig(name, updated)
            self.raw = updated
            let check = ConfigValue.object(in: try await client.getConfig(name))
            if let applied = check?["RecordMode"] as? String, applied != mode {
                error = "O equipamento aceitou o comando mas manteve o modo \(applied)."
                return
            }
            notice = "Configuração de gravação aplicada."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func copyToAllDays(from day: Int) {
        slots = Array(repeating: slots[day], count: 7)
    }

    func fill(day: Int, mask: Int) {
        slots[day] = Array(repeating: mask, count: Self.slotsPerDay)
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: [(1042, name)])
    }

    // MARK: - Conversões

    /// Trechos contínuos com a mesma máscara (máscara 0 = sem gravação, não vira período).
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

    /// "1 08:00:00-18:30:00" → blocos 16..<37 (horários arredondados para a meia hora mais próxima).
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

struct RecordingConfigView: View {
    @StateObject private var model: RecordingConfigModel

    init(camera: Camera) {
        _model = StateObject(wrappedValue: RecordingConfigModel(camera: camera))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if model.loaded {
                        Section("Gravação") {
                            Picker("Modo", selection: $model.mode) {
                                ForEach(model.modeOptions, id: \.value) { Text($0.label).tag($0.value) }
                            }
                            .pickerStyle(.segmented)
                            Stepper("Tamanho de cada arquivo: \(model.packetMinutes) min", value: $model.packetMinutes, in: 1 ... 120)
                            Stepper("Pré-gravação: \(model.preRecordSeconds) s", value: $model.preRecordSeconds, in: 0 ... 30)
                            if model.hasRedundancy {
                                Toggle("Redundância", isOn: $model.redundancy)
                            }
                        }
                        if model.mode == "ConfigRecord" {
                            Section {
                                WeekPlanGrid(slots: $model.slots, model: model)
                            } header: {
                                HStack {
                                    Text("Agenda semanal")
                                    Spacer()
                                    WeekPlanLegend()
                                }
                            } footer: {
                                Text("Clique e arraste nas faixas para marcar ou desmarcar meia hora. Botão direito no nome do dia para copiar, preencher ou limpar.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let message = model.error ?? model.validationError {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Diagnóstico…") { Task { model.diagnosticText = await model.diagnostic() } }
                    .disabled(model.loading || model.saving)
                Button("Recarregar") { Task { await model.load() } }
                    .disabled(model.loading || model.saving)
                Button("Aplicar") { Task { await model.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.loaded || model.loading || model.saving || model.validationError != nil)
            }
            .padding(12)
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }
}

// MARK: - Quadro semanal

/// Faixas do quadro, na ordem do VMS antigo.
private enum PlanRow: Int, CaseIterable {
    case normal, detection, alarm

    var bit: Int { 1 << rawValue }
    var label: String {
        switch self {
        case .normal: return "Normal"
        case .detection: return "Detecção"
        case .alarm: return "Alarme"
        }
    }
    var color: Color {
        switch self {
        case .normal: return Color(red: 0.05, green: 0.73, blue: 0.27)
        case .detection: return Color(red: 0.88, green: 0.95, blue: 0.35)
        case .alarm: return Color(red: 0.95, green: 0.12, blue: 0.12)
        }
    }
}

private struct WeekPlanLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(PlanRow.allCases, id: \.rawValue) { row in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(row.color).frame(width: 12, height: 12)
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
    var row: PlanRow?
}

private struct WeekPlanGrid: View {
    @Binding var slots: [[Int]]
    @ObservedObject var model: RecordingConfigModel
    @StateObject private var paint = PaintState()

    private let labelWidth: CGFloat = 76
    private let rulerHeight: CGFloat = 22
    private let rowHeight: CGFloat = 13
    private let rowGap: CGFloat = 2
    private let dayGap: CGFloat = 12
    private var dayHeight: CGFloat { CGFloat(PlanRow.allCases.count) * (rowHeight + rowGap) - rowGap + dayGap }
    private var totalHeight: CGFloat { rulerHeight + 7 * dayHeight }

    var body: some View {
        GeometryReader { proxy in
            let cell = (proxy.size.width - labelWidth) / CGFloat(RecordingConfigModel.slotsPerDay)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(context, cell: cell) }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { paintAt($0.location, cell: cell) }
                            .onEnded { _ in paint.value = nil; paint.row = nil }
                    )
                // Nomes dos dias, com menu de contexto.
                ForEach(0 ..< 7, id: \.self) { day in
                    Text(RecordingConfigModel.dayNames[day])
                        .font(.callout)
                        .frame(width: labelWidth - 8, height: dayHeight - dayGap, alignment: .leading)
                        .contentShape(Rectangle())
                        .offset(y: rulerHeight + CGFloat(day) * dayHeight)
                        .contextMenu { dayMenu(day) }
                }
            }
        }
        .frame(height: totalHeight)
    }

    @ViewBuilder
    private func dayMenu(_ day: Int) -> some View {
        Button("Copiar \(RecordingConfigModel.dayNames[day]) para todos os dias") { model.copyToAllDays(from: day) }
        Divider()
        Button("Dia inteiro: normal + detecção + alarme") { model.fill(day: day, mask: 7) }
        Button("Dia inteiro: só detecção + alarme") { model.fill(day: day, mask: 6) }
        Button("Limpar o dia") { model.fill(day: day, mask: 0) }
    }

    private func draw(_ context: GraphicsContext, cell: CGFloat) {
        // Régua de horas.
        for hour in 0 ... 24 {
            let x = labelWidth + CGFloat(hour * 2) * cell
            context.draw(Text("\(hour)").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: x, y: 7))
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: rulerHeight - 7))
            tick.addLine(to: CGPoint(x: x, y: rulerHeight - 2))
            context.stroke(tick, with: .color(.secondary), lineWidth: 1)
        }
        // Blocos.
        let off = Color.gray.opacity(0.35)
        for day in 0 ..< 7 {
            for row in PlanRow.allCases {
                let y = rulerHeight + CGFloat(day) * dayHeight + CGFloat(row.rawValue) * (rowHeight + rowGap)
                for slot in 0 ..< RecordingConfigModel.slotsPerDay {
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
        guard (0 ..< RecordingConfigModel.slotsPerDay).contains(slot), (0 ..< 7).contains(day),
              let row = PlanRow(rawValue: rowIndex) else { return }
        // O arraste fica na faixa (normal/detecção/alarme) em que começou.
        if paint.row == nil { paint.row = row }
        guard row == paint.row else { return }
        let isOn = slots[day][slot] & row.bit != 0
        if paint.value == nil { paint.value = !isOn }
        guard let value = paint.value, value != isOn else { return }
        slots[day][slot] ^= row.bit
    }
}
