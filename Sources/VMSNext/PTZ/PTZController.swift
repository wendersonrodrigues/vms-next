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

    /// Nome em português para a dica do mouse e o VoiceOver (o rawValue é o nome do protocolo).
    var label: String {
        switch self {
        case .up: return String(localized: "Para cima")
        case .down: return String(localized: "Para baixo")
        case .left: return String(localized: "Para a esquerda")
        case .right: return String(localized: "Para a direita")
        case .upLeft: return String(localized: "Para cima e à esquerda")
        case .upRight: return String(localized: "Para cima e à direita")
        case .downLeft: return String(localized: "Para baixo e à esquerda")
        case .downRight: return String(localized: "Para baixo e à direita")
        case .zoomIn: return String(localized: "Aproximar (zoom)")
        case .zoomOut: return String(localized: "Afastar (zoom)")
        case .focusNear: return String(localized: "Foco mais perto")
        case .focusFar: return String(localized: "Foco mais longe")
        case .irisOpen: return String(localized: "Abrir a íris")
        case .irisClose: return String(localized: "Fechar a íris")
        default: return rawValue
        }
    }
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

    /// Inverter o movimento, para câmeras instaladas de ponta-cabeça ou com o motor ao contrário.
    /// Fica guardado por câmera, no Mac.
    @Published var invertHorizontal: Bool {
        didSet { UserDefaults.standard.set(invertHorizontal, forKey: "ptz.invertH.\(camera.id)") }
    }
    @Published var invertVertical: Bool {
        didSet { UserDefaults.standard.set(invertVertical, forKey: "ptz.invertV.\(camera.id)") }
    }

    private let camera: Camera
    /// Canal do NVR que mostra esta câmera avulsa: o NVR também move a câmera (como no menu PTZ do próprio NVR).
    private let nvrChannel: Camera?
    /// A câmera não aceitou o PTZ direto: os próximos comandos vão pelo NVR.
    private var useNVR = false
    private var chain: Task<Void, Never>?

    /// O PTZ vai direto para a câmera; o canal do NVR só é usado se a câmera não responder.
    init(camera: Camera, nvrChannel: Camera? = nil) {
        self.camera = camera
        self.nvrChannel = camera.group == nil ? nvrChannel : nil
        useNVR = false
        invertHorizontal = UserDefaults.standard.bool(forKey: "ptz.invertH.\(camera.id)")
        invertVertical = UserDefaults.standard.bool(forKey: "ptz.invertV.\(camera.id)")
    }

    func begin(_ command: PTZCommand) {
        guard active != command else { return }
        if let current = active { send(oriented(current), step: 0, preset: -1) }
        active = command
        send(oriented(command), step: Int(speed), preset: 65535)
    }

    func end() {
        guard let command = active else { return }
        active = nil
        send(oriented(command), step: 0, preset: -1)
    }

    /// Direção que vai para a câmera, já com a inversão escolhida.
    private func oriented(_ command: PTZCommand) -> PTZCommand {
        var horizontal = 0, vertical = 0
        switch command {
        case .left: horizontal = -1
        case .right: horizontal = 1
        case .up: vertical = 1
        case .down: vertical = -1
        case .upLeft: (horizontal, vertical) = (-1, 1)
        case .upRight: (horizontal, vertical) = (1, 1)
        case .downLeft: (horizontal, vertical) = (-1, -1)
        case .downRight: (horizontal, vertical) = (1, -1)
        default: return command
        }
        if invertHorizontal { horizontal = -horizontal }
        if invertVertical { vertical = -vertical }
        switch (horizontal, vertical) {
        case (-1, 0): return .left
        case (1, 0): return .right
        case (0, 1): return .up
        case (0, -1): return .down
        case (-1, 1): return .upLeft
        case (1, 1): return .upRight
        case (-1, -1): return .downLeft
        default: return .downRight
        }
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
        let nvrChannel = nvrChannel
        chain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if self.useNVR, let nvrChannel {
                do {
                    try await Self.sendDVRIP(command, to: nvrChannel, step: step, preset: preset, tour: tour)
                    self.message = nil
                } catch {
                    self.message = String(localized: "PTZ pelo NVR: \(error.localizedDescription)")
                }
                return
            }
            if camera.isOnvif {
                await self.sendONVIF(command, step: step, preset: preset)
                // Sem resposta pelo ONVIF: se houver um canal do NVR com a câmera, tenta por ele.
                if self.message != nil, let nvrChannel,
                   (try? await Self.sendDVRIP(command, to: nvrChannel, step: step, preset: preset, tour: tour)) != nil {
                    self.useNVR = true
                    self.message = nil
                }
                return
            }
            do {
                try await Self.sendDVRIP(command, to: camera, step: step, preset: preset, tour: tour)
                self.message = nil
            } catch {
                // A câmera recusou: tenta pelo NVR e, dando certo, segue por ele.
                if let nvrChannel, (try? await Self.sendDVRIP(command, to: nvrChannel, step: step, preset: preset, tour: tour)) != nil {
                    self.useNVR = true
                    self.message = nil
                } else {
                    self.message = error.localizedDescription
                }
            }
        }
    }

    /// OPPTZControl (1400) para o canal do equipamento (câmera ou NVR).
    private static func sendDVRIP(_ command: PTZCommand, to camera: Camera, step: Int, preset: Int, tour: Int) async throws {
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
    }

    // MARK: - ONVIF (câmeras de outras marcas)

    /// Mesmos botões pelo PTZ padrão do ONVIF: setas e zoom viram movimento contínuo (velocidade 1–8 → 0,125–1),
    /// soltar vira Stop; presets pelo número (nome ou token igual ao número; senão, a posição na lista).
    /// Foco, íris e ronda não fazem parte do PTZ básico do ONVIF.
    private func sendONVIF(_ command: PTZCommand, step: Int, preset: Int) async {
        let services = OnvifServices.shared
        let speed = Double(max(step, 1)) / 8
        var x = 0.0, y = 0.0, zoom = 0.0
        switch command {
        case .left: x = -speed
        case .right: x = speed
        case .up: y = speed
        case .down: y = -speed
        case .upLeft: (x, y) = (-speed, speed)
        case .upRight: (x, y) = (speed, speed)
        case .downLeft: (x, y) = (-speed, -speed)
        case .downRight: (x, y) = (speed, -speed)
        case .zoomIn: zoom = speed
        case .zoomOut: zoom = -speed
        case .gotoPreset, .setPreset, .clearPreset:
            do {
                try await presetONVIF(command, number: preset)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            return
        default:
            message = String(localized: "Foco, íris e ronda não existem no PTZ pelo ONVIF.")
            return
        }
        do {
            if step == 0 {
                // Parar é o mais importante (senão a câmera segue girando): tenta mais vezes se a conexão cair.
                let isZoom = command == .zoomIn || command == .zoomOut
                try await services.stopPTZ(camera, panTilt: !isZoom, zoom: isZoom)
            } else {
                try await services.ptz(camera, action: "ContinuousMove", attempts: 3) {
                    OnvifPTZ.continuousMove(profile: $0, x: x, y: y, zoom: zoom)
                }
            }
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func presetONVIF(_ command: PTZCommand, number: Int) async throws {
        let services = OnvifServices.shared
        let list = OnvifPTZ.presetList(try await services.ptz(camera, action: "GetPresets") { OnvifPTZ.presets(profile: $0) })
        let label = String(number)
        let existing = list.first { $0.name == label || $0.token == label }
        switch command {
        case .gotoPreset:
            guard let token = existing?.token ?? (list.indices.contains(number - 1) ? list[number - 1].token : nil) else {
                message = String(localized: "O preset \(number) ainda não foi gravado nesta câmera.")
                return
            }
            try await services.ptz(camera, action: "GotoPreset") { OnvifPTZ.gotoPreset(profile: $0, token: token) }
        case .setPreset:
            try await services.ptz(camera, action: "SetPreset") { OnvifPTZ.setPreset(profile: $0, name: label, token: existing?.token) }
        default:
            if let token = existing?.token {
                try await services.ptz(camera, action: "RemovePreset") { OnvifPTZ.removePreset(profile: $0, token: token) }
            }
        }
    }
}
