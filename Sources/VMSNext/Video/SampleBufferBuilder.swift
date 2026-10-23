import CoreMedia
import Foundation

/// Converte access units (NAL units sem start code) em CMSampleBuffers AVCC/HVCC,
/// prontos para o AVSampleBufferDisplayLayer decodificar via VideoToolbox.
final class SampleBufferBuilder {
    private let codec: VideoCodec
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true

    init(track: SDPVideoTrack) {
        codec = track.codec
        for nal in track.parameterSets { _ = absorbParameterSet(nal) }
    }

    /// Sem `timing`, o quadro é marcado para exibir imediatamente (ao vivo/reprodução);
    /// com `timing`, leva o tempo de apresentação (gravação em arquivo).
    func makeSampleBuffer(nalus: [Data], corrupted: Bool, timing: CMSampleTimingInfo? = nil) -> CMSampleBuffer? {
        if corrupted {
            waitingForKeyframe = true
            return nil
        }

        var frame: [Data] = []
        var isKeyframe = false
        var parametersChanged = false

        for nal in nalus where !nal.isEmpty {
            if absorbParameterSet(nal) {
                parametersChanged = true
                continue
            }
            switch codec {
            case .h264:
                let type = nal[nal.startIndex] & 0x1F
                if type == 7 || type == 8 || type == 9 { continue } // SPS/PPS repetidos, AUD
                if type == 5 { isKeyframe = true }
            case .h265:
                let type = (nal[nal.startIndex] >> 1) & 0x3F
                if (32 ... 35).contains(type) { continue } // VPS/SPS/PPS repetidos, AUD
                if (16 ... 21).contains(type) { isKeyframe = true }
            }
            frame.append(nal)
        }

        if parametersChanged || format == nil { rebuildFormat() }
        guard let format, !frame.isEmpty else { return nil }

        if waitingForKeyframe {
            guard isKeyframe else { return nil }
            waitingForKeyframe = false
        }

        var bytes = Data()
        for nal in frame {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(nal)
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = bytes.count
        var timingEntry = timing ?? CMSampleTimingInfo()
        let created = withUnsafePointer(to: &timingEntry) { timingPointer in
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: timing == nil ? 0 : 1,
                sampleTimingArray: timing == nil ? nil : timingPointer,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
            )
        }
        guard created == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0
        {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if timing == nil { set(dict, kCMSampleAttachmentKey_DisplayImmediately, true) }
            set(dict, kCMSampleAttachmentKey_NotSync, !isKeyframe)
        }
        return sample
    }

    /// Guarda VPS/SPS/PPS. Retorna true se a NAL era um parameter set novo.
    private func absorbParameterSet(_ nal: Data) -> Bool {
        guard let first = nal.first else { return false }
        switch codec {
        case .h264:
            switch first & 0x1F {
            case 7: return replace(&sps, with: nal)
            case 8: return replace(&pps, with: nal)
            default: return false
            }
        case .h265:
            switch (first >> 1) & 0x3F {
            case 32: return replace(&vps, with: nal)
            case 33: return replace(&sps, with: nal)
            case 34: return replace(&pps, with: nal)
            default: return false
            }
        }
    }

    private func replace(_ slot: inout Data?, with nal: Data) -> Bool {
        guard slot != nal else { return false }
        slot = nal
        return true
    }

    private func rebuildFormat() {
        let sets: [Data]
        switch codec {
        case .h264:
            guard let sps, let pps else { return }
            sets = [sps, pps]
        case .h265:
            guard let vps, let sps, let pps else { return }
            sets = [vps, sps, pps]
        }

        let buffers = sets.map { [UInt8]($0) }
        let sizes = buffers.map(\.count)
        var description: CMFormatDescription?
        let status: OSStatus = withPointers(buffers) { pointers in
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description
                )
            case .h265:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description
                )
            }
        }
        if status == noErr, let description {
            format = description
            waitingForKeyframe = true
        }
    }

    private func withPointers<R>(_ buffers: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        func recurse(_ index: Int) -> R {
            if index == buffers.count { return body(pointers) }
            return buffers[index].withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress!)
                return recurse(index + 1)
            }
        }
        return recurse(0)
    }

    private func set(_ dict: CFMutableDictionary, _ key: CFString, _ value: Bool) {
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value ? kCFBooleanTrue : kCFBooleanFalse).toOpaque()
        )
    }
}
