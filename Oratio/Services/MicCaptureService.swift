import Foundation
import AVFoundation
import Combine

/// 마이크 오디오 캡처 서비스
/// AVAudioEngine을 이용하여 마이크 입력을 캡처한다.
/// 캡처된 오디오 버퍼는 콜백을 통해 STT 서비스에 전달된다.
class MicCaptureService: NSObject, ObservableObject {

    // MARK: - Published 상태

    @Published var isCapturing: Bool = false
    @Published var audioLevel: Float = 0.0

    // MARK: - 콜백

    /// AVAudioPCMBuffer 기반 콜백 (16kHz 모노 PCM)
    var onAudioPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - 오디오 설정

    static let targetSampleRate: Double = 16000.0
    static let targetChannelCount: AVAudioChannelCount = 1

    // MARK: - Private 프로퍼티

    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private lazy var targetFormat: AVAudioFormat? = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: false
        )
    }()

    // MARK: - 캡처 시작

    func startCapture() throws {
        guard !isCapturing else { return }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("[MicCaptureService] 유효하지 않은 입력 포맷: \(inputFormat)")
            return
        }

        guard let targetFormat = targetFormat else { return }

        // 리샘플링 컨버터 생성
        audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            guard let resampled = self.resample(buffer) else { return }

            // 오디오 레벨 업데이트
            let level = self.calculateAudioLevel(from: resampled)
            DispatchQueue.main.async {
                self.audioLevel = level
            }

            self.onAudioPCMBuffer?(resampled)
        }

        try audioEngine.start()

        DispatchQueue.main.async {
            self.isCapturing = true
        }

        print("[MicCaptureService] 마이크 캡처 시작 (sampleRate: \(Self.targetSampleRate)Hz)")
    }

    // MARK: - 캡처 정지

    func stopCapture() {
        guard isCapturing else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        DispatchQueue.main.async {
            self.isCapturing = false
            self.audioLevel = 0.0
        }

        print("[MicCaptureService] 마이크 캡처 정지")
    }

    // MARK: - 리샘플링

    private func resample(_ sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = audioConverter, let targetFormat = targetFormat else { return nil }

        let sourceFormat = sourceBuffer.format
        if sourceFormat.sampleRate == targetFormat.sampleRate
            && sourceFormat.channelCount == targetFormat.channelCount {
            return sourceBuffer
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let error = error {
            print("[MicCaptureService] 리샘플링 에러: \(error)")
            return nil
        }

        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }

    // MARK: - 오디오 레벨

    private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.0 }

        let channelDataValue = channelData[0]
        var sum: Float = 0.0

        for i in 0..<frameLength {
            let sample = channelDataValue[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        let minDb: Float = -60.0
        let db = 20.0 * log10(max(rms, 1e-10))
        let normalizedLevel = max(0.0, min(1.0, (db - minDb) / (-minDb)))

        return normalizedLevel
    }
}
