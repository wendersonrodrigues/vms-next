import SwiftUI

/// Ajuda do VMS Next (menu Ajuda): versão, criador, licença e um guia rápido.
struct HelpView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "—") (\(info?["CFBundleVersion"] as? String ?? "—"))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VMS Next").font(.largeTitle.weight(.bold))
                        Text("Versão \(version)").foregroundStyle(.secondary)
                        Text("Criado por Wenderson Rodrigues")
                        HStack(spacing: 12) {
                            Link("Projeto no GitHub", destination: NavigationRail.githubURL)
                            Link("Licença MIT (código aberto)", destination: NavigationRail.githubURL.appendingPathComponent("blob/main/LICENSE"))
                        }
                    }
                }
                Divider()
                section("Primeiros passos", [
                    "Dispositivos → Procurar na rede encontra as câmeras e NVRs Xiongmai da sua rede. Clique em Adicionar… e digite o usuário e a senha do equipamento.",
                    "As senhas ficam num cofre criptografado só deste Mac. Para levar a lista a outro Mac, use + → Exportar câmeras (as senhas não vão junto).",
                ])
                section("Ao vivo", [
                    "Duplo clique numa câmera abre em tela cheia; na barra de baixo ficam som, HD/SD, zoom digital, Gravar e PTZ.",
                    "Embaixo do mosaico: modelo de tela (arraste câmeras da lista para os quadros) e rodízio de telas.",
                    "Câmeras duplas: botão direito → Dividir em duas (split virtual).",
                ])
                section("Gravações e eventos", [
                    "Gravações: escolha a câmera na lista e o dia; a busca é automática. Dá para baixar em MP4 e tirar foto do quadro.",
                    "Eventos: alertas das câmeras (guardados no Mac), com atalhos para o ao vivo e a gravação do momento. Registro mostra o que aconteceu no app e nos equipamentos.",
                ])
                section("Configurações e preferências", [
                    "Configurações: ajustes da câmera ou do NVR escolhido na lista, organizados por assunto. Só aparecem as opções que o equipamento tem.",
                    "Preferências do app: pastas, aparência, gravação no Mac, sons e segundo plano.",
                ])
                Text("O VMS Next fala direto com os equipamentos na sua rede, sem nuvem e sem o SDK da fabricante. É um projeto independente, sem ligação com a Xiongmai.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: "circle.fill")
                    .labelStyle(BulletLabel())
            }
        }
    }
}

private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
