import Foundation

/// Remonta NAL units H.264 (RFC 6184) e H.265 (RFC 7798) a partir de pacotes RTP
/// e entrega um access unit (quadro) por timestamp.
final class RTPDepacketizer {
    /// NAL units do quadro (sem start code) e se houve perda de pacotes no quadro.
    var onAccessUnit: ((_ nalus: [Data], _ corrupted: Bool) -> Void)?

    private let codec: VideoCodec
    private var nalus: [Data] = []
    private var fragment = Data()
    private var fragmentActive = false
    private var currentTimestamp: UInt32?
    private var lastSequence: UInt16?
    private var lostPackets = false

    init(codec: VideoCodec) {
        self.codec = codec
    }

    func push(_ packet: Data) {
        let p = [UInt8](packet)
        guard p.count >= 12, p[0] >> 6 == 2 else { return }

        let hasPadding = p[0] & 0x20 != 0
        let hasExtension = p[0] & 0x10 != 0
        let csrcCount = Int(p[0] & 0x0F)
        let marker = p[1] & 0x80 != 0
        let sequence = UInt16(p[2]) << 8 | UInt16(p[3])
        let timestamp = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])

        var offset = 12 + csrcCount * 4
        if hasExtension {
            guard p.count >= offset + 4 else { return }
            let words = Int(p[offset + 2]) << 8 | Int(p[offset + 3])
            offset += 4 + words * 4
        }
        var end = p.count
        if hasPadding, let pad = p.last { end -= Int(pad) }
        guard offset < end else { return }

        if let last = lastSequence, sequence != last &+ 1 {
            lostPackets = true
            fragmentActive = false
        }
        lastSequence = sequence

        if let current = currentTimestamp, current != timestamp { flush() }
        currentTimestamp = timestamp

        let payload = Array(p[offset ..< end])
        switch codec {
        case .h264: handleH264(payload)
        case .h265: handleH265(payload)
        }

        if marker { flush() }
    }

    private func flush() {
        if !nalus.isEmpty || lostPackets {
            onAccessUnit?(nalus, lostPackets)
        }
        nalus.removeAll(keepingCapacity: true)
        lostPackets = false
        currentTimestamp = nil
    }

    private func handleH264(_ payload: [UInt8]) {
        guard let first = payload.first else { return }
        switch first & 0x1F {
        case 1 ... 23:
            nalus.append(Data(payload))
        case 24: // STAP-A
            appendAggregated(payload, from: 1)
        case 28: // FU-A
            guard payload.count > 2 else { return }
            let fu = payload[1]
            if fu & 0x80 != 0 {
                fragment = Data([(first & 0xE0) | (fu & 0x1F)])
                fragment.append(contentsOf: payload[2...])
                fragmentActive = true
            } else if fragmentActive {
                fragment.append(contentsOf: payload[2...])
            }
            if fu & 0x40 != 0, fragmentActive {
                nalus.append(fragment)
                fragmentActive = false
            }
        default:
            break
        }
    }

    private func handleH265(_ payload: [UInt8]) {
        guard payload.count >= 2 else { return }
        switch (payload[0] >> 1) & 0x3F {
        case 48: // AP
            appendAggregated(payload, from: 2)
        case 49: // FU
            guard payload.count > 3 else { return }
            let fu = payload[2]
            if fu & 0x80 != 0 {
                fragment = Data([(payload[0] & 0x81) | ((fu & 0x3F) << 1), payload[1]])
                fragment.append(contentsOf: payload[3...])
                fragmentActive = true
            } else if fragmentActive {
                fragment.append(contentsOf: payload[3...])
            }
            if fu & 0x40 != 0, fragmentActive {
                nalus.append(fragment)
                fragmentActive = false
            }
        default:
            nalus.append(Data(payload))
        }
    }

    private func appendAggregated(_ payload: [UInt8], from start: Int) {
        var i = start
        while i + 2 <= payload.count {
            let size = Int(payload[i]) << 8 | Int(payload[i + 1])
            i += 2
            guard size > 0, i + size <= payload.count else { return }
            nalus.append(Data(payload[i ..< i + size]))
            i += size
        }
    }
}
