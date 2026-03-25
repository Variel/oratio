import Foundation
import AVFoundation
import Combine
import os.log

private let micLog = Logger(subsystem: "ing.unlimit.oratio", category: "MicCapture")

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

        // Voice Processing 활성화 — AEC(에코 캔슬링) + 노이즈 억제
        // VP는 내부 집합 디바이스를 생성하여 3채널(마이크+참조)로 변경됨
        try inputNode.setVoiceProcessingEnabled(true)

        let vpFormat = inputNode.outputFormat(forBus: 0)
        micLog.warning("VP 활성화 — deviceID: \(inputNode.auAudioUnit.deviceID), sampleRate: \(vpFormat.sampleRate), ch: \(vpFormat.channelCount)")

        let inputFormat = vpFormat

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("[MicCaptureService] 유효하지 않은 입력 포맷: \(inputFormat)")
            return
        }

        guard let targetFormat = targetFormat else { return }

        audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)

        micLog.warning("tap 설치 — format: sampleRate=\(inputFormat.sampleRate), ch=\(inputFormat.channelCount)")

        // VP가 3채널을 줄 수 있으므로 nil format으로 받아서 채널 0만 추출
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            // 멀티채널이면 채널 0(에코 제거된 마이크)만 모노 버퍼로 추출
            let monoBuffer: AVAudioPCMBuffer
            if buffer.format.channelCount > 1 {
                guard let extracted = self.extractChannel0(from: buffer) else { return }
                monoBuffer = extracted
            } else {
                monoBuffer = buffer
            }

            // 리샘플링 (48kHz → 16kHz)
            let output: AVAudioPCMBuffer
            if monoBuffer.format.sampleRate == Self.targetSampleRate {
                output = monoBuffer
            } else {
                // 컨버터가 없거나 포맷이 바뀌었으면 재생성
                if self.audioConverter == nil || self.audioConverter?.inputFormat != monoBuffer.format {
                    self.audioConverter = AVAudioConverter(from: monoBuffer.format, to: targetFormat)
                }
                guard let resampled = self.resample(monoBuffer) else { return }
                output = resampled
            }

            let level = self.calculateAudioLevel(from: output)
            DispatchQueue.main.async {
                self.audioLevel = level
            }

            self.onAudioPCMBuffer?(output)
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
        try? audioEngine.inputNode.setVoiceProcessingEnabled(false)

        DispatchQueue.main.async {
            self.isCapturing = false
            self.audioLevel = 0.0
        }

        print("[MicCaptureService] 마이크 캡처 정지")
    }

    // MARK: - 채널 추출

    /// 멀티채널 버퍼에서 채널 0만 모노 버퍼로 추출
    private func extractChannel0(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = buffer.frameLength

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
            return nil
        }
        monoBuffer.frameLength = frameCount

        guard let monoData = monoBuffer.floatChannelData else { return nil }

        // 채널 0 복사
        memcpy(monoData[0], channelData[0], Int(frameCount) * MemoryLayout<Float>.size)

        return monoBuffer
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
