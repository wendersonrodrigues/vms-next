import SwiftUI

/// Rede Wi-Fi vista pela câmera (WifiAP: SSID, RSSI, Channel, NetType, EncrypType, Auth).
struct WiFiNetwork: Identifiable, Hashable {
    let ssid: String
    let signal: Int
    let channel: Int
    let netType: String
    let encryption: String
    let auth: String
    var id: String { ssid }

    /// Rede que o próprio NVR cria para as câmeras Wi-Fi dele (WIFINVR…/WIFIBRG…): não é a internet de casa.
    var isRecorderNetwork: Bool { ssid.hasPrefix("WIFINVR") || ssid.hasPrefix("WIFIBRG") }

    /// Rede aberta (sem senha).
    var isOpen: Bool {
        let auth = auth.uppercased(), encryption = encryption.uppercased()
        return auth == "OPEN" && (encryption == "NONE" || encryption.isEmpty)
    }

    /// Força do sinal em 0…3 barras. Algumas câmeras mandam dBm (negativo), outras porcentagem.
    var bars: Int {
        let percent = signal < 0 ? min(max((signal + 100) * 2, 0), 100) : min(signal, 100)
        return percent >= 70 ? 3 : percent >= 45 ? 2 : percent >= 20 ? 1 : 0
    }
}

