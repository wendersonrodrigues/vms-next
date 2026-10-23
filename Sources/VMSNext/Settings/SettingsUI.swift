import SwiftUI

/// Rótulo de configuração: nome em português claro, nome original entre parênteses quando ajuda
/// a achar a função no VMS antigo/iCSee, e uma explicação curta embaixo.
struct FieldLabel: View {
    let title: String
    var original: String?
    var detail: String?

    init(_ title: String, original: String? = nil, detail: String? = nil) {
        self.title = title
        self.original = original
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let original {
                Text(title) + Text(" (\(original))").foregroundColor(.secondary)
            } else {
                Text(title)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Grupos da barra lateral da janela de configurações.
enum SettingsGroup: String, CaseIterable {
    case image = "Imagem"
    case storage = "Gravação e armazenamento"
    case alarms = "Alarmes"
    case device = "Equipamento"
}
