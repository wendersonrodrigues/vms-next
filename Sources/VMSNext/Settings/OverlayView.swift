import SwiftUI

/// "Texto na imagem" (Sobrepor no VMS antigo): nome do canal, data/hora, máscaras de privacidade e texto
/// extra sobre o vídeo, editados sobre a imagem ao vivo.
/// - AVEnc.VideoWidget.[canal]: ChannelTitleAttribute / TimeTitleAttribute (PreviewBlend = ao vivo,
///   EncodeBlend = gravações, RelativePos[0…1] = x, y em 0–8192) e Covers (máscaras; RelativePos =
///   esquerda, topo, direita, base; CoversNum = quantas estão em uso).
/// - ChannelTitle: lista com o nome de cada canal.
/// - fVideo.OSDInfo: até 6 linhas de texto livre com a mesma ideia de visibilidade e posição.
@MainActor
final class OverlayModel: ObservableObject {
    struct Title {
        var live: Bool
        var recorded: Bool
        var position: CGPoint
    }

    static let scale: CGFloat = 8192

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var diagnosticText: String?

    @Published var channelTitle: Title?
    @Published var timeTitle: Title?
    @Published var channelName: String?

    @Published private(set) var maxMasks = 0
    @Published var masks: [CGRect] = []

    @Published private(set) var hasExtraText = false
    @Published var extraLines: [String] = []
    @Published var extraTitle = Title(live: false, recorded: false, position: .zero)

    let camera: Camera
    private var widgetRaw: Any?
    private var titlesRaw: [Any]?
    private var osdRaw: Any?
    private var originalName: String?
    private var widgetName: String { "AVEnc.VideoWidget.[\(camera.channel - 1)]" }

    init(camera: Camera) {
        self.camera = camera
    }

    var canAddMask: Bool { masks.count < maxMasks }

