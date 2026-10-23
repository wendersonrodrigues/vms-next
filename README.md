# VMS Next

Cliente nativo para **Apple Silicon** de câmeras e NVRs **Xiongmai** (XMEye / iCSee), feito em Swift e SwiftUI.

Substitui o **VMS V2.2.1.1** da Xiongmai, um app Qt 5.7 compilado só para Intel (x86_64) que foi abandonado pelo fabricante e depende do Rosetta, cujo suporte termina no macOS 27. O VMS Next roda nativamente em arm64, decodifica vídeo pelo hardware do chip M e conversa com as câmeras sem o SDK da Xiongmai e sem passar pela nuvem.

## Funcionalidades

### Visualização ao vivo
- Mosaico de **1, 4, 9 ou 16** câmeras, com paginação.
- **Duplo clique** abre a câmera em tela única; duplo clique de novo volta ao mosaico.
- Stream **extra** (mais leve) no mosaico e **principal** na tela única.
- Vídeo **H.264 e H.265** decodificado por hardware (VideoToolbox).
- **Reconexão automática** quando a câmera cai.
- **NVR como grupo**, como no VMS antigo: o mosaico principal mostra as câmeras avulsas, e clicando no NVR aparecem só os canais dele.
- Vídeo por **RTSP** ou pelo **protocolo Xiongmai** (automático para câmeras de várias lentes, cujo RTSP ignora o canal).

### Câmeras
- Cadastro manual (nome, IP, portas, canal, usuário) ou **importação do VMS antigo** (lê nome, IP e canais do `devices.db`; as senhas não são importadas).
- Senhas guardadas no **Keychain** do macOS, compartilhadas por todos os canais do mesmo equipamento.
- Caminho RTSP configurável (padrão Xiongmai já preenchido).

### PTZ
- Painel ao lado da câmera em tela única: **8 direções**, zoom, foco e íris enquanto o botão está pressionado.
- Velocidade de 1 a 8.
- **Presets**: salvar, ir e apagar.

### Gravações
- Busca por câmera ou canal do NVR e por dia, com tipo de cada arquivo (contínua, movimento, alarme, manual).
- Reprodução com pausa, velocidade de ½× a 8× e relógio com a hora da gravação.
- Diagnóstico da busca, que mostra os discos do equipamento e o código de cada tentativa.
- NVRs com **Criptografia de rede** em "Login de rede precisa de criptografia" recusam o app; use "Login remoto precisa de criptografia".

### Configurações da câmera
Janela de configurações por câmera (botão direito → **Configurações…** ou engrenagem na tela única):

- **Parâmetros da cam**: brilho, contraste, saturação, matiz, espelhar, inverter, compensação de contraluz (BLC) e anti-cintilação.
- **Visão noturna** para câmeras de luz dupla, com os mesmos modos do iCSee:
  - *Visão noturna colorida* (luz branca acende com pouca luz);
  - *Visão noturna infravermelha* (preto e branco);
  - *Alerta de luz dupla* (infravermelho; a luz branca acende ao detectar pessoas), com sensibilidade e duração da luz.
- No **NVR**, as configurações do equipamento (Rede, Versão) ficam separadas das de cada canal (Parâmetros da cam).
- **Rede**: IP, máscara, gateway, DHCP, DNS e porta HTTP, com validação, confirmação antes de trocar o endereço e atualização automática das câmeras daquele IP no app.
- **Versão**: modelo, firmware, número de série, tempo ligado e canais.
- **Diagnóstico**: mostra em JSON as configurações lidas da câmera (sem senhas), para identificar campos de modelos diferentes.

### Segurança
- Tudo roda na **rede local**; nenhum dado vai para a nuvem da Xiongmai.
- Depois de uma senha recusada, o app **não repete o login** até a senha ser trocada, para a câmera não bloquear o usuário.
- Configurações são gravadas no modo *ler, alterar e devolver*: campos que o app não conhece são preservados.

## Roteiro

| Fase | Conteúdo | Situação |
|---|---|---|
| MVP | Visualização ao vivo, mosaico, importação do VMS antigo | Concluída |
| 2 · Essenciais | PTZ, Parâmetros da cam, Rede, Versão | Concluída |
| 3 · Gravação e disco | Reprodução das gravações (concluída); config. de gravação, disco, foto | Em andamento |
| 4 · Alarmes | Detecção de pessoas/veículos, áreas de aviso, perda de vídeo, notificações do macOS | Planejada |
| 5 · Avançados | Sistema, data/hora, sobreposição de texto, usuários, manutenção | Planejada |

O plano detalhado está em [PLANO-MVP.md](PLANO-MVP.md).

## Requisitos

- Mac com **Apple Silicon**.
- **macOS 14** ou mais novo.
- Swift 6 (Command Line Tools ou Xcode) para compilar.

## Compilar e executar

```bash
./scripts/bundle.sh
open "build/VMS Next.app"
```

O script compila em modo release para arm64 e monta `build/VMS Next.app` com assinatura ad-hoc. Na primeira execução, o macOS pede permissão de acesso à **rede local**, necessária para falar com as câmeras.

O projeto é um Swift Package (`Package.swift`) e também abre direto no Xcode.

## Como funciona

| Camada | Pasta | Responsabilidade |
|---|---|---|
| Streaming | `Sources/VMSNext/Streaming` | Cliente RTSP próprio (Digest, TCP interleaved), parser de SDP e depacketização RTP H.264/H.265 |
| Vídeo | `Sources/VMSNext/Video` | Montagem de `CMSampleBuffer` e exibição em `AVSampleBufferDisplayLayer` |
| DVRIP | `Sources/VMSNext/DVRIP` | Protocolo de controle da Xiongmai (porta 34567): login, keep-alive, comandos e configurações em JSON |
| PTZ | `Sources/VMSNext/PTZ` | Comandos `OPPTZControl` e painel de controle |
| Reprodução | `Sources/VMSNext/Playback` | Busca (`OPFileQuery`), conexão de mídia (Claim), parser dos quadros Xiongmai e player com ritmo próprio |
| Configurações | `Sources/VMSNext/Settings` | Telas de Parâmetros da cam, Rede, Versão e diagnóstico |
| Modelos | `Sources/VMSNext/Models` | Câmeras (`cameras.json` em Application Support) e Keychain |
| Importação | `Sources/VMSNext/Import` | Leitura do `devices.db` do VMS antigo |

## Aviso

Projeto independente, sem relação com a Xiongmai. Feito para controlar equipamentos próprios na rede local.
