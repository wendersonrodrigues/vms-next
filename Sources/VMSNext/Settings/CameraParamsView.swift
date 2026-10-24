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
                                                      caption: "Exemplo ilustrativo: muda conforme os controles abaixo"))
                            slider("Brilho", detail: "Deixa a imagem toda mais clara ou mais escura.", value: $model.brightness)
                            slider("Contraste", detail: "Diferença entre as partes claras e escuras.", value: $model.contrast)
                            slider("Saturação", detail: "Intensidade das cores; 0 deixa em preto e branco.", value: $model.saturation)
                            slider("Matiz", original: "Hue", detail: "Puxa as cores para outro tom. Normalmente fica em 50.", value: $model.hue)
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
                                FieldLabel("Modo dia/noite", original: "Modo dia/noite",
                                           detail: "Como a câmera se comporta quando escurece.")
                            }
                            .pickerStyle(.radioGroup)
                            if model.hasDayNightThreshold {
                                slider("Sensibilidade da troca", detail: "Com que escuridão a câmera passa para o modo noturno.", value: $model.dayNightThreshold)
                            }
                            dayNightAdjustRow
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
                                slider("Brilho da luz branca", detail: "Força do LED branco quando ele acende à noite.", value: $model.lightBrightness)
                            }
                            if model.nightMode == "Intelligent" {
                                Picker(selection: $model.triggerLevel) {
                                    ForEach(model.triggerLevelOptions, id: \.value) { Text($0.label).tag($0.value) }
                                } label: {
                                    FieldLabel("Sensibilidade da luz", detail: "Quão fácil uma pessoa detectada acende a luz branca.")
                                }
                                Picker(selection: $model.triggerDuration) {
                                    ForEach(model.triggerDurationOptions, id: \.self) { Text("\($0) s").tag($0) }
                                } label: {
                                    FieldLabel("Duração da luz ligada", detail: "Por quanto tempo a luz fica acesa depois de detectar alguém.")
                                }
                            }
                        }
                    }
                    if model.hasImageParams {
                        Section("Orientação") {
                            previewRow(SettingPreview(mirror: model.mirror, flip: model.flip,
                                                      caption: model.mirror || model.flip ? "Como fica com a orientação escolhida" : "Imagem normal"))
                            Toggle(isOn: $model.mirror) {
                                FieldLabel("Espelhar", original: "Mirror", detail: "Inverte a imagem da esquerda para a direita.")
                            }
                            Toggle(isOn: $model.flip) {
                                FieldLabel("Virar de cabeça para baixo", original: "Flip", detail: "Use quando a câmera estiver instalada no teto ou invertida.")
                            }
                        }
                        Section("Exposição") {
                            previewRow(SettingPreview(backlight: model.backlight,
                                                      caption: model.backlight ? "Contraluz ligada: a pessoa no portão claro aparece"
                                                          : "Sem compensação: quem está no portão claro vira sombra"))
                            Toggle(isOn: $model.backlight) {
                                FieldLabel("Compensação de contraluz", original: "BLC / Luz de fundo",
                                           detail: "Clareia quem está na frente de uma janela ou portão iluminado.")
                            }
                            Toggle(isOn: $model.antiFlicker) {
                                FieldLabel("Anti-cintilação", original: "Anti brilho",
                                           detail: "Evita a imagem piscando sob lâmpadas fluorescentes ou LED.")
                            }
                        }
                    }
                    if let error = model.error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Diagnóstico…") { Task { model.diagnosticText = await model.diagnostic() } }
                    .disabled(model.loading || model.saving)
                Button("Recarregar") { Task { await model.load() } }
                    .disabled(model.loading || model.saving)
                Button("Aplicar") { Task { await model.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.loading || model.saving || (!model.hasImageParams && !model.hasColor))
            }
            .padding(12)
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
        model.dayNightOptions.first { $0.value == model.dayNight }.map { "À noite: \($0.label.lowercased())" } ?? "Modo do equipamento"
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
        default: return "Infravermelho: imagem em preto e branco, sem luz visível"
        }
    }

    /// "Ajuste dia e noite": de 1 a 5, quão cedo a câmera troca entre o modo dia e o noturno.
    @ViewBuilder
    private var dayNightAdjustRow: some View {
        if model.hasDayNightAdjust {
            HStack(alignment: .top) {
                FieldLabel("Ajuste dia e noite", original: "Day and night adjustment",
                           detail: "Quão cedo a câmera troca entre o modo dia e o noturno conforme a luz (1 a 5), como no VMS antigo.")
                    .frame(width: 260, alignment: .leading)
                Slider(value: $model.dayNightAdjust, in: 1 ... 5, step: 1)
                Text("\(Int(model.dayNightAdjust))").monospacedDigit().frame(width: 32, alignment: .trailing)
            }
        }
    }

    private func slider(_ title: String, original: String? = nil, detail: String? = nil, value: Binding<Double>) -> some View {
        HStack(alignment: .top) {
            FieldLabel(title, original: original, detail: detail).frame(width: 260, alignment: .leading)
            Slider(value: value, in: 0 ... 100, step: 1)
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
                    .padding(8)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
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