    func addMask() {
        guard canAddMask else { return }
        masks.append(CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3))
    }

    func removeMask(at index: Int) {
        guard masks.indices.contains(index) else { return }
        masks.remove(at: index)
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            widgetRaw = try? await client.getConfig(widgetName)
            if let widget = ConfigValue.object(in: widgetRaw) {
                channelTitle = Self.title(widget["ChannelTitleAttribute"])
                timeTitle = Self.title(widget["TimeTitleAttribute"])
                let covers = widget["Covers"] as? [[String: Any]] ?? []
                maxMasks = covers.count
                let active = min(ConfigValue.int(widget["CoversNum"]) ?? 0, covers.count)
                masks = covers.prefix(active).map { Self.rect($0["RelativePos"]) }
            }
            titlesRaw = await Self.readTitles(client)
            if let titles = titlesRaw, titles.indices.contains(camera.channel - 1) {
                channelName = Self.name(titles[camera.channel - 1])
                originalName = channelName
            }
            osdRaw = try? await client.getConfig("fVideo.OSDInfo")
            // O VMS antigo só mostra o texto extra com SupportOSDInfo, mas ele funciona nas câmeras testadas
            // sem essa capacidade; o VMS Next mostra sempre que a câmera tiver o fVideo.OSDInfo.
            if let osd = ConfigValue.object(in: osdRaw), let first = (osd["OSDInfo"] as? [[String: Any]])?.first {
                extraLines = (first["Info"] as? [String]) ?? []
                hasExtraText = true
                if let widget = first["OSDInfoWidget"] { extraTitle = Self.title(widget) ?? extraTitle }
            }
            if channelTitle == nil && timeTitle == nil && channelName == nil {
                error = "Este equipamento não informou o texto sobre a imagem. Use \"Diagnóstico…\" e me envie o resultado."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply() async {
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let name = channelName?.trimmingCharacters(in: .whitespaces)
            if let raw = widgetRaw, var widget = ConfigValue.object(in: raw) {
                Self.write(channelTitle, into: &widget, key: "ChannelTitleAttribute")
                Self.write(timeTitle, into: &widget, key: "TimeTitleAttribute")
                if var covers = widget["Covers"] as? [[String: Any]] {
                    for index in covers.indices {
                        let active = index < masks.count
                        covers[index]["PreviewBlend"] = active
                        covers[index]["EncodeBlend"] = active
                        if active { covers[index]["RelativePos"] = Self.devicePos(masks[index]) }
                    }
                    widget["Covers"] = covers
                    widget["CoversNum"] = masks.count
                }
                if let name, var title = widget["ChannelTitle"] as? [String: Any] {
                    title["Name"] = name
                    widget["ChannelTitle"] = title
                }
                let updated = ConfigValue.replacingObject(in: raw, with: widget)
                try await client.setConfig(widgetName, updated)
                widgetRaw = updated
            }
            if let name, name != originalName, var titles = titlesRaw, titles.indices.contains(camera.channel - 1) {
                titles[camera.channel - 1] = Self.replacingName(titles[camera.channel - 1], with: name)
                do {
                    try await client.setConfig("ChannelTitle", titles)
                } catch DVRIPError.device {
                    // Alguns firmwares só aceitam o nome pelo comando próprio (CHANNELTITLE_SET, 1046).
                    try await client.command(code: 1046, name: "ChannelTitle", payload: titles)
                }
                titlesRaw = titles
                originalName = name
            }
            if hasExtraText, let raw = osdRaw, var osd = ConfigValue.object(in: raw),
               var items = osd["OSDInfo"] as? [[String: Any]], !items.isEmpty {
                items[0]["Info"] = extraLines
                if var widget = items[0]["OSDInfoWidget"] as? [String: Any] {
                    widget["PreviewBlend"] = extraTitle.live
                    widget["EncodeBlend"] = extraTitle.recorded
                    // A caixa do texto extra guarda esquerda/topo/direita/base: move sem mudar o tamanho.
                    if var pos = widget["RelativePos"] as? [Int], pos.count >= 4 {
                        let width = pos[2] - pos[0], height = pos[3] - pos[1]
                        pos[0] = Self.device(extraTitle.position.x)
                        pos[1] = Self.device(extraTitle.position.y)
                        pos[2] = min(pos[0] + width, Int(Self.scale))
                        pos[3] = min(pos[1] + height, Int(Self.scale))
                        widget["RelativePos"] = pos
                    }
                    items[0]["OSDInfoWidget"] = widget
                }
                osd["OSDInfo"] = items
                let updated = ConfigValue.replacingObject(in: raw, with: osd)
                try await client.setConfig("fVideo.OSDInfo", updated)
                osdRaw = updated
            }
            notice = "Texto na imagem aplicado."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: [
            (1042, widgetName), (1042, "ChannelTitle"), (1048, "ChannelTitle"), (1042, "fVideo.OSDInfo"),
        ])
    }

    // MARK: - Conversões

    private static func readTitles(_ client: DVRIPClient) async -> [Any]? {
        if let list = try? await client.getConfig("ChannelTitle") as? [Any] { return list }
        if let response = try? await client.command(code: 1048, name: "ChannelTitle", payload: nil),
           let list = response["ChannelTitle"] as? [Any] { return list }
        return nil
    }

    private static func title(_ raw: Any?) -> Title? {
        guard let attribute = raw as? [String: Any] else { return nil }
        let pos = (attribute["RelativePos"] as? [Any])?.compactMap(ConfigValue.int) ?? []
        return Title(live: (attribute["PreviewBlend"] as? Bool) ?? false,
                     recorded: (attribute["EncodeBlend"] as? Bool) ?? false,
                     position: pos.count >= 2 ? CGPoint(x: CGFloat(pos[0]) / scale, y: CGFloat(pos[1]) / scale) : .zero)
    }

    private static func write(_ title: Title?, into widget: inout [String: Any], key: String) {
        guard let title, var attribute = widget[key] as? [String: Any] else { return }
        attribute["PreviewBlend"] = title.live
        attribute["EncodeBlend"] = title.recorded
        if var pos = (attribute["RelativePos"] as? [Any])?.compactMap(ConfigValue.int), pos.count >= 2 {
            pos[0] = device(title.position.x)
            pos[1] = device(title.position.y)
            attribute["RelativePos"] = pos
        }
        widget[key] = attribute
    }

    /// Máscara: esquerda, topo, direita, base → retângulo normalizado.
    private static func rect(_ raw: Any?) -> CGRect {
        let pos = (raw as? [Any])?.compactMap(ConfigValue.int) ?? []
        guard pos.count >= 4 else { return CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3) }
        return CGRect(x: CGFloat(pos[0]) / scale, y: CGFloat(pos[1]) / scale,
                      width: CGFloat(pos[2] - pos[0]) / scale, height: CGFloat(pos[3] - pos[1]) / scale)
    }

    private static func devicePos(_ rect: CGRect) -> [Int] {
        [device(rect.minX), device(rect.minY), device(rect.maxX), device(rect.maxY)]
    }

    static func device(_ value: CGFloat) -> Int {
        Int((min(max(value, 0), 1) * scale).rounded())
    }

    private static func name(_ raw: Any) -> String? {
        if let text = raw as? String { return text }
        return (raw as? [String: Any])?["Name"] as? String
    }

    private static func replacingName(_ raw: Any, with name: String) -> Any {
        if var dict = raw as? [String: Any] {
            dict["Name"] = name
            return dict
        }
        return name
    }
}

