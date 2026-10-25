import Foundation

/// Telas feitas com ConfigFormView. Os nomes e caminhos seguem o JSON da Xiongmai; quando um
/// valor não está nas opções conhecidas, a tela mostra "Valor do equipamento (…)".
enum ConfigFormSpecs {
    // MARK: - Qualidade do vídeo e som ("Mídia")

    static func encoding(camera: Camera) -> ConfigFormSpec {
        let channel = camera.channel - 1
        func stream(_ format: String, extra: Bool) -> [ConfigField] {
            let video: [ConfigKey] = [.key(format), "Video"]
            var fields: [ConfigField] = []
            if extra {
                fields.append(ConfigField(source: 0, path: [.key(format), "VideoEnable"], kind: .toggle,
                                          title: "Ativar o vídeo extra", original: "Vídeo",
                                          detail: "Versão leve do vídeo, usada na qualidade \"Extra\" do mosaico e no celular."))
            } else {
                fields.append(ConfigField(source: 0, path: video + ["Compression"], kind: .choice(compressions),
                                          title: "Compressão", original: "Compressão",
                                          detail: "H.265X é o H.265 com economia extra de espaço (o equipamento o registra como \"H.264\"). Fica travado nas câmeras que só têm uma opção.",
                                          allowed: { allowedCompressions($0, channel: channel) }))
            }
            let vbr = ConfigCondition(source: 0, path: video + ["BitRateControl"], values: ["VBR"])
            let cbr = ConfigCondition(source: 0, path: video + ["BitRateControl"], values: ["CBR"])
            fields += [
                ConfigField(source: 0, path: video + ["Resolution"], kind: .choice(resolutions),
                            title: "Resolução", original: "Resolução",
                            detail: extra ? "Tamanho da imagem do vídeo extra; depende da resolução do principal."
                                          : "Tamanho da imagem. Só aparecem as resoluções que a câmera suporta.",
                            allowed: { allowedResolutions($0, channel: channel, extra: extra) }),
                ConfigField(source: 0, path: video + ["Quality"], kind: .choice(qualities),
                            title: "Qualidade da imagem", original: "Qualidade",
                            detail: "Só no modo variável (VBR). Mais qualidade usa mais espaço no disco e mais internet.",
                            enabledWhen: vbr),
                ConfigField(source: 0, path: video + ["FPS"], kind: .choice((1 ... 30).map { ConfigOption(String($0), "\($0) quadros/s") }),
                            title: "Quadros por segundo", original: "FPS",
                            detail: "Mais quadros deixam o movimento mais suave e ocupam mais espaço."),
                ConfigField(source: 0, path: video + ["BitRateControl"], kind: .choice(bitRateControls),
                            title: "Controle de taxa", original: "Controle de stream",
                            detail: "Variável (VBR) segue a qualidade escolhida; constante (CBR) usa sempre a taxa de bits abaixo."),
                ConfigField(source: 0, path: video + ["BitRate"], kind: .choice([]),
                            title: "Taxa de bits", original: "Taxa de bit",
                            detail: "Só ajustável no modo constante (CBR) e com a codificação inteligente desligada. Mais kb/s = imagem melhor e arquivos maiores.",
                            enabledWhen: cbr,
                            disabledWhen: ConfigCondition(source: 2, path: ["Smart264PlusV2", .index(extra ? 1 : 0), "SmartH264Plus"],
                                                          values: ["1"]),
                            dynamicOptions: { bitRates($0, video: video) }),
                ConfigField(source: 0, path: video + ["GOP"], kind: .choice((1 ... 12).map { ConfigOption(String($0), "\($0) s") }),
                            title: "Intervalo entre quadros completos", original: "Intervalo de quadro",
                            detail: "Valores menores ajudam a avançar na gravação com precisão, mas ocupam mais espaço."),
                ConfigField(source: 0, path: [.key(format), "AudioEnable"], kind: .toggle,
                            title: "Gravar e transmitir o som", original: "Áudio",
                            detail: "Precisa de câmera com microfone."),
                // H265AI fica em Smart264PlusV2 (0/1); o Smart264V2.SmartH264 continua false nas câmeras testadas.
                ConfigField(source: 2, path: ["Smart264PlusV2", .index(extra ? 1 : 0), "SmartH264Plus"], kind: .choice([
                    ConfigOption("0", "Desligada (Fechar)"), ConfigOption("1", "Ligada (H265AI)"),
                ]), title: "Codificação inteligente", original: "Smart Encode",
                detail: "Economiza espaço quando a cena está parada.",
                requires: "EncodeFunction.SmartH264V2"),
            ]
            return fields
        }
        return ConfigFormSpec(
            intro: "Define como a câmera comprime o vídeo: o principal é o gravado e visto em alta qualidade; o extra é uma versão leve para o mosaico e o celular.",
            sources: [
                ConfigSource(name: "Simplify.Encode", element: channel),
                ConfigSource(name: "AVEnc.EncodeStaticParam", element: channel),
                ConfigSource(name: "AVEnc.SmartH264V2.[\(channel)]"),
            ],
            sections: [
                ConfigSection(title: "Vídeo principal (Stream principal)", fields: stream("MainFormat", extra: false)),
                ConfigSection(title: "Vídeo extra (Stream secundário)", fields: stream("ExtraFormat", extra: true)),
                ConfigSection(title: "Avançado", fields: [
                    ConfigField(source: 1, path: ["Profile"], kind: .choice([
                        ConfigOption("1", "Base (Baseline)"), ConfigOption("2", "Perfil principal (Main)"),
                        ConfigOption("3", "Perfil de destaque (High)"),
                    ]), title: "Perfil de codificação", original: "Configuração de codificação estática",
                    detail: "Perfis mais altos comprimem melhor; alguns aparelhos antigos só tocam o Básico."),
                ]),
            ],
            offersRestart: true,
            abilities: ["EncodeCapability"])
    }

