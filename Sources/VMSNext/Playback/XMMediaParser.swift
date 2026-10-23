import Foundation

/// Separa o fluxo de mídia da Xiongmai em quadros de vídeo. Cada bloco começa com 00 00 01 Fx:
/// - FC: quadro I. Cabeçalho de 16 bytes: tipo, fps, largura/8, altura/8, data/hora (u32), tamanho (u32).
/// - FD: quadro P. Cabeçalho de 8 bytes: tamanho (u32).
/// - FA (áudio): cabeçalho de 8 bytes com tipo (byte 4), taxa (byte 5) e tamanho (u16, bytes 6-7); G.711.
/// - F9 (informações): mesmo cabeçalho; ignorado.
/// O conteúdo dos quadros de vídeo é H.264/H.265 em formato Annex-B.
final class XMMediaParser {
    struct Frame {
        let nalus: [Data]
        let isKeyframe: Bool
        /// Data/hora gravada no quadro I (nil nos quadros P).
        let timestamp: Date?
    }

    private(set) var codec: VideoCodec?
    private(set) var fps: Int = 25
    private(set) var resolution: (width: Int, height: Int)?
    var onFrame: ((Frame) -> Void)?
    /// Áudio G.711 do bloco FA. Tipo 0x0A = lei µ; os demais (0x0E e outros) são tratados como lei A.
    var onAudio: ((_ samples: Data, _ codec: AudioCodec) -> Void)?

    private var buffer: [UInt8] = []

    func push(_ data: Data) {
        buffer.append(contentsOf: data)
        var i = 0
        let n = buffer.count
        while n - i >= 8 {
            guard buffer[i] == 0, buffer[i + 1] == 0, buffer[i + 2] == 1, buffer[i + 3] & 0xF0 == 0xF0 else {
                i += 1
                continue
            }
            switch buffer[i + 3] {
            case 0xFC, 0xFE:
                guard n - i >= 16 else { break }
                let length = le32(i + 12)
                guard n - i >= 16 + length else { break }
                if buffer[i + 5] > 0 { fps = Int(buffer[i + 5]) }
                resolution = (Int(buffer[i + 6]) * 8, Int(buffer[i + 7]) * 8)
                let time = Self.decodeTime(UInt32(le32(i + 8)))
                if buffer[i + 3] == 0xFC {
                    emit(Array(buffer[(i + 16) ..< (i + 16 + length)]), keyframe: true, time: time)
                }
                i += 16 + length
                continue
            case 0xFD:
                let length = le32(i + 4)
                guard n - i >= 8 + length else { break }
                emit(Array(buffer[(i + 8) ..< (i + 8 + length)]), keyframe: false, time: nil)
                i += 8 + length
                continue
            case 0xFA, 0xF9:
                let length = Int(buffer[i + 6]) | Int(buffer[i + 7]) << 8
                guard n - i >= 8 + length else { break }
                if buffer[i + 3] == 0xFA, length > 0, let onAudio {
                    onAudio(Data(buffer[(i + 8) ..< (i + 8 + length)]), buffer[i + 4] == 0x0A ? .ulaw : .alaw)
                }
                i += 8 + length
                continue
            default:
                i += 4
                continue
            }
            break // bloco incompleto: espera mais dados
        }
        if i > 0 { buffer.removeFirst(min(i, buffer.count)) }
    }

    private func emit(_ bytes: [UInt8], keyframe: Bool, time: Date?) {
        let nalus = Self.splitAnnexB(bytes)
        guard !nalus.isEmpty else { return }
        if codec == nil { codec = Self.detectCodec(nalus) }
        onFrame?(Frame(nalus: nalus, isKeyframe: keyframe, timestamp: time))
    }

    private func le32(_ at: Int) -> Int {
        Int(buffer[at]) | Int(buffer[at + 1]) << 8 | Int(buffer[at + 2]) << 16 | Int(buffer[at + 3]) << 24
    }

    /// Divide por start codes (00 00 01 ou 00 00 00 01).
    static func splitAnnexB(_ bytes: [UInt8]) -> [Data] {
        var starts: [(index: Int, length: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, 3)); i += 3; continue
                }
                if i + 4 <= bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }
        var nalus: [Data] = []
        for (k, start) in starts.enumerated() {
            let from = start.index + start.length
            let to = k + 1 < starts.count ? starts[k + 1].index : bytes.count
            if to > from { nalus.append(Data(bytes[from ..< to])) }
        }
        return nalus
    }

    /// H.264 começa com SPS (tipo 7); H.265 com VPS (tipo 32).
    static func detectCodec(_ nalus: [Data]) -> VideoCodec? {
        for nal in nalus {
            guard let b = nal.first else { continue }
            if (b >> 1) & 0x3F == 32 { return .h265 }
            if b & 0x1F == 7 { return .h264 }
        }
        return nil
    }

    /// Data compactada: segundos(6) minutos(6) horas(5) dia(5) mês(4) ano-2000(6), do bit menos significativo.
    static func decodeTime(_ v: UInt32) -> Date? {
        var c = DateComponents()
        c.second = Int(v & 0x3F)
        c.minute = Int((v >> 6) & 0x3F)
        c.hour = Int((v >> 12) & 0x1F)
        c.day = Int((v >> 17) & 0x1F)
        c.month = Int((v >> 22) & 0x0F)
        c.year = 2000 + Int(v >> 26)
        guard (1 ... 12).contains(c.month!), (1 ... 31).contains(c.day!) else { return nil }
        return Calendar.current.date(from: c)
    }
}
