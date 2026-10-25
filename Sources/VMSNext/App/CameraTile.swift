import SwiftUI

struct CameraTile: View {
    let camera: Camera
    let quality: StreamQuality
    /// Split virtual: qual metade da imagem este quadro mostra.
    var part: SplitPart = .full
    let onEdit: () -> Void
    var onSettings: (() -> Void)? = nil
    /// Divide a câmera em duas ou desfaz a divisão.
    var onToggleSplit: (() -> Void)? = nil
    /// Renomeia esta metade (só no app).
    var onRename: (() -> Void)? = nil
    /// Câmera em tela cheia: barra de baixo com som, HD/SD, zoom digital e PTZ.
    var single: SingleViewControls?
    private var allowsZoom: Bool { single != nil }
    /// Itens a mais no menu do botão direito (ex.: escolher a câmera do quadro no modelo de tela).
    var extraMenu: AnyView?

    @EnvironmentObject private var store: CameraStore
    @StateObject private var lease: StreamLease
    @StateObject private var zoom = DigitalZoom()
    @ObservedObject private var recorder = LocalRecorder.shared

    init(camera: Camera, quality: StreamQuality, part: SplitPart = .full, onEdit: @escaping () -> Void,
         onSettings: (() -> Void)? = nil, onToggleSplit: (() -> Void)? = nil, onRename: (() -> Void)? = nil,
         single: SingleViewControls? = nil, extraMenu: AnyView? = nil) {
        self.single = single
        self.extraMenu = extraMenu
        self.camera = camera
        self.quality = quality
        self.part = part
        self.onEdit = onEdit
        self.onSettings = onSettings
        self.onToggleSplit = onToggleSplit
        self.onRename = onRename
        _lease = StateObject(wrappedValue: StreamLease(key: LiveStreamHub.key(camera, quality)))
    }

