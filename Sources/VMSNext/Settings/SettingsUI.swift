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

/// Rodapé padrão das telas de configuração que gravam no equipamento: aviso de "aplicado" à esquerda e
/// Diagnóstico…, Recarregar e Aplicar à direita, sempre nessa ordem (Aplicar é a ação principal, com Return).
struct SettingsFooter: View {
    let notice: String?
    /// Lendo ou gravando: trava os três botões.
    let busy: Bool
    /// Motivo próprio da tela para não deixar aplicar (nada mudou, campo inválido…).
    var applyDisabled = false
    let onDiagnostic: () async -> Void
    let onReload: () async -> Void
    let onApply: () -> Void

    var body: some View {
        HStack {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success).lineLimit(2)
            }
            Spacer()
            Button("Diagnóstico…") { Task { await onDiagnostic() } }
                .disabled(busy)
            Button("Recarregar") { Task { await onReload() } }
                .keyboardShortcut("r")
                .disabled(busy)
            Button("Aplicar", action: onApply)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || applyDisabled)
        }
        .padding(Space.m)
    }
}
