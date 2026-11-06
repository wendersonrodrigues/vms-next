import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Estado da tela de gravações: equipamento/canal, dia e resultado da busca.
@MainActor
final class RecordingBrowser: ObservableObject {
    @Published var day = Date()
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var searching = false
    @Published var message: String?
    @Published var selected: Recording.ID?
    /// Horário do alerta aberto pelo ▶ (marca vermelha na linha do tempo).
    @Published var alarmMarker: Date?
    @Published var diagnosticText: String?
    @Published private(set) var downloads: [RecordingDownload] = []
    /// Resultado da última foto do quadro.
    @Published var photoMessage: String?
    /// Stream buscado: 0 = principal (Main), 1 = extra (Extra), como no VMS antigo.
    @Published var stream = 0
    /// Buscar fotos (Type "jpg") em vez de vídeos.
    @Published var photos = false
    /// Foto aberta no lugar do vídeo.
    @Published private(set) var photo: NSImage?
    @Published private(set) var photoRecording: Recording?
    @Published private(set) var photoLoading = false
    private var photoData: Data?
    /// NVR inteiro: gravações do dia de cada canal e o canal escolhido (o que toca, lista e baixa).
    @Published private(set) var channelRecordings: [Camera.ID: [Recording]] = [:]
    @Published private(set) var groupChannel: Camera.ID?
    /// Abrindo um alerta de Eventos: a busca automática espera.
    var openingRequest = false
    /// Marca a gravação na lista sem disparar a reprodução do início (ela já toca no momento do alerta).
    private(set) var suppressPlay = false

    func selectWithoutPlaying(_ id: Recording.ID) {
        suppressPlay = true
        selected = id
    }

    func consumeSuppressedPlay() -> Bool {
        defer { suppressPlay = false }
        return suppressPlay
    }

    /// Baixa a gravação em MP4 (ou a foto em JPEG) direto na pasta de downloads das Preferências, com a câmera, o dia,
    /// o horário e o tipo no nome. Já baixada por inteiro, mostra o arquivo no Finder; `again` baixa outra cópia.
    /// Uma gravação baixada enquanto ainda gravava (o arquivo cresceu depois) é baixada de novo sem perguntar.
    func download(_ recording: Recording, camera: Camera, again: Bool = false) {
        let saved = DownloadedRecordings.shared
        if !again, !saved.isPartial(recording, camera: camera), let existing = saved.file(of: recording, camera: camera) {
            NSWorkspace.shared.activateFileViewerSelecting([existing])
            return
        }
        if recording.isPhoto {
            Task { await savePhoto(recording, camera: camera) }
            return
        }
        if downloads.contains(where: { $0.state == .running && $0.recording.id == recording.id && $0.camera.id == camera.id }) { return }
        let prefs = AppPreferences.shared
        let extra = recording.stream == 1 ? " Extra" : ""
        guard let url = prefs.destination(named: "\(camera.displayName) \(AppPreferences.stamp(recording.begin)) \(recording.kind.label)\(extra)",
                                          in: prefs.downloadFolder, type: .mpeg4Movie, ask: false) else { return }
        let job = RecordingDownload(recording: recording, camera: camera, url: url)
        downloads.insert(job, at: 0)
        AppLog.shared.add(.file, "Download de gravação: \(url.lastPathComponent)", device: camera.displayName)
        Task { await job.start() }
    }

    func removeFinishedDownloads() {
        downloads.removeAll { $0.state != .running }
    }

    // MARK: - Fotos

    /// Abre a foto no lugar do vídeo.
    func showPhoto(_ recording: Recording, camera: Camera) async {
        photoRecording = recording
        photo = nil
        photoData = nil
        photoMessage = nil
        photoLoading = true
        defer { photoLoading = false }
        do {
            let data = try await RecordingPhoto.fetch(recording, camera: camera)
            guard photoRecording?.id == recording.id else { return }
            photoData = data
            photo = NSImage(data: data)
            if photo == nil { photoMessage = String(localized: "A foto veio num formato que o Mac não abre.") }
        } catch {
            if photoRecording?.id == recording.id { photoMessage = error.localizedDescription }
        }
    }

    func closePhoto() {
        photoRecording = nil
        photo = nil
        photoData = nil
    }

    private func savePhoto(_ recording: Recording, camera: Camera) async {
        do {
            let data = photoRecording?.id == recording.id && photoData != nil ? photoData! : try await RecordingPhoto.fetch(recording, camera: camera)
            let prefs = AppPreferences.shared
            guard let url = prefs.destination(named: "\(camera.displayName) \(AppPreferences.stamp(recording.begin)) \(recording.kind.label)",
                                              in: prefs.downloadFolder, type: .jpeg, ask: false) else { return }
            try data.write(to: url, options: .atomic)
            DownloadedRecordings.shared.mark(recording, camera: camera, url: url)
            AppLog.shared.add(.file, "Download de foto: \(url.lastPathComponent)", device: camera.displayName)
            photoMessage = String(localized: "Foto salva: \(url.lastPathComponent)")
        } catch {
            photoMessage = error.localizedDescription
        }
    }

    // MARK: - NVR inteiro