    // Capacidades (EncodeCapability): CompressionMask usa o bit 7 para H.264 e o 8 para H.265;
    // ResolutionMask usa um bit por tamanho, na ordem de `resolutionBits`. A resolução do vídeo extra
    // depende da principal: ExImageSizePerChannelEx[canal][bit da principal].
    private static let resolutionBits = [
        "D1", "HD1", "BCIF", "CIF", "QCIF", "VGA", "QVGA", "SVCD", "QQVGA", "ND1", "650TVL", "720P", "1_3M",
        "UXGA", "1080P", "WUXGA", "2_5M", "3M", "5M", "1080N", "4M", "6M", "8M", "12M", "4K",
    ]

    @MainActor
    private static func capability(_ model: ConfigFormModel) -> [String: Any]? {
        model.abilities["EncodeCapability"] as? [String: Any]
    }

    private static func mask(_ list: Any?, _ index: Int) -> Int? {
        guard let list = list as? [Any] else { return nil }
        return ConfigValue.int(list.indices.contains(index) ? list[index] : list.first)
    }

    private static func bits(_ mask: Int) -> [Int] {
        (0 ..< 32).filter { mask & (1 << $0) != 0 }
    }

    @MainActor
    private static func allowedCompressions(_ model: ConfigFormModel, channel: Int) -> [String]? {
        guard let info = capability(model)?["EncodeInfo"] as? [[String: Any]],
              let main = info.first(where: { $0["StreamType"] as? String == "MainStream" }),
              let value = ConfigValue.int(main["CompressionMask"]), value != 0 else { return nil }
        return bits(value).compactMap { [7: "H.264", 8: "H.265"][$0] }
    }

    @MainActor
    private static func allowedResolutions(_ model: ConfigFormModel, channel: Int, extra: Bool) -> [String]? {
        guard let capability = capability(model) else { return nil }
        let value: Int?
        if extra {
            let main = model.value(source: 0, path: ["MainFormat", "Video", "Resolution"]) as? String
            guard let bit = main.flatMap({ resolutionBits.firstIndex(of: $0) }),
                  let table = (capability["ExImageSizePerChannelEx"] as? [Any])?[safe: channel] as? [Any]
                      ?? (capability["ExImageSizePerChannelEx"] as? [Any])?.first as? [Any] else { return nil }
            value = mask(table, bit)
        } else {
            value = mask(capability["ImageSizePerChannel"], channel)
        }
        guard let value, value != 0 else { return nil }
        return bits(value).compactMap { resolutionBits[safe: $0] }
    }

