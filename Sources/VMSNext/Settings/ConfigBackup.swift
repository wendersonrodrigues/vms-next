import AppKit
import Foundation
import UniformTypeIdentifiers

/// Cópia de segurança das configurações em JSON legível (substitui o Importar/Exportar do VMS antigo,
/// que usa um arquivo binário próprio). Lê todas as configurações que o app conhece, de todos os canais.
enum ConfigBackup {
    /// Configurações do equipamento (sem canal).
    static let deviceNames = [
        "General.General", "General.Location", "General.AutoMaintain", "NetWork.NetNTP", "NetWork.OnlineUpgrade",
        "Storage.StorageNotExist", "Storage.StorageFailure", "Storage.StorageLowSpace",
        "Alarm.NetAbort", "Alarm.NetIPConflict", "Camera.WhiteLight", "ChannelTitle", "fVideo.OSDInfo",
    ]
    /// Configurações por canal (".[n]" no fim).
    static let channelNames = [
        "Camera.Param", "Camera.ParamEx", "AVEnc.VideoColor", "AVEnc.VideoWidget", "Record", "Storage.Snapshot",
        "Snap.SnapConfig", "Detect.MotionDetect", "Detect.HumanDetection", "Detect.FaceDetect", "Detect.FaceDetection", "Detect.BlindDetect", "Detect.LossDetect",
        "Detect.CarShapeDetection",
    ]
    /// Rede: só é restaurada se o usuário pedir (evita trocar o IP sem querer).
    static let networkNames = ["NetWork.NetCommon", "NetWork.NetDHCP", "NetWork.NetDNS"]

    struct Summary {
        let saved: Int
        let skipped: Int
    }

    @MainActor
    static func export(camera: Camera, to url: URL) async throws -> Summary {
        let client = try await DeviceSessions.shared.client(for: camera)
        let info = (try? await client.command(code: 1020, name: "SystemInfo", payload: nil))?["SystemInfo"] as? [String: Any] ?? [:]
        let channels = max(1, (ConfigValue.int(info["DigChannel"]) ?? 0) + (ConfigValue.int(info["VideoInChannel"]) ?? 0))
        let outputs = ConfigValue.int(info["AlarmOutChannel"]) ?? 0

        var names = deviceNames + networkNames
        names += (0 ..< outputs).map { "Alarm.AlarmOut.[\($0)]" }
        for channel in 0 ..< channels {
            names += channelNames.map { "\($0).[\(channel)]" }
        }

        var configs: [String: Any] = [:]
        var skipped = 0
        for name in names {
            if let value = try? await client.getConfig(name), !(value is NSNull) {
                configs[name] = value
            } else {
                skipped += 1
            }
        }
        let document: [String: Any] = [
            "app": "VMS Next",
            "date": DeviceTime.string(Date()),
            "device": camera.group ?? camera.displayName,
            "host": camera.host,
            "model": info["HardWare"] as? String ?? "",
            "firmware": info["SoftWareVersion"] as? String ?? "",
            "configs": configs,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return Summary(saved: configs.count, skipped: skipped)
    }

    struct Restore {
        let applied: Int
        let failed: [String]
    }

    /// Lê o arquivo e devolve (modelo gravado, configurações).
    static func read(_ url: URL) throws -> (model: String, configs: [String: Any]) {
        let data = try Data(contentsOf: url)
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configs = document["configs"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (document["model"] as? String ?? "", configs)
    }

    @MainActor
    static func restore(camera: Camera, configs: [String: Any], includeNetwork: Bool) async throws -> Restore {
        let client = try await DeviceSessions.shared.client(for: camera)
        var applied = 0
        var failed: [String] = []
        for name in configs.keys.sorted() {
            guard includeNetwork || !networkNames.contains(name), let value = configs[name] else { continue }
            do {
                try await client.setConfig(name, value)
                applied += 1
            } catch DVRIPError.device where name == "ChannelTitle" {
                if (try? await client.command(code: 1046, name: name, payload: value)) != nil { applied += 1 } else { failed.append(name) }
            } catch {
                failed.append(name)
            }
        }
        return Restore(applied: applied, failed: failed)
    }

    @MainActor
    static func savePanel(suggested: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = suggested
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
