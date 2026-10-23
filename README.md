# VMS Next

App nativo para **Mac com Apple Silicon** dedicado a câmeras e NVRs **Xiongmai** (XMEye / iCSee), feito em Swift e SwiftUI.

Reúne num só lugar o ao vivo, as gravações, os alertas e todas as configurações dos equipamentos. Roda em arm64, decodifica vídeo pelo hardware do chip M e conversa direto com as câmeras pela rede local, sem nuvem e sem o SDK da fabricante. Cobre as funções do VMS V2.2.1.1 para Mac (app para Intel, que depende do Rosetta) e acrescenta outras.

Versão atual: **0.10.0**. Código aberto, [licença MIT](LICENSE).

## Funcionalidades

### Início
- Painel com **temperatura** da sua cidade, **alertas de hoje**, **equipamentos conectados**, total de câmeras e **armazenamento** de cada disco, com a origem (HD do NVR ou cartão da câmera) e o tipo de gravação (cíclica ou para quando enche).
- **Conexão de cada equipamento** (conectado, sem conexão e o motivo) com atalhos para o ao vivo e as configurações.
- Menu de ícones para todas as áreas do app.

### Ao vivo
- **Modelos de tela**: Auto (todas as câmeras no melhor tamanho), 1, 4, 1 grande + 5, 1 grande + 7, 9 e 16, em botões na barra de baixo.
- **Arrastar e soltar** câmeras da lista para os quadros; cada modelo guarda as posições.
- **Modelos personalizados**: grade de até 6 × 6 com quadros juntados.
- **Rodízio de telas** (Tour): passa sozinho pelas telas escolhidas, com tempo ajustável.
- **Split virtual** para câmeras duplas: uma imagem vira dois quadros (cima e baixo) com um só vídeo da câmera, nomes próprios e o nome oficial sempre junto.
- Câmera em tela cheia com barra de baixo: **som**, **HD/SD**, **zoom digital** (botões, pinça no trackpad e arrastar), **Gravar** e **PTZ**.
- **PTZ**: 8 direções, velocidade, zoom óptico, foco, íris, presets e **ronda** (passeio entre presets).
- **Áudio** G.711 das câmeras, um som por vez.
- Lista de câmeras **reordenável** arrastando; NVR como grupo com seus canais.
- Vídeo H.264 e H.265 por RTSP ou pelo protocolo Xiongmai, com reconexão automática.

### Gravações
- A câmera vem da lista ao lado e a busca do dia é automática.
- Reprodução com pausa, saltos de 10 s, barra de progresso, velocidade de ½× a 8× e som.
- **Download em MP4** (vídeo sem recomprimir e som em AAC).
- **Zoom digital** e **foto do quadro**, inteira ou só da parte ampliada.

### Gravação no Mac
- Botão **Gravar** em cada câmera: grava o vídeo principal em MP4 no disco do Mac.
- **Gravação automática** por horário, para todas as câmeras ou só as escolhidas.
- Arquivos de 5 a 120 minutos, reserva de espaço livre e, com o disco cheio, parar ou apagar as mais antigas.

### Eventos
- Alertas das câmeras e do NVR, **guardados no Mac** entre aberturas.
- Em cada alerta: **Ao vivo** e **Gravação** (abre a gravação no momento do alerta).
- **Notificações do macOS** e **som no Mac** por tipo de alerta (sons do sistema ou arquivo próprio).
- **Alertas repetidos juntados** quando a mesma câmera avisa por ela e pelo NVR.
- **Registro**: o que aconteceu no app (entradas, configurações alteradas, reinícios, fotos, downloads) e o registro guardado em cada equipamento, com filtro por data e tipo e exportação em CSV.

### Dispositivos
- **Procurar na rede** (IPV4 pesquisar): encontra câmeras e NVRs Xiongmai da rede local, com IP, MAC e CloudID.
- Lista dos equipamentos cadastrados, com editar e configurações.
- **Importar e exportar** a lista de câmeras para outro Mac (sem as senhas).
- Senha salva visível no editor (botão de olho).

### Config. câmeras
Configurações embutidas na janela, para a câmera, o NVR ou o canal escolhido na lista. Começam num menu de ícones e mantêm a tela aberta ao trocar de câmera. Só aparecem as telas e opções que o equipamento informa ter (capacidades `SystemFunction`, `EncodeCapability` e outras).

