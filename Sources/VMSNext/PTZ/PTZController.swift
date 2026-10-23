import Foundation

enum PTZCommand: String {
    case up = "DirectionUp"
    case down = "DirectionDown"
    case left = "DirectionLeft"
    case right = "DirectionRight"
    case upLeft = "DirectionLeftUp"
    case upRight = "DirectionRightUp"
    case downLeft = "DirectionLeftDown"
    case downRight = "DirectionRightDown"
    case zoomIn = "ZoomTile"
    case zoomOut = "ZoomWide"
    case focusNear = "FocusNear"
    case focusFar = "FocusFar"
    case irisOpen = "IrisLarge"
    case irisClose = "IrisSmall"
    case setPreset = "SetPreset"
    case gotoPreset = "GotoPreset"
    case clearPreset = "ClearPreset"
    /// Ronda: passeio automático entre presets.
    case addTour = "AddTour"
    case deleteTour = "DeleteTour"
    case clearTour = "ClearTour"
    case startTour = "StartTour"
    case stopTour = "StopTour"
}

/// Envia comandos OPPTZControl (código 1400) para o canal da câmera.
/// Movimentos contínuos começam ao pressionar e param ao soltar; os envios são serializados
/// para que o "parar" nunca chegue antes do "começar".
@MainActor
final class PTZController: ObservableObject {
    @Published var speed: Double = 5
    @Published var preset = 1
    /// Ronda escolhida (como no VMS antigo, começa em 1) e quanto tempo parar em cada preset.
    @Published var tour = 1
    @Published var tourDwell = 10
    @Published private(set) var active: PTZCommand?
    @Published private(set) var message: String?

    private let camera: Camera
    private var chain: Task<Void, Never>?

    init(camera: Camera) {
        self.camera = camera
    }

    func begin(_ command: PTZCommand) {
        guard active != command else { return }
        if let current = active { send(current, step: 0, preset: -1) }
        active = command
        send(command, step: Int(speed), preset: 65535)
    }

    func end() {
        guard let command = active else { return }
        active = nil
        send(command, step: 0, preset: -1)
    }

    func presetAction(_ command: PTZCommand) {
        send(command, step: Int(speed), preset: preset)
    }

    /// Comandos da ronda. "Adicionar" põe o preset escolhido na ronda, parando `tourDwell` segundos nele.
    func tourAction(_ command: PTZCommand) {
        let step = command == .addTour ? tourDwell : Int(speed)
        send(command, step: step, preset: command == .addTour || command == .deleteTour ? preset : -1, tour: tour - 1)
    }

    private func send(_ command: PTZCommand, step: Int, preset: Int, tour: Int = 0) {
        let previous = chain
        let camera = camera
        chain = Task { [weak self] in
            await previous?.value
            do {
                let client = try await DeviceSessions.shared.client(for: camera)
                try await client.command(code: 1400, name: "OPPTZControl", payload: [
                    "Command": command.rawValue,
                    "Parameter": [
                        "AUX": ["Number": 0, "Status": "On"],
                        "Channel": camera.channel - 1,
                        "MenuOpts": "Enter",
                        "POINT": ["bottom": 0, "left": 0, "right": 0, "top": 0],
                        "Pattern": "SetBegin",
                        "Preset": preset,
                        "Step": step,
                        "Tour": tour,
                    ] as [String: Any],
                ])
                self?.message = nil
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }
}
