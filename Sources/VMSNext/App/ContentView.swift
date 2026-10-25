import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: CameraStore
    @StateObject private var ui = ContentUIState()
    @ObservedObject private var alarms = AlarmCenter.shared
    @ObservedObject private var layouts = ViewLayoutStore.shared
    @ObservedObject private var rotation = RotationStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A coluna de ícones fica fora da barra lateral: o botão de esconder a barra só esconde a lista de câmeras.
        HStack(spacing: 0) {
            // No Início a coluna de ícones também some: a própria Home tem o menu.
            if ui.mode != .home {
                NavigationRail(mode: $ui.mode, unread: alarms.unread)
                Divider()
            }
            NavigationSplitView(columnVisibility: $ui.columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 360)
            } detail: {
                detail
            }
            // Barra do topo com as cores do tema (não o cinza do sistema).
            .toolbarBackground(Theme.surface, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .onChange(of: ui.mode) { old, new in
            if new == .events { alarms.markAllRead() }
            // O PTZ do mosaico fecha ao sair do ao vivo.
            if new != .live { ui.mosaicPTZCamera = nil }
            // No Início a lista de câmeras fica recolhida; volta ao sair dele.
            let hidden: [ViewMode] = [.home, .preferences]
            if hidden.contains(new) { ui.columnVisibility = .detailOnly } else if hidden.contains(old) { ui.columnVisibility = .all }
        }
        .sheet(item: $ui.editing) { camera in
            CameraEditor(camera: camera)
        }
        .task {
            AlarmCenter.shared.start(store: store)
            ClockSync.runIfEnabled(store: store)
            AutoSnapshot.shared.reschedule()
            LocalRecorder.shared.start(store: store)
            rotation.apply = { step in
                ui.templateID = step.templateID
                ui.page = 0
                if step.context.hasPrefix("group:") {
                    ui.selection = .group(String(step.context.dropFirst(6)))
                } else {
                    ui.selection = .all
                }
                ui.mode = .live
            }
        }
        // Menus com atalhos (AppCommands) leem o estado desta janela.
        .focusedSceneObject(ui)
        .onChange(of: pageCount, initial: true) { _, count in ui.pageCount = count }
        .onChange(of: ui.selection, initial: true) { _, _ in
            ui.gridSelection = focusedCamera.map { camera in camera.group.map { .group($0) } ?? .all }
        }
        .onChange(of: alarms.openEventsRequested) { openEventsIfRequested() }
        .onAppear { openEventsIfRequested() }
        .sheet(isPresented: $ui.editingRotation) {
            RotationEditor()
        }
        .sheet(isPresented: $ui.editingTemplate) {
            TemplateEditor { ui.templateID = $0.id }
        }
        .alert("Renomear quadro", isPresented: Binding(get: { ui.renaming != nil }, set: { if !$0 { ui.renaming = nil } })) {
            TextField("Nome", text: Binding(get: { ui.renaming?.text ?? "" }, set: { ui.renaming?.text = $0 }))
            Button("Salvar") { applyRename() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O nome vale só no VMS Next; a câmera continua com o nome oficial.")
        }
        .alert("VMS Next", isPresented: Binding(get: { ui.alertMessage != nil }, set: { if !$0 { ui.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(ui.alertMessage ?? "")
        }
    }

    // MARK: - Barra lateral

    /// Primeiro nível da lista, dentro de "Câmeras": câmeras avulsas e NVRs na ordem escolhida.
    private var topNodes: [SidebarNode] {
        store.topLevel.compactMap { item in
            switch item {
            case let .camera(id):
                return store.cameras.first { $0.id == id }.map(cameraNode)
            case let .group(group):
                return SidebarNode(id: .group(group), title: group, icon: "server.rack",
                                   children: store.channels(in: group).map(cameraNode))
            }
        }
    }

    /// Câmera na lista; dividida (split virtual), mostra as duas metades dentro dela.
    private func cameraNode(_ camera: Camera) -> SidebarNode {
        guard let split = camera.split else {
            return SidebarNode(id: .camera(camera.id), title: camera.name, icon: "video")
        }
        return SidebarNode(id: .camera(camera.id), title: camera.name, icon: "video", children: split.parts.map { part in
            part == .top
                ? SidebarNode(id: .part(camera.id, .top), title: split.topName, icon: "rectangle.tophalf.filled")
                : SidebarNode(id: .part(camera.id, .bottom), title: split.bottomName, icon: "rectangle.bottomhalf.filled")
        })
    }

    /// Arrastar as metades na lista: com duas, qualquer movimento troca a ordem.
    private func moveParts(of id: Camera.ID, from source: IndexSet, to destination: Int) {
        guard var camera = store.cameras.first(where: { $0.id == id }), var split = camera.split else { return }
        var parts = split.parts
        parts.move(fromOffsets: source, toOffset: destination)
        split.bottomFirst = parts.first == .bottom
        camera.split = split
        store.upsert(camera)
    }

    private func toggleSplit(_ camera: Camera) {
        var updated = camera
        updated.split = camera.split == nil
            ? CameraSplit(topName: "\(camera.name) · cima", bottomName: "\(camera.name) · baixo") : nil
        if updated.split == nil, case let .part(id, _) = ui.selection, id == camera.id { ui.selection = .camera(id) }
        store.upsert(updated)
    }

    private func rename(_ camera: Camera, part: SplitPart) {
        ui.renaming = RenameRequest(cameraID: camera.id, part: part, text: camera.title(for: part))
    }

    private func applyRename() {
        guard let request = ui.renaming,
              var camera = store.cameras.first(where: { $0.id == request.cameraID }), var split = camera.split else { return }
        let name = request.text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if request.part == .top { split.topName = name } else { split.bottomName = name }
        camera.split = split
        store.upsert(camera)
    }

    private var sidebar: some View {
        // No ao vivo, o PTZ da câmera escolhida no mosaico fica no pé da lista (a lista rola por cima).
        GeometryReader { proxy in
            VStack(spacing: 0) {
                cameraList
                // Até 60% da altura: com muitas câmeras, a lista continua rolando por cima do painel.
                sidebarPTZ(height: min(580, proxy.size.height * 0.6))
            }
        }
        .background(Theme.sidebar)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ui.mosaicPTZCamera)
    }

    @ViewBuilder
    private func sidebarPTZ(height: CGFloat) -> some View {
        if ui.mode == .live, let id = ui.mosaicPTZCamera, let camera = store.cameras.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                Divider()
                ScrollView {
                    PTZPanel(camera: camera) { ui.mosaicPTZCamera = nil }
                        .id(camera.id)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { ui.ptzPanelHeight = $0 }
                }
                // Só a altura do conteúdo, encostado na base; com pouco espaço, no máximo `height` e rola.
                .frame(height: ui.ptzPanelHeight > 0 ? min(ui.ptzPanelHeight, height) : height)
            }
            .background(Theme.surface)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var cameraList: some View {
        List(selection: $ui.selection) {
            DisclosureGroup(isExpanded: expanded("all")) {
                ForEach(topNodes) { node in nodeRow(node) }
                    .onMove { store.moveTopLevel(from: $0, to: $1) }
            } label: {
                Label("Câmeras", systemImage: "square.grid.2x2")
                    .font(.headline)
                    .tag(SidebarItem.all)
                    .help("Mosaico de todas as câmeras avulsas. Arraste os itens abaixo para mudar a ordem.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .toolbar {
            if ui.mode == .live || ui.mode == .settings { addToolbar }
        }
        .onChange(of: ui.selection) {
            ui.page = 0
            // Escolher uma câmera na lista volta para o ao vivo (as gravações têm a própria escolha).
            if [.home, .events, .devices, .preferences].contains(ui.mode) { ui.mode = .live }
        }
    }

    /// "+" só onde faz sentido adicionar câmeras: ao vivo e configurações.
    @ToolbarContentBuilder
    private var addToolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("Nova câmera…") { ui.editing = Camera(name: String(localized: "Nova câmera"), host: "192.168.0.") }
                Button("Procurar câmeras na rede…") { ui.mode = .devices }
                Divider()
                Button("Importar câmeras…", action: importCameras)
                Button("Exportar câmeras…", action: exportCameras)
                    .disabled(store.cameras.isEmpty)
            } label: {
                Label("Adicionar", systemImage: "plus")
            }
            .help("Adicionar câmeras, ou importar e exportar a lista para outro Mac")
        }
    }

    /// Linha da lista. NVRs e câmeras divididas abrem os itens de dentro; os canais de um NVR
    /// também podem ser reordenados arrastando.
    private func nodeRow(_ node: SidebarNode) -> AnyView {
        let label = Label(node.title, systemImage: node.icon)
            .tag(node.id)
            .contextMenu { contextMenu(for: node.id) }
        guard let children = node.children else {
            // Câmeras e metades podem ser arrastadas para um quadro do modelo de tela.
            switch node.id {
            case let .camera(id): return AnyView(label.draggable(TileRef(cameraID: id, part: .full).token))
            case let .part(id, part): return AnyView(label.draggable(TileRef(cameraID: id, part: part).token))
            default: return AnyView(label)
            }
        }
        var move: ((IndexSet, Int) -> Void)?
        if case let .group(name) = node.id {
            move = { store.moveChannels(in: name, from: $0, to: $1) }
        } else if case let .camera(id) = node.id {
            move = { moveParts(of: id, from: $0, to: $1) }
        }
        return AnyView(DisclosureGroup(isExpanded: expanded("\(node.id)")) {
            ForEach(children) { child in nodeRow(child) }
                .onMove(perform: move)
        } label: {
            label
        })
    }

    private func expanded(_ key: String) -> Binding<Bool> {
        Binding(get: { !ui.collapsed.contains(key) },
                set: { if $0 { ui.collapsed.remove(key) } else { ui.collapsed.insert(key) } })
    }

    @ViewBuilder
    private func contextMenu(for item: SidebarItem) -> some View {
        switch item {
        case .all:
            EmptyView()
        case let .part(id, part):
            if let camera = store.cameras.first(where: { $0.id == id }) {
                Button("Renomear este quadro…") { rename(camera, part: part) }
                Button("Desfazer divisão") { toggleSplit(camera) }
            }
        case let .camera(id):
            if let camera = store.cameras.first(where: { $0.id == id }) {
                Button("Editar…") { ui.editing = camera }
                Button("Configurações…") { openSettings(settingsTarget(for: camera)) }
                Button(camera.split == nil ? String(localized: "Dividir em duas (split virtual)") : String(localized: "Desfazer divisão")) { toggleSplit(camera) }
                Button("Remover", role: .destructive) {
                    if ui.selection == item { ui.selection = .all }
                    store.remove(camera)
                }
            }
        case let .group(name):
            if let first = store.channels(in: name).first {
                Button("Configurações do NVR…") { openSettings(SettingsTarget(camera: first, scope: .recorder)) }
                Button("Remover NVR", role: .destructive) {
                    if ui.selection == item { ui.selection = .all }
                    store.removeGroup(name)
                }
            }
        }
    }

    /// Configurações do que está escolhido na lista: câmera, canal ou NVR inteiro.
    private var selectedSettingsTarget: SettingsTarget? {
        switch ui.selection {
        case let .camera(id), let .part(id, _):
            return store.cameras.first { $0.id == id }.map(settingsTarget(for:))
        case let .group(name):
            return store.channels(in: name).first.map { SettingsTarget(camera: $0, scope: .recorder) }
        case .all, nil:
            return nil
        }
    }

    private var settingsTitle: String {
        guard let target = selectedSettingsTarget else { return String(localized: "Configurações") }
        switch target.scope {
        case .recorder: return "Configurações do NVR · \(target.title)"
        case .channel: return "Configurações do canal · \(target.title)"
        case .camera: return "Configurações da câmera · \(target.title)"
        }
    }

    /// Abre as configurações embutidas, escolhendo o equipamento na lista.
    private func openSettings(_ target: SettingsTarget?) {
        guard let target else { return }
        if target.scope == .recorder, let group = target.camera.group {
            ui.selection = .group(group)
        } else {
            ui.selection = .camera(target.camera.id)
        }
        ui.mode = .settings
    }

    private func settingsTarget(for camera: Camera) -> SettingsTarget {
        SettingsTarget(camera: camera, scope: camera.group == nil ? .camera : .channel)
    }

    /// Câmera em tela única, quando a seleção é uma câmera.
    private var focusedCamera: Camera? {
        switch ui.selection {
        case let .camera(id), let .part(id, _): return store.cameras.first { $0.id == id }
        default: return nil
        }
    }

    /// Metade escolhida na lista (split virtual); a câmera inteira mostra a imagem toda.
    private var focusedPart: SplitPart {
        if case let .part(_, part) = ui.selection { return part }
        return .full
    }

    /// Mosaico: canais do NVR selecionado ou, fora dele, só as câmeras avulsas.
    private var gridCameras: [Camera] {
        if case let .group(name) = ui.selection { return store.channels(in: name) }
        return store.standaloneCameras
    }

    /// Quadros do mosaico: câmeras divididas ocupam dois quadros (cima e baixo) com o mesmo vídeo.
    private var gridTiles: [GridTile] {
        gridCameras.flatMap { camera in
            (camera.split?.parts ?? [.full]).map { GridTile(camera: camera, part: $0) }
        }
    }

    private var gridTitle: String {
        if case let .group(name) = ui.selection { return name }
        return String(localized: "Câmeras")
    }

    /// Abre ou fecha o PTZ desta câmera no pé da lista; abre a lista se ela estiver escondida.
    private func togglePTZ(_ camera: Camera) {
        if ui.mosaicPTZCamera == camera.id {
            ui.mosaicPTZCamera = nil
        } else {
            ui.mosaicPTZCamera = camera.id
            if ui.columnVisibility == .detailOnly { ui.columnVisibility = .all }
        }
    }

    private func backToGrid(from camera: Camera) {
        ui.selection = camera.group.map { .group($0) } ?? .all
    }

    // MARK: - Mosaico

    @ViewBuilder
    private var detail: some View {
        if store.cameras.isEmpty, ![.devices, .preferences].contains(ui.mode) {
            ContentUnavailableView {
                Label("Nenhuma câmera", systemImage: "video.slash")
            } description: {
                Text("Procure as câmeras na sua rede, adicione uma pelo IP ou importe a lista de outro Mac.")
            } actions: {
                Button("Procurar na rede") { ui.mode = .devices }
                    .buttonStyle(.borderedProminent)
                Button("Nova câmera…") { ui.editing = Camera(name: String(localized: "Nova câmera"), host: "192.168.0.") }
                Button("Importar câmeras…", action: importCameras)
            }
        } else if ui.mode == .home {
            HomeView(onMode: { ui.mode = $0 },
                     onOpenLive: { item in
                         ui.selection = item
                         ui.mode = .live
                     },
                     onSettings: { camera, recorder in
                         openSettings(recorder ? SettingsTarget(camera: camera, scope: .recorder) : settingsTarget(for: camera))
                     })
                .toolbar {
                    titleIcon
                    modeToolbar
                }
        } else if ui.mode == .settings {
            SettingsPane(target: selectedSettingsTarget, category: $ui.settingsCategory)
                .navigationTitle(settingsTitle)
                .toolbar {
                    titleIcon
                    modeToolbar
                }
        } else if ui.mode == .recordings {
            PlaybackView(cameraID: focusedCamera?.id, request: $ui.playbackRequest)
                .navigationTitle("Gravações")
                .toolbar {
                    titleIcon
                    modeToolbar
                }
        } else if ui.mode == .events {
            EventsView(center: AlarmCenter.shared, onOpenCamera: { id in
                ui.selection = .camera(id)
                ui.mode = .live
            }, onOpenRecording: { id, date in
                ui.selection = .camera(id)
                ui.playbackRequest = PlaybackRequest(cameraID: id, date: date)
                ui.mode = .recordings
            })
            .navigationTitle("Eventos")
            .toolbar {
                    titleIcon
                    modeToolbar
                }
        } else if ui.mode == .devices {
            DevicesView(onEdit: { ui.editing = $0 },
                        onSettings: { camera in
                            openSettings(camera.group == nil
                                ? settingsTarget(for: camera) : SettingsTarget(camera: camera, scope: .recorder))
                        })
                .toolbar {
                    titleIcon
                    modeToolbar
                }
        } else if ui.mode == .preferences {
            PreferencesView()
                .navigationTitle("Preferências")
                .toolbar {
                    titleIcon
                    modeToolbar
                }
        } else if let camera = focusedCamera {
            HStack(spacing: 0) {
                CameraTile(camera: camera, quality: ui.singleQuality, part: focusedPart, onEdit: { ui.editing = camera },
                           onSettings: { openSettings(settingsTarget(for: camera)) },
                           onToggleSplit: { toggleSplit(camera) },
                           onRename: focusedPart == .full ? nil : { rename(camera, part: focusedPart) },
                           single: SingleViewControls(quality: $ui.singleQuality),
                           onOpen: { backToGrid(from: camera) }, openTitle: String(localized: "Voltar ao mosaico"),
                           ptzActive: ui.mosaicPTZCamera == camera.id,
                           onTogglePTZ: { togglePTZ(camera) })
                    .id("\(camera.id)-\(focusedPart)-\(ui.singleQuality)-\(camera.hashValue)")
                    .onTapGesture(count: 2) { backToGrid(from: camera) }
            }
            .navigationTitle(camera.title(for: focusedPart))
            .toolbar {
                titleIcon
                gridToolbar(single: true)
                modeToolbar
            }
        } else {
            VStack(spacing: 0) {
                grid
                mosaicBar
            }
            .navigationTitle(gridTitle)
            .toolbar {
                titleIcon
                modeToolbar
            }
        }
    }

    /// Modelo de tela escolhido; nil = automático.
    private var currentTemplate: ViewTemplate? { layouts.template(ui.templateID) }

    /// Cada mosaico (câmeras avulsas ou um NVR) guarda as próprias posições.
    private var gridContext: String {
        if case let .group(name) = ui.selection { return "group:\(name)" }
        return "all"
    }

    private var orderedRefs: [TileRef] { gridTiles.map { TileRef(cameraID: $0.camera.id, part: $0.part) } }

    private func gridTile(for ref: TileRef) -> GridTile? {
        gridTiles.first { $0.camera.id == ref.cameraID && $0.part == ref.part }
    }

    private var pageCount: Int {
        guard let template = currentTemplate, !layouts.hasAssignments(template, context: gridContext) else { return 1 }
        return max(1, Int((Double(gridTiles.count) / Double(template.cells.count)).rounded(.up)))
    }

    /// Automático: testa cada número de colunas e fica com o que deixa a imagem 16:9 de cada câmera maior.
    private func autoShape(count: Int, size: CGSize) -> (columns: Int, rows: Int) {
        let total = max(count, 1)
        var best = (columns: 1, rows: total)
        var bestWidth: CGFloat = 0
        for columns in 1 ... total {
            let rows = Int((Double(total) / Double(columns)).rounded(.up))
            let cellWidth = size.width / CGFloat(columns)
            let cellHeight = size.height / CGFloat(rows)
            let videoWidth = min(cellWidth, cellHeight * 16 / 9)
            if videoWidth > bestWidth {
                bestWidth = videoWidth
                best = (columns, rows)
            }
        }
        return best
    }

    private var grid: some View {
        Group {
            if let template = currentTemplate {
                templateGrid(template)
            } else {
                autoGrid
            }
        }
        .background(Color(white: 0.08))
    }

    private func tileView(_ tile: GridTile, single: Bool, extraMenu: AnyView? = nil) -> some View {
        let camera = tile.camera
        return CameraTile(camera: camera, quality: single ? .main : .sub, part: tile.part,
                          onEdit: { ui.editing = camera },
                          onSettings: { openSettings(settingsTarget(for: camera)) },
                          onToggleSplit: { toggleSplit(camera) },
                          onRename: tile.part == .full ? nil : { rename(camera, part: tile.part) },
                          extraMenu: extraMenu,
                          onOpen: { ui.selection = tile.part == .full ? .camera(camera.id) : .part(camera.id, tile.part) },
                          ptzActive: ui.mosaicPTZCamera == camera.id,
                          onTogglePTZ: { togglePTZ(camera) })
            .id("\(camera.id)-\(tile.part)-\(single)-\(camera.hashValue)")
            .onTapGesture(count: 2) {
                ui.selection = tile.part == .full ? .camera(camera.id) : .part(camera.id, tile.part)
            }
    }

    private var autoGrid: some View {
        let slice = gridTiles
        return GeometryReader { proxy in
            let spacing: CGFloat = 2
            let shape = autoShape(count: slice.count, size: proxy.size)
            let width = (proxy.size.width - spacing * CGFloat(shape.columns - 1)) / CGFloat(shape.columns)
            let height = (proxy.size.height - spacing * CGFloat(shape.rows - 1)) / CGFloat(shape.rows)
            let single = slice.count == 1

            VStack(spacing: spacing) {
                ForEach(0 ..< shape.rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0 ..< shape.columns, id: \.self) { column in
                            let index = row * shape.columns + column
                            if index < slice.count {
                                tileView(slice[index], single: single)
                                    .frame(width: width, height: height)
                            }
                        }
                    }
                    // A última linha pode ter menos câmeras: fica centralizada.
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Modelo de tela: cada quadro na posição e tamanho do modelo. Arraste câmeras da lista (ou de
    /// outro quadro) para cima de um quadro para colocá-las ali.
    private func templateGrid(_ template: ViewTemplate) -> some View {
        let page = min(ui.page, pageCount - 1)
        let refs = layouts.tiles(for: template, context: gridContext, ordered: orderedRefs, page: page)
        let single = template.cells.count == 1
        return GeometryReader { proxy in
            let spacing: CGFloat = 2
            let cellWidth = (proxy.size.width - spacing * CGFloat(template.columns - 1)) / CGFloat(template.columns)
            let cellHeight = (proxy.size.height - spacing * CGFloat(template.rows - 1)) / CGFloat(template.rows)
            ZStack(alignment: .topLeading) {
                ForEach(template.cells.indices, id: \.self) { index in
                    let cell = template.cells[index]
                    cellView(index: index, ref: refs[index], template: template, single: single, page: page)
                        .frame(width: cellWidth * CGFloat(cell.w) + spacing * CGFloat(cell.w - 1),
                               height: cellHeight * CGFloat(cell.h) + spacing * CGFloat(cell.h - 1))
                        .offset(x: CGFloat(cell.x) * (cellWidth + spacing), y: CGFloat(cell.y) * (cellHeight + spacing))
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(index: Int, ref: TileRef?, template: ViewTemplate, single: Bool, page: Int) -> some View {
        let drop: ([String], CGPoint) -> Bool = { items, _ in
            guard let token = items.first, let dropped = TileRef(token: token), gridTile(for: dropped) != nil else { return false }
            layouts.place(dropped, in: index, template: template, context: gridContext, ordered: orderedRefs, page: page)
            return true
        }
        if let ref, let tile = gridTile(for: ref) {
            tileView(tile, single: single, extraMenu: AnyView(Group {
                chooseMenu(index: index, template: template, page: page)
                Button("Tirar deste quadro") {
                    layouts.clear(cell: index, template: template, context: gridContext, ordered: orderedRefs, page: page)
                }
            }))
            .draggable(ref.token)
            .dropDestination(for: String.self, action: drop)
        } else {
            ZStack {
                Color.black
                VStack(spacing: 8) {
                    Image(systemName: "plus.viewfinder").font(.title2)
                    Text("Arraste uma câmera da lista para cá").font(.caption)
                    Menu("Escolher câmera") { chooseMenu(index: index, template: template, page: page) }
                        .fixedSize()
                }
                .foregroundStyle(.white.opacity(0.6))
            }
            .dropDestination(for: String.self, action: drop)
        }
    }

    /// Lista das câmeras do mosaico para pôr num quadro (alternativa ao arrastar).
    @ViewBuilder
    private func chooseMenu(index: Int, template: ViewTemplate, page: Int) -> some View {
        Menu("Mostrar neste quadro") {
            ForEach(gridTiles, id: \.self) { tile in
                Button(tile.camera.title(for: tile.part)) {
                    layouts.place(TileRef(cameraID: tile.camera.id, part: tile.part), in: index, template: template,
                                  context: gridContext, ordered: orderedRefs, page: page)
                }
            }
        }
    }

    private func templateButton(_ template: ViewTemplate?) -> some View {
        let id = template?.id ?? ViewTemplate.autoID
        return Button {
            ui.templateID = id
        } label: {
            TemplateThumbnail(template: template, selected: ui.templateID == id)
        }
        .buttonStyle(.hover)
        .help(template.map(Self.templateTitle) ?? String(localized: "Auto: todas as câmeras, no melhor tamanho"))
        .accessibilityLabel(template.map(Self.templateTitle) ?? "Auto")
        .accessibilityAddTraits(ui.templateID == id ? .isSelected : [])
    }

    private var templateLabel: String {
        currentTemplate.map(Self.templateTitle) ?? "Auto"
    }

    static func templateTitle(_ template: ViewTemplate) -> String {
        switch template.id {
        case "grid1": return "1 câmera"
        case "grid2": return "4 câmeras"
        case "big6": return "1 grande + 5"
        case "big8": return "1 grande + 7"
        case "grid3": return "9 câmeras"
        case "grid4": return "16 câmeras"
        default: return template.name
        }
    }

    /// Ícone da tela antes do título (o mesmo da coluna de ícones).
    @ToolbarContentBuilder
    private var titleIcon: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ModeIcon(mode: ui.mode == .live && focusedCamera == nil ? .live : ui.mode, size: 22)
        }
    }

    @ToolbarContentBuilder
    private var modeToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                ui.mode = .events
                alarms.markAllRead()
            } label: {
                Image(systemName: alarms.unread > 0 ? "bell.fill" : "bell")
                    .overlay(alignment: .topTrailing) {
                        if alarms.unread > 0 {
                            Text(alarms.unread > 99 ? "99+" : "\(alarms.unread)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, Space.xs)
                                .padding(.vertical, Space.xxs)
                                .background(Capsule().fill(Color.red))
                                .offset(x: 9, y: -7)
                        }
                    }
            }
            .help(alarms.unread > 0 ? "\(alarms.unread) alerta(s) novo(s)" : String(localized: "Eventos"))
            .accessibilityLabel("Eventos")
            .accessibilityValue(alarms.unread > 0 ? "\(alarms.unread) \(alarms.unread == 1 ? "alerta novo" : "alertas novos")" : "")
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
                Button {
                    openSettings(focusedCamera.map(settingsTarget(for:)))
                } label: {
                    Label("Configurações", systemImage: "gearshape")
                }
                .help("Configurações da câmera")
            }
        }
    }

    /// Barra de baixo do mosaico: modelo de tela, páginas e rodízio.
    private var mosaicBar: some View {
        HStack(spacing: 14) {
            // Modelos de tela clicáveis, como a barra de modelos do VMS antigo.
            HStack(spacing: 6) {
                templateButton(nil)
                ForEach(ViewTemplate.builtIns) { templateButton($0) }
                ForEach(layouts.custom) { templateButton($0) }
                // Só o personalizado fica fora dos ícones: criar ou editar um modelo próprio.
                Button { ui.editingTemplate = true } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 22)
                        .padding(Space.xs)
                        .background(RoundedRectangle(cornerRadius: Radius.small).fill(Color.primary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(Theme.stroke))
                }
                .buttonStyle(.hover)
                .help("Criar ou editar um modelo personalizado (o \"25\" do VMS antigo)")
                .accessibilityLabel("Criar ou editar modelo de tela")
            }
            // Voltar à ordem da lista (desfaz as câmeras arrastadas neste modelo).
            if let template = currentTemplate {
                BarButton(icon: "arrow.uturn.backward", title: String(localized: "Ordem da lista"),
                          help: String(localized: "Voltar à ordem da lista: desfaz as câmeras arrastadas neste modelo")) {
                    layouts.reset(template: template, context: gridContext)
                }
                .disabled(!layouts.hasAssignments(template, context: gridContext))
            }

            if pageCount > 1 {
                ControlGroup {
                    Button { ui.page = max(0, ui.page - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(ui.page == 0)
                        .help("Página anterior (⌥⌘←)")
                        .accessibilityLabel("Página anterior")
                    Text("\(min(ui.page, pageCount - 1) + 1)/\(pageCount)").monospacedDigit()
                    Button { ui.page = min(pageCount - 1, ui.page + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(ui.page >= pageCount - 1)
                        .help("Próxima página (⌥⌘→)")
                        .accessibilityLabel("Próxima página")
                }
                .fixedSize()
            }
            Spacer()
            Button {
                if rotation.steps.isEmpty { ui.editingRotation = true } else { rotation.toggle() }
            } label: {
                Label(rotation.running ? String(localized: "Parar rodízio") : String(localized: "Rodízio de telas"),
                      systemImage: rotation.running ? "stop.circle" : "arrow.triangle.2.circlepath.circle")
            }
            .buttonStyle(.hover)
            .help(rotation.running ? String(localized: "Parar o rodízio de telas") : String(localized: "Passa sozinho pelas telas escolhidas (Tour do VMS antigo) · ⌥⌘R"))
            BarButton(icon: "slider.horizontal.3", help: String(localized: "Escolher as telas e o tempo do rodízio")) { ui.editingRotation = true }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .background(Theme.surface)
    }

    /// Clique numa notificação ou em "Ver eventos" na barra de menus.
    private func openEventsIfRequested() {
        guard alarms.openEventsRequested else { return }
        alarms.openEventsRequested = false
        ui.mode = .events
    }

    private func exportCameras() {
        let prefs = AppPreferences.shared
        guard let url = prefs.destination(named: "Câmeras do VMS Next \(AppPreferences.stamp(Date()))", in: prefs.downloadFolder, type: .json)
        else { return }
        do {
            try store.exportData().write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            AppLog.shared.add(.file, "Lista de câmeras exportada: \(url.lastPathComponent)")
        } catch {
            ui.alertMessage = error.localizedDescription
        }
    }

    private func importCameras() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try store.importData(Data(contentsOf: url))
            AppLog.shared.add(.file, "Lista de câmeras importada: \(count) nova(s)")
            ui.alertMessage = count == 0
                ? String(localized: "Nenhuma câmera nova no arquivo.")
                : String(localized: "\(count) câmera(s) importada(s). As senhas não vão no arquivo: defina a de cada equipamento (\"Definir senha\" no mosaico).")
        } catch {
            ui.alertMessage = String(localized: "Arquivo inválido: \(error.localizedDescription)")
        }
    }
}

/// Estado da janela principal (o macro @State do SwiftUI exige o Xcode; ObservableObject funciona só com o Swift).
final class ContentUIState: ObservableObject {
    /// Modelo de tela do mosaico (ViewTemplate.autoID = automático).
    @Published var templateID = ViewTemplate.autoID { didSet { save() } }
    @Published var editingTemplate = false
    @Published var editingRotation = false
    /// Lista de câmeras ao lado: recolhida no Início.
    @Published var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @Published var page = 0
    /// Páginas do mosaico atual (o menu Mosaico usa para saber se há próxima página).
    @Published var pageCount = 1
    /// Para onde "Voltar ao mosaico" leva quando uma câmera está em tela única; nil no mosaico.
    @Published var gridSelection: SidebarItem?
    @Published var selection: SidebarItem? = .all { didSet { save() } }
    @Published var editing: Camera?
    /// Categoria aberta em Configurações (nil = menu de ícones). Fica a mesma ao trocar de câmera.
    @Published var settingsCategory: SettingsCategory?
    @Published var renaming: RenameRequest?
    /// Pedido vindo de Eventos: abrir a gravação desta câmera neste momento.
    @Published var playbackRequest: PlaybackRequest?
    /// Itens da lista recolhidos (o resto fica aberto).
    @Published var collapsed: Set<String> = []
    @Published var alertMessage: String?
    /// Câmera com o PTZ aberto (mosaico ou tela única; só uma por vez), no pé da lista de câmeras.
    @Published var mosaicPTZCamera: Camera.ID?
    /// Altura do conteúdo do painel de PTZ, para ele ocupar só o necessário (rola só se não couber).
    @Published var ptzPanelHeight: CGFloat = 0
    /// Qualidade da câmera em tela cheia (o mosaico usa sempre o vídeo extra, mais leve).
    @Published var singleQuality: StreamQuality = .main
    /// O app sempre abre no Início, que mostra se as câmeras estão conectadas antes do mosaico.
    @Published var mode: ViewMode = .home { didSet { save() } }

    private static let stateKey = "ui.lastState"
    private var restoring = false

    /// "Retomar ao estado anterior": volta para a tela, a câmera e o modelo de quando o app foi fechado.
    @MainActor
    init() {
        let prefs = AppPreferences.shared
        singleQuality = prefs.singleQualityHD ? .main : .sub
        guard prefs.restoreState, let saved = UserDefaults.standard.dictionary(forKey: Self.stateKey) else { return }
        restoring = true
        if let raw = saved["template"] as? String { templateID = raw }
        if let raw = saved["selection"] as? String { selection = SidebarItem(token: raw) ?? .all }
        restoring = false
    }

    private func save() {
        guard !restoring else { return }
        UserDefaults.standard.set([
            "mode": mode.rawValue, "template": templateID, "selection": selection?.token ?? "all",
        ], forKey: Self.stateKey)
    }
}

/// Telas da coluna de ícones: o mesmo ícone aparece na coluna e antes do título da tela.
extension ViewMode {
    var title: String {
        switch self {
        case .home: return "Início"
        case .live: return "Ao vivo"
        case .recordings: return "Gravações"
        case .events: return "Eventos"
        case .devices: return "Dispositivos"
        case .settings: return "Configurações"
        case .preferences: return "Preferências"
        }
    }

    /// Ícone do sistema (usado quando não há o ícone gerado em Resources/Icons).
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .live: return "video.fill"
        case .recordings: return "play.rectangle.on.rectangle.fill"
        case .events: return "bell.fill"
        case .devices: return "externaldrive.connected.to.line.below.fill"
        case .settings: return "video.badge.ellipsis"
        case .preferences: return "gearshape.fill"
        }
    }
}

enum ViewMode: String {
    case home
    case live
    case recordings
    case events
    case devices
    case settings
    case preferences
}

/// Item da barra lateral: todas as câmeras avulsas, um NVR (mosaico dos canais) ou uma câmera/canal.
enum SidebarItem: Hashable {
    case all
    case group(String)
    case camera(Camera.ID)
    /// Uma metade de câmera dividida (split virtual).
    case part(Camera.ID, SplitPart)

    /// Texto para guardar a seleção entre aberturas do app.
    var token: String {
        switch self {
        case .all: return "all"
        case let .group(name): return "group:\(name)"
        case let .camera(id): return "camera:\(id.uuidString)"
        case let .part(id, part): return "part:\(id.uuidString):\(part.rawValue)"
        }
    }

    init?(token: String) {
        let pieces = token.split(separator: ":", maxSplits: 1).map(String.init)
        switch pieces.first {
        case "all": self = .all
        case "group" where pieces.count == 2: self = .group(pieces[1])
        case "camera" where pieces.count == 2:
            guard let id = UUID(uuidString: pieces[1]) else { return nil }
            self = .camera(id)
        case "part" where pieces.count == 2:
            let rest = pieces[1].split(separator: ":").map(String.init)
            guard rest.count == 2, let id = UUID(uuidString: rest[0]), let part = SplitPart(rawValue: rest[1]) else { return nil }
            self = .part(id, part)
        default: return nil
        }
    }
}

struct GridTile: Hashable {
    let camera: Camera
    let part: SplitPart
}

struct PlaybackRequest: Equatable {
    let id = UUID()
    let cameraID: Camera.ID
    let date: Date
}

struct RenameRequest {
    let cameraID: Camera.ID
    let part: SplitPart
    var text: String
}

struct SidebarNode: Identifiable, Hashable {
    let id: SidebarItem
    let title: String
    let icon: String
    var children: [SidebarNode]?
}
