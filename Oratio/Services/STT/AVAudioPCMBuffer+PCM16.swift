import AVFoundation
import Foundation

extension AVAudioPCMBuffer {
    /// PCM 버퍼를 16kHz 모노 PCM16 (Int16 little-endian) Data로 변환한다.
    func int16Data() -> Data? {
        guard let samples = monoFloatSamples(), !samples.isEmpty else { return nil }

        var pcmData = Data(count: samples.count * MemoryLayout<Int16>.size)
        pcmData.withUnsafeMutableBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for index in samples.indices {
                let sample = max(-1.0, min(1.0, samples[index]))
                int16Ptr[index] = Int16(sample * Float(Int16.max))
            }
        }

        return pcmData
    }

    /// 버퍼를 모노 Float 샘플 배열로 변환한다.
    func monoFloatSamples() -> [Float]? {
        guard let floatData = floatChannelData else { return nil }

        let channelCount = Int(format.channelCount)
        let frameCount = Int(frameLength)
        guard channelCount > 0, frameCount > 0 else { return nil }

        if channelCount == 1 {
            let bufferPointer = UnsafeBufferPointer(start: floatData[0], count: frameCount)
            return Array(bufferPointer)
        }

        var mixed = Array(repeating: Float.zero, count: frameCount)
        let scale = 1.0 / Float(channelCount)
        for channel in 0..<channelCount {
            let channelPointer = floatData[channel]
            for frame in 0..<frameCount {
                mixed[frame] += channelPointer[frame] * scale
            }
        }
        return mixed
    }

    static func makeMonoFloatBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channelData = buffer.floatChannelData?[0] else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
            channelData[index] = samples[index]
        }
        return buffer
    }
}