- **Imagem e visão noturna**: brilho, contraste, saturação, matiz, espelhar, virar, contraluz, anti-cintilação e os modos de visão noturna (colorida, infravermelha e luz dupla), com **prévia ilustrada** de cada ajuste.
- **Exposição e ajustes finos**: modo de exposição com os tempos da câmera, ganho, faixa dinâmica (WDR), ruído, estilo e filtro IR.
- **Texto na imagem** e máscaras de privacidade.
- **Qualidade do vídeo e som**: compressão (H.265X/H.265), resolução, qualidade, FPS, CBR/VBR, taxa de bits, intervalo de quadro, áudio e Smart Encode (H265AI), com aviso para reiniciar.
- **Gravação** com agenda semanal pintável, **Fotos automáticas** e **Disco / cartão**.
- **Alarmes**: detecção inteligente com área e linha de aviso, perda de vídeo, câmera bloqueada, veículos, problemas no equipamento e saída de alarme.
- **Equipamento**: sistema e horário, manutenção, usuários, restaurar padrão, rede, serviços de rede (nuvem, RTSP, filtro de IP, Wi-Fi, notificações no celular), **PTZ por cabo** (RS485) e informações.
- **Diagnóstico** em JSON (sem senhas) em cada tela, e **Capacidades…** em Informações.

### Preferências do app
- Tema claro, escuro ou igual ao Mac.
- Pastas de fotos, downloads e gravações, e se pergunta onde salvar.
- Voltar para onde parei, lembrar login, acertar o relógio das câmeras, qualidade ao abrir uma câmera.
- Captura automática de fotos, quantos alertas guardar e por quanto tempo guardar o registro.
- Segundo plano: ícone na barra de menus, alertas com a janela fechada, abrir junto com o Mac e esconder do Dock.

### Segurança
- Tudo roda na **rede local**; nada vai para a nuvem.
- Login no app e senhas das câmeras num **cofre criptografado** (AES-GCM, chave derivada da senha do VMS Next), só neste Mac.
- Depois de uma senha recusada, o app **não repete o login** até a senha ser trocada, para a câmera não bloquear o usuário.
- Configurações gravadas no modo *ler, alterar e devolver*: campos que o app não conhece são preservados.
- Diagnósticos e exportações nunca incluem senhas.

## Requisitos

- Mac com **Apple Silicon**.
- **macOS 14** ou mais novo (foto do quadro: macOS 14.4).
- Swift 6 (Command Line Tools ou Xcode) para compilar.
- NVRs com **Criptografia de rede** em "Login de rede precisa de criptografia" recusam o app; use "Login remoto precisa de criptografia".

## Compilar e executar

```bash
./scripts/bundle.sh
open "build/VMS Next.app"
```

O script compila em modo release para arm64 e monta `build/VMS Next.app` com assinatura ad-hoc, os ícones, as imagens de exemplo e a tradução dos menus. Na primeira execução, o macOS pede acesso à **rede local**, necessário para falar com as câmeras.

O projeto é um Swift Package (`Package.swift`) e também abre direto no Xcode.

## Como funciona

| Camada | Pasta | Responsabilidade |
|---|---|---|
| App | `Sources/VMSNext/App` | Janela principal, Início, coluna de ícones, Dispositivos, preferências, tema, modelos de tela e rodízio |
| Streaming | `Sources/VMSNext/Streaming` | Cliente RTSP próprio (Digest, TCP interleaved), SDP e depacketização RTP H.264/H.265 |
| Vídeo | `Sources/VMSNext/Video` | `CMSampleBuffer`, exibição em `AVSampleBufferDisplayLayer`, vídeo compartilhado entre quadros, split, zoom, foto e gravação no Mac |
| Áudio | `Sources/VMSNext/Audio` | Decodificação G.711 e reprodução |
| DVRIP | `Sources/VMSNext/DVRIP` | Protocolo da Xiongmai (porta 34567): login, comandos, configurações em JSON e busca na rede (porta 34569) |
| PTZ | `Sources/VMSNext/PTZ` | Comandos `OPPTZControl`, presets e ronda |
| Reprodução | `Sources/VMSNext/Playback` | Busca (`OPFileQuery`), conexão de mídia, parser dos quadros Xiongmai, player e download em MP4 |
| Alarmes | `Sources/VMSNext/Alarms` | Alertas (`GUARD`), notificações, sons, histórico e registro |
| Configurações | `Sources/VMSNext/Settings` | Telas de configuração, formulários a partir das capacidades do equipamento e diagnóstico |
| Modelos | `Sources/VMSNext/Models` | Câmeras (`cameras.json` em Application Support), cofre de senhas (`vault.json`) e modelos de tela |

O roteiro e os formatos aprendidos de cada configuração estão em [PLANO-MVP.md](PLANO-MVP.md).

## Créditos

Criado por **Wenderson Rodrigues**. Ícones e imagens de exemplo gerados no Magnific.

## Aviso

Projeto independente, sem relação com a Xiongmai. Feito para controlar equipamentos próprios na rede local.
