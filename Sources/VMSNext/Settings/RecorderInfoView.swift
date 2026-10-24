import SwiftUI

/// Telas do NVR que o VMS antigo mostra em "Avançados": Canal digital (NetWork.RemoteDevice), Modo de canal
/// (NetWork.ChnMode) e Status do canal (NetWork.ChnStatus). Por enquanto só leitura:
/// trocar a câmera de um canal ou o modo do NVR pode derrubar a gravação de todos os canais.
@MainActor
final class RecorderInfoModel: ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        var cells: [String]
        var good: Bool?
    }

    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var diagnosticText: String?
    @Published private(set) var columns: [String] = []
    @Published private(set) var rows: [Row] = []
    /// Linhas "nome: valor" para o que não é tabela (ex.: sincronização de horário, modo atual).
    @Published private(set) var details: [(label: String, value: String)] = []

    let camera: Camera
    let category: SettingsCategory

    init(camera: Camera, category: SettingsCategory) {
        self.camera = camera
        self.category = category
    }

    private var requests: [(UInt16, String)] {
        switch category {
        case .channelStatus: return [(1042, "NetWork.ChnStatus"), (1020, "NetWork.ChnStatus")]
        case .digitalChannels: return [(1042, "NetWork.RemoteDeviceV3"), (1042, "NetWork.RemoteDevice"), (1042, "NetWork.DigTimeSyn")]
        default: return [(1042, "NetWork.ChnMode"), (1042, "AVEnc.ChnDAModeState")]
        }
    }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            switch category {
            case .channelStatus: readStatus(await value(client, "NetWork.ChnStatus", fallbackCode: 1020))
            case .digitalChannels:
                var remote = await value(client, "NetWork.RemoteDeviceV3")
                if remote == nil { remote = await value(client, "NetWork.RemoteDevice") }
                readDigital(remote, sync: await value(client, "NetWork.DigTimeSyn"))
            default:
                readMode(await value(client, "NetWork.ChnMode"))
            }
            if rows.isEmpty && details.isEmpty {
                error = "O NVR não informou estes dados. Use \"Diagnóstico…\" e me envie o resultado."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: requests)
    }

    private func value(_ client: DVRIPClient, _ name: String, fallbackCode: UInt16? = nil) async -> Any? {
        if let config = try? await client.getConfig(name) { return config }
        if let code = fallbackCode, let response = try? await client.command(code: code, name: name, payload: nil) {
            return response[name]
        }
        return nil
    }

    // MARK: - Status do canal

    private func readStatus(_ raw: Any?) {
        columns = ["Canal", "Resolução máxima", "Resolução atual", "Conexão"]
        let items = (raw as? [Any]) ?? []
        rows = items.enumerated().compactMap { index, item in
            guard let dict = item as? [String: Any] else { return nil }
            let status = Self.text(Self.first(dict, ["Status", "ConnectStatus", "State"]))
            // O NVR manda linhas vazias para os canais que ele nem tem (D11…D32): não aparecem.
            if status.isEmpty && Self.text(Self.first(dict, ["MaxRes", "MaxResolution"])).isEmpty { return nil }
            let connected = Self.isConnected(status)
            return Row(cells: [
                Self.text(Self.first(dict, ["ChnName", "ChannelName", "Name"])).nonEmpty ?? String(format: "D%02d", index + 1),
                Self.text(Self.first(dict, ["MaxRes", "MaxResolution"])).nonEmpty ?? "—",
                Self.resolution(Self.text(Self.first(dict, ["CurRes", "CurResolution"]))),
                Self.statusLabel(status),
            ], good: connected)
        }
    }

    // MARK: - Canal digital

    private func readDigital(_ raw: Any?, sync: Any?) {
        columns = ["Canal", "Ativo", "Câmera", "Tipo", "Endereço IP", "Canal remoto"]
        let items = (raw as? [Any]) ?? []
        rows = items.enumerated().compactMap { index, item in
            guard let dict = item as? [String: Any] else { return nil }
            let decoders = (dict["Decoder"] as? [[String: Any]]) ?? []
            let selected = (ConfigValue.int(dict["SingleConnId"]) ?? 1) - 1
            let decoder = decoders.indices.contains(selected) ? decoders[selected] : decoders.first
            let enabled = Self.bool(dict["Enable"])
            return Row(cells: [
                String(format: "D%02d", index + 1),
                enabled ? "Sim" : "Não",
                decoder.flatMap { Self.text(Self.first($0, ["ConfName", "Name"])).nonEmpty } ?? (decoder == nil ? "Não configurado" : "—"),
                Self.text(decoder?["DevType"]).nonEmpty ?? "—",
                decoder.flatMap { Self.text($0["IPAddress"]).nonEmpty ?? NetworkModel.hexToIP($0["Address"]) } ?? "—",
                decoder.flatMap { ConfigValue.int($0["Channel"]) }.map { String($0 + 1) } ?? "—",
            ], good: enabled && decoder != nil)
        }
        details = []
        if let first = items.first as? [String: Any], let mode = first["ConnType"] as? String {
            details.append(("Modo", mode == "SINGLE" ? "Single link (uma câmera por canal)" : mode))
        }
        if let sync {
            details.append(("Sincronizar horário", Self.syncLabel(sync)))
        }
    }

    // MARK: - Modo de canal

    /// NetWork.ChnMode: TotalChnsMode traz, para cada modo, quantas câmeras de cada resolução o NVR aceita
    /// (DigitalCap5MChn = 10, DigitalCap4K = 4…) e quantas reproduções ao mesmo tempo (DigitalCapPlay).
    private func readMode(_ raw: Any?) {
        columns = ["Modo", "Câmeras aceitas", "Reproduções ao mesmo tempo", "Em uso"]
        details = []
        guard let config = raw as? [String: Any], let modes = config["TotalChnsMode"] as? [[String: Any]] else {
            rows = []
            return
        }
        let count = ConfigValue.int(config["TotalChnsModeNum"]) ?? modes.count
        let current = ConfigValue.int(config["CurChnsMode"])
        rows = modes.prefix(count).enumerated().map { index, mode in
            let cameras = mode.keys.sorted().compactMap { key -> String? in
                guard key.hasPrefix("DigitalCap"), !key.hasSuffix("DigiTal"), !key.hasSuffix("Play"),
                      let amount = ConfigValue.int(mode[key]), amount > 0 else { return nil }
                let resolution = key.dropFirst("DigitalCap".count).replacingOccurrences(of: "Chn", with: "")
                return "\(amount) × \(resolution)"
            }
            let inUse = index == current
            return Row(cells: [
                "Modo \(index + 1)",
                cameras.isEmpty ? "—" : cameras.joined(separator: ", "),
                ConfigValue.int(mode["DigitalCapPlay"]).map(String.init) ?? "—",
                inUse ? "Em uso" : "—",
            ], good: inUse)
        }
    }

    // MARK: - Texto

    private static func first(_ dict: [String: Any], _ keys: [String]) -> Any? {
        for key in keys { if let value = dict[key] { return value } }
        return nil
    }

    private static func text(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? Bool) ?? ((ConfigValue.int(value) ?? 0) != 0)
    }

    private static func isConnected(_ status: String) -> Bool? {
        let lower = status.lowercased()
        guard !lower.isEmpty else { return nil }
        return lower.contains("connect") && !lower.contains("dis") && !lower.contains("un") && !lower.contains("no")
    }

    private static func statusLabel(_ status: String) -> String {
        switch isConnected(status) {
        case true?: return "Conectado"
        case false?:
            let lower = status.lowercased()
            if lower.contains("config") { return "Não configurado" }
            return "Desconectado"
        case nil: return status.nonEmpty ?? "—"
        }
    }

    private static func resolution(_ value: String) -> String {
        guard !value.isEmpty else { return "—" }
        // "principal/extra", com 0x0 quando a câmera não informou o vídeo extra.
        return value.split(whereSeparator: { $0 == "/" || $0 == "|" }).map { part in
            part == "0x0" || part.lowercased() == "unknown" ? "Desconhecida" : String(part)
        }.joined(separator: " / ")
    }

    private static func syncLabel(_ value: Any) -> String {
        let raw: String
        let item = (value as? [Any])?.first ?? value
        if let dict = item as? [String: Any] { raw = text(dict["TimeSyn"] ?? dict.values.first) } else { raw = text(item) }
        // Nomes da lista "Sincronizar" do VMS antigo (Aux. Off, Fuso horário, Horário local).
        switch raw {
        case "T&Z": return "Fuso horário (horário e fuso do NVR)"
        case "UTC": return "Fuso horário (UTC)"
        case "Local", "LocalTime": return "Horário local"
        case "Off", "OFF", "Close": return "Desligado (Aux. Off)"
        default: return raw.nonEmpty ?? "—"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct RecorderInfoView: View {
    @StateObject private var model: RecorderInfoModel

    init(camera: Camera, category: SettingsCategory) {
        _model = StateObject(wrappedValue: RecorderInfoModel(camera: camera, category: category))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo do NVR…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if !model.details.isEmpty {
                        Section {
                            ForEach(Array(model.details.enumerated()), id: \.offset) { _, item in
                                LabeledContent(item.label, value: item.value)
                            }
                        }
                    }
                    if !model.rows.isEmpty {
                        Section {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                                GridRow {
                                    ForEach(model.columns, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                                }
                                Divider()
                                ForEach(model.rows) { row in
                                    GridRow {
                                        ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                                            if index == row.cells.count - 1, let good = row.good {
                                                Label(cell, systemImage: "circle.fill")
                                                    .labelStyle(StatusLabelStyle(color: good ? .green : .secondary))
                                            } else {
                                                Text(cell).monospacedDigit()
                                            }
                                        }
                                    }
                                }
                            }
                        } footer: {
                            Text("Só leitura. Para trocar a câmera de um canal ou o modo do NVR, use o VMS antigo: uma troca errada para a gravação de todos os canais.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack {
                Spacer()
                Button("Diagnóstico…") { Task { model.diagnosticText = await model.diagnostic() } }
                    .disabled(model.loading)
                Button("Recarregar") { Task { await model.load() } }
                    .disabled(model.loading)
            }
            .padding(12)
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }
}

/// Bolinha colorida antes do texto (verde = conectado).
private struct StatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(color)
            configuration.title
        }
    }
}
