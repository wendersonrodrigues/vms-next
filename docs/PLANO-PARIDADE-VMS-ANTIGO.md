# Plano de atualização: o que falta trazer do VMS antigo

Levantamento feito em 24/10/2026: passei por todas as telas de "Config. de dispositivo" do VMS antigo
(V2.2.1.1) com a Sala, a Frente e o NVR, só lendo (nenhum Salvar/Aplicar), e comparei com o VMS Next.

---

## 1. Como o VMS antigo decide o que mostrar em cada câmera

Ele **não guarda nada por câmera**. Ao abrir cada tela, ele monta a tela inteira, pergunta à câmera o que
ela tem e **esconde** (não apaga, some mesmo) o que ela não tem. Dá para ver isso acontecendo: no Sobrepor,
enquanto carrega aparecem Channel Title, Time Title, Status de gravação, Alarm flashes, Brilho, QR Code,
Antivibração, Transparência, Resolução e OSD; depois de ler a Sala sobram só "Exibição do canal",
"Exibição do horário" e "Máscara privac".

As fontes que ele usa (todas já lidas pelo VMS Next, mas pouco aproveitadas):

| Fonte | Comando | O que decide |
|---|---|---|
| `SystemFunction` | capacidade (1360) | telas e opções: `AlarmFunction.*`, `EncodeFunction.*`, `NetServerFunction.*`, `OtherFunction.*`, `TipShow.*` |
| `Camera` | capacidade (1360) | modos dia/noite, luz dupla, tempos do obturador (`Speeds`) |
| `SystemInfo` | config | quantas saídas/entradas de alarme (`AlarmOutChannel`, `AlarmInChannel`), canais |
| a própria config | config (1042) | campo que não vem na resposta = função que não existe |

### Diferenças reais encontradas entre Sala e Frente

| Campo | Sala | Frente | Efeito no VMS antigo |
|---|---|---|---|
| `OtherFunction.SupportHideNormalDLMode` | — | true | Frente **esconde** Star IR, Full Color e BlackAndWhiteMode do "Modo dia/noite" (só 3 opções) |
| `Camera.SupportIntellDoubleLight` | 1 | 1 | as duas mostram IntellMotionDetect, WarmLight, IntelligentInfrared |
| `OtherFunction.SupportCameraWhiteLight` | — | true | luz branca só na Frente |
| `AlarmFunction.LossDetect` | — | true | Frente tem a tela **Video Loss**; Sala não |
| `SystemInfo.AlarmOutChannel` | 0 | ≥1 | Frente tem a tela **Saída de alarme** e a ação "Saída de alarme + Atraso" nos alarmes; Sala não |
| `EncodeFunction.SmartH264V2` | true | — | codificação inteligente só na Sala |
| `TipShow.NoBeepTipShow` | true | true | não mostra "Bipe" nem "Aviso na tela" nas ações de alarme |

### Regra para o VMS Next (base de tudo abaixo)

1. Criar um **perfil de capacidades** por equipamento (SystemFunction + Camera + SystemInfo), lido uma vez e
   guardado em cache, com uma função `suporta("...")` usada por telas, seções, campos **e opções de listas**.
2. Função que a câmera não tem: **esconder** (não deixar apagado), igual ao VMS antigo.
3. Listas: mostrar **só as opções que a câmera tem**. O valor atual sempre aparece, mesmo que fora da regra.
4. Trocar seleção por controles mais diretos: ON/OFF vira **interruptor**; listas curtas (até 6) viram
   **botões de opção (radio)**; listas longas continuam como menu.
5. Campos dependentes ficam desativados quando o "Habilitar" da tela está desligado (como o VMS antigo faz
   em Video Blind/Video Loss).

---

## 2. Correções por tela (câmera avulsa)

### 2.1 Grade de funções (Config. câmeras)
- [x] **Perda de vídeo (Video Loss)** também nas câmeras avulsas quando `AlarmFunction.LossDetect` (Frente). Hoje só aparece no NVR.
- [x] **Saída de alarme** só quando `AlarmOutChannel > 0`. Hoje aparece na Sala, que não tem.
- [ ] Revisar as outras telas com a mesma regra (Detecção de veículo = `CarShapeDetection` etc.).