    /// Tamanho em pixels de cada resolução (mesmos valores das tabelas res_pw/res_ph do NVR).
    private static let resolutionPixels: [String: Double] = [
        "CIF": 352 * 288, "HD1": 704 * 288, "D1": 704 * 576, "960H": 960 * 576, "720P": 1280 * 720,
        "960P": 1280 * 960, "1080N": 960 * 1080, "1080P": 1920 * 1080, "3M": 2304 * 1296, "4M": 2560 * 1440,
        "5M": 2592 * 1944, "6M": 3072 * 2048, "8M": 3840 * 2160, "4K": 3840 * 2160,
    ]

    /// Lista de taxas como no VMS antigo: seis degraus (15%, 30%, 40%, 60%, 80% e 100%) de um máximo que
    /// cresce com a resolução e o FPS. O máximo segue os valores medidos no VMS antigo (4M a 12 qps = 4897,
    /// a 24 qps = 5632, a 27 qps = 6077; D1 a 12 qps = 795); a câmera aceita qualquer valor.
    @MainActor
    private static func bitRates(_ model: ConfigFormModel, video: [ConfigKey]) -> [ConfigOption]? {
        guard let resolution = model.value(source: 0, path: video + ["Resolution"]) as? String,
              let pixels = resolutionPixels[resolution] else { return nil }
        let fps = Double(ConfigValue.int(model.value(source: 0, path: video + ["FPS"])) ?? 12)
        let maximum = 4897 * pow(pixels / (2560 * 1440), 0.82) * fpsFactor(fps)
        var values = [0.15, 0.3, 0.4, 0.6, 0.8, 1.0].map { Int(maximum * $0) }
        if let current = ConfigValue.int(model.value(source: 0, path: video + ["BitRate"])), !values.contains(current) {
            values.append(current)
            values.sort()
        }
        return values.map { ConfigOption(String($0), "\($0) kb/s") }
    }

    /// Quanto o máximo cresce com o FPS, em relação a 12 qps: interpolado entre os pontos medidos.
    private static func fpsFactor(_ fps: Double) -> Double {
        let points: [(fps: Double, factor: Double)] = [(12, 1), (24, 5632.0 / 4897), (27, 6077.0 / 4897)]
        if fps <= 12 { return pow(max(fps, 1) / 12, 0.266) }
        for (low, high) in zip(points, points.dropFirst()) where fps <= high.fps {
            return low.factor + (high.factor - low.factor) * (fps - low.fps) / (high.fps - low.fps)
        }
        let (low, high) = (points[points.count - 2], points[points.count - 1])
        return high.factor + (high.factor - low.factor) * (fps - high.fps) / (high.fps - low.fps)
    }

    /// "Camera".Speeds: tempos fixos do obturador em µs, um por nível manual (1, 2, ...).
    @MainActor
    private static func exposureLevels(_ model: ConfigFormModel) -> [ConfigOption]? {
        guard let speeds = (model.abilities["Camera"] as? [String: Any])?["Speeds"] as? [Any], !speeds.isEmpty else { return nil }
        // Como o VMS antigo (CCameraParamConfig::onUpdateConfig): ordena os tempos do maior para o menor e o
        // Level gravado é a posição nessa lista (1 = obturador mais lento).
        let sorted = speeds.compactMap { ConfigValue.int($0) }.filter { $0 > 0 }.sorted(by: >)
        var options = [ConfigOption("0", "Automático")]
        for (index, micro) in sorted.enumerated() {
            options.append(ConfigOption(String(index + 1), "Manual · 1/\(Int(1_000_000 / Double(micro))) s"))
        }
        return options
    }

