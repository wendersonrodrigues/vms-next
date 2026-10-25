import SwiftUI

/// PTZ no pé da lista de câmeras (mosaico e tela única), no arranjo simples do VMS antigo: setas com zoom, íris
/// e foco ao lado; passo; preset e ronda escolhidos numa lista. Adicionar/remover/limpar a ronda fica numa
/// janelinha à parte, como no VMS antigo.
struct PTZPanel: View {
    let camera: Camera
    let onClose: () -> Void
    @StateObject private var ptz: PTZController
    @StateObject private var editingTour = HoverFlag()

    init(camera: Camera, onClose: @escaping () -> Void) {
        self.camera = camera
        self.onClose = onClose
        _ptz = StateObject(wrappedValue: PTZController(camera: camera))
    }

    /// Largura da coluna dos nomes ("Passo", "Preset", "Ronda"), para os controles ficarem alinhados.
    private let labelWidth: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").foregroundStyle(Theme.accent)
                Text("PTZ · \(camera.displayName)").font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Fechar os controles de PTZ")
                .accessibilityLabel("Fechar os controles de PTZ")
            }

            // Setas e, ao lado, zoom, íris e foco (embaixo só se a lista estiver estreita demais).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Space.s) {
                    directionPad
                    Spacer(minLength: 0)
                    lensControls
                }
                VStack(spacing: Space.s) { directionPad; lensControls }
            }

            Divider()

            VStack(spacing: Space.s) {
                row("Passo") {
                    Slider(value: $ptz.speed, in: 1 ... 8, step: 1)
                        .controlSize(.small)
                        .accessibilityLabel("Passo (velocidade)")
                    Text("\(Int(ptz.speed))").monospacedDigit().frame(width: 14, alignment: .trailing)
                }
                row("Preset") {
                    numberPicker($ptz.preset, range: 1 ... 255, label: "Preset")
                    Spacer(minLength: 0)
                    iconButton("arrow.uturn.forward", "Ir para o preset \(ptz.preset)") { ptz.presetAction(.gotoPreset) }
                    iconButton("plus", "Salvar a posição atual no preset \(ptz.preset)") { ptz.presetAction(.setPreset) }
                    iconButton("minus", "Apagar o preset \(ptz.preset)") { ptz.presetAction(.clearPreset) }
                }
                row("Ronda") {
                    numberPicker($ptz.tour, range: 1 ... 8, label: "Ronda")
                    Spacer(minLength: 0)
                    iconButton("play.fill", "Começar a ronda \(ptz.tour)") { ptz.tourAction(.startTour) }
                    iconButton("stop.fill", "Parar a ronda") { ptz.tourAction(.stopTour) }
                    iconButton("square.grid.3x3.fill", "Editar a ronda \(ptz.tour): adicionar, remover ou limpar presets") {
                        editingTour.on = true
                    }
                    .popover(isPresented: $editingTour.on, arrowEdge: .trailing) { tourEditor }
                }
            }

            HStack(spacing: Space.m) {
                Toggle("Inverter ←→", isOn: $ptz.invertHorizontal)
                    .help("Use quando a câmera vira para o lado contrário da seta")
                Toggle("Inverter ↑↓", isOn: $ptz.invertVertical)
                    .help("Use quando a câmera sobe ao apertar para baixo (ex.: instalada de ponta-cabeça)")
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption)
            .foregroundStyle(.secondary)

            if let message = ptz.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.m)
        .onDisappear { ptz.end() }
    }

    /// Linha com o nome à esquerda numa coluna fixa e os controles à direita.
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Space.xs) {
            Text(title).font(.callout).frame(width: labelWidth, alignment: .leading)
            content()
        }
    }

    private var directionPad: some View {
        Grid(horizontalSpacing: Space.xs, verticalSpacing: Space.xs) {
            GridRow {
                HoldButton(icon: "arrow.up.left", command: .upLeft, ptz: ptz, size: 28)
                HoldButton(icon: "arrow.up", command: .up, ptz: ptz, size: 28)
                HoldButton(icon: "arrow.up.right", command: .upRight, ptz: ptz, size: 28)
            }
            GridRow {
                HoldButton(icon: "arrow.left", command: .left, ptz: ptz, size: 28)
                Image(systemName: "video").font(.caption).foregroundStyle(.secondary).frame(width: 28, height: 28)
                HoldButton(icon: "arrow.right", command: .right, ptz: ptz, size: 28)
            }
            GridRow {
                HoldButton(icon: "arrow.down.left", command: .downLeft, ptz: ptz, size: 28)
                HoldButton(icon: "arrow.down", command: .down, ptz: ptz, size: 28)
                HoldButton(icon: "arrow.down.right", command: .downRight, ptz: ptz, size: 28)
            }
        }
        .padding(Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Color.primary.opacity(0.05)))
    }

    /// Como no VMS antigo: menos à esquerda, nome no meio, mais à direita.
    private var lensControls: some View {
        Grid(horizontalSpacing: Space.xs, verticalSpacing: Space.xs) {
            lensRow("Zoom", minus: ("minus.magnifyingglass", .zoomOut), plus: ("plus.magnifyingglass", .zoomIn))
            lensRow("Íris", minus: ("circle.dotted", .irisClose), plus: ("circle", .irisOpen))
            lensRow("Foco", minus: ("minus", .focusNear), plus: ("plus", .focusFar))
        }
    }

    private func lensRow(_ title: String, minus: (String, PTZCommand), plus: (String, PTZCommand)) -> some View {
        GridRow {
            HoldButton(icon: minus.0, command: minus.1, ptz: ptz, size: 26)
            Text(title).font(.caption).frame(width: 32)
            HoldButton(icon: plus.0, command: plus.1, ptz: ptz, size: 26)
        }
    }

    /// Lista para escolher o número com um clique (no lugar das setinhas, que eram lentas).
    private func numberPicker(_ value: Binding<Int>, range: ClosedRange<Int>, label: String) -> some View {
        Picker(label, selection: value) {
            ForEach(Array(range), id: \.self) { Text("\($0)").tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 58)
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 18, height: 14)
        }
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Janelinha "editar ronda" do VMS antigo: preset, tempo parado nele e adicionar/remover/limpar.
    private var tourEditor: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Ronda \(ptz.tour)").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.s) {
                GridRow {
                    Text("Preset")
                    numberPicker($ptz.preset, range: 1 ... 255, label: "Preset")
                }
                GridRow {
                    Text("Tempo em cada preset")
                    HStack(spacing: Space.xs) {
                        Picker("Tempo", selection: $ptz.tourDwell) {
                            ForEach(Array(Set([3, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 255, ptz.tourDwell])).sorted(), id: \.self) {
                                Text("\($0)").tag($0)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 64)
                        Text("s").foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Adicionar") { ptz.tourAction(.addTour) }
                    .help("Põe o preset \(ptz.preset) na ronda \(ptz.tour)")
                Button("Remover") { ptz.tourAction(.deleteTour) }
                    .help("Tira o preset \(ptz.preset) da ronda \(ptz.tour)")
                Spacer()
                Button("Limpar") { ptz.tourAction(.clearTour) }
                    .help("Apaga todos os presets da ronda \(ptz.tour)")
            }
            if let message = ptz.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(Space.l)
        .frame(width: 300)
    }
}

/// Botão que mantém o comando ativo enquanto pressionado.
private struct HoldButton: View {
    let icon: String
    let command: PTZCommand
    @ObservedObject var ptz: PTZController
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.4, weight: .semibold))
            .frame(width: size, height: size)
            .background(
                ptz.active == command ? Theme.accent.opacity(0.7) : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: Radius.small)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in ptz.begin(command) }
                    .onEnded { _ in ptz.end() }
            )
            .help(command.label)
            // VoiceOver: o gesto de segurar não serve; a ação move por meio segundo.
            .accessibilityElement()
            .accessibilityLabel(command.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                ptz.begin(command)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ptz.end() }
            }
    }
}
