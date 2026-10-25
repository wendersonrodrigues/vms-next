# Novidades

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
