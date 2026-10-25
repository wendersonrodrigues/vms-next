# Revisão da interface do VMS Next pelas regras da Apple (macOS)

Feita em 25/10/2026 sobre a versão 1.1.0 Beta 2, lendo o código das telas (`Sources/VMSNext`) e comparando com
as Human Interface Guidelines (HIG) da Apple para macOS. Os contrastes foram calculados com as cores do tema
(`App/Theme.swift`) pela fórmula da WCAG. Não houve teste com o app aberto: os itens marcados com 🔍 precisam ser
conferidos na tela antes de mudar.

Prioridade: **Alta** = atrapalha alguém de usar o app (leitura, VoiceOver, teclado); **Média** = foge do padrão do
Mac e causa estranheza; **Baixa** = acabamento.

---

## 1. Resumo

O visual tem identidade própria (tema grafite com destaque azul-violeta, coluna de ícones, cards) e as telas de
configuração seguem bem o formulário agrupado do macOS. Os pontos fracos são:

1. **Acessibilidade quase inexistente**: nenhum `accessibilityLabel` no app inteiro. O VoiceOver lê nomes de símbolos
   ("chevron left", "trash") ou nada nos quadros de vídeo, na agenda e no editor de regras.
2. **Contraste no modo claro**: o azul do tema, o laranja dos avisos e o verde dos "ok" ficam abaixo do mínimo de
   leitura sobre fundo claro.
3. **Teclado**: só Return/Esc nos diálogos. Não há atalhos para trocar de tela, tocar/pausar gravação, mover o PTZ
   nem menu "Visualizar". O ⌘, (Ajustes) não abre nada.
4. **Consistência**: duas cores de destaque misturadas, 26 espaçamentos e 14 arredondamentos diferentes, nomes
   diferentes para a mesma área ("Preferências" × "Preferências do app", "Config. câmeras" × "Configurações").

---

## 2. Por tema

### 2.1 Hierarquia e tipografia
| Prioridade | O que mudar | Onde |
|---|---|---|
| Alta | Textos de 7 a 9 pt são pequenos demais para o Mac (a Apple usa 10 pt como menor tamanho, `caption2`). Subir para pelo menos 10 pt ou tirar da tela: créditos da coluna (8–10 pt), nome oficial nas metades do split (9 pt), número do alerta no sino e na coluna (9 pt), bolinha de status do NVR (7 pt). | `App/NavigationRail.swift:82-124`, `App/CameraTile.swift:215`, `App/ContentView.swift:617`, `Settings/RecorderInfoView.swift:589` |
| Média | 39 tamanhos de fonte fixos (`.system(size:)`). Trocar pelos estilos do sistema (`.title`, `.headline`, `.body`, `.callout`, `.caption`) para a hierarquia ficar igual em todas as telas. Manter fixos só os "números grandes" (temperatura, título do banner). | vários |
| Média | Os créditos (nome, versão, autor, GitHub) aparecem em três lugares: coluna, banner do Início e Ajuda. Deixar no Início e em **Sobre o VMS Next**; na coluna, só a versão (útil por causa do Beta). | `App/NavigationRail.swift`, `App/HomeView.swift` |
| Baixa | Barra de título das configurações junta muita coisa numa linha (voltar, ícone, título, nome antigo, equipamento). O nome antigo pode ir para o subtítulo, embaixo do título. | `Settings/CameraSettingsView.swift:345-370` |

### 2.2 Espaçamento e formas
| Prioridade | O que mudar | Onde |
|---|---|---|
| Média | 26 valores diferentes de margem (de 1 a 32). Criar uma escala no `Theme` (4, 8, 12, 16, 20, 24) e usar só ela. | vários |
| Média | 14 arredondamentos diferentes (de 2 a 28). Padronizar em 4 níveis: 6 (controles pequenos), 10 (botões e miniaturas), 16 (cards), 22 (banner e coluna). | vários |
| Baixa | Botões que crescem 4% e ganham brilho ao passar o mouse (`HoverButtonStyle`) não são do Mac, onde o botão só clareia. Tirar o aumento e a sombra colorida, deixar só o fundo leve. | `App/Theme.swift:50-75` |

