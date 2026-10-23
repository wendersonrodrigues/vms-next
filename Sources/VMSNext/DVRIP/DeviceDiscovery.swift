import Darwin
import Foundation

/// Busca de equipamentos Xiongmai na rede local ("IPV4 pesquisar" do VMS antigo): envia o pedido de
/// busca (código 1530) por broadcast UDP na porta 34569 e junta as respostas (código 1531), que trazem
/// NetWork.NetCommon de cada equipamento: IP, porta, nome, MAC e número de série (o CloudID).
/// Não usa senha nem faz login: só pergunta "quem está aí".
enum DeviceDiscovery {
    struct Found: Identifiable, Hashable {
        let ip: String
        let port: Int
        let name: String
        let mac: String
        let serial: String
        var id: String { mac.isEmpty ? "\(ip):\(port)" : mac }
    }

    static let port: UInt16 = 34569

    /// Procura por `seconds` segundos. Roda fora da thread principal.
    static func search(seconds: Double = 3) async -> [Found] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(seconds: seconds))
            }
        }
    }

    private static func run(seconds: Double) -> [Found] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // As respostas costumam vir por broadcast para a porta 34569, então escutamos nela.
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = port.bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        _ = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        var request = Data([0xFF, 0x00, 0x00, 0x00])
        request.append(contentsOf: [UInt8](repeating: 0, count: 10))
        request.append(contentsOf: [0xFA, 0x05]) // 1530
        request.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr.s_addr = INADDR_BROADCAST

        func send() {
            request.withUnsafeBytes { bytes in
                _ = withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var found: [String: Found] = [:]
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(seconds)
        var nextSend = Date()
        while Date() < deadline {
            if Date() >= nextSend {
                send()
                nextSend = Date().addingTimeInterval(1)
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 20 else { continue }
            let code = UInt16(buffer[14]) | UInt16(buffer[15]) << 8
            guard code == 1531, let device = parse(Data(buffer[20 ..< count])) else { continue }
            found[device.id] = device
        }
        return found.values.sorted { ipValue($0.ip) < ipValue($1.ip) }
    }

    private static func parse(_ body: Data) -> Found? {
        let trimmed = body.prefix { $0 != 0 }
        guard let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any],
              let common = json["NetWork.NetCommon"] as? [String: Any],
              let ip = NetworkModel.hexToIP(common["HostIP"]), ip != "0.0.0.0" else { return nil }
        return Found(ip: ip,
                     port: ConfigValue.int(common["TCPPort"]) ?? 34567,
                     name: common["HostName"] as? String ?? "",
                     mac: common["MAC"] as? String ?? "",
                     serial: common["SN"] as? String ?? "")
    }

    private static func ipValue(_ ip: String) -> UInt32 {
        ip.split(separator: ".").compactMap { UInt32($0) }.reduce(0) { $0 << 8 | $1 }
    }
}