    private var stream: LiveStream { lease.stream }

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            if let single {
                if single.showPTZ.wrappedValue {
                    PTZBar(camera: camera)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                controlBar(single)
            }
        }
        .animation(.easeOut(duration: 0.2), value: single?.showPTZ.wrappedValue)
        .background(Color.black)
        .contentShape(Rectangle())
        .contextMenu { menu }
        .onAppear {
            let first = LiveStreamHub.shared.acquire(lease.key, name: camera.title(for: part))
            start(force: first)
        }
        .onDisappear { LiveStreamHub.shared.release(lease.key) }
        .onChange(of: store.passwordRevision) { start(force: true) }
    }

    /// Barra de baixo da câmera em tela cheia, no lugar onde as pessoas procuram esses controles.
    private func controlBar(_ single: SingleViewControls) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(camera.title(for: part)).font(.headline)
                if part != .full {
                    Label(camera.displayName, systemImage: "link").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if stream.hasAudio, part != .bottom {
                SpeakerButton(id: stream.audioID, setAudio: stream.setAudio)
                    .buttonStyle(.hover)
                    .font(.system(size: 20))
            }
            // HD = vídeo principal (qualidade máxima); SD = vídeo extra, mais leve para rede lenta.
            HStack(spacing: 4) {
                qualityButton(.main, icon: "hd", title: "HD", single: single,
                              help: "HD: vídeo principal, na resolução máxima da câmera")
                qualityButton(.sub, icon: "sd", title: "SD", single: single,
                              help: "SD: vídeo extra, mais leve (rede lenta ou Wi-Fi fraco)")
            }
            BarButton(icon: "camera", title: "Foto", help: "Salvar uma foto do que está na tela (com zoom, só a parte ampliada)") { takePhoto() }
            Button {
                recorder.toggle(camera)
            } label: {
                // Cinza parado; vermelho só enquanto grava, para não parecer que já está gravando.
                let isRecording = recorder.isRecording(camera)
                Label(isRecording ? "Gravando · parar" : "Gravar",
                      systemImage: isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isRecording ? Color.white : Color.secondary)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.xs)
                    .background(RoundedRectangle(cornerRadius: Radius.small).fill(isRecording ? Color.red : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.hover)
            .help("Gravar esta câmera no disco do Mac (vídeo principal), na pasta das Preferências")
            Button {
                single.showPTZ.wrappedValue.toggle()
            } label: {
                Label("PTZ", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.xs)
                    .background(RoundedRectangle(cornerRadius: Radius.small)
                        .fill(single.showPTZ.wrappedValue ? Theme.accent.opacity(0.25) : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.hover)
            .help("Mostrar os controles de movimento (PTZ), zoom óptico, foco e presets")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .background(Theme.surface)
    }

    private static let qualityIcons: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Icons") else { return result }
        for name in ["hd", "sd"] {
            if let image = NSImage(contentsOf: folder.appendingPathComponent("\(name).png")) { result[name] = image }
        }
        return result
    }()

    /// Botão HD ou SD com o ícone gerado; o escolhido fica aceso, o outro apagado.
    private func qualityButton(_ quality: StreamQuality, icon: String, title: String,
                               single: SingleViewControls, help: String) -> some View {
        let selected = single.quality.wrappedValue == quality
        return Button {
            single.quality.wrappedValue = quality
        } label: {
            Group {
                if let image = Self.qualityIcons[icon] {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: 40, height: 40)
                } else {
                    Text(title).font(.system(size: 13, weight: .bold)).frame(width: 40, height: 28)
                }
            }
            // Ícones chapados no estilo do macOS: o escolhido em cor cheia, o outro apagado, sem brilho.
            .opacity(selected ? 1 : 0.35)
            .saturation(selected ? 1 : 0)
        }
        .buttonStyle(.hover)
        .help(help)
    }

    /// Foto do quadro ao vivo como aparece na tela (com zoom, só a parte ampliada), na pasta de fotos das Preferências.
    private func takePhoto() {
        let zoomed = zoom.scale > 1
        let renderer = (part == .bottom ? stream.mirrorLayer() : stream.displayLayer).sampleBufferRenderer
        let name = "\(camera.title(for: part)) \(AppPreferences.stamp(Date()))\(zoomed ? " zoom" : "")"
        do {
            if try FrameSnapshot.save(from: renderer, name: name, zoom: zoomed ? zoom : nil, crop: part) != nil {
                NSSound(named: "Grab")?.play()
            }
        } catch {
            NSSound.beep()
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Editar câmera…", action: onEdit)
        if let onSettings { Button("Configurações…", action: onSettings) }
        Button("Reconectar") { start(force: true) }
        Button(recorder.isRecording(camera) ? "Parar gravação no Mac" : "Gravar no Mac") { recorder.toggle(camera) }
        if let extraMenu {
            Divider()
            extraMenu
        }
        if onToggleSplit != nil || onRename != nil { Divider() }
        if let onRename { Button("Renomear este quadro…", action: onRename) }
        if let onToggleSplit {
            Button(camera.split == nil ? "Dividir em duas (split virtual)" : "Desfazer divisão", action: onToggleSplit)
        }
    }

    private var videoArea: some View {
        ZStack {
            VideoLayerView(layer: part == .bottom ? stream.mirrorLayer() : stream.displayLayer, crop: part,
                           videoSize: stream.videoSize, zoom: zoom.scale, pan: zoom.pan)
                .gesture(allowsZoom ? zoom.gesture : nil)
            overlay
            if single == nil { nameOverlay }
            if allowsZoom { ZoomControls(zoom: zoom) }
            if recorder.isRecording(camera) {
                Label("REC", systemImage: "record.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs)
                    .background(Capsule().fill(Color.red))
                    .padding(Space.s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .help("Gravando no Mac")
            }
        }
    }

    private var nameOverlay: some View {
            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(camera.title(for: part))
                            .font(.caption.weight(.medium))
                        if part != .full {
                            // Nome oficial da câmera, sempre junto das metades.
                            Label(camera.displayName, systemImage: "link")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.small))
                    .foregroundStyle(.white)
                    Spacer()
                    if stream.hasAudio, part != .bottom {
                        SpeakerButton(id: stream.audioID, setAudio: stream.setAudio)
                            .buttonStyle(.hover)
                            .font(.caption)
                            .padding(Space.xs)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.small))
                            .foregroundStyle(.white)
                    }
                }
                .padding(Space.s)
            }
    }

    @ViewBuilder
    private var overlay: some View {
        switch stream.status {
        case .idle, .playing:
            EmptyView()
        case .connecting:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Conectando…")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
        case .needsPassword:
            VStack(spacing: 8) {
                Image(systemName: "key.fill").font(.title2)
                Text("Senha não definida")
                Button("Definir senha", action: onEdit)
            }
            .font(.caption)
            .foregroundStyle(.white)
        case let .failed(message, retrying):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text(message).multilineTextAlignment(.center)
                if retrying {
                    Text("Tentando novamente…").foregroundStyle(.white.opacity(0.6))
                } else {
                    Button("Corrigir senha", action: onEdit)
                }
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding()
        }
    }

    /// As duas metades dividem o vídeo: só o primeiro quadro (ou um pedido explícito) conecta.
    private func start(force: Bool = false) {
        guard force || stream.status == .idle else { return }
        stream.start(camera: camera, quality: quality, password: store.password(for: camera),
                     source: store.resolvedLiveSource(for: camera))
    }
}

/// Ligações da câmera em tela cheia com a janela: qualidade escolhida e painel de PTZ aberto.
struct SingleViewControls {
    var quality: Binding<StreamQuality>
    var showPTZ: Binding<Bool>
}
