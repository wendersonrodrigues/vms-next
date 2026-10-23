import SwiftUI

/// Categorias de configuração da câmera; as próximas fases entram aqui.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case imageParams
    case network

    var id: String { rawValue }
    var title: String {
        switch self {
        case .imageParams: return "Parâmetros da cam"
        case .network: return "Rede"
        }
    }
    var icon: String {
        switch self {
        case .imageParams: return "camera.aperture"
        case .network: return "network"
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var category: SettingsCategory? = .imageParams
}

/// Janela de configurações de uma câmera (equivalente às telas de configuração do VMS antigo).
struct CameraSettingsView: View {
    let camera: Camera

    @Environment(\.dismiss) private var dismiss
    @StateObject private var navigation = SettingsNavigation()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(SettingsCategory.allCases, selection: $navigation.category) { category in
                    Label(category.title, systemImage: category.icon).tag(category)
                }
                .listStyle(.sidebar)
                .frame(width: 200)

                Divider()

                Group {
                    switch navigation.category {
                    case .imageParams:
                        CameraParamsView(camera: camera)
                    case .network:
                        NetworkView(camera: camera)
                    case nil:
                        Text("Escolha uma categoria").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                Text(camera.name).foregroundStyle(.secondary)
                Spacer()
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 540)
    }
}
