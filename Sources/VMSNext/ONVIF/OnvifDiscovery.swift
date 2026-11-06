import Darwin
import Foundation

/// Busca padrão do ONVIF (WS-Discovery): manda um "Probe" por multicast UDP para 239.255.255.250:3702 e junta
/// as respostas ("ProbeMatch"), que trazem o endereço do serviço ONVIF e o nome/modelo de cada câmera.
/// Acha câmeras de qualquer marca que falem ONVIF. Não usa senha.
enum OnvifDiscovery {
    struct Found: Identifiable, Hashable {
        let ip: String
        /// Porta e caminho do serviço ONVIF (do XAddrs).
        let port: Int
        let path: String
        let name: String
        let hardware: String
        var id: String { ip }
    }

    static func search(seconds: Double = 3) async -> [Found] {
        async let probed: [Found] = withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(seconds: seconds))
            }
        }
        async let scanned = scan()
        var byIP = Dictionary((await probed).map { ($0.ip, $0) }, uniquingKeysWith: { first, _ in first })
        for item in await scanned where byIP[item.ip] == nil { byIP[item.ip] = item }
        return byIP.values.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }

    /// Câmeras que não respondem à busca padrão (as Yoosee, por exemplo): pergunta "quem é você" (GetDeviceInformation,
    /// que a maioria responde sem senha) na porta ONVIF 5000 de cada endereço da rede local do Mac.
    static let scanPorts = [5000]

    private static func scan() async -> [Found] {
        let hosts = localHosts()
        guard !hosts.isEmpty else { return [] }
        return await withTaskGroup(of: Found?.self) { group in
            for host in hosts {
                for port in scanPorts {
                    group.addTask { await identify(host: host, port: port) }
                }
            }
            var result: [Found] = []
            for await item in group { if let item { result.append(item) } }
            return result
        }
    }

    private static func identify(host: String, port: Int) async -> Found? {
        guard let url = URL(string: "http://\(host):\(port)/onvif/device_service") else { return nil }
        let client = OnvifClient(deviceURL: url, username: "", password: "")
        guard let xml = try? await client.call(url, body: "<tds:GetDeviceInformation/>", auth: false, timeout: 1.5),
              xml.first("GetDeviceInformationResponse") != nil else { return nil }
        let maker = xml.value("Manufacturer") ?? ""
        let model = xml.value("Model") ?? ""
        return Found(ip: host, port: port, path: "/onvif/device_service", name: "",
                     hardware: [maker, model].filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// Endereços da rede local (até 254 por interface), sem o próprio Mac.
    private static func localHosts() -> [String] {
        var result = Set<String>()
        var mine = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPointer = entry.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var mask = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // Redes grandes: só o /24 do Mac (o resto seria lento demais).
            if mask < 0xFFFF_FF00 { mask = 0xFFFF_FF00 }
            let network = ip & mask
            let broadcast = network | ~mask
            mine.insert(dotted(ip))
            guard broadcast > network + 1 else { continue }
            for value in (network + 1) ..< broadcast { result.insert(dotted(value)) }
        }
        return Array(result.subtracting(mine))
    }

    private static func dotted(_ value: UInt32) -> String {
        "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    private static func probe(types: Bool) -> Data {
        let typesXML = types ? "<d:Types>dn:NetworkVideoTransmitter</d:Types>" : ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" \
        xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">\
        <e:Header><w:MessageID>uuid:\(UUID().uuidString.lowercased())</w:MessageID>\
        <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>\
        <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>\
        <e:Body><d:Probe>\(typesXML)</d:Probe></e:Body></e:Envelope>
        """
        return Data(xml.utf8)
    }

    private static func run(seconds: Double) -> [Found] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(3702).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &target.sin_addr)

        func send(_ data: Data) {
            data.withUnsafeBytes { bytes in
                _ = withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        // Com e sem o tipo: algumas câmeras só respondem a um dos dois.
        send(probe(types: true))
        send(probe(types: false))

        var found: [String: Found] = [:]
        let deadline = Date().addingTimeInterval(seconds)
        var resent = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while Date() < deadline {
            if !resent, deadline.timeIntervalSinceNow < seconds / 2 {
                send(probe(types: true))
                resent = true
            }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { continue }
            var address = from.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN))
            let sender = String(cString: text)
            if let item = parse(Data(buffer[0 ..< count]), sender: sender), found[item.ip] == nil {
                found[item.ip] = item
            }
        }
        return found.values.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }

    private static func parse(_ data: Data, sender: String) -> Found? {
        guard let xml = OnvifXML.parse(data), let match = xml.first("ProbeMatch") else { return nil }
        let addresses = (match.value("XAddrs") ?? "").split(separator: " ").compactMap { URLComponents(string: String($0)) }
        // Prefere o endereço com o IP de quem respondeu (câmeras com duas redes mandam os dois).
        let chosen = addresses.first { $0.host == sender } ?? addresses.first
        let scopes = (match.value("Scopes") ?? "").split(separator: " ").map(String.init)
        func scope(_ key: String) -> String {
            let prefix = "onvif://www.onvif.org/\(key)/"
            return scopes.first { $0.lowercased().hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
                .flatMap { $0.removingPercentEncoding } ?? ""
        }
        return Found(ip: sender, port: chosen?.port ?? 80, path: chosen?.path.isEmpty == false ? chosen!.path : "/onvif/device_service",
                     name: scope("name"), hardware: scope("hardware"))
    }
}
