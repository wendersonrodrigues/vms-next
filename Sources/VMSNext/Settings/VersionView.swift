import SwiftUI

/// "Versão": SystemInfo (código 1020) com modelo, firmware, número de série e tempo ligado.
@MainActor
final class VersionModel: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var rows: [(label: String, value: String)] = []

    let camera: Camera

    /// Campos conhecidos, na ordem em que aparecem; os demais vêm depois com o nome original.
    private static let labels: [(key: String, label: String)] = [
        ("HardWare", "Modelo"),
        ("SoftWareVersion", "Firmware"),
        ("BuildTime", "Data do firmware"),
        ("SerialNo", "Número de série"),
        ("HardWareVersion", "Versão do hardware"),
        ("DeviceRunTime", "Tempo ligado"),
        ("VideoInChannel", "Canais de vídeo (analógicos)"),
        ("DigChannel", "Canais digitais"),
        ("AlarmInChannel", "Entradas de alarme"),
        ("AlarmOutChannel", "Saídas de alarme"),
        ("EncryptVersion", "Versão de criptografia"),
        ("UpdataTime", "Última atualização"),
    ]

    init(camera: Camera) {
        self.camera = camera
    }

    var asText: String {
        "\(camera.name)\n" + rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let response = try await client.command(code: 1020, name: "SystemInfo", payload: nil)
            guard let info = response["SystemInfo"] as? [String: Any] else { throw DVRIPError.invalidResponse }

            var result: [(String, String)] = []
            for (key, label) in Self.labels {
                guard let raw = info[key] else { continue }
                result.append((label, Self.format(key: key, raw)))
            }
            let known = Set(Self.labels.map(\.key))
            for key in info.keys.sorted() where !known.contains(key) {
                result.append((key, Self.format(key: key, info[key] as Any)))
            }
            rows = result
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func format(key: String, _ value: Any) -> String {
        if key == "DeviceRunTime", let minutes = ConfigValue.int(value) {
            let days = minutes / 1440
            let hours = (minutes % 1440) / 60
            return days > 0 ? "\(days) dias e \(hours) h" : "\(hours) h e \(minutes % 60) min"
        }
        switch value {
        case let text as String: return text.isEmpty ? "—" : text
        case let number as NSNumber: return number.stringValue
        default:
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "—"
        }
    }
}

struct VersionView: View {
    @StateObject private var model: VersionModel

    init(camera: Camera) {
        _model = StateObject(wrappedValue: VersionModel(camera: camera))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section("Informações do equipamento") {
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                            LabeledContent(row.label) {
                                Text(row.value).textSelection(.enabled)
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
                Spacer()
                Button("Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.asText, forType: .string)
                }
                .disabled(model.rows.isEmpty)
                Button("Recarregar") { Task { await model.load() } }
                    .disabled(model.loading)
            }
            .padding(12)
        }
        .task { await model.load() }
    }
}