### 2.3 Cores (modo claro e escuro)
| Prioridade | O que mudar | Onde |
|---|---|---|
| Alta | **Azul do tema no modo claro**: `#5B7CFF` dá 3,3:1 sobre o fundo claro e 3,6:1 com texto branco em cima (o mínimo para texto é 4,5:1). No escuro está ok (4,9:1). Usar uma variante mais escura só no modo claro, como `#3550D8` (5,8:1). | `App/Theme.swift:28` |
| Alta | **Laranja e verde em texto no modo claro**: o laranja do sistema dá 2,2:1 sobre branco, e é usado em 30 textos de erro/aviso; o verde também (18 usos). No escuro estão ótimos (8,7:1). Opções: deixar o ícone colorido e o texto em `.primary`, ou usar tons escuros no claro (laranja `#B25000`, 5,2:1; verde `#1E7B34`, 5,3:1). | `Label(error, …).foregroundStyle(.orange)` em 21 telas; notices verdes nos rodapés |
| Alta | **Duas cores de destaque misturadas**: 16 lugares usam `Color.accentColor`, que segue a cor de destaque escolhida no macOS (pode ser laranja, rosa…), e 12 usam `Theme.accent` (azul-violeta). O `.tint` não muda o `Color.accentColor`. Trocar tudo por `Theme.accent`, ou criar o `AccentColor` nos recursos. | `Settings/CameraSettingsView.swift`, `Settings/SettingsUI.swift` e outros |
| Média | As cores do tema são fixas e não respondem ao **Aumentar contraste** do macOS. A borda dos cards (7% de branco) some. Dar variantes de alto contraste no `Theme.dynamic` (aparências `accessibilityHighContrast…`). | `App/Theme.swift:7-12, 26` |
| Média | Selo vermelho com número branco (3,6:1) e "REC" branco no vermelho: aceitável por ser negrito, mas o número de 9 pt precisa subir para 10–11 pt. | `NavigationRail.swift:115`, `ContentView.swift:617` |
| Baixa | Tela de login usa um cinza fixo no topo, fora do tema e sem logo. Usar o `AppLogo` e as cores do tema. | `App/LoginView.swift:21-30` |

### 2.4 Acessibilidade — VoiceOver
| Prioridade | O que mudar | Onde |
|---|---|---|
| Alta | **Botões só com ícone sem nome em português.** O `.help` vira dica de mouse, não nome para o VoiceOver. Correção central: no `BarButton`, aplicar `.accessibilityLabel(title ?? help)`; nos outros, um rótulo por botão. Sem dica nenhuma hoje: setas de página do mosaico, apagar máscara e apagar passo do rodízio. | `App/Theme.swift:93-118`, `ContentView.swift:682-685`, `Settings/OverlayView.swift:441`, `App/RotationEditor.swift:35` |
| Alta | **Quadros de vídeo** não dizem nada. Juntar num elemento só, com nome ("Frente, ao vivo, gravando no Mac") e ações (abrir, foto, gravar, configurações). | `App/CameraTile.swift` |
| Alta | **PTZ**: as dicas mostram o nome do protocolo em inglês ("DirectionLeftUp", "ZoomTile"). Trocar por "Para cima e à esquerda", "Aproximar" etc., e usar o mesmo texto como rótulo. | `PTZ/PTZPanel.swift:205`, `PTZ/PTZController.swift:3-15` |
| Alta | **Agenda (grade de horários)** e **editor de regra** são desenhados à mão e só funcionam com mouse. A agenda precisa de um rótulo por dia ("Segunda: 8h às 18h") e ajuste por teclado, ou atalhos "Dia todo / Horário comercial / Nenhum". O editor de regra precisa ao menos de um resumo falado ("Área de 4 pontos"). | `Settings/ScheduleGrid.swift`, `Settings/RuleEditorView.swift` |
| Média | Selos e estados não são anunciados: número de alertas novos (coluna e sino), item selecionado na coluna (`.isSelected`), "REC". | `NavigationRail.swift`, `ContentView.swift:610-625`, `CameraTile.swift:200` |
| Média | Miniaturas de modelo de tela (barra do mosaico) têm só a dica de mouse; dar rótulo ("4 câmeras, escolhido"). | `ContentView.swift:571-580` |
| Média | No editor de modelo, os quadros são marcados com toque (`onTapGesture`), não com botão: não funcionam com teclado nem VoiceOver. Trocar por `Button`. | `App/TemplateEditor.swift:101` |
| Média | Nenhuma tela respeita **Reduzir movimento**. Desligar o aumento ao passar o mouse e as animações de seleção quando `accessibilityReduceMotion` estiver ativo. | `App/Theme.swift`, `NavigationRail.swift:105` |