### 2.2 Imagem e visão noturna
- [x] **Modo dia/noite** (radio), opções filtradas:
  - 0, 1, 2 só se **não** houver `SupportHideNormalDLMode`;
  - 3, 4, 5 só se `SupportIntellDoubleLight` ou `SupDayNightMotionDetect`.
- [x] Corrigir os nomes de 0–2 com a tradução do próprio VMS antigo (tela "IPC Param" e arquivo English.qm):
  0 = Star IR → **Visão noturna infravermelha**; 1 = Full Color → **Colorida (luz das estrelas)**;
  2 = BlackAndWhiteMode → **Alerta de luz dupla**. (Hoje o app diz "Preto e branco" para o 2.)
- [x] Seção **Luz branca** (iCSee) só com `SupportCameraWhiteLight`. Hoje aparece na Sala.
- [x] "Ajuste dia e noite" (`AutomaticAdjustment`) ✅ feito. "Sensibilidade da troca" (`DncThr`) só se o campo existir ✅.

### 2.3 Exposição e ajustes finos
- [x] Adicionar o que falta, cada um só se o campo existir na câmera:
  - **Nevoeiro nublado** (Clear Fog) ON/OFF + Level;
  - **Girar** (rotação da imagem);
  - **NoRedFaceExposure** (exposição de rosto, sem traduzir no VMS antigo);
  - "Superior" da Faixa dinâmica ✅ já existe.
  Chaves confirmadas comparando Sala e Frente: Nevoeiro = `Camera.ClearFog`, NoRedFaceExposure =
  `ParamEx.PreventOverExpo`, Girar = `PictureFlip` (já existia como "Virar de cabeça para baixo").
- [x] Nomes iguais ao VMS antigo: IR CUT = **Sincronização** / **Sincronização automática**;
  Obturador lento = **Nenhum / Baixo / Média / Forte** (conferir os valores 0/2/4/6 ou 0/1/2/3 no Diagnóstico);
  Modo de exposição = **Automático / Manual 1/60 … 1/10000** ✅.
- [x] ON/OFF (Luz de fundo, Espelhar, Anti brilho, Auto íris, Troca de IR) como interruptores ✅ (já são).
- [x] Perfil de imagem: typedefault/type1/type2 = Estilo 1/2/3 ✅ feito.

### 2.4 Sistema e horário
- [ ] **Fuso horário editável** (lista UTC−12 … UTC+14). Hoje é só leitura. Falta confirmar como o código do
  equipamento (14 = UTC−03:00) vira cada fuso antes de liberar a edição; um fuso errado bagunça a hora das gravações.
- [ ] **Horário de verão** com o botão "Configuração" (início e fim), não só liga/desliga.
- [x] **Idioma**: usar a lista que a câmera informa (na Sala: Inglês, Chinês simples, Espanhol, Russo,
  Português, Japonês). A Sala grava "Brazilian", que não está na lista do VMS antigo; por isso ele mostra
  o primeiro item (Inglês). O VMS Next mostra o valor real.
- [x] **HD cheio** (Parar / Sobrescrever) também aqui, como no VMS antigo (hoje fica em Disco).
- Lista de fuso lida: UTC−12:00 … UTC+13:00, com as meias horas (UTC−03:30, UTC+05:30, UTC+05:45 etc.).

### 2.5 Rede e Serviços de rede
- [x] **Interface com fio / Wi-Fi**: a Sala usa Wi-Fi (192.168.0.77) e o app lê só o IP com fio (192.168.1.10),
  por isso mostra o aviso e bloqueia. Ler `NetWork.Wifi` e mostrar a interface em uso.
- [ ] **Aba Wi-Fi** completa (o VMS antigo deixa editar): procurar redes (SSID, modo, sinal), habilitar, DHCP,
  SSID, senha, IP, máscara, gateway. Com confirmação forte (rede errada desconecta a câmera).