    @MainActor
    private static func protocols(_ model: ConfigFormModel, _ name: String) -> [ConfigOption]? {
        guard let list = model.abilities[name] as? [String], !list.isEmpty else { return nil }
        let names = ["NONE": "Nenhum", "PELCOD": "Pelco-D", "PELCOP": "Pelco-P"]
        return list.map { ConfigOption($0, names[$0] ?? $0) }
    }

    private static let compressions = [ConfigOption("H.265", "H.265"), ConfigOption("H.264", "H.265X")]

    private static let resolutions = [
        ConfigOption("CIF", "CIF (352×288)"), ConfigOption("HD1", "HD1 (704×288)"),
        ConfigOption("D1", "D1 (704×576)"), ConfigOption("960H", "960H (960×576)"),
        ConfigOption("720P", "720P (1280×720)"), ConfigOption("960P", "960P (1280×960)"),
        ConfigOption("1080N", "1080N (960×1080)"), ConfigOption("1080P", "1080P (1920×1080)"),
        ConfigOption("3M", "3M (2304×1296)"), ConfigOption("4M", "4M (2560×1440)"),
        ConfigOption("5M", "5M (2592×1944)"), ConfigOption("6M", "6M (3072×2048)"),
        ConfigOption("8M", "8M (3840×2160)"), ConfigOption("4K", "4K (3840×2160)"),
    ]

    private static let qualities = [
        ConfigOption("1", "Muito baixa (Muito baixo)"), ConfigOption("2", "Baixa (Baixo)"),
        ConfigOption("3", "Normal (Geral)"), ConfigOption("4", "Boa (Bom)"),
        ConfigOption("5", "Muito alta (Muito alta)"), ConfigOption("6", "Máxima (Ultra alta)"),
    ]

    private static let bitRateControls = [
        ConfigOption("CBR", "Constante (CBR)"), ConfigOption("VBR", "Variável (VBR)"),
    ]

    // MARK: - Exposição e ajustes finos ("Parâmetros da cam")

