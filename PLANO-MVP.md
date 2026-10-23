# VMS para Apple Silicon — Plano do MVP

Substituto nativo (Swift + SwiftUI, arm64) do VMS V2.2.1.1 da Xiongmai, que é só Intel (x86_64, Qt 5.7).

## Ambiente

- Swift 6.4 via Command Line Tools (sem Xcode): projeto em Swift Package Manager.
- Script `scripts/bundle.sh` empacota o executável em `VMS Next.app`.
- macOS 14+ como alvo mínimo.

## Escopo do MVP

1. **Cadastro de câmeras**
   - Nome, IP, porta RTSP (554), canal, stream (principal/extra), usuário.
   - Senha digitada pelo usuário no app e guardada no **Keychain** do macOS.
   - Importação de nome/IP/canais do `devices.db` do VMS antigo (sem senhas).
2. **Visualização ao vivo**
   - RTSP com autenticação Digest, transporte TCP interleaved.
   - Depacketização RTP de H.264 e H.265.
   - Exibição com `AVSampleBufferDisplayLayer` (decodificação por hardware via VideoToolbox).
   - Mosaico 1 / 4 / 9 / 16 e tela cheia com duplo clique.
   - Reconexão automática.
3. **Canais do NVR** (192.168.0.70, 10 canais) como câmeras individuais.

## Próximas fases: configurações da câmera

Todas as telas de configuração do VMS antigo usam o protocolo DVRIP da Xiongmai (porta 34567).
A base comum (login, sessão, leitura/gravação de configuração em JSON) entra no início da Fase 2.

### Fase 2: Essenciais
- **Config. de PTZ** e controle de PTZ na visualização ao vivo (direções, zoom, presets).
- **Parâmetros da cam**: brilho, contraste, dia/noite, espelhar/inverter.
- **Rede**: IP, máscara, gateway, DNS, DHCP, portas.
- **Versão**: modelo, firmware, número de série.

### Fase 3: Gravação e disco
- **Config. de gravação**: agenda, modo (contínuo/movimento), pré-gravação.
- **Gerenciamento de disco**: capacidade, uso, formatação.
- **Config. de foto**: captura por agenda ou evento.
- Busca e reprodução de gravações do NVR.

### Fase 4: Alarmes
- **Smart alert**: detecção de pessoa e veículo.
- **Video Blind**, **Video Loss**, **Anormalidade** (disco cheio, erro de disco, conflito de IP).
- **Saída de alarme**.
- Notificações nativas do macOS para os eventos.

### Fase 5: Avançados
- **Config. de sistema**: data/hora, NTP, fuso, idioma.
- **Sobrepor**: texto, nome do canal e data na imagem.
- **Usuários**: contas e permissões da câmera.
- **Padrão**: restaurar configurações de fábrica.
- **Manutenção**: reiniciar, reinício automático, atualização de firmware.

### Depois
- Gravação local e captura de imagem no Mac.
- Rondas (tour) e mapas.

## Estrutura

```
VMS-Project/
  Package.swift
  Sources/VMSNext/
    App/          VMSNextApp, ContentView
    Models/       Camera, CameraStore (JSON + Keychain)
    Streaming/    RTSPClient, RTPDepacketizer (H264/H265), DigestAuth
    Video/        VideoLayerView (AVSampleBufferDisplayLayer)
    Import/       LegacyVMSImporter (devices.db)
    DVRIP/        (Fase 2+) sessão, comandos e modelos de configuração
    Settings/     (Fase 2+) telas de configuração por categoria
  scripts/bundle.sh
```

## Status

- **MVP concluído (22/10/2026):** câmeras e canais do NVR ao vivo no mosaico, testado pelo usuário em Apple Silicon.
- **Fase 2 concluída (22/10/2026):** PTZ, Parâmetros da cam (incluindo visão noturna de luz dupla via `Camera.WhiteLight`), Rede e Versão, todos testados nas câmeras.
- Próximo: Fase 3 (Gravação e disco).

### Aprendizados sobre as câmeras
- Todas as câmeras são de luz dupla: a visão noturna fica em `Camera.WhiteLight.WorkMode` (`Auto` = colorida, `Close` = infravermelha, `Intelligent` = alerta de luz dupla), não em `DayNightColor`.
- `Camera.WhiteLight` não leva índice de canal; `Camera.Param`, `AVEnc.VideoColor` e `Camera.ParamEx` levam (`.[0]`).
- IPs na rede vêm em hex little-endian (`0x1300A8C0` = 192.168.0.19).
- O VMS antigo recusa salvar "Parâmetros da cam" se o tempo mínimo de exposição estiver abaixo de 0,1 ms.
- O "Alerta inteligente" do iCSee (pessoas, linha/área de aviso) entra na Fase 4.

## Critério de pronto do MVP

As 4 câmeras e os canais do NVR aparecem ao vivo no mosaico, em um Mac Apple Silicon, sem Rosetta.
