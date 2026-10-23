# Notas técnicas: protocolo Xiongmai (DVRIP)

O que o VMS Next aprendeu sobre os equipamentos Xiongmai (XMEye / iCSee) e que não está documentado pela fabricante. Útil para quem quiser contribuir ou investigar um modelo novo. Os nomes entre crases são os da configuração em JSON.

## Conexão

- Controle e configurações pelo protocolo DVRIP na **porta 34567**: cabeçalho de 20 bytes (little-endian) e corpo em JSON. A resposta usa o código do pedido + 1.
- Login 1000, keep-alive 1006, ler configuração 1042, gravar 1040, capacidades 1360 (`ABILITY_GET`).
- Gravar uma configuração pode responder **603**: salvo, vale depois de reiniciar (comum em codificação).
- **Busca na rede**: pedido 1530 por broadcast UDP na porta 34569; cada equipamento responde 1531 com `NetWork.NetCommon` (IP, porta, nome, MAC, número de série).
- NVRs com **Criptografia de rede = "Login de rede precisa de criptografia"** recusam o login (código 124). Use "Login remoto precisa de criptografia".
- Endereços IPv4 vêm em hex little-endian: `0x0100A8C0` = 192.168.0.1.

## Vídeo e áudio

- Ao vivo por RTSP (Digest, TCP interleaved) ou pelo próprio DVRIP (Claim 1413, dados 1412, `OPMonitor` 1410). Câmeras de várias lentes ignoram o canal no RTSP: use o DVRIP.
- Blocos de mídia começam com `00 00 01 Fx`: `FC` quadro I (cabeçalho de 16 bytes), `FD` quadro P, `FA` áudio (byte 4 = tipo, `0x0A` = G.711 lei µ, demais = lei A; 8 kHz), `F9` informações.
- Reprodução: busca `OPFileQuery` 1440, Claim 1424, dados 1426, `OPPlayBack` 1420.
- Registro do equipamento: `OPLogQuery` 1442, 128 registros por página.

## Capacidades

- `SystemFunction` diz quais funções existem (ex.: `AlarmFunction.LossDetect`, `NetServerFunction.NetNat`, `EncodeFunction.SmartH264V2`, `CommFunction.CommRS485`, `OtherFunction.SupportPTZTour`). O app esconde telas e seções que o equipamento não tem.
- `EncodeCapability`: `CompressionMask` usa o bit 7 para H.264 (mostrado como **H.265X**) e o bit 8 para H.265. `ResolutionMask` tem um bit por tamanho (0 D1, 1 HD1, 14 1080P, 20 4M, 21 6M…); a do vídeo extra vem de `ExImageSizePerChannelEx[canal][bit da principal]`.
- `Camera`.`Speeds`: tempos do obturador (µs) dos níveis manuais de `ExposureParam.Level`.
- `PTZProtocol` e `UartProtocol` listam os protocolos de PTZ por cabo.

## Configurações

- Imagem: `Camera.Param.[c]`, `Camera.ParamEx.[c]` e `AVEnc.VideoColor.[c]` levam o índice do canal; `Camera.WhiteLight` não.
- Visão noturna de câmeras de luz dupla: `Camera.WhiteLight.WorkMode` (`Auto` = colorida, `Close` = infravermelha, `Intelligent` = luz dupla), não `DayNightColor`.
- Codificação: `Simplify.Encode` (um item por canal, `MainFormat` e `ExtraFormat`), perfil em `AVEnc.EncodeStaticParam`, Smart Encode (H265AI) em `AVEnc.SmartH264V2.[c].Smart264PlusV2[stream].SmartH264Plus`.
- Agenda de gravação e foto: 7 dias × 6 períodos, máscara com bit 0 normal, bit 1 detecção, bit 2 alarme.
- Foto: câmeras usam agenda (`Storage.Snapshot.[c]`); NVRs usam `Snap.SnapConfig.[c]` (`SnapType` 0 intervalo, 1 horários, 2 fechado).
- Alarmes: `GUARD` 1500 assina os alertas, que chegam como 1504. Pessoa = `appEventHumanDetectAlarm`. Detecção de pessoas em `Detect.HumanDetection.[c]` (`PedRule`, área em 0–8192); ações no `EventHandler` de `Detect.MotionDetect.[c]`.
- NVR: canais acionados por máscaras `RecordMask`/`SnapShotMask`/`TourMask` (bit 0 = canal 1); veículos em `Detect.CarShapeDetection.[c]`; disco em `Storage.StorageNotExist/StorageFailure/StorageLowSpace`; rede em `Alarm.NetAbort/NetIPConflict`; conexão dos canais em `NetWork.ChnStatus`.
- Saída de alarme: `Alarm.AlarmOut.[n]` (`AlarmOutType` AUTO/MANUAL/CLOSE; `AlarmOutStatus` OPEN/CLOSE).
- Sistema: nome do equipamento em `NetWork.NetCommon.HostName`; fuso em `NetWork.NetNTP.TimeZone` (14 = UTC−03:00); relógio com `OPTimeQuery` 1452 e `OPTimeSetting` 1450.
- Disco cheio: `General.General.OverWrite` (`OverWrite` = gravação cíclica, `StopRecord` = para).
- Texto na imagem: `AVEnc.VideoWidget.[c]` (posições em 0–8192 e máscaras de privacidade).
- Manutenção: `General.AutoMaintain`; `OPMachine` 1450 com `Reboot`.
- Usuários: 1472 contas, 1474 grupos, 1482 adicionar, 1486 apagar, 1488 trocar senha.
- PTZ: `OPPTZControl` 1400 (direções, zoom, foco, íris, presets, `AddTour`/`DeleteTour`/`ClearTour`/`StartTour`/`StopTour`).

## Limitação conhecida

- A resolução mostrada na reprodução fica truncada em vídeos com mais de 2040 px de largura (o cabeçalho guarda largura/8 em 1 byte). A imagem não é afetada.