    static func exposure(camera: Camera) -> ConfigFormSpec {
        let channel = camera.channel - 1
        let level0to5 = (0 ... 5).map { ConfigOption(String($0), String($0)) }
        return ConfigFormSpec(
            intro: "Ajustes finos da imagem que o VMS antigo mostra em Parâmetros da cam. Brilho, cores, espelhar e visão noturna ficam em \"Imagem e visão noturna\".",
            sources: [
                ConfigSource(name: "Camera.Param.[\(channel)]"),
                ConfigSource(name: "Camera.ParamEx.[\(channel)]"),
                // "Nevoeiro nublado" do VMS antigo; só aparece se a câmera responder.
                ConfigSource(name: "Camera.ClearFog", element: channel),
            ],
            sections: [
                ConfigSection(title: "Exposição", fields: [
                    ConfigField(source: 0, path: ["ExposureParam", "Level"], kind: .choice([
                        ConfigOption("0", "Automático"), ConfigOption("1", "Manual"),
                    ]), title: "Modo de exposição", original: "Modo de exposição",
                    detail: "No automático a câmera escolhe o tempo do obturador entre o mínimo e o máximo abaixo; os outros fixam o obturador.",
                    dynamicOptions: exposureLevels),
                    // O VMS antigo só aceita de 0,1 a 80 ms e só grava os tempos no modo automático.
                    ConfigField(source: 0, path: ["ExposureParam", "LeastTime"], kind: .number(100 ... 80000, unit: "µs"),
                                title: "Tempo mínimo do obturador", original: "Horário",
                                detail: "Em microssegundos (1000 µs = 1 ms), de 100 a 80000.",
                                enabledWhen: ConfigCondition(source: 0, path: ["ExposureParam", "Level"], values: ["0"])),
                    ConfigField(source: 0, path: ["ExposureParam", "MostTime"], kind: .number(100 ... 80000, unit: "µs"),
                                title: "Tempo máximo do obturador", original: "Horário",
                                detail: "Tempos maiores clareiam a noite, mas borram quem se move.",
                                enabledWhen: ConfigCondition(source: 0, path: ["ExposureParam", "Level"], values: ["0"])),
                    ConfigField(source: 0, path: ["ElecLevel"], kind: .slider(0 ... 100),
                                title: "Brilho de referência", original: "Referência AE",
                                detail: "Quão clara a câmera tenta deixar a imagem. Padrão 50."),
                    ConfigField(source: 0, path: ["AeSensitivity"], kind: .slider(1 ... 10),
                                title: "Rapidez da exposição", original: "Sensibilidade AE",
                                detail: "Quão rápido a imagem se ajusta quando a luz muda."),
                    ConfigField(source: 0, path: ["EsShutter"], kind: .choice([
                        ConfigOption("0", "Nenhum"), ConfigOption("2", "Baixo"),
                        ConfigOption("4", "Média"), ConfigOption("6", "Forte"),
                    ]), title: "Obturador lento", original: "Obturador lento",
                    detail: "Clareia cenas escuras deixando o obturador aberto por mais tempo; pode causar rastro."),
                    ConfigField(source: 0, path: ["ApertureMode"], kind: .toggle,
                                title: "Íris automática", original: "Auto íris",
                                detail: "Só para lentes com íris motorizada."),
                ]),
                ConfigSection(title: "Ganho e contraluz", fields: [
                    ConfigField(source: 0, path: ["GainParam", "AutoGain"], kind: .toggle,
                                title: "Ganho automático", original: "AGC",
                                detail: "Amplifica a imagem no escuro; aumenta o chiado (ruído)."),
                    ConfigField(source: 0, path: ["GainParam", "Gain"], kind: .slider(0 ... 100),
                                title: "Limite do ganho", original: "Superior"),
                    ConfigField(source: 1, path: ["BroadTrends", "AutoGain"], kind: .toggle,
                                title: "Faixa dinâmica ampliada", original: "Faixa dinâmica / WDR",
                                detail: "Mostra detalhes em áreas muito claras e muito escuras ao mesmo tempo, como portões contra o sol."),
                    ConfigField(source: 1, path: ["BroadTrends", "Gain"], kind: .slider(0 ... 100),
                                title: "Intensidade da faixa dinâmica", original: "Superior",
                                enabledWhen: ConfigCondition(source: 1, path: ["BroadTrends", "AutoGain"], values: ["1"])),
                ]),
                ConfigSection(title: "Estilo e ruído", fields: [
                    ConfigField(source: 0, path: ["WhiteBalance"], kind: .choice([
                        ConfigOption("0", "Automático"), ConfigOption("1", "Interno"), ConfigOption("2", "Externo"),
                    ]), title: "Modo de cena", original: "Modo de cena",
                    detail: "Ajusta as cores para o tipo de luz do local."),
                    ConfigField(source: 1, path: ["Style"], kind: .choice([
                        ConfigOption("typedefault", "Estilo 1"), ConfigOption("type1", "Estilo 2"), ConfigOption("type2", "Estilo 3"),
                    ]), title: "Perfil de imagem", original: "Perfil de vídeo",
                    detail: "Predefinições de nitidez e cor da fábrica."),
                    ConfigField(source: 0, path: ["Day_nfLevel"], kind: .choice(level0to5),
                                title: "Redução de ruído de dia", original: "Nível dia NT",
                                detail: "Valores altos limpam o chiado, mas deixam a imagem mais lisa."),
                    ConfigField(source: 0, path: ["Night_nfLevel"], kind: .choice(level0to5),
                                title: "Redução de ruído à noite", original: "Nível de night NT"),
                ]),
                ConfigSection(title: "Nevoeiro e brilho", fields: [
                    ConfigField(source: 2, path: ["enable"], kind: .toggle,
                                title: "Nevoeiro nublado", original: "Clear Fog",
                                detail: "Clareia a imagem em dias de neblina, chuva fina ou fumaça."),
                    ConfigField(source: 2, path: ["Enable"], kind: .toggle,
                                title: "Nevoeiro nublado", original: "Clear Fog",
                                detail: "Clareia a imagem em dias de neblina, chuva fina ou fumaça."),
                    ConfigField(source: 2, path: ["level"], kind: .slider(0 ... 100),
                                title: "Intensidade do nevoeiro", original: "Level",
                                enabledWhen: ConfigCondition(source: 2, path: ["enable"], values: ["1"])),
                    ConfigField(source: 2, path: ["Level"], kind: .slider(0 ... 100),
                                title: "Intensidade do nevoeiro", original: "Level",
                                enabledWhen: ConfigCondition(source: 2, path: ["Enable"], values: ["1"])),
                    ConfigField(source: 1, path: ["PreventOverExpo"], kind: .toggle,
                                title: "Evitar rosto estourado", original: "NoRedFaceExposure",
                                detail: "À noite, segura o infravermelho para quem chega perto da câmera não ficar branco.",
                                requires: "Camera.SupportPreventOverExpo"),
                ]),
                // Só nas câmeras que informam a função, como no VMS antigo.
                ConfigSection(title: "Orientação e lente", fields: [
                    ConfigField(source: 1, path: ["CorridorMode"], kind: .choice([
                        ConfigOption("0", "Normal"), ConfigOption("1", "Corredor 1"),
                        ConfigOption("2", "Reflexo"), ConfigOption("3", "Corredor 2"),
                    ]), title: "Modo corredor", original: "CorridorMode",
                    detail: "Gira a imagem para ficar em pé, útil em corredores e portas estreitas.",
                    requires: "OtherFunction.SupportCorridorMode"),
                    ConfigField(source: 1, path: ["LDCValue"], kind: .slider(0 ... 100),
                                title: "Correção de distorção da lente", original: "LDC",
                                detail: "Endireita as bordas curvas das lentes grande-angulares.",
                                requires: "Camera.SupportSetLDC"),
                ]),
                ConfigSection(title: "Filtro infravermelho", fields: [
                    ConfigField(source: 0, path: ["IRCUTMode"], kind: .choice([
                        ConfigOption("0", "Sincronização"), ConfigOption("1", "Sincronização automática"),
                    ]), title: "Troca do filtro IR", original: "IR CUT",
                    detail: "Quando a câmera troca o filtro entre dia e noite."),
                    ConfigField(source: 0, path: ["IrcutSwap"], kind: .toggle,
                                title: "Inverter o filtro IR", original: "Troca de IR",
                                detail: "Só ligue se a imagem ficar rosada de dia ou escura à noite."),
                ]),
            ],
            abilities: ["Camera"],
            preview: { model in
                // Brilho de referência e ganho clareiam; faixa dinâmica mostra quem está contra a luz.
                let reference = Double(ConfigValue.int(model.value(source: 0, path: ["ElecLevel"])) ?? 50)
                let gainOn = ConfigFormModel.boolValue(model.value(source: 0, path: ["GainParam", "AutoGain"]))
                let wdr = model.value(source: 1, path: ["BroadTrends", "AutoGain"]).map(ConfigFormModel.boolValue)
                let noise = Double(ConfigValue.int(model.value(source: 0, path: ["Day_nfLevel"])) ?? 3)
                return SettingPreview(brightness: reference + (gainOn ? 8 : 0), contrast: 50 - noise * 3,
                                      backlight: wdr, caption: "Exemplo ilustrativo: brilho, ganho e faixa dinâmica")
            })
    }