struct OverlayView: View {
    let camera: Camera
    @StateObject private var model: OverlayModel
    @StateObject private var stream = LiveStream()
    @StateObject private var drag = DragTracker()
    @EnvironmentObject private var store: CameraStore

    /// Ponto de partida de cada arraste (não precisa redesenhar a tela).
    final class DragTracker: ObservableObject {
        var origin: [String: CGRect] = [:]
    }

    init(camera: Camera) {
        self.camera = camera
        _model = StateObject(wrappedValue: OverlayModel(camera: camera))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        preview
                    } footer: {
                        Text("Arraste o nome do canal, a data/hora, o texto extra e as máscaras para posicionar. Puxe o canto de uma máscara para mudar o tamanho.")
                            .foregroundStyle(.secondary)
                    }
                    if model.channelName != nil || model.channelTitle != nil {
                        Section("Nome do canal") {
                            if model.channelName != nil {
                                TextField(text: Binding(get: { model.channelName ?? "" }, set: { model.channelName = $0 })) {
                                    FieldLabel("Texto", original: "Nome do canal",
                                               detail: "Nome escrito sobre a imagem.")
                                }
                            }
                            if model.channelTitle != nil {
                                visibility(Binding(get: { model.channelTitle! }, set: { model.channelTitle = $0 }), original: "Exibição do canal")
                            }
                        }
                    }
                    if model.timeTitle != nil {
                        Section("Data e hora") {
                            visibility(Binding(get: { model.timeTitle! }, set: { model.timeTitle = $0 }), original: "Exibição do horário")
                        }
                    }
                    if model.maxMasks > 0 { masksSection }
                    if model.hasExtraText { extraTextSection }
                    if let error = model.error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            SettingsFooter(notice: model.notice, busy: model.loading || model.saving, applyDisabled: (model.channelTitle == nil && model.timeTitle == nil && model.channelName == nil),
                           onDiagnostic: { model.diagnosticText = await model.diagnostic() },
                           onReload: { await model.load() },
                           onApply: { Task { await model.apply() } })
        }
        .task { await model.load() }
        .onAppear {
            stream.displayLayer.videoGravity = .resize
            stream.start(camera: camera, quality: .sub, password: store.password(for: camera),
                         source: store.resolvedLiveSource(for: camera))
        }
        .onDisappear { stream.stop() }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    // MARK: - Imagem com os elementos arrastáveis

    private var preview: some View {
        let size = stream.videoSize ?? CGSize(width: 16, height: 9)
        return ZStack {
            VideoLayerView(layer: stream.displayLayer)
            GeometryReader { proxy in
                let frame = proxy.size
                ZStack(alignment: .topLeading) {
                    ForEach(model.masks.indices, id: \.self) { index in
                        maskView(index, frame: frame)
                    }
                    if let title = model.channelTitle {
                        tag(model.channelName ?? "Canal", key: "channel", origin: title.position, frame: frame) { model.channelTitle?.position = $0 }
                    }
                    if let title = model.timeTitle {
                        tag(Date().formatted(date: .numeric, time: .standard), key: "time", origin: title.position, frame: frame) { model.timeTitle?.position = $0 }
                    }
                    if model.hasExtraText, model.extraLines.contains(where: { !$0.isEmpty }) {
                        tag(model.extraLines.filter { !$0.isEmpty }.joined(separator: "\n"), key: "extra",
                            origin: model.extraTitle.position, frame: frame) { model.extraTitle.position = $0 }
                    }
                }
            }
            .coordinateSpace(name: "overlay")
            if stream.videoSize == nil {
                ProgressView("Carregando imagem…").tint(.white).foregroundStyle(.white)
            }
        }
        .aspectRatio(size, contentMode: .fit)
        .frame(maxHeight: 360)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Radius.small))
        .frame(maxWidth: .infinity)
    }

    private func tag(_ text: String, key: String, origin: CGPoint, frame: CGSize, move: @escaping (CGPoint) -> Void) -> some View {
        Text(text)
            .font(.system(size: max(10, frame.height * 0.035), weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, Space.xs)
            .background(Color.black.opacity(0.45))
            .overlay(Rectangle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .offset(x: origin.x * frame.width, y: origin.y * frame.height)
            .gesture(
                DragGesture(coordinateSpace: .named("overlay"))
                    .onChanged { value in
                        let start = drag.origin[key]?.origin ?? origin
                        if drag.origin[key] == nil { drag.origin[key] = CGRect(origin: origin, size: .zero) }
                        move(Self.clamp(CGPoint(x: start.x + value.translation.width / frame.width,
                                                y: start.y + value.translation.height / frame.height)))
                    }
                    .onEnded { _ in drag.origin[key] = nil }
            )
    }

    private func maskView(_ index: Int, frame: CGSize) -> some View {
        let rect = model.masks.indices.contains(index) ? model.masks[index] : .zero
        let key = "mask\(index)"
        return ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color.black.opacity(0.75))
                .overlay(Rectangle().stroke(Color.orange, lineWidth: 1.5))
                .overlay(Text("Máscara \(index + 1)").font(.caption).foregroundStyle(.white.opacity(0.8)))
            Rectangle()
                .fill(Color.orange)
                .frame(width: 12, height: 12)
                .gesture(
                    DragGesture(coordinateSpace: .named("overlay"))
                        .onChanged { value in
                            let start = drag.origin[key + "size"] ?? rect
                            if drag.origin[key + "size"] == nil { drag.origin[key + "size"] = rect }
                            var updated = start
                            updated.size.width = max(0.04, min(1 - start.minX, start.width + value.translation.width / frame.width))
                            updated.size.height = max(0.04, min(1 - start.minY, start.height + value.translation.height / frame.height))
                            if model.masks.indices.contains(index) { model.masks[index] = updated }
                        }
                        .onEnded { _ in drag.origin[key + "size"] = nil }
                )
        }
        .frame(width: rect.width * frame.width, height: rect.height * frame.height)
        .offset(x: rect.minX * frame.width, y: rect.minY * frame.height)
        .gesture(
            DragGesture(coordinateSpace: .named("overlay"))
                .onChanged { value in
                    let start = drag.origin[key] ?? rect
                    if drag.origin[key] == nil { drag.origin[key] = rect }
                    var updated = start
                    updated.origin.x = min(max(start.minX + value.translation.width / frame.width, 0), 1 - start.width)
                    updated.origin.y = min(max(start.minY + value.translation.height / frame.height, 0), 1 - start.height)
                    if model.masks.indices.contains(index) { model.masks[index] = updated }
                }
                .onEnded { _ in drag.origin[key] = nil }
        )
        .contextMenu {
            Button("Remover máscara \(index + 1)", role: .destructive) { model.removeMask(at: index) }
        }
    }

    private static func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 0.97), y: min(max(point.y, 0), 0.97))
    }

    // MARK: - Seções

    @ViewBuilder
    private func visibility(_ title: Binding<OverlayModel.Title>, original: String) -> some View {
        Toggle(isOn: title.live) {
            FieldLabel("Mostrar no ao vivo", original: original, detail: "Aparece no vídeo ao vivo (VMS Next, iCSee e monitor).")
        }
        Toggle(isOn: title.recorded) {
            FieldLabel("Gravar junto no vídeo", detail: "Fica marcado nas gravações e nos downloads; útil como prova.")
        }
    }

    private var masksSection: some View {
        Section {
            if model.masks.isEmpty {
                Text("Nenhuma máscara.").foregroundStyle(.secondary)
            }
            ForEach(model.masks.indices, id: \.self) { index in
                HStack {
                    Text("Máscara \(index + 1)")
                    Spacer()
                    Button(role: .destructive) { model.removeMask(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Apagar a máscara \(index + 1)")
                        .accessibilityLabel("Apagar a máscara \(index + 1)")
                }
            }
            Button {
                model.addMask()
            } label: {
                Label("Adicionar máscara", systemImage: "plus")
            }
            .disabled(!model.canAddMask)
        } header: {
            Text("Máscaras de privacidade (Máscara privac.)")
        } footer: {
            Text("Retângulos pretos que escondem partes da imagem, como a janela de um vizinho. Ficam escondidas também nas gravações. Até \(model.maxMasks).")
                .foregroundStyle(.secondary)
        }
    }

    private var extraTextSection: some View {
        Section {
            ForEach(0 ..< max(6, model.extraLines.count), id: \.self) { line in
                TextField("Linha \(line + 1)", text: Binding(
                    get: { model.extraLines.indices.contains(line) ? model.extraLines[line] : "" },
                    set: { value in
                        while model.extraLines.count <= line { model.extraLines.append("") }
                        model.extraLines[line] = value
                    }
                ))
            }
            visibility($model.extraTitle, original: "OSD Enable")
        } header: {
            Text("Texto extra (OSD)")
        } footer: {
            Text("Até \(max(6, model.extraLines.count)) linhas de texto livre sobre a imagem, como endereço ou telefone. Não existe no VMS antigo.")
                .foregroundStyle(.secondary)
        }
    }
}
