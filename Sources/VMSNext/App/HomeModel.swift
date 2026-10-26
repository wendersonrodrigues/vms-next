import AppKit
import CoreImage
import Foundation

/// Dados da tela Início: estado de cada equipamento, discos (e o que fazem quando enchem) e clima.
@MainActor
final class HomeModel: ObservableObject {
    struct Device: Identifiable {
        let id: String
        let name: String
        let address: String
        let isRecorder: Bool
        let channels: Int
        let camera: Camera
        var online: Bool?
        var error: String?
        var totalMB = 0
        var freeMB = 0
        /// General.General.OverWrite: true = gravação cíclica (apaga as mais antigas), false = para de gravar.
        var overwrite: Bool?
    }

    struct Weather {
        let city: String
        let temperature: Double
        let code: Int
        let isDay: Bool
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var checking = false
    @Published var city: String {
        didSet { UserDefaults.standard.set(city, forKey: "home.city") }
    }
    @Published private(set) var weather: Weather?
    @Published private(set) var weatherError: String?

    init() {
        city = UserDefaults.standard.string(forKey: "home.city") ?? ""
    }

    var onlineCount: Int { devices.filter { $0.online == true }.count }
    var totalMB: Int { devices.reduce(0) { $0 + $1.totalMB } }
    var freeMB: Int { devices.reduce(0) { $0 + $1.freeMB } }

    // MARK: - Equipamentos

    /// Um item por equipamento físico: câmeras avulsas (por IP e porta) e NVRs.
    func refresh(store: CameraStore) async {
        var seen = Set<String>()
        var list: [Device] = []
        for item in store.topLevel {
            switch item {
            case let .camera(id):
                guard let camera = store.cameras.first(where: { $0.id == id }),
                      seen.insert("\(camera.host):\(camera.dvripPort)").inserted else { continue }
                list.append(Device(id: camera.id.uuidString, name: camera.name, address: "\(camera.host):\(camera.dvripPort)",
                                   isRecorder: false, channels: 1, camera: camera))
            case let .group(name):
                let channels = store.channels(in: name)
                guard let first = channels.first, seen.insert("\(first.host):\(first.dvripPort)").inserted else { continue }
                list.append(Device(id: "group-\(name)", name: name, address: "\(first.host):\(first.dvripPort)",
                                   isRecorder: true, channels: channels.count, camera: first))
            }
        }
        devices = list
        checking = true
        await withTaskGroup(of: (Int, Device).self) { group in
            for (index, device) in list.enumerated() {
                group.addTask { @MainActor in (index, await Self.check(device, store: store)) }
            }
            for await (index, device) in group where index < devices.count {
                devices[index] = device
            }
        }
        checking = false
    }

    private static func check(_ device: Device, store: CameraStore) async -> Device {
        var device = device
        guard store.password(for: device.camera) != nil else {
            device.online = false
            device.error = String(localized: "Senha não definida")
            return device
        }
        do {
            let client = try await DeviceSessions.shared.client(for: device.camera)
            device.online = true
            if let response = try? await client.command(code: 1020, name: "StorageInfo", payload: nil) {
                let partitions = DiskModel.parse(response["StorageInfo"])
                device.totalMB = partitions.reduce(0) { $0 + $1.totalMB }
                device.freeMB = partitions.reduce(0) { $0 + $1.freeMB }
            }
            if let general = ConfigValue.object(in: try? await client.getConfig("General.General")),
               let mode = general["OverWrite"] as? String {
                device.overwrite = mode == "OverWrite"
            }
        } catch {
            device.online = false
            device.error = error.localizedDescription
        }
        return device
    }

    // MARK: - Clima (Open-Meteo, sem cadastro)

    func loadWeather() async {
        let name = city.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            weather = nil
            return
        }
        weatherError = nil
        do {
            var search = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            search.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "1"), .init(name: "language", value: "pt")]
            let (placeData, _) = try await URLSession.shared.data(from: search.url!)
            guard let place = (try JSONSerialization.jsonObject(with: placeData) as? [String: Any])?["results"] as? [[String: Any]],
                  let first = place.first, let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else {
                weatherError = String(localized: "Cidade não encontrada.")
                return
            }
            var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            forecast.queryItems = [.init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
                                   .init(name: "current", value: "temperature_2m,weather_code,is_day")]
            let (data, _) = try await URLSession.shared.data(from: forecast.url!)
            guard let current = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["current"] as? [String: Any],
                  let temperature = current["temperature_2m"] as? Double else {
                weatherError = String(localized: "Clima indisponível agora.")
                return
            }
            weather = Weather(city: first["name"] as? String ?? name, temperature: temperature,
                              code: current["weather_code"] as? Int ?? 0, isDay: (current["is_day"] as? Int ?? 1) == 1)
        } catch {
            weatherError = String(localized: "Sem internet para buscar o clima.")
        }
    }

    /// Código WMO do clima → descrição e ícone.
    static func describe(_ weather: Weather) -> (text: String, icon: String) {
        switch weather.code {
        case 0: return (String(localized: "Céu limpo"), weather.isDay ? "sun.max.fill" : "moon.stars.fill")
        case 1, 2: return (String(localized: "Parcialmente nublado"), weather.isDay ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: return ("Nublado", "cloud.fill")
        case 45, 48: return ("Neblina", "cloud.fog.fill")
        case 51 ... 57: return ("Garoa", "cloud.drizzle.fill")
        case 61 ... 67, 80 ... 82: return ("Chuva", "cloud.rain.fill")
        case 71 ... 77, 85, 86: return ("Neve", "cloud.snow.fill")
        case 95 ... 99: return ("Tempestade", "cloud.bolt.rain.fill")
        default: return ("—", "thermometer.medium")
        }
    }
}