    // MARK: - PTZ por cabo ("Config. de PTZ")

    static func ptzSerial(camera: Camera) -> ConfigFormSpec {
        func port(_ source: Int) -> [ConfigField] {
            [
                ConfigField(source: source, path: ["ProtocolName"], kind: .choice([
                    ConfigOption("NONE", "Nenhum"), ConfigOption("PELCOD", "Pelco-D"), ConfigOption("PELCOP", "Pelco-P"),
                ]), title: "Protocolo", original: "Protocolo",
                detail: "Tem que ser o mesmo configurado no motor ou na speed dome.",
                dynamicOptions: { protocols($0, source == 0 ? "PTZProtocol" : "UartProtocol") }),
                ConfigField(source: source, path: ["DeviceNo"], kind: .number(0 ... 255, unit: nil),
                            title: "Endereço", original: "Endereço",
                            detail: "Número do equipamento no cabo; igual ao das chaves do motor."),
                ConfigField(source: source, path: ["Attribute", 0], kind: .choice(
                    [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200].map { ConfigOption(String($0), String($0)) }),
                    title: "Velocidade", original: "Taxa"),
                ConfigField(source: source, path: ["Attribute", 1], kind: .choice(
                    (5 ... 8).map { ConfigOption(String($0), String($0)) }),
                    title: "Bits de dados", original: "Bits de dados"),
                ConfigField(source: source, path: ["Attribute", 3], kind: .choice([
                    ConfigOption("1", "1"), ConfigOption("2", "2"),
                ]), title: "Bits de parada", original: "Bits de parada"),
                ConfigField(source: source, path: ["Attribute", 2], kind: .choice([
                    ConfigOption("0", "Nenhuma"), ConfigOption("1", "Ímpar"), ConfigOption("2", "Par"),
                    ConfigOption("3", "Marca"), ConfigOption("4", "Espaço"),
                ]), title: "Paridade", original: "Paridade"),
            ]
        }
        return ConfigFormSpec(
            intro: "Só para câmeras com motor ligado por cabo RS485 (speed dome analógica). Câmeras IP com PTZ se movem pela rede e não usam isto.",
            sources: [
                ConfigSource(name: "Uart.PTZ", element: camera.channel - 1),
                ConfigSource(name: "Uart.RS485"),
            ],
            sections: [
                ConfigSection(title: "Porta PTZ (PTZ)", fields: port(0)),
                ConfigSection(title: "Porta RS485 (Rs485)", fields: port(1), requires: "CommFunction.CommRS485"),
            ],
            abilities: ["PTZProtocol", "UartProtocol"])
    }

