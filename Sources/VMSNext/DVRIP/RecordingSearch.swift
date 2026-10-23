import Foundation

/// Um arquivo de gravação no NVR/cartão, retornado por OPFileQuery.
struct Recording: Identifiable, Hashable {
    enum Kind: String {
        case regular = "R", motion = "M", alarm = "A", manual = "H", other = ""

        var label: String {
            switch self {
            case .regular: return "Contínua"
            case .motion: return "Movimento"
            case .alarm: return "Alarme"
            case .manual: return "Manual"
            case .other: return "Gravação"
            }
        }
    }

    var id: String { fileName }
    let fileName: String
    let begin: Date
    let end: Date
    let sizeKB: Int
    let channel: Int

    /// O tipo vem entre colchetes no nome: ".../00.00.00-00.15.00[R][@a1b][0].h264".
    var kind: Kind {
        guard let open = fileName.firstIndex(of: "["),
              let close = fileName[open...].firstIndex(of: "]") else { return .other }
        return Kind(rawValue: String(fileName[fileName.index(after: open) ..< close])) ?? .other
    }
}

enum DeviceTime {
    /// Formato de data/hora do protocolo, no fuso local do equipamento.
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ text: String) -> Date? { formatter.date(from: text) }
}

extension DVRIPClient {
    /// Lista as gravações de um canal (base 0) em um intervalo. O equipamento devolve no máximo
    /// 64 itens por consulta, então a busca continua a partir do fim do último arquivo.
    func findRecordings(channel: Int, from start: Date, to end: Date, type: String = "h264") async throws -> [Recording] {
        var results: [Recording] = []
        var cursor = start
        for _ in 0 ..< 50 {
            let response = try await command(code: 1440, name: "OPFileQuery", payload: [
                "BeginTime": DeviceTime.string(cursor),
                "EndTime": DeviceTime.string(end),
                "Channel": channel,
                "DriverTypeMask": "0x0000FFFF",
                "Event": "*",
                "Type": type,
                "StreamType": "0x00000000",
            ], accepted: [100, 101]) // 101 = nenhum arquivo no intervalo
            let items = response["OPFileQuery"] as? [[String: Any]] ?? []
            let page = items.compactMap { item -> Recording? in
                guard let name = item["FileName"] as? String,
                      let begin = (item["BeginTime"] as? String).flatMap(DeviceTime.date),
                      let finish = (item["EndTime"] as? String).flatMap(DeviceTime.date) else { return nil }
                return Recording(fileName: name, begin: begin, end: finish,
                                 sizeKB: ConfigValue.int(item["FileLength"]) ?? 0, channel: channel)
            }
            let known = Set(results.map(\.fileName))
            let fresh = page.filter { !known.contains($0.fileName) }
            results += fresh
            guard items.count >= 64, let last = page.map(\.end).max(), last > cursor, !fresh.isEmpty else { break }
            cursor = last.addingTimeInterval(1)
        }
        return results.sorted { $0.begin < $1.begin }
    }
}
