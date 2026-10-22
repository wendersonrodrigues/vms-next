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
                        Section("Imagem") {
                            slider("Brilho", value: $model.brightness)
                            slider("Contraste", value: $model.contrast)
                            slider("Saturação", value: $model.saturation)
                            slider("Matiz", value: $model.hue)
                        }
                    }
                    if model.hasWhiteLight {
                        Section("Visão noturna") {
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
                                slider("Brilho da luz branca", value: $model.lightBrightness)
                            }
                            if model.nightMode == "Intelligent" {
                                Picker("Sensibilidade", selection: $model.triggerLevel) {
                                    ForEach(model.triggerLevelOptions, id: \.value) { Text($0.label).tag($0.value) }
                                }
                                Picker("Duração da luz ligada", selection: $model.triggerDuration) {
                                    ForEach(model.triggerDurationOptions, id: \.self) { Text("\($0) s").tag($0) }
                                }
                            }
                        }
                    }
                    if model.hasImageParams && !model.hasWhiteLight {
                        Section("Dia / Noite") {
                            Picker("Modo", selection: $model.dayNight) {
                                ForEach(model.dayNightOptions, id: \.value) { Text($0.label).tag($0.value) }
                            }
                            if model.hasDayNightThreshold && model.dayNight == CameraParamsModel.autoDayNightMode {
                                slider("Sensibilidade da troca", value: $model.dayNightThreshold)
                            }
                        }
                    }
                    if model.hasImageParams {
                        Section("Orientação") {
                            Toggle("Espelhar (horizontal)", isOn: $model.mirror)
                            Toggle("Inverter (vertical)", isOn: $model.flip)
                        }
                        Section("Exposição") {
                            Toggle("Compensação de contraluz (BLC)", isOn: $model.backlight)
                            Toggle("Anti-cintilação", isOn: $model.antiFlicker)
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

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 160, alignment: .leading)
            Slider(value: value, in: 0 ... 100, step: 1)
            Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 32, alignment: .trailing)
        }
    }
}

/// Mostra o JSON de configuração lido da câmera, com botão para copiar.
private struct DiagnosticSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnóstico de imagem").font(.headline)
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
