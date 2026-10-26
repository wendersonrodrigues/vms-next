import AppKit
import SwiftUI

/// Gravações já baixadas neste Mac (câmera, arquivo, dia/horário e onde o MP4 ficou), em
/// ~/Library/Application Support/VMSNext/downloaded-recordings.json. Só contam as que o arquivo ainda existe.
@MainActor
final class DownloadedRecordings: ObservableObject {
    struct Item: Codable, Hashable {
        let cameraID: Camera.ID
        let fileName: String
        let begin: Date
        let end: Date
        let path: String
    }

    static let shared = DownloadedRecordings()

    @Published private(set) var items: [String: Item] = [:]

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VMSNext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloaded-recordings.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Item].self, from: data)
        {
            // Esquece os arquivos que foram apagados ou movidos.
            let existing = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
            items = Dictionary(existing.map { (RecordingTags.key($0.cameraID, $0.begin), $0) }, uniquingKeysWith: { _, last in last })
            if existing.count != saved.count { save() }
        }
    }

    func mark(_ recording: Recording, camera: Camera, url: URL) {
        items[RecordingTags.key(camera.id, recording.begin)] = Item(cameraID: camera.id, fileName: recording.fileName,
                                                                      begin: recording.begin, end: recording.end, path: url.path)
        save()
    }

    /// Arquivo baixado desta gravação, se ainda existir no Mac.
    func file(of recording: Recording, camera: Camera) -> URL? {
        guard let item = items[RecordingTags.key(camera.id, recording.begin)],
              FileManager.default.fileExists(atPath: item.path) else { return nil }
        return URL(fileURLWithPath: item.path)
    }

    /// Nomes dos arquivos do dia que já estão no Mac (para o tom mais claro na linha do tempo).
    func downloadedFiles(in recordings: [Recording], camera: Camera) -> Set<String> {
        Set(recordings.filter { file(of: $0, camera: camera) != nil }.map(\.fileName))
    }

    /// Dias do mês (1…31) com algum vídeo desta câmera baixado.
    func days(camera: Camera, month: Date) -> Set<Int> {
        let calendar = Calendar.current
        return Set(items.values.filter { $0.cameraID == camera.id && calendar.isDate($0.begin, equalTo: month, toGranularity: .month) }
            .map { calendar.component(.day, from: $0.begin) })
    }

    private func save() {
        let data = try? JSONEncoder().encode(Array(items.values).sorted { $0.begin < $1.begin })
        try? data?.write(to: fileURL, options: .atomic)
    }
}

extension DVRIPClient {
    /// Dias do mês com gravação (OPSCalendar, como o H264_DVR_SearchCalendar do VMS antigo): o equipamento
    /// devolve uma máscara com um bit por dia (bit 0 = dia 1). Vale para o equipamento todo, não por canal.
    func recordingDays(year: Int, month: Int) async throws -> Set<Int> {
        let response = try await command(code: 1446, name: "OPSCalendar", payload: [
            "Year": year, "Month": month, "FileType": "h264", "Event": "*", "Rev": "",
        ])
        let body = response["OPSCalendar"] as? [String: Any] ?? response
        let mask: Int
        if let number = body["Mask"] as? Int {
            mask = number
        } else if let text = body["Mask"] as? String {
            mask = Int(text.replacingOccurrences(of: "0x", with: ""), radix: text.hasPrefix("0x") ? 16 : 10) ?? 0
        } else {
            mask = 0
        }
        return Set((1 ... 31).filter { mask & (1 << ($0 - 1)) != 0 })
    }
}

/// Mês mostrado no calendário e os dias com gravação de cada mês já consultado.
@MainActor
final class RecordingCalendarState: ObservableObject {
    @Published var month: Date
    @Published private(set) var recordedDays: [String: Set<Int>] = [:]
    @Published private(set) var loading = false

    init(day: Date) { month = day }

    static func key(_ month: Date, camera: Camera) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: month)
        return "\(camera.id.uuidString)-\(parts.year ?? 0)-\(parts.month ?? 0)"
    }

    func load(camera: Camera) async {
        let key = Self.key(month, camera: camera)
        guard recordedDays[key] == nil else { return }
        loading = true
        defer { loading = false }
        let parts = Calendar.current.dateComponents([.year, .month], from: month)
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            recordedDays[key] = try await client.recordingDays(year: parts.year ?? 0, month: parts.month ?? 0)
        } catch {
            // Equipamento sem a consulta: o calendário funciona, só sem as marcas.
            recordedDays[key] = []
        }
    }
}

