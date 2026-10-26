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

    /// "Procurar" da janela "Config. de canal remoto" do VMS antigo: o NVR procura câmeras na rede dele
    /// (OPLocalSearch, código 1634). "TCP" é o NETIP do VMS antigo.
    struct Found: Identifiable {
        let id = UUID()
        let name: String
        let mac: String
        let ip: String
        let port: String
        let extra: String
    }
    static let searchProtocols: [(value: String, label: String)] = [
        ("TCP", "NETIP (Xiongmai)"), ("ONVIF", String(localized: "ONVIF (outras marcas)")), ("RTSP", "RTSP"),
    ]
    @Published var searchProtocol = "TCP"
    @Published private(set) var searching = false
    @Published private(set) var found: [Found]?
    @Published private(set) var searchError: String?
    private var lastSearch: Any?

    // MARK: Editar o canal ("Config. de canal remoto" do VMS antigo)

    /// Câmera ligada num canal do NVR (um "Decoder" de NetWork.RemoteDeviceV3).
    struct ChannelEdit: Identifiable {
        let id = UUID()
        let index: Int
        var enabled: Bool
        var name: String
        var devType: String
        var protocolName: String
        var remoteChannel: Int
        var ip: String
        var port: Int
        var user: String
        /// Vazia = mantém a senha que já está no NVR.
        var password = ""
        var mac: String
        var serial: String
    }
    static let devTypes = ["IPC", "DVR", "HVR"]
    static let channelProtocols: [(value: String, label: String)] = [("TCP", "NETIP"), ("ONVIF", "ONVIF")]

    private(set) var remoteRaw: [Any]?
    @Published var editing: ChannelEdit?
    @Published var confirmingSave = false
    @Published private(set) var saving = false
    @Published private(set) var notice: String?
    var canEdit: Bool { remoteRaw != nil }

    private func decoderIndex(_ channel: [String: Any]) -> Int {
        let decoders = (channel["Decoder"] as? [[String: Any]]) ?? []
        let selected = (ConfigValue.int(channel["SingleConnId"]) ?? 1) - 1
        return decoders.indices.contains(selected) ? selected : 0
    }

    func beginEdit(_ index: Int) {
        guard let list = remoteRaw, list.indices.contains(index), let channel = list[index] as? [String: Any] else { return }
        let decoders = (channel["Decoder"] as? [[String: Any]]) ?? []
        let decoder = decoders.indices.contains(decoderIndex(channel)) ? decoders[decoderIndex(channel)] : [:]
        editing = ChannelEdit(
            index: index, enabled: Self.bool(channel["Enable"]),
            name: Self.text(decoder["ConfName"]), devType: Self.text(decoder["DevType"]).nonEmpty ?? "IPC",
            protocolName: Self.text(decoder["Protocol"]).nonEmpty ?? "TCP",
            remoteChannel: (ConfigValue.int(decoder["Channel"]) ?? 0) + 1,
            ip: Self.text(decoder["IPAddress"]), port: ConfigValue.int(decoder["Port"]) ?? 34567,
            user: Self.text(decoder["UserName"]).nonEmpty ?? "admin",
            mac: Self.text(decoder["MacAddr"]), serial: Self.text(decoder["SerialNo"]))
    }

    /// Preenche o canal com uma câmera achada pelo "Procurar".
    func use(_ item: Found) {
        guard var edit = editing else { return }
        if item.name != "—" { edit.name = item.name }
        if item.ip != "—" { edit.ip = item.ip }
        if let port = Int(item.port) { edit.port = port }
        edit.mac = item.mac == "—" ? "" : item.mac
        edit.serial = item.extra
        edit.protocolName = searchProtocol == "ONVIF" ? "ONVIF" : "TCP"
        editing = edit
    }

    var editError: String? {
        guard let edit = editing else { return nil }
        if edit.name.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Dê um nome ao canal.") }
        if NetworkModel.ipToHex(edit.ip) == nil { return String(localized: "Endereço IP inválido.") }
        if !(1 ... 65535).contains(edit.port) { return String(localized: "Porta inválida.") }
        if edit.user.isEmpty { return String(localized: "Informe o usuário da câmera.") }
        return nil
    }

    /// Grava o canal no NVR (NetWork.RemoteDeviceV3), mantendo o resto da configuração como estava.
    func saveEdit() async {
        guard let edit = editing, editError == nil, var list = remoteRaw, list.indices.contains(edit.index),
              var channel = list[edit.index] as? [String: Any] else { return }
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        var decoders = (channel["Decoder"] as? [[String: Any]]) ?? []
        let position = decoderIndex(channel)
        var decoder = decoders.indices.contains(position) ? decoders[position] : [:]
        decoder["ConfName"] = edit.name.trimmingCharacters(in: .whitespaces)
        decoder["DevType"] = edit.devType
        decoder["Protocol"] = edit.protocolName
        decoder["Channel"] = max(edit.remoteChannel - 1, 0)
        decoder["IPAddress"] = edit.ip
        decoder["Port"] = edit.port
        decoder["UserName"] = edit.user
        if !edit.password.isEmpty { decoder["PassWord"] = edit.password }
        if decoder["MacAddr"] != nil || !edit.mac.isEmpty { decoder["MacAddr"] = edit.mac }
        if decoder["SerialNo"] != nil || !edit.serial.isEmpty { decoder["SerialNo"] = edit.serial }
        if decoders.indices.contains(position) { decoders[position] = decoder } else { decoders.append(decoder) }
        channel["Decoder"] = decoders
        channel["Enable"] = edit.enabled
        list[edit.index] = channel
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            try await client.setConfig("NetWork.RemoteDeviceV3", list)
            AppLog.shared.add(.config, String(format: "Canal D%02d do NVR: %@ (%@)", edit.index + 1, edit.name, edit.ip),
                              device: camera.group ?? camera.host)
            remoteRaw = list
            editing = nil
            notice = String(format: String(localized: "Canal D%02d gravado no NVR."), edit.index + 1)
            readDigital(list, sync: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

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
                // Só o formato V3 (lista de canais com "Decoder") pode ser editado aqui.
                remoteRaw = remote as? [Any]
                if remote == nil { remote = await value(client, "NetWork.RemoteDevice") }
                readDigital(remote, sync: await value(client, "NetWork.DigTimeSyn"))
            default:
                readMode(await value(client, "NetWork.ChnMode"))
            }
            if rows.isEmpty && details.isEmpty {
                error = String(localized: "O NVR não informou estes dados. Use \"Diagnóstico…\" e me envie o resultado.")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        var text = await ConfigDiagnostics.dump(camera: camera, requests: requests)
        if let lastSearch, let data = try? JSONSerialization.data(withJSONObject: ConfigDiagnostics.redacted(lastSearch),
                                                                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
            text += String(localized: "\n== OPLocalSearch (\(searchProtocol))\n") + (String(data: data, encoding: .utf8) ?? "")
        }
        return text
    }

    func search() async {
        searching = true
        searchError = nil
        defer { searching = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let response = try await client.command(code: 1634, name: "OPLocalSearch",
                                                    payload: ["SearchProtocol": searchProtocol], timeout: 40)
            lastSearch = response
            found = Self.devices(in: response).map { item in
                Found(name: Self.text(Self.first(item, ["HostName", "DeviceName", "Name"])).nonEmpty ?? "—",
                      mac: Self.text(Self.first(item, ["MAC", "Mac", "MacAddr"])).nonEmpty ?? "—",
                      ip: NetworkModel.hexToIP(Self.first(item, ["HostIP", "IPAddress", "IP"]))
                        ?? Self.text(Self.first(item, ["HostIP", "IPAddress", "IP"])).nonEmpty ?? "—",
                      port: Self.text(Self.first(item, ["TCPPort", "Port", "OnvifPort"])).nonEmpty ?? "—",
                      extra: Self.text(Self.first(item, ["SN", "SerialNo", "DeviceType", "Type"])))
            }
        } catch {
            searchError = error.localizedDescription
        }
    }

    /// Primeira lista de objetos da resposta (o nome do campo varia entre modelos).
    private static func devices(in value: Any) -> [[String: Any]] {
        if let list = value as? [[String: Any]] { return list }
        if let dict = value as? [String: Any] {
            for key in dict.keys.sorted() where key != "Ret" && key != "SessionID" {
                let inner = devices(in: dict[key] as Any)
                if !inner.isEmpty { return inner }
            }
        }
        return []
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
        columns = [String(localized: "Canal"), String(localized: "Resolução máxima"), String(localized: "Resolução atual"), String(localized: "Conexão")]
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
        columns = [String(localized: "Canal"), String(localized: "Ativo"), String(localized: "Câmera"), String(localized: "Tipo"), String(localized: "Endereço IP"), String(localized: "Canal remoto")]
        let items = (raw as? [Any]) ?? []
        rows = items.enumerated().compactMap { index, item in
            guard let dict = item as? [String: Any] else { return nil }
            let decoders = (dict["Decoder"] as? [[String: Any]]) ?? []
            let selected = (ConfigValue.int(dict["SingleConnId"]) ?? 1) - 1
            let decoder = decoders.indices.contains(selected) ? decoders[selected] : decoders.first
            let enabled = Self.bool(dict["Enable"])
            return Row(cells: [
                String(format: "D%02d", index + 1),
                enabled ? "Sim" : String(localized: "Não"),
                decoder.flatMap { Self.text(Self.first($0, ["ConfName", "Name"])).nonEmpty } ?? (decoder == nil ? String(localized: "Não configurado") : "—"),
                Self.text(decoder?["DevType"]).nonEmpty ?? "—",
                decoder.flatMap { Self.text($0["IPAddress"]).nonEmpty ?? NetworkModel.hexToIP($0["Address"]) } ?? "—",
                decoder.flatMap { ConfigValue.int($0["Channel"]) }.map { String($0 + 1) } ?? "—",
            ], good: enabled && decoder != nil)
        }
        details = []
        if let first = items.first as? [String: Any], let mode = first["ConnType"] as? String {
            details.append((String(localized: "Modo"), mode == "SINGLE" ? String(localized: "Single link (uma câmera por canal)") : mode))
        }
        if let sync {
            details.append((String(localized: "Sincronizar horário"), Self.syncLabel(sync)))
        }
    }

    // MARK: - Modo de canal

    /// NetWork.ChnMode: TotalChnsMode traz, para cada modo, quantas câmeras de cada resolução o NVR aceita
    /// (DigitalCap5MChn = 10, DigitalCap4K = 4…) e quantas reproduções ao mesmo tempo (DigitalCapPlay).
    private func readMode(_ raw: Any?) {
        columns = [String(localized: "Modo"), String(localized: "Câmeras aceitas"), String(localized: "Reproduções ao mesmo tempo"), String(localized: "Em uso")]
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
                inUse ? String(localized: "Em uso") : "—",
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
        case true?: return String(localized: "Conectado")
        case false?:
            let lower = status.lowercased()
            if lower.contains("config") { return String(localized: "Não configurado") }
            return String(localized: "Desconectado")
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
                            Text(model.category == .digitalChannels ? String(localized: "Para trocar a câmera de um canal, use \"Editar canal\" abaixo.") : String(localized: "Só leitura. Para mudar o modo do NVR, use o VMS antigo: uma troca errada para a gravação de todos os canais."))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.category == .digitalChannels {
                        if model.canEdit { editSection }
                        searchSection
                    }
                    if let error = model.error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                }
                Spacer()
                Button("Diagnóstico…") { Task { model.diagnosticText = await model.diagnostic() } }
                    .disabled(model.loading)
                Button("Recarregar") { Task { await model.load() } }
                    .keyboardShortcut("r")
                    .disabled(model.loading)
            }
            .padding(Space.m)
        }
        .task { await model.load() }
        .sheet(item: $model.editing) { _ in editSheet }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }
}

