import SwiftUI

/// Editor de modelo personalizado (o "25" do VMS antigo): escolhe a grade, junta quadros vizinhos
/// para formar quadros maiores e salva com um nome.
struct TemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var layouts = ViewLayoutStore.shared
    @StateObject private var draft: TemplateDraft
    let onSaved: (ViewTemplate) -> Void

    init(template: ViewTemplate? = nil, onSaved: @escaping (ViewTemplate) -> Void) {
        _draft = StateObject(wrappedValue: TemplateDraft(template: template))
        self.onSaved = onSaved
    }

    var body: some View {
        HStack(spacing: 0) {
            savedList
                .frame(width: 200)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Nome do modelo", text: $draft.name)
                HStack(spacing: 16) {
                    Stepper("Colunas: \(draft.columns)", value: Binding(get: { draft.columns }, set: { draft.resize(columns: $0, rows: draft.rows) }), in: 1 ... 6)
                    Stepper("Linhas: \(draft.rows)", value: Binding(get: { draft.rows }, set: { draft.resize(columns: draft.columns, rows: $0) }), in: 1 ... 6)
                }
                Text("Clique nos quadros para selecionar e use \"Juntar\" para formar um quadro maior (a seleção precisa formar um retângulo). \"Separar\" desfaz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Button("Juntar") { draft.mergeSelection() }
                        .disabled(!draft.canMerge)
                    Button("Separar") { draft.splitSelection() }
                        .disabled(!draft.canSplit)
                    Text("\(draft.cells.count) quadro(s)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancelar", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Salvar") {
                        let template = draft.template
                        layouts.saveCustom(template)
                        onSaved(template)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 760, height: 520)
    }

    private var savedList: some View {
        List {
            Section("Meus modelos") {
                if layouts.custom.isEmpty {
                    Text("Nenhum ainda").foregroundStyle(.secondary)
                }
                ForEach(layouts.custom) { template in
                    HStack {
                        Button(template.name) { draft.load(template) }
                            .buttonStyle(.plain)
                        Spacer()
                        Button(role: .destructive) {
                            layouts.deleteCustom(template.id)
                            if draft.id == template.id { draft.load(nil) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Apagar este modelo")
                    }
                }
            }
            Section {
                Button("Novo modelo") { draft.load(nil) }
            }
        }
        .listStyle(.sidebar)
    }

    private var preview: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 4
            let cellWidth = (proxy.size.width - spacing * CGFloat(draft.columns - 1)) / CGFloat(draft.columns)
            let cellHeight = (proxy.size.height - spacing * CGFloat(draft.rows - 1)) / CGFloat(draft.rows)
            ZStack(alignment: .topLeading) {
                ForEach(Array(draft.cells.enumerated()), id: \.offset) { index, cell in
                    let selected = draft.selection.contains(index)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.12))
                        .overlay(Text("\(index + 1)").font(.headline).foregroundStyle(.secondary))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                        .frame(width: cellWidth * CGFloat(cell.w) + spacing * CGFloat(cell.w - 1),
                               height: cellHeight * CGFloat(cell.h) + spacing * CGFloat(cell.h - 1))
                        .offset(x: CGFloat(cell.x) * (cellWidth + spacing), y: CGFloat(cell.y) * (cellHeight + spacing))
                        .onTapGesture { draft.toggle(index) }
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }
}

@MainActor
final class TemplateDraft: ObservableObject {
    @Published var id: String
    @Published var name: String
    @Published private(set) var columns: Int
    @Published private(set) var rows: Int
    @Published private(set) var cells: [ViewCell]
    @Published private(set) var selection: Set<Int> = []

    init(template: ViewTemplate?) {
        let base = template ?? ViewTemplate.grid("custom-\(UUID().uuidString)", 3)
        id = template?.id ?? base.id
        name = template?.name ?? "Meu modelo"
        columns = base.columns
        rows = base.rows
        cells = base.cells
    }

    var template: ViewTemplate {
        ViewTemplate(id: id, name: name.trimmingCharacters(in: .whitespaces), columns: columns, rows: rows,
                     cells: cells.sorted { ($0.y, $0.x) < ($1.y, $1.x) })
    }

    func load(_ template: ViewTemplate?) {
        let base = template ?? ViewTemplate.grid("custom-\(UUID().uuidString)", 3)
        id = base.id
        name = template?.name ?? "Meu modelo"
        columns = base.columns
        rows = base.rows
        cells = base.cells
        selection = []
    }

    /// Mudar a grade recomeça com quadros iguais.
    func resize(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        cells = (0 ..< columns * rows).map { ViewCell(x: $0 % columns, y: $0 / columns) }
        selection = []
    }

    func toggle(_ index: Int) {
        if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
    }

    /// Retângulo que envolve a seleção, se ela o preenche exatamente.
    private var mergedRect: ViewCell? {
        let chosen = selection.map { cells[$0] }
        guard chosen.count > 1 else { return nil }
        let minX = chosen.map(\.x).min()!, minY = chosen.map(\.y).min()!
        let maxX = chosen.map { $0.x + $0.w }.max()!, maxY = chosen.map { $0.y + $0.h }.max()!
        let rect = ViewCell(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
        guard chosen.reduce(0, { $0 + $1.w * $1.h }) == rect.w * rect.h else { return nil }
        return rect
    }

    var canMerge: Bool { mergedRect != nil }

    var canSplit: Bool { selection.contains { cells[$0].w > 1 || cells[$0].h > 1 } }

    func mergeSelection() {
        guard let rect = mergedRect else { return }
        cells = cells.enumerated().filter { !selection.contains($0.offset) }.map(\.element) + [rect]
        selection = []
    }

    func splitSelection() {
        var result: [ViewCell] = []
        for (index, cell) in cells.enumerated() {
            if selection.contains(index) {
                for y in cell.y ..< cell.y + cell.h {
                    for x in cell.x ..< cell.x + cell.w { result.append(ViewCell(x: x, y: y)) }
                }
            } else {
                result.append(cell)
            }
        }
        cells = result
        selection = []
    }
}