/// Calendário do mês: dias com gravação em azul claro, dias com vídeo baixado com um tom verde,
/// o dia escolhido em azul cheio. Dias futuros ficam apagados.
struct RecordingCalendar: View {
    let camera: Camera
    let selected: Date
    let onSelect: (Date) -> Void

    @StateObject private var state: RecordingCalendarState
    @ObservedObject private var downloaded = DownloadedRecordings.shared

    init(camera: Camera, selected: Date, onSelect: @escaping (Date) -> Void) {
        self.camera = camera
        self.selected = selected
        self.onSelect = onSelect
        _state = StateObject(wrappedValue: RecordingCalendarState(day: selected))
    }

    private let calendar = Calendar.current
    private let cell: CGFloat = 32

    var body: some View {
        VStack(spacing: Space.s) {
            header
            weekdays
            grid
            Divider()
            legend
        }
        .padding(Space.m)
        .frame(width: cell * 7 + Space.m * 2 + 6 * 2)
        .task(id: RecordingCalendarState.key(state.month, camera: camera)) { await state.load(camera: camera) }
    }

    private var header: some View {
        HStack {
            Text(state.month.formatted(.dateTime.month(.wide).year())).font(.headline)
            if state.loading { ProgressView().controlSize(.mini) }
            Spacer()
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Mês anterior")
                .accessibilityLabel("Mês anterior")
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(calendar.isDate(state.month, equalTo: Date(), toGranularity: .month))
                .help("Próximo mês")
                .accessibilityLabel("Próximo mês")
        }
    }

    private var weekdays: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return HStack(spacing: 2) {
            ForEach(0 ..< 7, id: \.self) { index in
                Text(symbols[(index + first) % 7])
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: cell)
            }
        }
    }

    private var grid: some View {
        let days = monthDays
        return VStack(spacing: 2) {
            ForEach(0 ..< days.count / 7, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0 ..< 7, id: \.self) { column in
                        if let date = days[row * 7 + column] { dayCell(date) } else { Color.clear.frame(width: cell, height: cell) }
                    }
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let day = calendar.component(.day, from: date)
        let recorded = state.recordedDays[RecordingCalendarState.key(state.month, camera: camera)]?.contains(day) ?? false
        let saved = downloaded.days(camera: camera, month: state.month).contains(day)
        let isSelected = calendar.isDate(date, inSameDayAs: selected)
        let future = date > Date()
        let isToday = calendar.isDateInToday(date)
        return Button {
            onSelect(date)
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: Radius.small)
                    .fill(isSelected ? Theme.accent
                          : saved ? Theme.success.opacity(0.28)
                          : recorded ? Theme.accent.opacity(0.18) : Color.clear)
                RoundedRectangle(cornerRadius: Radius.small)
                    .strokeBorder(isToday && !isSelected ? Theme.accent : Color.clear, lineWidth: 1)
                Text("\(day)")
                    .font(.callout.weight(recorded || saved ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white : future ? Color.secondary.opacity(0.5) : Color.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if saved {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(isSelected ? Color.white : Theme.success)
                        .padding(.bottom, 2)
                }
            }
            .frame(width: cell, height: cell)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel(dayDescription(date, recorded: recorded, saved: saved))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var legend: some View {
        HStack(spacing: Space.m) {
            legendItem(Theme.accent.opacity(0.18), String(localized: "Com gravação"))
            legendItem(Theme.success.opacity(0.28), String(localized: "Baixado no Mac"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: Space.xs) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text(title)
        }
    }

    /// Dias do mês na grade, com vazios antes do dia 1 (conforme o primeiro dia da semana) e no fim.
    private var monthDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: state.month),
              let count = calendar.range(of: .day, in: .month, for: state.month)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        days += (0 ..< count).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private func shiftMonth(_ value: Int) {
        if let next = calendar.date(byAdding: .month, value: value, to: state.month) { state.month = min(next, Date()) }
    }

    private func dayDescription(_ date: Date, recorded: Bool, saved: Bool) -> String {
        var text = date.formatted(date: .complete, time: .omitted)
        if recorded { text += ", " + String(localized: "com gravação") }
        if saved { text += ", " + String(localized: "baixado no Mac") }
        return text
    }
}
