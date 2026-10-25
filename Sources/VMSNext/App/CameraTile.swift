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
    /// Ação do duplo clique (abrir em tela única ou voltar ao mosaico), oferecida também ao VoiceOver.
    var onOpen: (() -> Void)?
    var openTitle = "Abrir em tela única"
    /// Mosaico: PTZ deste quadro aberto (azul) e a ação de abrir/fechar. nil = sem botão de PTZ.
    var ptzActive = false
    var onTogglePTZ: (() -> Void)?
    /// A câmera tem PTZ (lido das capacidades ou da escolha em Editar câmera). ObservableObject no lugar de
    /// @State, que precisa do Xcode.
    @StateObject private var ptzSupport = HoverFlag()
    private var hasPTZ: Bool { ptzSupport.on }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @EnvironmentObject private var store: CameraStore
    @StateObject private var lease: StreamLease
    @StateObject private var zoom = DigitalZoom()
    @ObservedObject private var recorder = LocalRecorder.shared

    init(camera: Camera, quality: StreamQuality, part: SplitPart = .full, onEdit: @escaping () -> Void,
         onSettings: (() -> Void)? = nil, onToggleSplit: (() -> Void)? = nil, onRename: (() -> Void)? = nil,
         single: SingleViewControls? = nil, extraMenu: AnyView? = nil,
         onOpen: (() -> Void)? = nil, openTitle: String = "Abrir em tela única",
         ptzActive: Bool = false, onTogglePTZ: (() -> Void)? = nil) {
        self.ptzActive = ptzActive
        self.onTogglePTZ = onTogglePTZ
        self.onOpen = onOpen
        self.openTitle = openTitle
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
                controlBar(single)
            } else {
                gridBar
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .contextMenu { menu }
        .onAppear {
            let first = LiveStreamHub.shared.acquire(lease.key, name: camera.title(for: part))
            start(force: first)
        }
        .onDisappear { LiveStreamHub.shared.release(lease.key) }
        .onChange(of: store.passwordRevision) { start(force: true) }
        .task(id: "\(camera.id)-\(camera.ptz)-\(camera.sameAs?.uuidString ?? "")") {
            ptzSupport.on = await DeviceCapabilities.hasPTZ(camera, in: store.cameras)
        }
    }

    /// Barra de baixo do quadro do mosaico: nome, câmera ligada, PTZ (só se tiver), som e abrir em tela única.
    private var gridBar: some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(camera.title(for: part))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if part != .full {
                    // Nome oficial da câmera, sempre junto das metades do split.
                    HStack(spacing: 3) {
                        LinkedCameraIcon(size: 12)
                        Text(camera.displayName).lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Câmera \(camera.displayName)")
                }
            }
            Spacer(minLength: Space.xs)
            if hasPTZ, let onTogglePTZ {
                Button(action: onTogglePTZ) {
                    Label("PTZ", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ptzActive ? Color.white : Color.white.opacity(0.55))
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.xxs)
                        .background(RoundedRectangle(cornerRadius: Radius.small)
                            .fill(ptzActive ? Theme.accent : Color.white.opacity(0.1)))
                }
                .buttonStyle(.hover)
                .help(ptzActive ? "Fechar os controles de PTZ desta câmera" : "Abrir os controles de PTZ desta câmera")
                .accessibilityLabel("PTZ")
                .accessibilityAddTraits(ptzActive ? .isSelected : [])
            }
            if stream.hasAudio, part != .bottom {
                SpeakerButton(id: stream.audioID, setAudio: stream.setAudio)
                    .buttonStyle(.hover)
                    .font(.caption)
            }
            if let onOpen {
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption.weight(.semibold))
                }
                .buttonStyle(.hover)
                .help("Abrir em tela única (também com duplo clique)")
                .accessibilityLabel("Abrir em tela única")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .frame(minHeight: 30)
        .background(Color(white: 0.07))
    }

    /// Barra de baixo da câmera em tela cheia, no lugar onde as pessoas procuram esses controles.
    private func controlBar(_ single: SingleViewControls) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(camera.title(for: part)).font(.headline)
                if part != .full {
                    HStack(spacing: 4) {
                        LinkedCameraIcon(size: 14)
                        Text(camera.displayName)
                    }
                    .font(.caption).foregroundStyle(.secondary)
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
            // PTZ no pé da lista de câmeras, o mesmo painel do mosaico (só nas câmeras que têm PTZ).
            if hasPTZ, let onTogglePTZ {
                Button(action: onTogglePTZ) {
                    Label("PTZ", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ptzActive ? Color.white : Color.primary)
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.xs)
                        .background(RoundedRectangle(cornerRadius: Radius.small)
                            .fill(ptzActive ? Theme.accent : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.hover)
                .help(ptzActive ? "Fechar os controles de PTZ" : "Mostrar os controles de PTZ ao lado, embaixo da lista de câmeras")
                .accessibilityLabel("PTZ")
                .accessibilityAddTraits(ptzActive ? .isSelected : [])
            }
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
        .accessibilityLabel(quality == .main ? "Qualidade HD" : "Qualidade SD")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                // Tela única: pinça e arrastar. Mosaico: pinça; arrastar só move a imagem quando ampliada
                // (sem zoom, arrastar troca o quadro de lugar no modelo de tela).
                .gesture(allowsZoom || zoom.scale > 1 ? zoom.gesture : nil)
                .simultaneousGesture(allowsZoom ? nil : zoom.magnifyGesture)
                // VoiceOver: nome da câmera, se está ao vivo e as ações do menu do botão direito.
                .accessibilityElement()
                .accessibilityLabel(camera.title(for: part))
                .accessibilityValue(accessibilityStatus)
                .accessibilityAddTraits(.isImage)
                .accessibilityAction(named: openTitle) { onOpen?() }
                .accessibilityAction(named: recorder.isRecording(camera) ? "Parar gravação no Mac" : "Gravar no Mac") {
                    recorder.toggle(camera)
                }
                .accessibilityAction(named: "Reconectar") { start(force: true) }
                .accessibilityAction(named: "Editar câmera") { onEdit() }
            overlay
            ZoomControls(zoom: zoom, compact: single == nil)
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
                    .accessibilityLabel("Gravando no Mac")
            }
        }
    }

    private var accessibilityStatus: String {
        let recording = recorder.isRecording(camera) ? ", gravando no Mac" : ""
        switch stream.status {
        case .idle, .playing: return "Ao vivo" + recording
        case .connecting: return "Conectando" + recording
        case .needsPassword: return "Senha não definida"
        case let .failed(message, _): return "Sem conexão: \(message)" + recording
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

/// Ligação da câmera em tela cheia com a janela: qualidade escolhida.
struct SingleViewControls {
    var quality: Binding<StreamQuality>
}