    /// Busca o dia de todos os canais do NVR, um depois do outro na mesma sessão. Canais sem gravação ou que
    /// recusam a busca ficam com a linha vazia.
    func searchGroup(channels: [Camera]) async {
        searching = true
        message = nil
        recordings = []
        channelRecordings = [:]
        defer { searching = false }
        guard let first = channels.first else { return }
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86_399)
        do {
            let client = try await DeviceSessions.shared.client(for: first)
            for channel in channels {
                var found: [Recording] = []
                for type in photos ? ["jpg"] : ["h264", "h265", "*"] {
                    do {
                        found = try await client.findRecordings(channel: channel.channel - 1, from: start, to: end, type: type, stream: stream)
                        break
                    } catch DVRIPError.device {
                        continue
                    }
                }
                channelRecordings[channel.id] = found
            }
        } catch {
            message = error.localizedDescription
        }
        if groupChannel == nil || !channels.contains(where: { $0.id == groupChannel }) {
            groupChannel = channels.first { !(channelRecordings[$0.id] ?? []).isEmpty }?.id ?? first.id
        }
        recordings = groupChannel.flatMap { channelRecordings[$0] } ?? []
        if channelRecordings.values.allSatisfy(\.isEmpty), message == nil {
            message = photos ? String(localized: "Nenhuma foto neste dia.") : String(localized: "Nenhuma gravação neste dia.")
        }
    }

    /// Escolhe o canal do NVR cuja linha foi clicada: a lista, as setas e o download passam a ser dele.
    func selectChannel(_ id: Camera.ID) {
        guard groupChannel != id else { return }
        groupChannel = id
        recordings = channelRecordings[id] ?? []
        selected = nil
    }

    func leaveGroup() {
        channelRecordings = [:]
        groupChannel = nil
    }

    /// Testa variações da busca no dia escolhido e lê os discos do equipamento,
    /// mostrando o código de resposta de cada tentativa. Só leitura.
    func diagnose(camera: Camera) async -> String {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86_399)
        var output = String(localized: "Busca de gravações: \(camera.displayName) · canal \(camera.channel) · \(DeviceTime.string(start).prefix(10))\n")
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let anyRet = Set(0 ..< 1000)

            output += "\n== StorageInfo\n"
            if let storage = try? await client.command(code: 1020, name: "StorageInfo", payload: nil, accepted: anyRet) {
                let value = storage["StorageInfo"] ?? storage
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                output += data.map { String(decoding: $0, as: UTF8.self) } ?? String(localized: "(ilegível)")
                output += "\n"
            } else {
                output += String(localized: "(sem resposta)\n")
            }

            output += String(localized: "\n== OPFileQuery (tipo · stream · máscara → código, arquivos)\n")
            for type in ["h264", "h265"] {
                for stream in ["0x00000000", "0x00000001"] {
                    for mask in ["0x0000FFFF", "0xFFFFFFFF"] {
                        let line = "\(type) · \(stream) · \(mask)"
                        do {
                            let r = try await client.command(code: 1440, name: "OPFileQuery", payload: [
                                "BeginTime": DeviceTime.string(start), "EndTime": DeviceTime.string(end),
                                "Channel": camera.channel - 1, "DriverTypeMask": mask, "Event": "*",
                                "Type": type, "StreamType": stream,
                            ], accepted: anyRet)
                            let count = (r["OPFileQuery"] as? [Any])?.count ?? 0
                            output += "\(line) → \(r["Ret"] ?? "?"), \(count)\n"
                        } catch {
                            output += "\(line) → erro: \(error.localizedDescription)\n"
                            if case DVRIPError.timeout = error { return output }
                        }
                    }
                }
            }
        } catch {
            output += String(localized: "\nFalha ao conectar: \(error.localizedDescription)\n")
        }
        return output
    }

    func search(camera: Camera) async {
        searching = true
        message = nil
        recordings = []
        defer { searching = false }
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86_399)
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            // Alguns NVRs recusam o tipo "h264" para canais H.265; tenta as variantes e
            // mostra os códigos de cada uma se todas forem recusadas.
            var refusals: [String] = []
            for type in photos ? ["jpg"] : ["h264", "h265", "*"] {
                do {
                    recordings = try await client.findRecordings(channel: camera.channel - 1, from: start, to: end, type: type, stream: stream)
                    refusals.removeAll()
                    break
                } catch let DVRIPError.device(code) {
                    refusals.append("\(type): \(code)")
                }
            }
            if !refusals.isEmpty {
                message = String(localized: "O equipamento recusou a busca no canal \(camera.channel) (códigos — \(refusals.joined(separator: ", ")).")
            } else if recordings.isEmpty {
                message = photos ? String(localized: "Nenhuma foto neste dia.") : String(localized: "Nenhuma gravação neste dia.")
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Calendário e lista de arquivos abertos (ObservableObject no lugar de @State, que precisa do Xcode).
final class PlaybackPopovers: ObservableObject {
    @Published var calendar = false
    @Published var list = false
    @Published var tags = false
    /// Câmera com cartão e NVR: de qual buscar agora (começa pelo NVR).
    @Published var useCard = false
}

struct PlaybackView: View {
    /// Câmera escolhida na lista ao lado da janela principal.
    let cameraID: Camera.ID?
    /// NVR escolhido na lista (o grupo, sem um canal): linha do tempo de todos os canais.
    var recorder: String? = nil
    /// Vindo de Eventos: abre a gravação que contém este momento.
    @Binding var request: PlaybackRequest?

    @EnvironmentObject private var store: CameraStore
    @StateObject private var browser = RecordingBrowser()
    @StateObject private var session = PlaybackSession()
    @StateObject private var zoom = DigitalZoom()
    @StateObject private var popovers = PlaybackPopovers()
    @StateObject private var timelineZoom = TimelineZoom()
    @ObservedObject private var tags = RecordingTags.shared
    @ObservedObject private var downloaded = DownloadedRecordings.shared
    /// Vídeo em foco: espaço toca/pausa, ← e → voltam e avançam 10 s (sem atrapalhar a lista e os campos).
    @FocusState private var playerFocused: Bool

    private var selectedCamera: Camera? {
        if isGroup { return groupChannels.first { $0.id == browser.groupChannel } }
        return store.cameras.first { $0.id == cameraID }
    }

    /// NVR inteiro escolhido na lista.
    private var isGroup: Bool { cameraID == nil && recorder != nil }
    private var groupChannels: [Camera] { recorder.map { store.channels(in: $0) } ?? [] }

    /// Equipamento onde a busca é feita: a câmera escolhida ou, se ela grava no NVR, o canal ligado a ela.
    /// Com cartão e NVR, segue a chave do cabeçalho.
    private var camera: Camera? {
        guard let selected = selectedCamera else { return nil }
        guard let channel = store.linkedChannel(for: selected) else { return selected }
        switch selected.recordingsFrom {
        case .camera: return selected
        case .nvr: return channel
        case .both: return popovers.useCard ? selected : channel
        }
    }

    /// Câmera com gravação nos dois lugares (e um canal do NVR ligado): mostra a chave Cartão | NVR.
    private var hasBothSources: Bool {
        guard let selected = selectedCamera else { return false }
        return selected.recordingsFrom == .both && store.linkedChannel(for: selected) != nil
    }

    private var fromNVR: Bool { camera?.id != selectedCamera?.id }

    var body: some View {
        // Vídeo em cima e a linha do tempo do dia embaixo, na largura toda: nada de painel com largura fixa,
        // que em janela estreita empurrava a lista de câmeras para fora.
        VStack(spacing: 0) {
            player
            timelinePanel
        }
        .onDisappear { session.stop() }
        // A câmera vem da lista ao lado: ao trocar de câmera ou de dia, busca de novo.
        .task(id: searchKey) {
            guard !browser.openingRequest else { return }
            browser.closePhoto()
            if isGroup {
                await browser.searchGroup(channels: groupChannels)
            } else if let camera {
                await browser.search(camera: camera)
            }
        }
        .onChange(of: cameraID) {
            popovers.useCard = false
            browser.alarmMarker = nil
        }
        .onChange(of: recorder) { if !isGroup { browser.leaveGroup() } }
        .onChange(of: session.clock) {
            if let clock = session.clock { timelineZoom.reveal(clock.timeIntervalSince(Calendar.current.startOfDay(for: browser.day))) }
        }
        .onAppear(perform: openRequest)
        .onChange(of: request) { openRequest() }
        .sheet(isPresented: Binding(get: { browser.diagnosticText != nil }, set: { if !$0 { browser.diagnosticText = nil } })) {
            DiagnosticSheet(text: browser.diagnosticText ?? "")
        }
    }

    /// Muda a câmera (ou o NVR inteiro), o dia, o stream ou vídeo/foto: busca de novo. No NVR, trocar de canal
    /// não busca (as linhas de todos já estão carregadas).
    private var searchKey: String {
        let target = isGroup ? "nvr:\(recorder ?? "")" : (camera?.id.uuidString ?? "")
        return "\(target)-\(Calendar.current.startOfDay(for: browser.day).timeIntervalSince1970)-\(browser.stream)-\(browser.photos)"
    }

    // MARK: - Linha do tempo e data

    private var isToday: Bool { Calendar.current.isDateInToday(browser.day) }

    /// Main | Extra e Vídeo | Foto, como na busca do VMS antigo.
    private var sourcePickers: some View {
        HStack(spacing: Space.s) {
            Picker("Stream", selection: $browser.stream) {
                Text("Main").tag(0)
                Text("Extra").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("Gravações do stream principal (Main, alta qualidade) ou do extra (Extra, menor), como no VMS antigo")
            Picker("Tipo de arquivo", selection: $browser.photos) {
                Text("Vídeo").tag(false)
                Text("Foto").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("Mostrar os vídeos ou as fotos guardadas no equipamento")
        }
    }

    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                if isGroup, let recorder {
                    Label { Text(recorder) } icon: { Image(systemName: "server.rack") }.font(.headline).lineLimit(1)
                    if let camera {
                        Text(camera.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    sourcePickers
                } else if let camera {
                    Label { Text(camera.displayName) } icon: { CameraGlyph() }.font(.headline).lineLimit(1)
                    sourcePickers
                    if hasBothSources {
                        Picker("Origem", selection: $popovers.useCard) {
                            Text("NVR").tag(false)
                            Text("Cartão").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .controlSize(.small)
                        .help("Buscar as gravações no NVR ou no cartão da câmera")
                    } else if fromNVR, let selectedCamera {
                        Text("gravações de \(selectedCamera.name) no NVR")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Esta câmera está configurada para buscar as gravações no NVR (Editar câmera → Gravações).")
                    }
                } else {
                    Label("Escolha uma câmera ou canal na lista ao lado.", systemImage: "arrow.left")
                        .foregroundStyle(.secondary)
                }
                if browser.searching { ProgressView().controlSize(.small) }
                Spacer(minLength: Space.s)
                ViewThatFits(in: .horizontal) {
                    kindSteppers
                    RecordingLegend(recordings: browser.recordings)
                }
                if let camera {
                    RecordingTagButton(count: currentRecording.map { tags.tags(of: $0, camera: camera).count } ?? 0) {
                        popovers.tags = true
                    }
                    .popover(isPresented: $popovers.tags, arrowEdge: .top) {
                        RecordingTagsPopover(camera: camera, current: currentRecording) { item in
                            popovers.tags = false
                            open(camera: camera, at: item.begin, exact: true)
                        }
                    }
                }
            }
            if isGroup {
                channelTimelines
                    .padding(.top, Space.xs)
            } else if let camera {
                RecordingTimeline(day: browser.day, recordings: browser.recordings, playhead: session.clock,
                                  alarm: browser.alarmMarker,
                                  tagged: tags.taggedFiles(in: browser.recordings, camera: camera),
                                  downloaded: downloaded.downloadedFiles(in: browser.recordings, camera: camera),
                                  zoom: timelineZoom) { date, kind, tolerance in
                    play(at: date, preferring: kind, tolerance: tolerance)
                }
                .padding(.top, Space.xs)
            }
            if let message = browser.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            dateBar
            if !browser.downloads.isEmpty { downloadsRow }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    /// NVR inteiro: uma linha por canal, todas na mesma régua e no mesmo zoom. Clicar numa linha escolhe o canal
    /// e toca dali (um canal por vez).
    private var channelTimelines: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(groupChannels.enumerated()), id: \.element.id) { index, channel in
                let chosen = channel.id == browser.groupChannel
                HStack(alignment: .bottom, spacing: Space.s) {
                    Button {
                        browser.selectChannel(channel.id)
                    } label: {
                        Text(channel.name)
                            .font(.caption.weight(chosen ? .semibold : .regular))
                            .foregroundStyle(chosen ? Theme.accent : .secondary)
                            .lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                    .help("Escolher \(channel.name): a lista de arquivos, as setas e o download passam a ser deste canal")
                    let list = browser.channelRecordings[channel.id] ?? []
                    RecordingTimeline(day: browser.day, recordings: list, playhead: chosen ? session.clock : nil,
                                      alarm: chosen ? browser.alarmMarker : nil,
                                      tagged: tags.taggedFiles(in: list, camera: channel),
                                      downloaded: downloaded.downloadedFiles(in: list, camera: channel),
                                      zoom: timelineZoom, merged: true, showsRuler: index == 0) { date, kind, tolerance in
                        browser.selectChannel(channel.id)
                        play(at: date, preferring: kind, tolerance: tolerance)
                    }
                }
                .padding(.horizontal, Space.xs)
                .background(RoundedRectangle(cornerRadius: Radius.small).fill(chosen ? Theme.accent.opacity(0.08) : .clear))
            }
        }
    }

    /// ‹ dia ›, a data (clique abre o calendário) e Hoje; à direita, buscar de novo e mais opções.
    private var dateBar: some View {
        HStack(spacing: Space.s) {
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .help("Dia anterior")
                .accessibilityLabel("Dia anterior")
            Button {
                popovers.calendar = true
            } label: {
                Label(browser.day.formatted(date: .complete, time: .omitted), systemImage: "calendar")
                    .lineLimit(1)
            }
            .help("Escolher o dia no calendário")
            .popover(isPresented: $popovers.calendar, arrowEdge: .top) {
                if let camera {
                    RecordingCalendar(camera: camera, selected: browser.day) { date in
                        browser.day = date
                        popovers.calendar = false
                    }
                } else {
                    DatePicker("Dia", selection: Binding(get: { browser.day }, set: { browser.day = $0; popovers.calendar = false }),
                               in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(Space.m)
                }
            }
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .disabled(isToday)
                .help("Próximo dia")
                .accessibilityLabel("Próximo dia")
            Button("Hoje") { browser.day = Date() }
                .buttonStyle(.borderedProminent)
                .disabled(isToday)
            Spacer(minLength: Space.s)
            TimelineZoomControls(zoom: timelineZoom)
            Button {
                Task {
                    if isGroup {
                        await browser.searchGroup(channels: groupChannels)
                    } else if let camera {
                        await browser.search(camera: camera)
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled((camera == nil && !isGroup) || browser.searching)
            .help("Buscar de novo")
            .accessibilityLabel("Buscar de novo")
            Button {
                popovers.list = true
            } label: {
                Label("Arquivos (\(browser.recordings.count))", systemImage: "list.bullet")
            }
            .disabled(browser.recordings.isEmpty)
            .help("Lista dos arquivos gravados no dia, para tocar ou baixar um arquivo específico")
            .popover(isPresented: $popovers.list, arrowEdge: .top) { recordingList }
            Menu {
                Button("Diagnóstico da busca…") {
                    guard let camera else { return }
                    Task { browser.diagnosticText = await browser.diagnose(camera: camera) }
                }
                .disabled(camera == nil || browser.searching)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Mais opções")
            .accessibilityLabel("Mais opções")
        }
    }

    private var recordingList: some View {
        List(browser.recordings, selection: $browser.selected) { recording in
            let saved = camera.flatMap { downloaded.file(of: recording, camera: $0) }
            let partial = camera.map { downloaded.isPartial(recording, camera: $0) } ?? false
            RecordingRow(recording: recording, downloaded: saved != nil, partial: partial,
                         onDownload: { again in if let camera { browser.download(recording, camera: camera, again: again) } },
                         onReveal: { if let saved { NSWorkspace.shared.activateFileViewerSelecting([saved]) } })
                .tag(recording.id)
                .contextMenu {
                    Button(recording.isPhoto ? "Abrir" : "Reproduzir") { play(recording) }
                    if let saved {
                        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        Button("Baixar de novo") {
                            if let camera { browser.download(recording, camera: camera, again: true) }
                        }
                    } else {
                        Button(recording.isPhoto ? "Baixar a foto" : "Baixar em MP4") {
                            if let camera { browser.download(recording, camera: camera) }
                        }
                    }
                }
        }
        .listStyle(.inset)
        .frame(width: 380, height: 360)
        .onChange(of: browser.selected) {
            if browser.consumeSuppressedPlay() { return }
            if let id = browser.selected, let recording = browser.recordings.first(where: { $0.id == id }) {
                play(recording)
            }
        }
    }

    private var downloadsRow: some View {
        HStack(alignment: .top, spacing: Space.m) {
            ForEach(browser.downloads.prefix(3)) { job in
                DownloadRow(job: job).frame(maxWidth: 260)
            }
            Spacer(minLength: 0)
            Button("Limpar") { browser.removeFinishedDownloads() }
                .controlSize(.small)
                .disabled(!browser.downloads.contains { $0.state != .running })
        }
    }

    private func shiftDay(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: browser.day) else { return }
        browser.day = min(next, Date())
    }

    /// Um ‹ tipo › para cada tipo de gravação que existe no dia.
    private var kindSteppers: some View {
        let present = Set(browser.recordings.map(\.kind))
        let savedToday = camera.map { cam in
            !downloaded.downloadedFiles(in: browser.recordings, camera: cam).isEmpty
        } ?? false
        return HStack(spacing: Space.s) {
            if savedToday {
                // Legenda do tom dos trechos já baixados.
                HStack(spacing: Space.xs) {
                    Capsule().fill(Color.secondary.opacity(0.25)).overlay(Capsule().stroke(Color.secondary, lineWidth: 1.2))
                        .frame(width: 14, height: 8)
                    Text("Baixado")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Trechos em tom mais claro, com contorno, já estão baixados no Mac")
            }
            ForEach(Recording.Kind.timelineOrder.filter { present.contains($0) }, id: \.self) { kind in
                RecordingKindStepper(kind: kind,
                                     canGoBack: neighbor(of: kind, forward: false) != nil,
                                     canGoForward: neighbor(of: kind, forward: true) != nil) { forward in
                    if let match = neighbor(of: kind, forward: forward) {
                        browser.selectWithoutPlaying(match.id)
                        play(match)
                    }
                }
            }
        }
    }

    /// Trecho anterior/seguinte do tipo, a partir do trecho que está tocando (ou do começo/fim do dia, se nada toca).
    /// A referência é o início do trecho atual, não o relógio: logo depois de um salto o relógio ainda está vazio
    /// ou atrasado, e o "anterior" acabava repetindo o mesmo trecho.
    private func neighbor(of kind: Recording.Kind, forward: Bool) -> Recording? {
        let ofKind = browser.recordings.filter { $0.kind == kind }
        let current = session.recording.flatMap { playing in browser.recordings.first { $0.id == playing.id } }
        let reference = current?.begin
            ?? session.clock.flatMap { Calendar.current.isDate($0, inSameDayAs: browser.day) ? $0 : nil }
        if forward {
            return ofKind.filter { $0.begin > (reference ?? .distantPast) }.min { $0.begin < $1.begin }
        }
        return ofKind.filter { $0.begin < (reference ?? .distantFuture) }.max { $0.begin < $1.begin }
    }

    /// Clique na linha do tempo. Numa faixa, toca o trecho daquele tipo (mesmo que outro tipo esteja tocando:
    /// clicar em Movimento durante a Contínua troca para o vídeo do movimento), com ~8 px de folga para acertar
    /// trechos curtos. Fora das faixas (ou na linha única do NVR), o trecho que tem o momento; num vão, o próximo.
    private func play(at date: Date, preferring kind: Recording.Kind?, tolerance: TimeInterval = 0) {
        guard let camera else { return }
        let list = browser.recordings
        var match: Recording?
        if let kind {
            let ofKind = list.filter { $0.kind == kind }
            match = ofKind.first { $0.begin <= date && date <= $0.end }
                ?? ofKind.filter { $0.begin.addingTimeInterval(-tolerance) <= date && date <= $0.end.addingTimeInterval(tolerance) }
                    .min { distance($0, to: date) < distance($1, to: date) }
        }
        if match == nil {
            // Na linha única, o evento (alarme, movimento) vem antes da contínua quando os dois cobrem o momento.
            let order: [Recording.Kind] = [.alarm, .motion, .manual, .regular, .other]
            let near = list.filter { $0.begin.addingTimeInterval(-tolerance) <= date && date <= $0.end.addingTimeInterval(tolerance) }
            match = near.filter { $0.begin <= date && date <= $0.end }.min { rank($0, order) < rank($1, order) }
                ?? near.min { distance($0, to: date) < distance($1, to: date) }
                ?? list.filter { $0.begin > date }.min { $0.begin < $1.begin }
        }
        guard let match else { return }
        browser.selectWithoutPlaying(match.id)
        if match.isPhoto {
            session.stop()
            Task { await browser.showPhoto(match, camera: camera) }
            return
        }
        browser.closePhoto()
        playerFocused = true
        let start = min(max(date, match.begin), max(match.end.addingTimeInterval(-1), match.begin))
        Task { await session.play(match, camera: camera, from: start) }
    }

    private func rank(_ recording: Recording, _ order: [Recording.Kind]) -> Int { order.firstIndex(of: recording.kind) ?? 9 }

    private func play(_ recording: Recording) {
        guard let camera else { return }
        if recording.isPhoto {
            session.stop()
            Task { await browser.showPhoto(recording, camera: camera) }
            return
        }
        browser.closePhoto()
        playerFocused = true
        Task { await session.play(recording, camera: camera) }
    }

    // MARK: - Player

    /// Busca o dia do alerta e toca a gravação que contém o momento (começando alguns segundos antes).
    /// O que o botão Baixar baixa: o vídeo tocando ou a foto aberta.
    private var downloadTarget: (recording: Recording, camera: Camera)? {
        if let photo = browser.photoRecording, let camera { return (photo, camera) }
        if let recording = session.recording, let camera = session.camera { return (recording, camera) }
        return nil
    }

    private var currentIsDownloaded: Bool {
        guard let target = downloadTarget else { return false }
        return downloaded.file(of: target.recording, camera: target.camera) != nil && !currentIsPartial
    }

    /// Baixado enquanto ainda gravava: o Baixar volta a baixar.
    private var currentIsPartial: Bool {
        guard let target = downloadTarget else { return false }
        return downloaded.isPartial(target.recording, camera: target.camera)
    }

    /// Vídeo que está tocando (ou o escolhido na lista), para as tags.
    private var currentRecording: Recording? {
        if let playing = session.recording, browser.recordings.contains(where: { $0.id == playing.id }) { return playing }
        return browser.selected.flatMap { id in browser.recordings.first { $0.id == id } }
    }

    private func openRequest() {
        guard let request, request.cameraID == cameraID, let camera else { return }
        self.request = nil
        open(camera: camera, at: request.date, exact: false)
    }

    /// Vai para o dia do momento, busca e toca a gravação que o contém. Alertas começam 5 s antes;
    /// um vídeo com tag começa no início dele (`exact`).
    private func open(camera: Camera, at date: Date, exact: Bool) {
        browser.openingRequest = true
        browser.day = date
        // Alerta: marca o horário na linha do tempo, e a agulha vai direto para ele.
        browser.alarmMarker = exact ? nil : date
        Task {
            await browser.search(camera: camera)
            browser.openingRequest = false
            if exact {
                let target = date.addingTimeInterval(1)
                guard let match = browser.recordings.first(where: { $0.begin <= target && target <= $0.end })
                    ?? browser.recordings.first(where: { $0.begin >= target }) else {
                    if browser.message == nil { browser.message = String(localized: "Nenhuma gravação neste momento.") }
                    return
                }
                browser.selectWithoutPlaying(match.id)
                await session.play(match, camera: camera, from: nil)
                return
            }
            // Qualquer trecho que tenha o horário do alerta (contínua, movimento ou alarme), começando bem nele.
            // A contínua vem primeiro: é a que tem também o que aconteceu antes e depois.
            let covering = browser.recordings.filter { $0.begin <= date && date <= $0.end }
            let order: [Recording.Kind] = [.regular, .alarm, .motion, .manual, .other]
            let best = covering.min { (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9) }
            if let best {
                browser.selectWithoutPlaying(best.id)
                await session.play(best, camera: camera, from: max(date.addingTimeInterval(-2), best.begin))
                return
            }
            // Sem gravação bem no horário: o trecho mais perto (antes ou depois), avisando.
            guard let nearest = browser.recordings.min(by: { distance($0, to: date) < distance($1, to: date) }) else {
                if browser.message == nil { browser.message = String(localized: "Nenhuma gravação neste dia.") }
                return
            }
            browser.message = String(localized: "Sem gravação às \(date.formatted(date: .omitted, time: .standard)); tocando o trecho mais perto.")
            browser.selectWithoutPlaying(nearest.id)
            let start = nearest.end < date ? max(nearest.end.addingTimeInterval(-10), nearest.begin) : nearest.begin
            await session.play(nearest, camera: camera, from: start)
        }
    }

    private func distance(_ recording: Recording, to date: Date) -> TimeInterval {
        date < recording.begin ? recording.begin.timeIntervalSince(date) : date.timeIntervalSince(recording.end)
    }

    /// Foto do quadro atual (pausar antes ajuda a escolher o momento exato).
    private func takePhoto() {
        let zoomed = zoom.scale > 1
        let stamp = (session.clock ?? Date()).formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))h\(minute: .twoDigits)m\(second: .twoDigits)s",
            timeZone: .current, calendar: .current))
        let name = "\(session.camera?.displayName ?? "Gravação") \(stamp)\(zoomed ? " zoom" : "")"
        do {
            if let url = try FrameSnapshot.save(from: session.displayLayer.sampleBufferRenderer, name: name,
                                                zoom: zoomed ? zoom : nil) {
                browser.photoMessage = String(localized: "Foto salva: \(url.lastPathComponent)")
            }
        } catch {
            browser.photoMessage = error.localizedDescription
        }
    }

    private var player: some View {
        VStack(spacing: 0) {
            ZStack {
                GeometryReader { proxy in
                    VideoLayerView(layer: session.displayLayer, zoom: zoom.scale, pan: zoom.pan,
                                   onScrollZoom: session.recording == nil ? nil : { zoom.zoom(by: $0, at: $1, in: $2) })
                        .gesture(session.recording == nil ? nil : zoom.gesture)
                        .onAppear { zoom.viewSize = proxy.size }
                        .onChange(of: proxy.size) { zoom.viewSize = proxy.size }
                }
                overlay
                photoLayer
                if session.recording != nil { ZoomControls(zoom: zoom) }
            }
            .background(Color.black)
            .focusable()
            .focusEffectDisabled()
            .focused($playerFocused)
            .simultaneousGesture(TapGesture().onEnded { playerFocused = true })
            .onKeyPress(.space) {
                guard session.recording != nil else { return .ignored }
                if session.status == .finished { session.seek(to: 0) } else { session.togglePause() }
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard session.recording != nil else { return .ignored }
                session.skip(by: -10)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard session.recording != nil else { return .ignored }
                session.skip(by: 10)
                return .handled
            }

            // Barra de baixo no mesmo estilo do ao vivo: controles no centro, ferramentas à direita.
            VStack(spacing: 8) {
                seekBar
                // Larga: tudo com nomes; estreita: só ícones e a velocidade num menu (nada sai da tela).
                ViewThatFits(in: .horizontal) {
                    controlRow(compact: false)
                    controlRow(compact: true)
                }
                if let message = browser.photoMessage ?? (session.info.isEmpty ? nil : session.info) {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .background(Theme.surface)
        }
    }

    private func controlRow(compact: Bool) -> some View {
        let hasRecording = session.recording != nil
        return HStack(spacing: Space.s) {
            if let clock = session.clock {
                Text(clock.formatted(date: compact ? .omitted : .abbreviated, time: .standard))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: Space.s)
            BarButton(icon: "gobackward.10", help: String(localized: "Voltar 10 s (←)")) { session.skip(by: -10) }
                .disabled(!hasRecording)
            Button {
                if session.status == .finished { session.seek(to: 0) } else { session.togglePause() }
            } label: {
                Image(systemName: session.status == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Theme.accentGradient))
            }
            .buttonStyle(.hover)
            .disabled(![.playing, .paused, .finished].contains(session.status))
            .help(session.status == .playing ? String(localized: "Pausar (espaço)") : String(localized: "Reproduzir (espaço)"))
            .accessibilityLabel(session.status == .playing ? "Pausar" : "Reproduzir")
            BarButton(icon: "goforward.10", help: String(localized: "Avançar 10 s (→)")) { session.skip(by: 10) }
                .disabled(!hasRecording)
            BarButton(icon: "stop.fill", help: String(localized: "Parar")) { session.stop() }
                .disabled(session.status == .idle)
            speedControl(compact: compact)
            Spacer(minLength: Space.s)
            if session.hasAudio {
                SpeakerButton(id: session.audioID, setAudio: session.setAudio)
                    .buttonStyle(.hover)
                    .font(.system(size: 18))
                    .disabled(session.speed != 1)
            }
            BarButton(icon: "camera", title: compact ? nil : String(localized: "Foto"),
                      help: String(localized: "Salvar uma foto do que está na tela (com zoom, só a parte ampliada)")) { takePhoto() }
                .disabled(!hasRecording)
            BarButton(icon: currentIsDownloaded ? "checkmark.circle" : "arrow.down.circle",
                      title: compact ? nil : (currentIsDownloaded ? String(localized: "Baixado")
                                              : currentIsPartial ? String(localized: "Baixar de novo") : String(localized: "Baixar")),
                      help: currentIsDownloaded ? String(localized: "Já está no Mac: mostrar o arquivo no Finder (⌘D)")
                          : currentIsPartial ? String(localized: "Foi baixada enquanto ainda gravava; baixar de novo com o trecho todo (⌘D)")
                          : String(localized: "Baixar esta gravação na pasta das Preferências (⌘D)")) {
                if let target = downloadTarget { browser.download(target.recording, camera: target.camera) }
            }
            .keyboardShortcut(compact ? nil : KeyboardShortcut("d"))
            .disabled(downloadTarget == nil)
            if currentIsDownloaded {
                BarButton(icon: "arrow.clockwise.circle", help: String(localized: "Baixar de novo (outra cópia na pasta das Preferências)")) {
                    if let target = downloadTarget { browser.download(target.recording, camera: target.camera, again: true) }
                }
            }
        }
    }

    private static let speeds: [Double] = [0.5, 1, 2, 4, 8]
    private static func speedText(_ speed: Double) -> String { "\(speed == 0.5 ? "½" : String(Int(speed)))×" }

    @ViewBuilder
    private func speedControl(compact: Bool) -> some View {
        let binding = Binding(get: { session.speed }, set: { session.setSpeed($0) })
        if compact {
            Picker("Velocidade", selection: binding) {
                ForEach(Self.speeds, id: \.self) { Text(Self.speedText($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        } else {
            Picker("Velocidade", selection: binding) {
                ForEach(Self.speeds, id: \.self) { Text(Self.speedText($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
    }

    /// Barra de progresso: clicar ou arrastar pula para o ponto escolhido.
    private var seekBar: some View {
        let shown = session.scrubbing ? session.scrubPosition : session.position
        return HStack(spacing: 8) {
            Text(Self.timeText(shown))
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
            Slider(
                value: Binding(get: { session.scrubbing ? session.scrubPosition : session.position },
                               set: { session.scrubPosition = $0 }),
                in: 0 ... session.duration,
                onEditingChanged: { editing in
                    if editing {
                        session.scrubPosition = session.position
                        session.scrubbing = true
                    } else {
                        session.scrubbing = false
                        session.seek(to: session.scrubPosition)
                    }
                }
            )
            .controlSize(.small)
            .disabled(session.recording == nil)
            Text(Self.timeText(session.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
        }
    }

    private static func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Foto aberta da lista ou da linha do tempo, por cima do vídeo parado.
    @ViewBuilder
    private var photoLayer: some View {
        if let recording = browser.photoRecording {
            ZStack {
                Color.black
                if let image = browser.photo {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if browser.photoLoading {
                    ProgressView("Abrindo foto…").tint(.white).foregroundStyle(.white)
                } else if let message = browser.photoMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                VStack {
                    HStack {
                        Text("\(recording.kind.label) · \(recording.begin.formatted(date: .omitted, time: .standard))")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                        Spacer()
                        Button { browser.closePhoto() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.85))
                            .help("Fechar a foto")
                            .accessibilityLabel("Fechar a foto")
                    }
                    Spacer()
                }
                .padding(Space.m)
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch session.status {
        case .idle:
            Text("Escolha uma câmera e um dia, busque e clique em uma gravação.")
                .foregroundStyle(.white.opacity(0.7))
        case .connecting:
            ProgressView("Abrindo gravação…").tint(.white).foregroundStyle(.white)
        case .finished:
            Label("Fim da gravação", systemImage: "checkmark.circle")
                .padding(Space.s)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.small))
                .foregroundStyle(.white)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .padding(Space.s)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.small))
                .foregroundStyle(.yellow)
        case .playing, .paused:
            EmptyView()
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    var downloaded = false
    /// Baixada enquanto ainda gravava: o arquivo do equipamento cresceu depois.
    var partial = false
    /// Baixar (again = outra cópia de um arquivo já baixado).
    var onDownload: (_ again: Bool) -> Void = { _ in }
    var onReveal: () -> Void = {}

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.isPhoto ? recording.begin.formatted(date: .omitted, time: .standard)
                                       : "\(recording.begin.formatted(date: .omitted, time: .standard)) – \(recording.end.formatted(date: .omitted, time: .standard))")
                    .monospacedDigit()
                Text(String(format: "%.1f MB", Double(recording.sizeKB) / 1024))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if partial {
                Label("Incompleto", systemImage: "clock.arrow.circlepath")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                    .background(Theme.warning.opacity(0.2), in: Capsule())
                    .foregroundStyle(Theme.warning)
                    .help("Baixado enquanto ainda gravava; baixe de novo para ter o trecho todo")
            } else if downloaded {
                // Selo "No Mac": este vídeo já está baixado aqui.
                Label("No Mac", systemImage: "internaldrive.fill")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                    .background(Theme.success.opacity(0.2), in: Capsule())
                    .foregroundStyle(Theme.success)
                    .help("Já baixado no Mac")
                    .accessibilityLabel("Já baixado no Mac")
            }
            Text(recording.kind.label)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                .background(color.opacity(0.2), in: Capsule())
                .foregroundStyle(color)
            downloadButton
        }
    }

    /// Baixar direto da lista; já baixado, o menu tem "Mostrar no Finder" e "Baixar de novo".
    @ViewBuilder
    private var downloadButton: some View {
        if downloaded && !partial {
            Menu {
                Button("Mostrar no Finder", action: onReveal)
                Button("Baixar de novo") { onDownload(true) }
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.success)
            .help("Já baixado: mostrar no Finder ou baixar de novo")
            .accessibilityLabel("Opções do arquivo baixado")
        } else {
            Button { onDownload(false) } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.borderless)
                .help(partial ? "Baixar de novo, com o trecho todo" : (recording.isPhoto ? "Baixar a foto" : "Baixar em MP4"))
                .accessibilityLabel(partial ? "Baixar de novo" : "Baixar")
        }
    }

    private var color: Color { recording.kind.color }
}

private struct DownloadRow: View {
    @ObservedObject var job: RecordingDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.title).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                switch job.state {
                case .running:
                    Button { job.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Cancelar")
                        .accessibilityLabel("Cancelar o download")
                case .finished:
                    Button { NSWorkspace.shared.activateFileViewerSelecting([job.url]) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Mostrar no Finder")
                        .accessibilityLabel("Mostrar no Finder")
                default:
                    EmptyView()
                }
            }
            switch job.state {
            case .running:
                ProgressView(value: job.progress).controlSize(.small)
            case .finished:
                Text("Concluído").font(.caption2).foregroundStyle(Theme.success)
            case .cancelled:
                Text("Cancelado").font(.caption2).foregroundStyle(.secondary)
            case let .failed(message):
                Text(message).font(.caption2).foregroundStyle(Theme.warning).lineLimit(2)
            }
        }
    }
}
