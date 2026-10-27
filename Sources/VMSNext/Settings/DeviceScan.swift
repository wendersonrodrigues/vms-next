import Foundation

/// Varredura completa de um equipamento: pede todas as configurações que o SDK do VMS antigo conhece
/// (lista tirada do libnetsdk), mais alguns nomes de firmwares mais novos, e mostra as funções ligadas do
/// SystemFunction. Serve para descobrir o que o equipamento tem quando uma tela não aparece. Só leitura.
@MainActor
enum DeviceScan {
    /// Nomes de configuração do libnetsdk.dylib do VMS antigo.
    static let sdkNames: [String] = [
        "AVEnc.ChnDAModeState", "AVEnc.CombineEncode", "AVEnc.CombineEncodeParam", "AVEnc.Encode",
        "AVEnc.EncodeAddBeep", "AVEnc.EncodeEx", "AVEnc.EncodeStaticParam", "AVEnc.EncodeStaticParamV2",
        "AVEnc.H264Ability", "AVEnc.MultiChannelEncode", "AVEnc.SmartH264", "AVEnc.SmartH264V2", "AVEnc.VideoColor",
        "AVEnc.VideoColorCustom", "AVEnc.VideoWidget", "AVEnc.WaterMark", "Ability.DeviceDesc",
        "Ability.DigitalHide", "Ability.DigitalReal", "Ability.EncodePower", "Ability.GUIThemeList",
        "Ability.PreHVRCapMode", "Ability.RecordEnable", "Ability.SerialNo", "Ability.SupportVstd",
        "Ability.VGAResolution", "Alarm.433AlarmDev", "Alarm.AlarmOut", "Alarm.BlurCheck", "Alarm.Duration",
        "Alarm.GSensorAlarm", "Alarm.IPCAlarm", "Alarm.LocalAlarm", "Alarm.LoginFailed", "Alarm.NetAbort",
        "Alarm.NetAlarm", "Alarm.NetIPConflict", "Alarm.PIR", "Alarm.PTZAlarmProtocol", "Alarm.Serial",
        "Alarm.SpeedAlarm", "Analyze.Avd", "Analyze.BallCameraTrackDetect", "Analyze.Cpc", "Analyze.IntelEncode",
        "Analyze.Osc", "Analyze.Pea", "Analyze.PlateDetectWhiteList", "Analyze.Pub", "Camera.CameraSetAwb",
        "Camera.ClearFog", "Camera.FishEye", "Camera.FishLensParam", "Camera.MotorCtrl", "Camera.Param",
        "Camera.ParamEx", "Camera.SpecialNight", "Consumer.AddedAlarmDev", "Consumer.CommDevCfg",
        "Consumer.ConsSensorAlarm", "Custom.BPlat", "Custom.FaceDetectKS", "Custom.FaceFTPUploadKS",
        "Custom.IndicatorLight", "Custom.PgsLeadScreen", "Custom.PgsLightCtrl", "Custom.SHYZUrlLoad",
        "Custom.THXYVerion", "Custom.XMGWFloorInfo", "Custom.XMGWInfo", "Custom.battery", "Custom.sim",
        "Detect.Analyze", "Detect.AnalyzeLink", "Detect.BlindDetect", "Detect.FaceDetect", "Detect.FaceDetection",
        "Detect.HumanDetection", "Detect.HumanDetectionDVR", "Detect.LossDetect", "Detect.MotionDetect",
        "Detect.MotionDetectIPC", "Detect.PIRDetect", "Detect.ParkingLotDetect", "Detect.PlateDetect",
        "Detect.WordDetect", "General.AutoLogin", "General.AutoMaintain", "General.EmailForSendResetCode",
        "General.General", "General.IdlePTZstate", "General.Location", "General.LogStorage", "General.PlateDetect",
        "General.PwdSafety", "General.ResumePtzState", "General.SupportLang", "General.TimingWork",
        "NetUse.DigitalAbility", "NetUse.DigitalEncode", "NetUse.DigitalHumanAbility", "NetUse.EncodeChDisplay",
        "NetWork.AddDecode", "NetWork.AlarmServer", "NetWork.AnjuP2P", "NetWork.AutoConnect", "NetWork.BWenv",
        "NetWork.BaiduCloud", "NetWork.BjlthyCfg", "NetWork.C7Platform", "NetWork.ChnMode", "NetWork.ChnStatus",
        "NetWork.CloudStorage", "NetWork.CoaxialControlArr", "NetWork.DAS", "NetWork.DDNSADDR", "NetWork.DataLink",
        "NetWork.DigManagerShow", "NetWork.DigTimeSyn", "NetWork.FtpAutoUpLoad", "NetWork.GlobalEyes",
        "NetWork.GodEye", "NetWork.HeartBeat", "NetWork.IPAdaptive", "NetWork.IPv6", "NetWork.IntelBrasSpecialInfo",
        "NetWork.KShttpcommunication", "NetWork.KaCong", "NetWork.LimitLoginUsersNum", "NetWork.LocalSdkPlatform",
        "NetWork.MidDAS", "NetWork.MobileWatch", "NetWork.MonitorPlatfrom", "NetWork.MultimediaMsg", "NetWork.Nat",
        "NetWork.Net3G", "NetWork.NetARSP", "NetWork.NetCommon", "NetWork.NetCommonEx", "NetWork.NetConDisconTime",
        "NetWork.NetDDNS", "NetWork.NetDHCP", "NetWork.NetDNS", "NetWork.NetEmail", "NetWork.NetFTP",
        "NetWork.NetIPFilter", "NetWork.NetKeyboard", "NetWork.NetMobile", "NetWork.NetNTP", "NetWork.NetOrder",
        "NetWork.NetPPPoE", "NetWork.NetinfoTranComm", "NetWork.OnlineUpgrade", "NetWork.OnvifPwdCheckout",
        "NetWork.PMS", "NetWork.PRERemoteDevice", "NetWork.ParkingPort", "NetWork.PlanTask", "NetWork.Pos",
        "NetWork.RTMP", "NetWork.RTSP", "NetWork.RemoteDevice", "NetWork.RemoteDeviceV2", "NetWork.RemoteDeviceV3",
        "NetWork.SPVMN", "NetWork.SPVMNnas", "NetWork.SPVSIP", "NetWork.SerialTrans", "NetWork.ShortMsg",
        "NetWork.TUTKIOTC", "NetWork.TUTKRecordTimeSectionName", "NetWork.TranCommData", "NetWork.Upnp",
        "NetWork.UserProgram", "NetWork.VPN", "NetWork.Wifi", "NetWork.WifiMode", "NetWork.XMHeartBeat",
        "OEMcfg.Correspondent", "Simplify.Encode", "Snap.Breviary", "Snap.SnapConfig", "Status.DigitChn",
        "Status.NatInfo", "Status.RecordState", "Status.TitleName", "Storage.Snapshot", "Storage.StorageFailure",
        "Storage.StorageLowSpace", "Storage.StorageNotExist", "Storage.StoragePosition", "System.ExUserMap",
        "System.Time", "System.TimeZone", "Uart.Comm", "Uart.PTZ", "Uart.PTZPattern", "Uart.PTZPreset",
        "Uart.PTZTour", "Uart.RS485", "fVideo.AudioInFormat", "fVideo.AudioSupportType", "fVideo.GUISet",
        "fVideo.LossShowStr", "fVideo.OEMChSeq", "fVideo.OSDInfo", "fVideo.OSDWidget", "fVideo.OsdLogo",
        "fVideo.Play", "fVideo.Spot", "fVideo.TVAdjust", "fVideo.Tour", "fVideo.VideoOut", "fVideo.VideoOutPriority",
        "fVideo.VideoSeque", "fVideo.VideoSignal", "fVideo.VoColorAdjust", "fVideo.Volume", "fVideo.WheelFunction",
    ]

