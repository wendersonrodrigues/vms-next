import AVFoundation
import Foundation

enum AudioCodec {
    /// G.711 lei A (PCMA), o mais comum nas câmeras Xiongmai.
    case alaw
    /// G.711 lei µ (PCMU).
    case ulaw
}

/// Decodificação G.711 (8 bits por amostra → PCM 16 bits).
enum G711 {
    static func decode(_ bytes: Data, codec: AudioCodec) -> [Int16] {
        bytes.map { codec == .alaw ? alaw($0) : ulaw($0) }
    }

    private static func alaw(_ value: UInt8) -> Int16 {
        let a = value ^ 0x55
        var t = Int16(a & 0x0F) << 4
        let segment = (a & 0x70) >> 4
        switch segment {
        case 0: t += 8
        case 1: t += 0x108
        default: t = (t + 0x108) << (segment - 1)
        }
        return a & 0x80 != 0 ? t : -t
    }

    private static func ulaw(_ value: UInt8) -> Int16 {
        let u = ~value
        var t = (Int16(u & 0x0F) << 3) + 0x84
        t <<= Int16((u & 0x70) >> 4)
        return u & 0x80 != 0 ? (0x84 - t) : (t - 0x84)
    }
}

/// Toca PCM 16 bits mono. Só uma câmera toca por vez (AudioFocus).
final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var started = false

    func play(_ samples: [Int16], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if format?.sampleRate != sampleRate {
            stopLocked()
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        }
        guard let format else { return }
        if !started {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do { try engine.start() } catch { return }
            player.play()
            started = true
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = Float(sample) / 32768 }
        player.scheduleBuffer(buffer)
    }

    func stop() {
        lock.lock()
        stopLocked()
        lock.unlock()
    }

    private func stopLocked() {
        guard started else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        started = false
    }
}

/// Qual fonte (câmera ao vivo ou player) está com o som ligado. Ligar uma desliga a anterior.
@MainActor
final class AudioFocus: ObservableObject {
    static let shared = AudioFocus()

    @Published private(set) var owner: UUID?

    func take(_ id: UUID) { owner = id }

    func release(_ id: UUID) {
        if owner == id { owner = nil }
    }

    func toggle(_ id: UUID) {
        owner = owner == id ? nil : id
    }
}
