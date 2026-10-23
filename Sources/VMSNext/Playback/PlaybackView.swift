import SwiftUI

/// Estado da tela de gravações: equipamento/canal, dia e resultado da busca.
@MainActor
final class RecordingBrowser: ObservableObject {
    @Published var cameraID: Camera.ID?
    @Published var day = Date()
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var searching = false
    @Published private(set) var message: String?
    @Published var selected: Recording.ID?
    @Published var diagnosticText: String?

    /// Testa variações da busca no dia escolhido e lê os discos do equipamento,
    /// mostrando o código de resposta de cada tentativa. Só leitura.
    func diagnose(camera: Camera) async -> String {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86_399)
        var output = "Busca de gravações: \(camera.displayName) · canal \(camera.channel) · \(DeviceTime.string(start).prefix(10))\n"
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let anyRet = Set(0 ..< 1000)

            output += "\n== StorageInfo\n"
            if let storage = try? await client.command(code: 1020, name: "StorageInfo", payload: nil, accepted: anyRet) {
                let value = storage["StorageInfo"] ?? storage
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                output += data.map { String(decoding: $0, as: UTF8.self) } ?? "(ilegível)"
                output += "\n"
            } else {
                output += "(sem resposta)\n"
            }

            output += "\n== OPFileQuery (tipo · stream · máscara → código, arquivos)\n"
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
            output += "\nFalha ao conectar: \(error.localizedDescription)\n"
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
            for type in ["h264", "h265", "*"] {
                do {
                    recordings = try await client.findRecordings(channel: camera.channel - 1, from: start, to: end, type: type)
                    refusals.removeAll()
                    break
                } catch let DVRIPError.device(code) {
                    refusals.append("\(type): \(code)")
                }
            }
            if !refusals.isEmpty {
                message = "O equipamento recusou a busca no canal \(camera.channel) (códigos — \(refusals.joined(separator: ", ")))."
            } else if recordings.isEmpty {
                message = "Nenhuma gravação neste dia."
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

struct PlaybackView: View {
    @EnvironmentObject private var store: CameraStore
    @StateObject private var browser = RecordingBrowser()
    @StateObject private var session = PlaybackSession()

    private var camera: Camera? {
        store.cameras.first { $0.id == browser.cameraID } ?? store.cameras.first
    }

    var body: some View {
        HStack(spacing: 0) {
            searchPanel
                .frame(width: 300)
            Divider()
            player
        }
        .onDisappear { session.stop() }
        .sheet(isPresented: Binding(get: { browser.diagnosticText != nil }, set: { if !$0 { browser.diagnosticText = nil } })) {
            DiagnosticSheet(text: browser.diagnosticText ?? "")
        }
    }

    // MARK: - Busca

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Câmera", selection: Binding(get: { camera?.id }, set: { browser.cameraID = $0 })) {
                ForEach(store.standaloneCameras) { Text($0.name).tag(Optional($0.id)) }
                ForEach(store.groups, id: \.self) { group in
                    Section(group) {
                        ForEach(store.channels(in: group)) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                }
            }
            DatePicker("Dia", selection: $browser.day, displayedComponents: .date)
                .datePickerStyle(.graphical)
            Button {
                guard let camera else { return }
                Task { await browser.search(camera: camera) }
            } label: {
                Label("Buscar gravações", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(camera == nil || browser.searching)

            Button("Diagnóstico da busca…") {
                guard let camera else { return }
                Task { browser.diagnosticText = await browser.diagnose(camera: camera) }
            }
            .controlSize(.small)
            .disabled(camera == nil || browser.searching)

            if browser.searching {
                ProgressView().frame(maxWidth: .infinity)
            } else if let message = browser.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            List(browser.recordings, selection: $browser.selected) { recording in
                RecordingRow(recording: recording)
                    .tag(recording.id)
                    .onTapGesture(count: 2) { play(recording) }
            }
            .listStyle(.inset)
            .onChange(of: browser.selected) {
                if let id = browser.selected, let recording = browser.recordings.first(where: { $0.id == id }) {
                    play(recording)
                }
            }
        }
        .padding(12)
    }

    private func play(_ recording: Recording) {
        guard let camera else { return }
        Task { await session.play(recording, camera: camera) }
    }

    // MARK: - Player

    private var player: some View {
        VStack(spacing: 0) {
            ZStack {
                VideoLayerView(layer: session.displayLayer)
                overlay
            }
            .background(Color.black)

            VStack(spacing: 6) {
                seekBar
                HStack(spacing: 12) {
                    Button {
                        session.skip(by: -10)
                    } label: {
                        Image(systemName: "gobackward.10")
                    }
                    .help("Voltar 10 s")
                    .disabled(session.recording == nil)

                    Button {
                        if session.status == .finished {
                            session.seek(to: 0)
                        } else {
                            session.togglePause()
                        }
                    } label: {
                        Image(systemName: session.status == .playing ? "pause.fill" : "play.fill")
                    }
                    .disabled(![.playing, .paused, .finished].contains(session.status))

                    Button {
                        session.skip(by: 10)
                    } label: {
                        Image(systemName: "goforward.10")
                    }
                    .help("Avançar 10 s")
                    .disabled(session.recording == nil)

                    Button {
                        session.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .disabled(session.status == .idle)

                    Picker("Velocidade", selection: Binding(get: { session.speed }, set: { session.setSpeed($0) })) {
                        ForEach([0.5, 1, 2, 4, 8], id: \.self) { Text("\($0 == 0.5 ? "½" : String(Int($0)))×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)

                    Spacer()

                    if let clock = session.clock {
                        Text(clock.formatted(date: .abbreviated, time: .standard))
                            .monospacedDigit()
                    }
                    if !session.info.isEmpty {
                        Text(session.info).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
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
                .padding(8)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.white)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .padding(8)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.yellow)
        case .playing, .paused:
            EmptyView()
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(recording.begin.formatted(date: .omitted, time: .standard)) – \(recording.end.formatted(date: .omitted, time: .standard))")
                    .monospacedDigit()
                Text(String(format: "%.1f MB", Double(recording.sizeKB) / 1024))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(recording.kind.label)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.2), in: Capsule())
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch recording.kind {
        case .regular: return .blue
        case .motion: return .orange
        case .alarm: return .red
        case .manual: return .purple
        case .other: return .gray
        }
    }
}
