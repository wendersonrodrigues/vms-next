import SwiftUI

/// Painel de PTZ ao lado da câmera em tela única: direções e zoom/foco/íris
/// funcionam enquanto o botão está pressionado; presets por número.
struct PTZPanel: View {
    @StateObject private var ptz: PTZController

    init(camera: Camera) {
        _ptz = StateObject(wrappedValue: PTZController(camera: camera))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PTZ").font(.headline)

            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    HoldButton(icon: "arrow.up.left", command: .upLeft, ptz: ptz)
                    HoldButton(icon: "arrow.up", command: .up, ptz: ptz)
                    HoldButton(icon: "arrow.up.right", command: .upRight, ptz: ptz)
                }
                GridRow {
                    HoldButton(icon: "arrow.left", command: .left, ptz: ptz)
                    Image(systemName: "video").foregroundStyle(.secondary).frame(width: 40, height: 40)
                    HoldButton(icon: "arrow.right", command: .right, ptz: ptz)
                }
                GridRow {
                    HoldButton(icon: "arrow.down.left", command: .downLeft, ptz: ptz)
                    HoldButton(icon: "arrow.down", command: .down, ptz: ptz)
                    HoldButton(icon: "arrow.down.right", command: .downRight, ptz: ptz)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("Velocidade: \(Int(ptz.speed))").font(.caption).foregroundStyle(.secondary)
                Slider(value: $ptz.speed, in: 1 ... 8, step: 1)
            }

            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                pairRow("Zoom", minus: ("minus.magnifyingglass", .zoomOut), plus: ("plus.magnifyingglass", .zoomIn))
                pairRow("Foco", minus: ("minus", .focusNear), plus: ("plus", .focusFar))
                pairRow("Íris", minus: ("circle.dotted", .irisClose), plus: ("circle", .irisOpen))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Stepper("Preset \(ptz.preset)", value: $ptz.preset, in: 1 ... 255)
                HStack {
                    Button("Ir") { ptz.presetAction(.gotoPreset) }
                    Button("Salvar") { ptz.presetAction(.setPreset) }
                    Button("Apagar") { ptz.presetAction(.clearPreset) }
                }
                .controlSize(.small)
            }

            if let message = ptz.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding()
        .frame(width: 220)
        .background(.regularMaterial)
        .onDisappear { ptz.end() }
    }

    private func pairRow(_ title: String, minus: (String, PTZCommand), plus: (String, PTZCommand)) -> some View {
        GridRow {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            HoldButton(icon: minus.0, command: minus.1, ptz: ptz, size: 32)
            HoldButton(icon: plus.0, command: plus.1, ptz: ptz, size: 32)
        }
    }
}

/// PTZ na horizontal, logo acima da barra de baixo da câmera em tela cheia.
struct PTZBar: View {
    @StateObject private var ptz: PTZController

    init(camera: Camera) {
        _ptz = StateObject(wrappedValue: PTZController(camera: camera))
    }

    // Da direita para a esquerda: as setas ficam no canto direito, perto do mouse que vem do vídeo.
    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            Spacer(minLength: 0)
            if let message = ptz.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 200, alignment: .leading)
            }

            // Ronda: lista de presets que a câmera percorre sozinha (como "Ronda" no PTZ do VMS antigo).
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Stepper("Ronda \(ptz.tour)", value: $ptz.tour, in: 1 ... 8)
                    Stepper("\(ptz.tourDwell) s", value: $ptz.tourDwell, in: 3 ... 255)
                        .help("Quanto tempo a câmera para em cada preset da ronda")
                }
                HStack {
                    Button { ptz.tourAction(.startTour) } label: { Image(systemName: "play.fill") }
                        .help("Começar a ronda")
                    Button { ptz.tourAction(.stopTour) } label: { Image(systemName: "stop.fill") }
                        .help("Parar a ronda")
                    Button("+ Preset \(ptz.preset)") { ptz.tourAction(.addTour) }
                        .help("Adicionar o preset \(ptz.preset) a esta ronda")
                    Button("− Preset") { ptz.tourAction(.deleteTour) }
                        .help("Tirar o preset \(ptz.preset) desta ronda")
                    Button("Limpar") { ptz.tourAction(.clearTour) }
                        .help("Apagar todos os presets desta ronda")
                }
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                Stepper("Preset \(ptz.preset)", value: $ptz.preset, in: 1 ... 255)
                HStack {
                    Button("Ir") { ptz.presetAction(.gotoPreset) }
                    Button("Salvar") { ptz.presetAction(.setPreset) }
                    Button("Apagar") { ptz.presetAction(.clearPreset) }
                }
                .controlSize(.small)
            }

            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                pairRow("Zoom óptico", minus: ("minus.magnifyingglass", .zoomOut), plus: ("plus.magnifyingglass", .zoomIn))
                pairRow("Foco", minus: ("minus", .focusNear), plus: ("plus", .focusFar))
                pairRow("Íris", minus: ("circle.dotted", .irisClose), plus: ("circle", .irisOpen))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Velocidade: \(Int(ptz.speed))").font(.caption).foregroundStyle(.secondary)
                Slider(value: $ptz.speed, in: 1 ... 8, step: 1).frame(width: 140)
                Toggle("Inverter esquerda/direita", isOn: $ptz.invertHorizontal)
                    .help("Use quando a câmera vira para o lado contrário da seta")
                Toggle("Inverter cima/baixo", isOn: $ptz.invertVertical)
                    .help("Use quando a câmera sobe ao apertar para baixo (ex.: instalada de ponta-cabeça)")
            }
            .toggleStyle(.checkbox)
            .font(.caption)

            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    HoldButton(icon: "arrow.up.left", command: .upLeft, ptz: ptz, size: 30)
                    HoldButton(icon: "arrow.up", command: .up, ptz: ptz, size: 30)
                    HoldButton(icon: "arrow.up.right", command: .upRight, ptz: ptz, size: 30)
                }
                GridRow {
                    HoldButton(icon: "arrow.left", command: .left, ptz: ptz, size: 30)
                    Image(systemName: "video").foregroundStyle(.secondary).frame(width: 30, height: 30)
                    HoldButton(icon: "arrow.right", command: .right, ptz: ptz, size: 30)
                }
                GridRow {
                    HoldButton(icon: "arrow.down.left", command: .downLeft, ptz: ptz, size: 30)
                    HoldButton(icon: "arrow.down", command: .down, ptz: ptz, size: 30)
                    HoldButton(icon: "arrow.down.right", command: .downRight, ptz: ptz, size: 30)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.surfaceHigh)
        .onDisappear { ptz.end() }
    }

    private func pairRow(_ title: String, minus: (String, PTZCommand), plus: (String, PTZCommand)) -> some View {
        GridRow {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HoldButton(icon: minus.0, command: minus.1, ptz: ptz, size: 26)
            HoldButton(icon: plus.0, command: plus.1, ptz: ptz, size: 26)
        }
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
                ptz.active == command ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in ptz.begin(command) }
                    .onEnded { _ in ptz.end() }
            )
            .help(command.rawValue)
    }
}
