# Novidades

## 1.3.0 — 26/10/2026

- **Eventos com IA no Mac**: antes de avisar, o app pega uma foto da câmera e o Vision do macOS procura pessoas, rostos, veículos, cães e gatos (e placas). O alerta diz o que apareceu, a notificação leva a foto e movimento sem nada vira provável falso alarme. Tudo no Mac, sem internet.
- **Gerenciador de alarmes**: gravidade (automática ou à mão), soneca por câmera ou tipo, notas, filtros e **▶ Play**, que abre a gravação com a agulha no horário do alerta e uma marca vermelha na linha do tempo.
- **Origem das gravações** em Editar câmera: cartão da câmera, NVR ou os dois, com a chave NVR | Cartão nas Gravações.
- **Gravações**: tags nos vídeos, download direto na pasta das Preferências, vídeos baixados marcados ("No Mac", tom mais claro na linha do tempo), calendário com os dias gravados e baixados, e a agulha desliza nos saltos.
- **Zoom pela roda do mouse**, mirando onde o mouse está, no mosaico, na tela única e nas Gravações.
- **Barra de menus**: botões em ícone, alertas repetidos numa linha só e câmeras silenciadas escolhidas ali mesmo.

## 1.2.0 — 25/10/2026

- **Gravações em linha do tempo**: o dia inteiro numa régua de 0 h a 24 h, com uma faixa e uma cor para cada tipo (alarme, movimento, manual e contínua). Passar o mouse mostra a hora; clicar toca dali.
- **Setas por tipo**: ‹ Movimento › e ‹ Contínua › levam ao trecho anterior ou ao próximo daquele tipo.
- **Barra de data**: ‹ › de dia em dia, calendário ao clicar na data, Hoje e a lista de arquivos do dia.
- **Janela estreita**: a lista de câmeras não some mais nas Gravações, e a barra do player se ajusta à largura.
- **Inglês** como segundo idioma, com a escolha nas Preferências (o app reinicia no idioma escolhido).
- **Ícones da barra de menus** novos: normal, alertas novos e sem receber alertas.
- **Ícone de câmera do app** na lista lateral, Dispositivos, Eventos, PTZ e Gravações.
- README novo, com as telas atuais.

## 1.1.0 — 25/10/2026

Versão oficial. Junta tudo das betas 1, 2 e 3 e acrescenta:

- **Mosaico novo**: barra embaixo de cada quadro com nome, câmera ligada (ícone novo), **PTZ** (só nas câmeras que têm), som e **expandir**; **zoom digital** em cada quadro.
- **PTZ no pé da lista de câmeras**, para o mosaico e a tela única, uma câmera por vez, no arranjo simples do VMS antigo: setas, zoom/íris/foco, passo, preset e ronda escolhidos numa lista, e janela para editar a ronda. A barra de PTZ embaixo da tela única saiu.
- **PTZ (motor)** em Editar câmera: automático (pelas capacidades) ou escolhido à mão.
- **Logo e ícone novos**, um só desenho para o modo claro e o escuro.
- README com as novidades e os próximos passos.

Resumo das betas: configurações conferidas no código do VMS antigo (REA + Hopper), fuso horário e servidor de horário, seletor de canal na Mídia, funções extras mantidas (texto extra, evitar rosto estourado, opções avançadas das detecções) e a interface revista pelas regras da Apple (cores e contraste, VoiceOver, atalhos de teclado, telas acessíveis e acabamento).

## 1.1.0 Beta 3 — 25/10/2026

Versão de testes. Interface revista pelas regras da Apple para o macOS (relatório em `docs/REVISAO-INTERFACE-MACOS.md`).