### 2.5 Teclado
| Prioridade | O que mudar | Onde |
|---|---|---|
| Alta | **Ajustes do app no ⌘,**: o macOS espera "VMS Next › Ajustes…" (⌘,). Hoje as Preferências só abrem pela coluna. Ligar o ⌘, à mesma tela (cena `Settings` ou comando que troca para `.preferences`). | `App/VMSNextApp.swift` |
| Alta | **Menu Visualizar** com as telas e atalhos: ⌘1 Início, ⌘2 Ao vivo, ⌘3 Gravações, ⌘4 Eventos, ⌘5 Dispositivos, ⌘6 Config. câmeras. Também "Mostrar/ocultar lista" (⌃⌘S) e Tela cheia (⌃⌘F). | `App/VMSNextApp.swift` (`CommandMenu`) |
| Alta | **Gravações**: espaço para tocar/pausar, ← e → para voltar e avançar 10 s, ⌘D para baixar. | `Playback/PlaybackView.swift:300-340` |
| Média | **Ao vivo**: ← e → (ou Page Up/Down) para trocar de página do mosaico; Return para abrir a câmera escolhida; Esc para voltar ao mosaico; setas para mover o PTZ quando o painel estiver aberto. | `App/ContentView.swift`, `PTZ/PTZPanel.swift` |
| Média | **Configurações**: ⌘R em "Recarregar" e Delete para apagar item escolhido (máscara, usuário, passo do rodízio), com a confirmação que já existe. | telas de `Settings/` |
| Média | 🔍 Conferir o anel de foco com Tab nos botões de estilo próprio (`.hover`, cards do menu de configurações): estilos próprios às vezes não desenham o anel. | `App/Theme.swift`, `CameraSettingsView.swift:430` |

### 2.6 Consistência entre as telas
| Prioridade | O que mudar | Onde |
|---|---|---|
| Média | Nomes: a coluna diz "Preferências", a tela diz "Preferências do app"; a coluna diz "Config. câmeras", as janelas dizem "Configurações". Desde o macOS 13 a Apple usa **Ajustes** para o app. Sugestão: "Ajustes" (o app) e "Configurações" (as câmeras), em todo lugar. | `ContentView.swift:381, 799-800`, `NavigationRail.swift:297` |
| Média | Seções de ação com títulos diferentes para a mesma coisa: "Ao detectar · …" (Detecção inteligente) e "Quando acontecer · …" (Câmera bloqueada, Perda de vídeo). Escolher um. | `Settings/SmartAlertView.swift:523`, `Settings/EventConfigView.swift:633` |
| Média | Quatro estilos de botão sem regra (próprio `.hover` 14, `.borderless` 11, `.plain` 4, `.borderedProminent` 2). Regra sugerida: barras de vídeo = `BarButton`; formulários = botão padrão do sistema; uma ação principal por tela = `.borderedProminent`; ícones dentro de cards = `.borderless`. | vários |
| Média | Rodapé das configurações: 16 de 29 telas têm "Diagnóstico… / Recarregar / Aplicar". Usar o mesmo rodapé, na mesma ordem, em todas que gravam algo (um componente só). | `Settings/` |
| Baixa | Botão "Login" em inglês na tela de entrada: trocar por "Entrar". | `App/LoginView.swift:58` |
| Baixa | Mensagens de carregamento variam ("Lendo da câmera…", "do equipamento…", "do NVR…"). Tudo bem por contexto; só manter "equipamento" quando não se sabe o tipo. | vários |

---

## 3. Lista por tela

