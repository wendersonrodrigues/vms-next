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
        .sheet(item: $ui.configuring) { target in
            CameraSettingsView(target: target)
        }
        .alert("VMS Next", isPresented: Binding(get: { ui.alertMessage != nil }, set: { if !$0 { ui.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(ui.alertMessage ?? "")
        }
    }

    // MARK: - Barra lateral

    private var sidebarNodes: [SidebarNode] {
        var nodes = [SidebarNode(id: .all, title: "Câmeras", icon: "square.grid.2x2")]
        nodes += store.standaloneCameras.map { SidebarNode(id: .camera($0.id), title: $0.name, icon: "video") }
        for group in store.groups {
            let channels = store.channels(in: group).map {
                SidebarNode(id: .camera($0.id), title: $0.name, icon: "video")
            }
            nodes.append(SidebarNode(id: .group(group), title: group, icon: "server.rack", children: channels))
        }
        return nodes
    }

    private var sidebar: some View {
        List(sidebarNodes, children: \.children, selection: $ui.selection) { node in
            Label(node.title, systemImage: node.icon)
                .contextMenu { contextMenu(for: node.id) }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .onChange(of: ui.selection) { ui.page = 0 }
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

    @ViewBuilder
    private func contextMenu(for item: SidebarItem) -> some View {
        switch item {
        case .all:
            EmptyView()
        case let .camera(id):
            if let camera = store.cameras.first(where: { $0.id == id }) {
                Button("Editar…") { ui.editing = camera }
                Button("Configurações…") { ui.configuring = settingsTarget(for: camera) }
                Button("Remover", role: .destructive) {
                    if ui.selection == item { ui.selection = .all }
                    store.remove(camera)
                }
            }
        case let .group(name):
            if let first = store.channels(in: name).first {
                Button("Configurações do NVR…") { ui.configuring = SettingsTarget(camera: first, scope: .recorder) }
                Button("Remover NVR", role: .destructive) {
                    if ui.selection == item { ui.selection = .all }
                    store.removeGroup(name)
                }
            }
        }
    }

    private func settingsTarget(for camera: Camera) -> SettingsTarget {
        SettingsTarget(camera: camera, scope: camera.group == nil ? .camera : .channel)
    }

    /// Câmera em tela única, quando a seleção é uma câmera.
    private var focusedCamera: Camera? {
        guard case let .camera(id) = ui.selection else { return nil }
        return store.cameras.first { $0.id == id }
    }

    /// Mosaico: canais do NVR selecionado ou, fora dele, só as câmeras avulsas.
    private var gridCameras: [Camera] {
        if case let .group(name) = ui.selection { return store.channels(in: name) }
        return store.standaloneCameras
    }

    private var gridTitle: String {
        if case let .group(name) = ui.selection { return name }
        return "Câmeras"
    }

    private func backToGrid(from camera: Camera) {
        ui.selection = camera.group.map { .group($0) } ?? .all
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
        } else if ui.mode == .recordings {
            PlaybackView()
                .toolbar { modeToolbar }
        } else if let camera = focusedCamera {
            HStack(spacing: 0) {
                CameraTile(camera: camera, quality: .main, onEdit: { ui.editing = camera },
                           onSettings: { ui.configuring = settingsTarget(for: camera) })
                    .id(camera)
                    .onTapGesture(count: 2) { backToGrid(from: camera) }
                if ui.showPTZ {
                    PTZPanel(camera: camera)
                        .id(camera)
                }
            }
            .navigationTitle(camera.displayName)
            .toolbar {
                modeToolbar
                gridToolbar(single: true)
            }
        } else {
            grid
                .navigationTitle(gridTitle)
                .toolbar {
                    modeToolbar
                    gridToolbar(single: false)
                }
        }
    }

    private var pageCount: Int {
        max(1, Int((Double(gridCameras.count) / Double(ui.layout.tilesPerPage)).rounded(.up)))
    }

    private var grid: some View {
        let perPage = ui.layout.tilesPerPage
        let current = min(ui.page, pageCount - 1)
        let slice = Array(gridCameras.dropFirst(current * perPage).prefix(perPage))

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
                                               onEdit: { ui.editing = camera },
                                               onSettings: { ui.configuring = settingsTarget(for: camera) })
                                        .id("\(camera.id)-\(ui.layout.rawValue)-\(camera.hashValue)")
                                        .onTapGesture(count: 2) { ui.selection = .camera(camera.id) }
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
    private var modeToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Modo", selection: $ui.mode) {
                Text("Ao vivo").tag(ViewMode.live)
                Text("Gravações").tag(ViewMode.recordings)
            }
            .pickerStyle(.segmented)
        }
    }

    @ToolbarContentBuilder
    private func gridToolbar(single: Bool) -> some ToolbarContent {
        if single {
            ToolbarItem {
                Button {
                    if let camera = focusedCamera { backToGrid(from: camera) }
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
                    ui.configuring = focusedCamera.map(settingsTarget(for:))
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
    @Published var selection: SidebarItem? = .all
    @Published var editing: Camera?
    @Published var configuring: SettingsTarget?
    @Published var alertMessage: String?
    @Published var showPTZ = true
    @Published var mode: ViewMode = .live
}

enum ViewMode {
    case live
    case recordings
}

/// Item da barra lateral: todas as câmeras avulsas, um NVR (mosaico dos canais) ou uma câmera/canal.
enum SidebarItem: Hashable {
    case all
    case group(String)
    case camera(Camera.ID)
}

struct SidebarNode: Identifiable, Hashable {
    let id: SidebarItem
    let title: String
    let icon: String
    var children: [SidebarNode]?
}
