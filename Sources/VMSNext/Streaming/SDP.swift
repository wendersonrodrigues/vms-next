import Foundation

enum VideoCodec {
    case h264
    case h265
}

/// Faixa de vídeo descrita no SDP retornado pelo DESCRIBE.
struct SDPVideoTrack {
    let codec: VideoCodec
    let payloadType: Int
    let control: String
    /// SPS/PPS (H.264) ou VPS/SPS/PPS (H.265) vindos do `a=fmtp`, sem start code.
    let parameterSets: [Data]
}

enum SDPParser {
    static func videoTrack(from text: String) throws -> SDPVideoTrack {
        var inVideo = false
        var payloadType: Int?
        var codecName: String?
        var control = ""
        var fmtp: [String: String] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                if inVideo { break }
                inVideo = line.hasPrefix("m=video")
                if inVideo {
                    let parts = line.split(separator: " ")
                    if parts.count >= 4 { payloadType = Int(parts[3]) }
                }
                continue
            }
            guard inVideo else { continue }

            if line.hasPrefix("a=rtpmap:") {
                let value = line.dropFirst("a=rtpmap:".count)
                let parts = value.split(separator: " ", maxSplits: 1)
                if parts.count == 2, Int(parts[0]) == payloadType {
                    codecName = parts[1].split(separator: "/").first.map { String($0).uppercased() }
                }
            } else if line.hasPrefix("a=control:") {
                control = String(line.dropFirst("a=control:".count))
            } else if line.hasPrefix("a=fmtp:") {
                let value = line.dropFirst("a=fmtp:".count)
                guard let space = value.firstIndex(of: " ") else { continue }
                for pair in value[value.index(after: space)...].split(separator: ";") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { continue }
                    fmtp[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                        kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        guard let payloadType else { throw RTSPError.noVideoTrack }

        let codec: VideoCodec
        var parameterSets: [Data] = []
        switch codecName ?? "" {
        case "H264":
            codec = .h264
            for item in (fmtp["sprop-parameter-sets"] ?? "").split(separator: ",") {
                if let d = Data(base64Encoded: String(item)) { parameterSets.append(d) }
            }
        case "H265", "HEVC":
            codec = .h265
            for key in ["sprop-vps", "sprop-sps", "sprop-pps"] {
                if let v = fmtp[key], let d = Data(base64Encoded: v) { parameterSets.append(d) }
            }
        case let other:
            throw RTSPError.unsupportedCodec(other.isEmpty ? "desconhecido" : other)
        }

        return SDPVideoTrack(codec: codec, payloadType: payloadType, control: control, parameterSets: parameterSets)
    }
}