### Início
- Alta: subir o texto do status dos equipamentos e dos cards que usam `.caption2` no modo claro; conferir o contraste do texto branco sobre o banner quando a imagem é clara 🔍.
- Média: tirar os créditos duplicados (já estão no banner); padronizar margens dos cards (18/22 → escala).
- Média: botão de engrenagem do clima e botões de ícone dos equipamentos com rótulo para o VoiceOver.

### Ao vivo (mosaico e câmera)
- Alta: rótulo e ações do VoiceOver em cada quadro; "REC" anunciado.
- Alta: setas de página com nome; ← → para trocar de página; Esc volta ao mosaico.
- Média: miniaturas de modelo com rótulo e estado "escolhido"; editor de modelo com botões no lugar do toque.
- Média: nome oficial nas metades do split de 9 → 10–11 pt.
- Média: PTZ com nomes em português e setas do teclado.

### Gravações
- Alta: espaço / ← → / ⌘D.
- Média: barra de tempo (Slider) com valor falado ("12:34 de 30:00").
- Baixa: os rótulos pequenos da lista (`caption2`, 4 usos) passam para `caption`.

### Eventos
- Média: dar ação de teclado para "Ver ao vivo" / "Ver gravação" (hoje é duplo clique ou menu de contexto); Return abre ao vivo.
- Média: aviso de notificações bloqueadas e o "ok" verde precisam do tom escuro no modo claro.

### Dispositivos
- Média: "Já adicionada" em verde no claro; trocar por ícone verde + texto normal.

### Configurações das câmeras (menu e todas as telas)
- Alta: erros em laranja no modo claro (21 telas) → ícone laranja e texto normal, ou laranja escuro.
- Alta: agenda e editor de regra acessíveis (ver 2.4).
- Média: um rodapé padrão; ⌘R em Recarregar; títulos "Ao detectar" × "Quando acontecer" iguais.
- Média: ícones do cabeçalho e dos cards usam `Color.accentColor` → trocar pelo azul do tema.
- Baixa: nome antigo da categoria no subtítulo, não na mesma linha do título.

### Preferências / Ajustes do app
- Alta: abrir com ⌘,.
- Média: um nome só ("Ajustes") na coluna e no título.

### Tela de entrada (login)
- Baixa: logo e cores do tema; "Login" → "Entrar".

### Coluna de ícones
- Alta: créditos de 8–10 pt (tirar ou subir); selo de alertas anunciado.
- Média: estado "selecionado" para o VoiceOver; sem crescer ao passar o mouse com Reduzir movimento.

### Barra de menus (ícone no topo da tela)
- Média: erro em laranja no claro; botões já têm texto, ok.

---

## 4. Ordem sugerida
1. ✅ **Tema** (feito em 25/10): azul, laranja e verde com tom escuro no claro; um destaque só; variantes de alto
   contraste; escala de margens (`Space`) e arredondamentos (`Radius`). Ícones do menu e HD/SD refeitos no estilo
   dos Ajustes do macOS (Magnific).
2. ✅ **Rótulos do VoiceOver** (feito em 25/10): `BarButton` com rótulo e estado "ligado", os 25 botões só de
   ícone com nome em português, PTZ em português (dica e VoiceOver, com ação de mover por meio segundo), HD/SD,
   selos de alertas (coluna e sino), item escolhido na coluna, modelo de tela escolhido e "REC".
3. ✅ **Teclado** (feito em 25/10): ⌘, abre as Preferências; menu Visualizar com Início…Config. câmeras em ⌘1–⌘6;
   menu Mosaico (página anterior/próxima ⌥⌘← ⌥⌘→, voltar ao mosaico ⌥⌘↑, rodízio ⌥⌘R); Gravações com espaço,
   ← → (vídeo em foco) e ⌘D para baixar. Ficaram para depois: setas no PTZ, ⌘R em Recarregar e Delete para apagar.
4. **Telas difíceis**: quadros de vídeo, agenda, editor de regra, editor de modelo.
5. **Acabamento**: tamanhos mínimos de fonte, nomes iguais, rodapé padrão, tela de entrada.

Cada etapa é pequena o bastante para testar e fazer commit separado, como nas etapas de paridade.