extension RecorderInfoView {
    @ViewBuilder
    var editSection: some View {
        Section {
            HStack {
                Text("Trocar a câmera de um canal ou os dados de acesso dela.")
                Spacer()
                Menu("Editar canal") {
                    ForEach(model.rows.indices, id: \.self) { index in
                        Button(model.rows[index].cells.prefix(3).joined(separator: " · ")) { model.beginEdit(index) }
                    }
                }
                .fixedSize()
            }
        } header: {
            Text("Editar canal (Config. de canal remoto)")
        }
    }

    @ViewBuilder
    var editSheet: some View {
        if let edit = model.editing {
            let binding = Binding(get: { model.editing ?? edit }, set: { model.editing = $0 })
            VStack(alignment: .leading, spacing: 12) {
                Text(String(format: String(localized: "Canal D%02d do NVR"), edit.index + 1)).font(.headline)
                Form {
                    Toggle("Canal ativo (Habilitar)", isOn: binding.enabled)
                    TextField("Nome (Nome cfg)", text: binding.name)
                    Picker("Tipo de dispositivo", selection: binding.devType) {
                        ForEach(RecorderInfoModel.devTypes + (RecorderInfoModel.devTypes.contains(edit.devType) ? [] : [edit.devType]), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Protocolo", selection: binding.protocolName) {
                        ForEach(RecorderInfoModel.channelProtocols, id: \.value) { Text($0.label).tag($0.value) }
                        if !RecorderInfoModel.channelProtocols.contains(where: { $0.value == edit.protocolName }) {
                            Text(edit.protocolName).tag(edit.protocolName)
                        }
                    }
                    Stepper("Canal remoto: \(binding.wrappedValue.remoteChannel)", value: binding.remoteChannel, in: 1 ... 64)
                    TextField("Endereço IP", text: binding.ip)
                    TextField("Porta", value: binding.port, format: .number.grouping(.never))
                    TextField("Nome de usuário", text: binding.user)
                    SecureField("Senha (deixe vazio para manter a atual)", text: binding.password)
                    if let found = model.found, !found.isEmpty {
                        Menu("Usar uma câmera encontrada no Procurar") {
                            ForEach(found) { item in
                                Button("\(item.name) · \(item.ip):\(item.port)") { model.use(item) }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                if let error = model.editError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
                HStack {
                    Spacer()
                    Button("Cancelar") { model.editing = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Gravar no NVR") { model.confirmingSave = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.editError != nil || model.saving)
                }
            }
            .padding(Space.xl)
            .frame(width: 480)
            .confirmationDialog(String(format: String(localized: "Gravar o canal D%02d no NVR?"), edit.index + 1), isPresented: $model.confirmingSave) {
                Button("Gravar") { Task { await model.saveEdit() } }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("O NVR passa a buscar o vídeo deste canal no endereço informado. Se os dados estiverem errados, o canal fica sem imagem e sem gravação até ser corrigido.")
            }
        }
    }

    /// Busca de câmeras feita pelo próprio NVR, na rede dele (inclusive nas portas PoE).
    @ViewBuilder
    var searchSection: some View {
        Section {
            HStack {
                Picker("Protocolo", selection: $model.searchProtocol) {
                    ForEach(RecorderInfoModel.searchProtocols, id: \.value) { Text($0.label).tag($0.value) }
                }
                .frame(maxWidth: 320)
                Spacer()
                if model.searching { ProgressView().controlSize(.small) }
                Button("Procurar") { Task { await model.search() } }
                    .disabled(model.searching)
            }
            if let found = model.found {
                if found.isEmpty {
                    Text("Nenhuma câmera encontrada com esse protocolo.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            ForEach([String(localized: "Nome"), "MAC", String(localized: "Endereço IP"), String(localized: "Porta"), String(localized: "Informação")], id: \.self) {
                                Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        ForEach(found) { item in
                            GridRow {
                                Text(item.name)
                                Text(item.mac).monospacedDigit()
                                Text(item.ip).monospacedDigit()
                                Text(item.port).monospacedDigit()
                                Text(item.extra).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if let error = model.searchError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
        } header: {
            Text("Procurar câmeras na rede do NVR (Procurar)")
        } footer: {
            Text("O NVR procura sozinho, inclusive nas portas PoE dele, por isso aparecem endereços que o Mac não enxerga.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Bolinha colorida antes do texto (verde = conectado).
private struct StatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 8)).foregroundStyle(color)
            configuration.title
        }
    }
}