    /// Nomes do SDK do VMS Pro para Windows (V3.1.6.3, 2026) que o SDK do VMS antigo não tem.
    static let vmsProNames = [
        "fVideo.VolumeIn", "fVideo.AudioDeviceVolume", "fVideo.AudioAcquisitionMode", "fVideo.MaxPreviewNum",
        "Detect.AlarmVoicePeriod", "Detect.FireDetection", "Detect.LeavePostDetection", "Detect.CustomerFlow",
        "Detect.VehicleBerthLeaveDetection", "Camera.WhiteLight", "AVEnc.ImageEffect", "AVEnc.MultiLensJoin",
        "Ability.FunctionEnable", "Ability.VoiceTipType", "Ability.LocalVoiceTipType", "Ability.OSDShow",
        "Dev.ElectCapacity", "General.AppBindFlag", "NetWork.GBProType", "System.ProductId", "Uart.PTZControlCmd",
        "PTZ.Flip", "PTZ.Mirror",
    ]

    /// Nomes vistos em firmwares mais novos (palpites: o VMS antigo não conhece).
    static let newerNames = [
        "Detect.FaceRecognition", "Detect.FaceDetectionV2", "Detect.HumanDetectionNVR", "Detect.HumanDetectionNVRNew",
        "Detect.CarShapeDetection", "Detect.TargetDetect", "Detect.SmartDetect", "Detect.IntelligentDetect",
        "Detect.FaceCapture", "Detect.FaceSnap", "Ability.FaceDetect", "NetUse.DigitalFaceAbility", "NetUse.DigitalAIAbility",
    ]