- [ ] **Porta ONVIF** e **OnvifProtect**.
- [ ] **Nuvem**: além de ligar/desligar, o **MTU** (1280 bytes).
- [ ] **Filtro de IP** editável (tipo lista negra/branca, adicionar, apagar). Hoje é só leitura.
- [ ] **NTP**: "Custom" ou "Auto Select Server" + intervalo ✅ (conferir se o modo automático existe).

### 2.6 Sobrepor (Texto na imagem)
- [x] Mostrar as opções extras **só quando a câmera tiver**: Channel Title, Time Title, Status de gravação,
  Alarm flashes, Channel Docking Line, Brilho, Device QR Code, Antivibração, Transparência, Resolução, OSD extra.
  Feito para o texto extra (exige `OtherFunction.SupportOSDInfo`); as outras opções o VMS Next ainda não tem.

### 2.7 Detecção inteligente, Câmera bloqueada, Perda de vídeo
O VMS antigo mostra **só**: Habilitar, HumanoidDetect, Sensibilidade, Rule, Período, Intervalo,
Saída de alarme + Atraso (só com saídas), Gravação, Record Delay, Tirar foto, Ativação de PTZ,
Enviar e-mail, Escrever log, FTP, Notificações, Saída de alarme.
- [x] Esconder as ações que a câmera não tem: Bipe e Aviso na tela (`TipShow.NoBeepTipShow`),
  Aviso sonoro (`SupportAlarmVoiceTips`), Saída de alarme (`AlarmOutChannel > 0`), opções antigas (SMS, MMS,
  Matriz, ShowInfo, SaveSer) sempre escondidas.
- [x] **Sensibilidade em 6 níveis**: Muito baixa, Baixa, Média, Alta, Muito alta, Ultra alta.
- [ ] **Ativação de PTZ**: canal + tipo (Nenhum, Predefinido, Ronda, Padrão) + número.
- [ ] **Câmera bloqueada**: corrigir "Tirar foto" que aparece **duas vezes**; não tem Intervalo nem Saída de alarme.
- [ ] Desativar os campos quando "Habilitar" estiver desligado.
- [ ] Editor de regra: conferir as formas do VMS antigo (triângulo, quadrado, pentágono, hexágono,
  heptágono, octógono, linha "Cordão" ou área "alertArea", "Mostrar traços").

### 2.8 Anormalidade (Problemas no equipamento)
- [x] Eventos só os que a câmera informa: Nenhum disco, Falha de armazenamento, Espaço de armazenamento,
  Internet desconectada, Conflito de IP. Cada um com Habilitar, Timed Alarm e Notificações.

### 2.9 Disco
- [x] Botões do VMS antigo (menos Particionar; não testados no equipamento, mexem no disco de verdade): Leitura/gravação, Foto, Somente leitura, Redundante, **Formatar**, Recuperar,
  Particionar (todos com confirmação). Colunas de início e fim da gravação.

### 2.10 Usuários
- [x] **Grupos**: adicionar (copiando permissões) e apagar grupo vazio. Falta: modificar grupo e modificar usuário.

### 2.11 Manutenção
- [x] **Auto reiniciar** (já existia): Nunca, Todo dia, Domingo … Sábado (conferir se já existe).
- [x] **Auto deletar** arquivos antigos (já existia): Nunca deletar ou Customizado (número de dias).
- [ ] Importar / exportar configuração ✅ (conferir).

### 2.12 Qualidade do vídeo (Mídia)
Lido na Sala (na segunda tentativa; na primeira o VMS antigo não carregou):
H.265 · 4M · Ultra alta · 24 qps · CBR · 3378 kb/s · intervalo 1 · áudio ligado; extra D1 · Bom · 24 · CBR · 1126.
- [x] **Configuração de codificação estática**: Base, Perfil principal, Perfil de destaque (Baseline/Main/High).
- [x] **Taxa de bit como lista calculada** (máximo recalibrado: 4M a 24 qps = 5632) igual ao VMS antigo (na Sala: 844, 1688, 2252, 3378, 4504, 5632),
  além do valor atual. Conferir: o VMS Next mostra 3223/963 e o VMS antigo 3378/1126 — ver qual é o valor real.