/// Wi-Fi da câmera: rede atual, procurar redes (WifiAP, como o "Procurar" do VMS antigo) e trocar de rede.
/// Trocar é arriscado: com a senha errada a câmera sai da rede. Por isso o app confere a senha, avisa quando
/// a conexão com a câmera é pelo próprio Wi-Fi e, depois de trocar, procura a câmera na rede pelo número de
/// série para achar o IP novo.
@MainActor
final class WiFiModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case switching
        /// Esperando a câmera aparecer na rede de novo (segundos que faltam).
        case waiting(Int)
        case done(String)
        case failed(String)
    }

    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentSSID: String?
    /// A câmera mandou a configuração de Wi-Fi (sem ela, a "rede atual" fica como não informada).
    @Published private(set) var configLoaded = false
    @Published private(set) var enabled = false
    /// Ligar/desligar o Wi-Fi e o DHCP dele (como o "Habilitar" e o "DHCP" da aba Wifi do VMS antigo).
    @Published var wantEnabled = false
    @Published private(set) var dhcp: Bool?
    @Published var wantDHCP = false
    @Published private(set) var applying = false
    @Published private(set) var notice: String?
    private var dhcpRaw: [Any]?
    @Published private(set) var wifiIP: String?
    @Published private(set) var wifiMask: String?
    @Published private(set) var wifiGateway: String?
    @Published private(set) var networks: [WiFiNetwork] = []
    @Published var chosen: WiFiNetwork?
    @Published var password = ""
    @Published var showPassword = false
    @Published var understoodRisk = false
    /// Achou a câmera com outro IP depois da troca.
    @Published private(set) var newIP: String?
    @Published var diagnosticText: String?

    let camera: Camera
    private var raw: Any?
    private var serial: String?

    init(camera: Camera) { self.camera = camera }

    /// A câmera está na rede Wi-Fi que o NVR cria (WIFINVR…/WIFIBRG…): é assim que o NVR recebe o vídeo dela.
    var onRecorderNetwork: Bool {
        guard let ssid = currentSSID else { return false }
        return ssid.hasPrefix("WIFINVR") || ssid.hasPrefix("WIFIBRG")
    }

    /// O app fala com a câmera pelo IP do Wi-Fi dela: trocar de rede corta esta conexão.
    var connectedOverWiFi: Bool { wifiIP != nil && wifiIP == camera.host }

    private var dhcpEntry: Int? {
        dhcpRaw?.firstIndex { (($0 as? [String: Any])?["Interface"] as? String)?.hasPrefix("wlan") == true }
    }

    var hasChanges: Bool { configLoaded && (wantEnabled != enabled || (dhcp != nil && wantDHCP != dhcp)) }

    /// Desligar o Wi-Fi pelo próprio Wi-Fi cortaria a única ligação com a câmera.
    var applyProblem: String? {
        if connectedOverWiFi, !wantEnabled, enabled {
            return String(localized: "O VMS Next está falando com a câmera pelo Wi-Fi: desligue o Wi-Fi depois de ligar a câmera no cabo.")
        }
        return nil
    }

    /// Grava o Wi-Fi ligado/desligado (NetWork.Wifi) e o DHCP dele (NetWork.NetDHCP), lendo e devolvendo.
    func apply() async {
        guard hasChanges, applyProblem == nil else { return }
        applying = true
        notice = nil
        error = nil
        defer { applying = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            if wantEnabled != enabled, let raw, var config = ConfigValue.object(in: raw) {
                config["Enable"] = wantEnabled
                let updated = ConfigValue.replacingObject(in: raw, with: config)
                try await client.setConfig("NetWork.Wifi", updated)
                self.raw = updated
                enabled = wantEnabled
                AppLog.shared.add(.config, wantEnabled ? "Wi-Fi ligado" : "Wi-Fi desligado", device: camera.displayName)
            }
            if let dhcp, wantDHCP != dhcp, var list = dhcpRaw, let index = dhcpEntry, var entry = list[index] as? [String: Any] {
                entry["Enable"] = entry["Enable"] is Bool ? wantDHCP as Any : (wantDHCP ? 1 : 0) as Any
                list[index] = entry
                try await client.setConfig("NetWork.NetDHCP", list)
                dhcpRaw = list
                self.dhcp = wantDHCP
            }
            notice = String(localized: "Wi-Fi aplicado.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    var passwordProblem: String? {
        guard let chosen, !chosen.isOpen else { return nil }
        if password.count < 8 { return String(localized: "A senha do Wi-Fi tem pelo menos 8 caracteres.") }
        if password.count > 63 { return String(localized: "A senha do Wi-Fi tem no máximo 63 caracteres.") }
        return nil
    }

    var canSwitch: Bool {
        chosen != nil && passwordProblem == nil && (!connectedOverWiFi || understoodRisk) && phase != .switching
    }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            guard let value = try? await client.getConfig("NetWork.Wifi") else {
                // Câmeras sem módulo Wi-Fi ativo (ou só com cabo) respondem sem a configuração.
                error = String(localized: "A câmera não mandou a configuração de Wi-Fi: ela pode estar só no cabo ou sem o Wi-Fi ativo. Procurar redes ainda funciona, mas não dá para trocar.")
                return
            }
            raw = value
            configLoaded = true
            let config = ConfigValue.object(in: value) ?? [:]
            enabled = (config["Enable"] as? Bool) ?? (ConfigValue.int(config["Enable"]) == 1)
            let ssid = config["SSID"] as? String ?? ""
            currentSSID = ssid.isEmpty ? nil : ssid
            let ip = NetworkModel.hexToIP(config["HostIP"])
            wifiIP = ip == "0.0.0.0" ? nil : ip
            wifiMask = NetworkModel.hexToIP(config["Submask"]).flatMap { $0 == "0.0.0.0" ? nil : $0 }
            wifiGateway = NetworkModel.hexToIP(config["GateWay"]).flatMap { $0 == "0.0.0.0" ? nil : $0 }
            wantEnabled = enabled
            // DHCP do Wi-Fi: a entrada "wlan…" do NetWork.NetDHCP (a do cabo é a "eth0").
            dhcpRaw = try? await client.getConfig("NetWork.NetDHCP") as? [Any]
            if let entry = dhcpEntry.map({ dhcpRaw?[$0] as? [String: Any] }) ?? nil {
                dhcp = (entry["Enable"] as? Bool) ?? (ConfigValue.int(entry["Enable"]) == 1)
                wantDHCP = dhcp ?? false
            } else {
                dhcp = nil
            }
            if let common = ConfigValue.object(in: try? await client.getConfig("NetWork.NetCommon")) {
                serial = common["SN"] as? String
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Procura as redes que a câmera enxerga (pode levar alguns segundos).
    func scan() async {
        phase = .scanning
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            var found: [WiFiNetwork] = []
            // Câmeras com AsyncGetWifiAP respondem a primeira vez vazio enquanto procuram: tenta de novo.
            for attempt in 0 ..< 3 where found.isEmpty {
                if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
                let response = try? await client.command(code: 1020, name: "WifiAP", payload: nil, timeout: 15)
                found = Self.parse(response?["WifiAP"])
            }
            var seen = Set<String>()
            // Uma linha por nome (redes com vários pontos de acesso aparecem várias vezes): fica a de sinal mais forte.
            networks = found.sorted { $0.signal > $1.signal }.filter { !$0.ssid.isEmpty && seen.insert($0.ssid).inserted }
            phase = networks.isEmpty ? .failed(String(localized: "A câmera não encontrou redes Wi-Fi (ou não respondeu à busca).")) : .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static func parse(_ value: Any?) -> [WiFiNetwork] {
        let list = ((value as? [String: Any])?["WifiAP"] as? [[String: Any]]) ?? (value as? [[String: Any]]) ?? []
        return list.map { item in
            // "nRSSI" é o sinal em dBm; "RSSI" vem como texto ("Excellent", "Low"…) nas câmeras novas.
            WiFiNetwork(ssid: item["SSID"] as? String ?? "", signal: ConfigValue.int(item["nRSSI"]) ?? ConfigValue.int(item["RSSI"]) ?? -100,
                        channel: ConfigValue.int(item["Channel"]) ?? 0, netType: item["NetType"] as? String ?? "Infra",
                        encryption: item["EncrypType"] as? String ?? "", auth: item["Auth"] as? String ?? "")
        }
    }

    func choose(_ network: WiFiNetwork) {
        chosen = network
        password = ""
        showPassword = false
        understoodRisk = false
    }

    /// Grava a rede nova (lendo, alterando e devolvendo NetWork.Wifi) e procura a câmera na rede depois.
    func switchNetwork() async {
        guard let chosen, canSwitch, let raw, var config = ConfigValue.object(in: raw) else {
            if self.raw == nil { phase = .failed(String(localized: "Sem a configuração de Wi-Fi da câmera, não dá para trocar de rede.")) }
            return
        }
        phase = .switching
        config["Enable"] = true
        config["SSID"] = chosen.ssid
        config["Keys"] = chosen.isOpen ? "" : password
        config["Auth"] = chosen.auth
        config["EncrypType"] = chosen.encryption
        config["NetType"] = chosen.netType
        if chosen.channel > 0 { config["Channel"] = chosen.channel }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            try await client.setConfig("NetWork.Wifi", ConfigValue.replacingObject(in: raw, with: config))
            AppLog.shared.add(.config, "Wi-Fi trocado para \(chosen.ssid)", device: camera.displayName)
        } catch {
            // Conectado pelo Wi-Fi, a câmera pode cortar a conexão antes de responder: segue para a busca.
            if !connectedOverWiFi {
                phase = .failed(String(localized: "A câmera não aceitou: \(error.localizedDescription)"))
                return
            }
        }
        self.chosen = nil
        password = ""
        await waitForCamera(ssid: chosen.ssid)
    }

    /// Até 90 s procurando a câmera pelo número de série (a busca da rede local, sem senha).
    private func waitForCamera(ssid: String) async {
        let deadline = Date().addingTimeInterval(90)
        try? await Task.sleep(for: .seconds(8))
        while Date() < deadline {
            phase = .waiting(max(Int(deadline.timeIntervalSinceNow), 0))
            let found = await DeviceDiscovery.search(seconds: 3)
            let mine = found.filter { serial != nil && $0.serial == serial }
            if !mine.isEmpty {
                let ips = mine.map(\.ip)
                if ips.contains(camera.host) {
                    phase = .done(String(localized: "A câmera está na rede \"\(ssid)\" e continua no mesmo endereço."))
                } else {
                    newIP = ips.first
                    phase = .done(String(localized: "A câmera entrou na rede \"\(ssid)\" com o endereço \(ips.joined(separator: ", "))."))
                }
                await load()
                return
            }
        }
        phase = .failed(String(localized: "A câmera não apareceu na rede em 90 s. Se a senha estiver errada, ela volta pelo cabo de rede; no pior caso, segure o botão de reset."))
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: [(1042, "NetWork.Wifi"), (1042, "NetWork.NetDHCP"), (1020, "WifiAP"),
                                                                 (1042, "NetWork.WifiMode")])
    }
}

struct WiFiView: View {
    @StateObject private var model: WiFiModel
    @EnvironmentObject private var store: CameraStore

    init(camera: Camera) {
        _model = StateObject(wrappedValue: WiFiModel(camera: camera))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    currentSection
                    networksSection
                    if let chosen = model.chosen { switchSection(chosen) }
                    statusSection
                    if let error = model.error {
                        Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning) }
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            SettingsFooter(notice: model.notice, busy: model.loading || model.applying,
                           applyDisabled: !model.hasChanges || model.applyProblem != nil,
                           onDiagnostic: { model.diagnosticText = await model.diagnostic() },
                           onReload: { await model.load() },
                           onApply: { Task { await model.apply() } })
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    private var currentSection: some View {
        Section("Rede atual") {
            if model.configLoaded {
                Toggle(isOn: $model.wantEnabled) {
                    FieldLabel(String(localized: "Wi-Fi ligado"), original: "Habilitar",
                               detail: String(localized: "Câmeras ligadas no cabo de rede (RJ-45) podem ficar com o Wi-Fi desligado."))
                }
                if model.dhcp != nil {
                    Toggle(isOn: $model.wantDHCP) {
                        FieldLabel(String(localized: "IP automático no Wi-Fi (DHCP)"), original: "DHCP",
                                   detail: String(localized: "O roteador escolhe o IP do Wi-Fi da câmera. Desligado, ela usa o IP fixo abaixo."))
                    }
                    .disabled(!model.wantEnabled)
                }
                if let problem = model.applyProblem {
                    Text(problem).font(.caption).foregroundStyle(Theme.warning)
                } else if model.onRecorderNetwork, !model.wantEnabled, model.enabled {
                    Text("Se o NVR recebe esta câmera pela rede Wi-Fi dele, ele para de gravá-la com o Wi-Fi desligado. Pelo cabo, nada muda.")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            } else {
                LabeledContent(String(localized: "Wi-Fi")) { Text(String(localized: "Não informado")) }
            }
            LabeledContent(String(localized: "Rede (SSID)")) { Text(model.currentSSID ?? "—").textSelection(.enabled) }
            LabeledContent(String(localized: "IP no Wi-Fi")) { Text(model.wifiIP ?? "—").textSelection(.enabled) }
            if let mask = model.wifiMask { LabeledContent(String(localized: "Máscara")) { Text(mask).textSelection(.enabled) } }
            if let gateway = model.wifiGateway { LabeledContent(String(localized: "Gateway")) { Text(gateway).textSelection(.enabled) } }
            if model.onRecorderNetwork {
                Label("Esta câmera está na rede Wi-Fi do NVR. Se o NVR a cadastrou por essa rede (e não pelo cabo), é por ela que ele recebe e grava o vídeo.", systemImage: "externaldrive.connected.to.line.below")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.connectedOverWiFi {
                Label("O VMS Next está falando com a câmera pelo Wi-Fi dela.", systemImage: "wifi")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var networksSection: some View {
        Section {
            HStack {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label("Procurar redes", systemImage: "magnifyingglass")
                }
                .disabled(model.phase == .scanning || model.phase == .switching)
                if model.phase == .scanning {
                    ProgressView().controlSize(.small)
                    Text("A câmera está procurando…").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(model.networks) { network in
                Button {
                    model.choose(network)
                } label: {
                    HStack(spacing: Space.m) {
                        Image(systemName: "wifi", variableValue: Double(network.bars) / 3)
                            .frame(width: 22)
                        Text(network.ssid)
                        if network.ssid == model.currentSSID {
                            Text("atual").font(.caption2.weight(.semibold))
                                .padding(.horizontal, Space.xs).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accent.opacity(0.15)))
                                .foregroundStyle(Theme.accent)
                        }
                        Spacer()
                        if network.isRecorderNetwork {
                            Text("rede do NVR").font(.caption2).foregroundStyle(.secondary)
                                .help("Rede que o NVR cria para câmeras Wi-Fi ligadas direto nele.")
                        }
                        if !network.isOpen { Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption) }
                        Text(network.channel > 0 ? String(localized: "canal \(network.channel)") : "")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.chosen == network { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(network.ssid), \(network.isOpen ? String(localized: "aberta") : String(localized: "com senha"))")
            }
        } header: {
            Text("Redes que a câmera enxerga")
        } footer: {
            Text("A lista vem da própria câmera: são as redes que chegam até onde ela está.").foregroundStyle(.secondary)
        }
    }

    private func switchSection(_ network: WiFiNetwork) -> some View {
        Section {
            if !network.isOpen {
                HStack {
                    if model.showPassword {
                        TextField(String(localized: "Senha do Wi-Fi"), text: $model.password)
                    } else {
                        SecureField(String(localized: "Senha do Wi-Fi"), text: $model.password)
                    }
                    Button {
                        model.showPassword.toggle()
                    } label: {
                        Image(systemName: model.showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(model.showPassword ? String(localized: "Esconder a senha") : String(localized: "Mostrar a senha"))
                }
                if let problem = model.passwordProblem, !model.password.isEmpty {
                    Text(problem).font(.caption).foregroundStyle(Theme.warning)
                }
            }
            if model.onRecorderNetwork, !network.isRecorderNetwork {
                Label("Se o NVR recebe esta câmera pela rede Wi-Fi dele, ele para de gravá-la ao sair dessa rede. Pelo cabo, nada muda.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
            if model.connectedOverWiFi {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label("Atenção: a conexão com a câmera é por este Wi-Fi", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                    Text("Ao trocar, a conexão cai. Com a senha errada a câmera fica fora da rede até você ligar um cabo de rede nela (ou segurar o reset).")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Entendi, a senha está certa", isOn: $model.understoodRisk)
                }
            }
            HStack {
                Button("Cancelar") { model.chosen = nil }
                Spacer()
                Button {
                    Task { await model.switchNetwork() }
                } label: {
                    Text(String(localized: "Conectar a câmera em \"\(network.ssid)\""))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSwitch)
            }
        } header: {
            Text("Trocar para \"\(network.ssid)\"")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.phase {
        case .switching:
            Section { HStack { ProgressView().controlSize(.small); Text("Gravando a rede nova na câmera…") } }
        case let .waiting(seconds):
            Section {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Procurando a câmera na rede… (\(seconds) s)")
                }
            }
        case let .done(message):
            Section {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                if let ip = model.newIP {
                    Button(String(localized: "Usar o endereço \(ip) nesta câmera")) {
                        var updated = model.camera
                        updated.host = ip
                        store.upsert(updated)
                    }
                }
            }
        case let .failed(message):
            Section { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning) }
        default:
            EmptyView()
        }
    }
}
