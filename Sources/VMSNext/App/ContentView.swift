import SwiftUI

enum GridLayout: Int, CaseIterable, Identifiable {
    case one = 1, four = 2, nine = 3, sixteen = 4

    var id: Int { rawValue }
    var columns: Int { rawValue }
    var tilesPerPage: Int { rawValue * rawValue }
    var label: String { "\(tilesPerPage)" }
}

struct ContentView: View {
    @EnvironmentObject private var store: CameraStore
    @StateObject private var ui = ContentUIState()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(item: $ui.editing) { camera in
            CameraEditor(camera: camera)
        }
        .sheet(item: $ui.configuring) { camera in
            CameraSettingsView(camera: camera)
        }
        .alert("VMS Next", isPresented: Binding(get: { ui.alertMessage != nil }, set: { if !$0 { ui.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(ui.alertMessage ?? "")
        }
    }

    // MARK: - Barra lateral

    private var sidebar: some View {
        List(selection: $ui.focused) {
            Section("Câmeras") {
                ForEach(store.cameras) { camera in
                    Label(camera.name, systemImage: "video")
                        .tag(camera.id)
                        .contextMenu {
                            Button("Editar…") { ui.editing = camera }
                            Button("Configurações…") { ui.configuring = camera }
                            Button("Remover", role: .destructive) {
                                if ui.focused == camera.id { ui.focused = nil }
                                store.remove(camera)
                            }
                        }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Nova câmera…") { ui.editing = Camera(name: "Nova câmera", host: "192.168.0.") }
                    Button("Importar do VMS antigo") { importLegacy() }
                } label: {
                    Label("Adicionar", systemImage: "plus")
                }
            }
        }
    }

    // MARK: - Mosaico

    @ViewBuilder
    private var detail: some View {
        if store.cameras.isEmpty {
            ContentUnavailableView {
                Label("Nenhuma câmera", systemImage: "video.slash")
            } description: {
                Text("Importe as câmeras do VMS antigo ou adicione uma manualmente.")
            } actions: {
                Button("Importar do VMS antigo") { importLegacy() }
                    .buttonStyle(.borderedProminent)
                Button("Nova câmera…") { ui.editing = Camera(name: "Nova câmera", host: "192.168.0.") }
            }
        } else if let id = ui.focused, let camera = store.cameras.first(where: { $0.id == id }) {
            HStack(spacing: 0) {
                CameraTile(camera: camera, quality: .main, onEdit: { ui.editing = camera }, onSettings: { ui.configuring = camera })
                    .id(camera)
                    .onTapGesture(count: 2) { ui.focused = nil }
                if ui.showPTZ {
                    PTZPanel(camera: camera)
                        .id(camera)
                }
            }
            .toolbar { gridToolbar(single: true) }
        } else {
            grid
                .toolbar { gridToolbar(single: false) }
        }
    }

    private var pageCount: Int {
        max(1, Int((Double(store.cameras.count) / Double(ui.layout.tilesPerPage)).rounded(.up)))
    }

    private var grid: some View {
        let perPage = ui.layout.tilesPerPage
        let current = min(ui.page, pageCount - 1)
        let slice = Array(store.cameras.dropFirst(current * perPage).prefix(perPage))

        return GeometryReader { proxy in
            let spacing: CGFloat = 2
            let columns = ui.layout.columns
            let width = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let height = (proxy.size.height - spacing * CGFloat(columns - 1)) / CGFloat(columns)

            VStack(spacing: spacing) {
                ForEach(0 ..< columns, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0 ..< columns, id: \.self) { column in
                            let index = row * columns + column
                            Group {
                                if index < slice.count {
                                    let camera = slice[index]
                                    CameraTile(camera: camera, quality: ui.layout == .one ? .main : .sub,
                                               onEdit: { ui.editing = camera }, onSettings: { ui.configuring = camera })
                                        .id("\(camera.id)-\(ui.layout.rawValue)-\(camera.hashValue)")
                                        .onTapGesture(count: 2) { ui.focused = camera.id }
                                } else {
                                    Color.black
                                }
                            }
                            .frame(width: width, height: height)
                        }
                    }
                }
            }
        }
        .background(Color(white: 0.08))
    }

    @ToolbarContentBuilder
    private func gridToolbar(single: Bool) -> some ToolbarContent {
        if single {
            ToolbarItem {
                Button {
                    ui.focused = nil
                } label: {
                    Label("Voltar ao mosaico", systemImage: "square.grid.2x2")
                }
            }
            ToolbarItem {
                Toggle(isOn: $ui.showPTZ) {
                    Label("PTZ", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                .help("Mostrar controles de PTZ")
            }
            ToolbarItem {
                Button {
                    ui.configuring = store.cameras.first { $0.id == ui.focused }
                } label: {
                    Label("Configurações", systemImage: "gearshape")
                }
                .help("Configurações da câmera")
            }
        } else {
            ToolbarItem {
                Picker("Layout", selection: $ui.layout) {
                    ForEach(GridLayout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: ui.layout) { ui.page = 0 }
            }
            if pageCount > 1 {
                ToolbarItem {
                    ControlGroup {
                        Button { ui.page = max(0, ui.page - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(ui.page == 0)
                        Text("\(min(ui.page, pageCount - 1) + 1)/\(pageCount)").monospacedDigit()
                        Button { ui.page = min(pageCount - 1, ui.page + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(ui.page >= pageCount - 1)
                    }
                }
            }
        }
    }

    private func importLegacy() {
        do {
            let count = try store.importLegacy()
            ui.alertMessage = count == 0
                ? "Nenhuma câmera nova para importar."
                : "\(count) câmera(s) importada(s). Defina a senha de cada equipamento (clique em \"Definir senha\" no mosaico)."
        } catch {
            ui.alertMessage = error.localizedDescription
        }
    }
}

/// Estado da janela principal (o macro @State do SwiftUI exige o Xcode; ObservableObject funciona só com o Swift).
final class ContentUIState: ObservableObject {
    @Published var layout: GridLayout = .four
    @Published var page = 0
    @Published var focused: Camera.ID?
    @Published var editing: Camera?
    @Published var configuring: Camera?
    @Published var alertMessage: String?
    @Published var showPTZ = true
}
