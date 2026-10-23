import Foundation

/// Um quadro do mosaico: câmera (ou metade de câmera dividida).
struct TileRef: Hashable, Codable {
    let cameraID: Camera.ID
    let part: SplitPart

    /// Texto usado no arrastar e soltar.
    var token: String { "\(cameraID.uuidString)|\(part.rawValue)" }

    init(cameraID: Camera.ID, part: SplitPart) {
        self.cameraID = cameraID
        self.part = part
    }

    init?(token: String) {
        let pieces = token.split(separator: "|").map(String.init)
        guard pieces.count == 2, let id = UUID(uuidString: pieces[0]), let part = SplitPart(rawValue: pieces[1]) else { return nil }
        self.init(cameraID: id, part: part)
    }
}

/// Retângulo de um quadro numa grade de colunas × linhas.
struct ViewCell: Codable, Hashable {
    var x: Int
    var y: Int
    var w: Int = 1
    var h: Int = 1

    func contains(_ cx: Int, _ cy: Int) -> Bool { cx >= x && cx < x + w && cy >= y && cy < y + h }
}

/// Modelo de tela ("editor de visualização" do VMS antigo): grade com quadros de tamanhos diferentes.
struct ViewTemplate: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var columns: Int
    var rows: Int
    var cells: [ViewCell]

    var isCustom: Bool { id.hasPrefix("custom-") }

    static let autoID = "auto"

    static func grid(_ id: String, _ side: Int) -> ViewTemplate {
        ViewTemplate(id: id, name: "\(side * side)", columns: side, rows: side,
                     cells: (0 ..< side * side).map { ViewCell(x: $0 % side, y: $0 / side) })
    }

    /// Um quadro grande no canto e os outros em volta (como os modelos do VMS antigo).
    static func featured(_ id: String, side: Int) -> ViewTemplate {
        let big = side - 1
        var cells = [ViewCell(x: 0, y: 0, w: big, h: big)]
        cells += (0 ..< big).map { ViewCell(x: big, y: $0) }
        cells += (0 ..< side).map { ViewCell(x: $0, y: big) }
        return ViewTemplate(id: id, name: "1 + \(cells.count - 1)", columns: side, rows: side, cells: cells)
    }

    static let builtIns: [ViewTemplate] = [
        grid("grid1", 1), grid("grid2", 2), featured("big6", side: 3), featured("big8", side: 4),
        grid("grid3", 3), grid("grid4", 4),
    ]
}

/// Modelos personalizados e quais câmeras ficam em cada quadro, salvos no Mac.
@MainActor
final class ViewLayoutStore: ObservableObject {
    static let shared = ViewLayoutStore()

    @Published private(set) var custom: [ViewTemplate] = [] {
        didSet { save() }
    }
    /// "modelo|contexto" → quadro → câmera. Sem entrada, o mosaico segue a ordem da lista.
    @Published private(set) var assignments: [String: [Int: TileRef]] = [:] {
        didSet { save() }
    }

