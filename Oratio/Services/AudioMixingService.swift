import AVFoundation
import Foundation

/// 시스템 오디오 + 마이크를 단일 PCM 스트림으로 합성하는 실험용 믹서
final class AudioMixingService {
    var onMixedPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let queue = DispatchQueue(
        label: "ing.unlimit.oratio.audioMixingQueue",
        qos: .userInteractive
    )

    private let chunkSize = 320 // 20ms @ 16kHz
    private let micLinearGain: Float
    private let configuredMicDelaySamples: Int

    private var systemQueue = SampleQueue()
    private var micQueue = SampleQueue()
    private var pendingMicDelaySamples: Int

    init(micGainDb: Double, micDelayMs: Double) {
        self.micLinearGain = Float(pow(10.0, micGainDb / 20.0))
        self.configuredMicDelaySamples = max(0, Int((micDelayMs / 1000.0 * AudioCaptureService.sampleRate).rounded()))
        self.pendingMicDelaySamples = self.configuredMicDelaySamples

        print("[AudioMixingService] 실험 믹서 시작 (micGain: \(micGainDb)dB, micDelay: \(micDelayMs)ms)")
    }

    func reset() {
        queue.sync {
            systemQueue.removeAll()
            micQueue.removeAll()
            pendingMicDelaySamples = configuredMicDelaySamples
        }
    }

    func appendSystemAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.monoFloatSamples(), !samples.isEmpty else { return }

        queue.async { [weak self] in
            guard let self else { return }
            self.systemQueue.append(contentsOf: samples)
            self.emitMixedChunksIfNeeded()
        }
    }

    func appendMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        guard var samples = buffer.monoFloatSamples(), !samples.isEmpty else { return }

        if micLinearGain != 1.0 {
            for index in samples.indices {
                samples[index] *= micLinearGain
            }
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.micQueue.append(contentsOf: samples)
            self.emitMixedChunksIfNeeded()
        }
    }

    func flush() {
        queue.sync {
            while systemQueue.count > 0 || micQueue.count > 0 {
                emitMixedChunk(frameCount: chunkSize)
            }
        }
    }

    private func emitMixedChunksIfNeeded() {
        while shouldEmitChunk {
            emitMixedChunk(frameCount: chunkSize)
        }
    }

    private var shouldEmitChunk: Bool {
        systemQueue.count >= chunkSize ||
        micQueue.count >= chunkSize ||
        (systemQueue.count > 0 && pendingMicDelaySamples == 0)
    }

    private func emitMixedChunk(frameCount: Int) {
        let systemSamples = systemQueue.popFirst(frameCount, padWithZeros: true)
        let micSamples = delayedMicSamples(frameCount: frameCount)

        var mixedSamples = Array(repeating: Float.zero, count: frameCount)
        var hasSignal = false

        for index in 0..<frameCount {
            let sample = max(-1.0, min(1.0, systemSamples[index] + micSamples[index]))
            mixedSamples[index] = sample
            if !hasSignal, abs(sample) > 0.000_1 {
                hasSignal = true
            }
        }

        guard hasSignal,
              let outputBuffer = AVAudioPCMBuffer.makeMonoFloatBuffer(
                samples: mixedSamples,
                sampleRate: AudioCaptureService.sampleRate
              ) else {
            return
        }

        onMixedPCMBuffer?(outputBuffer)
    }

    private func delayedMicSamples(frameCount: Int) -> [Float] {
        var output = Array(repeating: Float.zero, count: frameCount)
        var writeIndex = 0

        if pendingMicDelaySamples > 0 {
            let delayedFrames = min(frameCount, pendingMicDelaySamples)
            pendingMicDelaySamples -= delayedFrames
            writeIndex += delayedFrames
        }

        if writeIndex < frameCount {
            let takeCount = min(frameCount - writeIndex, micQueue.count)
            if takeCount > 0 {
                let availableSamples = micQueue.popFirst(takeCount, padWithZeros: false)
                for (offset, sample) in availableSamples.enumerated() {
                    output[writeIndex + offset] = sample
                }
            }
        }

        return output
    }
}

private struct SampleQueue {
    private var storage: [Float] = []
    private var headIndex: Int = 0

    var count: Int {
        storage.count - headIndex
    }

    mutating func append(contentsOf newSamples: [Float]) {
        storage.append(contentsOf: newSamples)
    }

    mutating func popFirst(_ count: Int, padWithZeros: Bool) -> [Float] {
        let actualCount = min(count, self.count)
        let start = headIndex
        let end = headIndex + actualCount
        let result = Array(storage[start..<end])
        headIndex = end
        compactIfNeeded()

        guard padWithZeros, actualCount < count else {
            return result
        }

        return result + Array(repeating: Float.zero, count: count - actualCount)
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
        headIndex = 0
    }

    private mutating func compactIfNeeded() {
        guard headIndex > 0, (headIndex >= 4096 || headIndex * 2 >= storage.count) else { return }
        storage.removeFirst(headIndex)
        headIndex = 0
    }
}
