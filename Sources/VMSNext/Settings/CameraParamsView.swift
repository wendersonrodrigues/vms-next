import SwiftUI

struct CameraParamsView: View {
    @StateObject private var model: CameraParamsModel

    init(camera: Camera) {
        _model = StateObject(wrappedValue: CameraParamsModel(camera: camera))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if model.hasColor {
                        Section("Cores da imagem") {
                            previewRow(SettingPreview(brightness: model.brightness, contrast: model.contrast,
                                                      saturation: model.saturation, hue: model.hue,
                                                      caption: String(localized: "Exemplo ilustrativo: muda conforme os controles abaixo")))
                            slider("Brilho", detail: String(localized: "Deixa a imagem toda mais clara ou mais escura."), value: $model.brightness)
                            slider("Contraste", detail: String(localized: "Diferença entre as partes claras e escuras."), value: $model.contrast)
                            slider(String(localized: "Saturação"), detail: String(localized: "Intensidade das cores; 0 deixa em preto e branco."), value: $model.saturation)
                            slider("Matiz", original: "Hue", detail: String(localized: "Puxa as cores para outro tom. Normalmente fica em 50."), value: $model.hue)
                        }
                    }
                    if model.hasImageParams {
                        Section("Dia / Noite") {
                            previewRow(SettingPreview(night: dayNightPreview, caption: dayNightCaption))
                            // Mesma lista do "Modo dia/noite" do VMS antigo; só os modos que a câmera tem.
                            Picker(selection: $model.dayNight) {
                                ForEach(model.visibleDayNightOptions, id: \.value) { option in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.original.isEmpty ? option.label : "\(option.label) (\(option.original))")
                                        if !option.detail.isEmpty {
                                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .tag(option.value)
                                }
                            } label: {
                                FieldLabel(String(localized: "Modo dia/noite"), original: "Modo dia/noite",
                                           detail: String(localized: "Como a câmera se comporta quando escurece."))
                            }
                            .pickerStyle(.radioGroup)
                            // Como no VMS antigo: nos modos normais o controle é o limiar (DNC Threshold);
                            // nos de luz dupla, o "Ajuste dia e noite".
                            let doubleLightMode = (3 ... 5).contains(model.dayNight)
                            if model.hasDayNightThreshold && (!doubleLightMode || !model.hasDayNightAdjust) {
                                slider(String(localized: "Sensibilidade da troca"), original: "DNC Threshold",
                                       detail: String(localized: "Com que escuridão a câmera passa para o modo noturno."), value: $model.dayNightThreshold,
                                       range: 10 ... 50)
                            }
                            if doubleLightMode || !model.hasDayNightThreshold { dayNightAdjustRow }
                        }
                    }
                    if model.hasWhiteLight {
                        Section("Luz branca") {
                            previewRow(SettingPreview(night: nightPreview, caption: nightCaption))
                            Picker("Modo", selection: $model.nightMode) {
                                ForEach(model.nightModeOptions, id: \.value) { option in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                        if !option.detail.isEmpty {
                                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .tag(option.value)
                                }
                            }
                            .pickerStyle(.radioGroup)

                            if model.nightMode != "Close" {
                                slider(String(localized: "Brilho da luz branca"), detail: String(localized: "Força do LED branco quando ele acende à noite."), value: $model.lightBrightness)
                            }
                            if model.nightMode == "Intelligent" {
                                Picker(selection: $model.triggerLevel) {
                                    ForEach(model.triggerLevelOptions, id: \.value) { Text($0.label).tag($0.value) }
                                } label: {
                                    FieldLabel(String(localized: "Sensibilidade da luz"), detail: String(localized: "Quão fácil uma pessoa detectada acende a luz branca."))
                                }
                                Picker(selection: $model.triggerDuration) {
                                    ForEach(model.triggerDurationOptions, id: \.self) { Text("\($0) s").tag($0) }
                                } label: {
                                    FieldLabel(String(localized: "Duração da luz ligada"), detail: String(localized: "Por quanto tempo a luz fica acesa depois de detectar alguém."))
                                }
                            }
                        }
                    }
                    if model.hasImageParams {
                        Section("Orientação") {
                            previewRow(SettingPreview(mirror: model.mirror, flip: model.flip,
                                                      caption: model.mirror || model.flip ? String(localized: "Como fica com a orientação escolhida") : String(localized: "Imagem normal")))
                            Toggle(isOn: $model.mirror) {
                                FieldLabel("Espelhar", original: "Espelhar", detail: String(localized: "Inverte a imagem da esquerda para a direita."))
                            }
                            Toggle(isOn: $model.flip) {
                                FieldLabel(String(localized: "Virar de cabeça para baixo"), original: "Girar", detail: String(localized: "Use quando a câmera estiver instalada no teto ou invertida."))
                            }
                        }
                        Section("Exposição") {
                            previewRow(SettingPreview(backlight: model.backlight,
                                                      caption: model.backlight ? String(localized: "Contraluz ligada: a pessoa no portão claro aparece")
                                                          : String(localized: "Sem compensação: quem está no portão claro vira sombra")))
                            Toggle(isOn: $model.backlight) {
                                FieldLabel(String(localized: "Compensação de contraluz"), original: "BLC / Luz de fundo",
                                           detail: String(localized: "Clareia quem está na frente de uma janela ou portão iluminado."))
                            }
                            Toggle(isOn: $model.antiFlicker) {
                                FieldLabel(String(localized: "Anti-cintilação"), original: "Anti brilho",
                                           detail: String(localized: "Evita a imagem piscando sob lâmpadas fluorescentes ou LED."))
                            }
                        }
                    }
                    if let error = model.error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warning)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            SettingsFooter(notice: model.notice, busy: model.loading || model.saving, applyDisabled: (!model.hasImageParams && !model.hasColor),
                           onDiagnostic: { model.diagnosticText = await model.diagnostic() },
                           onReload: { await model.load() },
                           onApply: { Task { await model.apply() } })
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    /// Pré-visualização ilustrativa centralizada no topo da seção.
    private func previewRow(_ preview: SettingPreview) -> some View {
        HStack {
            Spacer()
            preview
            Spacer()
        }
    }

    private var dayNightPreview: SettingPreview.Night {
        switch model.dayNight {
        case 1, 4: return .color
        case 2, 3: return .dualLight
        default: return .infrared
        }
    }

    private var dayNightCaption: String {
        model.dayNightOptions.first { $0.value == model.dayNight }.map { String(localized: "À noite: \($0.label.lowercased())") } ?? String(localized: "Modo do equipamento")
    }

    private var nightPreview: SettingPreview.Night {
        switch model.nightMode {
        case "Auto": return .color
        case "Intelligent": return .dualLight
        default: return .infrared
        }
    }

    private var nightCaption: String {
        switch model.nightMode {
        case "Auto": return "Visão noturna colorida: luz branca acesa, imagem em cores"
        case "Intelligent": return "Luz dupla: infravermelho e, ao detectar alguém, acende a luz e fica colorido"
        default: return String(localized: "Infravermelho: imagem em preto e branco, sem luz visível")
        }
    }

    /// "Ajuste dia e noite": de 1 a 5, quão cedo a câmera troca entre o modo dia e o noturno.
    @ViewBuilder
    private var dayNightAdjustRow: some View {
        if model.hasDayNightAdjust {
            HStack(alignment: .top) {
                FieldLabel(String(localized: "Ajuste dia e noite"), original: "Day and night adjustment",
                           detail: String(localized: "Quão cedo a câmera troca entre o modo dia e o noturno conforme a luz (1 a 5), como no VMS antigo."))
                    .frame(width: 260, alignment: .leading)
                Slider(value: $model.dayNightAdjust, in: 1 ... 5, step: 1)
                Text("\(Int(model.dayNightAdjust))").monospacedDigit().frame(width: 32, alignment: .trailing)
            }
        }
    }

    /// O limiar dia/noite (DncThr) vai de 10 a 50 no VMS antigo; o resto, de 0 a 100.
    private func slider(_ title: String, original: String? = nil, detail: String? = nil, value: Binding<Double>,
                        range: ClosedRange<Double> = 0 ... 100) -> some View {
        HStack(alignment: .top) {
            FieldLabel(title, original: original, detail: detail).frame(width: 260, alignment: .leading)
            Slider(value: value, in: min(range.lowerBound, value.wrappedValue) ... max(range.upperBound, value.wrappedValue), step: 1)
            Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 32, alignment: .trailing)
        }
    }
}

/// Mostra o JSON de configuração lido da câmera, com botão para copiar.
struct DiagnosticSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnóstico").font(.headline)
            Text("Configurações lidas da câmera, sem senhas. Copie e envie para análise.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.small))
            HStack {
                Spacer()
                Button("Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560, height: 480)
    }
}