    private let customKey = "views.custom"
    private let assignmentsKey = "views.assignments"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: customKey), let list = try? JSONDecoder().decode([ViewTemplate].self, from: data) {
            custom = list
        }
        if let data = defaults.data(forKey: assignmentsKey),
           let map = try? JSONDecoder().decode([String: [Int: TileRef]].self, from: data) {
            assignments = map
        }
    }

    var all: [ViewTemplate] { ViewTemplate.builtIns + custom }

    func template(_ id: String) -> ViewTemplate? { all.first { $0.id == id } }

    static func key(_ template: String, _ context: String) -> String { "\(template)|\(context)" }

    /// Câmeras de cada quadro: as escolhidas pelo usuário ou, sem escolha, as da lista em ordem.
    func tiles(for template: ViewTemplate, context: String, ordered: [TileRef], page: Int) -> [TileRef?] {
        if let map = assignments[Self.key(template.id, context)] {
            return template.cells.indices.map { index in map[index].flatMap { ordered.contains($0) ? $0 : nil } }
        }
        let start = page * template.cells.count
        return template.cells.indices.map { start + $0 < ordered.count ? ordered[start + $0] : nil }
    }

    func hasAssignments(_ template: ViewTemplate, context: String) -> Bool {
        assignments[Self.key(template.id, context)] != nil
    }

    /// Põe a câmera no quadro. Se ela já estava em outro quadro, os dois trocam de lugar.
    func place(_ ref: TileRef, in cell: Int, template: ViewTemplate, context: String, ordered: [TileRef], page: Int) {
        let key = Self.key(template.id, context)
        var map = assignments[key] ?? Dictionary(uniqueKeysWithValues:
            tiles(for: template, context: context, ordered: ordered, page: page).enumerated().compactMap { index, ref in
                ref.map { (index, $0) }
            })
        if let old = map.first(where: { $0.value == ref })?.key, old != cell {
            map[old] = map[cell]
        }
        map[cell] = ref
        assignments[key] = map
    }

    func clear(cell: Int, template: ViewTemplate, context: String, ordered: [TileRef], page: Int) {
        let key = Self.key(template.id, context)
        var map = assignments[key] ?? Dictionary(uniqueKeysWithValues:
            tiles(for: template, context: context, ordered: ordered, page: page).enumerated().compactMap { index, ref in
                ref.map { (index, $0) }
            })
        map[cell] = nil
        assignments[key] = map
    }

    /// Volta a seguir a ordem da lista.
    func reset(template: ViewTemplate, context: String) {
        assignments[Self.key(template.id, context)] = nil
    }

    func saveCustom(_ template: ViewTemplate) {
        if let index = custom.firstIndex(where: { $0.id == template.id }) {
            custom[index] = template
        } else {
            custom.append(template)
        }
        assignments = assignments.filter { !$0.key.hasPrefix("\(template.id)|") }
    }

    func deleteCustom(_ id: String) {
        custom.removeAll { $0.id == id }
        assignments = assignments.filter { !$0.key.hasPrefix("\(id)|") }
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: customKey) }
        if let data = try? JSONEncoder().encode(assignments) { defaults.set(data, forKey: assignmentsKey) }
    }
}

/// Um passo do rodízio de telas: um modelo de tela num mosaico (câmeras avulsas ou um NVR).
struct RotationStep: Codable, Hashable, Identifiable {
    var id = UUID()
    var templateID: String
    /// "all" ou "group:<nome do NVR>".
    var context: String
}

/// Rodízio de telas ("Config. de Tour" do VMS antigo): passa pelos modelos escolhidos, um de cada vez.
@MainActor
final class RotationStore: ObservableObject {
    static let shared = RotationStore()

    @Published var steps: [RotationStep] = [] { didSet { save() } }
    /// Segundos em cada tela.
    @Published var dwell: Int = 20 { didSet { save() } }
    @Published private(set) var running = false
    @Published private(set) var index = 0
    private var timer: Timer?
    var apply: ((RotationStep) -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "rotation.steps"), let saved = try? JSONDecoder().decode([RotationStep].self, from: data) {
            steps = saved
        }
        dwell = defaults.object(forKey: "rotation.dwell") as? Int ?? 20
    }

    func toggle() { running ? stop() : start() }

    func start() {
        guard !steps.isEmpty else { return }
        running = true
        index = 0
        apply?(steps[0])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(dwell, 3)), repeats: true) { _ in
            MainActor.assumeIsolated { RotationStore.shared.advance() }
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    private func advance() {
        guard running, !steps.isEmpty else { return stop() }
        index = (index + 1) % steps.count
        apply?(steps[index])
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(steps) { defaults.set(data, forKey: "rotation.steps") }
        defaults.set(dwell, forKey: "rotation.dwell")
    }
}
