import AVFoundation
import Foundation

extension AVAudioPCMBuffer {
    /// PCM 버퍼를 16kHz 모노 PCM16 (Int16 little-endian) Data로 변환한다.
    func int16Data() -> Data? {
        guard let floatData = floatChannelData else { return nil }

        let channelCount = Int(format.channelCount)
        let frameCount = Int(frameLength)

        guard channelCount > 0, frameCount > 0 else { return nil }

        var pcmData = Data(count: frameCount * MemoryLayout<Int16>.size)
        pcmData.withUnsafeMutableBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            let floatPtr = floatData[0]
            for index in 0..<frameCount {
                let sample = max(-1.0, min(1.0, floatPtr[index]))
                int16Ptr[index] = Int16(sample * Float(Int16.max))
            }
        }

        return pcmData
    }
}
