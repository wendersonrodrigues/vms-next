import SwiftUI

/// Categorias de configuração da câmera; as próximas fases entram aqui.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case imageParams
    case exposure
    case encoding
    case overlay
    case recording
    case snapshot
    case smartAlert
    case videoLoss
    case blind
    case vehicle
    case abnormality
    case alarmOutput
    case disk
    case dateTime
    case maintenance
    case users
    case defaults
    case network
    case netServices
    case ptzSerial
    case version

    var id: String { rawValue }
    var title: String {
        switch self {
        case .imageParams: return "Imagem e visão noturna"
        case .exposure: return "Exposição e ajustes finos"
        case .encoding: return "Qualidade do vídeo e som"
        case .netServices: return "Serviços de rede"
        case .ptzSerial: return "PTZ por cabo"
        case .overlay: return "Texto na imagem"
        case .recording: return "Gravação"
        case .snapshot: return "Fotos automáticas"
        case .smartAlert: return "Detecção inteligente"
        case .videoLoss: return "Perda de vídeo"
        case .blind: return "Câmera bloqueada"
        case .vehicle: return "Detecção de veículos"
        case .abnormality: return "Problemas no equipamento"
        case .alarmOutput: return "Saída de alarme"
        case .disk: return "Disco / cartão"
        case .dateTime: return "Sistema e horário"
        case .maintenance: return "Manutenção"
        case .users: return "Usuários"
        case .defaults: return "Restaurar padrão"
        case .network: return "Rede"
        case .version: return "Informações"
        }
    }

    /// Nome da mesma tela no VMS antigo, para quem está acostumado com ele.
    var original: String {
        switch self {
        case .imageParams: return "Parâmetros da cam"
        case .exposure: return "Parâmetros da cam"
        case .encoding: return "Mídia"
        case .netServices: return "Rede (Nuvem, RTSP, Wifi…)"
        case .ptzSerial: return "Config. de PTZ"
        case .overlay: return "Sobrepor"
        case .recording: return "Config. de gravação"
        case .snapshot: return "Config. de foto"
        case .smartAlert: return "Smart alert"
        case .videoLoss: return "Video Loss"
        case .blind: return "Video Blind"
        case .vehicle: return "CarShape Detect"
        case .abnormality: return "Anormalidade"
        case .alarmOutput: return "Saída de alarme"
        case .disk: return "Gerenciamento de disco"
        case .dateTime: return "Config. do sistema"
        case .maintenance: return "Manutenção"
        case .users: return "Usuários"
        case .defaults: return "Padrão"
        case .network: return "Rede"
        case .version: return "Versão"
        }
    }

    var subtitle: String {
        switch self {
        case .imageParams: return "Brilho, cores, espelhar e modo noturno"
        case .exposure: return "Exposição, ganho, ruído e filtro IR"
        case .encoding: return "Resolução, compressão, FPS e áudio"
        case .netServices: return "Nuvem, RTSP, filtro de IP, Wi-Fi e alertas no celular"
        case .ptzSerial: return "Protocolo e porta serial RS485 do motor"
        case .overlay: return "Nome do canal e data/hora sobre o vídeo"
        case .recording: return "Quando gravar e tamanho dos arquivos"
        case .snapshot: return "Captura de fotos por horário ou intervalo"
        case .smartAlert: return "Movimento, pessoas e o que fazer ao detectar"
        case .videoLoss: return "Aviso quando a imagem do canal some"
        case .blind: return "Aviso quando a lente é coberta"
        case .vehicle: return "Aviso quando aparece um carro ou moto"
        case .abnormality: return "Disco, rede e conflito de IP"
        case .alarmOutput: return "Sirene, luz ou relé ligados ao equipamento"
        case .disk: return "Espaço livre, estado e disco cheio"
        case .dateTime: return "Relógio, fuso, nome e idioma do equipamento"
        case .maintenance: return "Reiniciar e reinício automático"
        case .users: return "Contas e senhas do equipamento"
        case .defaults: return "Voltar configurações de fábrica"
        case .network: return "Endereço IP, DNS e portas"
        case .version: return "Modelo, firmware e número de série"
        }
    }

    var group: SettingsGroup {
        switch self {
        case .imageParams, .exposure, .overlay: return .image
        case .encoding, .recording, .snapshot, .disk: return .storage
        case .smartAlert, .videoLoss, .blind, .vehicle, .abnormality, .alarmOutput: return .alarms
        case .dateTime, .maintenance, .users, .defaults, .network, .netServices, .ptzSerial, .version: return .device
        }
    }
    /// Funções de SystemFunction que liberam a tela (basta uma). Vazio = sempre aparece.
    var requiredFunctions: [String] {
        switch self {
        case .smartAlert: return ["AlarmFunction.MotionDetect", "AlarmFunction.HumanDection", "AlarmFunction.HumanDectionNVRNew"]
        case .videoLoss: return ["AlarmFunction.LossDetect"]
        case .blind: return ["AlarmFunction.BlindDetect"]
        case .vehicle: return ["AlarmFunction.CarShapeDetection"]
        case .abnormality: return ["AlarmFunction.StorageNotExist", "AlarmFunction.StorageFailure",
                                   "AlarmFunction.NetAbort", "AlarmFunction.NetIpConflict"]
        case .ptzSerial: return ["CommFunction.CommRS485", "CommFunction.CommRS232"]
        default: return []
        }
    }

    func isSupported(by functions: [String: Any]?) -> Bool {
        requiredFunctions.isEmpty || requiredFunctions.contains { DeviceCapabilities.supports(functions, $0) }
    }

    var icon: String {
        switch self {
        case .imageParams: return "camera.aperture"
        case .exposure: return "sun.max"
        case .encoding: return "film"
        case .netServices: return "antenna.radiowaves.left.and.right"
        case .ptzSerial: return "cable.connector"
        case .overlay: return "textformat"
        case .recording: return "record.circle"
        case .snapshot: return "camera"
        case .smartAlert: return "figure.walk.motion"
        case .videoLoss: return "video.slash"
        case .blind: return "eye.slash"
        case .vehicle: return "car"
        case .abnormality: return "exclamationmark.triangle"
        case .alarmOutput: return "light.beacon.max"
        case .disk: return "internaldrive"
        case .dateTime: return "clock"
        case .maintenance: return "wrench.and.screwdriver"
        case .users: return "person.2"
        case .defaults: return "arrow.counterclockwise"
        case .network: return "network"
        case .version: return "info.circle"
        }
    }
}