- [ ] Smart Encode: Fechar / H265AI ✅ (conferir o nome "H265AI").
- [ ] Resolução: o VMS antigo mostra só as que a câmera aceita (Sala: só 4M e D1) ✅ já é assim.
- [ ] "Remote Preview" e "AudioEncodeMode" aparecem enquanto carrega e somem na Sala: mostrar só quando existirem.

---

## 3. NVR (o VMS antigo mostra outra grade)

- [x] **IPC Param** — já coberto: as telas de cada canal do NVR (Imagem, Exposição, Mídia) configuram a câmera pelo NVR. Falta só "Reiniciar a câmera" e o volume.
  Original: configurar a câmera ligada no NVR **através do NVR** (Versão + QR Code, Imagem, Luz,
  Codificação, Avançado com volume e nevoeiro, Reiniciar a câmera). Hoje o VMS Next não tem.
- [x] **Canal digital** (só leitura, "Câmeras do NVR"): lista das câmeras do NVR (nome, tipo, IP, canal remoto), Habilitar,
  Sincronizar horário (Aux. Off, Fuso horário, Horário local), Decodificar (Prioridade real 1/2, Média,
  Prioridade de fluxo 1–4), Modo (Single link), Resolução de sincronização.
- [x] **Modo de canal** (só leitura, "Modo dos canais"): tabela de modos (ex.: 10 × 5M ou 4 × 4K), máximo de playback e de visualização.
- [x] **Status do canal** ("Estado dos canais"): canal, resolução máxima, resolução atual, conectado / não configurado.
- [x] **Detec. Smart** do NVR (já existia como Detecção inteligente): canal (Todos), HumanoidDetect, Gravar, Aviso no celular, Avançado, Sensibilidade, Rule.
- [x] **CarShape Detect** (já existia como Detecção de veículos) (veículo) do NVR: canal (Todos), Habilitar, Período, Tour (canais 1–10 e Todos),
  Enviar e-mail, Escrever log, Aviso no celular, Som de alarme.
- Detalhes do IPC Param lidos: Imagem (período dia/noite com dois horários, brilho, contraste, saturação,
  matiz, ganho, nitidez horizontal/vertical, modo dia/noite, limiar, cena, faixa dinâmica, espelhar, virar,
  IR Swap); Luz (modo: WarmLight, IntellMotionDetect, IntelligentInfrared, sensibilidade, duração, horário);
  Avançado (exposição com tempos mín./máx., AE, AGC, Clear Fog + Level, NT dia/noite, IR_CUT
  SyncSwitch/AutoSwitch, sensibilidade AE, obturador lento, contraluz, auto íris, anti cintilação,
  NoRedFaceExposure, **VolumeAdjustment**). A aba de codificação não terminou de carregar no VMS antigo
  nem em duas tentativas (é a mesma tela da Mídia).

---

## 4. Funções do próprio app (fora das câmeras)

- [x] **Som por tipo de alarme** (já existia, com arquivo próprio) (o VMS antigo tem 10: movimento, ocluído, perda de vídeo, alarme I/O,
  análise de vídeo, detecção humana, rosto, disco cheio, erro de disco, veículo), com arquivo próprio.
- [ ] Preferências: "Auto Connect Device", "Auto comutação entre stream secundário e principal",
  formato da gravação no Mac, pasta de exportar log.
- [ ] **Atualização de firmware** (o VMS antigo tem "Atualização").
- [ ] Mapa e Decodificar: baixa prioridade.

---

## 5. Ordem sugerida

1. ✅ **Perfil de capacidades** + regra "esconder" (item 1) — `DeviceCapabilities.profile(for:)`.
2. Telas com erro hoje: dia/noite (2.2), Luz branca (2.2), grade (2.1), ações de alarme (2.7), Rede/Wi-Fi (2.5).
3. Campos que faltam: Exposição (2.3), Sistema (2.4), Sobrepor (2.6), Anormalidade (2.8).
4. ✅ Telas novas do NVR (3), só leitura. Editar a câmera de cada canal fica para depois, com confirmação.
5. ✅ Disco, Usuários, Manutenção, Mídia (2.9–2.12) e sons de alarme (4). Sobram os itens ainda desmarcados acima.

Cada etapa: implementar → testar com Sala, Frente e NVR → commit.
