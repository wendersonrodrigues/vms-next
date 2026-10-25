import Foundation

/// "Rede": NetWork.NetCommon (IP, máscara, gateway, portas), NetWork.NetDHCP e NetWork.NetDNS.
/// Os endereços IPv4 vêm como hex little-endian: "0x0A00A8C0" = 192.168.0.10.
@MainActor
final class NetworkModel: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var diagnosticText: String?
    @Published var confirmingAddressChange = false

    /// Só libera a edição quando o IP decodificado bate com o IP usado para conectar,
    /// garantindo que a leitura do formato está certa antes de gravar algo.
    @Published private(set) var decodingVerified = false
    @Published private(set) var hasDHCP = false
    @Published private(set) var hasDNS = false

    @Published var dhcp = false
    @Published var ip = ""
    @Published var mask = ""
    @Published var gateway = ""
    @Published var dns1 = ""
    @Published var dns2 = ""
    @Published var httpPort = 80
    @Published private(set) var tcpPort = 34567
    @Published private(set) var mac = ""
    @Published private(set) var hostName = ""

    /// Wi-Fi (NetWork.Wifi), como na aba "Wifi" do VMS antigo. Câmeras como a Sala ficam no Wi-Fi e o
    /// IP do cabo (NetCommon) é outro; o app reconhece a interface em uso em vez de bloquear tudo.
    struct WifiInfo {
        var enabled: Bool
        var ssid: String
        var ip: String
        var mask: String
        var gateway: String
        var dhcp: Bool?
    }
    @Published private(set) var wifi: WifiInfo?
    /// A conexão do app com a câmera está passando pelo Wi-Fi.
    var connectedByWifi: Bool { wifi.map { $0.enabled && $0.ip == camera.host } ?? false }

    let camera: Camera
    /// Chamado quando o IP da câmera muda, para atualizar a lista de câmeras do app.
    var onAddressChanged: ((_ old: String, _ new: String) -> Void)?

    private var commonRaw: [String: Any]?
    private var dhcpRaw: [Any]?
    private var dnsRaw: [String: Any]?
    private var wifiRaw: [String: Any]?
    private var loaded: (dhcp: Bool, ip: String) = (false, "")

    private let commonName = "NetWork.NetCommon"
    private let dhcpName = "NetWork.NetDHCP"
    private let dnsName = "NetWork.NetDNS"
    private let wifiName = "NetWork.Wifi"

    init(camera: Camera) {
        self.camera = camera
    }

    /// Mudanças que podem deixar a câmera inacessível pedem confirmação.
    var changesAddress: Bool { dhcp != loaded.dhcp || ip != loaded.ip }

    var validationError: String? {
        if !dhcp {
            for (label, value) in [("IP", ip), (String(localized: "Máscara"), mask), ("Gateway", gateway)] where Self.ipToHex(value) == nil {
                return String(localized: "\(label) inválido: \(value)")
            }
            if !Self.isValidMask(mask) { return String(localized: "Máscara inválida: \(mask)") }
            if !Self.sameSubnet(ip, gateway, mask: mask) { return String(localized: "O gateway não está na mesma rede do IP.") }
        }
        if hasDNS {
            for value in [dns1, dns2] where !value.isEmpty && Self.ipToHex(value) == nil {
                return String(localized: "DNS inválido: \(value)")
            }
        }
        if !(1 ... 65535).contains(httpPort) { return String(localized: "Porta HTTP inválida") }
        return nil
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            commonRaw = ConfigValue.object(in: try await optional(client, commonName))
            dhcpRaw = try await optional(client, dhcpName) as? [Any]
            dnsRaw = ConfigValue.object(in: try await optional(client, dnsName))
            wifiRaw = ConfigValue.object(in: try await optional(client, wifiName))
            read()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply() async {
        if let validationError {
            error = validationError
            return
        }
        saving = true
        error = nil
        notice = nil
        defer { saving = false }

        let oldIP = loaded.ip
        let newIP = ip
        let addressChanged = changesAddress
        do {
            let client = try await DeviceSessions.shared.client(for: camera)

            if var dns = dnsRaw, hasDNS {
                if let hex = Self.ipToHex(dns1.isEmpty ? "0.0.0.0" : dns1) { dns["Address"] = hex }
                if let hex = Self.ipToHex(dns2.isEmpty ? "0.0.0.0" : dns2) { dns["SpareAddress"] = hex }
                try await client.setConfig(dnsName, dns)
                dnsRaw = dns
            }

            // O endereço é gravado por último: depois dele a conexão atual pode cair.
            var common = commonRaw ?? [:]
            ConfigValue.set(&common, "HttpPort", httpPort)
            if !dhcp {
                common["HostIP"] = Self.ipToHex(ip)
                common["Submask"] = Self.ipToHex(mask)
                common["GateWay"] = Self.ipToHex(gateway)
            }

            do {
                if var list = dhcpRaw, hasDHCP, let index = dhcpIndex {
                    if var entry = list[index] as? [String: Any] {
                        entry["Enable"] = dhcp
                        list[index] = entry
                        try await client.setConfig(dhcpName, list)
                        dhcpRaw = list
                    }
                }
                try await client.setConfig(commonName, common)
                commonRaw = common
            } catch let failure as DVRIPError where addressChanged && failure.isDisconnect {
                // A câmera trocou de endereço antes de responder: esperado.
            }

            if addressChanged {
                DeviceSessions.shared.invalidate(account: camera.keychainAccount)
                if !dhcp, newIP != oldIP {
                    onAddressChanged?(oldIP, newIP)
                    notice = String(localized: "Endereço alterado para \(newIP). As câmeras desse IP foram atualizadas no app.")
                } else {
                    notice = String(localized: "DHCP ativado. A câmera vai receber um IP do roteador; atualize o endereço no app quando souber qual é.")
                }
            } else {
                notice = String(localized: "Configurações de rede aplicadas.")
            }
            loaded = (dhcp, ip)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: [
            (1042, commonName), (1042, dhcpName), (1042, dnsName), (1042, wifiName),
        ])
    }

    // MARK: - Leitura

    private var dhcpIndex: Int? {
        guard let list = dhcpRaw else { return nil }
        let entries = list.compactMap { $0 as? [String: Any] }
        return entries.firstIndex { ($0["Interface"] as? String) == "eth0" } ?? (entries.isEmpty ? nil : 0)
    }

    private func read() {
        guard let common = commonRaw else {
            error = String(localized: "Este equipamento não informou a configuração de rede.")
            return
        }
        ip = Self.hexToIP(common["HostIP"]) ?? ""
        mask = Self.hexToIP(common["Submask"]) ?? ""
        gateway = Self.hexToIP(common["GateWay"]) ?? ""
        httpPort = ConfigValue.int(common["HttpPort"]) ?? 80
        tcpPort = ConfigValue.int(common["TCPPort"]) ?? 34567
        mac = common["MAC"] as? String ?? ""
        hostName = common["HostName"] as? String ?? ""

        if let index = dhcpIndex, let entry = dhcpRaw?[index] as? [String: Any] {
            hasDHCP = true
            dhcp = (entry["Enable"] as? Bool) ?? (ConfigValue.int(entry["Enable"]) == 1)
        }
        if let dns = dnsRaw {
            hasDNS = true
            dns1 = Self.hexToIP(dns["Address"]).flatMap { $0 == "0.0.0.0" ? nil : $0 } ?? ""
            dns2 = Self.hexToIP(dns["SpareAddress"]).flatMap { $0 == "0.0.0.0" ? nil : $0 } ?? ""
        }

        if let raw = wifiRaw {
            let wifiDHCP = (dhcpRaw?.compactMap { $0 as? [String: Any] }.first { ($0["Interface"] as? String)?.hasPrefix("wlan") == true })
                .map { ($0["Enable"] as? Bool) ?? (ConfigValue.int($0["Enable"]) == 1) }
            wifi = WifiInfo(enabled: (raw["Enable"] as? Bool) ?? (ConfigValue.int(raw["Enable"]) == 1),
                            ssid: raw["SSID"] as? String ?? "",
                            ip: Self.hexToIP(raw["HostIP"]) ?? "",
                            mask: Self.hexToIP(raw["Submask"]) ?? "",
                            gateway: Self.hexToIP(raw["GateWay"]) ?? "",
                            dhcp: wifiDHCP)
        } else {
            wifi = nil
        }

        loaded = (dhcp, ip)
        // O formato dos endereços está confirmado se o IP do cabo ou o do Wi-Fi for o usado pelo app.
        // Pelo Wi-Fi, mexer no IP do cabo não derruba a conexão atual.
        decodingVerified = ip == camera.host || connectedByWifi
        if !decodingVerified {
            error = String(localized: "O IP lido (\(ip.isEmpty ? ")vazioString(localized: " : ip)) não bate com o endereço usado (\(camera.host)). A edição fica bloqueada por segurança; use \"Diagnóstico…\" e me envie o resultado.")
        }
    }

    private func optional(_ client: DVRIPClient, _ name: String) async throws -> Any? {
        do {
            return try await client.getConfig(name)
        } catch DVRIPError.device, DVRIPError.invalidResponse {
            return nil
        }
    }

    // MARK: - Endereços IPv4

    nonisolated static func hexToIP(_ value: Any?) -> String? {
        guard let text = value as? String, text.lowercased().hasPrefix("0x"),
              let v = UInt32(text.dropFirst(2), radix: 16) else { return nil }
        return [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24].map(String.init).joined(separator: ".")
    }

    static func ipToHex(_ ip: String) -> String? {
        guard let v = ipValue(ip) else { return nil }
        let b = [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]
        return String(format: "0x%08X", b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24)
    }

    /// Valor numérico em ordem de rede (192.168.0.10 → 0xC0A8000A).
    private static func ipValue(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    private static func isValidMask(_ mask: String) -> Bool {
        guard let v = ipValue(mask), v != 0 else { return false }
        return (~v &+ 1) & ~v == 0 // uns contíguos seguidos de zeros
    }

    private static func sameSubnet(_ a: String, _ b: String, mask: String) -> Bool {
        guard let x = ipValue(a), let y = ipValue(b), let m = ipValue(mask) else { return false }
        return x & m == y & m
    }
}