/// O que está sendo configurado: uma câmera avulsa, o NVR em si ou um canal do NVR.
enum SettingsScope {
    case camera
    case recorder
    case channel

    var categories: [SettingsCategory] {
        switch self {
        case .camera: return [.imageParams, .exposure, .overlay, .encoding, .recording, .snapshot, .smartAlert, .blind, .abnormality, .alarmOutput, .disk, .dateTime, .maintenance, .users, .defaults, .network, .netServices, .ptzSerial, .version]
        case .recorder: return [.smartAlert, .blind, .videoLoss, .vehicle, .abnormality, .alarmOutput, .disk, .dateTime, .maintenance, .users, .defaults, .network, .netServices, .version]
        case .channel: return [.imageParams, .exposure, .overlay, .encoding, .recording, .snapshot, .smartAlert, .videoLoss, .blind, .vehicle]
        }
    }
}

/// Alvo da janela de configurações; `camera` é o canal (ou, para o NVR, qualquer canal dele).
struct SettingsTarget: Identifiable {
    let id = UUID()
    let camera: Camera
    let scope: SettingsScope

    /// "Configurações da câmera", "do NVR" ou "do canal".
    var kindLabel: String {
        switch scope {
        case .recorder: return "Configurações do NVR"
        case .channel: return "Configurações do canal do NVR"
        case .camera: return "Configurações da câmera"
        }
    }

    var icon: String { scope == .recorder ? "server.rack" : "video.fill" }

    var title: String {
        switch scope {
        case .recorder: return camera.group ?? camera.host
        case .camera, .channel: return camera.displayName
        }
    }
}

/// Conteúdo de uma categoria de configuração para um alvo (câmera, NVR ou canal).
struct SettingsContent: View {
    let target: SettingsTarget
    let category: SettingsCategory
    private var camera: Camera { target.camera }

    @EnvironmentObject private var store: CameraStore

    /// Canais do NVR: o maior canal cadastrado (mínimo 1); o NVR informa o total exato nas telas que o leem.
    private var recorderChannels: Int {
        max(store.channels(in: camera.group ?? "").map(\.channel).max() ?? 1, 1)
    }

    var body: some View {
        switch category {
        case .imageParams:
            CameraParamsView(camera: camera)
        case .exposure:
            ConfigFormView(camera: camera, spec: ConfigFormSpecs.exposure(camera: camera))
        case .encoding:
            ConfigFormView(camera: camera, spec: ConfigFormSpecs.encoding(camera: camera))
        case .netServices:
            ConfigFormView(camera: camera, spec: ConfigFormSpecs.networkServices(camera: camera))
        case .ptzSerial:
            ConfigFormView(camera: camera, spec: ConfigFormSpecs.ptzSerial(camera: camera))
        case .overlay:
            OverlayView(camera: camera)
        case .recording:
            RecordingConfigView(camera: camera)
        case .snapshot:
            PhotoConfigView(camera: camera)
        case .smartAlert:
            if target.scope == .recorder {
                RecorderChannelView(recorder: camera, channelCount: recorderChannels) { channel in
                    SmartAlertView(camera: channel)
                }
            } else {
                SmartAlertView(camera: camera)
            }
        case .vehicle:
            EventConfigView(camera: camera, screen: .vehicle, allChannels: target.scope == .recorder)
        case .videoLoss:
            EventConfigView(camera: camera, screen: .videoLoss, allChannels: target.scope == .recorder)
        case .blind:
            EventConfigView(camera: camera, screen: .blind, allChannels: target.scope == .recorder)
        case .abnormality:
            EventConfigView(camera: camera, screen: .abnormality)
        case .alarmOutput:
            AlarmOutputView(camera: camera)
        case .disk:
            DiskView(camera: camera)
        case .dateTime:
            DateTimeView(camera: camera)
        case .maintenance:
            MaintenanceView(camera: camera, isRecorder: target.scope == .recorder)
        case .users:
            UsersView(camera: camera)
        case .defaults:
            RestoreDefaultsView(camera: camera)
        case .network:
            NetworkView(camera: camera)
        case .version:
            VersionView(camera: camera)
        }
    }
}