    /// Palavras que fazem a resposta aparecer inteira (o resto só diz que respondeu).
    private static let detailWords = ["face", "human", "detect", "analyze", "ability", "smart", "intell", "target", ".ai", "ped", "volume", "audio", "whitelight", "imageeffect", "multilens", "ptz."]

    /// `onProgress(feito, total)` a cada pedido.
    static func run(camera: Camera, onProgress: @escaping (Int, Int) -> Void) async -> String {
        let channel = camera.channel - 1
        var requests: [String] = []
        for name in sdkNames + vmsProNames + newerNames {
            requests.append(name)
            // Configurações por canal: também com o índice do canal (e do 0, no NVR).
            if name.hasPrefix("Detect.") || name.hasPrefix("Camera.") || name.hasPrefix("NetUse.Digital") || name.hasPrefix("fVideo.Volume") {
                requests.append("\(name).[\(channel)]")
            }
        }
        var output = String(localized: "Varredura completa: \(camera.displayName) · canal \(camera.channel)\n")
        output += String(localized: "Só leitura: nada é alterado no equipamento.\n")

        // Funções ligadas do SystemFunction, e as de rosto/pessoa/IA mesmo desligadas.
        let functions = await DeviceCapabilities.systemFunction(for: camera)
        output += "\n== SystemFunction\n"
        if let functions {
            for group in functions.keys.sorted() {
                guard let flags = functions[group] as? [String: Any] else { continue }
                let on = flags.keys.sorted().filter { isOn(flags[$0]) }
                let interesting = flags.keys.sorted().filter { key in
                    !isOn(flags[key]) && ["face", "human", "ai", "intell", "target", "smart"].contains { key.lowercased().contains($0) }
                }
                output += "\(group): " + (on.isEmpty ? "—" : on.joined(separator: ", ")) + "\n"
                if !interesting.isEmpty { output += String(localized: "  desligadas: \(interesting.joined(separator: ", "))\n") }
            }
        } else {
            output += String(localized: "(o equipamento não informou)\n")
        }

        var answered: [(String, Any)] = []
        var refused: [String] = []
        var client = try? await DeviceSessions.shared.client(for: camera)

        // Capacidades (ABILITY_GET): o que o equipamento diz que suporta, inteiras (são curtas e dizem muito).
        output += String(localized: "\n== Capacidades\n")
        for name in DeviceCapabilities.names where name != "SystemFunction" {
            guard let response = try? await client?.command(code: 1360, name: name, payload: nil, timeout: 4),
                  let value = response[name], !(value is NSNull),
                  let data = try? JSONSerialization.data(withJSONObject: ConfigDiagnostics.redacted(value),
                                                         options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else {
                output += "\(name): " + String(localized: "não informou") + "\n"
                if client?.isClosed == true { client = try? await DeviceSessions.shared.client(for: camera) }
                continue
            }
            output += "-- \(name)\n" + String(decoding: data, as: UTF8.self) + "\n"
        }
        for (index, name) in requests.enumerated() {
            onProgress(index + 1, requests.count)
            if client == nil || client?.isClosed == true { client = try? await DeviceSessions.shared.client(for: camera) }
            guard let client else { refused.append(name + " (sem conexão)"); continue }
            do {
                let response = try await client.command(code: 1042, name: name, payload: nil, timeout: 4)
                if let value = response[name], !(value is NSNull) { answered.append((name, value)) } else { refused.append(name) }
            } catch let DVRIPError.device(code) {
                refused.append("\(name) (\(code))")
            } catch {
                refused.append("\(name) (" + String(localized: "sem resposta") + ")")
            }
        }

        output += String(localized: "\n== Responderam (\(answered.count))\n")
        output += answered.map(\.0).joined(separator: "\n") + "\n"
        output += String(localized: "\n== Recusaram (\(refused.count))\n")
        output += refused.joined(separator: ", ") + "\n"
        for (name, value) in answered where detailWords.contains(where: { name.lowercased().contains($0) }) {
            output += "\n== \(name)\n"
            if let data = try? JSONSerialization.data(withJSONObject: ConfigDiagnostics.redacted(value),
                                                      options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
                output += String(decoding: data, as: UTF8.self) + "\n"
            }
        }
        return output
    }

    private static func isOn(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        return (value as? NSNumber)?.boolValue ?? false
    }
}