    // MARK: - Serviços de rede (abas da "Rede")

    static func networkServices(camera: Camera) -> ConfigFormSpec {
        ConfigFormSpec(
            intro: "As outras abas da Rede do VMS antigo. Endereço IP, DNS e portas ficam em \"Rede\".",
            sources: [
                ConfigSource(name: "NetWork.NetCommon"),
                ConfigSource(name: "NetWork.Nat"),
                ConfigSource(name: "NetWork.RTSP"),
                ConfigSource(name: "NetWork.NetIPFilter"),
                ConfigSource(name: "NetWork.Wifi"),
                ConfigSource(name: "NetWork.PMS"),
                ConfigSource(name: "NetWork.OnvifPwdCheckout"),
            ],
            sections: [
                ConfigSection(title: "Transmissão (TCP/IP)", fields: [
                    ConfigField(source: 0, path: ["UseHSDownLoad"], kind: .toggle,
                                title: "Download rápido", original: "Habilitar alta velocidade de download",
                                detail: "Baixa gravações mais rápido, usando mais da rede."),
                    ConfigField(source: 0, path: ["TransferPlan"], kind: .choice([
                        ConfigOption("Quality", "Prioriza a qualidade (Pré qualidade)"),
                        ConfigOption("Fluency", "Prioriza a fluidez (Pré fluência)"),
                        ConfigOption("AutoAdapt", "Automático (Adaptativo)"),
                        ConfigOption("Transmission", "Prioriza a transmissão"),
                    ]), title: "Política de transmissão", original: "Política de transmissão de rede",
                    detail: "Em rede lenta, a fluidez reduz a qualidade para o vídeo não travar."),
                ]),
                ConfigSection(title: "Nuvem (Nuvem)", fields: [
                    ConfigField(source: 1, path: ["NatEnable"], kind: .toggle,
                                title: "Acesso pela nuvem", original: "Nuvem",
                                detail: "Permite ver a câmera pelo iCSee/XMEye fora de casa. Desligado, só funciona na rede local."),
                    ConfigField(source: 1, path: ["XMeyeMTU"], kind: .number(576 ... 1500, unit: "bytes"),
                                title: "Tamanho do pacote (MTU)", original: "MTU",
                                detail: "Padrão 1280. Só mude se o acesso pela nuvem ficar travando.",
                                enabledWhen: ConfigCondition(source: 1, path: ["NatEnable"], values: ["1"])),
                ], requires: "NetServerFunction.NetNat"),
                ConfigSection(title: "ONVIF", fields: [
                    ConfigField(source: 6, path: ["OnvifPort"], kind: .number(1 ... 65535, unit: nil),
                                title: "Porta ONVIF", original: "Porta onvif",
                                detail: "Usada por NVRs e programas de outras marcas para achar a câmera."),
                    ConfigField(source: 6, path: ["Port"], kind: .number(1 ... 65535, unit: nil),
                                title: "Porta ONVIF", original: "Porta onvif",
                                detail: "Usada por NVRs e programas de outras marcas para achar a câmera."),
                    ConfigField(source: 6, path: ["Enable"], kind: .toggle,
                                title: "Exigir senha no ONVIF", original: "OnvifProtect",
                                detail: "Desligado, qualquer aparelho da rede consegue ver a câmera pelo ONVIF sem senha."),
                ]),
                ConfigSection(title: "RTSP (RTSP)",
                              footer: "O VMS Next usa o RTSP para o vídeo ao vivo das câmeras avulsas. Se mudar a porta, ajuste também \"Porta RTSP\" em Editar câmera.",
                              fields: [
                                  ConfigField(source: 2, path: ["IsServer"], kind: .toggle,
                                              title: "Servidor RTSP ligado", original: "RTSP"),
                                  ConfigField(source: 2, path: ["Server", "Port"], kind: .number(1 ... 65535, unit: nil),
                                              title: "Porta RTSP", original: "Porta"),
                              ], requires: "NetServerFunction.NetRTSP"),
                ConfigSection(title: "Filtro de IP (Filtro de IP)",
                              footer: "Somente leitura: um filtro errado bloqueia o próprio Mac. Para mudar, use o VMS antigo ou o iCSee.",
                              fields: [
                                  ConfigField(source: 3, path: ["Enable"], kind: .info, title: "Filtro ligado"),
                                  ConfigField(source: 3, path: ["TrustList"], kind: .ipAddress, title: "Endereços permitidos", original: "Lista branca"),
                                  ConfigField(source: 3, path: ["Trusted"], kind: .ipAddress, title: "Endereços permitidos", original: "Lista branca"),
                                  ConfigField(source: 3, path: ["BannedList"], kind: .ipAddress, title: "Endereços bloqueados", original: "Lista negra"),
                                  ConfigField(source: 3, path: ["Banned"], kind: .ipAddress, title: "Endereços bloqueados", original: "Lista negra"),
                              ], requires: "NetServerFunction.NetIPFilter"),
                ConfigSection(title: "Wi-Fi (Wifi)",
                              footer: "Somente leitura: uma rede ou senha errada desconecta a câmera. Para trocar o Wi-Fi, use o iCSee.",
                              fields: [
                                  ConfigField(source: 4, path: ["Enable"], kind: .info, title: "Wi-Fi ligado"),
                                  ConfigField(source: 4, path: ["SSID"], kind: .info, title: "Rede (SSID)"),
                                  ConfigField(source: 4, path: ["HostIP"], kind: .ipAddress, title: "IP no Wi-Fi"),
                              ], requires: "NetServerFunction.NetWifi"),
                ConfigSection(title: "Notificações no celular (Pms)", fields: [
                    ConfigField(source: 5, path: ["Enable"], kind: .toggle,
                                title: "Enviar alertas ao celular", original: "Pms",
                                detail: "Manda os alarmes para o app iCSee/XMEye pelo servidor da fabricante."),
                    ConfigField(source: 5, path: ["ServName"], kind: .info, title: "Servidor"),
                    ConfigField(source: 5, path: ["Port"], kind: .info, title: "Porta"),
                ], requires: "NetServerFunction.NetPMS"),
            ],
            confirmApply: "Algumas destas opções podem cortar o acesso pelo celular ou o vídeo ao vivo. Confira antes de aplicar.")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