- **Visual**: ícones do menu e HD/SD novos, no estilo dos Ajustes do macOS; cores que passam no contraste mínimo também no modo claro; destaque azul único (não muda com a cor escolhida no macOS); bordas e cores mais fortes com "Aumentar contraste"; margens e cantos padronizados.
- **VoiceOver**: todos os botões com nome em português; PTZ em português e acionável; alertas, seleção, HD/SD e gravação anunciados; quadros de vídeo com estado e ações; agenda com resumo falado por dia; editor de regra e editor de modelo usáveis sem mouse.
- **Teclado**: ⌘, abre as Preferências; ⌘1 a ⌘6 trocam de tela; menu Mosaico (⌥⌘← ⌥⌘→ páginas, ⌥⌘↑ voltar ao mosaico, ⌥⌘R rodízio); Gravações com espaço, ← → e ⌘D; ⌘R recarrega as configurações.
- **Acabamento**: nenhum texto abaixo de 10 pt; nomes iguais em todo o app ("Configurações", "Preferências"); rodapé igual em todas as telas de configuração; tela de entrada com logo e tema; respeita "Reduzir movimento".

## 1.1.0 Beta 2 — 25/10/2026

Versão de testes. Traz de volta funções úteis que tinham sumido por não existirem no VMS antigo.

- **Texto na imagem**: o texto extra (até 6 linhas, como endereço ou telefone) volta a aparecer em toda câmera que tenha essa configuração.
- **Exposição**: "Evitar rosto estourado" aparece sempre que a câmera tiver o campo.
- **Detecções**: grupo recolhido "Opções avançadas" com "Mostrar informação na imagem" e "Filtro de oscilação".
- **Qualidade do vídeo e som**: o seletor de canal fica só nessa tela, como no VMS antigo.

## 1.1.0 Beta 1 — 25/10/2026

Versão de testes: muita coisa nova, ainda com erros conhecidos. Fica em beta até tudo ser conferido nas câmeras.

- **Configurações iguais ao VMS antigo**, conferidas no próprio código dele (REA + Hopper): cada tela mostra só o que a câmera tem, com os mesmos valores. Mapa completo em `docs/REA-MAPA-CONFIG.md`.
- **Exposição**: ordem certa do modo manual, tempos do obturador de 0,1 a 80 ms (só no automático), novos "Modo corredor" e "Correção de distorção da lente".
- **Imagem e visão noturna**: limiar dia/noite de 10 a 50, modo "Leitura de placas" e regras de luz dupla; luz branca com duração até 120 s e sensibilidade como no VMS antigo.
- **Qualidade do vídeo e som**: seletor de canal (lente dupla, como Quintal/Corredor), perfil estático, taxa de bits em lista e codificação inteligente.
- **Sistema e horário**: fuso horário editável (System.TimeZone) e escolha do servidor de horário (automático ou personalizado).
- **Detecção e alarmes**: sensibilidade em 6 níveis, Ativação de PTZ, ações escondidas quando a câmera não tem, "Continuar gravando por" de 10 a 300 s.
- **NVR**: Câmeras do NVR, Modo e Estado dos canais, procurar câmeras pelo NVR e editar o canal.
- **Rede**: interface com fio ou Wi-Fi, MTU da nuvem e proteção ONVIF.
- **Disco, Usuários e Manutenção** como no VMS antigo.
- Ao vivo: zoom digital flutuante, setas de PTZ à direita com inversão por câmera e reordenar as metades do split.

## 1.0.0 — 23/10/2026

Primeira versão pública.

- **Início** com clima, alertas do dia, equipamentos conectados, discos (com origem e tipo de gravação) e conexão de cada equipamento.
- **Ao vivo**: modelos de tela com arrastar e soltar, modelos personalizados, rodízio de telas, split virtual para câmeras duplas, zoom digital, foto do quadro, HD/SD, som, PTZ com presets e ronda, gravação no Mac (manual ou por horário).
- **Gravações**: busca automática por câmera e dia, reprodução de ½× a 8× com som, zoom, foto e download em MP4.
- **Eventos**: histórico guardado no Mac, notificações e sons por tipo, atalhos para o ao vivo e a gravação do momento, alertas repetidos juntados e registro do app e dos equipamentos.
- **Dispositivos**: busca de câmeras e NVRs na rede, importar e exportar a lista.
- **Config. câmeras**: todas as configurações do VMS antigo e mais (qualidade do vídeo, exposição, serviços de rede, PTZ por cabo), mostrando só o que cada equipamento suporta, com prévias ilustradas.
- **Preferências do app**: tema, pastas, gravação no Mac, captura automática, segundo plano na barra de menus.
- Cofre de senhas criptografado, menus em português, Ajuda e licença MIT.
