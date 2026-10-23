import SwiftUI

/// Categorias de configuração da câmera; as próximas fases entram aqui.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case imageParams
    case recording
    case snapshot
    case smartAlert
    case disk
    case network
    case version

    var id: String { rawValue }
    var title: String {
        switch self {
        case .imageParams: return "Imagem e visão noturna"
        case .recording: return "Gravação"
        case .snapshot: return "Fotos automáticas"
        case .smartAlert: return "Detecção inteligente"
        case .disk: return "Disco / cartão"
        case .network: return "Rede"
        case .version: return "Informações"
        }
    }

    /// Nome da mesma tela no VMS antigo, para quem está acostumado com ele.
    var original: String {
        switch self {
        case .imageParams: return "Parâmetros da cam"
        case .recording: return "Config. de gravação"
        case .snapshot: return "Config. de foto"
        case .smartAlert: return "Smart alert"
        case .disk: return "Gerenciamento de disco"
        case .network: return "Rede"
        case .version: return "Versão"
        }
    }

    var subtitle: String {
        switch self {
        case .imageParams: return "Brilho, cores, espelhar e modo noturno"
        case .recording: return "Quando gravar e tamanho dos arquivos"
        case .snapshot: return "Captura de fotos por horário ou intervalo"
        case .smartAlert: return "Movimento, pessoas e o que fazer ao detectar"
        case .disk: return "Espaço livre, estado e disco cheio"
        case .network: return "Endereço IP, DNS e portas"
        case .version: return "Modelo, firmware e número de série"
        }
    }

    var group: SettingsGroup {
        switch self {
        case .imageParams: return .image
        case .recording, .snapshot, .disk: return .storage
        case .smartAlert: return .alarms
        case .network, .version: return .device
        }
    }
    var icon: String {
        switch self {
        case .imageParams: return "camera.aperture"
        case .recording: return "record.circle"
        case .snapshot: return "camera"
        case .smartAlert: return "figure.walk.motion"
        case .disk: return "internaldrive"
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
        case .camera: return [.imageParams, .recording, .snapshot, .smartAlert, .disk, .network, .version]
        case .recorder: return [.disk, .network, .version]
        case .channel: return [.imageParams, .recording, .snapshot, .smartAlert]
        }
    }
}

/// Alvo da janela de configurações; `camera` é o canal (ou, para o NVR, qualquer canal dele).
struct SettingsTarget: Identifiable {
    let id = UUID()
    let camera: Camera
    let scope: SettingsScope

    var title: String {
        switch scope {
        case .recorder: return camera.group ?? camera.host
        case .camera, .channel: return camera.displayName
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var category: SettingsCategory?

    init(category: SettingsCategory?) {
        self.category = category
    }
}

/// Janela de configurações (equivalente às telas de configuração do VMS antigo).
struct CameraSettingsView: View {
    let target: SettingsTarget
    private var camera: Camera { target.camera }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var navigation: SettingsNavigation

    init(target: SettingsTarget) {
        self.target = target
        _navigation = StateObject(wrappedValue: SettingsNavigation(category: target.scope.categories.first))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $navigation.category) {
                    ForEach(SettingsGroup.allCases, id: \.self) { group in
                        let items = target.scope.categories.filter { $0.group == group }
                        if !items.isEmpty {
                            Section(group.rawValue) {
                                ForEach(items) { category in
                                    Label(category.title, systemImage: category.icon)
                                        .help("\(category.subtitle). No VMS antigo: \(category.original)")
                                    .tag(category)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 220)

                Divider()

                Group {
                    switch navigation.category {
                    case .imageParams:
                        CameraParamsView(camera: camera)
                    case .recording:
                        RecordingConfigView(camera: camera)
                    case .snapshot:
                        PhotoConfigView(camera: camera)
                    case .smartAlert:
                        SmartAlertView(camera: camera)
                    case .disk:
                        DiskView(camera: camera)
                    case .network:
                        NetworkView(camera: camera)
                    case .version:
                        VersionView(camera: camera)
                    case nil:
                        Text("Escolha uma categoria").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                Label(target.title, systemImage: target.scope == .recorder ? "server.rack" : "video")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 920, idealWidth: 960, minHeight: 640, idealHeight: 700)
    }
}