final class SettingsPaneState: ObservableObject {
    /// SystemFunction do equipamento: esconde as telas de funções que ele não tem.
    @Published var functions: [String: Any]?
    @Published var loadedFor: String?
}

/// Configurações embutidas na janela principal (como no VMS antigo): o alvo é o que está escolhido na
/// lista de câmeras ao lado. Sem categoria, mostra o menu de ícones; trocar de câmera mantém a categoria.
struct SettingsPane: View {
    let target: SettingsTarget?
    @Binding var category: SettingsCategory?

    @StateObject private var state = SettingsPaneState()

    fileprivate var available: [SettingsCategory] {
        guard let target else { return [] }
        return target.scope.categories.filter { $0.isSupported(by: state.functions) }
    }

    var body: some View {
        Group {
            if let target {
                if let category, available.contains(category) {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Button {
                                self.category = nil
                            } label: {
                                Label("Todas as configurações", systemImage: "chevron.left")
                            }
                            Divider().frame(height: 16)
                            Image(systemName: category.icon).foregroundStyle(category.group.color)
                            Text(category.title).font(.headline)
                            Text("(\(category.original))").foregroundStyle(.secondary)
                            Spacer()
                            // Sempre à vista: qual equipamento está sendo configurado.
                            HStack(spacing: 8) {
                                Image(systemName: target.icon).foregroundStyle(Color.accentColor)
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(target.kindLabel).font(.caption).foregroundStyle(.secondary)
                                    Text(target.title).font(.headline)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        Divider()
                        HStack(spacing: 0) {
                            quickList
                                .frame(width: 220)
                            Divider()
                            SettingsContent(target: target, category: category)
                                .id("\(target.camera.id)-\(target.scope)-\(category)")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    SettingsMenu(target: target, categories: available) { category = $0 }
                }
            } else {
                ContentUnavailableView {
                    Label("Escolha um equipamento", systemImage: "gearshape.2")
                } description: {
                    Text("Clique numa câmera, num NVR ou num canal na lista ao lado para ver as configurações dele.")
                }
            }
        }
        .task(id: target.map { "\($0.camera.host):\($0.camera.dvripPort)" }) {
            guard let target else { return }
            state.functions = nil
            state.functions = await DeviceCapabilities.systemFunction(for: target.camera)
        }
    }
}

extension SettingsPane {
    /// Lista lateral de acesso rápido às outras categorias, enquanto uma está aberta.
    var quickList: some View {
        List(selection: Binding(get: { category }, set: { if let new = $0 { category = new } })) {
            ForEach(SettingsGroup.allCases, id: \.self) { group in
                let items = available.filter { $0.group == group }
                if !items.isEmpty {
                    Section(group.rawValue) {
                        ForEach(items) { item in
                            Label(item.title, systemImage: item.icon)
                                .help("\(item.subtitle). No VMS antigo: \(item.original)")
                                .tag(item)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Menu de ícones por grupo, como a tela de configurações do VMS antigo.
struct SettingsMenu: View {
    let target: SettingsTarget
    let categories: [SettingsCategory]
    let onSelect: (SettingsCategory) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: target.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Color.accentColor.gradient))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.kindLabel).font(.callout).foregroundStyle(.secondary)
                        Text(target.title).font(.title.weight(.bold))
                    }
                }
                Divider()
                ForEach(SettingsGroup.allCases, id: \.self) { group in
                    let items = categories.filter { $0.group == group }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.rawValue)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)], spacing: 12) {
                                ForEach(items) { category in
                                    tile(category, color: group.color)
                                }
                            }
                        }
                        .padding(14)
                        .themedCard(radius: 18)
                    }
                }
            }
            .padding(20)
        }
    }

    private func tile(_ category: SettingsCategory, color: Color) -> some View {
        Button {
            onSelect(category)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 12).fill(color.gradient))
                Text(category.title)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(category.original)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surfaceHigh))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help(category.subtitle)
    }
}

extension SettingsGroup {
    var color: Color {
        switch self {
        case .image: return .orange
        case .storage: return .green
        case .alarms: return .red
        case .device: return .blue
        }
    }
}
