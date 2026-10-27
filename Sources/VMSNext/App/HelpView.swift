import SwiftUI

/// Ajuda do VMS Next (menu Ajuda): versão, criador, licença e um guia rápido.
struct HelpView: View {
    private var version: String { AppInfo.fullVersion }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    AppLogo(size: 84)
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
                section(String(localized: "Primeiros passos"), [
                    String(localized: "Dispositivos → Procurar na rede encontra as câmeras e NVRs Xiongmai da sua rede. Clique em Adicionar… e digite o usuário e a senha do equipamento."),
                    String(localized: "As senhas ficam num cofre criptografado só deste Mac. Para levar a lista a outro Mac, use + → Exportar câmeras (as senhas não vão junto)."),
                ])
                section(String(localized: "Ao vivo"), [
                    String(localized: "Duplo clique numa câmera abre em tela cheia; na barra de baixo ficam som, conversa (o microfone do Mac sai no alto-falante da câmera), HD/SD, foto e Gravar."),
                    String(localized: "Embaixo do mosaico: modelo de tela (arraste câmeras da lista para os quadros) e rodízio de telas."),
                    String(localized: "Zoom digital: roda do mouse em cima do quadro (amplia onde o mouse está), pinça no trackpad ou os botões da lateral; arraste para mover."),
                    String(localized: "PTZ: o botão PTZ do quadro abre o controle no pé da lista de câmeras, com setas, zoom, foco, presets e ronda."),
                    String(localized: "Câmeras duplas: botão direito → Dividir em duas (split virtual)."),
                ])
                section(String(localized: "Gravações"), [
                    String(localized: "Escolha a câmera na lista: a linha do tempo mostra o dia, com uma faixa e uma cor por tipo (alarme, movimento, manual, contínua). Clique num ponto para assistir dali."),
                    String(localized: "As setas ‹ › de cada tipo levam ao trecho anterior ou ao próximo. A data abre o calendário, que marca os dias com gravação e os dias com vídeo baixado."),
                    String(localized: "Baixar salva em MP4 direto na pasta das Preferências; os baixados ficam com o selo No Mac. Tags marcam vídeos para achar depois, de qualquer dia."),
                    String(localized: "Câmera sem cartão que grava no NVR: Editar câmera → Gravações → NVR (ou Cartão e NVR, com a chave para trocar)."),
                ])
                section(String(localized: "Eventos e alertas"), [
                    String(localized: "Antes de avisar, a IA do Mac (Vision, sem internet) analisa a foto do alerta e diz o que apareceu: pessoa, veículo, animal. Movimento sem nada vira provável falso alarme."),
                    String(localized: "Cada alerta tem gravidade, nota, soneca e ▶ Play, que abre a gravação com a agulha no horário do alerta (marca vermelha na linha do tempo)."),
                    String(localized: "Na barra de menus: últimos alertas, ligar e desligar os avisos e escolher as câmeras silenciadas. Registro mostra o que aconteceu no app e nos equipamentos."),
                ])
                section(String(localized: "Configurações e preferências"), [
                    String(localized: "Configurações: ajustes da câmera ou do NVR escolhido na lista, organizados por assunto. Só aparecem as opções que o equipamento tem."),
                    String(localized: "Rede e Wi-Fi: endereço, DNS e portas como no VMS antigo; o Wi-Fi procura redes e troca de rede com segurança, achando a câmera de novo depois."),
                    String(localized: "Alarmes: a voz que a câmera toca e em que horários, detecção de rosto e o alarme manual (disparar e parar pelo Mac, no NVR)."),
                    String(localized: "Preferências (⌘,): idioma, pastas, aparência, gravação no Mac, sons e segundo plano. Ajustes dos alertas (em Eventos): notificações, sons e a IA."),
                ])
                Text("O VMS Next fala direto com os equipamentos na sua rede, sem nuvem e sem o SDK da fabricante. É um projeto independente, sem ligação com a Xiongmai.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Space.xxl)
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
